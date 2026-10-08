//! Per-chat git change review and user-initiated commits.
//!
//! The daemon attributes working-tree changes to the chat whose turn made
//! them. Clients show a per-chat summary chip, open a review, and commit the
//! ticked files/hunks. Nothing here ever commits automatically.
//!
//! Clients refresh `git.changes.summary` when a workspace's `chat.turn`
//! journal entries arrive and after their own commits; there is no dedicated
//! journal topic.
//!
//! Methods (paired-device scope in brackets):
//! - `git.changes.summary`        SummaryRequest -> SummaryResult        [repository:read]
//! - `git.changes.status`         StatusRequest -> StatusResult          [repository:read]
//! - `git.changes.review`         ReviewRequest -> ReviewResult          [repository:read]
//! - `git.changes.commit_message` CommitMessageRequest -> CommitMessageResult [repository:read]
//! - `git.changes.commit`         CommitRequest -> CommitResult          [chat:write + repository:read]
//! - `git.changes.push`           PushRequest -> PullPushResult          [chat:write + repository:read]
//! - `git.changes.pull_push`      PullPushRequest -> PullPushResult      [chat:write + repository:read]
//! - `git.changes.workspace`      WorkspaceRequest -> WorkspaceResult    [repository:read]
//! - `git.changes.file_patch`     FilePatchRequest -> FilePatchResult    [repository:read]
//! - `config.commit.set`          ConfigCommitSetRequest -> ConfigCommitSnapshot [owner only, like config.ui.set]
//!
//! Committing and pushing a chat's own changes is a chat action, so the Chat
//! pairing preset (chat:write + repository:read) may do it without general
//! repository:write. The Monitor preset has no chat:write and stays read-only.
//!
//! Reads run with `GIT_OPTIONAL_LOCKS=0` and never fetch. `push` and
//! `pull_push` only accept repositories the workspace already surfaced
//! through claims, `review`, or `status`.
//!
//! ## Workspace changes (`git.changes.workspace`, `git.changes.file_patch`)
//!
//! Client-agnostic read model behind the desktop side panel's Changes view
//! (also meant for the web and mobile clients). Baseline is the working tree
//! against HEAD; untracked files are listed as `added`.
//! - Repository id: `WorkspaceRepo.root`, an opaque string (the repository's
//!   absolute path on the daemon host). Clients echo it back verbatim in
//!   `FilePatchRequest.root`; `WorkspaceRepo.name` is the display name.
//! - File paths are repository-relative, `/`-separated, never `..`.
//! - Ownership is workspace-wide (`unassigned`, `mine` = one confident chat,
//!   `unclear`, `shared`); `owners` names the claiming chats; `title` is never empty
//!   (closed, untitled, and subagent chats read `Chat <last 6 id chars>`).
//! - Bounds: at most `MAX_WORKSPACE_FILES` files per response. A repository
//!   with more dirty paths than the daemon tracks, or that would exceed the
//!   remaining budget, comes back `too_many_files` with no files. Patches over
//!   `MAX_FILE_PATCH_BYTES` come back `truncated` with no text; binary files
//!   come back `binary` with no text.
//! - Patch format: plain git unified diff for one file (`diff --git` header,
//!   `---`/`+++`, `@@` hunks; new files diff from `/dev/null`), not
//!   VERDE_DIFF_V2. `context_lines` is git's `-U` (null: 3, capped at
//!   1_000_000 = whole file), so clients can expand collapsed context by
//!   refetching with a larger value.
//! - Errors: `invalid_params` (malformed request, or a path that is not
//!   repository-relative), `resource_not_found` (`root` is not one of the
//!   workspace's repositories), `capability_unavailable` (git missing or the
//!   repository unreadable). A path that is no longer dirty is not an error:
//!   it comes back `clean`.
//! - Not journaled: refresh on `chat.turn`/`chat.completion` activity, on
//!   open, and after commits, like `git.changes.summary`.
//!
//! ## Committed transcript row
//!
//! After a successful commit the daemon appends one UI-only transcript row to
//! the chat when its thread is idle (`CommitResult.transcript_message_id`
//! names it; null when the chat was busy or the write failed). It is not sent
//! to the chat's own provider as a turn. Chat handoffs in `full` and `recent`
//! context modes do embed system rows (including this one) as text in the new
//! chat's opening prompt; `summary` mode skips them. Exact shape:
//! - `message_id`: `git-commit-<unix_ms>-<nonce>`
//! - `role`: `"system"`, `author`: `"git"`
//! - `body`: `\n`-separated lines; only line 1 is required.
//!   - Line 1 (always, stable; clients may show it verbatim):
//!     `Committed <N> file<s>: <entries>` where N is `CommitResult.files`,
//!     `<s>` is empty when N == 1, and `<entries>` joins one entry per
//!     committed repository with `", "`. Each entry is the 7-character short
//!     sha, then ` (<repo basename>)` only when more than one repository
//!     committed, then ` · pushed` when that repository's push succeeded.
//!   - Line 2 (optional): the subject, i.e. the first line of the committed
//!     message. Positional: present, possibly empty, whenever line 3 follows.
//!   - Line 3 (optional): `branch <name>`, the first repository's branch
//!     (`RepoCommit.branch`); empty on a detached HEAD. Positional: present,
//!     possibly empty, whenever a line 4 follows.
//!   - Lines 4+ (optional): one line per entry, in entry order:
//!     - `remote <url>`: the commit's page on the forge
//!       (`https://<host>/<owner>/<repo>/commit/<full sha>`, derived from
//!       the push remote's URL). Written only for pushed entries, so the
//!       link always resolves.
//!     - `local`: the repository had no remote at all when it committed
//!       (clients show "Local only · no remote" and no Push).
//!     - bare `remote`: no link (not pushed yet, or the remote is not a
//!       recognisable forge).
//!     Trailing bare `remote` lines are omitted (`local` never is), so a row
//!     with no links and no local entries has no line 4.
//!   Rows written before lines 2-4 existed carry fewer lines, and rows
//!   written before `local` existed may carry a `remote <url>` for an
//!   unpushed entry: clients link an entry only when it is marked
//!   ` · pushed`. A missing entry line means "unknown" (treat as has remote).
//!   Examples:
//!   `Committed 3 files: 1a2b3c4 · pushed\nfix: trim input\nbranch main\nremote https://github.com/o/r/commit/1a2b3c4…`,
//!   `Committed 1 file: 1a2b3c4\nwip\nbranch main\nlocal`.
//!
//!   The row is rewritten in place (same `message_id`) when a later push from
//!   the chat (`git.changes.push`, `git.changes.pull_push` or a commit with
//!   `push`) publishes its commit: ` · pushed` is added to that entry, its
//!   `remote <url>` line filled, and any `local` line replaced. Only the
//!   chat's 20 most recent `git` rows are considered, and only while the
//!   chat is idle.

