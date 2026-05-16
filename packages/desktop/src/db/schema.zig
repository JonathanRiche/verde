//! SQLite schema and connection initialization for app persistence.

const std = @import("std");
const zqlite = @import("zqlite");

pub const INIT_SQL: [:0]const u8 =
    \\pragma foreign_keys = on;
    \\pragma journal_mode = wal;
    \\create table if not exists app_state (
    \\    id integer primary key check (id = 1),
    \\    selected_project_index integer not null,
    \\    sidebar_collapsed integer not null default 0
    \\);
    \\create table if not exists projects (
    \\    id integer primary key,
    \\    project_id text not null unique,
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
    \\    selected_thread_index integer not null default 0
    \\);
    \\create unique index if not exists projects_sort_index_idx on projects(sort_index);
    \\create table if not exists threads (
    \\    id integer primary key,
    \\    project_id integer not null references projects(id) on delete cascade,
    \\    sort_index integer not null,
    \\    title text not null,
    \\    archived integer not null default 0,
    \\    committed integer not null default 1,
    \\    last_activity_at integer,
    \\    provider_thread_id text,
    \\    model_ref text,
    \\    reasoning_effort integer,
    \\    fast_mode integer,
    \\    access_mode integer,
    \\    provider integer not null,
    \\    harness integer not null,
    \\    draft text not null default '',
    \\    draft_image_path text,
    \\    draft_image_mime text,
    \\    draft_image_byte_size integer,
    \\    unique(project_id, sort_index)
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
    try ensureColumn(conn, "projects", "archived", "alter table projects add column archived integer not null default 0");
    try ensureColumn(conn, "projects", "terminal_height", "alter table projects add column terminal_height real");
    try ensureColumn(conn, "projects", "terminal_layout_json", "alter table projects add column terminal_layout_json text");
    try ensureColumn(conn, "projects", "terminal_docks_json", "alter table projects add column terminal_docks_json text");
    try ensureColumn(conn, "projects", "workspace_layout_json", "alter table projects add column workspace_layout_json text");
    try ensureColumn(conn, "threads", "archived", "alter table threads add column archived integer not null default 0");
    try ensureColumn(conn, "threads", "reasoning_variant", "alter table threads add column reasoning_variant text");
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
