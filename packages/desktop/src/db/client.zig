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

// Full-state autosaves use a detached connection while focused saves and
// completion ledgers use the UI-owned connection. SQLite serializes writers,
// so serialize Verde's in-process owners before entering SQLite rather than
// allowing a legitimate send to exhaust the busy timeout behind an autosave.
const InProcessWriteMutex = struct {
    inner: std.atomic.Mutex = .unlocked,

    fn lock(self: *InProcessWriteMutex) void {
        while (!self.inner.tryLock()) std.atomic.spinLoopHint();
    }

    fn unlock(self: *InProcessWriteMutex) void {
        self.inner.unlock();
    }
};

var in_process_write_mutex: InProcessWriteMutex = .{};

pub const STATE_DB_NAME = "state.sqlite";

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

    pub fn init(allocator: std.mem.Allocator, pref_path: []const u8) !Self {
        const path = try pathForPrefPath(allocator, pref_path);
        errdefer allocator.free(path);

        const flags = zqlite.OpenFlags.Create | zqlite.OpenFlags.EXResCode;
        const conn = try zqlite.open(path, flags);
        errdefer conn.close();

        in_process_write_mutex.lock();
        defer in_process_write_mutex.unlock();
        try schema.initialize(conn);
        return .{
            .allocator = allocator,
            .path = path,
            .conn = conn,
        };
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
        return self.loadSnapshot(backing_allocator, NoopLoadHook{});
    }

    fn loadSnapshot(self: *const Self, backing_allocator: std.mem.Allocator, hook: anytype) !?LoadedState {
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
        var workspaces: std.ArrayList(PersistedProject) = .empty;
        defer workspaces.deinit(arena);

        var workspace_rows = try self.conn.rows(
            "select id, workspace_id, label, path, archived, unread_count, collapsed, thread_list_expanded, terminal_height, terminal_layout_json, terminal_docks_json, workspace_layout_json, selected_thread_index, companion_thread_local_id, " ++
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
                .threads = try self.loadThreads(arena, workspace_id),
            });
        }
        if (workspace_rows.err) |err| return err;

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

    pub fn upsertSurfaceState(self: *const Self, surface: PersistedSurfaceState) !void {
        in_process_write_mutex.lock();
        defer in_process_write_mutex.unlock();
        try self.conn.exec(
            "insert into surface_completions (session_id, workspace_id, workspace_path, dock_id, pane_id, provider, provider_thread_id, title, status, status_changed_at_ms, completed_at_ms, last_event_title, last_event_body) " ++
                "values (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13) " ++
                "on conflict(session_id) do update set workspace_id = excluded.workspace_id, workspace_path = excluded.workspace_path, dock_id = excluded.dock_id, " ++
                "pane_id = excluded.pane_id, provider = excluded.provider, provider_thread_id = excluded.provider_thread_id, title = excluded.title, " ++
                "status = excluded.status, status_changed_at_ms = excluded.status_changed_at_ms, completed_at_ms = excluded.completed_at_ms, " ++
                "last_event_title = excluded.last_event_title, last_event_body = excluded.last_event_body",
            .{
                surface.session_id,
                surface.workspace_id,
                surface.workspace_path,
                @as(i64, @intCast(surface.dock_id)),
                if (surface.pane_id) |pane_id| @as(i64, @intCast(pane_id)) else null,
                encodeOptionalEnum(surface.provider),
                surface.provider_thread_id,
                surface.title,
                @as(i64, @intFromEnum(surface.status)),
                surface.status_changed_at_ms,
                surface.completed_at_ms,
                surface.last_event_title,
                surface.last_event_body,
            },
        );
    }

    pub fn clearSurfaceState(self: *const Self, session_id: []const u8) !bool {
        in_process_write_mutex.lock();
        defer in_process_write_mutex.unlock();
        try self.conn.exec("delete from surface_completions where session_id = ?1", .{session_id});
        return self.conn.changes() > 0;
    }

    pub fn upsertChatCompletion(self: *const Self, completion: PersistedChatCompletion) !void {
        in_process_write_mutex.lock();
        defer in_process_write_mutex.unlock();
        try self.conn.exec(
            "insert into chat_completions (workspace_id, local_thread_id, completed_at_ms) values (?1, ?2, ?3) " ++
                "on conflict(workspace_id, local_thread_id) do update set completed_at_ms = excluded.completed_at_ms",
            .{ completion.workspace_id, completion.local_thread_id, completion.completed_at_ms },
        );
    }

    pub fn clearChatCompletion(self: *const Self, workspace_id: []const u8, local_thread_id: []const u8) !bool {
        in_process_write_mutex.lock();
        defer in_process_write_mutex.unlock();
        try self.conn.exec(
            "delete from chat_completions where workspace_id = ?1 and local_thread_id = ?2",
            .{ workspace_id, local_thread_id },
        );
        return self.conn.changes() > 0;
    }

    pub fn save(self: *const Self, state: PersistedState) !void {
        in_process_write_mutex.lock();
        defer in_process_write_mutex.unlock();
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
                "insert into workspaces (workspace_id, sort_index, label, path, archived, unread_count, collapsed, thread_list_expanded, terminal_height, terminal_layout_json, terminal_docks_json, workspace_layout_json, selected_thread_index, companion_thread_local_id, " ++
                    "herdr_remote_alias, herdr_session_name, herdr_workspace_id, herdr_local_dir, herdr_remote_cwd, herdr_last_pane_id, herdr_attach_dock_id, herdr_attach_pane_id, herdr_pane_links_json, herdr_updated_at_ms) " ++
                    "values (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?18, ?19, ?20, ?21, ?22, ?23, ?24)",
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
                    project.companion_thread_local_id,
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

    /// Persist one chat thread without rewriting unrelated transcript history.
    pub fn saveThread(self: *const Self, workspace_id: []const u8, thread_index: usize, thread: PersistedThread) !void {
        in_process_write_mutex.lock();
        defer in_process_write_mutex.unlock();
        var workspace_row = (try self.conn.row(
            "select id from workspaces where workspace_id = ?1",
            .{workspace_id},
        )) orelse return error.WorkspaceNotFound;
        defer workspace_row.deinit();
        const workspace_row_id = workspace_row.int(0);

        try self.conn.transaction();
        errdefer self.conn.rollback();
        try self.conn.exec(
            "delete from threads where workspace_id = ?1 and sort_index = ?2",
            .{ workspace_row_id, @as(i64, @intCast(thread_index)) },
        );
        try self.saveThreadAtIndex(workspace_row_id, thread_index, thread);
        try self.conn.commit();
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

        // M4-P4 identity round-trip: durable message identities must reload
        // verbatim so the next flush re-carries them instead of re-minting
        // positional ids. Pre-v4 projections (daemon not yet migrated) lack
        // the column; validateReadOnly accepts them, so probe before select.
        const has_message_id = blk: {
            const probe = self.conn.row(
                "select 1 from pragma_table_info('messages') where name = 'message_id'",
                .{},
            ) catch break :blk false;
            const row = probe orelse break :blk false;
            row.deinit();
            break :blk true;
        };
        var message_rows = try self.conn.rows(
            if (has_message_id)
                "select role, author, body, image_path, image_mime, image_byte_size, tool_call_id, tool_call_kind, tool_call_status, message_id " ++
                    "from messages where thread_id = ?1 order by sort_index"
            else
                "select role, author, body, image_path, image_mime, image_byte_size, tool_call_id, tool_call_kind, tool_call_status, null " ++
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
                // Empty string normalizes to null: "no identity known".
                .message_id = blk: {
                    const raw = message_row.nullableText(9) orelse break :blk null;
                    if (raw.len == 0) break :blk null;
                    break :blk try allocator.dupe(u8, raw);
                },
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
            try self.saveThreadAtIndex(project_id, thread_index, thread);
        }
    }

    fn saveThreadAtIndex(self: *const Self, project_id: i64, thread_index: usize, thread: PersistedThread) !void {
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

fn testCreateLegacyWalFixture(pref_path: []const u8) !zqlite.Conn {
    const conn = try testOpenDatabase(testing.allocator, pref_path);
    errdefer conn.close();
    try conn.execNoArgs(migration_fixture.LEGACY_V0_WAL_SQL);
    return conn;
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

test "fresh database initializes at the current schema version" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const pref_path = try testDirPathAlloc(tmp.dir, testing.allocator);
    defer testing.allocator.free(pref_path);

    var client = try Client.init(testing.allocator, pref_path);
    defer client.deinit();
    try testing.expectEqual(schema.CURRENT_VERSION, try testUserVersion(client.conn));
    try testing.expect(try schema.testHasColumn(client.conn, "threads", "reasoning_variant"));
    var table_count = (try client.conn.row("select count(*) from sqlite_schema where type = 'table' and name not like 'sqlite_%'", .{})).?;
    defer table_count.deinit();
    try testing.expectEqual(@as(i64, 6), table_count.int(0));
    try testExpectDatabaseChecks(client.conn);
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

test "read-only open loads a current database" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const pref_path = try testDirPathAlloc(tmp.dir, testing.allocator);
    defer testing.allocator.free(pref_path);

    {
        var writer = try Client.init(testing.allocator, pref_path);
        defer writer.deinit();
        try writer.save(.{ .sidebar_collapsed = true });
    }

    var reader = try Client.initReadOnly(testing.allocator, pref_path);
    defer reader.deinit();
    var busy_timeout = (try reader.conn.row("pragma busy_timeout", .{})).?;
    defer busy_timeout.deinit();
    try testing.expectEqual(@as(i64, schema.BUSY_TIMEOUT_MS), busy_timeout.int(0));
    var loaded = (try reader.load(testing.allocator)).?;
    defer loaded.deinit();
    try testing.expect(loaded.value.sidebar_collapsed);
    try testing.expectError(error.ReadOnly, reader.conn.execNoArgs("delete from app_state"));
}

test "load holds one WAL snapshot across all reads" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const pref_path = try testDirPathAlloc(tmp.dir, testing.allocator);
    defer testing.allocator.free(pref_path);

    var writer = try Client.init(testing.allocator, pref_path);
    defer writer.deinit();
    try writer.save(.{
        .selected_project_index = 0,
        .projects = &.{.{
            .id = "workspace-1",
            .label = "before",
            .path = "/tmp/workspace",
        }},
    });

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

    var loaded = (try reader.loadSnapshot(testing.allocator, UpdateAfterFirstRead{ .conn = writer.conn })).?;
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

    var client = try Client.init(testing.allocator, pref_path);
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

    var loaded = (try client.load(testing.allocator)).?;
    defer loaded.deinit();
    try testExpectLegacyFixtureState(loaded.value, null);
    try testExpectDatabaseChecks(client.conn);
}

test "WAL pre-versioning fixture migrates and reopens with sidecars present" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const pref_path = try testDirPathAlloc(tmp.dir, testing.allocator);
    defer testing.allocator.free(pref_path);

    const legacy = try testCreateLegacyWalFixture(pref_path);
    var legacy_open = true;
    defer if (legacy_open) legacy.close();
    {
        var journal_mode = (try legacy.row("pragma journal_mode", .{})).?;
        defer journal_mode.deinit();
        try testing.expectEqualStrings("wal", journal_mode.text(0));
    }
    _ = try tmp.dir.statFile(testing.io, STATE_DB_NAME ++ "-wal", .{});
    _ = try tmp.dir.statFile(testing.io, STATE_DB_NAME ++ "-shm", .{});

    {
        var migrated = try Client.init(testing.allocator, pref_path);
        defer migrated.deinit();
        try testing.expectEqual(schema.CURRENT_VERSION, try testUserVersion(migrated.conn));
        try testing.expect(try schema.testHasColumn(migrated.conn, "threads", "reasoning_variant"));
        try testExpectRowCount(migrated.conn, "messages", 5);
        var loaded = (try migrated.load(testing.allocator)).?;
        defer loaded.deinit();
        try testExpectLegacyFixtureState(loaded.value, null);
        try testExpectDatabaseChecks(migrated.conn);
    }
    legacy.close();
    legacy_open = false;

    var reopened = try Client.init(testing.allocator, pref_path);
    defer reopened.deinit();
    try testing.expectEqual(schema.CURRENT_VERSION, try testUserVersion(reopened.conn));
    try testing.expect(try schema.testHasColumn(reopened.conn, "threads", "reasoning_variant"));
    try testExpectRowCount(reopened.conn, "messages", 5);
    var loaded = (try reopened.load(testing.allocator)).?;
    defer loaded.deinit();
    try testExpectLegacyFixtureState(loaded.value, null);
    try testExpectDatabaseChecks(reopened.conn);
}