const std = @import("std");

pub const METHOD_SUMMARY: []const u8 = "git.changes.summary";
pub const METHOD_REVIEW: []const u8 = "git.changes.review";
pub const METHOD_COMMIT_MESSAGE: []const u8 = "git.changes.commit_message";
pub const METHOD_COMMIT: []const u8 = "git.changes.commit";
pub const METHOD_PULL_PUSH: []const u8 = "git.changes.pull_push";
/// Plain push of the current branch; sets the upstream when missing.
pub const METHOD_PUSH: []const u8 = "git.changes.push";
/// Branch/upstream facts for a chat's repositories (button labels).
pub const METHOD_STATUS: []const u8 = "git.changes.status";
/// Owner-only write of the `chat.commit_*` keys in verde.json.
pub const METHOD_CONFIG_COMMIT_SET: []const u8 = "config.commit.set";
/// Every uncommitted file across the workspace's repositories (the desktop
/// side panel's Changes view). Read-only; claims are never pruned here.
pub const METHOD_WORKSPACE: []const u8 = "git.changes.workspace";
/// One file's patch against HEAD, fetched lazily per expanded file.
pub const METHOD_FILE_PATCH: []const u8 = "git.changes.file_patch";

/// Returned when a commit's frozen patch no longer applies. Re-open review.
pub const ERR_CHANGED_SINCE_REVIEW: []const u8 = "changed_since_review";
/// Returned when HEAD moved during the commit; nothing was written.
pub const ERR_HEAD_MOVED: []const u8 = "head_moved";
/// Returned for an expired or unknown review id.
pub const ERR_REVIEW_EXPIRED: []const u8 = "review_expired";
/// git has no user.name/user.email for this repository.
pub const ERR_MISSING_IDENTITY: []const u8 = "missing_git_identity";
/// Pull & push refused while chats are running in the repository.
pub const ERR_TURNS_RUNNING: []const u8 = "turns_running";
/// A requested new branch could not be created; nothing was committed.
pub const ERR_BRANCH_CREATE_FAILED: []const u8 = "branch_create_failed";
/// The same review is being committed (or the same push `request_id` is
/// running) by another request. Retry after it finishes to get its result.
pub const ERR_IN_PROGRESS: []const u8 = "in_progress";

