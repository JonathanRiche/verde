//! Wire DTOs for the daemon-owned M3 state store.
//!
//! This module deliberately contains only JSON-safe protocol data.  It does
//! not import the desktop state model or the SQLite implementation.

const std = @import("std");
const protocol = @import("protocol.zig");
// The composite snapshot references the volatile registry DTOs directly so
// the envelope has exactly one wire definition (m5_design §2 module-edge choice).
const registry_protocol = @import("registry_protocol.zig");

// Stable storage method names.  These are wire identifiers, not dispatcher
// implementation names, and must not be changed after publication.
pub const METHOD_STATE_SNAPSHOT_REPLACE: []const u8 = "state.snapshot.replace";
pub const METHOD_APP_STATE_SET: []const u8 = "state.app.set";
pub const METHOD_WORKSPACE_UPSERT: []const u8 = "workspace.upsert";
pub const METHOD_CHAT_THREAD_UPSERT: []const u8 = "chat.thread.upsert";
pub const METHOD_CHAT_THREAD_ARCHIVE_SET: []const u8 = "chat.thread.archive.set";
pub const METHOD_CHAT_THREAD_CLOSE: []const u8 = "chat.thread.close";
pub const METHOD_CHAT_THREAD_MOVE: []const u8 = "chat.thread.move";
pub const METHOD_CHAT_DRAFT_SET: []const u8 = "chat.draft.set";
pub const METHOD_CHAT_MESSAGE_APPEND: []const u8 = "chat.message.append";
pub const METHOD_SURFACE_UPSERT: []const u8 = "surface.upsert";
pub const METHOD_SURFACE_CLEAR: []const u8 = "surface.clear";
pub const METHOD_SURFACE_COMPLETION_OBSERVE: []const u8 = "surface.completion.observe";
pub const METHOD_SURFACE_COMMIT_PROOF_CLASSIFY: []const u8 = "surface.commitProof.classify";
pub const METHOD_NOTIFICATION_CHAT_COMPLETION_UPSERT: []const u8 =
    "notification.chatCompletion.upsert";
pub const METHOD_NOTIFICATION_CHAT_COMPLETION_CLEAR: []const u8 =
    "notification.chatCompletion.clear";
pub const METHOD_CORE_SNAPSHOT: []const u8 = "core.snapshot";
pub const METHOD_DAEMON_STORE_STATUS: []const u8 = "daemon.storeStatus";
pub const METHOD_CHAT_THREAD_GET: []const u8 = "chat.thread.get";
pub const METHOD_CHAT_THREAD_LIST: []const u8 = "chat.thread.list";
pub const METHOD_WORKSPACE_LIST: []const u8 = "workspace.list";
pub const METHOD_WORKSPACE_REPOSITORY_MANIFEST_GET: []const u8 =
    "workspace.repository.manifest.get";
/// Read-only composer `@` mention search inside a daemon-resolved repository
/// route. Clients send `{workspace_id, repository_id?, relative_cwd?, query,
/// limit?}`; results are root-relative paths only.
pub const METHOD_WORKSPACE_FILES_SEARCH: []const u8 = "workspace.files.search";
pub const METHOD_BROWSER_COOKIE_SOURCES_LIST: []const u8 = "browser.cookies.sources.list";
pub const METHOD_BROWSER_COOKIE_DOMAINS_LIST: []const u8 = "browser.cookies.domains.list";
pub const METHOD_BROWSER_COOKIE_EXPORT: []const u8 = "browser.cookies.export";
pub const METHOD_WORKSPACE_REPOSITORY_UPSERT: []const u8 =
    "workspace.repository.upsert";
pub const METHOD_WORKSPACE_REPOSITORY_REMOVE: []const u8 =
    "workspace.repository.remove";
pub const METHOD_WORKSPACE_REPOSITORY_DEFAULT_SET: []const u8 =
    "workspace.repository.default.set";
pub const METHOD_WORKSPACE_REPOSITORY_BINDING_UPSERT: []const u8 =
    "workspace.repository.binding.upsert";
pub const METHOD_WORKSPACE_REPOSITORY_BINDING_REMOVE: []const u8 =
    "workspace.repository.binding.remove";
/// Validate a folder on this runtime and make it a workspace's checkout in one
/// idempotent call (see docs/multi-machine-workspaces.md). Reuses a workspace
/// that already owns the folder by recording the caller's ID as its alias.
pub const METHOD_WORKSPACE_ATTACH: []const u8 = "workspace.attach";
/// Sidebar order: listed workspaces lead in the given order; unlisted rows
/// (closed workspaces, rows the caller has not seen) keep their relative order after them.
pub const METHOD_WORKSPACE_REORDER: []const u8 = "workspace.reorder";
pub const METHOD_CHAT_MESSAGE_LIST: []const u8 = "chat.message.list";
pub const METHOD_CHAT_TURN_RECORD: []const u8 = "chat.turn.record";
/// Composer shell mode (`!command`): run one bounded command in the chat's
/// daemon-resolved working directory and record it in the transcript.
pub const METHOD_CHAT_SHELL_RUN: []const u8 = "chat.shell.run";
/// Returned by `chat.shell.run` when the command needs `confirmed: true`.
pub const ERR_SHELL_CONFIRMATION_REQUIRED: []const u8 = "confirmation_required";
pub const METHOD_CONFIG_FAVORITE_MODEL_SET: []const u8 = "config.favoriteModel.set";
pub const METHOD_CONFIG_UI_SET: []const u8 = "config.ui.set";
/// Durable browsing history behind address-bar suggestions. `record` counts
/// a user-driven page load (`visit: false` only refreshes the title); `query`
/// returns frecency-ranked matches; `clear` wipes the table.
pub const METHOD_BROWSER_HISTORY_RECORD: []const u8 = "browser.history.record";
pub const METHOD_BROWSER_HISTORY_QUERY: []const u8 = "browser.history.query";
pub const METHOD_BROWSER_HISTORY_CLEAR: []const u8 = "browser.history.clear";

