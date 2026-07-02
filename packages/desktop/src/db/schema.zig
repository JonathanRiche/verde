//! SQLite schema and connection initialization for app persistence.

const std = @import("std");
const zqlite = @import("zqlite");

pub const INIT_SQL: [:0]const u8 =
    \\pragma foreign_keys = on;
    \\pragma journal_mode = wal;
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
    \\    unique(thread_id, sort_index)
    \\);
;

pub fn initialize(conn: zqlite.Conn) !void {
    try conn.busyTimeout(5000);
    try conn.execNoArgs(INIT_SQL);
    try ensureColumn(conn, "app_state", "sidebar_collapsed", "alter table app_state add column sidebar_collapsed integer not null default 0");
    try ensureColumn(conn, "workspaces", "archived", "alter table workspaces add column archived integer not null default 0");
    try ensureColumn(conn, "workspaces", "terminal_height", "alter table workspaces add column terminal_height real");
    try ensureColumn(conn, "workspaces", "terminal_layout_json", "alter table workspaces add column terminal_layout_json text");
    try ensureColumn(conn, "workspaces", "terminal_docks_json", "alter table workspaces add column terminal_docks_json text");
    try ensureColumn(conn, "workspaces", "workspace_layout_json", "alter table workspaces add column workspace_layout_json text");
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
