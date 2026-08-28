//! SQLite schema and connection initialization for app persistence.

const std = @import("std");
const zqlite = @import("zqlite");

/// Latest schema version understood by this build.
pub const CURRENT_VERSION: i64 = 1;
/// Maximum schema version understood by read-only clients and the daemon store.
pub const MAX_SUPPORTED_VERSION: i64 = 9;
/// SQLite busy timeout shared by writer and read-only connections.
pub const BUSY_TIMEOUT_MS = 5000;

/// Stable daemon identity persisted alongside the authoritative store state.
pub const RuntimeIdentity = struct {
    runtime_id: []const u8,
    instance_id: []const u8,
};

/// Stored shape of one attachment past the primary inside the additive v5
/// `threads.draft_images_json` / `messages.extra_images_json` columns. Only
/// genuinely known metadata is stored; mime may be empty.
pub const StoredExtraImage = struct {
    path: []const u8,
    mime: []const u8 = "",
    byte_size: u64 = 0,
};

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
    try initializeToVersion(conn, CURRENT_VERSION);
}

/// Initialize a writer connection to the requested schema version.
///
/// The normal desktop writer deliberately requests v1. The daemon store is
/// the only caller that requests the newer versions while the store remains
/// dormant in production.
pub fn initializeToVersion(conn: zqlite.Conn, target_version: i64) !void {
    if (target_version < CURRENT_VERSION or target_version > MAX_SUPPORTED_VERSION) {
        return error.DatabaseSchemaInvalid;
    }
    try conn.busyTimeout(BUSY_TIMEOUT_MS);
    const initial_version = try userVersion(conn);
    if (initial_version > target_version) return error.DatabaseSchemaTooNew;

    if (initial_version < target_version) {
        try migrateToVersion(conn, target_version, .none);
    }

    try conn.execNoArgs(
        \\pragma foreign_keys = on;
        \\pragma journal_mode = wal;
    );
}

/// Initialize the authoritative daemon store and bind it to one identity.
///
/// For a new database or a pre-v8 database, the current schema and identity
/// pair commit in the same migration transaction. A v8+ database must already carry
/// the exact pair; missing, partial, or mismatched metadata is never reseeded.
pub fn initializeStoreWithRuntimeIdentity(conn: zqlite.Conn, identity: RuntimeIdentity) !void {
    if (!validRuntimeIdentityPart(identity.runtime_id) or
        !validRuntimeIdentityPart(identity.instance_id))
    {
        return error.InvalidRuntimeIdentity;
    }

    try conn.busyTimeout(BUSY_TIMEOUT_MS);
    const initial_version = try userVersion(conn);
    if (initial_version > MAX_SUPPORTED_VERSION) return error.DatabaseSchemaTooNew;

    if (initial_version < MAX_SUPPORTED_VERSION) {
        try migrateToVersionWithRuntimeIdentity(conn, MAX_SUPPORTED_VERSION, identity);
    } else {
        try conn.execNoArgs("begin immediate");
        errdefer conn.rollback();
        try validateOrSeedRuntimeIdentity(conn, identity, false);
        try seedLegacyPrimaryRepositories(conn);
        try conn.commit();
    }

    try conn.execNoArgs(
        \\pragma foreign_keys = on;
        \\pragma journal_mode = wal;
    );
}

/// Validate that a read-only connection can consume the schema without
/// attempting initialization or migration.
pub fn validateReadOnly(conn: zqlite.Conn) !void {
    const version = try userVersion(conn);
    if (version < 0) return error.DatabaseSchemaInvalid;
    if (version > MAX_SUPPORTED_VERSION) return error.DatabaseSchemaTooNew;
    if (version < CURRENT_VERSION) return error.DatabaseSchemaTooOld;
}

const MigrationFailurePoint = enum {
    none,
    before_version_bump,
};

fn migrate(conn: zqlite.Conn, comptime failure_point: MigrationFailurePoint) !void {
    try migrateToVersion(conn, CURRENT_VERSION, failure_point);
}

fn migrateToVersion(
    conn: zqlite.Conn,
    target_version: i64,
    comptime failure_point: MigrationFailurePoint,
) !void {
    try migrateToVersionInternal(conn, target_version, failure_point, null);
}

fn migrateToVersionWithRuntimeIdentity(
    conn: zqlite.Conn,
    target_version: i64,
    identity: RuntimeIdentity,
) !void {
    try migrateToVersionInternal(conn, target_version, .none, identity);
}

fn migrateToVersionInternal(
    conn: zqlite.Conn,
    target_version: i64,
    comptime failure_point: MigrationFailurePoint,
    runtime_identity: ?RuntimeIdentity,
) !void {
    try conn.execNoArgs("begin immediate");
    errdefer conn.rollback();

    const initial_version = try userVersion(conn);
    var version = initial_version;
    if (version > target_version) return error.DatabaseSchemaTooNew;
    while (version < target_version) {
        switch (version) {
            0 => {
                try migrateV0ToV1(conn);
                if (failure_point == .before_version_bump) return error.TestMigrationFailure;
                try conn.execNoArgs("pragma user_version = 1");
                version = 1;
            },
            1 => {
                try migrateV1ToV2(conn);
                if (failure_point == .before_version_bump) return error.TestMigrationFailure;
                try conn.execNoArgs("pragma user_version = 2");
                version = 2;
            },
            2 => {
                try migrateV2ToV3(conn);
                if (failure_point == .before_version_bump) return error.TestMigrationFailure;
                try conn.execNoArgs("pragma user_version = 3");
                version = 3;
            },
            3 => {
                try migrateV3ToV4(conn);
                if (failure_point == .before_version_bump) return error.TestMigrationFailure;
                try conn.execNoArgs("pragma user_version = 4");
                version = 4;
            },
            4 => {
                try migrateV4ToV5(conn);
                if (failure_point == .before_version_bump) return error.TestMigrationFailure;
                try conn.execNoArgs("pragma user_version = 5");
                version = 5;
            },
            5 => {
                try migrateV5ToV6(conn);
                if (failure_point == .before_version_bump) return error.TestMigrationFailure;
                try conn.execNoArgs("pragma user_version = 6");
                version = 6;
            },
            6 => {
                try migrateV6ToV7(conn);
                if (failure_point == .before_version_bump) return error.TestMigrationFailure;
                try conn.execNoArgs("pragma user_version = 7");
                version = 7;
            },
            7 => {
                try migrateV7ToV8(conn);
                if (failure_point == .before_version_bump) return error.TestMigrationFailure;
                try conn.execNoArgs("pragma user_version = 8");
                version = 8;
            },
            8 => {
                try migrateV8ToV9(conn);
                if (failure_point == .before_version_bump) return error.TestMigrationFailure;
                try conn.execNoArgs("pragma user_version = 9");
                version = 9;
            },
            else => return error.DatabaseSchemaInvalid,
        }
    }

    if (runtime_identity) |identity| {
        try validateOrSeedRuntimeIdentity(conn, identity, initial_version < 8);
        try seedLegacyPrimaryRepositories(conn);
    }

    try conn.commit();
}