pub const STATE_SNAPSHOT_REPLACE_METHOD = METHOD_STATE_SNAPSHOT_REPLACE;
pub const APP_STATE_SET_METHOD = METHOD_APP_STATE_SET;
pub const WORKSPACE_UPSERT_METHOD = METHOD_WORKSPACE_UPSERT;
pub const CHAT_THREAD_UPSERT_METHOD = METHOD_CHAT_THREAD_UPSERT;
pub const CHAT_DRAFT_SET_METHOD = METHOD_CHAT_DRAFT_SET;
pub const CHAT_MESSAGE_APPEND_METHOD = METHOD_CHAT_MESSAGE_APPEND;
pub const SURFACE_UPSERT_METHOD = METHOD_SURFACE_UPSERT;
pub const SURFACE_CLEAR_METHOD = METHOD_SURFACE_CLEAR;
pub const NOTIFICATION_CHAT_COMPLETION_UPSERT_METHOD = METHOD_NOTIFICATION_CHAT_COMPLETION_UPSERT;
pub const NOTIFICATION_CHAT_COMPLETION_CLEAR_METHOD = METHOD_NOTIFICATION_CHAT_COMPLETION_CLEAR;
pub const CORE_SNAPSHOT_METHOD = METHOD_CORE_SNAPSHOT;
pub const DAEMON_STORE_STATUS_METHOD = METHOD_DAEMON_STORE_STATUS;
pub const CHAT_THREAD_GET_METHOD = METHOD_CHAT_THREAD_GET;
pub const CHAT_THREAD_LIST_METHOD = METHOD_CHAT_THREAD_LIST;
pub const WORKSPACE_LIST_METHOD = METHOD_WORKSPACE_LIST;
pub const WORKSPACE_REPOSITORY_MANIFEST_GET_METHOD = METHOD_WORKSPACE_REPOSITORY_MANIFEST_GET;
pub const WORKSPACE_REPOSITORY_UPSERT_METHOD = METHOD_WORKSPACE_REPOSITORY_UPSERT;
pub const WORKSPACE_REPOSITORY_REMOVE_METHOD = METHOD_WORKSPACE_REPOSITORY_REMOVE;
pub const WORKSPACE_REPOSITORY_DEFAULT_SET_METHOD = METHOD_WORKSPACE_REPOSITORY_DEFAULT_SET;
pub const WORKSPACE_REPOSITORY_BINDING_UPSERT_METHOD = METHOD_WORKSPACE_REPOSITORY_BINDING_UPSERT;
pub const WORKSPACE_REPOSITORY_BINDING_REMOVE_METHOD = METHOD_WORKSPACE_REPOSITORY_BINDING_REMOVE;
pub const CHAT_MESSAGE_LIST_METHOD = METHOD_CHAT_MESSAGE_LIST;
pub const CHAT_TURN_RECORD_METHOD = METHOD_CHAT_TURN_RECORD;
pub const CONFIG_FAVORITE_MODEL_SET_METHOD = METHOD_CONFIG_FAVORITE_MODEL_SET;
pub const CONFIG_UI_SET_METHOD = METHOD_CONFIG_UI_SET;

// Re-export the shared storage error names from the one protocol error owner.
pub const ERR_CONFLICT = protocol.ERR_CONFLICT;
pub const ERR_INVALID_PARAMS = protocol.ERR_INVALID_PARAMS;
pub const ERR_RESOURCE_NOT_FOUND = protocol.ERR_RESOURCE_NOT_FOUND;
pub const ERR_INVALID_STATE = protocol.ERR_INVALID_STATE;
pub const ERR_CAPABILITY_UNAVAILABLE = protocol.ERR_CAPABILITY_UNAVAILABLE;
pub const ERR_INTERNAL = protocol.ERR_INTERNAL;
pub const ERR_STORE_BUSY = protocol.ERR_STORE_BUSY;
pub const ERR_SCHEMA_TOO_NEW = protocol.ERR_SCHEMA_TOO_NEW;
pub const ERR_STORE_CORRUPT = protocol.ERR_STORE_CORRUPT;
pub const ERR_STORE_UNAVAILABLE = protocol.ERR_STORE_UNAVAILABLE;
pub const ERR_REVISION_EXPIRED = protocol.ERR_REVISION_EXPIRED;

pub const DEFAULT_PAGE_ITEMS: u32 = 100;
pub const MAX_PAGE_ITEMS: u32 = 200;
pub const MAX_PAGE_CURSOR_BYTES: usize = @import("pagination.zig").MAX_CURSOR_BYTES;