/// `feature/<slug>` names are sanitized to `[a-z0-9/-]`, at most this many
/// bytes after the prefix; the fallback name is `feature/update`.
pub const BRANCH_PREFIX: []const u8 = "feature/";
pub const BRANCH_FALLBACK: []const u8 = "feature/update";
pub const MAX_BRANCH_SLUG_BYTES: usize = 64;

/// Default and maximum total hunk text in one `git.changes.review` response.
pub const DEFAULT_REVIEW_HUNK_BUDGET_BYTES: u64 = 512 * 1024;
pub const MAX_REVIEW_HUNK_BUDGET_BYTES: u64 = 3 * 1024 * 1024;

pub const SummaryRequest = struct {
    workspace_id: []const u8,
};

pub const ThreadSummary = struct {
    local_thread_id: []const u8,
    files: u32,
    additions: u32,
    deletions: u32,
    /// Files shared with another chat or with an unclear owner.
    attention: u32,
};

pub const SummaryResult = struct {
    workspace_id: []const u8,
    /// Bumps whenever attribution changes; equal revisions mean equal data.
    revision: u64,
    threads: []const ThreadSummary = &.{},
};

pub const ReviewRequest = struct {
    workspace_id: []const u8,
    local_thread_id: []const u8,
    /// Optional route (as for `workspace.files.search`) so a chat's own
    /// repository is inspected even before any change was attributed.
    repository_id: ?[]const u8 = null,
    relative_cwd: ?[]const u8 = null,
    project_path: ?[]const u8 = null,
    cwd: ?[]const u8 = null,
    include_unassigned: bool = true,
    /// Total hunk text budget across all files (clamped to
    /// 0..MAX_REVIEW_HUNK_BUDGET_BYTES; default 512 KiB). Files are filled in
    /// response order; once one does not fit, it and every later file get
    /// `preview_truncated: true`, `hunk_selectable: false` and no hunks.
    /// Such files can still be committed whole.
    hunk_budget_bytes: ?u64 = null,
};

pub const StatusRequest = struct {
    workspace_id: []const u8,
    local_thread_id: []const u8,
    /// Optional route, exactly as in `ReviewRequest`.
    repository_id: ?[]const u8 = null,
    relative_cwd: ?[]const u8 = null,
    project_path: ?[]const u8 = null,
    cwd: ?[]const u8 = null,
};

/// Branch facts shared by `RepoStatus` and `ReviewRepo`. Computed without
/// fetching, so `ahead`/`behind` are relative to the last fetched upstream.
pub const RepoStatus = struct {
    root: []const u8,
    /// Last path component of `root`.
    name: []const u8,
    /// Null when HEAD is detached.
    branch: ?[]const u8 = null,
    /// `origin/HEAD`'s target, else `main` or `master` if present, else null.
    default_branch: ?[]const u8 = null,
    is_default_branch: bool = false,
    /// e.g. `origin/feature/x`; null when the branch has no upstream yet
    /// (a push sets it).
    upstream: ?[]const u8 = null,
    /// Commits on HEAD not on the upstream. Without an upstream (and with a
    /// remote), commits not on any remote-tracking ref, so an unpublished
    /// branch still reports work to push.
    ahead: u32 = 0,
    /// Commits on the upstream not on HEAD (0 without an upstream).
    behind: u32 = 0,
    has_remote: bool = false,
};