test "schema migration is idempotent across repeated client initialization" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const pref_path = try testDirPathAlloc(tmp.dir, testing.allocator);
    defer testing.allocator.free(pref_path);
    try testCreateLegacyFixture(pref_path);
    {
        const legacy = try testOpenDatabase(testing.allocator, pref_path);
        defer legacy.close();
        try legacy.execNoArgs(
            \\alter table threads add column reasoning_variant text;
            \\update threads set reasoning_variant = '最高' where id = 1001;
        );
    }

    {
        var first = try Client.init(testing.allocator, pref_path);
        defer first.deinit();
        try testing.expectEqual(schema.CURRENT_VERSION, try testUserVersion(first.conn));
    }
    {
        var second = try Client.init(testing.allocator, pref_path);
        defer second.deinit();
        try testing.expectEqual(schema.CURRENT_VERSION, try testUserVersion(second.conn));
        var columns = try second.conn.rows("pragma table_info(threads)", .{});
        defer columns.deinit();
        var reasoning_variant_count: usize = 0;
        while (columns.next()) |row| {
            if (std.mem.eql(u8, row.text(1), "reasoning_variant")) reasoning_variant_count += 1;
        }
        if (columns.err) |err| return err;
        try testing.expectEqual(@as(usize, 1), reasoning_variant_count);
        try testExpectRowCount(second.conn, "workspaces", 2);
        try testExpectRowCount(second.conn, "threads", 3);
        try testExpectRowCount(second.conn, "messages", 5);
        var loaded = (try second.load(testing.allocator)).?;
        defer loaded.deinit();
        try testExpectLegacyFixtureState(loaded.value, "最高");
        try testExpectDatabaseChecks(second.conn);
    }
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
    try testing.expectError(error.DatabaseSchemaTooNew, Client.init(testing.allocator, pref_path));

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