/// Stable provider failure codes persisted with terminal turn outcomes.
pub const ProviderFailureReason = enum {
    provider_unavailable,
    provider_not_authenticated,
};
pub const PRIMARY_REPOSITORY_ID: []const u8 = "primary";

/// Common metadata carried by every store mutation.
pub const MutationHeader = struct {
    /// Stable retry identity for the logical mutation.  This is not the RPC id.
    request_key: []const u8,
    /// Optimistic-concurrency guard for the durable store revision.
    expected_store_revision: ?u64 = null,
    /// Opaque ID issued by daemon.client.register.
    client_id: []const u8,
};

/// Receipt returned after a store mutation commits, or after a recognized retry.
pub const WriteResult = struct {
    store_revision: u64,
    applied: bool,
    duplicate: bool = false,
};

/// A daemon-hosted file or a future remote-safe attachment reference.
pub const Attachment = struct {
    path: []const u8,
    mime: []const u8,
    byte_size: usize = 0,
    attachment_id: ?[]const u8 = null,
};

/// Compatibility metadata for a workspace's durable Herdr link.
pub const HerdrWorkspaceLink = struct {
    remote_alias: []const u8 = "",
    session_name: []const u8,
    workspace_id: []const u8,
    local_dir: []const u8,
    remote_cwd: ?[]const u8 = null,
    last_pane_id: ?[]const u8 = null,
    attach_dock_id: ?u32 = null,
    attach_pane_id: ?u32 = null,
    pane_links_json: ?[]const u8 = null,
    updated_at_ms: i64 = 0,
};

/// One runtime-local checkout for a stable workspace repository identity.
pub const RepositoryBinding = struct {
    runtime_id: []const u8,
    root_path: []const u8,
    availability: []const u8 = "available",
};

/// Repository identity is workspace-scoped and never derived from a checkout path.
pub const Repository = struct {
    repository_id: []const u8,
    label: []const u8,
    vcs_identity: ?[]const u8 = null,
    default_branch: ?[]const u8 = null,
    bindings: []const RepositoryBinding = &.{},
};

/// Stable repository metadata without runtime-local checkout bindings.
pub const RepositoryDefinition = struct {
    repository_id: []const u8,
    label: []const u8,
    vcs_identity: ?[]const u8 = null,
    default_branch: ?[]const u8 = null,
};

/// Bounded read of one workspace's complete repository manifest.
pub const WorkspaceRepositoryManifestRequest = struct {
    workspace_id: []const u8,
};

pub const WorkspaceRepositoryManifestResult = struct {
    workspace_id: []const u8,
    default_repository_id: []const u8,
    repositories: []const Repository = &.{},
    store_revision: u64,
};

/// `workspace.attach` params. `role` is `primary` (the workspace's own folder;
/// `repository_id` must be `primary`) or `context` (an extra repository of an
/// existing workspace). `root_path` is absolute on the target runtime.
/// `expect_identity` is a raw or normalized remote URL compared by normalized
/// `v1:` key against the folder's `origin`.
pub const WorkspaceAttachRequest = struct {
    mutation: MutationHeader,
    workspace_id: []const u8,
    label: []const u8,
    repository_id: []const u8 = PRIMARY_REPOSITORY_ID,
    role: []const u8 = WORKSPACE_ATTACH_ROLE_PRIMARY,
    root_path: []const u8,
    expect_identity: ?[]const u8 = null,
};

pub const WORKSPACE_ATTACH_ROLE_PRIMARY: []const u8 = "primary";
pub const WORKSPACE_ATTACH_ROLE_CONTEXT: []const u8 = "context";

/// `workspace_id` is the workspace that now owns the folder: the caller's ID,
/// or, when `reused`, the existing workspace the caller's ID is an alias of.
/// `root_path` is the canonical folder path; `git_identity` its raw `origin`.
pub const WorkspaceAttachResult = struct {
    workspace_id: []const u8,
    repository_id: []const u8,
    root_path: []const u8,
    git_identity: ?[]const u8 = null,
    store_revision: u64,
    reused: bool,
};

pub const WorkspaceReorderRequest = struct {
    mutation: MutationHeader,
    workspace_ids: []const []const u8,
};

pub const WorkspaceRepositoryUpsertRequest = struct {
    mutation: MutationHeader,
    workspace_id: []const u8,
    repository: RepositoryDefinition,
};

pub const WorkspaceRepositoryRemoveRequest = struct {
    mutation: MutationHeader,
    workspace_id: []const u8,
    repository_id: []const u8,
};

pub const WorkspaceDefaultRepositorySetRequest = struct {
    mutation: MutationHeader,
    workspace_id: []const u8,
    repository_id: []const u8,
};

pub const WorkspaceRepositoryBindingUpsertRequest = struct {
    mutation: MutationHeader,
    workspace_id: []const u8,
    repository_id: []const u8,
    binding: RepositoryBinding,
};

pub const WorkspaceRepositoryBindingRemoveRequest = struct {
    mutation: MutationHeader,
    workspace_id: []const u8,
    repository_id: []const u8,
    runtime_id: []const u8,
};