/// Repositories relevant to the chat: those holding its claims plus its own
/// route repository.
pub const StatusResult = struct {
    workspace_id: []const u8,
    local_thread_id: []const u8,
    repos: []const RepoStatus = &.{},
};

pub const OtherThread = struct {
    local_thread_id: []const u8,
    title: []const u8,
};

pub const ReviewHunk = struct {
    index: u32,
    /// `@@ -a,b +c,d @@ ...` line.
    header: []const u8,
    /// Full hunk text including the header line.
    text: []const u8,
};

pub const ReviewFile = struct {
    path: []const u8,
    /// `modified`, `added`, or `deleted`.
    status: []const u8,
    /// `mine`, `shared`, `unclear`, or `unassigned`.
    ownership: []const u8,
    other_threads: []const OtherThread = &.{},
    additions: u32,
    deletions: u32,
    binary: bool,
    /// Individual hunks may be ticked; otherwise only the whole file.
    hunk_selectable: bool,
    /// Hunks were omitted from the response (large file); whole file only.
    preview_truncated: bool,
    hunks: []const ReviewHunk = &.{},
};

pub const ReviewRepo = struct {
    root: []const u8,
    /// Last path component of `root`, for grouping headers.
    name: []const u8,
    branch: ?[]const u8 = null,
    head: ?[]const u8 = null,
    /// Same meaning as the `RepoStatus` fields.
    default_branch: ?[]const u8 = null,
    is_default_branch: bool = false,
    upstream: ?[]const u8 = null,
    ahead: u32 = 0,
    behind: u32 = 0,
    has_remote: bool = false,
    files: []const ReviewFile = &.{},
};

pub const ReviewResult = struct {
    review_id: []const u8,
    workspace_id: []const u8,
    local_thread_id: []const u8,
    /// The chat has a running turn; the review is a frozen point-in-time view.
    turn_running: bool,
    /// `commit` or `commit_and_push` from settings.
    default_action: []const u8,
    repos: []const ReviewRepo = &.{},
};

pub const FileSelection = struct {
    path: []const u8,
    /// Omitted/null selects the whole file.
    hunks: ?[]const u32 = null,
};

pub const RepoSelection = struct {
    root: []const u8,
    files: []const FileSelection,
};

pub const CommitMessageRequest = struct {
    review_id: []const u8,
    /// Limit the message to these selections; omitted uses every file the
    /// chat owns (mine/shared/unclear).
    selections: ?[]const RepoSelection = null,
};

pub const CommitMessageResult = struct {
    message: []const u8,
    /// Suggested `feature/<slug>` branch from the same model call (falls back
    /// to a slug of the subject). Pass it as `CommitRequest.branch_name`.
    branch: ?[]const u8 = null,
    provider: []const u8,
    model: []const u8,
};

/// Idempotent per review: repeating a commit for a `review_id` that already
/// committed returns the stored `CommitResult` (even if the request body
/// differs) until the review expires (1 hour, or evicted after 16 newer
/// reviews). A repeat while the first is still running gets `in_progress`.
pub const CommitRequest = struct {
    review_id: []const u8,
    message: []const u8,
    selections: []const RepoSelection,
    /// Push after committing; sets the upstream (`push -u <remote> HEAD`)
    /// when the branch has none.
    push: bool = false,
    /// Create a branch at the current HEAD in each committed repository and
    /// commit onto it. The working tree and index are untouched. When a
    /// branch cannot be created that repository commits nothing and the
    /// request fails with `branch_create_failed`.
    new_branch: bool = false,
    /// Preferred name for `new_branch` (sanitized, `feature/` prefixed);
    /// null derives one from the message subject. `-2`, `-3`... are appended
    /// on collision with local branches.
    branch_name: ?[]const u8 = null,
};