test "newer WAL schema rejection leaves WAL state untouched" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const pref_path = try testDirPathAlloc(tmp.dir, testing.allocator);
    defer testing.allocator.free(pref_path);

    const future = try testCreateLegacyWalFixture(pref_path);
    defer future.close();
    // Derive the future version so schema-chain growth can't stale this fixture.
    try future.execNoArgs(std.fmt.comptimePrint(
        \\create table future_marker (id integer primary key, value text not null);
        \\insert into future_marker (id, value) values (1, 'future WAL data Ω');
        \\pragma user_version = {d};
    , .{schema.MAX_SUPPORTED_VERSION + 1}));
    _ = try tmp.dir.statFile(testing.io, STATE_DB_NAME ++ "-wal", .{});
    _ = try tmp.dir.statFile(testing.io, STATE_DB_NAME ++ "-shm", .{});

    const main_before = try tmp.dir.readFileAlloc(testing.io, STATE_DB_NAME, testing.allocator, .unlimited);
    defer testing.allocator.free(main_before);
    const wal_before = try tmp.dir.readFileAlloc(testing.io, STATE_DB_NAME ++ "-wal", testing.allocator, .unlimited);
    defer testing.allocator.free(wal_before);
    try testing.expectError(error.DatabaseSchemaTooNew, Client.initReadOnly(testing.allocator, pref_path));
    try testing.expectError(error.DatabaseSchemaTooNew, Client.init(testing.allocator, pref_path));

    const main_after = try tmp.dir.readFileAlloc(testing.io, STATE_DB_NAME, testing.allocator, .unlimited);
    defer testing.allocator.free(main_after);
    const wal_after = try tmp.dir.readFileAlloc(testing.io, STATE_DB_NAME ++ "-wal", testing.allocator, .unlimited);
    defer testing.allocator.free(wal_after);
    try testing.expectEqualSlices(u8, main_before, main_after);
    try testing.expectEqualSlices(u8, wal_before, wal_after);
    // SQLite may update volatile WAL-index read marks while opening a
    // connection, even when the database and WAL receive no writes.
    _ = try tmp.dir.statFile(testing.io, STATE_DB_NAME ++ "-shm", .{});

    try testing.expectEqual(schema.MAX_SUPPORTED_VERSION + 1, try testUserVersion(future));
    var marker = (try future.row("select value from future_marker where id = 1", .{})).?;
    defer marker.deinit();
    try testing.expectEqualStrings("future WAL data Ω", marker.text(0));
    try testing.expect(!try schema.testHasColumn(future, "future_marker", "reasoning_variant"));
}

