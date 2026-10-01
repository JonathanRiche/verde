//! GUI-side controller for per-chat git change review and user-initiated
//! commits (daemon `git.changes.*`, see headless git_changes_protocol.zig).
//!
//! Owns the per-workspace change summaries behind the chat header chip and
//! sidebar dot, and the review sheet state (ticks, message, commit results).
//! Every daemon call runs on a short-lived worker thread; results are drained
//! on the UI thread by `pollGitChanges`. Nothing here commits without an
//! explicit click in the review sheet.

const std = @import("std");

const loop_wakeup = @import("loop_wakeup");
const platform_runtime = @import("platform_runtime");
const daemon_client = @import("../daemon/client.zig");
const headless = @import("headless");
const app_config = @import("../app/config.zig");
const chat_types = @import("chat_types.zig");

const proto = headless.git_changes_protocol;
const Mutex = std.atomic.Mutex;
const page = std.heap.page_allocator;

pub const ReviewResult = proto.ReviewResult;
pub const ReviewRepo = proto.ReviewRepo;
pub const ReviewFile = proto.ReviewFile;
pub const ThreadSummary = proto.ThreadSummary;

/// Coalesces bursts of `chat.turn` journal entries into one summary call.
pub const SUMMARY_DEBOUNCE_MS: u64 = 500;
/// Summary/review/commit run git in the daemon; allow more than the default.
const GIT_TIMEOUT_MS: u32 = 30_000;
/// Commit & push and pull & push wait on the network.
const PUSH_TIMEOUT_MS: u32 = 120_000;
/// Commit message generation starts a provider turn.
const MESSAGE_TIMEOUT_MS: u32 = 150_000;
/// Longest commit message the sheet edits.
pub const MESSAGE_CAPACITY: usize = 8192;

// ------------------------------------------------------------------
// Pure helpers (unit tested)
// ------------------------------------------------------------------

pub const Action = enum {
    commit,
    commit_and_push,

    pub fn fromConfig(value: app_config.CommitDefaultAction) Action {
        return switch (value) {
            .commit => .commit,
            .commit_and_push => .commit_and_push,
        };
    }

    pub fn parse(value: []const u8) Action {
        return if (std.mem.eql(u8, value, "commit_and_push")) .commit_and_push else .commit;
    }

    pub fn other(self: Action) Action {
        return if (self == .commit) .commit_and_push else .commit;
    }

    pub fn label(self: Action) []const u8 {
        return if (self == .commit) "Commit" else "Commit & push";
    }

    pub fn busyLabel(self: Action) []const u8 {
        return if (self == .commit) "Committing…" else "Committing & pushing…";
    }

    /// Footer label of the review sheet's "on a new branch" button.
    pub fn newBranchLabel(self: Action) []const u8 {
        return if (self == .commit) "Commit on new branch" else "Commit & push on new branch";
    }
};

/// Branch facts across a chat's repositories (`git.changes.status`), reduced
/// to what the header button and menu need.
pub const RepoFacts = struct {
    /// Commits not yet on the upstream, summed across repositories.
    ahead: u32 = 0,
    /// Some repository has a remote but its branch has no upstream yet, so a
    /// push would publish it.
    unpublished: bool = false,
    on_default_branch: bool = false,
    /// Any repository has a remote to push to.
    has_remote: bool = false,

    pub fn canPush(self: RepoFacts) bool {
        return self.ahead > 0 or self.unpublished;
    }
};

pub fn repoFacts(repos: []const proto.RepoStatus) RepoFacts {
    var facts: RepoFacts = .{};
    for (repos) |repo| {
        facts.ahead +|= repo.ahead;
        if (repo.has_remote) facts.has_remote = true;
        if (repo.has_remote and repo.branch != null and repo.upstream == null) facts.unpublished = true;
        if (repo.is_default_branch) facts.on_default_branch = true;
    }
    return facts;
}

/// Repositories a plain Push should push: they have a remote and a branch,
/// and either commits ahead or no upstream yet.
pub fn isPushTarget(repo: proto.RepoStatus) bool {
    return repo.has_remote and repo.branch != null and (repo.ahead > 0 or repo.upstream == null);
}

pub const HeaderKind = enum { commit, commit_and_push, push };

/// The chat header's split button: `[↑ Commit & push (4) | ▾]` or `[↑2 Push | ▾]`.
pub const HeaderButton = struct {
    kind: HeaderKind,
    /// Files the quick path would commit: the chat's own, not shared or
    /// unclear (the count badge); 0 for push.
    files: u32 = 0,
    /// Some file is shared or has an unclear owner (amber badge).
    attention: bool = false,
    ahead: u32 = 0,
    buf: [48]u8 = undefined,
    len: usize = 0,

    pub fn label(self: *const HeaderButton) []const u8 {
        return self.buf[0..self.len];
    }
};

/// Picks the header button from the change summary and branch facts. With
/// changes it offers the settings' default action (plain Commit when no
/// repository has a remote); with nothing to commit but commits ahead it
/// offers Push; otherwise it is hidden (null).
pub fn headerButton(summary: ?ThreadSummary, facts: ?RepoFacts, default_action: Action) ?HeaderButton {
    if (summary) |row| {
        if (row.files > 0) {
            const no_remote = if (facts) |known| !known.has_remote else false;
            const action: Action = if (no_remote) .commit else default_action;
            var button: HeaderButton = .{
                .kind = if (action == .commit) .commit else .commit_and_push,
                // Shared and unclear files are counted in `attention`; the
                // quick path leaves them out, so the badge does too.
                .files = row.files -| row.attention,
                .attention = row.attention > 0,
            };
            const text = action.label();
            @memcpy(button.buf[0..text.len], text);
            button.len = text.len;
            return button;
        }
    }
    const known = facts orelse return null;
    if (known.ahead == 0) return null;
    var button: HeaderButton = .{ .kind = .push, .ahead = known.ahead };
    const text = std.fmt.bufPrint(&button.buf, "{d} Push", .{known.ahead}) catch return null;
    button.len = text.len;
    return button;
}

/// What the header Commit & push / Commit does with a freshly loaded review.
/// Only files the chat owns (`mine`) are committed, whole; shared, unclear
/// and unassigned files are left out, never a reason to stop.
pub const QuickPlan = enum {
    /// No uncommitted files at all.
    nothing,
    /// Nothing is this chat's own but some file needs a decision: open the
    /// full review sheet.
    review,
    /// Some of this chat's files are on the default branch: confirm first.
    confirm_default_branch,
    /// This chat's files, on feature branches: commit (and push) now.
    direct,
};

pub fn quickPlan(review: ReviewResult) QuickPlan {
    var total: usize = 0;
    var mine: usize = 0;
    var on_default = false;
    for (review.repos) |repo| {
        var repo_mine = false;
        for (repo.files) |file| {
            total += 1;
            if (std.mem.eql(u8, file.ownership, "mine")) {
                mine += 1;
                repo_mine = true;
            }
        }
        if (repo_mine and repo.is_default_branch) on_default = true;
    }
    if (total == 0) return .nothing;
    if (mine == 0) return .review;
    return if (on_default) .confirm_default_branch else .direct;
}

/// Shared and unclear files the quick path leaves out (reported in its
/// result toast so the user can review them with Commit…).
pub fn leftOutFileCount(review: ReviewResult) usize {
    var total: usize = 0;
    for (review.repos) |repo| {
        for (repo.files) |file| {
            if (std.mem.eql(u8, file.ownership, "shared") or std.mem.eql(u8, file.ownership, "unclear")) total += 1;
        }
    }
    return total;
}

/// Toast detail for files the quick path left out.
pub fn leftOutNote(buf: []u8, count: usize) []const u8 {
    return std.fmt.bufPrint(buf, "{d} {s} left out (shared/unclear) \u{2014} use Commit\u{2026} to review them", .{
        count,
        if (count == 1) "file" else "files",
    }) catch "";
}

/// Files the quick path commits: every file this chat owns, whole.
pub fn mineFileCount(review: ReviewResult) usize {
    var total: usize = 0;
    for (review.repos) |repo| {
        for (repo.files) |file| {
            if (std.mem.eql(u8, file.ownership, "mine")) total += 1;
        }
    }
    return total;
}

/// Branch of the first repository holding this chat's files (the one the
/// default-branch confirmation names).
pub fn quickBranch(review: ReviewResult) ?[]const u8 {
    for (review.repos) |repo| {
        for (repo.files) |file| {
            if (std.mem.eql(u8, file.ownership, "mine")) return repo.branch orelse repo.default_branch;
        }
    }
    return null;
}

/// The message a commit uses: what the user typed, else the generated
/// message; null when both are blank.
pub fn effectiveMessage(typed: []const u8, generated: []const u8) ?[]const u8 {
    const own = std.mem.trim(u8, typed, " \t\r\n");
    if (own.len > 0) return own;
    const fallback = std.mem.trim(u8, generated, " \t\r\n");
    if (fallback.len > 0) return fallback;
    return null;
}

/// First line of a commit message.
pub fn messageSubject(message: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, message, " \t\r\n");
    const end = std.mem.indexOfScalar(u8, trimmed, '\n') orelse trimmed.len;
    return std.mem.trimEnd(u8, trimmed[0..end], " \t\r");
}

pub fn confirmTitle(buf: []u8, branch: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "Commit & push to {s}?", .{branch}) catch "Commit & push to the default branch?";
}

/// Body of the default-branch confirmation; `subject` is null while the
/// message is still being written.
pub fn confirmBody(buf: []u8, files: usize, branch: []const u8, subject: ?[]const u8) []const u8 {
    return std.fmt.bufPrint(buf, "This will commit and push {d} {s} on \u{201C}{s}\u{201D} \u{00B7} {s}. You can continue on this branch or create a feature branch and run the same action there.", .{
        files,
        if (files == 1) "file" else "files",
        branch,
        subject orelse "Writing message\u{2026}",
    }) catch "This will commit and push this chat's files on the default branch.";
}

/// Order-sensitive fingerprint of the ticks, so the sheet can tell whether
/// the generated message still matches the selection.
pub fn selectionHash(ticks: []const FileTick) u64 {
    var hasher = std.hash.Wyhash.init(0);
    for (ticks) |tick| {
        hasher.update(&.{@intFromBool(tick.whole)});
        for (tick.hunks) |ticked| hasher.update(&.{@intFromBool(ticked)});
        hasher.update(&.{0xff});
    }
    return hasher.final();
}

pub const Chip = struct {
    /// Backing storage for `text()`.
    buf: [96]u8 = undefined,
    len: usize = 0,
    attention: bool = false,

    pub fn text(self: *const Chip) []const u8 {
        return self.buf[0..self.len];
    }
};

/// Header chip `● 4 files +120 −30`; null (hidden) when the chat owns no files.
pub fn summaryChip(summary: ?ThreadSummary) ?Chip {
    const row = summary orelse return null;
    if (row.files == 0) return null;
    var chip: Chip = .{ .attention = row.attention > 0 };
    const written = std.fmt.bufPrint(&chip.buf, "\u{25CF} {d} {s} +{d} \u{2212}{d}", .{
        row.files,
        if (row.files == 1) "file" else "files",
        row.additions,
        row.deletions,
    }) catch return null;
    chip.len = written.len;
    return chip;
}

/// Hunks are pickable only when the daemon sent them and allows partial commits.
pub fn canSelectHunks(file: ReviewFile) bool {
    return file.hunk_selectable and !file.binary and !file.preview_truncated and file.hunks.len > 0;
}

pub const TickState = enum { none, all, partial };

/// One file's selection. Hunk-selectable files track each hunk (by position
/// in `file.hunks`); other files are ticked whole.
pub const FileTick = struct {
    whole: bool = false,
    hunks: []bool = &.{},

    pub fn state(self: FileTick, file: ReviewFile) TickState {
        if (!canSelectHunks(file) or self.hunks.len != file.hunks.len) {
            return if (self.whole) .all else .none;
        }
        var picked: usize = 0;
        for (self.hunks) |ticked| {
            if (ticked) picked += 1;
        }
        if (picked == 0) return .none;
        if (picked == self.hunks.len) return .all;
        return .partial;
    }

    fn setAll(self: *FileTick, value: bool) void {
        self.whole = value;
        @memset(self.hunks, value);
    }

    /// Unticks a fully ticked file; ticks anything else wholly.
    pub fn toggle(self: *FileTick, file: ReviewFile) void {
        self.setAll(self.state(file) != .all);
    }

    pub fn toggleHunk(self: *FileTick, file: ReviewFile, hunk_position: usize) void {
        if (!canSelectHunks(file) or hunk_position >= self.hunks.len) {
            self.toggle(file);
            return;
        }
        self.hunks[hunk_position] = !self.hunks[hunk_position];
        self.whole = self.state(file) == .all;
    }

    pub fn hunkTicked(self: FileTick, hunk_position: usize) bool {
        if (hunk_position < self.hunks.len) return self.hunks[hunk_position];
        return self.whole;
    }
};

pub fn reviewFileCount(review: ReviewResult) usize {
    var total: usize = 0;
    for (review.repos) |repo| total += repo.files.len;
    return total;
}

/// Mine is ticked; shared/unclear/unassigned stay unticked until the user opts in.
pub fn defaultTicks(allocator: std.mem.Allocator, review: ReviewResult) ![]FileTick {
    const ticks = try allocator.alloc(FileTick, reviewFileCount(review));
    var index: usize = 0;
    for (review.repos) |repo| {
        for (repo.files) |file| {
            const mine = std.mem.eql(u8, file.ownership, "mine");
            const hunks: []bool = if (canSelectHunks(file)) try allocator.alloc(bool, file.hunks.len) else &.{};
            @memset(hunks, mine);
            ticks[index] = .{ .whole = mine, .hunks = hunks };
            index += 1;
        }
    }
    return ticks;
}

/// Keep whole-file choices across a reload; partial hunk picks reset because
/// hunk indices are only meaningful within one review.
pub fn carryTicks(
    allocator: std.mem.Allocator,
    review: ReviewResult,
    previous_review: ReviewResult,
    previous_ticks: []const FileTick,
) ![]FileTick {
    const ticks = try defaultTicks(allocator, review);
    var index: usize = 0;
    for (review.repos) |repo| {
        for (repo.files) |file| {
            defer index += 1;
            const old = findTick(previous_review, previous_ticks, repo.root, file.path) orelse continue;
            switch (old.tick.state(old.file)) {
                .all => ticks[index].setAll(true),
                .none => ticks[index].setAll(false),
                .partial => {},
            }
        }
    }
    return ticks;
}

const FoundTick = struct { file: ReviewFile, tick: FileTick };

fn findTick(review: ReviewResult, ticks: []const FileTick, root: []const u8, path: []const u8) ?FoundTick {
    var index: usize = 0;
    for (review.repos) |repo| {
        for (repo.files) |file| {
            defer index += 1;
            if (index >= ticks.len) return null;
            if (std.mem.eql(u8, repo.root, root) and std.mem.eql(u8, file.path, path)) {
                return .{ .file = file, .tick = ticks[index] };
            }
        }
    }
    return null;
}

/// Whole files omit `hunks`; partial files list the ticked hunk indices.
pub fn buildSelections(allocator: std.mem.Allocator, review: ReviewResult, ticks: []const FileTick) ![]proto.RepoSelection {
    var repos: std.ArrayList(proto.RepoSelection) = .empty;
    var index: usize = 0;
    for (review.repos) |repo| {
        var files: std.ArrayList(proto.FileSelection) = .empty;
        for (repo.files) |file| {
            defer index += 1;
            if (index >= ticks.len) break;
            const tick = ticks[index];
            switch (tick.state(file)) {
                .none => {},
                .all => try files.append(allocator, .{ .path = file.path }),
                .partial => {
                    var hunks: std.ArrayList(u32) = .empty;
                    for (file.hunks, 0..) |hunk, position| {
                        if (tick.hunks[position]) try hunks.append(allocator, hunk.index);
                    }
                    try files.append(allocator, .{ .path = file.path, .hunks = try hunks.toOwnedSlice(allocator) });
                },
            }
        }
        if (files.items.len > 0) {
            try repos.append(allocator, .{ .root = repo.root, .files = try files.toOwnedSlice(allocator) });
        }
    }
    return repos.toOwnedSlice(allocator);
}

pub fn selectionFileCount(selections: []const proto.RepoSelection) usize {
    var total: usize = 0;
    for (selections) |repo| total += repo.files.len;
    return total;
}

pub fn ownershipLabel(buf: []u8, file: ReviewFile) []const u8 {
    if (std.mem.eql(u8, file.ownership, "mine")) return "Mine";
    if (std.mem.eql(u8, file.ownership, "unassigned")) return "Unassigned";
    if (!std.mem.eql(u8, file.ownership, "shared")) return "Unclear owner";
    if (file.other_threads.len == 0) return "Shared";
    var writer: std.Io.Writer = .fixed(buf);
    writer.writeAll("Shared with ") catch return "Shared";
    for (file.other_threads, 0..) |other, position| {
        if (position > 0) writer.writeAll(", ") catch break;
        const title = std.mem.trim(u8, other.title, " \t\r\n");
        writer.writeAll(if (title.len == 0) "another chat" else title) catch break;
    }
    return writer.buffered();
}

pub const ErrorKind = enum { reload, retry, identity, other };

pub fn commitErrorKind(code: ?[]const u8) ErrorKind {
    const value = code orelse return .other;
    if (std.mem.eql(u8, value, proto.ERR_CHANGED_SINCE_REVIEW) or std.mem.eql(u8, value, proto.ERR_REVIEW_EXPIRED)) return .reload;
    if (std.mem.eql(u8, value, proto.ERR_HEAD_MOVED)) return .retry;
    if (std.mem.eql(u8, value, proto.ERR_MISSING_IDENTITY)) return .identity;
    return .other;
}

