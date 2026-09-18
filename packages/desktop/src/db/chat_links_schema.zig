//! Additive orchestration persistence schema.
pub const SCHEMA_SQL: [:0]const u8 =
    \\create table if not exists chat_links (
    \\ link_id text primary key, workspace_id text not null, parent_thread_id text not null,
    \\ local_thread_id text not null, hidden integer not null default 0,
    \\ delivery_enabled integer not null default 1,
    \\ unique(workspace_id,parent_thread_id,local_thread_id)
    \\);
    \\create table if not exists chat_tasks (
    \\ task_id text primary key, workspace_id text not null, local_thread_id text not null,
    \\ owner text not null, status text not null default 'running', summary text not null default '',
    \\ created_at_ms integer not null, updated_at_ms integer not null, revision integer not null default 1,
    \\ approval_json text, result_json text
    \\);
    \\create table if not exists chat_deliveries (
    \\ task_id text not null references chat_tasks(task_id) on delete cascade,
    \\ link_id text not null references chat_links(link_id) on delete cascade,
    \\ revision integer not null, status text not null, summary text not null,
    \\ delivered integer not null default 0, parent_turn_id text,
    \\ primary key(task_id,link_id,revision)
    \\);
    \\create index if not exists chat_tasks_thread_idx on chat_tasks(workspace_id,local_thread_id,created_at_ms);
;