/// Durable workspace metadata plus compatibility presentation fields.
pub const Workspace = struct {
    workspace_id: []const u8,
    label: []const u8,
    path: []const u8,
    /// Additive multi-repository manifest. Empty means a legacy one-path
    /// workspace and projects as the stable `primary` repository.
    repositories: []const Repository = &.{},
    default_repository_id: ?[]const u8 = null,
    /// Other workspace IDs that resolve to this workspace on this runtime
    /// (`workspace.attach` reuse). Daemon-filled on reads; ignored on writes.
    aliases: []const []const u8 = &.{},
    archived: bool = false,
    unread_count: u32 = 0,
    collapsed: ?bool = null,
    thread_list_expanded: ?bool = null,
    terminal_height: ?f32 = null,
    terminal_layout_json: ?[]const u8 = null,
    terminal_docks_json: ?[]const u8 = null,
    workspace_layout_json: ?[]const u8 = null,
    /// Client-scoped compatibility state retained while snapshot replacement exists.
    selected_thread_index: usize = 0,
    companion_thread_local_id: ?[]const u8 = null,
    herdr_link: ?HerdrWorkspaceLink = null,
    /// User-chosen identity overrides; null derives from the workspace id.
    icon_index: ?u8 = null,
    color_index: ?u8 = null,
    provider: []const u8 = "opencode",
    harness: []const u8 = "local_cli",
    draft: []const u8 = "",
    threads: []const Thread = &.{},
    messages: []const Message = &.{},
};

/// A durable transcript row.  Role/provider/tool values remain strings so new
/// daemon variants can pass through older clients.
pub const Message = struct {
    /// Stable position inside the owning thread. Older snapshot clients may
    /// omit it; paginated transcript responses always populate it.
    sort_index: usize = 0,
    /// Legacy snapshot rows may omit this field; chat.message.append must
    /// reject an empty message ID with invalid_params.
    message_id: []const u8 = "",
    role: []const u8,
    author: []const u8,
    body: []const u8,
    images: []const Attachment = &.{},
    /// Legacy single-image compatibility field used by the pre-M3 snapshot.
    image: ?Attachment = null,
    tool_call_id: ?[]const u8 = null,
    tool_call_kind: ?[]const u8 = null,
    tool_call_status: ?[]const u8 = null,
    created_at_ms: ?i64 = null,
    updated_at_ms: ?i64 = null,
};

/// Thread activity is Unix seconds. Older CLI clients wrote milliseconds;
/// normalize those values before comparing or displaying persisted activity.
pub fn threadActivitySeconds(timestamp: ?i64) ?i64 {
    const value = timestamp orelse return null;
    return if (value >= 1_000_000_000_000) @divTrunc(value, std.time.ms_per_s) else value;
}

test "thread activity normalizes legacy milliseconds without changing seconds or missing values" {
    try std.testing.expectEqual(@as(?i64, null), threadActivitySeconds(null));
    try std.testing.expectEqual(@as(?i64, 0), threadActivitySeconds(0));
    try std.testing.expectEqual(@as(?i64, 1_790_000_000), threadActivitySeconds(1_790_000_000));
    try std.testing.expectEqual(@as(?i64, 1_700_000_000), threadActivitySeconds(1_700_000_000_999));
    try std.testing.expect(threadActivitySeconds(1_700_000_000_999).? < threadActivitySeconds(1_790_000_000).?);
}

/// Thread metadata keyed by (workspace_id, local_thread_id).
pub const Thread = struct {
    local_thread_id: []const u8,
    title: []const u8,
    archived: bool = false,
    committed: bool = true,
    /// Unix seconds since the last chat activity.
    last_activity_at: ?i64 = null,
    provider_thread_id: ?[]const u8 = null,
    model_ref: ?[]const u8 = null,
    reasoning_effort: ?[]const u8 = null,
    reasoning_variant: ?[]const u8 = null,
    fast_mode: ?[]const u8 = null,
    access_mode: ?[]const u8 = null,
    provider: []const u8 = "opencode",
    harness: []const u8 = "local_cli",
    tui_dock_id: ?u32 = null,
    /// Per-thread working-directory override. Null means the thread follows
    /// its workspace path; "projectless" chats point at home or scratch.
    cwd: ?[]const u8 = null,
    /// Desktop connection-profile identity. Null decodes as the Local profile.
    profile_id: ?[]const u8 = null,
    /// Stable identity returned by the selected daemon handshake. It remains
    /// null for legacy committed threads until they are verified again.
    runtime_id: ?[]const u8 = null,
    /// Stable repository binding for new clients. Null is the legacy primary repository.
    repository_id: ?[]const u8 = null,
    /// Runtime-independent directory beneath the selected repository root.
    repository_cwd: ?[]const u8 = null,
    draft: []const u8 = "",
    draft_image: ?Attachment = null,
    draft_images: []const Attachment = &.{},
    /// Durable sort-index boundary before this bounded tail.
    message_offset: usize = 0,
    messages: []const Message = &.{},
};

/// Durable state for one terminal surface.
pub const SurfaceState = struct {
    session_id: []const u8,
    workspace_id: []const u8 = "",
    workspace_path: []const u8 = "",
    dock_id: u32 = 0,
    pane_id: ?u32 = null,
    provider: ?[]const u8 = null,
    provider_thread_id: ?[]const u8 = null,
    title: []const u8 = "",
    status: []const u8 = "idle",
    status_changed_at_ms: i64 = 0,
    completed_at_ms: i64 = 0,
    last_event_title: ?[]const u8 = null,
    last_event_body: ?[]const u8 = null,
};