pub fn commitErrorText(code: ?[]const u8, message: ?[]const u8) []const u8 {
    return switch (commitErrorKind(code)) {
        .reload => if (code != null and std.mem.eql(u8, code.?, proto.ERR_REVIEW_EXPIRED))
            "This review expired, so it was reloaded. Check the selection and commit again."
        else
            "Files changed since this review was opened, so it was reloaded. Check the selection and commit again.",
        .retry => "HEAD moved while committing; nothing was written. Try again.",
        .identity => "Git has no user.name / user.email for this repository. Set them with `git config`, then try again.",
        .other => if (message) |text| (if (text.len > 0) text else "Commit failed.") else "Commit failed.",
    };
}

pub const CommitOutcome = struct {
    text: []const u8,
    /// Repository whose push was rejected; offers Pull & push.
    pull_push_root: ?[]const u8 = null,
};

/// `Committed 2 files · e57cfce · pushed`; a rejected push offers Pull & push.
pub fn commitOutcome(buf: []u8, result: proto.CommitResult) CommitOutcome {
    var writer: std.Io.Writer = .fixed(buf);
    var files: u64 = result.files;
    if (files == 0) {
        for (result.repos) |repo| files += repo.files;
    }
    writer.print("Committed {d} {s}", .{ files, if (files == 1) "file" else "files" }) catch {};
    var first_sha = true;
    for (result.repos) |repo| {
        const sha = if (repo.short_commit.len > 0) repo.short_commit else repo.commit[0..@min(repo.commit.len, 7)];
        if (sha.len == 0) continue;
        writer.writeAll(if (first_sha) " \u{00B7} " else ", ") catch {};
        writer.writeAll(sha) catch {};
        first_sha = false;
    }
    var rejected: ?proto.RepoCommit = null;
    var failed: ?proto.RepoCommit = null;
    var all_pushed = result.repos.len > 0;
    for (result.repos) |repo| {
        if (rejected == null and std.mem.eql(u8, repo.push, "rejected")) rejected = repo;
        if (failed == null and std.mem.eql(u8, repo.push, "failed")) failed = repo;
        if (!std.mem.eql(u8, repo.push, "pushed")) all_pushed = false;
    }
    if (rejected != null) {
        writer.writeAll(" \u{00B7} push rejected") catch {};
    } else if (failed) |repo| {
        writer.writeAll(" \u{00B7} push failed") catch {};
        if (repo.push_message) |message| {
            if (message.len > 0) writer.print(": {s}", .{message}) catch {};
        }
    } else if (all_pushed) {
        writer.writeAll(" \u{00B7} pushed") catch {};
    }
    for (result.repos) |repo| {
        if (repo.branch_created) {
            if (repo.branch) |branch| writer.print(" \u{00B7} on {s}", .{branch}) catch {};
            break;
        }
    }
    for (result.repos) |repo| {
        if (repo.index_reset) {
            writer.writeAll(" \u{00B7} staged changes for these files were reset") catch {};
            break;
        }
    }
    return .{ .text = writer.buffered(), .pull_push_root = if (rejected) |repo| repo.root else null };
}

// ---- Outcome toast (pure) -------------------------------------------

pub const ToastTone = enum { running, success, warning, failure };

/// Success toasts hold this long, then fade; the others stay until dismissed.
pub const TOAST_SUCCESS_HOLD_MS: i64 = 5000;
pub const TOAST_IN_MS: i64 = 160;
pub const TOAST_OUT_MS: i64 = 240;
/// The running spinner advances one step per tick (no display-rate frames).
pub const TOAST_SPINNER_STEP_MS: i64 = 90;

/// Outcome card of a finished git action (Commit, Commit & push, Push,
/// Pull & push), drawn at the bottom of the workspace.
pub const Toast = struct {
    tone: ToastTone = .success,
    title_buf: [96]u8 = undefined,
    title_len: usize = 0,
    detail_buf: [320]u8 = undefined,
    detail_len: usize = 0,
    /// Rejected push: the card offers Pull & push for this chat.
    pull_push_thread_buf: [128]u8 = undefined,
    pull_push_thread_len: usize = 0,
    /// Monotonic stamp set when the toast is shown.
    shown_at_ms: i64 = 0,

    pub fn title(self: *const Toast) []const u8 {
        return self.title_buf[0..self.title_len];
    }

    pub fn detail(self: *const Toast) []const u8 {
        return self.detail_buf[0..self.detail_len];
    }

    pub fn pullPushThread(self: *const Toast) ?[]const u8 {
        return if (self.pull_push_thread_len > 0) self.pull_push_thread_buf[0..self.pull_push_thread_len] else null;
    }

    fn setTitle(self: *Toast, value: []const u8) void {
        self.title_len = copyInto(&self.title_buf, value).len;
    }

    fn setDetail(self: *Toast, value: []const u8) void {
        self.detail_len = copyInto(&self.detail_buf, value).len;
    }

    fn setPullPushThread(self: *Toast, value: []const u8) void {
        self.pull_push_thread_len = copyInto(&self.pull_push_thread_buf, value).len;
    }

    /// Leads the detail with how many files the quick path left out.
    pub fn noteLeftOut(self: *Toast, count: usize) void {
        if (count == 0) return;
        var note_buf: [128]u8 = undefined;
        var old_buf: [320]u8 = undefined;
        const old = copyInto(&old_buf, self.detail());
        var detail_buf: [320]u8 = undefined;
        self.setDetail(joinDetail(&detail_buf, &.{ leftOutNote(&note_buf, count), old }));
    }
};

/// Joins non-empty parts with ` · `, dropping any that do not fit.
fn joinDetail(buf: []u8, parts: []const []const u8) []const u8 {
    var writer: std.Io.Writer = .fixed(buf);
    var first = true;
    for (parts) |part| {
        const text = std.mem.trim(u8, part, " \t\r\n");
        if (text.len == 0) continue;
        if (!first) writer.writeAll(" \u{00B7} ") catch break;
        writer.writeAll(text) catch break;
        first = false;
    }
    return writer.buffered();
}

/// `Committed 3 files` / `Committed & pushed 3 files`, detail
/// `sha · branch · subject`; a rejected push offers Pull & push.
pub fn commitToast(result: proto.CommitResult, push_requested: bool) Toast {
    var toast: Toast = .{};
    var files: u64 = result.files;
    if (files == 0) {
        for (result.repos) |repo| files += repo.files;
    }
    var rejected: ?proto.RepoCommit = null;
    var failed: ?proto.RepoCommit = null;
    var all_pushed = result.repos.len > 0;
    for (result.repos) |repo| {
        if (rejected == null and std.mem.eql(u8, repo.push, "rejected")) rejected = repo;
        if (failed == null and std.mem.eql(u8, repo.push, "failed")) failed = repo;
        if (!std.mem.eql(u8, repo.push, "pushed")) all_pushed = false;
    }
    const noun = if (files == 1) "file" else "files";
    var title_buf: [96]u8 = undefined;
    const title = if (rejected != null)
        std.fmt.bufPrint(&title_buf, "Committed {d} {s}, push rejected", .{ files, noun })
    else if (failed != null)
        std.fmt.bufPrint(&title_buf, "Committed {d} {s}, push failed", .{ files, noun })
    else if (push_requested and all_pushed)
        std.fmt.bufPrint(&title_buf, "Committed & pushed {d} {s}", .{ files, noun })
    else
        std.fmt.bufPrint(&title_buf, "Committed {d} {s}", .{ files, noun });
    toast.setTitle(title catch "Committed");
    toast.tone = if (rejected != null) .warning else if (failed != null) .failure else .success;

    var sha_buf: [96]u8 = undefined;
    var shas: std.Io.Writer = .fixed(&sha_buf);
    for (result.repos) |repo| {
        const sha = if (repo.short_commit.len > 0) repo.short_commit else repo.commit[0..@min(repo.commit.len, 7)];
        if (sha.len == 0) continue;
        if (shas.buffered().len > 0) shas.writeAll(", ") catch break;
        shas.writeAll(sha) catch break;
    }
    const first: ?proto.RepoCommit = if (result.repos.len > 0) result.repos[0] else null;
    const branch = if (first) |repo| repo.branch orelse "" else "";
    const subject = if (first) |repo| firstLineOf(repo.subject) else "";
    const problem: []const u8 = if (rejected != null)
        "The remote has commits this branch does not."
    else if (failed) |repo|
        (if (repo.push_message) |message| (if (message.len > 0) firstLineOf(message) else "Push failed.") else "Push failed.")
    else
        "";
    var detail_buf: [320]u8 = undefined;
    toast.setDetail(joinDetail(&detail_buf, &.{ problem, shas.buffered(), branch, subject }));
    if (rejected != null) toast.setPullPushThread(result.local_thread_id);
    return toast;
}

/// `Pushed 2 commits to origin/main`; without an upstream (first push of a
/// branch) `Published <branch>`. Detail: head sha · repository · branch ·
/// subject (sha and subject from the daemon's push facts, when known).
pub fn pushToast(repos: u32, commits: u32, upstream: []const u8, branch: []const u8, repo_name: []const u8, head: []const u8, subject: []const u8) Toast {
    var toast: Toast = .{ .tone = .success };
    var title_buf: [96]u8 = undefined;
    const noun = if (commits == 1) "commit" else "commits";
    const title = if (repos > 1)
        std.fmt.bufPrint(&title_buf, "Pushed {d} {s} to {d} repositories", .{ commits, noun, repos })
    else if (upstream.len > 0 and commits > 0)
        std.fmt.bufPrint(&title_buf, "Pushed {d} {s} to {s}", .{ commits, noun, upstream })
    else if (upstream.len > 0)
        std.fmt.bufPrint(&title_buf, "Pushed to {s}", .{upstream})
    else if (branch.len > 0)
        std.fmt.bufPrint(&title_buf, "Published {s}", .{branch})
    else
        std.fmt.bufPrint(&title_buf, "Pushed", .{});
    toast.setTitle(title catch "Pushed");
    var detail_buf: [320]u8 = undefined;
    toast.setDetail(joinDetail(&detail_buf, &.{ head, if (repos > 1) "" else repo_name, branch, firstLineOf(subject) }));
    return toast;
}

/// A push (or pull & push) that did not land: `rejected` is amber and offers
/// Pull & push; anything else is red with git's message.
pub fn pushFailureToast(title: []const u8, status: []const u8, message: ?[]const u8, local_thread_id: []const u8, offer_pull_push: bool) Toast {
    var toast: Toast = .{};
    toast.setTitle(title);
    if (std.mem.eql(u8, status, "rejected")) {
        toast.tone = .warning;
        toast.setDetail("The remote has commits this branch does not.");
        if (offer_pull_push) toast.setPullPushThread(local_thread_id);
    } else {
        toast.tone = .failure;
        const text = if (message) |value| firstLineOf(value) else "";
        toast.setDetail(if (text.len > 0) text else "git push did not succeed.");
    }
    return toast;
}

pub fn failureToast(title: []const u8, detail: []const u8) Toast {
    var toast: Toast = .{ .tone = .failure };
    toast.setTitle(title);
    toast.setDetail(detail);
    return toast;
}

pub fn pullPushToast(root: []const u8, branch: []const u8, head: []const u8, subject: []const u8) Toast {
    var toast: Toast = .{ .tone = .success };
    toast.setTitle("Pulled & pushed");
    var detail_buf: [320]u8 = undefined;
    toast.setDetail(joinDetail(&detail_buf, &.{ head, std.fs.path.basename(root), branch, firstLineOf(subject) }));
    return toast;
}

pub const ToastPhase = struct { alpha: f32, rise: f32, animating: bool };

/// Toast timing: slide in, then (with a hold) fade out; null once expired.
pub fn toastPhase(elapsed_ms: i64, hold_ms: ?i64) ?ToastPhase {
    if (elapsed_ms < 0) return .{ .alpha = 0.0, .rise = 0.0, .animating = true };
    if (hold_ms) |hold| if (elapsed_ms >= hold) return null;
    const in_t: f32 = @min(1.0, @as(f32, @floatFromInt(elapsed_ms)) / @as(f32, @floatFromInt(TOAST_IN_MS)));
    const out_t: f32 = if (hold_ms) |hold|
        @min(1.0, @as(f32, @floatFromInt(hold - elapsed_ms)) / @as(f32, @floatFromInt(TOAST_OUT_MS)))
    else
        1.0;
    const inv = 1.0 - in_t;
    return .{ .alpha = @min(in_t, out_t), .rise = 1.0 - inv * inv * inv, .animating = in_t < 1.0 or out_t < 1.0 };
}

fn firstLineOf(value: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    const end = std.mem.indexOfScalar(u8, trimmed, '\n') orelse trimmed.len;
    return std.mem.trimEnd(u8, trimmed[0..end], " \t\r");
}

pub const COMMIT_PROVIDER_OPTIONS = [_]app_config.CommitMessageProvider{ .auto, .codex, .claude, .cursor, .opencode };

pub fn commitProviderLabel(provider: app_config.CommitMessageProvider) []const u8 {
    return switch (provider) {
        .auto => "Auto",
        .codex => "Codex",
        .claude => "Claude",
        .cursor => "Cursor",
        .opencode => "OpenCode",
    };
}

// ------------------------------------------------------------------
// Background jobs
// ------------------------------------------------------------------

const Job = enum { summary, status, review, commit_message, commit, push, pull_push, config_set };

/// Independent lanes so a slow commit message never blocks a summary refresh
/// or a commit. `quick` and `quick_message` serve the header's one-click
/// Commit & push / Push / Pull & push, independent of the review sheet.
const LaneId = enum(u3) { summary, sheet, message, config, status, quick, quick_message };
const LANE_COUNT = @typeInfo(LaneId).@"enum".fields.len;

const Status = enum { idle, pending, completed };

const Request = struct {
    job: Job,
    pref_path: []u8,
    params_json: []u8,
    timeout_ms: u32,
    delay_ms: u64 = 0,
    generation: u64 = 0,
    /// Workspace id (summary) or repository root (pull & push).
    tag: []u8,

    fn deinit(self: *Request) void {
        page.free(self.pref_path);
        page.free(self.params_json);
        page.free(self.tag);
        page.destroy(self);
    }
};

const Payload = union(enum) {
    none,
    summary: std.json.Parsed(proto.SummaryResult),
    status: std.json.Parsed(proto.StatusResult),
    review: std.json.Parsed(proto.ReviewResult),
    commit_message: std.json.Parsed(proto.CommitMessageResult),
    commit: std.json.Parsed(proto.CommitResult),
    pull_push: std.json.Parsed(proto.PullPushResult),
    config_set: std.json.Parsed(proto.ConfigCommitSnapshot),

    fn deinit(self: *Payload) void {
        switch (self.*) {
            .none => {},
            inline else => |*parsed| parsed.deinit(),
        }
        self.* = .none;
    }
};

const Result = struct {
    job: Job,
    generation: u64,
    err_code: ?[]u8 = null,
    err_message: ?[]u8 = null,
    payload: Payload = .none,

    fn deinit(self: *Result) void {
        if (self.err_code) |value| page.free(value);
        if (self.err_message) |value| page.free(value);
        self.payload.deinit();
    }

    fn failed(self: Result) bool {
        return self.payload == .none;
    }
};

const Lane = struct {
    mutex: Mutex = .unlocked,
    status: Status = .idle,
    worker: ?std.Thread = null,
    request: ?*Request = null,
    result: ?Result = null,

    fn lock(self: *Lane) void {
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
    }

    fn busy(self: *Lane) bool {
        self.lock();
        defer self.mutex.unlock();
        return self.status != .idle;
    }

    fn join(self: *Lane) void {
        if (self.worker) |thread| thread.join();
        self.worker = null;
        if (self.request) |request| request.deinit();
        self.request = null;
        if (self.result) |*result| result.deinit();
        self.result = null;
        self.status = .idle;
    }
};

fn methodFor(job: Job) []const u8 {
    return switch (job) {
        .summary => proto.METHOD_SUMMARY,
        .status => proto.METHOD_STATUS,
        .review => proto.METHOD_REVIEW,
        .commit_message => proto.METHOD_COMMIT_MESSAGE,
        .commit => proto.METHOD_COMMIT,
        .push => proto.METHOD_PUSH,
        .pull_push => proto.METHOD_PULL_PUSH,
        .config_set => proto.METHOD_CONFIG_COMMIT_SET,
    };
}

fn worker(lane: *Lane, request: *Request) void {
    if (request.delay_ms > 0) platform_runtime.sleepMillis(request.delay_ms);
    var result: Result = .{ .job = request.job, .generation = request.generation };
    runJob(request, &result);
    lane.lock();
    lane.result = result;
    lane.status = .completed;
    lane.mutex.unlock();
    loop_wakeup.notify();
}

fn setError(result: *Result, code: ?[]const u8, message: []const u8) void {
    result.err_code = if (code) |value| page.dupe(u8, value) catch null else null;
    result.err_message = page.dupe(u8, message) catch null;
}