fn migrateV1ToV2(conn: zqlite.Conn) !void {
    // Production flip (S1 Minor 5 / S5 P3 handoff): legacy v1 DBs may hold
    // duplicate non-null (workspace_id, local_thread_id) rows. Dedupe before
    // the partial unique index. Survivor = MAX(rowid): re-import / re-insert
    // paths that created duplicates typically append a fresher copy at a higher
    // id, so keeping the newest row preserves the latest transcript content.
    // Messages for discarded rows are deleted first because foreign_keys are
    // off during migration (cascade would not fire).
    try conn.execNoArgs(
        \\delete from messages where thread_id in (
        \\  select t.id from threads t
        \\  where t.local_thread_id is not null
        \\    and exists (
        \\      select 1 from threads t2
        \\      where t2.workspace_id = t.workspace_id
        \\        and t2.local_thread_id = t.local_thread_id
        \\        and t2.id > t.id
        \\    )
        \\);
        \\delete from threads where id in (
        \\  select t.id from threads t
        \\  where t.local_thread_id is not null
        \\    and exists (
        \\      select 1 from threads t2
        \\      where t2.workspace_id = t.workspace_id
        \\        and t2.local_thread_id = t.local_thread_id
        \\        and t2.id > t.id
        \\    )
        \\);
    );
    try conn.execNoArgs(
        \\create table if not exists store_state (
        \\    id integer primary key check (id = 1),
        \\    store_revision integer not null check (store_revision >= 0)
        \\);
        \\insert or ignore into store_state (id, store_revision) values (1, 0);
        \\create table if not exists store_receipts (
        \\    request_key text primary key,
        \\    operation text not null,
        \\    fingerprint text not null,
        \\    store_revision integer not null check (store_revision >= 0),
        \\    response_payload text not null,
        \\    response_status integer not null default 0
        \\);
        \\create table if not exists client_message_keys (
        \\    thread_id integer not null references threads(id) on delete cascade,
        \\    message_id text not null,
        \\    message_fingerprint text not null,
        \\    sort_index integer not null,
        \\    created_at_ms integer,
        \\    updated_at_ms integer,
        \\    store_revision integer not null check (store_revision >= 0),
        \\    primary key (thread_id, message_id)
        \\);
        \\create unique index if not exists threads_workspace_local_thread_id_idx
        \\    on threads(workspace_id, local_thread_id) where local_thread_id is not null;
    );
}

fn migrateV2ToV3(conn: zqlite.Conn) !void {
    try conn.execNoArgs(
        \\create table if not exists workspace_leases (
        \\    workspace_id text not null,
        \\    lease_id text not null,
        \\    owner text not null,
        \\    client_id text not null,
        \\    command text not null,
        \\    resources_json text not null,
        \\    created_at_ms integer not null,
        \\    expires_at_ms integer not null,
        \\    last_renewal_ms integer not null,
        \\    primary key (workspace_id, lease_id)
        \\);
        \\create index if not exists workspace_leases_expires_idx
        \\    on workspace_leases(expires_at_ms);
        \\create table if not exists terminal_process_outcomes (
        \\    workspace_id text not null,
        \\    process_id text not null,
        \\    generation integer not null,
        \\    session_id text not null,
        \\    command text not null,
        \\    cwd text not null,
        \\    pid integer,
        \\    process_group integer,
        \\    started_at_ms integer not null,
        \\    finished_at_ms integer not null,
        \\    dock_id integer not null,
        \\    pane_id integer,
        \\    owner_kind text not null,
        \\    owner_title text not null,
        \\    provider text,
        \\    status text not null,
        \\    exit_code integer,
        \\    signal integer,
        \\    cancellation_reason text,
        \\    primary key (workspace_id, process_id, generation)
        \\);
        \\create index if not exists terminal_process_outcomes_finished_idx
        \\    on terminal_process_outcomes(finished_at_ms);
    );
}

fn migrateV3ToV4(conn: zqlite.Conn) !void {
    try conn.execNoArgs(
        \\create table if not exists chat_turns (
        \\    turn_id text primary key,
        \\    workspace_id text not null,
        \\    local_thread_id text not null,
        \\    status text not null check (status in ('accepted', 'running', 'waiting_approval', 'completed', 'failed', 'aborted', 'interrupted')),
        \\    started_at_ms integer not null,
        \\    finished_at_ms integer,
        \\    provider text not null,
        \\    provider_thread_id text,
        \\    error_message text,
        \\    user_message_id text,
        \\    committed_store_revision integer
        \\);
        \\create index if not exists chat_turns_thread_idx
        \\    on chat_turns(workspace_id, local_thread_id, started_at_ms);
        \\create index if not exists chat_turns_status_idx
        \\    on chat_turns(status, started_at_ms);
    );

    // M3 kept client-visible identity and timestamps in its receipt mapping.
    // Mirror them on transcript rows so durable reads retain the exact order
    // emitted by transcript_apply without requiring a private mapping join.
    try ensureColumn(conn, "messages", "message_id", "alter table messages add column message_id text");
    try ensureColumn(conn, "messages", "created_at_ms", "alter table messages add column created_at_ms integer");
    try ensureColumn(conn, "messages", "updated_at_ms", "alter table messages add column updated_at_ms integer");
    try conn.execNoArgs(
        \\update messages
        \\set message_id = (select message_id from client_message_keys where client_message_keys.thread_id = messages.thread_id and client_message_keys.sort_index = messages.sort_index),
        \\    created_at_ms = (select created_at_ms from client_message_keys where client_message_keys.thread_id = messages.thread_id and client_message_keys.sort_index = messages.sort_index),
        \\    updated_at_ms = (select updated_at_ms from client_message_keys where client_message_keys.thread_id = messages.thread_id and client_message_keys.sort_index = messages.sort_index)
        \\where message_id is null;
        \\create unique index if not exists messages_thread_message_id_idx
        \\    on messages(thread_id, message_id) where message_id is not null;
    );
}