/// Legacy completion notification ledger row.
pub const ChatCompletion = struct {
    workspace_id: []const u8,
    local_thread_id: []const u8,
    completed_at_ms: i64,
};

/// Compatibility snapshot transported through state.snapshot.replace.
pub const Snapshot = struct {
    schema_version: u32 = 1,
    store_revision: u64 = 0,
    selected_workspace_index: usize = 0,
    sidebar_collapsed: bool = false,
    workspaces: []const Workspace = &.{},
    surface_states: []const SurfaceState = &.{},
    chat_completions: []const ChatCompletion = &.{},
    provider: ?[]const u8 = null,
    harness: ?[]const u8 = null,
    draft: ?[]const u8 = null,
    messages: ?[]const Message = null,
    /// Threads the client closed since its last acknowledged replace. They
    /// flip cold in the same transaction that persists the layout which no
    /// longer references them, so no reader can observe a layout ordinal that
    /// points past the open thread array. A carried thread is never closed.
    closed_threads: []const ClosedThreadRef = &.{},
};

pub const ClosedThreadRef = struct {
    workspace_id: []const u8,
    local_thread_id: []const u8,
};

/// Request for the transitional whole-state replacement.
pub const SnapshotReplaceRequest = struct {
    mutation: MutationHeader,
    snapshot: Snapshot,
    /// Only bootstrap may omit the expected revision guard.
    bootstrap: bool = false,
};

/// Targeted shell-selection mutation. Routine selection/sidebar changes must
/// not require reconciling every workspace and thread.
pub const AppStateSetRequest = struct {
    mutation: MutationHeader,
    selected_workspace_index: usize,
    sidebar_collapsed: bool,
};

pub const WorkspaceUpsertRequest = struct {
    mutation: MutationHeader,
    workspace: Workspace,
};

pub const ThreadUpsertRequest = struct {
    mutation: MutationHeader,
    workspace_id: []const u8,
    thread: Thread,
};

/// Change only archive/open state, preserving transcript and composer metadata.
pub const ThreadArchiveSetRequest = struct {
    mutation: MutationHeader,
    workspace_id: []const u8,
    local_thread_id: []const u8,
    archived: bool,
};

/// Close one thread: it leaves the composite snapshot and the durable
/// refresh stream until a later `state.snapshot.replace` / `chat.thread.upsert`
/// carries it again (which reopens it). The row itself is untouched otherwise.
pub const ThreadCloseRequest = struct {
    mutation: MutationHeader,
    workspace_id: []const u8,
    local_thread_id: []const u8,
};

/// Reassign one idle thread, with its transcript and turn/link records, to
/// another workspace. The thread lands open at the end of the target's open
/// set; `cwd` replaces its working-directory override so a provider session
/// stays pinned to the directory it started in (null keeps the stored value).
pub const ThreadMoveRequest = struct {
    mutation: MutationHeader,
    workspace_id: []const u8,
    local_thread_id: []const u8,
    target_workspace_id: []const u8,
    cwd: ?[]const u8 = null,
};

/// Atomically replace or append one thread's composer draft.
pub const ChatDraftSetRequest = struct {
    mutation: MutationHeader,
    workspace_id: []const u8,
    local_thread_id: []const u8,
    text: []const u8,
    append: bool = false,
};

pub const MessageAppendRequest = struct {
    mutation: MutationHeader,
    workspace_id: []const u8,
    thread_id: []const u8,
    message: Message,
};

pub const SurfaceUpsertRequest = struct {
    mutation: MutationHeader,
    surface: SurfaceState,
};

pub const SurfaceClearRequest = struct {
    mutation: MutationHeader,
    session_id: []const u8,
    workspace_id: ?[]const u8 = null,
};

pub const SurfaceCompletionObserveRequest = struct {
    surface: SurfaceState,
};

pub const SurfaceCompletionObserveResult = struct {
    store_revision: u64,
    matches: bool,
};

pub const SurfaceCommitProofClassifyRequest = struct {
    request_key: []const u8,
    operation: []const u8,
    fingerprint: []const u8,
    store_revision: u64,
    surface: ?SurfaceState = null,
    cleared_session_id: ?[]const u8 = null,
};

pub const SurfaceCommitProofClassifyResult = struct {
    classification: []const u8,
};

pub const NotificationChatCompletionUpsertRequest = struct {
    mutation: MutationHeader,
    completion: ChatCompletion,
};

pub const NotificationChatCompletionClearRequest = struct {
    mutation: MutationHeader,
    workspace_id: []const u8,
    local_thread_id: []const u8,
    /// When present, only clears this completion or an older one. This keeps
    /// a delayed acknowledgement from consuming a later turn on the thread.
    completed_at_ms: ?i64 = null,
};

// Frozen scope names for the M5 composite core.snapshot request.  An absent
// scopes field means store-only, preserving the M3 shape.
pub const SNAPSHOT_SCOPE_STORE: []const u8 = "store";
pub const SNAPSHOT_SCOPE_REGISTRY: []const u8 = "registry";
pub const SNAPSHOT_SCOPE_SESSIONS: []const u8 = "sessions";
pub const SNAPSHOT_SCOPE_TURNS: []const u8 = "turns";
/// Workspace rows only (labels, paths, persisted layout JSON) with no
/// threads or messages, so detached UIs can read open-pane layout without
/// tripping the transport cap the full `store` scope hits.
pub const SNAPSHOT_SCOPE_WORKSPACES: []const u8 = "workspaces";
/// User `verde.json` settings that every daemon client should honor, starting
/// with workspace strip geometry (`ui.workspace_panes_per_view` and friends).
pub const SNAPSHOT_SCOPE_CONFIG: []const u8 = "config";