fn parseTyped(comptime T: type, value: std.json.Value) ?std.json.Parsed(T) {
    return std.json.parseFromValue(T, page, value, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch null;
}

fn runJob(request: *Request, result: *Result) void {
    var params = std.json.parseFromSlice(std.json.Value, page, request.params_json, .{}) catch {
        setError(result, null, "Could not encode the request.");
        return;
    };
    defer params.deinit();
    var transport: daemon_client.HeadlessTransport = .{
        .allocator = page,
        .pref_path = request.pref_path,
        .timeout_ms = request.timeout_ms,
    };
    var client = daemon_client.headlessClient(page, &transport);
    var parsed = client.call(methodFor(request.job), params.value) catch {
        setError(result, null, "Could not reach the Verde daemon, or it took too long to answer.");
        return;
    };
    defer parsed.deinit();
    if (parsed.response.err) |err| {
        setError(result, err.code, err.message);
        return;
    }
    const value = parsed.response.result orelse {
        setError(result, null, "The daemon returned an empty response.");
        return;
    };
    result.payload = switch (request.job) {
        .summary => if (parseTyped(proto.SummaryResult, value)) |typed| .{ .summary = typed } else .none,
        .status => if (parseTyped(proto.StatusResult, value)) |typed| .{ .status = typed } else .none,
        .review => if (parseTyped(proto.ReviewResult, value)) |typed| .{ .review = typed } else .none,
        .commit_message => if (parseTyped(proto.CommitMessageResult, value)) |typed| .{ .commit_message = typed } else .none,
        .commit => if (parseTyped(proto.CommitResult, value)) |typed| .{ .commit = typed } else .none,
        .push, .pull_push => if (parseTyped(proto.PullPushResult, value)) |typed| .{ .pull_push = typed } else .none,
        .config_set => if (parseTyped(proto.ConfigCommitSnapshot, value)) |typed| .{ .config_set = typed } else .none,
    };
    if (result.payload == .none) setError(result, null, "The daemon returned an unexpected response.");
}

// ------------------------------------------------------------------
// State
// ------------------------------------------------------------------

const SummaryEntry = struct {
    workspace_id: []u8,
    parsed: std.json.Parsed(proto.SummaryResult),

    fn deinit(self: *SummaryEntry) void {
        page.free(self.workspace_id);
        self.parsed.deinit();
    }
};

pub const SheetPhase = enum {
    loading,
    ready,
    load_error,
    /// Commit landed but a push was rejected; the sheet shows the outcome and
    /// offers Pull & push.
    result,
};

pub const MessageStatus = enum { idle, writing, failed };

pub const Sheet = struct {
    phase: SheetPhase = .loading,
    workspace_id: []u8 = &.{},
    local_thread_id: []u8 = &.{},
    thread_title: []u8 = &.{},
    /// `git.changes.review` params, kept so reloads reuse the same route.
    review_params: []u8 = &.{},
    review: ?std.json.Parsed(proto.ReviewResult) = null,
    tick_arena: std.heap.ArenaAllocator = .init(page),
    ticks: []FileTick = &.{},
    expanded: []bool = &.{},

    /// Primary action: Commit (Commit…, palette) or Commit & push (the
    /// header's Commit & push when files need a decision).
    mode: Action = .commit,
    /// The file list shows checkboxes and hunks instead of the plain list.
    editing: bool = false,

    /// What the user typed. Empty means "use the generated message", which
    /// the field shows as placeholder text.
    message_storage: [MESSAGE_CAPACITY + 1]u8 = [_]u8{0} ** (MESSAGE_CAPACITY + 1),
    message_cursor: usize = 0,
    /// Last message the provider wrote (placeholder and empty-box commit).
    generated_storage: [MESSAGE_CAPACITY]u8 = undefined,
    generated_len: usize = 0,
    /// `feature/<slug>` suggested with the generated message.
    branch_storage: [128]u8 = undefined,
    branch_len: usize = 0,
    message_status: MessageStatus = .idle,
    message_generation: u64 = 0,
    /// `selectionHash` of the ticks the last message request covered.
    message_selection: u64 = 0,
    /// Message to request once the current generation finishes.
    message_rerun: ?bool = null,
    source_buf: [128]u8 = undefined,
    source_len: usize = 0,
    /// A commit clicked while the message was still being written; the value
    /// is `new_branch`. It runs as soon as the message lands.
    pending_new_branch: ?bool = null,
    /// Action the pending commit runs (the sheet's mode or its alternate).
    pending_action: Action = .commit,

    busy: ?Action = null,
    busy_new_branch: bool = false,
    error_buf: [320]u8 = undefined,
    error_len: usize = 0,
    outcome_buf: [320]u8 = undefined,
    outcome_len: usize = 0,
    pull_push_root: ?[]u8 = null,
    pull_push_busy: bool = false,

    scroll_y: f32 = 0,
    message_scroll_y: f32 = 0,

    fn deinit(self: *Sheet) void {
        page.free(self.workspace_id);
        page.free(self.local_thread_id);
        page.free(self.thread_title);
        page.free(self.review_params);
        if (self.review) |*parsed| parsed.deinit();
        self.tick_arena.deinit();
        if (self.pull_push_root) |root| page.free(root);
        self.* = undefined;
    }

    pub fn reviewValue(self: *const Sheet) ?ReviewResult {
        return if (self.review) |parsed| parsed.value else null;
    }

    pub fn message(self: *const Sheet) []const u8 {
        return std.mem.sliceTo(self.message_storage[0..], 0);
    }

    pub fn messageBuffer(self: *Sheet) [:0]u8 {
        return self.message_storage[0..MESSAGE_CAPACITY :0];
    }

    pub fn errorText(self: *const Sheet) []const u8 {
        return self.error_buf[0..self.error_len];
    }

    pub fn outcomeText(self: *const Sheet) []const u8 {
        return self.outcome_buf[0..self.outcome_len];
    }

    pub fn sourceText(self: *const Sheet) []const u8 {
        return self.source_buf[0..self.source_len];
    }

    fn setErrorText(self: *Sheet, text: []const u8) void {
        const len = @min(text.len, self.error_buf.len);
        @memcpy(self.error_buf[0..len], text[0..len]);
        self.error_len = len;
    }

    pub fn generated(self: *const Sheet) []const u8 {
        return self.generated_storage[0..self.generated_len];
    }

    pub fn branchSuggestion(self: *const Sheet) ?[]const u8 {
        return if (self.branch_len > 0) self.branch_storage[0..self.branch_len] else null;
    }

    /// The message a commit would use now (typed, else generated).
    pub fn messageToCommit(self: *const Sheet) ?[]const u8 {
        return effectiveMessage(self.message(), self.generated());
    }

    /// A commit is running or waiting for its message; edits are frozen.
    pub fn locked(self: *const Sheet) bool {
        return self.busy != null or self.pending_new_branch != null;
    }

    fn setGenerated(self: *Sheet, text: []const u8, branch: ?[]const u8) void {
        const trimmed = std.mem.trim(u8, text, " \t\r\n");
        const len = @min(trimmed.len, MESSAGE_CAPACITY);
        @memcpy(self.generated_storage[0..len], trimmed[0..len]);
        self.generated_len = len;
        const name = branch orelse "";
        const branch_len = @min(name.len, self.branch_storage.len);
        @memcpy(self.branch_storage[0..branch_len], name[0..branch_len]);
        self.branch_len = branch_len;
    }

    fn clearTyped(self: *Sheet) void {
        @memset(self.message_storage[0..], 0);
        self.message_cursor = 0;
        self.message_scroll_y = 0;
    }

    /// Selected files and their line totals (partial files count whole).
    pub fn selectedTotals(self: *const Sheet) struct { files: usize, additions: u64, deletions: u64 } {
        const review = self.reviewValue() orelse return .{ .files = 0, .additions = 0, .deletions = 0 };
        var files: usize = 0;
        var additions: u64 = 0;
        var deletions: u64 = 0;
        var index: usize = 0;
        for (review.repos) |repo| {
            for (repo.files) |file| {
                defer index += 1;
                if (index >= self.ticks.len or self.ticks[index].state(file) == .none) continue;
                files += 1;
                additions += file.additions;
                deletions += file.deletions;
            }
        }
        return .{ .files = files, .additions = additions, .deletions = deletions };
    }

    /// Some repository holding a selected file is on its default branch.
    pub fn selectionOnDefaultBranch(self: *const Sheet) bool {
        const review = self.reviewValue() orelse return false;
        var index: usize = 0;
        for (review.repos) |repo| {
            var selected = false;
            for (repo.files) |file| {
                defer index += 1;
                if (index < self.ticks.len and self.ticks[index].state(file) != .none) selected = true;
            }
            if (selected and repo.is_default_branch) return true;
        }
        return false;
    }

    pub fn fileCount(self: *const Sheet) usize {
        return self.ticks.len;
    }

    pub fn selectedFileCount(self: *const Sheet) usize {
        const review = self.reviewValue() orelse return 0;
        var total: usize = 0;
        var index: usize = 0;
        for (review.repos) |repo| {
            for (repo.files) |file| {
                defer index += 1;
                if (index < self.ticks.len and self.ticks[index].state(file) != .none) total += 1;
            }
        }
        return total;
    }

    /// Resolves a flat file index to its repo and file.
    pub fn fileAt(self: *const Sheet, flat_index: usize) ?struct { repo: ReviewRepo, file: ReviewFile } {
        const review = self.reviewValue() orelse return null;
        var index: usize = 0;
        for (review.repos) |repo| {
            if (flat_index < index + repo.files.len) return .{ .repo = repo, .file = repo.files[flat_index - index] };
            index += repo.files.len;
        }
        return null;
    }

    fn installReview(self: *Sheet, parsed: std.json.Parsed(proto.ReviewResult), carry: bool) void {
        var next_arena: std.heap.ArenaAllocator = .init(page);
        const allocator = next_arena.allocator();
        const empty_ticks: []FileTick = &.{};
        const empty_flags: []bool = &.{};
        const previous_review: ?ReviewResult = if (carry) self.reviewValue() else null;
        const ticks: []FileTick = if (previous_review) |previous|
            carryTicks(allocator, parsed.value, previous, self.ticks) catch empty_ticks
        else
            defaultTicks(allocator, parsed.value) catch empty_ticks;
        const expanded: []bool = allocator.alloc(bool, reviewFileCount(parsed.value)) catch empty_flags;
        @memset(expanded, false);
        // Keep expansion for files still present after a reload.
        if (previous_review) |previous| {
            var index: usize = 0;
            for (parsed.value.repos) |repo| {
                for (repo.files) |file| {
                    defer index += 1;
                    if (index >= expanded.len) break;
                    var old_index: usize = 0;
                    outer: for (previous.repos) |old_repo| {
                        for (old_repo.files) |old_file| {
                            defer old_index += 1;
                            if (std.mem.eql(u8, old_repo.root, repo.root) and std.mem.eql(u8, old_file.path, file.path)) {
                                if (old_index < self.expanded.len) expanded[index] = self.expanded[old_index];
                                break :outer;
                            }
                        }
                    }
                }
            }
        }
        if (self.review) |*previous| previous.deinit();
        self.tick_arena.deinit();
        self.tick_arena = next_arena;
        self.review = parsed;
        self.ticks = ticks;
        self.expanded = expanded;
    }
};

pub const QuickPhase = enum {
    /// Loading the review that decides the path.
    reviewing,
    /// The default-branch confirmation is up.
    confirming,
    /// Waiting for the generated message before committing.
    writing,
    committing,
    pushing,
    pull_pushing,
};

/// One header-initiated git action (Commit & push, Push, Pull & push). At
/// most one runs at a time; it never opens the sheet unless files need a
/// decision.
pub const Quick = struct {
    phase: QuickPhase,
    workspace_id: []u8 = &.{},
    local_thread_id: []u8 = &.{},
    review: ?std.json.Parsed(proto.ReviewResult) = null,
    generated_storage: [MESSAGE_CAPACITY]u8 = undefined,
    generated_len: usize = 0,
    branch_storage: [128]u8 = undefined,
    branch_len: usize = 0,
    message_status: MessageStatus = .idle,
    /// Commit requested before the message landed; the value is `new_branch`.
    pending_new_branch: ?bool = null,
    /// Repositories still to push (Push), in order.
    push_roots: std.ArrayList([]u8) = .empty,
    pushed: u32 = 0,
    /// Branch name for the confirmation title.
    branch_buf: [128]u8 = undefined,
    branch_name_len: usize = 0,
    files: usize = 0,
    /// Commit & push (true) or plain Commit (false).
    push: bool = true,
    /// Shared/unclear files the quick commit leaves out.
    left_out: usize = 0,
    /// The message request waits for an aborted action's request to land.
    message_queued: bool = false,
    /// Push: commits ahead across the pushed repositories, and the first
    /// one's upstream and name, for the outcome toast.
    push_commits: u32 = 0,
    upstream_buf: [128]u8 = undefined,
    upstream_len: usize = 0,
    repo_name_buf: [128]u8 = undefined,
    repo_name_len: usize = 0,

    fn deinit(self: *Quick) void {
        page.free(self.workspace_id);
        page.free(self.local_thread_id);
        if (self.review) |*parsed| parsed.deinit();
        for (self.push_roots.items) |root| page.free(root);
        self.push_roots.deinit(page);
        self.* = undefined;
    }

    pub fn generated(self: *const Quick) []const u8 {
        return self.generated_storage[0..self.generated_len];
    }

    pub fn branchName(self: *const Quick) []const u8 {
        return if (self.branch_name_len > 0) self.branch_buf[0..self.branch_name_len] else "main";
    }

    fn branchSuggestion(self: *const Quick) ?[]const u8 {
        return if (self.branch_len > 0) self.branch_storage[0..self.branch_len] else null;
    }

    /// Toast text while the action runs; null while the confirmation is up.
    pub fn progressText(self: *const Quick) ?[]const u8 {
        return switch (self.phase) {
            .confirming => null,
            .reviewing => "Checking changes\u{2026}",
            .writing => "Writing message\u{2026}",
            .committing => if (self.push) "Committing & pushing\u{2026}" else "Committing\u{2026}",
            .pushing => "Pushing\u{2026}",
            .pull_pushing => "Pulling & pushing\u{2026}",
        };
    }
};

const StatusEntry = struct {
    local_thread_id: []u8,
    parsed: std.json.Parsed(proto.StatusResult),

    fn deinit(self: *StatusEntry) void {
        page.free(self.local_thread_id);
        self.parsed.deinit();
    }
};

/// Branch status is cached for this many chats; the oldest is dropped.
const MAX_STATUS_ENTRIES: usize = 32;

pub const State = struct {
    lanes: [LANE_COUNT]Lane = [_]Lane{.{}} ** LANE_COUNT,
    summaries: std.ArrayList(SummaryEntry) = .empty,
    /// Workspaces waiting for a summary call while one is in flight.
    summary_queue: std.ArrayList([]u8) = .empty,
    /// The daemon does not know `git.changes.*` (older build).
    disabled: bool = false,
    sheet: ?*Sheet = null,
    /// Bumps on every sheet open/close so late results are dropped.
    generation: u64 = 0,
    /// A settings write arrived while another was in flight.
    config_write_pending: bool = false,
    /// Workspaces whose summary was requested at least once; later refreshes
    /// come from journal activity, focus, and commits.
    requested: std.ArrayList([]u8) = .empty,
    /// `git.changes.status` per chat, for the header button and menu.
    statuses: std.ArrayList(StatusEntry) = .empty,
    /// Chats waiting for a status call while one is in flight.
    status_queue: std.ArrayList([]u8) = .empty,
    /// Chats whose status was requested at least once.
    status_requested: std.ArrayList([]u8) = .empty,
    /// The daemon does not know `git.changes.status`.
    status_disabled: bool = false,
    /// The running header action, if any.
    quick: ?*Quick = null,
    /// Bumps whenever `quick` starts or is dropped so late results are ignored.
    quick_generation: u64 = 0,
    /// Outcome card of the last finished git action, until it expires or is
    /// dismissed.
    toast: ?Toast = null,
    /// Chat and repository whose last push was rejected (offers Pull & push).
    rejected_thread: ?[]u8 = null,
    rejected_root: ?[]u8 = null,
    rejected_workspace: ?[]u8 = null,
    /// Pointer hover target across the sheet and confirmation, so hover
    /// styling repaints only when it changes.
    hover_action: u16 = 0,
    hover_index: usize = 0,
    hover_valid: bool = false,

    pub fn deinit(self: *State) void {
        for (&self.lanes) |*entry| {
            entry.lock();
            entry.mutex.unlock();
            entry.join();
        }
        for (self.summaries.items) |*entry| entry.deinit();
        self.summaries.deinit(page);
        for (self.summary_queue.items) |id| page.free(id);
        self.summary_queue.deinit(page);
        for (self.requested.items) |id| page.free(id);
        self.requested.deinit(page);
        for (self.statuses.items) |*entry| entry.deinit();
        self.statuses.deinit(page);
        for (self.status_queue.items) |id| page.free(id);
        self.status_queue.deinit(page);
        for (self.status_requested.items) |id| page.free(id);
        self.status_requested.deinit(page);
        if (self.quick) |quick| {
            quick.deinit();
            page.destroy(quick);
        }
        self.quick = null;
        self.clearRejected();
        if (self.sheet) |sheet| {
            sheet.deinit();
            page.destroy(sheet);
        }
        self.sheet = null;
    }

    /// The review sheet or the default-branch confirmation is up.
    pub fn overlayOpen(self: *const State) bool {
        return self.sheet != null or self.confirmOpen();
    }

    pub fn confirmOpen(self: *const State) bool {
        const quick = self.quick orelse return false;
        return quick.phase == .confirming;
    }

    pub fn threadStatus(self: *const State, local_thread_id: []const u8) ?proto.StatusResult {
        for (self.statuses.items) |entry| {
            if (std.mem.eql(u8, entry.local_thread_id, local_thread_id)) return entry.parsed.value;
        }
        return null;
    }

    pub fn threadFacts(self: *const State, local_thread_id: []const u8) ?RepoFacts {
        const status = self.threadStatus(local_thread_id) orelse return null;
        return repoFacts(status.repos);
    }

    /// Cached branch of one of the chat's repositories, or "".
    pub fn repoBranch(self: *const State, local_thread_id: []const u8, root: []const u8) []const u8 {
        const status = self.threadStatus(local_thread_id) orelse return "";
        for (status.repos) |repo| {
            if (std.mem.eql(u8, repo.root, root)) return repo.branch orelse "";
        }
        return "";
    }

    pub fn rejectedFor(self: *const State, local_thread_id: []const u8) bool {
        const thread = self.rejected_thread orelse return false;
        return std.mem.eql(u8, thread, local_thread_id);
    }

    fn clearRejected(self: *State) void {
        if (self.rejected_thread) |value| page.free(value);
        if (self.rejected_root) |value| page.free(value);
        if (self.rejected_workspace) |value| page.free(value);
        self.rejected_thread = null;
        self.rejected_root = null;
        self.rejected_workspace = null;
    }

    fn setRejected(self: *State, workspace_id: []const u8, local_thread_id: []const u8, root: []const u8) void {
        self.clearRejected();
        const thread = page.dupe(u8, local_thread_id) catch return;
        const owned_root = page.dupe(u8, root) catch {
            page.free(thread);
            return;
        };
        const workspace = page.dupe(u8, workspace_id) catch {
            page.free(thread);
            page.free(owned_root);
            return;
        };
        self.rejected_thread = thread;
        self.rejected_root = owned_root;
        self.rejected_workspace = workspace;
    }

    fn storeStatus(self: *State, parsed: std.json.Parsed(proto.StatusResult)) void {
        var incoming = parsed;
        for (self.statuses.items) |*entry| {
            if (!std.mem.eql(u8, entry.local_thread_id, incoming.value.local_thread_id)) continue;
            entry.parsed.deinit();
            entry.parsed = incoming;
            return;
        }
        const id = page.dupe(u8, incoming.value.local_thread_id) catch {
            incoming.deinit();
            return;
        };
        if (self.statuses.items.len >= MAX_STATUS_ENTRIES) {
            var oldest = self.statuses.orderedRemove(0);
            oldest.deinit();
        }
        self.statuses.append(page, .{ .local_thread_id = id, .parsed = incoming }) catch {
            page.free(id);
            incoming.deinit();
        };
    }

    fn lane(self: *State, id: LaneId) *Lane {
        return &self.lanes[@intFromEnum(id)];
    }

    pub fn threadSummary(self: *const State, local_thread_id: []const u8) ?ThreadSummary {
        for (self.summaries.items) |entry| {
            for (entry.parsed.value.threads) |row| {
                if (std.mem.eql(u8, row.local_thread_id, local_thread_id)) return row;
            }
        }
        return null;
    }

    fn storeSummary(self: *State, parsed: std.json.Parsed(proto.SummaryResult)) bool {
        var incoming = parsed;
        for (self.summaries.items) |*entry| {
            if (!std.mem.eql(u8, entry.workspace_id, incoming.value.workspace_id)) continue;
            if (entry.parsed.value.revision == incoming.value.revision and incoming.value.revision != 0) {
                incoming.deinit();
                return false;
            }
            entry.parsed.deinit();
            entry.parsed = incoming;
            return true;
        }
        const id = page.dupe(u8, incoming.value.workspace_id) catch {
            incoming.deinit();
            return false;
        };
        self.summaries.append(page, .{ .workspace_id = id, .parsed = incoming }) catch {
            page.free(id);
            incoming.deinit();
            return false;
        };
        return true;
    }
};

fn spawn(self: anytype, lane_id: LaneId, job: Job, params: anytype, tag: []const u8, options: struct {
    timeout_ms: u32 = GIT_TIMEOUT_MS,
    delay_ms: u64 = 0,
    generation: u64 = 0,
}) bool {
    const state = &self.git_changes;
    const lane = state.lane(lane_id);
    if (lane.busy()) return false;
    lane.join();
    const params_json = std.json.Stringify.valueAlloc(page, params, .{ .emit_null_optional_fields = false }) catch return false;
    const request = page.create(Request) catch {
        page.free(params_json);
        return false;
    };
    request.* = .{
        .job = job,
        .pref_path = page.dupe(u8, self.storage.pref_path) catch {
            page.free(params_json);
            page.destroy(request);
            return false;
        },
        .params_json = params_json,
        .timeout_ms = options.timeout_ms,
        .delay_ms = options.delay_ms,
        .generation = options.generation,
        .tag = page.dupe(u8, tag) catch {
            page.free(params_json);
            page.free(request.pref_path);
            page.destroy(request);
            return false;
        },
    };
    lane.lock();
    lane.request = request;
    lane.status = .pending;
    lane.worker = std.Thread.spawn(.{}, worker, .{ lane, request }) catch {
        lane.request = null;
        lane.status = .idle;
        lane.mutex.unlock();
        request.deinit();
        return false;
    };
    lane.mutex.unlock();
    return true;
}

// ------------------------------------------------------------------
// AppState-facing API (self is *AppState)
// ------------------------------------------------------------------

/// Refreshes one workspace's change summary. Calls are coalesced: while one
/// is in flight, later requests queue once per workspace.
pub fn refreshGitChangesSummary(self: anytype, workspace_id: []const u8, debounce: bool) void {
    const state = &self.git_changes;
    if (state.disabled or workspace_id.len == 0) return;
    if (spawn(self, .summary, .summary, proto.SummaryRequest{ .workspace_id = workspace_id }, workspace_id, .{
        .delay_ms = if (debounce) SUMMARY_DEBOUNCE_MS else 0,
    })) return;
    for (state.summary_queue.items) |queued| {
        if (std.mem.eql(u8, queued, workspace_id)) return;
    }
    const owned = page.dupe(u8, workspace_id) catch return;
    state.summary_queue.append(page, owned) catch page.free(owned);
}

/// Fetches a workspace's summary the first time it is shown. Safe to call
/// every frame: it only issues one request per workspace.
pub fn ensureGitChangesSummary(self: anytype, workspace_id: []const u8) void {
    const state = &self.git_changes;
    if (state.disabled or workspace_id.len == 0) return;
    for (state.requested.items) |id| {
        if (std.mem.eql(u8, id, workspace_id)) return;
    }
    const owned = page.dupe(u8, workspace_id) catch return;
    state.requested.append(page, owned) catch {
        page.free(owned);
        return;
    };
    refreshGitChangesSummary(self, workspace_id, false);
}

/// Refreshes the selected workspace's summary.
pub fn refreshSelectedWorkspaceGitChanges(self: anytype, debounce: bool) void {
    if (self.project_controller.projects.items.len == 0) return;
    const index = @min(self.project_controller.selected_index, self.project_controller.projects.items.len - 1);
    const project = &self.project_controller.projects.items[index];
    refreshGitChangesSummary(self, project.id, debounce);
}

/// `chat.turn` journal activity: chats may have edited files.
pub fn noteGitChangesJournalActivity(self: anytype) void {
    refreshSelectedWorkspaceGitChanges(self, true);
}

pub fn gitChangesThreadSummary(self: anytype, local_thread_id: []const u8) ?ThreadSummary {
    return self.git_changes.threadSummary(local_thread_id);
}

const ThreadRef = struct { project_index: usize, thread_index: usize };

fn findThread(self: anytype, local_thread_id: []const u8) ?ThreadRef {
    if (local_thread_id.len == 0) return null;
    for (self.project_controller.projects.items, 0..) |*project, project_index| {
        for (project.threads.items, 0..) |*thread, thread_index| {
            if (std.mem.eql(u8, thread.local_thread_id, local_thread_id)) {
                return .{ .project_index = project_index, .thread_index = thread_index };
            }
        }
    }
    return null;
}

fn focusedThreadRef(self: anytype) ?ThreadRef {
    const projects = self.project_controller.projects.items;
    if (projects.len == 0) return null;
    const project_index = self.project_controller.selected_index;
    if (project_index >= projects.len) return null;
    const pane_id = self.focusedWorkspaceChatPaneId() orelse return null;
    const thread_index = self.workspaceChatThreadIndexByPane(pane_id) orelse return null;
    if (thread_index >= projects[project_index].threads.items.len) return null;
    return .{ .project_index = project_index, .thread_index = thread_index };
}

/// `git.changes.review` params for a chat: its own route so the chat's
/// repository is inspected even before any change was attributed.
fn reviewRequestFor(project: anytype, thread: anytype) proto.ReviewRequest {
    const route = thread.selectedRuntimeRoute();
    return .{
        .workspace_id = project.id,
        .local_thread_id = thread.local_thread_id,
        .repository_id = route.repository_id,
        .relative_cwd = route.relative_cwd,
        .project_path = project.path,
        .cwd = thread.cwd,
        .include_unassigned = true,
    };
}

fn runsLocally(thread: anytype) bool {
    return std.mem.eql(u8, thread.selectedRuntimeRoute().profile_id, chat_types.LOCAL_RUNTIME_PROFILE_ID);
}

// ---- Branch status (header button) --------------------------------

/// Refreshes one chat's branch status (`git.changes.status`). Calls are
/// coalesced like summaries: while one is in flight, later chats queue once.
pub fn refreshGitChangesStatus(self: anytype, local_thread_id: []const u8) void {
    const state = &self.git_changes;
    if (state.disabled or state.status_disabled) return;
    const ref = findThread(self, local_thread_id) orelse return;
    const project = &self.project_controller.projects.items[ref.project_index];
    const thread = &project.threads.items[ref.thread_index];
    if (!thread.committed or !runsLocally(thread)) return;
    const review = reviewRequestFor(project, thread);
    const params = proto.StatusRequest{
        .workspace_id = review.workspace_id,
        .local_thread_id = review.local_thread_id,
        .repository_id = review.repository_id,
        .relative_cwd = review.relative_cwd,
        .project_path = review.project_path,
        .cwd = review.cwd,
    };
    if (spawn(self, .status, .status, params, local_thread_id, .{})) return;
    for (state.status_queue.items) |queued| {
        if (std.mem.eql(u8, queued, local_thread_id)) return;
    }
    const owned = page.dupe(u8, local_thread_id) catch return;
    state.status_queue.append(page, owned) catch page.free(owned);
}

/// Fetches a chat's branch status the first time its header is drawn. Safe
/// to call every frame; later refreshes follow summaries, commits and pushes.
pub fn ensureGitChangesStatus(self: anytype, local_thread_id: []const u8) void {
    const state = &self.git_changes;
    if (state.disabled or state.status_disabled or local_thread_id.len == 0) return;
    for (state.status_requested.items) |id| {
        if (std.mem.eql(u8, id, local_thread_id)) return;
    }
    const owned = page.dupe(u8, local_thread_id) catch return;
    state.status_requested.append(page, owned) catch {
        page.free(owned);
        return;
    };
    refreshGitChangesStatus(self, local_thread_id);
}

/// A summary for `workspace_id` changed: the focused chat's branch facts
/// may have too.
fn refreshFocusedStatus(self: anytype, workspace_id: []const u8) void {
    const ref = focusedThreadRef(self) orelse return;
    const project = &self.project_controller.projects.items[ref.project_index];
    if (!std.mem.eql(u8, project.id, workspace_id)) return;
    refreshGitChangesStatus(self, project.threads.items[ref.thread_index].local_thread_id);
}

pub const HeaderMenu = struct {
    can_commit: bool = false,
    can_push: bool = false,
    can_pull_push: bool = false,
    /// A header git action is running (for any chat); actions are disabled.
    busy: bool = false,
};

pub const HeaderView = struct {
    button: ?HeaderButton = null,
    /// Progress label while this chat's header action runs.
    busy_label: ?[]const u8 = null,
    menu: HeaderMenu = .{},
};

/// Everything the chat header needs to draw its git split button and menu.
pub fn gitChangesHeader(self: anytype, local_thread_id: []const u8) HeaderView {
    const state = &self.git_changes;
    const summary = state.threadSummary(local_thread_id);
    const facts = state.threadFacts(local_thread_id);
    var view: HeaderView = .{
        .button = headerButton(summary, facts, Action.fromConfig(self.app_config.commit_default_action)),
        .menu = .{
            .can_commit = if (summary) |row| row.files > 0 else false,
            .can_push = if (facts) |known| known.canPush() else false,
            .can_pull_push = state.rejectedFor(local_thread_id),
            .busy = state.quick != null or state.sheet != null,
        },
    };
    if (state.quick) |quick| {
        if (std.mem.eql(u8, quick.local_thread_id, local_thread_id)) view.busy_label = quick.progressText();
    }
    return view;
}

/// The header button's main part: runs the action its label names.
pub fn gitHeaderPrimary(self: anytype, local_thread_id: []const u8) void {
    const view = gitChangesHeader(self, local_thread_id);
    const button = view.button orelse return;
    if (view.menu.busy) return;
    switch (button.kind) {
        .commit => startCommit(self, local_thread_id),
        .commit_and_push => startCommitAndPush(self, local_thread_id),
        .push => startPush(self, local_thread_id),
    }
}

// ---- Review sheet ---------------------------------------------------

pub fn commitSheet(self: anytype) ?*Sheet {
    return self.git_changes.sheet;
}

/// The review sheet or the default-branch confirmation owns input.
pub fn commitSheetOpen(self: anytype) bool {
    return self.git_changes.overlayOpen();
}

/// Opens the review sheet for one chat with Commit as the primary action.
pub fn openCommitSheet(self: anytype, project_index: usize, thread_index: usize) void {
    openCommitSheetMode(self, project_index, thread_index, .commit);
}

/// Opens the review sheet for one chat. The review loads in the background.
pub fn openCommitSheetMode(self: anytype, project_index: usize, thread_index: usize, mode: Action) void {
    if (project_index >= self.project_controller.projects.items.len) return;
    const project = &self.project_controller.projects.items[project_index];
    if (thread_index >= project.threads.items.len) return;
    const thread = &project.threads.items[thread_index];
    const state = &self.git_changes;
    if (!thread.committed) {
        self.setSidebarNotice("This chat has no saved changes yet.");
        return;
    }
    if (state.quick != null) {
        self.setSidebarNotice("Another git action is still running.");
        return;
    }
    closeCommitSheetSilently(self);
    const sheet = page.create(Sheet) catch return;
    sheet.* = .{ .mode = mode };
    const params = reviewRequestFor(project, thread);
    sheet.review_params = std.json.Stringify.valueAlloc(page, params, .{ .emit_null_optional_fields = false }) catch &.{};
    sheet.workspace_id = page.dupe(u8, project.id) catch &.{};
    sheet.local_thread_id = page.dupe(u8, thread.local_thread_id) catch &.{};
    sheet.thread_title = page.dupe(u8, thread.title) catch &.{};
    state.generation +%= 1;
    state.sheet = sheet;
    if (!runsLocally(thread)) {
        sheet.phase = .load_error;
        sheet.setErrorText("Reviewing changes is only available for chats that run on this machine.");
        self.markDirty();
        return;
    }
    loadReview(self, false);
    self.markDirty();
}

/// Opens the sheet for the focused workspace chat pane.
pub fn openCommitSheetForFocusedChat(self: anytype) bool {
    const ref = focusedThreadRef(self) orelse return false;
    openCommitSheet(self, ref.project_index, ref.thread_index);
    return true;
}

/// Opens the sheet (Commit) for a chat identified by its thread id.
pub fn openCommitSheetForThreadId(self: anytype, local_thread_id: []const u8) void {
    openCommitSheetForThreadIdMode(self, local_thread_id, .commit);
}

pub fn openCommitSheetForThreadIdMode(self: anytype, local_thread_id: []const u8, mode: Action) void {
    const ref = findThread(self, local_thread_id) orelse return;
    openCommitSheetMode(self, ref.project_index, ref.thread_index, mode);
}

fn closeCommitSheetSilently(self: anytype) void {
    const state = &self.git_changes;
    const sheet = state.sheet orelse return;
    state.generation +%= 1;
    if (self.palette_modal_text_focus == .commit_message) self.palette_modal_text_focus = .none;
    sheet.deinit();
    page.destroy(sheet);
    state.sheet = null;
}

/// Closes the sheet (or dismisses the default-branch confirmation) and
/// refreshes the header for its chat.
pub fn closeCommitSheet(self: anytype) void {
    const state = &self.git_changes;
    const sheet = state.sheet orelse {
        if (state.confirmOpen()) gitQuickAbort(self);
        return;
    };
    const workspace_id = page.dupe(u8, sheet.workspace_id) catch null;
    defer if (workspace_id) |id| page.free(id);
    const thread_id = page.dupe(u8, sheet.local_thread_id) catch null;
    defer if (thread_id) |id| page.free(id);
    closeCommitSheetSilently(self);
    if (workspace_id) |id| refreshGitChangesSummary(self, id, false);
    if (thread_id) |id| refreshGitChangesStatus(self, id);
    self.markDirty();
}

fn loadReview(self: anytype, carry: bool) void {
    const state = &self.git_changes;
    const sheet = state.sheet orelse return;
    if (!carry) sheet.phase = .loading;
    var params = std.json.parseFromSlice(std.json.Value, page, sheet.review_params, .{}) catch {
        sheet.phase = .load_error;
        sheet.setErrorText("Could not build the review request.");
        return;
    };
    defer params.deinit();
    if (!spawn(self, .sheet, .review, params.value, if (carry) "carry" else "", .{ .generation = state.generation })) {
        if (!carry) sheet.phase = .load_error;
        sheet.setErrorText("Another git action is still running. Try again in a moment.");
    }
}

pub fn reloadCommitSheet(self: anytype) void {
    const sheet = self.git_changes.sheet orelse return;
    sheet.error_len = 0;
    loadReview(self, sheet.review != null);
    self.markDirty();
}

/// Edit switches the file list between the plain list and per-file/per-hunk
/// ticks. Leaving it regenerates the placeholder message when the selection
/// changed and nothing was typed.
pub fn commitSheetToggleEditing(self: anytype) void {
    const sheet = self.git_changes.sheet orelse return;
    if (sheet.locked() or sheet.phase != .ready) return;
    // "Show diffs" / "Hide diffs": expand or collapse every file's hunks.
    // Ticking works either way.
    sheet.editing = !sheet.editing;
    @memset(sheet.expanded, sheet.editing);
    sheet.scroll_y = 0;
    if (!sheet.editing and sheet.message().len == 0 and selectionHash(sheet.ticks) != sheet.message_selection) {
        generateCommitMessage(self, false);
    }
    self.markDirty();
}

pub fn commitSheetToggleFile(self: anytype, flat_index: usize) void {
    const sheet = self.git_changes.sheet orelse return;
    if (sheet.locked()) return;
    const found = sheet.fileAt(flat_index) orelse return;
    if (flat_index >= sheet.ticks.len) return;
    sheet.ticks[flat_index].toggle(found.file);
    self.markDirty();
}

pub fn commitSheetToggleHunk(self: anytype, flat_index: usize, hunk_position: usize) void {
    const sheet = self.git_changes.sheet orelse return;
    if (sheet.locked()) return;
    const found = sheet.fileAt(flat_index) orelse return;
    if (flat_index >= sheet.ticks.len) return;
    sheet.ticks[flat_index].toggleHunk(found.file, hunk_position);
    self.markDirty();
}

pub fn commitSheetToggleExpanded(self: anytype, flat_index: usize) void {
    const sheet = self.git_changes.sheet orelse return;
    if (flat_index >= sheet.expanded.len) return;
    sheet.expanded[flat_index] = !sheet.expanded[flat_index];
    self.markDirty();
}

/// Asks the provider for a message covering the ticked files. It fills the
/// placeholder; an explicit ↻ also clears what the user typed so the new
/// message shows.
pub fn generateCommitMessage(self: anytype, explicit: bool) void {
    const state = &self.git_changes;
    const sheet = state.sheet orelse return;
    const review = sheet.reviewValue() orelse return;
    var arena: std.heap.ArenaAllocator = .init(page);
    defer arena.deinit();
    const selections = buildSelections(arena.allocator(), review, sheet.ticks) catch return;
    if (selections.len == 0) {
        if (explicit) {
            sheet.setErrorText("Select at least one file to write a message for.");
            self.markDirty();
        }
        return;
    }
    sheet.message_generation +%= 1;
    const tag: []const u8 = if (explicit) "explicit" else "auto";
    if (!spawn(self, .message, .commit_message, proto.CommitMessageRequest{
        .review_id = review.review_id,
        .selections = selections,
    }, tag, .{ .timeout_ms = MESSAGE_TIMEOUT_MS, .generation = state.generation })) {
        // A request is already running; ask again once it lands.
        sheet.message_rerun = explicit or (sheet.message_rerun orelse false);
        sheet.message_status = .writing;
        self.markDirty();
        return;
    }
    sheet.message_selection = selectionHash(sheet.ticks);
    sheet.message_status = .writing;
    self.markDirty();
}

/// Commit (or Commit & push, per the sheet's mode) the ticked files. An empty
/// message box commits the generated message; when that is still being
/// written (or no longer matches the selection) the commit waits for it.
pub fn commitSheetCommit(self: anytype, new_branch: bool) void {
    const sheet = self.git_changes.sheet orelse return;
    commitSheetCommitAs(self, sheet.mode, new_branch);
}

/// The footer's other action: Commit & push from a Commit sheet, or plain
/// Commit from a Commit & push sheet.
pub fn commitSheetCommitAlternate(self: anytype) void {
    const sheet = self.git_changes.sheet orelse return;
    if (!sheetHasRemote(sheet) and sheet.mode == .commit) return;
    commitSheetCommitAs(self, sheet.mode.other(), false);
}

/// Some repository in the review can be pushed to.
pub fn sheetHasRemote(sheet: *const Sheet) bool {
    const review = sheet.reviewValue() orelse return false;
    for (review.repos) |repo| if (repo.has_remote) return true;
    return false;
}

fn commitSheetCommitAs(self: anytype, action: Action, new_branch: bool) void {
    const state = &self.git_changes;
    const sheet = state.sheet orelse return;
    if (sheet.locked() or sheet.phase != .ready) return;
    if (sheet.selectedFileCount() == 0) {
        sheet.setErrorText("Select at least one file to commit.");
        self.markDirty();
        return;
    }
    sheet.error_len = 0;
    if (std.mem.trim(u8, sheet.message(), " \t\r\n").len == 0) {
        const stale = selectionHash(sheet.ticks) != sheet.message_selection;
        if (sheet.message_status == .writing or stale or sheet.generated_len == 0) {
            if (sheet.message_status == .failed and !stale) {
                sheet.setErrorText("Couldn't write a commit message. Type one, then commit.");
                self.markDirty();
                return;
            }
            if (sheet.message_status != .writing or stale) generateCommitMessage(self, false);
            sheet.pending_new_branch = new_branch;
            sheet.pending_action = action;
            self.markDirty();
            return;
        }
    }
    spawnSheetCommit(self, new_branch, action);
}

fn spawnSheetCommit(self: anytype, new_branch: bool, action: Action) void {
    const state = &self.git_changes;
    const sheet = state.sheet orelse return;
    sheet.pending_new_branch = null;
    const review = sheet.reviewValue() orelse return;
    const message = sheet.messageToCommit() orelse {
        sheet.setErrorText("Write a commit message first.");
        self.markDirty();
        return;
    };
    var arena: std.heap.ArenaAllocator = .init(page);
    defer arena.deinit();
    const selections = buildSelections(arena.allocator(), review, sheet.ticks) catch return;
    if (selections.len == 0) {
        sheet.setErrorText("Select at least one file to commit.");
        self.markDirty();
        return;
    }
    const push = action == .commit_and_push;
    if (!spawn(self, .sheet, .commit, proto.CommitRequest{
        .review_id = review.review_id,
        .message = message,
        .selections = selections,
        .push = push,
        .new_branch = new_branch,
        .branch_name = if (new_branch) sheet.branchSuggestion() else null,
    }, "", .{
        .timeout_ms = if (push) PUSH_TIMEOUT_MS else GIT_TIMEOUT_MS,
        .generation = state.generation,
    })) {
        sheet.setErrorText("Another git action is still running. Try again in a moment.");
        self.markDirty();
        return;
    }
    sheet.busy = action;
    sheet.busy_new_branch = new_branch;
    sheet.error_len = 0;
    state.toast = null;
    self.markDirty();
}

pub fn commitSheetPrimaryAction(self: anytype) Action {
    const sheet = self.git_changes.sheet orelse return Action.fromConfig(self.app_config.commit_default_action);
    return sheet.mode;
}

/// Pull & push for the repository whose push was rejected.
pub fn commitSheetPullPush(self: anytype) void {
    const state = &self.git_changes;
    const sheet = state.sheet orelse return;
    const root = sheet.pull_push_root orelse return;
    if (sheet.pull_push_busy) return;
    if (!spawn(self, .sheet, .pull_push, proto.PullPushRequest{
        .workspace_id = sheet.workspace_id,
        .root = root,
        .local_thread_id = sheet.local_thread_id,
    }, sheet.workspace_id, .{ .timeout_ms = PUSH_TIMEOUT_MS, .generation = state.generation })) {
        sheet.setErrorText("Another git action is still running. Try again in a moment.");
        self.markDirty();
        return;
    }
    sheet.pull_push_busy = true;
    sheet.error_len = 0;
    state.toast = null;
    self.markDirty();
}

// ---- Header quick actions -----------------------------------------

/// The Push button on a transcript commit card.
pub const CardPush = enum { hidden, available, running };

/// Push shows on a commit card whose row is not marked pushed, when the
/// chat's branch can push (commits ahead or unpublished) to a remote. While a
/// push or pull & push from this chat runs it shows as a spinner.
pub fn cardPushState(row_pushed: bool, row_has_remote: bool, facts: ?RepoFacts, running: bool) CardPush {
    if (row_pushed) return .hidden;
    if (running) return .running;
    const known = facts orelse return .hidden;
    if (!row_has_remote and !known.has_remote) return .hidden;
    return if (known.canPush()) .available else .hidden;
}

pub fn gitCommitCardPush(self: anytype, local_thread_id: []const u8, row_pushed: bool, row_has_remote: bool) CardPush {
    const state = &self.git_changes;
    const running = if (state.quick) |quick|
        (quick.phase == .pushing or quick.phase == .pull_pushing) and std.mem.eql(u8, quick.local_thread_id, local_thread_id)
    else
        false;
    return cardPushState(row_pushed, row_has_remote, state.threadFacts(local_thread_id), running);
}

/// The running header action's toast text, if any.
pub fn gitQuickProgressText(self: anytype) ?[]const u8 {
    const quick = self.git_changes.quick orelse return null;
    return quick.progressText();
}

/// The default-branch confirmation, when it is up.
pub fn gitQuickConfirm(self: anytype) ?*const Quick {
    const quick = self.git_changes.quick orelse return null;
    return if (quick.phase == .confirming) quick else null;
}

// ---- Outcome toast --------------------------------------------------

/// What the bottom git toast draws this frame.
pub const ToastView = struct {
    tone: ToastTone,
    title: []const u8,
    detail: []const u8 = "",
    /// Show the Pull & push button (rejected push).
    pull_push: bool = false,
    /// Running toasts have no × and ignore clicks.
    dismissible: bool = true,
    alpha: f32 = 1.0,
    rise: f32 = 1.0,
};

fn toastNowMs() i64 {
    return @intCast(platform_runtime.monotonicTimestampNs() / std.time.ns_per_ms);
}

fn toastHold(toast: *const Toast) ?i64 {
    return if (toast.tone == .success) TOAST_SUCCESS_HOLD_MS else null;
}

/// The running git action's progress, else the last outcome until it
/// expires (success) or is dismissed (warning, failure).
pub fn gitToastView(self: anytype) ?ToastView {
    const state = &self.git_changes;
    if (state.quick) |quick| {
        if (quick.progressText()) |text| {
            const detail: []const u8 = switch (quick.phase) {
                .committing, .pushing => if (quick.branch_name_len > 0) quick.branchName() else "",
                else => "",
            };
            return .{ .tone = .running, .title = text, .detail = detail, .dismissible = false };
        }
    }
    if (state.sheet) |sheet| {
        if (sheet.busy) |busy| return .{ .tone = .running, .title = busy.busyLabel(), .dismissible = false };
        if (sheet.pull_push_busy) return .{ .tone = .running, .title = "Pulling & pushing\u{2026}", .dismissible = false };
    }
    if (state.toast) |*toast| {
        const phase = toastPhase(toastNowMs() - toast.shown_at_ms, toastHold(toast)) orelse return null;
        return .{
            .tone = toast.tone,
            .title = toast.title(),
            .detail = toast.detail(),
            .pull_push = toast.pullPushThread() != null,
            .alpha = phase.alpha,
            .rise = phase.rise,
        };
    }
    return null;
}

/// True during the toast's slide-in and fade-out only.
pub fn gitToastAnimating(self: anytype) bool {
    const view = gitToastView(self) orelse return false;
    if (view.tone == .running) return false;
    return view.alpha < 1.0 or view.rise < 1.0;
}

/// Next wake the toast needs: a spinner step while running, or the fade
/// start of a held success toast.
pub fn gitToastWakeMs(self: anytype) ?i64 {
    const view = gitToastView(self) orelse return null;
    if (view.tone == .running) return TOAST_SPINNER_STEP_MS;
    const toast = if (self.git_changes.toast) |*value| value else return null;
    const hold = toastHold(toast) orelse return null;
    const remaining = hold - TOAST_OUT_MS - (toastNowMs() - toast.shown_at_ms);
    return if (remaining > 0) remaining else null;
}

fn showToast(self: anytype, toast: Toast) void {
    var value = toast;
    value.shown_at_ms = toastNowMs();
    self.git_changes.toast = value;
    self.markDirty();
    loop_wakeup.notify();
}

/// × or a click on the card.
pub fn dismissGitToast(self: anytype) void {
    if (self.git_changes.toast == null) return;
    self.git_changes.toast = null;
    self.markDirty();
}

/// The toast's Pull & push button.
pub fn gitToastPullPush(self: anytype) void {
    const toast = if (self.git_changes.toast) |*value| value else return;
    const thread = toast.pullPushThread() orelse return;
    var thread_buf: [128]u8 = undefined;
    const thread_id = copyInto(&thread_buf, thread);
    self.git_changes.toast = null;
    self.markDirty();
    startPullPush(self, thread_id);
}

fn beginQuick(self: anytype, ref: ThreadRef, phase: QuickPhase) ?*Quick {
    const state = &self.git_changes;
    if (state.quick != null) {
        self.setSidebarNotice("Another git action is still running.");
        return null;
    }
    if (state.sheet != null) return null;
    const project = &self.project_controller.projects.items[ref.project_index];
    const thread = &project.threads.items[ref.thread_index];
    if (!thread.committed) {
        self.setSidebarNotice("This chat has no saved changes yet.");
        return null;
    }
    if (!runsLocally(thread)) {
        self.setSidebarNotice("Committing is only available for chats that run on this machine.");
        return null;
    }
    const quick = page.create(Quick) catch return null;
    quick.* = .{ .phase = phase };
    quick.workspace_id = page.dupe(u8, project.id) catch &.{};
    quick.local_thread_id = page.dupe(u8, thread.local_thread_id) catch &.{};
    state.quick_generation +%= 1;
    state.quick = quick;
    state.toast = null;
    self.markDirty();
    return quick;
}

fn endQuick(self: anytype) void {
    const state = &self.git_changes;
    const quick = state.quick orelse return;
    state.quick_generation +%= 1;
    quick.deinit();
    page.destroy(quick);
    state.quick = null;
    self.markDirty();
}

/// Ends the quick action and opens the full review sheet (Commit & push)
/// for its chat, e.g. when a file needs a decision or no message came back.
fn quickFallbackToSheet(self: anytype, notice: ?[]const u8) void {
    const quick = self.git_changes.quick orelse return;
    var id_buf: [256]u8 = undefined;
    const len = @min(quick.local_thread_id.len, id_buf.len);
    @memcpy(id_buf[0..len], quick.local_thread_id[0..len]);
    const mode: Action = if (quick.push) .commit_and_push else .commit;
    endQuick(self);
    openCommitSheetForThreadIdMode(self, id_buf[0..len], mode);
    if (notice) |text| self.setSidebarNotice(text);
}

/// Refreshes summary and branch status for the quick action's chat.
fn refreshAfterQuick(self: anytype, workspace_id: []const u8, local_thread_id: []const u8) void {
    refreshGitChangesSummary(self, workspace_id, false);
    refreshGitChangesStatus(self, local_thread_id);
}

/// Commit & push: review, then commit this chat's own files (shared and
/// unclear ones are left out) after writing the message, confirming first on
/// the default branch. The sheet opens only when nothing is the chat's own.
pub fn startCommitAndPush(self: anytype, local_thread_id: []const u8) void {
    startQuickCommit(self, local_thread_id, true);
}

/// Plain Commit from the header: the quick path without pushing.
pub fn startCommit(self: anytype, local_thread_id: []const u8) void {
    startQuickCommit(self, local_thread_id, false);
}

fn startQuickCommit(self: anytype, local_thread_id: []const u8, push: bool) void {
    const ref = findThread(self, local_thread_id) orelse return;
    const state = &self.git_changes;
    const quick = beginQuick(self, ref, .reviewing) orelse return;
    quick.push = push;
    const project = &self.project_controller.projects.items[ref.project_index];
    const params = reviewRequestFor(project, &project.threads.items[ref.thread_index]);
    if (!spawn(self, .quick, .review, params, "", .{ .generation = state.quick_generation })) {
        endQuick(self);
        self.setSidebarNotice("Another git action is still running. Try again in a moment.");
    }
}

pub fn startCommitAndPushForFocusedChat(self: anytype) bool {
    const ref = focusedThreadRef(self) orelse return false;
    startCommitAndPush(self, self.project_controller.projects.items[ref.project_index].threads.items[ref.thread_index].local_thread_id);
    return true;
}

/// Push: re-reads branch status, then pushes every repository with commits
/// ahead (or without an upstream yet).
pub fn startPush(self: anytype, local_thread_id: []const u8) void {
    const ref = findThread(self, local_thread_id) orelse return;
    const state = &self.git_changes;
    _ = beginQuick(self, ref, .pushing) orelse return;
    const project = &self.project_controller.projects.items[ref.project_index];
    const review = reviewRequestFor(project, &project.threads.items[ref.thread_index]);
    const params = proto.StatusRequest{
        .workspace_id = review.workspace_id,
        .local_thread_id = review.local_thread_id,
        .repository_id = review.repository_id,
        .relative_cwd = review.relative_cwd,
        .project_path = review.project_path,
        .cwd = review.cwd,
    };
    if (!spawn(self, .quick, .status, params, "", .{ .generation = state.quick_generation })) {
        endQuick(self);
        self.setSidebarNotice("Another git action is still running. Try again in a moment.");
    }
}

pub fn startPushForFocusedChat(self: anytype) bool {
    const ref = focusedThreadRef(self) orelse return false;
    startPush(self, self.project_controller.projects.items[ref.project_index].threads.items[ref.thread_index].local_thread_id);
    return true;
}

/// Pull & push the repository whose last push from this chat was rejected.
pub fn startPullPush(self: anytype, local_thread_id: []const u8) void {
    const state = &self.git_changes;
    if (!state.rejectedFor(local_thread_id)) return;
    const ref = findThread(self, local_thread_id) orelse return;
    _ = beginQuick(self, ref, .pull_pushing) orelse return;
    if (!spawn(self, .quick, .pull_push, proto.PullPushRequest{
        .workspace_id = state.rejected_workspace orelse "",
        .root = state.rejected_root orelse "",
        .local_thread_id = local_thread_id,
    }, "", .{ .timeout_ms = PUSH_TIMEOUT_MS, .generation = state.quick_generation })) {
        endQuick(self);
        self.setSidebarNotice("Another git action is still running. Try again in a moment.");
    }
}

/// Confirmation buttons: continue on the default branch, or create a
/// feature branch (named from the generated suggestion) and commit there.
pub fn gitQuickContinue(self: anytype, new_branch: bool) void {
    const quick = self.git_changes.quick orelse return;
    if (quick.phase != .confirming) return;
    switch (quick.message_status) {
        .idle => if (quick.generated_len > 0) {
            quickCommit(self, new_branch);
        } else {
            quickFallbackToSheet(self, "Couldn't write a commit message. Type one to commit.");
        },
        .writing => {
            quick.phase = .writing;
            quick.pending_new_branch = new_branch;
            self.markDirty();
        },
        .failed => quickFallbackToSheet(self, "Couldn't write a commit message. Type one to commit."),
    }
}

/// Abort in the confirmation: nothing is committed.
pub fn gitQuickAbort(self: anytype) void {
    const quick = self.git_changes.quick orelse return;
    if (quick.phase != .confirming) return;
    endQuick(self);
}

fn requestQuickMessage(self: anytype) void {
    const state = &self.git_changes;
    const quick = state.quick orelse return;
    const parsed = quick.review orelse return;
    var arena: std.heap.ArenaAllocator = .init(page);
    defer arena.deinit();
    const allocator = arena.allocator();
    const ticks = defaultTicks(allocator, parsed.value) catch return;
    const selections = buildSelections(allocator, parsed.value, ticks) catch return;
    quick.message_status = .writing;
    if (!spawn(self, .quick_message, .commit_message, proto.CommitMessageRequest{
        .review_id = parsed.value.review_id,
        .selections = selections,
    }, "", .{ .timeout_ms = MESSAGE_TIMEOUT_MS, .generation = state.quick_generation })) {
        // An aborted action's message request still occupies the lane; this
        // one is sent when it lands (see pollGitChanges).
        quick.message_queued = true;
    }
}

fn quickCommit(self: anytype, new_branch: bool) void {
    const state = &self.git_changes;
    const quick = state.quick orelse return;
    quick.pending_new_branch = null;
    const parsed = quick.review orelse return;
    const message = effectiveMessage("", quick.generated()) orelse {
        quickFallbackToSheet(self, "Couldn't write a commit message. Type one to commit.");
        return;
    };
    var arena: std.heap.ArenaAllocator = .init(page);
    defer arena.deinit();
    const allocator = arena.allocator();
    const ticks = defaultTicks(allocator, parsed.value) catch return;
    const selections = buildSelections(allocator, parsed.value, ticks) catch return;
    if (selections.len == 0) {
        endQuick(self);
        self.setSidebarNotice("This chat has no files to commit.");
        return;
    }
    if (!spawn(self, .quick, .commit, proto.CommitRequest{
        .review_id = parsed.value.review_id,
        .message = message,
        .selections = selections,
        .push = quick.push,
        .new_branch = new_branch,
        .branch_name = if (new_branch) quick.branchSuggestion() else null,
    }, "", .{ .timeout_ms = PUSH_TIMEOUT_MS, .generation = state.quick_generation })) {
        endQuick(self);
        self.setSidebarNotice("Another git action is still running. Try again in a moment.");
        return;
    }
    quick.phase = .committing;
    self.markDirty();
}

fn applyQuickReview(self: anytype, result: *Result) void {
    const quick = self.git_changes.quick orelse return;
    switch (result.payload) {
        .review => |parsed| {
            result.payload = .none;
            if (quick.review) |*previous| previous.deinit();
            quick.review = parsed;
            const plan = quickPlan(parsed.value);
            switch (plan) {
                .nothing => {
                    endQuick(self);
                    self.setSidebarNotice("No uncommitted changes for this chat.");
                },
                .review => quickFallbackToSheet(self, null),
                .confirm_default_branch, .direct => {
                    quick.files = mineFileCount(parsed.value);
                    quick.left_out = leftOutFileCount(parsed.value);
                    const branch = quickBranch(parsed.value) orelse "main";
                    const len = @min(branch.len, quick.branch_buf.len);
                    @memcpy(quick.branch_buf[0..len], branch[0..len]);
                    quick.branch_name_len = len;
                    // A local commit on the default branch needs no confirmation.
                    if (plan == .direct or !quick.push) {
                        quick.phase = .writing;
                        quick.pending_new_branch = false;
                    } else {
                        quick.phase = .confirming;
                    }
                    requestQuickMessage(self);
                },
            }
        },
        else => {
            endQuick(self);
            showToast(self, failureToast("Commit & push failed", result.err_message orelse "Could not load this chat's changes."));
        },
    }
    self.markDirty();
}

fn applyQuickMessage(self: anytype, result: *Result) void {
    const quick = self.git_changes.quick orelse return;
    switch (result.payload) {
        .commit_message => |parsed| {
            const value = parsed.value;
            const text = std.mem.trim(u8, value.message, " \t\r\n");
            const len = @min(text.len, MESSAGE_CAPACITY);
            @memcpy(quick.generated_storage[0..len], text[0..len]);
            quick.generated_len = len;
            const branch = value.branch orelse "";
            const branch_len = @min(branch.len, quick.branch_storage.len);
            @memcpy(quick.branch_storage[0..branch_len], branch[0..branch_len]);
            quick.branch_len = branch_len;
            quick.message_status = .idle;
            if (quick.pending_new_branch) |new_branch| quickCommit(self, new_branch);
        },
        else => {
            quick.message_status = .failed;
            if (quick.pending_new_branch != null) {
                quickFallbackToSheet(self, "Couldn't write a commit message. Type one to commit.");
            }
        },
    }
    self.markDirty();
}

fn applyQuickCommit(self: anytype, result: *Result) void {
    const state = &self.git_changes;
    const quick = state.quick orelse return;
    var workspace_buf: [256]u8 = undefined;
    var thread_buf: [256]u8 = undefined;
    const workspace_id = copyInto(&workspace_buf, quick.workspace_id);
    const thread_id = copyInto(&thread_buf, quick.local_thread_id);
    const push = quick.push;
    const left_out = quick.left_out;
    switch (result.payload) {
        .commit => |parsed| {
            var buf: [320]u8 = undefined;
            const outcome = commitOutcome(&buf, parsed.value);
            if (outcome.pull_push_root) |root| {
                state.setRejected(workspace_id, thread_id, root);
            } else if (state.rejectedFor(thread_id)) {
                state.clearRejected();
            }
            applyUpdatedRows(self, thread_id, parsed.value.updated_rows);
            endQuick(self);
            var toast = commitToast(parsed.value, push);
            toast.noteLeftOut(left_out);
            showToast(self, toast);
        },
        else => {
            const code = result.err_code;
            if (commitErrorKind(code) == .reload) {
                quickFallbackToSheet(self, "Files changed while committing, so the review opened. Check it and commit again.");
                refreshAfterQuick(self, workspace_id, thread_id);
                return;
            }
            endQuick(self);
            if (code != null and std.mem.eql(u8, code.?, proto.ERR_BRANCH_CREATE_FAILED)) {
                showToast(self, failureToast("Commit failed", result.err_message orelse "Could not create the branch; nothing was committed."));
            } else if (code != null and std.mem.eql(u8, code.?, proto.ERR_IN_PROGRESS)) {
                self.setSidebarNotice("This commit is already running.");
            } else {
                showToast(self, failureToast("Commit failed", commitErrorText(code, result.err_message)));
            }
        },
    }
    refreshAfterQuick(self, workspace_id, thread_id);
}

/// Push starts by re-reading status; collect the repositories to push.
fn applyQuickStatus(self: anytype, result: *Result) void {
    const state = &self.git_changes;
    const quick = state.quick orelse return;
    switch (result.payload) {
        .status => |parsed| {
            result.payload = .none;
            for (parsed.value.repos) |repo| {
                if (!isPushTarget(repo)) continue;
                const root = page.dupe(u8, repo.root) catch continue;
                quick.push_roots.append(page, root) catch {
                    page.free(root);
                    continue;
                };
                quick.push_commits +|= repo.ahead;
                if (quick.branch_name_len == 0) {
                    const branch = repo.branch orelse "";
                    const len = @min(branch.len, quick.branch_buf.len);
                    @memcpy(quick.branch_buf[0..len], branch[0..len]);
                    quick.branch_name_len = len;
                    quick.upstream_len = copyInto(&quick.upstream_buf, repo.upstream orelse "").len;
                    quick.repo_name_len = copyInto(&quick.repo_name_buf, repo.name).len;
                }
            }
            state.storeStatus(parsed);
            if (quick.push_roots.items.len == 0) {
                endQuick(self);
                self.setSidebarNotice("Nothing to push.");
                return;
            }
            quickPushNext(self);
        },
        else => {
            endQuick(self);
            showToast(self, failureToast("Push failed", result.err_message orelse "Could not read the branch status."));
        },
    }
    self.markDirty();
}

fn quickPushNext(self: anytype) void {
    const state = &self.git_changes;
    const quick = state.quick orelse return;
    if (quick.push_roots.items.len == 0) return;
    if (!spawn(self, .quick, .push, proto.PushRequest{
        .workspace_id = quick.workspace_id,
        .root = quick.push_roots.items[0],
        .local_thread_id = quick.local_thread_id,
    }, quick.push_roots.items[0], .{ .timeout_ms = PUSH_TIMEOUT_MS, .generation = state.quick_generation })) {
        endQuick(self);
        self.setSidebarNotice("Another git action is still running. Try again in a moment.");
    }
}

fn applyQuickPush(self: anytype, request: *Request, result: *Result) void {
    const state = &self.git_changes;
    const quick = state.quick orelse return;
    var workspace_buf: [256]u8 = undefined;
    var thread_buf: [256]u8 = undefined;
    const workspace_id = copyInto(&workspace_buf, quick.workspace_id);
    const thread_id = copyInto(&thread_buf, quick.local_thread_id);
    defer refreshGitChangesStatus(self, thread_id);
    switch (result.payload) {
        .pull_push => |parsed| {
            const value = parsed.value;
            if (std.mem.eql(u8, value.push, "pushed")) {
                quick.pushed += 1;
                applyUpdatedRows(self, thread_id, value.updated_rows);
                if (quick.push_roots.items.len > 0) page.free(quick.push_roots.orderedRemove(0));
                if (quick.push_roots.items.len > 0) {
                    quickPushNext(self);
                    return;
                }
                if (state.rejectedFor(thread_id)) state.clearRejected();
                // A single repository: prefer the daemon's facts about what it published.
                const single = quick.pushed == 1;
                const toast = pushToast(
                    quick.pushed,
                    if (single) value.commits orelse quick.push_commits else quick.push_commits,
                    quick.upstream_buf[0..quick.upstream_len],
                    quick.branch_buf[0..quick.branch_name_len],
                    quick.repo_name_buf[0..quick.repo_name_len],
                    if (single) value.head orelse "" else "",
                    if (single) value.subject orelse "" else "",
                );
                endQuick(self);
                showToast(self, toast);
                return;
            }
            if (std.mem.eql(u8, value.push, "rejected")) {
                state.setRejected(workspace_id, thread_id, request.tag);
                endQuick(self);
                showToast(self, pushFailureToast("Push rejected", value.push, value.push_message, thread_id, true));
                return;
            }
            endQuick(self);
            showToast(self, pushFailureToast("Push failed", value.push, value.push_message, thread_id, false));
        },
        else => {
            endQuick(self);
            showToast(self, failureToast("Push failed", result.err_message orelse "git push did not succeed."));
        },
    }
}

fn applyQuickPullPush(self: anytype, result: *Result) void {
    const state = &self.git_changes;
    const quick = state.quick orelse return;
    var workspace_buf: [256]u8 = undefined;
    var thread_buf: [256]u8 = undefined;
    const workspace_id = copyInto(&workspace_buf, quick.workspace_id);
    const thread_id = copyInto(&thread_buf, quick.local_thread_id);
    endQuick(self);
    switch (result.payload) {
        .pull_push => |parsed| {
            const value = parsed.value;
            if (std.mem.eql(u8, value.push, "pushed")) {
                if (state.rejectedFor(thread_id)) state.clearRejected();
                applyUpdatedRows(self, thread_id, value.updated_rows);
                showToast(self, pullPushToast(value.root, state.repoBranch(thread_id, value.root), value.head orelse "", value.subject orelse ""));
            } else {
                showToast(self, pushFailureToast("Pull & push failed", value.push, value.push_message, thread_id, false));
            }
        },
        else => {
            const code = result.err_code orelse "";
            if (std.mem.eql(u8, code, proto.ERR_TURNS_RUNNING)) {
                showToast(self, failureToast("Pull & push waited", "Chats are still running in this repository. Pull & push once they finish."));
            } else {
                showToast(self, failureToast("Pull & push failed", result.err_message orelse "git pull or push did not succeed."));
            }
        },
    }
    refreshAfterQuick(self, workspace_id, thread_id);
}

/// Swaps in the bodies of committed transcript rows the daemon rewrote after
/// a push. Hydrated rows are otherwise never re-read, so without this the card
/// would keep showing the commit as unpushed until the chat reloads.
fn applyUpdatedRows(self: anytype, local_thread_id: []const u8, rows: []const proto.UpdatedRow) void {
    if (rows.len == 0) return;
    const ref = findThread(self, local_thread_id) orelse return;
    const thread = &self.project_controller.projects.items[ref.project_index].threads.items[ref.thread_index];
    var changed = false;
    for (rows) |row| {
        for (thread.messages.items, 0..) |*message, index| {
            const id = message.message_id orelse continue;
            if (!std.mem.eql(u8, id, row.message_id)) continue;
            if (std.mem.eql(u8, message.body, row.body)) break;
            const body = self.allocator.dupeZ(u8, row.body) catch break;
            self.allocator.free(message.body);
            message.body = body;
            if (index < thread.transcript_markdown_entries.items.len) {
                if (thread.transcript_markdown_entries.items[index]) |entry| entry.deinit(self.allocator);
                thread.transcript_markdown_entries.items[index] = null;
            }
            changed = true;
            break;
        }
    }
    if (!changed) return;
    thread.transcript_layout_valid = false;
    self.markDirty();
}

fn copyInto(buf: []u8, value: []const u8) []const u8 {
    const len = @min(value.len, buf.len);
    @memcpy(buf[0..len], value[0..len]);
    return buf[0..len];
}

// ---- Settings -------------------------------------------------------

/// Writes `chat.commit_*` through the daemon and mirrors it in memory.
pub fn setCommitSettings(
    self: anytype,
    provider: ?app_config.CommitMessageProvider,
    model: ?[]const u8,
    action: ?app_config.CommitDefaultAction,
) void {
    if (provider) |value| {
        if (self.app_config.commit_message_provider != value) {
            self.app_config.commit_message_provider = value;
            // A provider change resets the model, as the daemon does.
            self.app_config.setCommitMessageModel(self.allocator, null) catch {};
        }
    }
    if (model) |value| {
        self.app_config.setCommitMessageModel(self.allocator, if (value.len == 0) null else value) catch {};
    }
    if (action) |value| self.app_config.commit_default_action = value;
    const request = proto.ConfigCommitSetRequest{
        .commit_message_provider = if (provider) |value| @tagName(value) else null,
        .commit_message_model = model,
        .commit_default_action = if (action) |value| @tagName(value) else null,
    };
    // One write at a time; the full in-memory state is written once the
    // current one lands.
    if (!spawn(self, .config, .config_set, request, "", .{})) self.git_changes.config_write_pending = true;
    self.markDirty();
}

fn flushPendingConfigWrite(self: anytype) void {
    if (!self.git_changes.config_write_pending) return;
    self.git_changes.config_write_pending = false;
    const request = proto.ConfigCommitSetRequest{
        .commit_message_provider = @tagName(self.app_config.commit_message_provider),
        .commit_message_model = self.app_config.commit_message_model orelse "",
        .commit_default_action = @tagName(self.app_config.commit_default_action),
    };
    if (!spawn(self, .config, .config_set, request, "", .{})) self.git_changes.config_write_pending = true;
}

fn takeCompleted(lane: *Lane) ?struct { request: *Request, result: Result } {
    lane.lock();
    if (lane.status != .completed) {
        lane.mutex.unlock();
        return null;
    }
    const thread = lane.worker.?;
    const request = lane.request.?;
    const result = lane.result.?;
    lane.worker = null;
    lane.request = null;
    lane.result = null;
    lane.status = .idle;
    lane.mutex.unlock();
    thread.join();
    return .{ .request = request, .result = result };
}

fn isUnknownMethod(code: ?[]const u8) bool {
    const value = code orelse return false;
    return std.mem.eql(u8, value, "method_not_found") or std.mem.eql(u8, value, "unknown_method") or std.mem.eql(u8, value, "unsupported");
}

/// Drains finished workers on the UI thread. Call from the main poll loop.
pub fn pollGitChanges(self: anytype) void {
    const state = &self.git_changes;
    if (takeCompleted(state.lane(.summary))) |done| {
        var result = done.result;
        defer result.deinit();
        defer done.request.deinit();
        switch (result.payload) {
            .summary => |parsed| {
                result.payload = .none;
                if (state.storeSummary(parsed)) {
                    self.markDirty();
                    refreshFocusedStatus(self, done.request.tag);
                }
            },
            else => if (isUnknownMethod(result.err_code)) {
                state.disabled = true;
            },
        }
        if (state.summary_queue.items.len > 0) {
            const next = state.summary_queue.orderedRemove(0);
            defer page.free(next);
            refreshGitChangesSummary(self, next, true);
        }
    }
    if (takeCompleted(state.lane(.status))) |done| {
        var result = done.result;
        defer result.deinit();
        defer done.request.deinit();
        switch (result.payload) {
            .status => |parsed| {
                result.payload = .none;
                state.storeStatus(parsed);
                self.markDirty();
            },
            else => if (isUnknownMethod(result.err_code)) {
                state.status_disabled = true;
            },
        }
        if (state.status_queue.items.len > 0) {
            const next = state.status_queue.orderedRemove(0);
            defer page.free(next);
            refreshGitChangesStatus(self, next);
        }
    }
    if (takeCompleted(state.lane(.config))) |done| {
        var result = done.result;
        defer result.deinit();
        defer done.request.deinit();
        if (result.failed()) {
            self.setSidebarNotice(result.err_message orelse "Could not save commit settings.");
        }
        flushPendingConfigWrite(self);
    }
    if (takeCompleted(state.lane(.message))) |done| {
        var result = done.result;
        defer result.deinit();
        defer done.request.deinit();
        applyMessageResult(self, done.request, &result);
    }
    if (takeCompleted(state.lane(.sheet))) |done| {
        var result = done.result;
        defer result.deinit();
        defer done.request.deinit();
        switch (done.request.job) {
            .review => applyReviewResult(self, done.request, &result),
            .commit => applyCommitResult(self, done.request, &result),
            .pull_push => applyPullPushResult(self, done.request, &result),
            else => {},
        }
    }
    if (takeCompleted(state.lane(.quick_message))) |done| {
        var result = done.result;
        defer result.deinit();
        defer done.request.deinit();
        if (done.request.generation == state.quick_generation) applyQuickMessage(self, &result);
        if (state.quick) |quick| {
            if (quick.message_queued) {
                quick.message_queued = false;
                requestQuickMessage(self);
            }
        }
    }
    if (takeCompleted(state.lane(.quick))) |done| {
        var result = done.result;
        defer result.deinit();
        defer done.request.deinit();
        if (done.request.generation == state.quick_generation) {
            switch (done.request.job) {
                .review => applyQuickReview(self, &result),
                .commit => applyQuickCommit(self, &result),
                .status => applyQuickStatus(self, &result),
                .push => applyQuickPush(self, done.request, &result),
                .pull_push => applyQuickPullPush(self, &result),
                else => {},
            }
        }
    }
}

fn applyMessageResult(self: anytype, request: *Request, result: *Result) void {
    const state = &self.git_changes;
    const sheet = state.sheet orelse return;
    if (request.generation != state.generation) return;
    const explicit = std.mem.eql(u8, request.tag, "explicit");
    defer if (sheet.message_rerun) |rerun_explicit| {
        sheet.message_rerun = null;
        generateCommitMessage(self, rerun_explicit);
    };
    switch (result.payload) {
        .commit_message => |parsed| {
            const value = parsed.value;
            sheet.setGenerated(value.message, value.branch);
            if (explicit) {
                sheet.clearTyped();
                if (self.palette_modal_text_focus == .commit_message) self.modal_text_selection_anchor = null;
            }
            sheet.message_status = .idle;
            const written = std.fmt.bufPrint(&sheet.source_buf, "{s}{s}{s}", .{
                value.provider,
                if (value.model.len > 0) " \u{00B7} " else "",
                value.model,
            }) catch "";
            sheet.source_len = written.len;
            // A commit clicked while writing runs now, unless a newer
            // request (for a changed selection) is about to replace this one.
            if (sheet.message_rerun == null) {
                if (sheet.pending_new_branch) |new_branch| spawnSheetCommit(self, new_branch, sheet.pending_action);
            }
        },
        else => {
            sheet.message_status = .failed;
            if (sheet.pending_new_branch != null) {
                sheet.pending_new_branch = null;
                sheet.setErrorText("Couldn't write a commit message. Type one, then commit.");
            }
            if (commitErrorKind(result.err_code) == .reload) {
                loadReview(self, true);
            } else if (explicit) {
                sheet.setErrorText(result.err_message orelse "Could not write a commit message.");
            }
        },
    }
    self.markDirty();
}

fn applyReviewResult(self: anytype, request: *Request, result: *Result) void {
    const state = &self.git_changes;
    const sheet = state.sheet orelse return;
    if (request.generation != state.generation) return;
    const carry = std.mem.eql(u8, request.tag, "carry");
    switch (result.payload) {
        .review => |parsed| {
            result.payload = .none;
            sheet.installReview(parsed, carry);
            sheet.phase = .ready;
            // Hunk indices changed with a reload, so a pending placeholder
            // message is re-requested for the new review too.
            if (!carry or sheet.message().len == 0) generateCommitMessage(self, false);
        },
        else => {
            if (!carry or sheet.review == null) sheet.phase = .load_error;
            sheet.setErrorText(result.err_message orelse "Could not load this chat's changes.");
        },
    }
    self.markDirty();
}

fn applyCommitResult(self: anytype, request: *Request, result: *Result) void {
    const state = &self.git_changes;
    const sheet = state.sheet orelse return;
    if (request.generation != state.generation) return;
    const push_requested = if (sheet.busy) |busy| busy == .commit_and_push else false;
    sheet.busy = null;
    var thread_buf: [256]u8 = undefined;
    const thread_id = copyInto(&thread_buf, sheet.local_thread_id);
    switch (result.payload) {
        .commit => |parsed| {
            applyUpdatedRows(self, thread_id, parsed.value.updated_rows);
            const outcome = commitOutcome(&sheet.outcome_buf, parsed.value);
            sheet.outcome_len = outcome.text.len;
            if (outcome.pull_push_root) |root| {
                // Keep the sheet up with the outcome so Pull & push stays reachable.
                sheet.pull_push_root = page.dupe(u8, root) catch null;
                sheet.phase = .result;
                state.setRejected(sheet.workspace_id, sheet.local_thread_id, root);
                refreshGitChangesSummary(self, sheet.workspace_id, false);
                refreshGitChangesStatus(self, thread_id);
                showToast(self, commitToast(parsed.value, push_requested));
            } else {
                if (state.rejectedFor(thread_id) and parsed.value.repos.len > 0 and std.mem.eql(u8, parsed.value.repos[0].push, "pushed")) state.clearRejected();
                // Built before the sheet (and the result it points into) closes.
                const toast = commitToast(parsed.value, push_requested);
                closeCommitSheet(self);
                showToast(self, toast);
            }
        },
        else => {
            sheet.setErrorText(commitErrorText(result.err_code, result.err_message));
            if (commitErrorKind(result.err_code) == .reload) {
                loadReview(self, true);
            } else {
                showToast(self, failureToast("Commit failed", commitErrorText(result.err_code, result.err_message)));
            }
        },
    }
    self.markDirty();
}

fn applyPullPushResult(self: anytype, request: *Request, result: *Result) void {
    const state = &self.git_changes;
    refreshGitChangesSummary(self, request.tag, false);
    const sheet = state.sheet orelse return;
    if (request.generation != state.generation) return;
    sheet.pull_push_busy = false;
    switch (result.payload) {
        .pull_push => |parsed| {
            const value = parsed.value;
            if (std.mem.eql(u8, value.push, "pushed")) {
                if (state.rejectedFor(sheet.local_thread_id)) state.clearRejected();
                applyUpdatedRows(self, sheet.local_thread_id, value.updated_rows);
                const toast = pullPushToast(value.root, state.repoBranch(sheet.local_thread_id, value.root), value.head orelse "", value.subject orelse "");
                closeCommitSheet(self);
                showToast(self, toast);
            } else {
                var buf: [320]u8 = undefined;
                const text = std.fmt.bufPrint(&buf, "Push {s}{s}{s}", .{
                    value.push,
                    if (value.push_message != null) ": " else "",
                    value.push_message orelse "",
                }) catch "Push failed.";
                sheet.setErrorText(text);
                showToast(self, pushFailureToast("Pull & push failed", value.push, value.push_message, sheet.local_thread_id, false));
            }
        },
        else => {
            const code = result.err_code orelse "";
            if (std.mem.eql(u8, code, proto.ERR_TURNS_RUNNING)) {
                sheet.setErrorText("Chats are still running in this repository. Pull & push once they finish.");
            } else {
                sheet.setErrorText(result.err_message orelse "Pull & push failed.");
                showToast(self, failureToast("Pull & push failed", result.err_message orelse "git pull or push did not succeed."));
            }
        },
    }
    self.markDirty();
}

// ------------------------------------------------------------------
// Tests
// ------------------------------------------------------------------

const testing = std.testing;

fn testReview() ReviewResult {
    const S = struct {
        const hunks = [_]proto.ReviewHunk{
            .{ .index = 0, .header = "@@ -1 +1 @@", .text = "@@ -1 +1 @@\n-a\n+b" },
            .{ .index = 1, .header = "@@ -9 +9 @@", .text = "@@ -9 +9 @@\n-c\n+d" },
        };
        const others = [_]proto.OtherThread{ .{ .local_thread_id = "t2", .title = "Fix login" }, .{ .local_thread_id = "t3", .title = " " } };
        const files = [_]ReviewFile{
            .{ .path = "a.zig", .status = "modified", .ownership = "mine", .additions = 2, .deletions = 2, .binary = false, .hunk_selectable = true, .preview_truncated = false, .hunks = &hunks },
            .{ .path = "b.zig", .status = "modified", .ownership = "shared", .other_threads = &others, .additions = 1, .deletions = 0, .binary = false, .hunk_selectable = false, .preview_truncated = false },
            .{ .path = "c.png", .status = "added", .ownership = "unassigned", .additions = 0, .deletions = 0, .binary = true, .hunk_selectable = false, .preview_truncated = false },
        };
        const other_files = [_]ReviewFile{
            .{ .path = "d.md", .status = "deleted", .ownership = "unclear", .additions = 0, .deletions = 4, .binary = false, .hunk_selectable = false, .preview_truncated = true },
        };
        const repos = [_]ReviewRepo{
            .{ .root = "/w/app", .name = "app", .branch = "main", .files = &files },
            .{ .root = "/w/lib", .name = "lib", .files = &other_files },
        };
    };
    return .{
        .review_id = "r1",
        .workspace_id = "w",
        .local_thread_id = "t1",
        .turn_running = false,
        .default_action = "commit",
        .repos = &S.repos,
    };
}

test "summary chip formats counts and hides empty chats" {
    try testing.expect(summaryChip(null) == null);
    try testing.expect(summaryChip(.{ .local_thread_id = "t", .files = 0, .additions = 3, .deletions = 1, .attention = 0 }) == null);
    const many = summaryChip(.{ .local_thread_id = "t", .files = 4, .additions = 120, .deletions = 30, .attention = 0 }).?;
    try testing.expectEqualStrings("\u{25CF} 4 files +120 \u{2212}30", many.text());
    try testing.expect(!many.attention);
    const one = summaryChip(.{ .local_thread_id = "t", .files = 1, .additions = 0, .deletions = 0, .attention = 1 }).?;
    try testing.expectEqualStrings("\u{25CF} 1 file +0 \u{2212}0", one.text());
    try testing.expect(one.attention);
}

test "default ticks select only mine files" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const review = testReview();
    const ticks = try defaultTicks(arena.allocator(), review);
    try testing.expectEqual(@as(usize, 4), ticks.len);
    const files = review.repos[0].files;
    try testing.expectEqual(TickState.all, ticks[0].state(files[0]));
    try testing.expectEqual(TickState.none, ticks[1].state(files[1]));
    try testing.expectEqual(TickState.none, ticks[2].state(files[2]));
    try testing.expectEqual(TickState.none, ticks[3].state(review.repos[1].files[0]));
}