fn migrateV4ToV5(conn: zqlite.Conn) !void {
    // Multi-attachment durability: the single image_path/mime/byte_size
    // columns keep the primary attachment for old readers, while every
    // attachment past the first is carried as a compact JSON array so no
    // composer or transcript image is silently narrowed to one.
    try ensureColumn(conn, "threads", "draft_images_json", "alter table threads add column draft_images_json text");
    try ensureColumn(conn, "messages", "extra_images_json", "alter table messages add column extra_images_json text");
}

fn migrateV5ToV6(conn: zqlite.Conn) !void {
    // Per-thread working-directory override. Null keeps the thread on its
    // workspace path, so every existing row and older client is unaffected.
    try ensureColumn(conn, "threads", "cwd", "alter table threads add column cwd text");
}

fn migrateV6ToV7(conn: zqlite.Conn) !void {
    // Per-thread execution routing. Nulls intentionally encode legacy Local +
    // primary-repository state so every existing row remains valid and a
    // stable runtime identity can be learned on a later handshake.
    try ensureColumn(conn, "threads", "profile_id", "alter table threads add column profile_id text");
    try ensureColumn(conn, "threads", "runtime_id", "alter table threads add column runtime_id text");
    try ensureColumn(conn, "threads", "repository_id", "alter table threads add column repository_id text");
    try ensureColumn(conn, "threads", "repository_cwd", "alter table threads add column repository_cwd text");
    try conn.execNoArgs(
        \\create trigger if not exists threads_committed_route_immutable
        \\before update of committed, profile_id, runtime_id, repository_id, repository_cwd on threads
        \\when old.committed != 0 and (
        \\    new.committed = 0
        \\    or coalesce(new.profile_id, 'local') != coalesce(old.profile_id, 'local')
        \\    or coalesce(new.repository_id, 'primary') != coalesce(old.repository_id, 'primary')
        \\    or coalesce(new.repository_cwd, '') != coalesce(old.repository_cwd, '')
        \\    or (old.profile_id is not null and old.profile_id != 'local' and
        \\        old.runtime_id is null)
        \\    or (old.runtime_id is not null and
        \\        (new.runtime_id is null or new.runtime_id != old.runtime_id))
        \\)
        \\begin
        \\    select raise(abort, 'committed thread route is immutable');
        \\end;
    );
}

fn migrateV7ToV8(conn: zqlite.Conn) !void {
    // The JSON sidecar keeps the data-directory runtime identity discoverable,
    // while SQLite is authoritative for the store incarnation. Null/null is
    // retained only so generic test/projection stores can migrate; production
    // initialization seeds the pair in this same transaction.
    try ensureColumn(conn, "store_state", "runtime_id", "alter table store_state add column runtime_id text");
    try ensureColumn(conn, "store_state", "instance_id", "alter table store_state add column instance_id text");
    try conn.execNoArgs(
        \\drop trigger if exists threads_committed_route_immutable;
        \\create trigger threads_committed_route_immutable
        \\before update of committed, profile_id, runtime_id, repository_id, repository_cwd on threads
        \\when old.committed != 0 and (
        \\    new.committed = 0
        \\    or coalesce(new.profile_id, 'local') != coalesce(old.profile_id, 'local')
        \\    or coalesce(new.repository_id, 'primary') != coalesce(old.repository_id, 'primary')
        \\    or coalesce(new.repository_cwd, '') != coalesce(old.repository_cwd, '')
        \\    or (old.profile_id is not null and old.profile_id != 'local' and
        \\        old.runtime_id is null)
        \\    or (old.runtime_id is not null and
        \\        (new.runtime_id is null or new.runtime_id != old.runtime_id))
        \\)
        \\begin
        \\    select raise(abort, 'committed thread route is immutable');
        \\end;
        \\create trigger if not exists store_runtime_identity_pair_valid
        \\before update of runtime_id, instance_id on store_state
        \\when (new.runtime_id is null) != (new.instance_id is null)
        \\  or (new.runtime_id is not null and (
        \\      length(new.runtime_id) != 32
        \\      or new.runtime_id glob '*[^0-9a-f]*'
        \\      or length(new.instance_id) != 32
        \\      or new.instance_id glob '*[^0-9a-f]*'
        \\  ))
        \\begin
        \\    select raise(abort, 'invalid store runtime identity');
        \\end;
        \\create trigger if not exists store_runtime_identity_immutable
        \\before update of runtime_id, instance_id on store_state
        \\when (old.runtime_id is not null or old.instance_id is not null) and (
        \\    new.runtime_id is null
        \\    or new.instance_id is null
        \\    or new.runtime_id != old.runtime_id
        \\    or new.instance_id != old.instance_id
        \\)
        \\begin
        \\    select raise(abort, 'store runtime identity is immutable');
        \\end;
    );
}