/// Optional filters for a coherent daemon snapshot read.
pub const CoreSnapshotRequest = struct {
    workspace_id: ?[]const u8 = null,
    after_store_revision: ?u64 = null,
    /// M5 additive scope selection (SNAPSHOT_SCOPE_* names).  Null keeps the
    /// M3 store-only behavior so old clients never change meaning.
    scopes: ?[]const []const u8 = null,
};

/// Volatile terminal-session summary for the composite snapshot's `sessions`
/// scope.  Field names mirror the established session.list summary wire names.
pub const SessionSummary = struct {
    session_id: []const u8 = "",
    workspace_id: []const u8 = "",
    workspace_path: []const u8 = "",
    cwd: []const u8 = "",
    label: []const u8 = "",
    command: []const u8 = "",
    dock_id: ?u32 = null,
    pane_id: ?u32 = null,
    pid: ?i64 = null,
    running: bool = false,
    status: []const u8 = "",
    exit_status: ?i64 = null,
};

/// Workspace-layout slice of `verde.json` `ui`. Detached clients size the
/// scrolling strip from these values instead of local defaults.
pub const ConfigUiSnapshot = struct {
    workspace_pane_gap: f32 = 12.0,
    workspace_panes_per_view: u8 = 1,
    workspace_split_default_pane: []const u8 = "chat",
    workspace_scroll_direction: []const u8 = "horizontal",
    workspace_scroll_mode: []const u8 = "automatic",
    workspace_scroll_threshold: u8 = 3,
    unzoom_on_pane_navigation: bool = false,
    /// True only when every motion area is reduced (legacy readers).
    reduced_motion: bool = false,
    reduced_motion_parts: ConfigReducedMotionParts = .{},
};

/// Per-area `ui.reduced_motion_parts`; defaults match desktop `ReducedMotion`.
pub const ConfigReducedMotionParts = struct {
    pane_scroll: bool = true,
    pane_layout: bool = false,
    status_pulse: bool = false,
    chat: bool = false,
    chrome: bool = false,
};

pub const ConfigFavoriteModel = struct {
    provider: []const u8,
    model: []const u8,
};

/// Starting model, reasoning (effort tag or variant) and speed for a new chat
/// on one provider, as the desktop would pick them.
pub const ConfigNewChatDefault = struct {
    provider: []const u8,
    model: []const u8,
    reasoning: ?[]const u8 = null,
    fast: bool = false,
};

pub const ConfigChatSnapshot = struct {
    favorite_models: []const ConfigFavoriteModel = &.{},
    /// Provider a new chat starts on: the last explicit choice, else the
    /// configured default.
    new_chat_provider: []const u8 = "codex",
    /// Providers with a configured or remembered starting model; any other
    /// provider starts on its CLI default.
    new_chat_defaults: []const ConfigNewChatDefault = &.{},
    /// Resolved `chat.title_provider` / `chat.title_model`, so detached
    /// clients regenerate titles with the same model as the desktop.
    title_provider: []const u8 = "codex",
    title_model: []const u8 = "",
    /// `chat.commit_message_provider` (`auto` or a provider).
    commit_message_provider: []const u8 = "auto",
    /// Explicit commit-message model; null uses the provider's fast default.
    commit_message_model: ?[]const u8 = null,
    /// `commit` or `commit_and_push`.
    commit_default_action: []const u8 = "commit",
};

pub const ConfigSnapshot = struct {
    ui: ConfigUiSnapshot = .{},
    chat: ConfigChatSnapshot = .{},
    /// Raw shared keybind config. Detached UIs parse the same accelerator and
    /// prefix contracts as the desktop instead of maintaining local settings.
    keybinds: std.json.Value = .null,
};

/// Idempotently update one model favorite in the shared user config.
pub const ConfigFavoriteModelSetRequest = struct {
    provider: []const u8,
    model: []const u8,
    favorite: bool,
};

pub const ConfigFavoriteModelSetResult = struct {
    provider: []const u8,
    model: []const u8,
    favorite: bool,
};

/// Patch the client-visible `verde.json` `ui` slice. Omitted fields keep
/// their current value; the result is the full slice after the write.
pub const ConfigUiSetRequest = struct {
    workspace_pane_gap: ?f32 = null,
    workspace_panes_per_view: ?u8 = null,
    workspace_split_default_pane: ?[]const u8 = null,
    workspace_scroll_direction: ?[]const u8 = null,
    workspace_scroll_mode: ?[]const u8 = null,
    workspace_scroll_threshold: ?u8 = null,
    unzoom_on_pane_navigation: ?bool = null,
    reduced_motion_parts: ?ConfigReducedMotionPartsPatch = null,
};

pub const ConfigReducedMotionPartsPatch = struct {
    pane_scroll: ?bool = null,
    pane_layout: ?bool = null,
    status_pulse: ?bool = null,
    chat: ?bool = null,
    chrome: ?bool = null,
};