test "hunk toggles produce partial selections with daemon hunk indices" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const review = testReview();
    const ticks = try defaultTicks(allocator, review);
    const file = review.repos[0].files[0];
    ticks[0].toggleHunk(file, 0);
    try testing.expectEqual(TickState.partial, ticks[0].state(file));
    ticks[2].toggle(review.repos[0].files[2]);

    const selections = try buildSelections(allocator, review, ticks);
    try testing.expectEqual(@as(usize, 1), selections.len);
    try testing.expectEqualStrings("/w/app", selections[0].root);
    try testing.expectEqual(@as(usize, 2), selections[0].files.len);
    try testing.expectEqualStrings("a.zig", selections[0].files[0].path);
    try testing.expectEqualSlices(u32, &.{1}, selections[0].files[0].hunks.?);
    try testing.expectEqualStrings("c.png", selections[0].files[1].path);
    try testing.expect(selections[0].files[1].hunks == null);
    try testing.expectEqual(@as(usize, 2), selectionFileCount(selections));

    // Ticking the last hunk back makes the file whole again (no hunk list).
    ticks[0].toggleHunk(file, 0);
    try testing.expectEqual(TickState.all, ticks[0].state(file));
    // Toggling a whole file unticks it; toggling a partial file ticks it all.
    ticks[0].toggleHunk(file, 1);
    ticks[0].toggle(file);
    try testing.expectEqual(TickState.all, ticks[0].state(file));
    ticks[0].toggle(file);
    try testing.expectEqual(TickState.none, ticks[0].state(file));
    try testing.expectEqual(@as(usize, 1), selectionFileCount(try buildSelections(allocator, review, ticks)));
}