test "terminal surface states survive state saves and clear explicitly" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const pref_path = try testDirPathAlloc(tmp.dir, testing.allocator);
    defer testing.allocator.free(pref_path);

    var client = try Client.init(testing.allocator, pref_path);
    defer client.deinit();

    try client.save(.{});
    try client.upsertSurfaceState(.{
        .session_id = "session-later",
        .workspace_id = "workspace-2",
        .workspace_path = "/tmp/two",
        .dock_id = 2,
        .pane_id = 12,
        .provider = .cursor,
        .title = "Later",
        .status = .working,
        .status_changed_at_ms = 200,
    });
    try client.upsertSurfaceState(.{
        .session_id = "session-first",
        .workspace_id = "workspace-1",
        .workspace_path = "/tmp/one",
        .dock_id = 1,
        .pane_id = 11,
        .provider = .codex,
        .title = "First",
        .status = .done,
        .status_changed_at_ms = 100,
        .completed_at_ms = 100,
    });

    // Ordinary app-state snapshots must not erase the independent surface
    // ledger, including when another process writes it between saves.
    try client.save(.{ .sidebar_collapsed = true });

    var loaded = (try client.load(testing.allocator)).?;
    defer loaded.deinit();
    try testing.expectEqual(@as(usize, 2), loaded.value.surface_states.len);
    try testing.expectEqualStrings("session-first", loaded.value.surface_states[0].session_id);
    try testing.expectEqual(db_types.SurfaceStatus.done, loaded.value.surface_states[0].status);
    try testing.expectEqualStrings("session-later", loaded.value.surface_states[1].session_id);
    try testing.expectEqual(db_types.SurfaceStatus.working, loaded.value.surface_states[1].status);
    try testing.expect(try client.clearSurfaceState("session-first"));
    try testing.expect(!try client.clearSurfaceState("session-first"));
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