pub const RepoCommit = struct {
    root: []const u8,
    commit: []const u8,
    short_commit: []const u8,
    subject: []const u8,
    files: u32,
    /// Branch the commit landed on; null for a detached HEAD.
    branch: ?[]const u8 = null,
    /// `branch` was created by this commit (`new_branch`).
    branch_created: bool = false,
    /// `not_requested`, `pushed`, `rejected`, or `failed`.
    push: []const u8,
    push_message: ?[]const u8 = null,
    /// The user's staging area for the committed paths was reset rather than
    /// advanced exactly.
    index_reset: bool = false,
};

/// A committed transcript row the daemon rewrote in place (see "Committed
/// transcript row"); clients holding the row swap in `body`.
pub const UpdatedRow = struct {
    message_id: []const u8,
    body: []const u8,
};

pub const CommitResult = struct {
    workspace_id: []const u8,
    local_thread_id: []const u8,
    files: u32,
    repos: []const RepoCommit = &.{},
    /// Earlier rows of this chat that this commit's push published.
    updated_rows: []const UpdatedRow = &.{},
    /// UI-only transcript row id; null when the chat was busy.
    transcript_message_id: ?[]const u8 = null,
};

/// `git pull --rebase --autostash`, then push. Refused with `turns_running`
/// while a chat works in the repository.
pub const PullPushRequest = struct {
    workspace_id: []const u8,
    root: []const u8,
    /// Chat whose committed transcript rows are marked pushed afterwards.
    local_thread_id: ?[]const u8 = null,
};

/// Push the current branch of `root`; never touches the working tree, so it
/// is allowed while chats run. Without an upstream it runs
/// `push -u <origin or first remote> HEAD`.
pub const PushRequest = struct {
    workspace_id: []const u8,
    root: []const u8,
    /// Chat whose committed transcript rows are marked pushed afterwards.
    local_thread_id: ?[]const u8 = null,
    /// Optional client idempotency key. A repeat with the same key (same
    /// workspace) within 10 minutes returns the first result; a repeat while
    /// it runs gets `in_progress`. At most 16 keys are remembered.
    request_id: ?[]const u8 = null,
};

/// Result of `git.changes.push` and `git.changes.pull_push`.
pub const PullPushResult = struct {
    root: []const u8,
    /// `pushed`, `rejected` (remote has commits you don't), or `failed`.
    push: []const u8,
    push_message: ?[]const u8 = null,
    /// Rows of the request's `local_thread_id` marked pushed by this push.
    updated_rows: []const UpdatedRow = &.{},
    // What a `pushed` result published (null otherwise, and from older
    // daemons):
    /// Commits the upstream had not seen (for a first publish: commits on no
    /// remote-tracking ref).
    commits: ?u32 = null,
    /// Short sha and subject of the pushed HEAD.
    head: ?[]const u8 = null,
    subject: ?[]const u8 = null,
    /// Upstream after the push, e.g. `origin/main`.
    upstream: ?[]const u8 = null,
    /// Web page of the pushed HEAD on the forge
    /// (`https://<host>/<owner>/<repo>/commit/<full sha>`), derived from the
    /// push remote's URL like the transcript row's `remote` line.
    remote_url: ?[]const u8 = null,
};

pub const WorkspaceRequest = struct {
    workspace_id: []const u8,
};

pub const WorkspaceOwner = struct {
    local_thread_id: []const u8,
    /// Never empty; falls back to `Chat <last 6 id chars>`.
    title: []const u8,
    /// The claim is a guess (overlapping turns without edit evidence).
    unclear: bool = false,
};

pub const WorkspaceFile = struct {
    /// Repository-relative path.
    path: []const u8,
    /// `modified`, `added`, or `deleted` (untracked files are `added`).
    status: []const u8,
    untracked: bool = false,
    /// Workspace-wide, not relative to one chat: `unassigned` (no chat
    /// claimed it), `mine` (one chat), `unclear` (one uncertain claim), or
    /// `shared` (several chats).
    ownership: []const u8,
    owners: []const WorkspaceOwner = &.{},
    additions: u32 = 0,
    deletions: u32 = 0,
    binary: bool = false,
};