fn migrateV8ToV9(conn: zqlite.Conn) !void {
    // Repository identity is workspace-scoped and checkout paths are
    // runtime-scoped. The legacy workspace path remains the local runtime's
    // stable `primary` binding instead of becoming an inferred repository ID.
    try ensureColumn(
        conn,
        "workspaces",
        "default_repository_id",
        "alter table workspaces add column default_repository_id text not null default 'primary'",
    );
    try conn.execNoArgs(
        \\create table if not exists workspace_repositories (
        \\    id integer primary key,
        \\    workspace_id integer not null references workspaces(id) on delete cascade,
        \\    repository_id text not null check (
        \\        length(repository_id) between 1 and 128 and
        \\        repository_id not glob '*[^A-Za-z0-9._-]*'
        \\    ),
        \\    sort_index integer not null check (sort_index >= 0),
        \\    label text not null check (length(label) between 1 and 256),
        \\    vcs_identity text check (vcs_identity is null or length(vcs_identity) between 1 and 2048),
        \\    default_branch text check (default_branch is null or length(default_branch) between 1 and 255),
        \\    unique(workspace_id, repository_id)
        \\);
        \\create table if not exists workspace_repository_bindings (
        \\    repository_row_id integer not null references workspace_repositories(id) on delete cascade,
        \\    runtime_id text not null check (
        \\        length(runtime_id) = 32 and runtime_id not glob '*[^0-9a-f]*'
        \\    ),
        \\    root_path text not null check (length(root_path) between 1 and 4096),
        \\    availability text not null check (availability in ('available', 'missing', 'unknown')),
        \\    primary key (repository_row_id, runtime_id)
        \\);
        \\create index if not exists workspace_repository_bindings_runtime_idx
        \\    on workspace_repository_bindings(runtime_id, repository_row_id);
        \\create trigger if not exists workspaces_primary_binding_path_insert_valid
        \\before insert on workspaces
        \\when exists (select 1 from store_state where id = 1 and runtime_id is not null)
        \\ and not (
        \\    (length(new.path) > 1 and substr(new.path, 1, 1) = '/')
        \\    or (length(new.path) > 3 and substr(new.path, 1, 1) glob '[A-Za-z]'
        \\        and substr(new.path, 2, 1) = ':'
        \\        and substr(new.path, 3, 1) in ('/', '\'))
        \\    or (substr(new.path, 1, 2) = '\\'
        \\        and instr(substr(new.path, 3), '\') > 1
        \\        and instr(substr(new.path, 3 + instr(substr(new.path, 3), '\')), '\') > 1
        \\        and length(substr(new.path, 3 + instr(substr(new.path, 3), '\'))) >
        \\            instr(substr(new.path, 3 + instr(substr(new.path, 3), '\')), '\'))
        \\ )
        \\begin
        \\    select raise(abort, 'workspace primary repository path must be absolute');
        \\end;
        \\create trigger if not exists workspaces_primary_repository_insert
        \\after insert on workspaces
        \\begin
        \\    insert into workspace_repositories (workspace_id, repository_id, sort_index, label)
        \\    values (new.id, 'primary', 0, 'Primary');
        \\    insert into workspace_repository_bindings (repository_row_id, runtime_id, root_path, availability)
        \\    select repository.id, state.runtime_id, new.path, 'available'
        \\    from workspace_repositories repository join store_state state on state.id = 1
        \\    where repository.workspace_id = new.id
        \\      and repository.repository_id = 'primary'
        \\      and state.runtime_id is not null
        \\      and (
        \\          (length(new.path) > 1 and substr(new.path, 1, 1) = '/')
        \\          or (length(new.path) > 3 and substr(new.path, 1, 1) glob '[A-Za-z]'
        \\              and substr(new.path, 2, 1) = ':'
        \\              and substr(new.path, 3, 1) in ('/', '\'))
        \\          or (substr(new.path, 1, 2) = '\\'
        \\              and instr(substr(new.path, 3), '\') > 1
        \\              and instr(substr(new.path, 3 + instr(substr(new.path, 3), '\')), '\') > 1
        \\              and length(substr(new.path, 3 + instr(substr(new.path, 3), '\'))) >
        \\                  instr(substr(new.path, 3 + instr(substr(new.path, 3), '\')), '\'))
        \\      );
        \\    select case when not exists (
        \\        select 1 from workspace_repositories repository
        \\        where repository.workspace_id = new.id
        \\          and repository.repository_id = new.default_repository_id
        \\    ) then raise(abort, 'workspace default repository is missing') end;
        \\end;
        \\create trigger if not exists workspaces_default_repository_valid
        \\before update of default_repository_id on workspaces
        \\when not exists (
        \\    select 1 from workspace_repositories repository
        \\    where repository.workspace_id = old.id
        \\      and repository.repository_id = new.default_repository_id
        \\)
        \\begin
        \\    select raise(abort, 'workspace default repository is missing');
        \\end;
        \\create trigger if not exists workspace_default_repository_delete_guard
        \\before delete on workspace_repositories
        \\when exists (select 1 from workspaces where id = old.workspace_id)
        \\ and old.repository_id = (
        \\    select default_repository_id from workspaces where id = old.workspace_id
        \\ )
        \\begin
        \\    select raise(abort, 'workspace default repository cannot be removed');
        \\end;
        \\create trigger if not exists workspace_primary_repository_delete_guard
        \\before delete on workspace_repositories
        \\when exists (select 1 from workspaces where id = old.workspace_id)
        \\ and old.repository_id = 'primary'
        \\begin
        \\    select raise(abort, 'workspace primary repository cannot be removed');
        \\end;
        \\create trigger if not exists workspaces_primary_binding_path_update_valid
        \\before update of path on workspaces
        \\when new.path != old.path
        \\ and exists (select 1 from store_state where id = 1 and runtime_id is not null)
        \\ and not (
        \\    (length(new.path) > 1 and substr(new.path, 1, 1) = '/')
        \\    or (length(new.path) > 3 and substr(new.path, 1, 1) glob '[A-Za-z]'
        \\        and substr(new.path, 2, 1) = ':'
        \\        and substr(new.path, 3, 1) in ('/', '\'))
        \\    or (substr(new.path, 1, 2) = '\\'
        \\        and instr(substr(new.path, 3), '\') > 1
        \\        and instr(substr(new.path, 3 + instr(substr(new.path, 3), '\')), '\') > 1
        \\        and length(substr(new.path, 3 + instr(substr(new.path, 3), '\'))) >
        \\            instr(substr(new.path, 3 + instr(substr(new.path, 3), '\')), '\'))
        \\ )
        \\begin
        \\    select raise(abort, 'workspace primary repository path must be absolute');
        \\end;
        \\create trigger if not exists workspaces_primary_binding_path_sync
        \\after update of path on workspaces
        \\when new.path != old.path
        \\begin
        \\    update workspace_repository_bindings
        \\    set root_path = new.path
        \\    where repository_row_id = (
        \\        select repository.id from workspace_repositories repository
        \\        where repository.workspace_id = new.id and repository.repository_id = 'primary'
        \\    )
        \\      and runtime_id = (select runtime_id from store_state where id = 1);
        \\end;
    );
    try seedLegacyPrimaryRepositories(conn);
}

fn seedLegacyPrimaryRepositories(conn: zqlite.Conn) !void {
    try conn.execNoArgs(
        \\insert or ignore into workspace_repositories (workspace_id, repository_id, sort_index, label)
        \\select id, 'primary', 0, 'Primary' from workspaces;
        \\insert or ignore into workspace_repository_bindings (repository_row_id, runtime_id, root_path, availability)
        \\select repository.id, state.runtime_id, workspace.path, 'available'
        \\from workspace_repositories repository
        \\join workspaces workspace on workspace.id = repository.workspace_id
        \\join store_state state on state.id = 1
        \\where repository.repository_id = 'primary' and state.runtime_id is not null
        \\  and (
        \\      (length(workspace.path) > 1 and substr(workspace.path, 1, 1) = '/')
        \\      or (length(workspace.path) > 3 and substr(workspace.path, 1, 1) glob '[A-Za-z]'
        \\          and substr(workspace.path, 2, 1) = ':'
        \\          and substr(workspace.path, 3, 1) in ('/', '\'))
        \\      or (substr(workspace.path, 1, 2) = '\\'
        \\          and instr(substr(workspace.path, 3), '\') > 1
        \\          and instr(substr(workspace.path, 3 + instr(substr(workspace.path, 3), '\')), '\') > 1
        \\          and length(substr(workspace.path, 3 + instr(substr(workspace.path, 3), '\'))) >
        \\              instr(substr(workspace.path, 3 + instr(substr(workspace.path, 3), '\')), '\'))
        \\  );
    );
}

fn validateOrSeedRuntimeIdentity(conn: zqlite.Conn, identity: RuntimeIdentity, allow_seed: bool) !void {
    var row = (try conn.row(
        "select runtime_id, instance_id from store_state where id = 1",
        .{},
    )) orelse return error.StoreMetadataMissing;
    defer row.deinit();

    const stored_runtime_id = row.nullableText(0);
    const stored_instance_id = row.nullableText(1);
    if (stored_runtime_id == null and stored_instance_id == null) {
        if (!allow_seed) return error.StoreMetadataMissing;
        try conn.exec(
            "update store_state set runtime_id = ?1, instance_id = ?2 where id = 1",
            .{ identity.runtime_id, identity.instance_id },
        );
        return;
    }
    if (stored_runtime_id == null or stored_instance_id == null) return error.StoreMetadataCorrupt;
    if (!validRuntimeIdentityPart(stored_runtime_id.?) or
        !validRuntimeIdentityPart(stored_instance_id.?))
    {
        return error.StoreMetadataCorrupt;
    }
    if (!std.mem.eql(u8, stored_runtime_id.?, identity.runtime_id) or
        !std.mem.eql(u8, stored_instance_id.?, identity.instance_id))
    {
        return error.RuntimeIdentityMismatch;
    }
}

fn validRuntimeIdentityPart(value: []const u8) bool {
    if (value.len != 32) return false;
    for (value) |byte| {
        if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) return false;
    }
    return true;
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

test "schema migration chain advances v1 to v2 to v3 to v4 and preserves populated v3 data" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const path = try std.fs.path.joinZ(std.testing.allocator, &.{ path_buf[0..path_len], "state.sqlite" });
    defer std.testing.allocator.free(path);

    const conn = try zqlite.open(path, zqlite.OpenFlags.Create | zqlite.OpenFlags.EXResCode);
    defer conn.close();

    try migrateToVersion(conn, 1, .none);
    try std.testing.expectEqual(@as(i64, 1), try userVersion(conn));
    try conn.execNoArgs(
        \\insert into app_state (id, selected_workspace_index, sidebar_collapsed) values (1, 0, 0);
        \\insert into workspaces (workspace_id, sort_index, label, path) values ('chain-workspace', 0, 'Chain', '/chain');
    );

    try migrateToVersion(conn, 2, .none);
    try std.testing.expectEqual(@as(i64, 2), try userVersion(conn));
    try conn.execNoArgs(
        \\insert into store_receipts (request_key, operation, fingerprint, store_revision, response_payload, response_status)
        \\values ('chain-key', 'workspace.upsert', 'fingerprint', 1, '{}', 0);
    );

    try migrateToVersion(conn, 3, .none);
    try std.testing.expectEqual(@as(i64, 3), try userVersion(conn));
    try std.testing.expect(try testHasColumn(conn, "workspace_leases", "resources_json"));
    try std.testing.expect(try testHasColumn(conn, "terminal_process_outcomes", "cancellation_reason"));
    try conn.execNoArgs(
        \\insert into workspaces (workspace_id, sort_index, label, path) values ('v3-workspace', 1, 'V3', '/v3');
        \\insert into threads (workspace_id, sort_index, title, local_thread_id, provider, harness)
        \\values ((select id from workspaces where workspace_id = 'v3-workspace'), 0, 'V3 thread', 'v3-thread', 0, 0);
        \\insert into messages (thread_id, sort_index, role, author, body)
        \\values ((select id from threads where local_thread_id = 'v3-thread'), 0, 2, 'assistant', 'mapped transcript');
        \\insert into messages (thread_id, sort_index, role, author, body)
        \\values ((select id from threads where local_thread_id = 'v3-thread'), 1, 2, 'assistant', 'unmapped transcript');
        \\insert into client_message_keys (thread_id, message_id, message_fingerprint, sort_index, created_at_ms, updated_at_ms, store_revision)
        \\values ((select id from threads where local_thread_id = 'v3-thread'), 'mapped-message', 'v3-fingerprint', 0, 301, 302, 3);
    );

    try migrateToVersion(conn, 4, .none);
    try std.testing.expectEqual(@as(i64, 4), try userVersion(conn));
    try std.testing.expect(try testHasColumn(conn, "chat_turns", "committed_store_revision"));
    try std.testing.expect(try testHasColumn(conn, "messages", "message_id"));
    try std.testing.expect(try testHasColumn(conn, "messages", "created_at_ms"));
    try std.testing.expect(try testHasColumn(conn, "messages", "updated_at_ms"));

    var workspace = (try conn.row("select label from workspaces where workspace_id = 'chain-workspace'", .{})).?;
    defer workspace.deinit();
    try std.testing.expectEqualStrings("Chain", workspace.text(0));
    var receipt = (try conn.row("select response_payload from store_receipts where request_key = 'chain-key'", .{})).?;
    defer receipt.deinit();
    try std.testing.expectEqualStrings("{}", receipt.text(0));
    var mapped_message = (try conn.row(
        "select message_id, created_at_ms, updated_at_ms from messages where body = 'mapped transcript'",
        .{},
    )).?;
    defer mapped_message.deinit();
    try std.testing.expectEqualStrings("mapped-message", mapped_message.text(0));
    try std.testing.expectEqual(@as(i64, 301), mapped_message.int(1));
    try std.testing.expectEqual(@as(i64, 302), mapped_message.int(2));
    var unmapped_message = (try conn.row(
        "select message_id, created_at_ms, updated_at_ms from messages where body = 'unmapped transcript'",
        .{},
    )).?;
    defer unmapped_message.deinit();
    try std.testing.expect(unmapped_message.nullableText(0) == null);
    try std.testing.expect(unmapped_message.nullableInt(1) == null);
    try std.testing.expect(unmapped_message.nullableInt(2) == null);

    try migrateToVersion(conn, 5, .none);
    try std.testing.expectEqual(@as(i64, 5), try userVersion(conn));
    try std.testing.expect(try testHasColumn(conn, "threads", "draft_images_json"));
    try std.testing.expect(try testHasColumn(conn, "messages", "extra_images_json"));

    try migrateToVersion(conn, 6, .none);
    try std.testing.expectEqual(@as(i64, 6), try userVersion(conn));
    try std.testing.expect(try testHasColumn(conn, "threads", "cwd"));

    try migrateToVersion(conn, 7, .none);
    try std.testing.expectEqual(@as(i64, 7), try userVersion(conn));
    try std.testing.expect(try testHasColumn(conn, "threads", "profile_id"));
    try std.testing.expect(try testHasColumn(conn, "threads", "runtime_id"));
    try std.testing.expect(try testHasColumn(conn, "threads", "repository_id"));
    try std.testing.expect(try testHasColumn(conn, "threads", "repository_cwd"));

    try migrateToVersion(conn, 8, .none);
    try std.testing.expectEqual(@as(i64, 8), try userVersion(conn));
    try std.testing.expect(try testHasColumn(conn, "store_state", "runtime_id"));
    try std.testing.expect(try testHasColumn(conn, "store_state", "instance_id"));
    var identity = (try conn.row(
        "select runtime_id, instance_id from store_state where id = 1",
        .{},
    )).?;
    defer identity.deinit();
    try std.testing.expect(identity.nullableText(0) == null);
    try std.testing.expect(identity.nullableText(1) == null);

    try migrateToVersion(conn, 9, .none);
    try std.testing.expectEqual(@as(i64, 9), try userVersion(conn));
    try std.testing.expect(try testHasColumn(conn, "workspaces", "default_repository_id"));
    try std.testing.expect(try testHasColumn(conn, "workspace_repositories", "repository_id"));
    try std.testing.expect(try testHasColumn(conn, "workspace_repository_bindings", "runtime_id"));
    var primary = (try conn.row(
        "select repository_id, label from workspace_repositories where workspace_id = (select id from workspaces where workspace_id = 'chain-workspace')",
        .{},
    )).?;
    defer primary.deinit();
    try std.testing.expectEqualStrings("primary", primary.text(0));
    try std.testing.expectEqualStrings("Primary", primary.text(1));
}

test "v9 migration preserves legacy path as primary runtime binding" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const path = try std.fs.path.joinZ(std.testing.allocator, &.{ path_buf[0..path_len], "state.sqlite" });
    defer std.testing.allocator.free(path);

    const runtime_id = "0123456789abcdef0123456789abcdef";
    const conn = try zqlite.open(path, zqlite.OpenFlags.Create | zqlite.OpenFlags.EXResCode);
    defer conn.close();
    try migrateToVersion(conn, 8, .none);
    try conn.exec(
        "update store_state set runtime_id = ?1, instance_id = ?2 where id = 1",
        .{ runtime_id, "fedcba9876543210fedcba9876543210" },
    );
    try conn.execNoArgs(
        \\insert into app_state (id, selected_workspace_index, sidebar_collapsed) values (1, 0, 0);
        \\insert into workspaces (workspace_id, sort_index, label, path) values ('legacy', 0, 'Legacy', '/legacy');
    );

    try migrateToVersion(conn, 9, .none);
    {
        var migrated = (try conn.row(
            \\select workspace.default_repository_id, repository.repository_id, binding.runtime_id, binding.root_path
            \\from workspaces workspace
            \\join workspace_repositories repository on repository.workspace_id = workspace.id
            \\join workspace_repository_bindings binding on binding.repository_row_id = repository.id
            \\where workspace.workspace_id = 'legacy'
        , .{})).?;
        defer migrated.deinit();
        try std.testing.expectEqualStrings("primary", migrated.text(0));
        try std.testing.expectEqualStrings("primary", migrated.text(1));
        try std.testing.expectEqualStrings(runtime_id, migrated.text(2));
        try std.testing.expectEqualStrings("/legacy", migrated.text(3));
    }

    try std.testing.expectError(
        error.ConstraintTrigger,
        conn.execNoArgs("insert into workspaces (workspace_id, sort_index, label, path) values ('root-posix', 1, 'Root', '/')"),
    );
    try std.testing.expectError(
        error.ConstraintTrigger,
        conn.execNoArgs("insert into workspaces (workspace_id, sort_index, label, path) values ('root-drive', 1, 'Root', 'C:\\')"),
    );
    try std.testing.expectError(
        error.ConstraintTrigger,
        conn.execNoArgs("insert into workspaces (workspace_id, sort_index, label, path) values ('root-unc', 1, 'Root', '\\\\server\\share')"),
    );

    try conn.execNoArgs(
        "insert into workspaces (workspace_id, sort_index, label, path) values ('new', 1, 'New', '/new')",
    );
    {
        var inserted = (try conn.row(
            \\select binding.root_path
            \\from workspace_repository_bindings binding
            \\join workspace_repositories repository on repository.id = binding.repository_row_id
            \\join workspaces workspace on workspace.id = repository.workspace_id
            \\where workspace.workspace_id = 'new' and repository.repository_id = 'primary'
        , .{})).?;
        defer inserted.deinit();
        try std.testing.expectEqualStrings("/new", inserted.text(0));
    }

    try conn.execNoArgs("update workspaces set path = '/new-location' where workspace_id = 'new'");
    {
        var moved = (try conn.row(
            \\select binding.root_path
            \\from workspace_repository_bindings binding
            \\join workspace_repositories repository on repository.id = binding.repository_row_id
            \\join workspaces workspace on workspace.id = repository.workspace_id
            \\where workspace.workspace_id = 'new' and repository.repository_id = 'primary'
        , .{})).?;
        defer moved.deinit();
        try std.testing.expectEqualStrings("/new-location", moved.text(0));
    }

    try conn.execNoArgs("pragma foreign_keys = on");
    try conn.execNoArgs("delete from workspaces where workspace_id = 'new'");
    var orphan_count = (try conn.row(
        "select count(*) from workspace_repositories where workspace_id not in (select id from workspaces)",
        .{},
    )).?;
    defer orphan_count.deinit();
    try std.testing.expectEqual(@as(i64, 0), orphan_count.int(0));
}

test "v1 to v2 migration failure before version bump rolls back cleanly" {
    // Carried S1 review Minor 1: inject failure after v1→v2 DDL, before user_version bump.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const path = try std.fs.path.joinZ(std.testing.allocator, &.{ path_buf[0..path_len], "state.sqlite" });
    defer std.testing.allocator.free(path);

    const conn = try zqlite.open(path, zqlite.OpenFlags.Create | zqlite.OpenFlags.EXResCode);
    defer conn.close();
    try initialize(conn);
    try conn.execNoArgs(
        \\insert into app_state (id, selected_workspace_index, sidebar_collapsed) values (1, 0, 0);
        \\insert into workspaces (workspace_id, sort_index, label, path) values ('v1-probe', 0, 'Probe', '/probe');
    );

    try std.testing.expectError(error.TestMigrationFailure, migrateToVersion(conn, 2, .before_version_bump));
    try std.testing.expectEqual(@as(i64, 1), try userVersion(conn));
    try std.testing.expect(!try testHasColumn(conn, "store_state", "store_revision"));
    try std.testing.expect(!try testHasColumn(conn, "store_receipts", "request_key"));
    try std.testing.expect(!try testHasColumn(conn, "client_message_keys", "message_id"));
    // Partial unique index must not survive a rolled-back v1→v2 arm.
    var index_row = (try conn.row(
        "select count(*) from sqlite_schema where type = 'index' and name = 'threads_workspace_local_thread_id_idx'",
        .{},
    )).?;
    defer index_row.deinit();
    try std.testing.expectEqual(@as(i64, 0), index_row.int(0));

    var probe = (try conn.row("select label from workspaces where workspace_id = 'v1-probe'", .{})).?;
    defer probe.deinit();
    try std.testing.expectEqualStrings("Probe", probe.text(0));
}

test "v2 to v3 migration failure rolls back transfer tables and preserves v2 data" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const path = try std.fs.path.joinZ(std.testing.allocator, &.{ path_buf[0..path_len], "state.sqlite" });
    defer std.testing.allocator.free(path);

    const conn = try zqlite.open(path, zqlite.OpenFlags.Create | zqlite.OpenFlags.EXResCode);
    defer conn.close();
    try migrateToVersion(conn, 2, .none);
    try conn.execNoArgs(
        \\insert into store_receipts (request_key, operation, fingerprint, store_revision, response_payload, response_status)
        \\values ('rollback-key', 'workspace.upsert', 'fingerprint', 1, '{"ok":true}', 0);
    );

    try std.testing.expectError(error.TestMigrationFailure, migrateToVersion(conn, 3, .before_version_bump));
    try std.testing.expectEqual(@as(i64, 2), try userVersion(conn));
    try std.testing.expect(!try testHasColumn(conn, "workspace_leases", "lease_id"));
    try std.testing.expect(!try testHasColumn(conn, "terminal_process_outcomes", "process_id"));
    var receipt = (try conn.row("select response_payload from store_receipts where request_key = 'rollback-key'", .{})).?;
    defer receipt.deinit();
    try std.testing.expectEqualStrings("{\"ok\":true}", receipt.text(0));
}

test "v3 to v4 migration failure rolls back ledger and ordering columns" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const path = try std.fs.path.joinZ(std.testing.allocator, &.{ path_buf[0..path_len], "state.sqlite" });
    defer std.testing.allocator.free(path);

    const conn = try zqlite.open(path, zqlite.OpenFlags.Create | zqlite.OpenFlags.EXResCode);
    defer conn.close();
    try migrateToVersion(conn, 3, .none);
    try conn.execNoArgs(
        \\insert into workspace_leases (workspace_id, lease_id, owner, client_id, command, resources_json, created_at_ms, expires_at_ms, last_renewal_ms)
        \\values ('rollback-workspace', 'lease-1', 'owner', 'client', 'build', '[]', 1, 2, 1);
    );

    try std.testing.expectError(error.TestMigrationFailure, migrateToVersion(conn, 4, .before_version_bump));
    try std.testing.expectEqual(@as(i64, 3), try userVersion(conn));
    try std.testing.expect(!try testHasColumn(conn, "chat_turns", "turn_id"));
    try std.testing.expect(!try testHasColumn(conn, "messages", "message_id"));
    var lease = (try conn.row("select lease_id from workspace_leases where lease_id = 'lease-1'", .{})).?;
    defer lease.deinit();
    try std.testing.expectEqualStrings("lease-1", lease.text(0));
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

test "v1 to v2 dedupe keeps max-rowid survivor and its messages; idempotent re-run" {
    // MAJOR-4 / NEW-3: three duplicate (workspace_id, local_thread_id) rows with
    // distinct messages; max-rowid survives; discarded messages deleted;
    // non-duplicate control thread+message survives; re-running the dedupe SQL
    // itself is a no-op (not just the version-gated migrate no-op).
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const path = try std.fs.path.joinZ(std.testing.allocator, &.{ path_buf[0..path_len], "state.sqlite" });
    defer std.testing.allocator.free(path);

    const conn = try zqlite.open(path, zqlite.OpenFlags.Create | zqlite.OpenFlags.EXResCode);
    defer conn.close();

    try migrateToVersion(conn, 1, .none);
    try std.testing.expectEqual(@as(i64, 1), try userVersion(conn));
    try conn.execNoArgs(
        \\insert into app_state (id, selected_workspace_index, sidebar_collapsed) values (1, 0, 0);
        \\insert into workspaces (workspace_id, sort_index, label, path) values ('dup-ws', 0, 'Dup', '/dup');
        \\insert into workspaces (workspace_id, sort_index, label, path) values ('ctrl-ws', 1, 'Control', '/ctrl');
    );
    // Three threads with the same local_thread_id under the same workspace FK.
    try conn.execNoArgs(
        \\insert into threads (workspace_id, sort_index, title, local_thread_id, provider, harness)
        \\values ((select id from workspaces where workspace_id = 'dup-ws'), 0, 'Oldest', 'shared-thread', 0, 0);
        \\insert into messages (thread_id, sort_index, role, author, body)
        \\values ((select id from threads where title = 'Oldest'), 0, 0, 'You', 'oldest body');
        \\insert into threads (workspace_id, sort_index, title, local_thread_id, provider, harness)
        \\values ((select id from workspaces where workspace_id = 'dup-ws'), 1, 'Middle', 'shared-thread', 0, 0);
        \\insert into messages (thread_id, sort_index, role, author, body)
        \\values ((select id from threads where title = 'Middle'), 0, 0, 'You', 'middle body');
        \\insert into threads (workspace_id, sort_index, title, local_thread_id, provider, harness)
        \\values ((select id from workspaces where workspace_id = 'dup-ws'), 2, 'Newest', 'shared-thread', 0, 0);
        \\insert into messages (thread_id, sort_index, role, author, body)
        \\values ((select id from threads where title = 'Newest'), 0, 0, 'You', 'newest body');
        \\insert into messages (thread_id, sort_index, role, author, body)
        \\values ((select id from threads where title = 'Newest'), 1, 2, 'assistant', 'newest reply');
        \\insert into threads (workspace_id, sort_index, title, local_thread_id, provider, harness)
        \\values ((select id from workspaces where workspace_id = 'ctrl-ws'), 0, 'ControlOnly', 'unique-thread', 0, 0);
        \\insert into messages (thread_id, sort_index, role, author, body)
        \\values ((select id from threads where title = 'ControlOnly'), 0, 0, 'You', 'control body');
    );

    var before_threads = (try conn.row(
        "select count(*) from threads where local_thread_id = 'shared-thread'",
        .{},
    )).?;
    defer before_threads.deinit();
    try std.testing.expectEqual(@as(i64, 3), before_threads.int(0));

    try migrateToVersion(conn, 2, .none);
    try std.testing.expectEqual(@as(i64, 2), try userVersion(conn));

    var after_threads = (try conn.row(
        "select count(*) from threads where local_thread_id = 'shared-thread'",
        .{},
    )).?;
    defer after_threads.deinit();
    try std.testing.expectEqual(@as(i64, 1), after_threads.int(0));

    var survivor = (try conn.row(
        "select title from threads where local_thread_id = 'shared-thread'",
        .{},
    )).?;
    defer survivor.deinit();
    // MAX(rowid) survivor is the freshest re-insert ("Newest").
    try std.testing.expectEqualStrings("Newest", survivor.text(0));

    var msg_count = (try conn.row(
        \\select count(*) from messages where thread_id = (
        \\  select id from threads where local_thread_id = 'shared-thread'
        \\)
    , .{})).?;
    defer msg_count.deinit();
    try std.testing.expectEqual(@as(i64, 2), msg_count.int(0));

    var newest_body = (try conn.row(
        \\select body from messages where thread_id = (
        \\  select id from threads where local_thread_id = 'shared-thread'
        \\) order by sort_index limit 1
    , .{})).?;
    defer newest_body.deinit();
    try std.testing.expectEqualStrings("newest body", newest_body.text(0));

    // NEW-3: non-duplicate control thread + message must survive (no-loss-beyond-dupes).
    var control = (try conn.row(
        "select title from threads where local_thread_id = 'unique-thread'",
        .{},
    )).?;
    defer control.deinit();
    try std.testing.expectEqualStrings("ControlOnly", control.text(0));
    var control_msg = (try conn.row(
        \\select body from messages where thread_id = (
        \\  select id from threads where local_thread_id = 'unique-thread'
        \\)
    , .{})).?;
    defer control_msg.deinit();
    try std.testing.expectEqualStrings("control body", control_msg.text(0));
    var total_threads = (try conn.row("select count(*) from threads", .{})).?;
    defer total_threads.deinit();
    try std.testing.expectEqual(@as(i64, 2), total_threads.int(0));

    // NEW-3: re-execute the dedupe SQL directly (version gate would no-op).
    try conn.execNoArgs(
        \\delete from messages where thread_id in (
        \\  select t.id from threads t
        \\  where t.local_thread_id is not null
        \\    and exists (
        \\      select 1 from threads t2
        \\      where t2.workspace_id = t.workspace_id
        \\        and t2.local_thread_id = t.local_thread_id
        \\        and t2.id > t.id
        \\    )
        \\);
        \\delete from threads where id in (
        \\  select t.id from threads t
        \\  where t.local_thread_id is not null
        \\    and exists (
        \\      select 1 from threads t2
        \\      where t2.workspace_id = t.workspace_id
        \\        and t2.local_thread_id = t.local_thread_id
        \\        and t2.id > t.id
        \\    )
        \\);
    );
    var after_sql_rerun = (try conn.row(
        "select count(*) from threads where local_thread_id = 'shared-thread'",
        .{},
    )).?;
    defer after_sql_rerun.deinit();
    try std.testing.expectEqual(@as(i64, 1), after_sql_rerun.int(0));
    var msg_sql_rerun = (try conn.row(
        \\select count(*) from messages where thread_id = (
        \\  select id from threads where local_thread_id = 'shared-thread'
        \\)
    , .{})).?;
    defer msg_sql_rerun.deinit();
    try std.testing.expectEqual(@as(i64, 2), msg_sql_rerun.int(0));
    var control_after = (try conn.row(
        "select count(*) from threads where local_thread_id = 'unique-thread'",
        .{},
    )).?;
    defer control_after.deinit();
    try std.testing.expectEqual(@as(i64, 1), control_after.int(0));

    // Version-gated re-run remains a no-op at v2.
    try migrateToVersion(conn, 2, .none);
    var after_rerun = (try conn.row(
        "select count(*) from threads where local_thread_id = 'shared-thread'",
        .{},
    )).?;
    defer after_rerun.deinit();
    try std.testing.expectEqual(@as(i64, 1), after_rerun.int(0));
    var msg_rerun = (try conn.row(
        \\select count(*) from messages where thread_id = (
        \\  select id from threads where local_thread_id = 'shared-thread'
        \\)
    , .{})).?;
    defer msg_rerun.deinit();
    try std.testing.expectEqual(@as(i64, 2), msg_rerun.int(0));
}
