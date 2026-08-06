//! Frozen pre-versioning database fixture used by migration regression tests.

// This is the version-0 schema written out independently from schema.INIT_SQL.
// It represents the current schema immediately before reasoning_variant was
// introduced and deliberately leaves PRAGMA user_version at SQLite's default 0.
pub const LEGACY_V0_SQL: [:0]const u8 =
    \\create table app_state (
    \\    id integer primary key check (id = 1),
    \\    selected_workspace_index integer not null,
    \\    sidebar_collapsed integer not null default 0
    \\);
    \\create table workspaces (
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
    \\create unique index workspaces_sort_index_idx on workspaces(sort_index);
    \\create table threads (
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
    \\create table messages (
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
    \\create table surface_completions (
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
    \\create index surface_completions_completed_idx on surface_completions(completed_at_ms);
    \\create table chat_completions (
    \\    workspace_id text not null,
    \\    local_thread_id text not null,
    \\    completed_at_ms integer not null,
    \\    primary key (workspace_id, local_thread_id)
    \\);
    \\create index chat_completions_completed_idx on chat_completions(completed_at_ms);
    \\insert into app_state (id, selected_workspace_index, sidebar_collapsed)
    \\values (1, 1, 1);
    \\insert into workspaces (
    \\    id, workspace_id, sort_index, label, path, archived, unread_count,
    \\    collapsed, thread_list_expanded, terminal_height, terminal_layout_json,
    \\    terminal_docks_json, workspace_layout_json, selected_thread_index,
    \\    companion_thread_local_id, herdr_remote_alias, herdr_session_name,
    \\    herdr_workspace_id, herdr_local_dir, herdr_remote_cwd,
    \\    herdr_last_pane_id, herdr_attach_dock_id, herdr_attach_pane_id,
    \\    herdr_pane_links_json, herdr_updated_at_ms
    \\) values
    \\    (101, 'workspace-α', 0, 'Montréal 🚀', '/tmp/verde/équipe', 0, 7,
    \\     1, 1, 384.5, '{"root":"terminal"}', '[{"id":4}]',
    \\     '{"pane":"chat"}', 0, 'thread-archived', 'zod.example', 'défaut',
    \\     'remote-α', '/tmp/verde/équipe', '/srv/工程', 'pane-九', 4, 9,
    \\     '[{"verde_pane_id":9}]', 1700000000123),
    \\    (202, 'workspace-archive', 1, 'Archive Ω', 'C:/Users/Test/Verde Ω', 1, 0,
    \\     0, 0, null, null, null, null, 0, null, null, null, null, null,
    \\     null, null, null, null, null, null);
    \\insert into threads (
    \\    id, workspace_id, sort_index, title, archived, committed,
    \\    local_thread_id, last_activity_at, provider_thread_id, model_ref,
    \\    reasoning_effort, fast_mode, access_mode, provider, harness,
    \\    tui_dock_id, draft, draft_image_path, draft_image_mime,
    \\    draft_image_byte_size
    \\) values
    \\    (1001, 101, 0, 'Active café', 0, 1, 'thread-active', 1700000001000,
    \\     'provider-活', 'openai/gpt-5', 2, 1, 0, 1, 0, 4,
    \\     'draft — keep exactly', '/tmp/draft-猫.png', 'image/png', 4242),
    \\    (1002, 101, 1, 'Archived thread 🗄️', 1, 1, 'thread-archived',
    \\     1700000002000, null, 'opencode/model', 1, 0, 1, 0, 1, null,
    \\     '', null, null, null),
    \\    (2001, 202, 0, 'Workspace archive thread', 1, 1,
    \\     'thread-workspace-archive', 1700000003000, 'provider-old', null,
    \\     null, null, null, 2, 0, 12, '再開', null, null, null);
    \\insert into messages (
    \\    id, thread_id, sort_index, role, author, body, image_path,
    \\    image_mime, image_byte_size, tool_call_id, tool_call_kind,
    \\    tool_call_status
    \\) values
    \\    (5001, 1001, 0, 0, 'You', 'Hello, 世界 👋', '/tmp/input-λ.jpg',
    \\     'image/jpeg', 12345, null, null, null),
    \\    (5002, 1001, 1, 1, 'Codex', 'It''s persisted — café', null,
    \\     null, null, null, null, null),
    \\    (5003, 1001, 2, 2, 'Ran command', '$ printf ''✓''', null,
    \\     null, null, 'call-π', 5, 2),
    \\    (5004, 1002, 0, 0, 'You', 'Archived question ¿qué?', null,
    \\     null, null, null, null, null),
    \\    (5005, 2001, 0, 1, 'Claude', '旧 workspace answer', null,
    \\     null, null, null, null, null);
    \\insert into surface_completions (
    \\    session_id, workspace_id, workspace_path, dock_id, pane_id, provider,
    \\    provider_thread_id, title, status, status_changed_at_ms,
    \\    completed_at_ms, last_event_title, last_event_body
    \\) values
    \\    ('session-α', 'workspace-α', '/tmp/verde/équipe', 4, 9, 1,
    \\     'provider-活', 'Build ✓', 3, 1700000004000, 1700000004000,
    \\     'Ran command', '全部 good'),
    \\    ('session-error', 'workspace-archive', 'C:/Users/Test/Verde Ω', 12,
    \\     null, 3, null, 'Failure ⚠', 4, 1700000005000, 0,
    \\     'Command failed', 'exit 2 — Ω');
    \\insert into chat_completions (workspace_id, local_thread_id, completed_at_ms)
    \\values
    \\    ('workspace-α', 'thread-active', 1700000006000),
    \\    ('workspace-archive', 'thread-workspace-archive', 1700000007000);
;