pub const CoreSnapshotResult = struct {
    snapshot: Snapshot,
    store_revision: u64,
    // M5 additive composite sections.  Every default is absent/empty so the
    // M3 store-only result shape decodes unchanged when no scopes were asked.
    /// Volatile revision namespace; present when any volatile scope was read.
    envelope: ?registry_protocol.RegistryRevisionEnvelope = null,
    /// Journal cursor to start core.changes polling from this snapshot.
    change_cursor: ?u64 = null,
    processes: []const registry_protocol.ProcessSnapshot = &.{},
    leases: []const registry_protocol.LeaseRecord = &.{},
    sessions: []const SessionSummary = &.{},
    turns: []const TurnRecord = &.{},
    /// Present when the `config` scope was requested. Null keeps older
    /// composite replies decode-compatible.
    config: ?ConfigSnapshot = null,
    /// Scopes the daemon could not fully serve yet (e.g. chat before the
    /// M4-P4 authority flip).  Honest partial snapshots instead of blocking.
    incomplete_scopes: []const []const u8 = &.{},
};

/// The status request is intentionally empty; the daemon chooses its current
/// queue/drain state rather than trusting client-supplied flags.
pub const StoreStatusRequest = struct {};

pub const StoreStatusResult = struct {
    schema_version: u32 = 0,
    store_revision: u64 = 0,
    writer_ready: bool = false,
    queued_mutation_count: usize = 0,
    drain_state: []const u8 = "open",
};

/// Identifies one durable thread for a direct transcript read.
pub const ThreadGetRequest = struct {
    workspace_id: []const u8,
    local_thread_id: []const u8,
    /// Return at most this many of the earliest messages. Callers that only
    /// need thread settings (and whether any message exists) pass a small
    /// limit so long transcripts stay under the response cap.
    message_limit: ?u32 = null,
};

/// A bounded thread-list row. Messages are deliberately absent from this DTO.
pub const ThreadListItem = struct {
    local_thread_id: []const u8,
    title: []const u8,
    /// Model-generated one-line summary used for search; empty when none.
    description: []const u8 = "",
    /// Owning workspace; filled so cross-workspace history queries resolve.
    workspace_id: []const u8 = "",
    /// Daemon-owned open/closed bit (see `ThreadCloseRequest`).
    open: bool = true,
    /// Stable position in the workspace's thread array. Persisted workspace
    /// layout JSON references chat panes by this index, so detached UIs need
    /// it to resolve open panes to threads.
    sort_index: usize = 0,
    archived: bool = false,
    committed: bool = true,
    /// Unix seconds since the last chat activity.
    last_activity_at: ?i64 = null,
    provider_thread_id: ?[]const u8 = null,
    model_ref: ?[]const u8 = null,
    reasoning_effort: ?[]const u8 = null,
    reasoning_variant: ?[]const u8 = null,
    fast_mode: ?[]const u8 = null,
    access_mode: ?[]const u8 = null,
    provider: []const u8 = "opencode",
    harness: []const u8 = "local_cli",
    cwd: ?[]const u8 = null,
    profile_id: ?[]const u8 = null,
    runtime_id: ?[]const u8 = null,
    repository_id: ?[]const u8 = null,
    repository_cwd: ?[]const u8 = null,
};

/// One durable thread and the revision from which it was read.
pub const ThreadGetResult = struct {
    thread: Thread,
    store_revision: u64,
};

/// Bounded per-workspace thread metadata query. Returned cursors are opaque,
/// revision-bound, and valid only for the same workspace query.
pub const ThreadListRequest = struct {
    /// Empty lists every workspace (history queries).
    workspace_id: []const u8 = "",
    limit: u32 = 100,
    cursor: ?[]const u8 = null,
    /// Null lists open and closed rows; false is the cold-history query.
    open: ?bool = null,
    /// Case-insensitive title/description substring filter; empty matches all.
    query: []const u8 = "",
    /// Order by last activity (newest first) instead of sort_index.
    recent_first: bool = false,
};

/// Bounded per-workspace thread metadata result.
pub const ThreadListResult = struct {
    threads: []const ThreadListItem = &.{},
    next_cursor: ?[]const u8 = null,
    store_revision: u64 = 0,
};

/// Bounded workspace row with an explicit repository manifest projection.
pub const WorkspaceListItem = struct {
    workspace_id: []const u8,
    label: []const u8,
    path: []const u8,
    sort_index: usize = 0,
    archived: bool = false,
    repositories: []const Repository = &.{},
    default_repository_id: []const u8 = PRIMARY_REPOSITORY_ID,
    /// Other workspace IDs that resolve to this workspace (`workspace.attach`).
    aliases: []const []const u8 = &.{},
};

/// Returned cursors are opaque, revision-bound, and valid only with the same
/// `include_archived` filter.
pub const WorkspaceListRequest = struct {
    limit: u32 = DEFAULT_PAGE_ITEMS,
    cursor: ?[]const u8 = null,
    include_archived: bool = false,
};

pub const WorkspaceListResult = struct {
    /// Serving daemon identity; binding roots are local only when this matches.
    runtime_id: []const u8 = "",
    workspaces: []const WorkspaceListItem = &.{},
    next_cursor: ?[]const u8 = null,
    store_revision: u64 = 0,
};

