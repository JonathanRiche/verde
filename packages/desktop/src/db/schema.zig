//! SQLite schema and connection initialization for app persistence.

const std = @import("std");
const zqlite = @import("zqlite");

/// Latest schema version understood by this build.
pub const CURRENT_VERSION: i64 = 1;

pub const INIT_SQL: [:0]const u8 =
    \\create table if not exists app_state (
    \\    id integer primary key check (id = 1),
    \\    selected_workspace_index integer not null,
    \\    sidebar_collapsed integer not null default 0
    \\);
    \\create table if not exists workspaces (
    \\    id integer primary key,
    \\    workspace_id text not null unique,
    \\    sort_index integer not null,
    \\    label text not null,
    \\    path text not null,
    \\    archived integer not null default 0,
    \\    unread_count integer not null default 0,
    \\    collapsed integer not null default 0,
    \\    thread_list_expanded integer not null default 0,
    \\    terminal_height real,
    \\    terminal_layout_json text,
    \\    terminal_docks_json text,
    \\    workspace_layout_json text,
    \\    selected_thread_index integer not null default 0,
    \\    companion_thread_local_id text,
    \\    herdr_remote_alias text,
    \\    herdr_session_name text,
    \\    herdr_workspace_id text,
    \\    herdr_local_dir text,
    \\    herdr_remote_cwd text,
    \\    herdr_last_pane_id text,
    \\    herdr_attach_dock_id integer,
    \\    herdr_attach_pane_id integer,
    \\    herdr_pane_links_json text,
    \\    herdr_updated_at_ms integer
    \\);
    \\create unique index if not exists workspaces_sort_index_idx on workspaces(sort_index);
    \\create table if not exists threads (
    \\    id integer primary key,
    \\    workspace_id integer not null references workspaces(id) on delete cascade,
    \\    sort_index integer not null,
    \\    title text not null,
    \\    archived integer not null default 0,
    \\    committed integer not null default 1,
    \\    local_thread_id text,
    \\    last_activity_at integer,
    \\    provider_thread_id text,
    \\    model_ref text,
    \\    reasoning_effort integer,
    \\    reasoning_variant text,
    \\    fast_mode integer,
    \\    access_mode integer,
    \\    provider integer not null,
    \\    harness integer not null,
    \\    tui_dock_id integer,
    \\    draft text not null default '',
    \\    draft_image_path text,
    \\    draft_image_mime text,
    \\    draft_image_byte_size integer,
    \\    unique(workspace_id, sort_index)
    \\);
    \\create table if not exists messages (
    \\    id integer primary key,
    \\    thread_id integer not null references threads(id) on delete cascade,
    \\    sort_index integer not null,
    \\    role integer not null,
    \\    author text not null,
    \\    body text not null,
    \\    image_path text,
    \\    image_mime text,
    \\    image_byte_size integer,
    \\    tool_call_id text,
    \\    tool_call_kind integer,
    \\    tool_call_status integer,
    \\    unique(thread_id, sort_index)
    \\);
    \\create table if not exists surface_completions (
    \\    session_id text primary key,
    \\    workspace_id text not null default '',
    \\    workspace_path text not null default '',
    \\    dock_id integer not null default 0,
    \\    pane_id integer,
    \\    provider integer,
    \\    provider_thread_id text,
    \\    title text not null default '',
    \\    status integer not null default 3,
    \\    status_changed_at_ms integer not null default 0,
    \\    completed_at_ms integer not null,
    \\    last_event_title text,
    \\    last_event_body text
    \\);
    \\create index if not exists surface_completions_completed_idx on surface_completions(completed_at_ms);
    \\create table if not exists chat_completions (
    \\    workspace_id text not null,
    \\    local_thread_id text not null,
    \\    completed_at_ms integer not null,
    \\    primary key (workspace_id, local_thread_id)
    \\);
    \\create index if not exists chat_completions_completed_idx on chat_completions(completed_at_ms);
;

pub fn initialize(conn: zqlite.Conn) !void {
    try conn.busyTimeout(5000);
    const initial_version = try userVersion(conn);
    if (initial_version > CURRENT_VERSION) return error.DatabaseSchemaTooNew;

    if (initial_version < CURRENT_VERSION) {
        try migrate(conn, .none);
    }

    try conn.execNoArgs(
        \\pragma foreign_keys = on;
        \\pragma journal_mode = wal;
    );
}

const MigrationFailurePoint = enum {
    none,
    before_version_bump,
};

fn migrate(conn: zqlite.Conn, comptime failure_point: MigrationFailurePoint) !void {
    try conn.execNoArgs("begin immediate");
    errdefer conn.rollback();

    var version = try userVersion(conn);
    if (version > CURRENT_VERSION) return error.DatabaseSchemaTooNew;
    while (version < CURRENT_VERSION) {
        switch (version) {
            0 => {
                try migrateV0ToV1(conn);
                if (failure_point == .before_version_bump) return error.TestMigrationFailure;
                try conn.execNoArgs("pragma user_version = 1");
                version = 1;
            },
            else => return error.DatabaseSchemaInvalid,
        }
    }

    try conn.commit();
}