test "carry ticks keeps whole-file choices and resets partial picks" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const review = testReview();
    const previous = try defaultTicks(allocator, review);
    previous[0].toggleHunk(review.repos[0].files[0], 1); // partial
    previous[1].toggle(review.repos[0].files[1]); // shared ticked
    const carried = try carryTicks(allocator, review, review, previous);
    try testing.expectEqual(TickState.all, carried[0].state(review.repos[0].files[0]));
    try testing.expectEqual(TickState.all, carried[1].state(review.repos[0].files[1]));
    try testing.expectEqual(TickState.none, carried[2].state(review.repos[0].files[2]));
}

test "ownership labels name other chats" {
    var buf: [128]u8 = undefined;
    const review = testReview();
    try testing.expectEqualStrings("Mine", ownershipLabel(&buf, review.repos[0].files[0]));
    try testing.expectEqualStrings("Shared with Fix login, another chat", ownershipLabel(&buf, review.repos[0].files[1]));
    try testing.expectEqualStrings("Unassigned", ownershipLabel(&buf, review.repos[0].files[2]));
    try testing.expectEqualStrings("Unclear owner", ownershipLabel(&buf, review.repos[1].files[0]));
}

test "hunks are selectable only for complete text diffs" {
    const review = testReview();
    try testing.expect(canSelectHunks(review.repos[0].files[0]));
    try testing.expect(!canSelectHunks(review.repos[0].files[1]));
    try testing.expect(!canSelectHunks(review.repos[0].files[2]));
    try testing.expect(!canSelectHunks(review.repos[1].files[0]));
}

