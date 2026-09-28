//! Mobile wire projections of the git.changes daemon protocol.
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
    /// Commits on HEAD not on the upstream (0 without an upstream).
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

pub const CommitResult = struct {
    workspace_id: []const u8,
    local_thread_id: []const u8,
    files: u32,
    repos: []const RepoCommit = &.{},
    /// UI-only transcript row id; null when the chat was busy.
    transcript_message_id: ?[]const u8 = null,
};

/// `git pull --rebase --autostash`, then push. Refused with `turns_running`
/// while a chat works in the repository.
pub const PullPushRequest = struct {
    workspace_id: []const u8,
    root: []const u8,
};

pub const PushRequest = struct {
    workspace_id: []const u8,
    root: []const u8,
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