/// `chat.shell.run` params. The working directory uses the same route fields
/// as `chat.turn.start`: `repository_id` (+ optional `relative_cwd`) resolves
/// through this runtime's repository binding; legacy local chats send
/// `project_path`, which must equal the stored workspace path or thread cwd.
pub const ShellRunRequest = struct {
    workspace_id: []const u8,
    local_thread_id: []const u8,
    command: []const u8,
    /// Destructive commands and supervised chats require explicit approval.
    confirmed: bool = false,
    project_path: ?[]const u8 = null,
};

pub const ShellRunResult = struct {
    /// `completed`, `failed`, or `timed_out`.
    status: []const u8,
    exit_code: ?u8 = null,
    cwd: []const u8,
    shell: []const u8,
    duration_ms: i64,
    truncated: bool = false,
    command_message_id: []const u8,
    result_message_id: []const u8,
    store_revision: u64,
};

/// Bidirectional bounded transcript request. A returned cursor is opaque and
/// already encodes its direction; clients must not construct one themselves.
pub const MessageListRequest = struct {
    workspace_id: []const u8,
    local_thread_id: []const u8,
    direction: []const u8 = "backward",
    limit: u32 = DEFAULT_PAGE_ITEMS,
    cursor: ?[]const u8 = null,
    /// Absolute transcript boundary used by GUI projections that already
    /// retain a durable message offset. Opaque cursors take precedence.
    before_offset: ?usize = null,
};

pub const MessageListResult = struct {
    messages: []const Message = &.{},
    next_cursor: ?[]const u8 = null,
    store_revision: u64 = 0,
};

/// Durable summary of one accepted chat turn.
pub const TurnRecord = struct {
    turn_id: []const u8,
    workspace_id: []const u8,
    local_thread_id: []const u8,
    status: []const u8,
    started_at_ms: i64,
    finished_at_ms: ?i64 = null,
    provider: []const u8,
    provider_thread_id: ?[]const u8 = null,
    error_message: ?[]const u8 = null,
    failure_reason: ?ProviderFailureReason = null,
    user_message_id: ?[]const u8 = null,
    committed_store_revision: ?u64 = null,
};

/// Direct lookup request for one durable turn ledger row.
pub const BrowserHistoryRecordRequest = struct {
    url: []const u8,
    title: ?[]const u8 = null,
    visit: bool = true,
};

pub const BrowserHistoryQueryRequest = struct {
    query: []const u8 = "",
    limit: u32 = 8,
};

pub const BrowserHistoryEntry = struct {
    url: []const u8,
    title: []const u8 = "",
    visit_count: u32 = 1,
    last_visit_ms: i64 = 0,
};

pub const BrowserHistoryQueryResult = struct {
    entries: []const BrowserHistoryEntry = &.{},
};

pub const TurnRecordRequest = struct {
    turn_id: []const u8,
};

// Descriptive aliases keep the wire vocabulary usable at call sites without
// introducing duplicate representations.
pub const ImageAttachment = Attachment;
pub const Surface = SurfaceState;
pub const CompletionLedgerEntry = ChatCompletion;
pub const SnapshotQueryRequest = CoreSnapshotRequest;
pub const SnapshotQueryResult = CoreSnapshotResult;

/// Encode any store DTO using the standard JSON object representation.
pub fn encode(allocator: std.mem.Allocator, value: anytype) ![]u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    var stringify: std.json.Stringify = .{ .writer = &writer.writer, .options = .{} };
    try stringify.write(value);
    return try writer.toOwnedSlice();
}

/// Decode a store DTO while ignoring fields introduced by a newer peer.
pub fn decode(comptime T: type, allocator: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(T) {
    return std.json.parseFromSlice(T, allocator, bytes, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
}

/// Decode a store DTO into allocations owned by the caller's arena.
pub fn decodeLeaky(comptime T: type, allocator: std.mem.Allocator, bytes: []const u8) !T {
    return std.json.parseFromSliceLeaky(T, allocator, bytes, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
}

test "decode owns strings after the input buffer is released" {
    const allocator = std.testing.allocator;
    const json =
        "{\"mutation\":{\"request_key\":\"request\",\"client_id\":\"client\"}," ++
        "\"workspace_id\":\"workspace\",\"thread_id\":\"thread\",\"message\":{" ++
        "\"message_id\":\"message\",\"role\":\"user\",\"author\":\"author\",\"body\":\"body\"}}";
    const input = try allocator.dupe(u8, json);
    var input_owned = true;
    defer if (input_owned) allocator.free(input);

    var parsed = try decode(MessageAppendRequest, allocator, input);
    defer parsed.deinit();

    @memset(input, 0xa5);
    allocator.free(input);
    input_owned = false;

    try std.testing.expectEqualStrings("request", parsed.value.mutation.request_key);
    try std.testing.expectEqualStrings("client", parsed.value.mutation.client_id);
    try std.testing.expectEqualStrings("workspace", parsed.value.workspace_id);
    try std.testing.expectEqualStrings("thread", parsed.value.thread_id);
    try std.testing.expectEqualStrings("message", parsed.value.message.message_id);
    try std.testing.expectEqualStrings("user", parsed.value.message.role);
    try std.testing.expectEqualStrings("author", parsed.value.message.author);
    try std.testing.expectEqualStrings("body", parsed.value.message.body);
}