test "commit errors map to friendly text" {
    try testing.expectEqual(ErrorKind.reload, commitErrorKind(proto.ERR_CHANGED_SINCE_REVIEW));
    try testing.expectEqual(ErrorKind.reload, commitErrorKind(proto.ERR_REVIEW_EXPIRED));
    try testing.expectEqual(ErrorKind.retry, commitErrorKind(proto.ERR_HEAD_MOVED));
    try testing.expectEqual(ErrorKind.identity, commitErrorKind(proto.ERR_MISSING_IDENTITY));
    try testing.expectEqual(ErrorKind.other, commitErrorKind(null));
    try testing.expect(std.mem.startsWith(u8, commitErrorText(proto.ERR_CHANGED_SINCE_REVIEW, null), "Files changed since"));
    try testing.expect(std.mem.startsWith(u8, commitErrorText(proto.ERR_REVIEW_EXPIRED, null), "This review expired"));
    try testing.expectEqualStrings("boom", commitErrorText("internal", "boom"));
    try testing.expectEqualStrings("Commit failed.", commitErrorText(null, null));
}

test "commit outcome summarizes shas and push state" {
    var buf: [320]u8 = undefined;
    const pushed = [_]proto.RepoCommit{
        .{ .root = "/w/app", .commit = "e57cfce1234", .short_commit = "e57cfce", .subject = "s", .files = 2, .push = "pushed" },
    };
    const ok = commitOutcome(&buf, .{ .workspace_id = "w", .local_thread_id = "t", .files = 2, .repos = &pushed });
    try testing.expectEqualStrings("Committed 2 files \u{00B7} e57cfce \u{00B7} pushed", ok.text);
    try testing.expect(ok.pull_push_root == null);

    const rejected = [_]proto.RepoCommit{
        .{ .root = "/w/app", .commit = "abcdef0123", .short_commit = "", .subject = "s", .files = 1, .push = "rejected", .index_reset = true },
    };
    const bad = commitOutcome(&buf, .{ .workspace_id = "w", .local_thread_id = "t", .files = 0, .repos = &rejected });
    try testing.expectEqualStrings("Committed 1 file \u{00B7} abcdef0 \u{00B7} push rejected \u{00B7} staged changes for these files were reset", bad.text);
    try testing.expectEqualStrings("/w/app", bad.pull_push_root.?);

    const local = [_]proto.RepoCommit{
        .{ .root = "/w/app", .commit = "1111111", .short_commit = "1111111", .subject = "s", .files = 3, .push = "not_requested" },
    };
    try testing.expectEqualStrings("Committed 3 files \u{00B7} 1111111", commitOutcome(&buf, .{ .workspace_id = "w", .local_thread_id = "t", .files = 3, .repos = &local }).text);
}