pub const WorkspaceRepo = struct {
    root: []const u8,
    /// Last path component of `root`.
    name: []const u8,
    head: ?[]const u8 = null,
    /// Same meaning as the `RepoStatus` fields.
    branch: ?[]const u8 = null,
    default_branch: ?[]const u8 = null,
    is_default_branch: bool = false,
    upstream: ?[]const u8 = null,
    ahead: u32 = 0,
    behind: u32 = 0,
    has_remote: bool = false,
    /// Too many dirty paths to list (or over the response's
    /// `MAX_WORKSPACE_FILES` budget); `files` is empty.
    too_many_files: bool = false,
    /// Sorted by path; empty for a clean repository.
    files: []const WorkspaceFile = &.{},
};

/// Repositories reachable from the workspace (its folder, configured extra
/// folders, and any repository holding the workspace's claims), each with its
/// uncommitted changes against HEAD.
pub const WorkspaceResult = struct {
    workspace_id: []const u8,
    /// Claims revision, as in `SummaryResult`.
    revision: u64 = 0,
    repos: []const WorkspaceRepo = &.{},
};

/// Files listed across all repositories of one `git.changes.workspace`
/// response (keeps it under the 1 MiB remote-runtime message limit).
pub const MAX_WORKSPACE_FILES: usize = 2000;

/// Patches larger than this come back `truncated` with no text.
pub const MAX_FILE_PATCH_BYTES: u64 = 256 * 1024;

pub const FilePatchRequest = struct {
    workspace_id: []const u8,
    /// A `WorkspaceRepo.root` of this workspace; others are refused.
    root: []const u8,
    path: []const u8,
    /// Unchanged lines around each change (`git diff -U`); null means 3.
    /// The view asks for a large value to expand collapsed context.
    context_lines: ?u32 = null,
};

pub const FilePatchResult = struct {
    root: []const u8,
    path: []const u8,
    /// The file is no longer dirty; the other fields are empty.
    clean: bool = false,
    status: []const u8 = "modified",
    binary: bool = false,
    truncated: bool = false,
    additions: u32 = 0,
    deletions: u32 = 0,
    /// Echo of the request's `context_lines`.
    context_lines: ?u32 = null,
    /// Unified diff (`diff --git` header and hunks); null when clean,
    /// binary, or truncated.
    patch: ?[]const u8 = null,
};

pub const ConfigCommitSetRequest = struct {
    /// `auto`, `codex`, `claude`, `cursor`, or `opencode`.
    commit_message_provider: ?[]const u8 = null,
    /// Empty string clears back to the provider default.
    commit_message_model: ?[]const u8 = null,
    /// `commit` or `commit_and_push`.
    commit_default_action: ?[]const u8 = null,
};

pub const ConfigCommitSnapshot = struct {
    commit_message_provider: []const u8 = "auto",
    /// Explicit model for a fixed provider; null uses the provider default.
    commit_message_model: ?[]const u8 = null,
    commit_default_action: []const u8 = "commit",
};

test "git changes method names are stable" {
    try std.testing.expectEqualStrings("git.changes.summary", METHOD_SUMMARY);
    try std.testing.expectEqualStrings("git.changes.review", METHOD_REVIEW);
    try std.testing.expectEqualStrings("git.changes.commit_message", METHOD_COMMIT_MESSAGE);
    try std.testing.expectEqualStrings("git.changes.commit", METHOD_COMMIT);
    try std.testing.expectEqualStrings("git.changes.pull_push", METHOD_PULL_PUSH);
    try std.testing.expectEqualStrings("git.changes.push", METHOD_PUSH);
    try std.testing.expectEqualStrings("git.changes.status", METHOD_STATUS);
    try std.testing.expectEqualStrings("config.commit.set", METHOD_CONFIG_COMMIT_SET);
    try std.testing.expectEqualStrings("git.changes.workspace", METHOD_WORKSPACE);
    try std.testing.expectEqualStrings("git.changes.file_patch", METHOD_FILE_PATCH);
}