test "single-thread save preserves unrelated transcript history" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const pref_path = try testDirPathAlloc(tmp.dir, testing.allocator);
    defer testing.allocator.free(pref_path);

    var client = try Client.init(testing.allocator, pref_path);
    defer client.deinit();

    try client.save(.{ .projects = &.{.{
        .id = "workspace-1",
        .label = "Workspace",
        .path = "/tmp/workspace",
        .threads = &.{
            .{
                .title = "Unrelated",
                .local_thread_id = "thread-1",
                .provider = .codex,
                .messages = &.{.{ .role = .user, .author = "You", .body = "keep me" }},
            },
            .{
                .title = "Target",
                .local_thread_id = "thread-2",
                .provider = .codex,
                .messages = &.{.{ .role = .user, .author = "You", .body = "old" }},
            },
        },
    }} });

    try client.saveThread("workspace-1", 1, .{
        .title = "Target updated",
        .local_thread_id = "thread-2",
        .provider = .codex,
        .messages = &.{
            .{ .role = .user, .author = "You", .body = "old" },
            .{ .role = .user, .author = "You", .body = "new prompt" },
        },
    });

    var loaded = (try client.load(testing.allocator)).?;
    defer loaded.deinit();
    const threads = loaded.value.projects[0].threads.?;
    try testing.expectEqual(@as(usize, 2), threads.len);
    try testing.expectEqualStrings("keep me", threads[0].messages[0].body);
    try testing.expectEqualStrings("Target updated", threads[1].title);
    try testing.expectEqual(@as(usize, 2), threads[1].messages.len);
    try testing.expectEqualStrings("new prompt", threads[1].messages[1].body);
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
                .companion_thread_local_id = "companion-local",
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
                        .title = "Companion",
                        .committed = true,
                        .local_thread_id = "companion-local",
                        .provider = .codex,
                        .draft = "",
                        .messages = &.{.{
                            .role = .user,
                            .author = "You",
                            .body = "companion-thread",
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
    try testing.expectEqualStrings("companion-local", loaded.?.value.projects[0].companion_thread_local_id.?);
    try testing.expectEqualStrings("companion-local", loaded.?.value.projects[0].threads.?[1].local_thread_id.?);
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
