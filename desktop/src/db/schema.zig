//! SQLite schema and connection initialization for app persistence.

const zqlite = @import("zqlite");

pub const INIT_SQL: [:0]const u8 =
    \\pragma foreign_keys = on;
    \\pragma journal_mode = wal;
    \\create table if not exists app_state (
    \\    id integer primary key check (id = 1),
    \\    selected_project_index integer not null
    \\);
    \\create table if not exists projects (
    \\    id integer primary key,
    \\    project_id text not null unique,
    \\    sort_index integer not null,
    \\    label text not null,
    \\    path text not null,
    \\    unread_count integer not null default 0,
    \\    collapsed integer not null default 0,
    \\    thread_list_expanded integer not null default 0,
    \\    selected_thread_index integer not null default 0
    \\);
    \\create unique index if not exists projects_sort_index_idx on projects(sort_index);
    \\create table if not exists threads (
    \\    id integer primary key,
    \\    project_id integer not null references projects(id) on delete cascade,
    \\    sort_index integer not null,
    \\    title text not null,
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
}