fn migrateV0ToV1(conn: zqlite.Conn) !void {
    try conn.execNoArgs(INIT_SQL);
    try ensureColumn(conn, "app_state", "sidebar_collapsed", "alter table app_state add column sidebar_collapsed integer not null default 0");
    try ensureColumn(conn, "workspaces", "archived", "alter table workspaces add column archived integer not null default 0");
    try ensureColumn(conn, "workspaces", "terminal_height", "alter table workspaces add column terminal_height real");
    try ensureColumn(conn, "workspaces", "terminal_layout_json", "alter table workspaces add column terminal_layout_json text");
    try ensureColumn(conn, "workspaces", "terminal_docks_json", "alter table workspaces add column terminal_docks_json text");
    try ensureColumn(conn, "workspaces", "workspace_layout_json", "alter table workspaces add column workspace_layout_json text");
    try ensureColumn(conn, "workspaces", "companion_thread_local_id", "alter table workspaces add column companion_thread_local_id text");
    try ensureColumn(conn, "workspaces", "herdr_remote_alias", "alter table workspaces add column herdr_remote_alias text");
    try ensureColumn(conn, "workspaces", "herdr_session_name", "alter table workspaces add column herdr_session_name text");
    try ensureColumn(conn, "workspaces", "herdr_workspace_id", "alter table workspaces add column herdr_workspace_id text");
    try ensureColumn(conn, "workspaces", "herdr_local_dir", "alter table workspaces add column herdr_local_dir text");
    try ensureColumn(conn, "workspaces", "herdr_remote_cwd", "alter table workspaces add column herdr_remote_cwd text");
    try ensureColumn(conn, "workspaces", "herdr_last_pane_id", "alter table workspaces add column herdr_last_pane_id text");
    try ensureColumn(conn, "workspaces", "herdr_attach_dock_id", "alter table workspaces add column herdr_attach_dock_id integer");
    try ensureColumn(conn, "workspaces", "herdr_attach_pane_id", "alter table workspaces add column herdr_attach_pane_id integer");
    try ensureColumn(conn, "workspaces", "herdr_pane_links_json", "alter table workspaces add column herdr_pane_links_json text");
    try ensureColumn(conn, "workspaces", "herdr_updated_at_ms", "alter table workspaces add column herdr_updated_at_ms integer");
    try ensureColumn(conn, "threads", "archived", "alter table threads add column archived integer not null default 0");
    try ensureColumn(conn, "threads", "local_thread_id", "alter table threads add column local_thread_id text");
    try ensureColumn(conn, "threads", "reasoning_variant", "alter table threads add column reasoning_variant text");
    try ensureColumn(conn, "threads", "tui_dock_id", "alter table threads add column tui_dock_id integer");
    try ensureColumn(conn, "messages", "tool_call_id", "alter table messages add column tool_call_id text");
    try ensureColumn(conn, "messages", "tool_call_kind", "alter table messages add column tool_call_kind integer");
    try ensureColumn(conn, "messages", "tool_call_status", "alter table messages add column tool_call_status integer");
    // Keep the legacy table name so existing unacknowledged completions migrate
    // in place; it now stores the latest non-idle terminal surface state.
    try ensureColumn(conn, "surface_completions", "status", "alter table surface_completions add column status integer not null default 3");
    try ensureColumn(conn, "surface_completions", "status_changed_at_ms", "alter table surface_completions add column status_changed_at_ms integer not null default 0");
}

fn userVersion(conn: zqlite.Conn) !i64 {
    var row = (try conn.row("pragma user_version", .{})) orelse return error.MissingSchemaVersion;
    defer row.deinit();
    return row.int(0);
}

fn ensureColumn(conn: zqlite.Conn, table_name: []const u8, column_name: []const u8, alter_sql: [*:0]const u8) !void {
    var pragma_buf: [128]u8 = undefined;
    const pragma_sql = try std.fmt.bufPrint(&pragma_buf, "pragma table_info({s})", .{table_name});
    var rows = try conn.rows(pragma_sql, .{});
    defer rows.deinit();

    while (rows.next()) |row| {
        if (std.mem.eql(u8, row.text(1), column_name)) return;
    }
    if (rows.err) |err| return err;

    try conn.execNoArgs(alter_sql);
}

pub fn testHasColumn(conn: zqlite.Conn, table_name: []const u8, column_name: []const u8) !bool {
    var pragma_buf: [128]u8 = undefined;
    const pragma_sql = try std.fmt.bufPrint(&pragma_buf, "pragma table_info({s})", .{table_name});
    var rows = try conn.rows(pragma_sql, .{});
    defer rows.deinit();

    while (rows.next()) |row| {
        if (std.mem.eql(u8, row.text(1), column_name)) return true;
    }
    if (rows.err) |err| return err;
    return false;
}

test "failed migration rolls back schema, version, and data" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const path = try std.fs.path.joinZ(std.testing.allocator, &.{ path_buf[0..path_len], "state.sqlite" });
    defer std.testing.allocator.free(path);

    const flags = zqlite.OpenFlags.Create | zqlite.OpenFlags.EXResCode;
    const conn = try zqlite.open(path, flags);
    defer conn.close();
    try conn.execNoArgs(
        \\create table threads (id integer primary key, marker text not null);
        \\insert into threads (id, marker) values (7, 'kept through rollback');
    );

    // A deterministic hook failure exercises SQLite's rollback path. The test
    // cannot simulate process death or power loss hermetically.
    try std.testing.expectError(error.TestMigrationFailure, migrate(conn, .before_version_bump));
    try std.testing.expectEqual(@as(i64, 0), try userVersion(conn));
    try std.testing.expect(!try testHasColumn(conn, "threads", "reasoning_variant"));

    var table_count = (try conn.row("select count(*) from sqlite_schema where type = 'table' and name not like 'sqlite_%'", .{})).?;
    defer table_count.deinit();
    try std.testing.expectEqual(@as(i64, 1), table_count.int(0));

    var marker = (try conn.row("select marker from threads where id = 7", .{})).?;
    defer marker.deinit();
    try std.testing.expectEqualStrings("kept through rollback", marker.text(0));
}
