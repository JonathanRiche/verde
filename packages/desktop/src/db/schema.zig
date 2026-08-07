//! SQLite schema and connection initialization for app persistence.

const std = @import("std");
const zqlite = @import("zqlite");

/// Latest schema version understood by this build.
pub const CURRENT_VERSION: i64 = 1;
/// Maximum schema version understood by read-only clients and the daemon store.
pub const MAX_SUPPORTED_VERSION: i64 = 4;
/// SQLite busy timeout shared by writer and read-only connections.
pub const BUSY_TIMEOUT_MS = 5000;

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
    try conn.execNoArgs("begin immediate");
    errdefer conn.rollback();

    var version = try userVersion(conn);
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
            else => return error.DatabaseSchemaInvalid,
        }
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