test "header button follows changes, remote and ahead" {
    const changes: ThreadSummary = .{ .local_thread_id = "t", .files = 4, .additions = 1, .deletions = 1, .attention = 0 };
    const remote: RepoFacts = .{ .has_remote = true };

    const push_default = headerButton(changes, remote, .commit_and_push).?;
    try testing.expectEqual(HeaderKind.commit_and_push, push_default.kind);
    try testing.expectEqualStrings("Commit & push", push_default.label());
    try testing.expectEqual(@as(u32, 4), push_default.files);
    try testing.expect(!push_default.attention);

    try testing.expectEqualStrings("Commit", headerButton(changes, remote, .commit).?.label());
    // Unknown facts keep the configured action.
    try testing.expectEqual(HeaderKind.commit_and_push, headerButton(changes, null, .commit_and_push).?.kind);
    // No remote at all: plain Commit.
    try testing.expectEqual(HeaderKind.commit, headerButton(changes, .{ .has_remote = false }, .commit_and_push).?.kind);

    var shared = changes;
    shared.attention = 1;
    try testing.expect(headerButton(shared, remote, .commit).?.attention);
    // The badge counts what the quick path commits: the chat's own files.
    try testing.expectEqual(@as(u32, 3), headerButton(shared, remote, .commit).?.files);
    var all_unclear = changes;
    all_unclear.attention = changes.files;
    const review_only = headerButton(all_unclear, remote, .commit_and_push).?;
    try testing.expectEqual(@as(u32, 0), review_only.files);
    try testing.expect(review_only.attention);

    const clean: ThreadSummary = .{ .local_thread_id = "t", .files = 0, .additions = 0, .deletions = 0, .attention = 0 };
    const ahead = headerButton(clean, .{ .has_remote = true, .ahead = 3 }, .commit).?;
    try testing.expectEqual(HeaderKind.push, ahead.kind);
    try testing.expectEqualStrings("3 Push", ahead.label());
    try testing.expectEqual(@as(u32, 3), ahead.ahead);

    try testing.expect(headerButton(clean, remote, .commit_and_push) == null);
    try testing.expect(headerButton(null, null, .commit_and_push) == null);
    try testing.expect(headerButton(null, .{ .has_remote = true, .ahead = 1 }, .commit).?.kind == .push);
}

test "repo facts and push targets" {
    const repos = [_]proto.RepoStatus{
        .{ .root = "/a", .name = "a", .branch = "main", .is_default_branch = true, .upstream = "origin/main", .ahead = 2, .has_remote = true },
        .{ .root = "/b", .name = "b", .branch = "feature/x", .has_remote = true },
        .{ .root = "/c", .name = "c", .branch = "main", .upstream = "origin/main", .has_remote = true },
        .{ .root = "/d", .name = "d", .branch = "main" },
    };
    const facts = repoFacts(&repos);
    try testing.expectEqual(@as(u32, 2), facts.ahead);
    try testing.expect(facts.unpublished and facts.on_default_branch and facts.has_remote and facts.canPush());
    try testing.expect(isPushTarget(repos[0]));
    try testing.expect(isPushTarget(repos[1]));
    try testing.expect(!isPushTarget(repos[2]));
    try testing.expect(!isPushTarget(repos[3]));
    try testing.expect(!repoFacts(repos[2..3]).canPush());
}

test "quick plan picks review, confirm or direct" {
    const mine = ReviewFile{ .path = "a.zig", .status = "modified", .ownership = "mine", .additions = 1, .deletions = 0, .binary = false, .hunk_selectable = true, .preview_truncated = false };
    const unassigned = ReviewFile{ .path = "u.zig", .status = "added", .ownership = "unassigned", .additions = 1, .deletions = 0, .binary = false, .hunk_selectable = true, .preview_truncated = false };
    const shared = ReviewFile{ .path = "s.zig", .status = "modified", .ownership = "shared", .additions = 1, .deletions = 0, .binary = false, .hunk_selectable = true, .preview_truncated = false };
    const unclear = ReviewFile{ .path = "q.zig", .status = "modified", .ownership = "unclear", .additions = 1, .deletions = 0, .binary = false, .hunk_selectable = true, .preview_truncated = false };
    const Case = struct {
        fn review(repos: []const ReviewRepo) ReviewResult {
            return .{ .review_id = "r", .workspace_id = "w", .local_thread_id = "t", .turn_running = false, .default_action = "commit", .repos = repos };
        }
    };

    try testing.expectEqual(QuickPlan.nothing, quickPlan(Case.review(&.{})));
    try testing.expectEqual(QuickPlan.nothing, quickPlan(Case.review(&.{.{ .root = "/w", .name = "w" }})));

    const feature = [_]ReviewRepo{.{ .root = "/w", .name = "w", .branch = "feature/x", .files = &.{mine} }};
    try testing.expectEqual(QuickPlan.direct, quickPlan(Case.review(&feature)));
    try testing.expectEqual(@as(usize, 1), mineFileCount(Case.review(&feature)));
    try testing.expectEqualStrings("feature/x", quickBranch(Case.review(&feature)).?);

    const on_main = [_]ReviewRepo{.{ .root = "/w", .name = "w", .branch = "main", .is_default_branch = true, .files = &.{ mine, unassigned } }};
    try testing.expectEqual(QuickPlan.confirm_default_branch, quickPlan(Case.review(&on_main)));
    try testing.expectEqual(@as(usize, 1), mineFileCount(Case.review(&on_main)));

    // Unassigned files on the default branch without any of mine: review.
    const only_unassigned = [_]ReviewRepo{.{ .root = "/w", .name = "w", .branch = "main", .is_default_branch = true, .files = &.{unassigned} }};
    try testing.expectEqual(QuickPlan.review, quickPlan(Case.review(&only_unassigned)));
    try testing.expect(quickBranch(Case.review(&only_unassigned)) == null);

    // Shared and unclear files never stop the quick path while the chat has
    // files of its own; they are left out and counted for the toast.
    const with_shared = [_]ReviewRepo{.{ .root = "/w", .name = "w", .branch = "feature/x", .files = &.{ mine, shared } }};
    try testing.expectEqual(QuickPlan.direct, quickPlan(Case.review(&with_shared)));
    try testing.expectEqual(@as(usize, 1), mineFileCount(Case.review(&with_shared)));
    try testing.expectEqual(@as(usize, 1), leftOutFileCount(Case.review(&with_shared)));
    const with_unclear = [_]ReviewRepo{
        .{ .root = "/w", .name = "w", .branch = "feature/x", .files = &.{mine} },
        .{ .root = "/l", .name = "l", .branch = "main", .files = &.{ unclear, shared, unassigned } },
    };
    try testing.expectEqual(QuickPlan.direct, quickPlan(Case.review(&with_unclear)));
    try testing.expectEqual(@as(usize, 2), leftOutFileCount(Case.review(&with_unclear)));
    // The default-branch confirmation still applies with files left out.
    const main_shared = [_]ReviewRepo{.{ .root = "/w", .name = "w", .branch = "main", .is_default_branch = true, .files = &.{ mine, unclear } }};
    try testing.expectEqual(QuickPlan.confirm_default_branch, quickPlan(Case.review(&main_shared)));
    // Nothing of its own, only files needing a decision: open the review.
    const no_mine = [_]ReviewRepo{.{ .root = "/w", .name = "w", .branch = "feature/x", .files = &.{ shared, unclear } }};
    try testing.expectEqual(QuickPlan.review, quickPlan(Case.review(&no_mine)));
    try testing.expectEqual(@as(usize, 0), mineFileCount(Case.review(&no_mine)));

    // Mine files commit whole; everything else stays unticked.
    const ticks = try defaultTicks(testing.allocator, Case.review(&with_shared));
    defer {
        for (ticks) |tick| testing.allocator.free(tick.hunks);
        testing.allocator.free(ticks);
    }
    try testing.expect(ticks[0].whole and !ticks[1].whole);

    // Default branch only matters for the repository holding this chat's files.
    const split = [_]ReviewRepo{
        .{ .root = "/w", .name = "w", .branch = "feature/x", .files = &.{mine} },
        .{ .root = "/l", .name = "l", .branch = "main", .is_default_branch = true, .files = &.{unassigned} },
    };
    try testing.expectEqual(QuickPlan.direct, quickPlan(Case.review(&split)));
}

test "quick commit toast names files left out" {
    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings("2 files left out (shared/unclear) \u{2014} use Commit\u{2026} to review them", leftOutNote(&buf, 2));
    try testing.expectEqualStrings("1 file left out (shared/unclear) \u{2014} use Commit\u{2026} to review them", leftOutNote(&buf, 1));
    const repos = [_]proto.RepoCommit{
        .{ .root = "/w/app", .commit = "e57cfce1234", .short_commit = "e57cfce", .subject = "Fix", .files = 2, .branch = "feature/x", .push = "pushed" },
    };
    var toast = commitToast(.{ .workspace_id = "w", .local_thread_id = "t", .files = 2, .repos = &repos }, true);
    toast.noteLeftOut(2);
    try testing.expectEqualStrings("2 files left out (shared/unclear) \u{2014} use Commit\u{2026} to review them \u{00B7} e57cfce \u{00B7} feature/x \u{00B7} Fix", toast.detail());
    var plain = commitToast(.{ .workspace_id = "w", .local_thread_id = "t", .files = 2, .repos = &repos }, true);
    plain.noteLeftOut(0);
    try testing.expectEqualStrings("e57cfce \u{00B7} feature/x \u{00B7} Fix", plain.detail());
}

test "empty message box commits the generated message" {
    try testing.expectEqualStrings("Fix typo", effectiveMessage("  Fix typo \n", "Generated").?);
    try testing.expectEqualStrings("Generated", effectiveMessage("", "Generated\n").?);
    try testing.expectEqualStrings("Generated", effectiveMessage(" \n\t", "Generated").?);
    try testing.expect(effectiveMessage("", "") == null);
    try testing.expect(effectiveMessage("  ", " \n") == null);
    try testing.expectEqualStrings("Add login", messageSubject("\nAdd login  \n\nBody text"));
    try testing.expectEqualStrings("One", messageSubject("One"));
}

test "sheet placeholder and typed text" {
    const sheet = try testing.allocator.create(Sheet);
    defer testing.allocator.destroy(sheet);
    sheet.* = .{};
    defer sheet.tick_arena.deinit();
    try testing.expect(sheet.messageToCommit() == null);
    sheet.setGenerated("  Add feature\n\nDetails\n", "feature/add-feature");
    try testing.expectEqualStrings("Add feature\n\nDetails", sheet.generated());
    try testing.expectEqualStrings("feature/add-feature", sheet.branchSuggestion().?);
    try testing.expectEqualStrings("Add feature\n\nDetails", sheet.messageToCommit().?);
    @memcpy(sheet.message_storage[0..5], "Mine!");
    sheet.message_cursor = 5;
    try testing.expectEqualStrings("Mine!", sheet.messageToCommit().?);
    sheet.clearTyped();
    try testing.expectEqual(@as(usize, 0), sheet.message().len);
    try testing.expectEqual(@as(usize, 0), sheet.message_cursor);
    sheet.setGenerated("x", null);
    try testing.expect(sheet.branchSuggestion() == null);
}

test "selection hash tracks tick changes" {
    var hunks_a = [_]bool{ true, false };
    var hunks_b = [_]bool{ true, true };
    const a = [_]FileTick{ .{ .whole = false, .hunks = &hunks_a }, .{ .whole = true } };
    const b = [_]FileTick{ .{ .whole = false, .hunks = &hunks_b }, .{ .whole = true } };
    try testing.expectEqual(selectionHash(&a), selectionHash(&a));
    try testing.expect(selectionHash(&a) != selectionHash(&b));
}

test "default branch confirmation text" {
    var buf: [320]u8 = undefined;
    try testing.expectEqualStrings("Commit & push to main?", confirmTitle(&buf, "main"));
    try testing.expectEqualStrings(
        "This will commit and push 3 files on \u{201C}main\u{201D} \u{00B7} Writing message\u{2026}. You can continue on this branch or create a feature branch and run the same action there.",
        confirmBody(&buf, 3, "main", null),
    );
    try testing.expectEqualStrings(
        "This will commit and push 1 file on \u{201C}trunk\u{201D} \u{00B7} Add login. You can continue on this branch or create a feature branch and run the same action there.",
        confirmBody(&buf, 1, "trunk", "Add login"),
    );
}

test "commit outcome names a created branch" {
    var buf: [320]u8 = undefined;
    const repos = [_]proto.RepoCommit{
        .{ .root = "/w/app", .commit = "abcdef0123", .short_commit = "abcdef0", .subject = "s", .files = 2, .branch = "feature/login", .branch_created = true, .push = "pushed" },
    };
    try testing.expectEqualStrings(
        "Committed 2 files \u{00B7} abcdef0 \u{00B7} pushed \u{00B7} on feature/login",
        commitOutcome(&buf, .{ .workspace_id = "w", .local_thread_id = "t", .files = 2, .repos = &repos }).text,
    );
    const existing = [_]proto.RepoCommit{
        .{ .root = "/w/app", .commit = "abcdef0123", .short_commit = "abcdef0", .subject = "s", .files = 2, .branch = "feature/login", .push = "pushed" },
    };
    try testing.expectEqualStrings(
        "Committed 2 files \u{00B7} abcdef0 \u{00B7} pushed",
        commitOutcome(&buf, .{ .workspace_id = "w", .local_thread_id = "t", .files = 2, .repos = &existing }).text,
    );
}

test "quick progress text per phase" {
    var quick: Quick = .{ .phase = .confirming };
    try testing.expect(quick.progressText() == null);
    quick.phase = .writing;
    try testing.expectEqualStrings("Writing message\u{2026}", quick.progressText().?);
    quick.phase = .pushing;
    try testing.expectEqualStrings("Pushing\u{2026}", quick.progressText().?);
    try testing.expectEqualStrings("main", quick.branchName());
}

test "commit toast titles and details" {
    const pushed = [_]proto.RepoCommit{
        .{ .root = "/w/app", .commit = "e57cfce1234", .short_commit = "e57cfce", .subject = "Fix login flow\n\nbody", .files = 3, .branch = "main", .push = "pushed" },
    };
    const both = commitToast(.{ .workspace_id = "w", .local_thread_id = "t", .files = 3, .repos = &pushed }, true);
    try testing.expectEqual(ToastTone.success, both.tone);
    try testing.expectEqualStrings("Committed & pushed 3 files", both.title());
    try testing.expectEqualStrings("e57cfce \u{00B7} main \u{00B7} Fix login flow", both.detail());
    try testing.expect(both.pullPushThread() == null);

    const local = [_]proto.RepoCommit{
        .{ .root = "/w/app", .commit = "1111111aaaa", .short_commit = "", .subject = "Add docs", .files = 1, .push = "not_requested" },
        .{ .root = "/w/lib", .commit = "2222222bbbb", .short_commit = "2222222", .subject = "", .files = 1, .push = "not_requested" },
    };
    const commit_only = commitToast(.{ .workspace_id = "w", .local_thread_id = "t", .files = 0, .repos = &local }, false);
    try testing.expectEqualStrings("Committed 2 files", commit_only.title());
    try testing.expectEqualStrings("1111111, 2222222 \u{00B7} Add docs", commit_only.detail());

    const rejected = [_]proto.RepoCommit{
        .{ .root = "/w/app", .commit = "abcdef0123", .short_commit = "abcdef0", .subject = "s", .files = 1, .branch = "main", .push = "rejected" },
    };
    const warn = commitToast(.{ .workspace_id = "w", .local_thread_id = "t9", .files = 1, .repos = &rejected }, true);
    try testing.expectEqual(ToastTone.warning, warn.tone);
    try testing.expectEqualStrings("Committed 1 file, push rejected", warn.title());
    try testing.expectEqualStrings("The remote has commits this branch does not. \u{00B7} abcdef0 \u{00B7} main \u{00B7} s", warn.detail());
    try testing.expectEqualStrings("t9", warn.pullPushThread().?);

    const failed = [_]proto.RepoCommit{
        .{ .root = "/w/app", .commit = "abcdef0123", .short_commit = "abcdef0", .subject = "", .files = 1, .push = "failed", .push_message = "fatal: no route\nmore" },
    };
    const bad = commitToast(.{ .workspace_id = "w", .local_thread_id = "t", .files = 1, .repos = &failed }, true);
    try testing.expectEqual(ToastTone.failure, bad.tone);
    try testing.expectEqualStrings("Committed 1 file, push failed", bad.title());
    try testing.expectEqualStrings("fatal: no route \u{00B7} abcdef0", bad.detail());
}

test "push and pull toasts" {
    const two = pushToast(1, 2, "origin/main", "main", "app", "abc1234", "Fix the thing\n\nbody");
    try testing.expectEqualStrings("Pushed 2 commits to origin/main", two.title());
    try testing.expectEqualStrings("abc1234 \u{00B7} app \u{00B7} main \u{00B7} Fix the thing", two.detail());
    try testing.expectEqualStrings("Pushed 1 commit to origin/main", pushToast(1, 1, "origin/main", "main", "app", "", "").title());
    try testing.expectEqualStrings("Published feature/x", pushToast(1, 0, "", "feature/x", "app", "", "").title());
    const many = pushToast(2, 5, "origin/main", "main", "app", "", "");
    try testing.expectEqualStrings("Pushed 5 commits to 2 repositories", many.title());
    try testing.expectEqualStrings("main", many.detail());

    const rejected = pushFailureToast("Push rejected", "rejected", null, "t1", true);
    try testing.expectEqual(ToastTone.warning, rejected.tone);
    try testing.expectEqualStrings("t1", rejected.pullPushThread().?);
    const failed = pushFailureToast("Push failed", "failed", "remote hung up", "t1", false);
    try testing.expectEqual(ToastTone.failure, failed.tone);
    try testing.expectEqualStrings("remote hung up", failed.detail());
    try testing.expect(failed.pullPushThread() == null);

    const pulled = pullPushToast("/home/me/app", "main", "", "");
    try testing.expectEqualStrings("Pulled & pushed", pulled.title());
    try testing.expectEqualStrings("app \u{00B7} main", pulled.detail());
}

test "toast phase holds success and keeps errors" {
    try testing.expect(toastPhase(TOAST_SUCCESS_HOLD_MS, TOAST_SUCCESS_HOLD_MS) == null);
    const held = toastPhase(1000, TOAST_SUCCESS_HOLD_MS).?;
    try testing.expectEqual(@as(f32, 1.0), held.alpha);
    try testing.expect(!held.animating);
    try testing.expect(toastPhase(TOAST_SUCCESS_HOLD_MS - 10, TOAST_SUCCESS_HOLD_MS).?.animating);
    try testing.expect(toastPhase(0, TOAST_SUCCESS_HOLD_MS).?.animating);
    const sticky = toastPhase(10 * TOAST_SUCCESS_HOLD_MS, null).?;
    try testing.expectEqual(@as(f32, 1.0), sticky.alpha);
    try testing.expect(!sticky.animating);
}

test "commit card push button visibility" {
    const ahead: RepoFacts = .{ .ahead = 2, .has_remote = true };
    try testing.expectEqual(CardPush.available, cardPushState(false, true, ahead, false));
    // Already pushed rows never offer Push, even while a push runs.
    try testing.expectEqual(CardPush.hidden, cardPushState(true, true, ahead, false));
    try testing.expectEqual(CardPush.hidden, cardPushState(true, true, ahead, true));
    try testing.expectEqual(CardPush.running, cardPushState(false, true, ahead, true));
    // Nothing left to push on the branch (pushed from a terminal, say).
    try testing.expectEqual(CardPush.hidden, cardPushState(false, true, .{ .has_remote = true }, false));
    // No remote anywhere, or branch facts not loaded yet.
    try testing.expectEqual(CardPush.hidden, cardPushState(false, false, .{ .ahead = 1 }, false));
    try testing.expectEqual(CardPush.hidden, cardPushState(false, true, null, false));
    // A row link proves a remote even when the facts missed it; unpublished
    // branches push too.
    try testing.expectEqual(CardPush.available, cardPushState(false, true, .{ .unpublished = true }, false));
    try testing.expectEqual(CardPush.available, cardPushState(false, false, .{ .unpublished = true, .has_remote = true }, false));
}
