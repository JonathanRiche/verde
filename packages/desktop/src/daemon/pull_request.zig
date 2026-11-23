//! GitHub pull requests for a chat's pushed feature branch: the daemon side
//! of `git.changes.pr_prepare` / `pr_message` / `pr_create` (contract in
//! headless git_changes_protocol.zig, "Pull requests").
//!
//! Local facts come from git (`git_changes.Git`). GitHub is reached only
//! through the GitHub CLI behind `Runner`, so tests script `gh` instead of
//! touching the network. Argument building, output parsing, eligibility and
//! the fallback/generated text are pure functions. Every `gh` call has a
//! finite deadline, and nothing here pushes: a branch must already be pushed.
//!
//! This module owns no locks; the daemon calls it with no daemon lock held.

const std = @import("std");

const proto = @import("headless").git_changes_protocol;
const process_env = @import("../platform/env.zig");
const git_changes = @import("git_changes.zig");

const log = std.log.scoped(.pull_request);

const Git = git_changes.Git;
pub const Error = git_changes.Error;

/// `gh auth status` may refresh a token over the network.
pub const AUTH_TIMEOUT_MS: i64 = 15_000;
pub const LIST_TIMEOUT_MS: i64 = 20_000;
pub const CREATE_TIMEOUT_MS: i64 = 60_000;
/// Commits listed in `PrPrepareResult.subjects` and the generation prompt.
pub const MAX_LISTED_COMMITS: usize = 50;
pub const MAX_TITLE_BYTES: usize = 256;
/// GitHub rejects bodies over 65536 characters.
pub const MAX_BODY_BYTES: usize = 60 * 1024;
/// Diff text sent to the model, like commit message generation.
pub const DIFF_BUDGET: usize = 20 * 1024;
const GH_OUTPUT_LIMIT: usize = 1024 * 1024;

/// A one-line, user-facing failure with its protocol error code.
pub const Failure = struct {
    code: []const u8,
    message: []const u8,
};

pub fn Outcome(comptime T: type) type {
    return union(enum) { ok: T, failed: Failure };
}

// ---------------------------------------------------------------------------
// GitHub remotes (pure)

pub const GithubRepo = struct {
    host: []const u8,
    owner: []const u8,
    name: []const u8,

    /// `HOST/OWNER/REPO`, the form `gh --repo` accepts on every host.
    pub fn slug(self: GithubRepo, arena: std.mem.Allocator) Error![]const u8 {
        return std.fmt.allocPrint(arena, "{s}/{s}/{s}", .{ self.host, self.owner, self.name }) catch error.OutOfMemory;
    }

    /// `OWNER/REPO` for display.
    pub fn display(self: GithubRepo, arena: std.mem.Allocator) Error![]const u8 {
        return std.fmt.allocPrint(arena, "{s}/{s}", .{ self.owner, self.name }) catch error.OutOfMemory;
    }
};

/// The GitHub repository a remote URL points at (`git@github.com:o/r.git`,
/// `ssh://git@github.com/o/r`, `https://github.com/o/r(.git)`), or null for
/// any other host or shape. GitHub Enterprise Cloud (`*.ghe.com`) counts;
/// self-hosted Enterprise Server hosts are not recognised.
pub fn parseGithubRemote(url_raw: []const u8) ?GithubRepo {
    const url = std.mem.trim(u8, url_raw, " \t\r\n");
    if (url.len == 0) return null;
    var host: []const u8 = undefined;
    var path: []const u8 = undefined;
    if (std.mem.indexOf(u8, url, "://")) |scheme_end| {
        const scheme = url[0..scheme_end];
        const known = for ([_][]const u8{ "https", "http", "ssh", "git", "git+ssh" }) |candidate| {
            if (std.ascii.eqlIgnoreCase(scheme, candidate)) break true;
        } else false;
        if (!known) return null;
        const rest = url[scheme_end + 3 ..];
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return null;
        host = rest[0..slash];
        path = rest[slash + 1 ..];
    } else {
        // scp-like `[user@]host:owner/repo`; a `/` before the `:` means a path.
        const colon = std.mem.indexOfScalar(u8, url, ':') orelse return null;
        if (std.mem.indexOfScalar(u8, url[0..colon], '/') != null) return null;
        host = url[0..colon];
        path = url[colon + 1 ..];
    }
    if (std.mem.lastIndexOfScalar(u8, host, '@')) |at| host = host[at + 1 ..];
    if (std.mem.indexOfScalar(u8, host, ':')) |port| host = host[0..port];
    const canonical = githubHost(host) orelse return null;
    path = std.mem.trim(u8, path, "/");
    if (std.mem.endsWith(u8, path, ".git")) path = path[0 .. path.len - ".git".len];
    const slash = std.mem.indexOfScalar(u8, path, '/') orelse return null;
    const owner = path[0..slash];
    const name = path[slash + 1 ..];
    if (!validRepoPart(owner) or !validRepoPart(name)) return null;
    return .{ .host = canonical, .owner = owner, .name = name };
}

fn githubHost(host: []const u8) ?[]const u8 {
    for ([_][]const u8{ "github.com", "www.github.com", "ssh.github.com" }) |candidate| {
        if (std.ascii.eqlIgnoreCase(host, candidate)) return "github.com";
    }
    if (host.len > ".ghe.com".len and std.ascii.endsWithIgnoreCase(host, ".ghe.com")) {
        for (host) |c| if (!(std.ascii.isAlphanumeric(c) or c == '.' or c == '-')) return null;
        return host;
    }
    return null;
}

fn validRepoPart(part: []const u8) bool {
    if (part.len == 0 or part.len > 100) return false;
    for (part) |c| if (!(std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.')) return false;
    return true;
}

// ---------------------------------------------------------------------------
// Eligibility (pure)

pub const Problem = enum {
    detached_head,
    no_default_branch,
    on_default_branch,
    not_github,
    nothing_ahead,
    not_pushed,

    /// How far a repository got towards a PR; when no repository of a chat
    /// is eligible, the furthest one's problem is reported.
    fn rank(self: Problem) u8 {
        return @intFromEnum(self);
    }

    pub fn code(self: Problem) []const u8 {
        return switch (self) {
            .detached_head => proto.ERR_DETACHED_HEAD,
            .no_default_branch => proto.ERR_NO_DEFAULT_BRANCH,
            .on_default_branch => proto.ERR_ON_DEFAULT_BRANCH,
            .not_github => proto.ERR_NOT_GITHUB,
            .nothing_ahead => proto.ERR_NOTHING_AHEAD,
            .not_pushed => proto.ERR_NOT_PUSHED,
        };
    }
};

/// Branch facts that decide whether a PR can be opened.
pub const BranchFacts = struct {
    /// Null when HEAD is detached.
    branch: ?[]const u8 = null,
    default_branch: ?[]const u8 = null,
    upstream: ?[]const u8 = null,
    has_remote: bool = false,
    /// Commits not on the upstream (on no remote-tracking ref when there is
    /// no upstream yet): `RepoStatus.ahead`.
    unpushed: u32 = 0,
    /// Commits the remote default branch does not have.
    ahead_of_default: u32 = 0,
    /// The push remote is on GitHub.
    github: bool = false,
};

pub fn branchProblem(facts: BranchFacts) ?Problem {
    const branch = facts.branch orelse return .detached_head;
    const default = facts.default_branch orelse return .no_default_branch;
    if (std.mem.eql(u8, branch, default)) return .on_default_branch;
    if (!facts.github) return .not_github;
    if (facts.ahead_of_default == 0) return .nothing_ahead;
    if (facts.upstream == null or facts.unpushed > 0) return .not_pushed;
    return null;
}

/// One-line message for a branch problem.
pub fn problemFailure(arena: std.mem.Allocator, problem: Problem, facts: BranchFacts) Error!Failure {
    const branch = facts.branch orelse "";
    const default = facts.default_branch orelse "the default branch";
    const message: []const u8 = switch (problem) {
        .detached_head => "HEAD is detached. Switch to a branch to open a pull request.",
        .no_default_branch => "Couldn't tell this repository's default branch (no origin/HEAD, main or master).",
        .on_default_branch => try fmt(arena, "{s} is the default branch. Commit on a feature branch to open a pull request.", .{branch}),
        .not_github => if (facts.has_remote) "This repository's remote is not on GitHub." else "This repository has no remote on GitHub.",
        .nothing_ahead => try fmt(arena, "{s} has no commits that {s} doesn't have.", .{ branch, default }),
        .not_pushed => if (facts.upstream == null)
            try fmt(arena, "Push {s} first: it is not on GitHub yet.", .{branch})
        else
            try fmt(arena, "Push {s} first: {d} commit{s} not on GitHub yet.", .{ branch, facts.unpushed, if (facts.unpushed == 1) " is" else "s are" }),
    };
    return .{ .code = problem.code(), .message = message };
}

/// Index of the first eligible candidate, or of the one whose problem got
/// furthest (first wins ties) so the reported reason is the most useful.
pub fn pickCandidate(problems: []const ?Problem) struct { index: usize, problem: ?Problem } {
    var best: usize = 0;
    for (problems, 0..) |maybe, index| {
        const problem = maybe orelse return .{ .index = index, .problem = null };
        if (problem.rank() > problems[best].?.rank()) best = index;
    }
    return .{ .index = best, .problem = if (problems.len > 0) problems[best] else .detached_head };
}

/// Title and body as the user confirmed them, or why not.
pub fn validateText(title_raw: []const u8, body: []const u8) ?Failure {
    const title = std.mem.trim(u8, title_raw, " \t\r\n");
    if (title.len == 0) return .{ .code = "invalid_params", .message = "The pull request needs a title." };
    if (std.mem.indexOfAny(u8, title, "\r\n") != null) return .{ .code = "invalid_params", .message = "The title must be a single line." };
    if (title.len > MAX_TITLE_BYTES) return .{ .code = "invalid_params", .message = "The title is too long (256 bytes at most)." };
    if (body.len > MAX_BODY_BYTES) return .{ .code = "invalid_params", .message = "The description is too long (60 KiB at most)." };
    return null;
}

// ---------------------------------------------------------------------------
// gh arguments (pure)

/// No `--active`: gh before 2.40 rejects it, which would read as signed out.
pub fn authStatusArgs(host: []const u8) [4][]const u8 {
    return .{ "auth", "status", "--hostname", host };
}

/// The open PR whose head is `branch` (`gh pr list` never prompts).
pub fn listArgs(repo_slug: []const u8, branch: []const u8) [12][]const u8 {
    return .{ "pr", "list", "--repo", repo_slug, "--head", branch, "--state", "open", "--limit", "1", "--json", "number,url,title,isDraft" };
}

pub const CreateArgs = struct {
    repo_slug: []const u8,
    base: []const u8,
    head: []const u8,
    title: []const u8,
    body_file: []const u8,
    draft: bool = false,
};

/// `--head` keeps gh from pushing or forking; `--repo` from guessing among
/// remotes; the body goes through a file so its size never meets argv limits.
pub fn createArgs(arena: std.mem.Allocator, options: CreateArgs) Error![]const []const u8 {
    var args: std.ArrayList([]const u8) = .empty;
    args.appendSlice(arena, &.{
        "pr",          "create",
        "--repo",      options.repo_slug,
        "--base",      options.base,
        "--head",      options.head,
        "--title",     options.title,
        "--body-file", options.body_file,
    }) catch return error.OutOfMemory;
    if (options.draft) args.append(arena, "--draft") catch return error.OutOfMemory;
    return args.items;
}

// ---------------------------------------------------------------------------
// gh output (pure)

pub const PullRequest = proto.PullRequest;

pub const UrlMatch = struct { url: []const u8, number: u32 };

/// Last `https://<host>/<owner>/<repo>/pull/<number>` in `text`.
pub fn findPullRequestUrl(text: []const u8) ?UrlMatch {
    var found: ?UrlMatch = null;
    var tokens = std.mem.tokenizeAny(u8, text, " \t\r\n\"'<>()");
    while (tokens.next()) |raw| {
        const token = std.mem.trimEnd(u8, raw, ".,;:");
        if (!std.mem.startsWith(u8, token, "https://")) continue;
        const marker = std.mem.lastIndexOf(u8, token, "/pull/") orelse continue;
        const digits = token[marker + "/pull/".len ..];
        const number = std.fmt.parseInt(u32, digits, 10) catch continue;
        if (number == 0) continue;
        found = .{ .url = token, .number = number };
    }
    return found;
}

/// First PR of a `gh pr list --json number,url,title,isDraft` array.
pub fn parseOpenList(arena: std.mem.Allocator, stdout: []const u8) Error!?PullRequest {
    const Row = struct { number: u32, url: []const u8, title: []const u8 = "", isDraft: bool = false };
    const trimmed = std.mem.trim(u8, stdout, " \t\r\n");
    if (trimmed.len == 0) return null;
    const rows = std.json.parseFromSliceLeaky([]const Row, arena, trimmed, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch return error.GitUnavailable;
    if (rows.len == 0) return null;
    return .{ .number = rows[0].number, .url = rows[0].url, .title = rows[0].title, .draft = rows[0].isDraft };
}

pub const GhFailureKind = enum { not_authenticated, already_exists, nothing_ahead, not_pushed, network, other };

/// What a failed `gh` call's output says went wrong.
pub fn classifyGhFailure(output: []const u8) GhFailureKind {
    const Probe = struct {
        fn has(text: []const u8, needle: []const u8) bool {
            return containsIgnoreCase(text, needle);
        }
    };
    if (Probe.has(output, "already exists")) return .already_exists;
    if (Probe.has(output, "gh auth login") or Probe.has(output, "not logged in") or Probe.has(output, "HTTP 401") or
        Probe.has(output, "Bad credentials") or Probe.has(output, "authentication required") or Probe.has(output, "token in") or Probe.has(output, "invalid token"))
    {
        return .not_authenticated;
    }
    // GitHub answers a head missing on the remote with blank shas.
    if (Probe.has(output, "Head sha can't be blank") or Probe.has(output, "Head ref must be a branch") or Probe.has(output, "must first push")) return .not_pushed;
    if (Probe.has(output, "No commits between")) return .nothing_ahead;
    if (Probe.has(output, "dial tcp") or Probe.has(output, "no such host") or Probe.has(output, "could not resolve") or
        Probe.has(output, "connection refused") or Probe.has(output, "i/o timeout") or Probe.has(output, "network is unreachable") or Probe.has(output, "TLS handshake"))
    {
        return .network;
    }
    return .other;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (haystack.len < needle.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

/// The last meaningful line of gh's output, for `gh_failed` messages.
pub fn ghMessage(output: []const u8) []const u8 {
    var lines = std.mem.splitBackwardsScalar(u8, output, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        // gh prints a usage hint after some errors; the error is above it.
        if (std.mem.startsWith(u8, trimmed, "Usage:") or std.mem.startsWith(u8, trimmed, "Run '")) continue;
        return trimmed[0..@min(trimmed.len, 300)];
    }
    return "gh did not succeed.";
}

/// Maps a failed gh run to the failure the user sees.
pub fn ghFailure(result: RunResult) Failure {
    if (result.timed_out) return .{ .code = proto.ERR_GH_FAILED, .message = "GitHub did not answer in time. Check your connection and try again." };
    const output = if (std.mem.trim(u8, result.stderr, " \t\r\n").len > 0) result.stderr else result.stdout;
    return switch (classifyGhFailure(output)) {
        .not_authenticated => unauthenticated,
        .not_pushed => .{ .code = proto.ERR_NOT_PUSHED, .message = "The branch is not on GitHub yet. Push it first." },
        .nothing_ahead => .{ .code = proto.ERR_NOTHING_AHEAD, .message = "GitHub sees no commits between the branch and its base." },
        .network => .{ .code = proto.ERR_GH_FAILED, .message = "Couldn't reach GitHub. Check your connection and try again." },
        .already_exists, .other => .{ .code = proto.ERR_GH_FAILED, .message = ghMessage(output) },
    };
}

pub const gh_missing: Failure = .{ .code = proto.ERR_GH_MISSING, .message = "GitHub CLI (gh) is not installed. Install it from cli.github.com to open pull requests." };
pub const unauthenticated: Failure = .{ .code = proto.ERR_GH_UNAUTHENTICATED, .message = "GitHub CLI is not signed in. Run `gh auth login`, then try again." };

// ---------------------------------------------------------------------------
// Pull request text (pure)

pub const Text = struct {
    title: []const u8,
    body: []const u8 = "",
};

pub const Commit = struct {
    sha: []const u8,
    subject: []const u8,
    body: []const u8 = "",
};

/// Records of `git log --format=%H%x1f%s%x1f%b%x1e`.
pub fn parseLog(arena: std.mem.Allocator, stdout: []const u8) Error![]Commit {
    var commits: std.ArrayList(Commit) = .empty;
    var records = std.mem.splitScalar(u8, stdout, 0x1e);
    while (records.next()) |raw| {
        const record = std.mem.trim(u8, raw, " \t\r\n");
        if (record.len == 0) continue;
        var fields = std.mem.splitScalar(u8, record, 0x1f);
        const sha = std.mem.trim(u8, fields.next() orelse continue, " \t\r\n");
        const subject = std.mem.trim(u8, fields.next() orelse "", " \t\r\n");
        const body = std.mem.trim(u8, fields.rest(), " \t\r\n");
        if (sha.len == 0) continue;
        commits.append(arena, .{ .sha = sha, .subject = subject, .body = body }) catch return error.OutOfMemory;
    }
    return commits.items;
}

/// `feature/add-dark-mode` -> `Add dark mode`; empty when nothing is left.
pub fn titleFromBranch(arena: std.mem.Allocator, branch: []const u8) Error![]const u8 {
    const last = if (std.mem.lastIndexOfScalar(u8, branch, '/')) |slash| branch[slash + 1 ..] else branch;
    var out: std.ArrayList(u8) = .empty;
    var pending_space = false;
    for (last) |c| {
        if (c == '-' or c == '_' or c == ' ' or c == '.') {
            pending_space = out.items.len > 0;
            continue;
        }
        if (pending_space) out.append(arena, ' ') catch return error.OutOfMemory;
        pending_space = false;
        out.append(arena, c) catch return error.OutOfMemory;
    }
    if (out.items.len > 0) out.items[0] = std.ascii.toUpper(out.items[0]);
    return out.items;
}

/// Text used when the model is unavailable: one commit gives its subject and
/// body; several give a title from the branch name (else the newest subject)
/// and a list of subjects, oldest first. `commits` is oldest first.
pub fn fallbackText(arena: std.mem.Allocator, commits: []const Commit, branch: []const u8) Error!Text {
    if (commits.len == 1) return .{ .title = clampTitle(commits[0].subject), .body = clampBody(commits[0].body) };
    var title = try titleFromBranch(arena, branch);
    if (title.len == 0 and commits.len > 0) title = commits[commits.len - 1].subject;
    if (title.len == 0) title = branch;
    var body: std.ArrayList(u8) = .empty;
    for (commits) |commit| {
        body.print(arena, "- {s}\n", .{commit.subject}) catch return error.OutOfMemory;
    }
    return .{ .title = clampTitle(title), .body = clampBody(std.mem.trimEnd(u8, body.items, "\n")) };
}

/// Splits a model reply into a title (first non-empty line) and body (the
/// rest), dropping fences, quotes and `Title:`/`Description:` labels a model
/// may add. Null when no title is left.
pub fn splitGeneratedText(arena: std.mem.Allocator, raw: []const u8) Error!?Text {
    const text = (try git_changes.normalizeGeneratedMessage(arena, raw)) orelse return null;
    var lines = std.mem.splitScalar(u8, text, '\n');
    var title: []const u8 = "";
    while (lines.next()) |line| {
        title = std.mem.trim(u8, line, " \t\r");
        if (title.len > 0) break;
    }
    title = std.mem.trimStart(u8, title, "# ");
    title = stripLabel(title, &.{ "title:", "pr title:", "pull request title:" });
    title = std.mem.trim(u8, title, " \t*_`\"'");
    if (title.len == 0) return null;
    var body = std.mem.trim(u8, lines.rest(), " \t\r\n");
    // A `Description:` / `Body:` label line before the body.
    const first_end = std.mem.indexOfScalar(u8, body, '\n') orelse body.len;
    const first = std.mem.trim(u8, body[0..first_end], " \t\r*_#");
    const labels = [_][]const u8{ "description:", "body:", "summary:" };
    for (labels) |label| {
        if (std.ascii.eqlIgnoreCase(first, label)) {
            body = std.mem.trim(u8, body[first_end..], " \t\r\n");
            break;
        }
    }
    body = stripLabel(body, &labels);
    return .{ .title = clampTitle(title), .body = clampBody(std.mem.trim(u8, body, " \t\r\n")) };
}

fn stripLabel(text: []const u8, labels: []const []const u8) []const u8 {
    for (labels) |label| {
        if (text.len >= label.len and std.ascii.eqlIgnoreCase(text[0..label.len], label)) return std.mem.trim(u8, text[label.len..], " \t");
    }
    return text;
}

fn clampTitle(raw: []const u8) []const u8 {
    const line = git_changes.firstLine(raw);
    return utf8Prefix(line, MAX_TITLE_BYTES);
}

fn clampBody(raw: []const u8) []const u8 {
    return utf8Prefix(raw, MAX_BODY_BYTES);
}

fn utf8Prefix(text: []const u8, max_bytes: usize) []const u8 {
    if (text.len <= max_bytes) return text;
    var end = max_bytes;
    while (end > 0 and (text[end] & 0xC0) == 0x80) end -= 1;
    return text[0..end];
}

pub const PromptInput = struct {
    branch: []const u8,
    base: []const u8,
    chat_title: []const u8 = "",
    /// Oldest first.
    commits: []const Commit,
    stat: []const u8 = "",
    diff: []const u8 = "",
};

pub fn buildPrompt(arena: std.mem.Allocator, input: PromptInput) Error![]const u8 {
    var commit_lines: std.ArrayList(u8) = .empty;
    for (input.commits) |commit| {
        commit_lines.print(arena, "- {s}\n", .{commit.subject}) catch return error.OutOfMemory;
        if (commit.body.len > 0) {
            var body_lines = std.mem.splitScalar(u8, utf8Prefix(commit.body, 1200), '\n');
            while (body_lines.next()) |line| commit_lines.print(arena, "  {s}\n", .{line}) catch return error.OutOfMemory;
        }
    }
    return fmt(arena,
        \\Write a GitHub pull request title and description for the branch below.
        \\Output only the pull request: the title on the first line (concise, imperative, at most 72 characters, no "Title:" label), then a blank line, then a short Markdown description of what changed and why (a few sentences or bullets). No code fences around the reply, no preamble. Do not run tools or read files; everything you need is here.
        \\
        \\Branch: {s} into {s}
        \\Chat that made the changes: {s}
        \\
        \\Commits (oldest first):
        \\{s}
        \\Changed files:
        \\{s}
        \\
        \\Diff:
        \\{s}
    , .{ input.branch, input.base, input.chat_title, commit_lines.items, input.stat, input.diff });
}

/// Transcript row written after `pr_create` (format in the protocol docs).
pub fn rowBody(arena: std.mem.Allocator, pr: PullRequest, title: []const u8) Error![]const u8 {
    return fmt(arena, "Opened {s}pull request #{d}: {s}\n{s}", .{ if (pr.draft) "draft " else "", pr.number, git_changes.firstLine(title), pr.url });
}

fn fmt(arena: std.mem.Allocator, comptime format: []const u8, args: anytype) Error![]const u8 {
    return std.fmt.allocPrint(arena, format, args) catch error.OutOfMemory;
}

// ---------------------------------------------------------------------------
// gh process

pub const RunResult = struct {
    exit_code: ?u8,
    stdout: []const u8 = "",
    stderr: []const u8 = "",
    /// Killed at its deadline.
    timed_out: bool = false,

    pub fn ok(self: RunResult) bool {
        return !self.timed_out and self.exit_code != null and self.exit_code.? == 0;
    }
};

pub const RunError = error{ OutOfMemory, GhMissing };

/// Runs `gh <args>` in `cwd` with a deadline. Injectable so tests script gh.
pub const Runner = struct {
    context: *anyopaque,
    runFn: *const fn (context: *anyopaque, arena: std.mem.Allocator, cwd: []const u8, args: []const []const u8, timeout_ms: i64) RunError!RunResult,

    pub fn run(self: Runner, arena: std.mem.Allocator, cwd: []const u8, args: []const []const u8, timeout_ms: i64) RunError!RunResult {
        return self.runFn(self.context, arena, cwd, args, timeout_ms);
    }
};

/// The real GitHub CLI, resolved on the daemon's augmented PATH. Prompts,
/// colour, pagers and update notices are off; stdin is closed.
pub const Gh = struct {
    env: std.process.Environ.Map,
    /// Null when `gh` is not installed.
    executable: ?[]const u8,

    pub fn init(arena: std.mem.Allocator) Error!Gh {
        var env = process_env.buildAugmentedEnvMap(arena) catch return error.GitUnavailable;
        errdefer env.deinit();
        for ([_][2][]const u8{
            .{ "GH_PROMPT_DISABLED", "1" },
            .{ "GH_NO_UPDATE_NOTIFIER", "1" },
            .{ "GH_NO_EXTENSION_UPDATE_NOTIFIER", "1" },
            .{ "GH_SPINNER_DISABLED", "1" },
            .{ "NO_COLOR", "1" },
            .{ "CLICOLOR", "0" },
            .{ "GH_PAGER", "cat" },
            .{ "GIT_TERMINAL_PROMPT", "0" },
            .{ "LC_ALL", "C" },
        }) |pair| env.put(pair[0], pair[1]) catch return error.OutOfMemory;
        const executable: ?[]const u8 = process_env.resolveExecutableInEnvMapAlloc(arena, &env, "gh") catch null;
        return .{ .env = env, .executable = executable };
    }

    pub fn deinit(self: *Gh) void {
        self.env.deinit();
    }

    pub fn runner(self: *Gh) Runner {
        return .{ .context = self, .runFn = run };
    }

    fn run(context: *anyopaque, arena: std.mem.Allocator, cwd: []const u8, args: []const []const u8, timeout_ms: i64) RunError!RunResult {
        const self: *Gh = @ptrCast(@alignCast(context));
        const executable = self.executable orelse return error.GhMissing;
        const argv = arena.alloc([]const u8, args.len + 1) catch return error.OutOfMemory;
        argv[0] = executable;
        @memcpy(argv[1..], args);
        process_env.spawnPreflight(executable, cwd) catch return .{ .exit_code = null, .stderr = "gh could not start in this repository folder." };
        var threaded: std.Io.Threaded = .init(arena, .{});
        defer threaded.deinit();
        const io = threaded.io();
        const duration: std.Io.Timeout = .{ .duration = .{ .raw = .fromMilliseconds(timeout_ms), .clock = .awake } };
        const result = std.process.run(arena, io, .{
            .argv = argv,
            .cwd = .{ .path = cwd },
            .environ_map = &self.env,
            .stdout_limit = .limited(GH_OUTPUT_LIMIT),
            .stderr_limit = .limited(GH_OUTPUT_LIMIT),
            // One deadline for the whole call, not one per read.
            .timeout = duration.toDeadline(io),
        }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Timeout => {
                log.warn("gh {s} timed out after {d}ms", .{ args[0], timeout_ms });
                return .{ .exit_code = null, .timed_out = true };
            },
            error.FileNotFound => return error.GhMissing,
            else => {
                log.warn("gh {s} failed to run err={s}", .{ args[0], @errorName(err) });
                return .{ .exit_code = null, .stderr = "gh could not run." };
            },
        };
        const exit_code: ?u8 = switch (result.term) {
            .exited => |code| code,
            else => null,
        };
        return .{ .exit_code = exit_code, .stdout = result.stdout, .stderr = result.stderr };
    }
};

// ---------------------------------------------------------------------------
// Orchestration (git + gh)

/// A repository's branch as far as a pull request is concerned.
pub const Branch = struct {
    root: []const u8,
    facts: BranchFacts,
    /// Null when the push remote is not on GitHub.
    repo: ?GithubRepo = null,
    /// Ref the base is compared against (`refs/remotes/origin/<default>`, else
    /// the local default branch); null without a default branch.
    base_ref: ?[]const u8 = null,

    pub fn problem(self: Branch) ?Problem {
        return branchProblem(self.facts);
    }
};

/// Reads branch facts from git only (no network).
pub fn inspect(git: *Git, root: []const u8) Error!Branch {
    const status = try git_changes.repoStatus(git, root);
    var branch: Branch = .{ .root = root, .facts = .{
        .branch = status.branch,
        .default_branch = status.default_branch,
        .upstream = status.upstream,
        .has_remote = status.has_remote,
        .unpushed = status.ahead,
    } };
    if (status.default_branch) |default| branch.base_ref = try baseRef(git, root, default);
    // The default branch itself needs no remote lookups.
    if (status.branch == null or status.is_default_branch) return branch;
    if (status.has_remote) {
        if (try git_changes.pushRemoteUrl(git, root)) |url| {
            branch.repo = parseGithubRemote(url);
            branch.facts.github = branch.repo != null;
        }
    }
    if (branch.base_ref) |ref| branch.facts.ahead_of_default = try countAhead(git, root, ref);
    return branch;
}

/// `RepoStatus.github` / `ahead_of_default` for `git.changes.status`.
/// `github` is known for any branch with a remote (so a commit onto a new
/// branch from the default one can still offer a PR); `ahead_of_default`
/// only for a branch other than the default.
pub const StatusExtras = struct { github: bool = false, ahead_of_default: ?u32 = null };

pub fn statusExtras(git: *Git, root: []const u8, status: git_changes.RepoStatus) Error!StatusExtras {
    if (status.branch == null or !status.has_remote) return .{};
    const url = (try git_changes.pushRemoteUrl(git, root)) orelse return .{};
    const github = parseGithubRemote(url) != null;
    if (!github or status.is_default_branch) return .{ .github = github };
    const default = status.default_branch orelse return .{ .github = github };
    const ref = (try baseRef(git, root, default)) orelse return .{ .github = github };
    return .{ .github = github, .ahead_of_default = try countAhead(git, root, ref) };
}

fn baseRef(git: *Git, root: []const u8, default: []const u8) Error!?[]const u8 {
    for ([_][]const u8{ "refs/remotes/origin/", "refs/heads/" }) |prefix| {
        const ref = fmt(git.arena, "{s}{s}", .{ prefix, default }) catch return error.OutOfMemory;
        const found = try git.run(root, &.{ "rev-parse", "-q", "--verify", ref }, .{});
        if (found.ok()) return ref;
    }
    return null;
}

fn countAhead(git: *Git, root: []const u8, base_ref: []const u8) Error!u32 {
    const range = fmt(git.arena, "{s}..HEAD", .{base_ref}) catch return error.OutOfMemory;
    const result = try git.run(root, &.{ "rev-list", "--count", range }, .{});
    if (!result.ok()) return 0;
    return std.fmt.parseInt(u32, std.mem.trim(u8, result.stdout, " \t\r\n"), 10) catch 0;
}

/// Commits on HEAD the base does not have, oldest first (newest
/// `MAX_LISTED_COMMITS`), merges left out.
pub fn commitsAhead(git: *Git, root: []const u8, base_ref: []const u8) Error![]Commit {
    const range = fmt(git.arena, "{s}..HEAD", .{base_ref}) catch return error.OutOfMemory;
    const limit = fmt(git.arena, "-{d}", .{MAX_LISTED_COMMITS}) catch return error.OutOfMemory;
    const result = try git.run(root, &.{ "log", "--no-merges", "--reverse", limit, "--format=%H%x1f%s%x1f%b%x1e", range }, .{});
    if (!result.ok()) return &.{};
    return parseLog(git.arena, result.stdout);
}

/// `--stat` and a bounded diff of the branch against its merge base.
pub fn diffAhead(git: *Git, root: []const u8, base_ref: []const u8) Error!struct { stat: []const u8, diff: []const u8 } {
    const range = fmt(git.arena, "{s}...HEAD", .{base_ref}) catch return error.OutOfMemory;
    const stat = try git.run(root, &.{ "diff", "--no-ext-diff", "--no-color", "--stat=120", range }, .{});
    const diff = try git.run(root, &.{ "diff", "--no-ext-diff", "--no-color", range }, .{});
    var text: []const u8 = if (diff.ok()) diff.stdout else "";
    if (text.len > DIFF_BUDGET) {
        text = fmt(git.arena, "{s}\n[diff truncated]\n", .{utf8Prefix(text, DIFF_BUDGET)}) catch return error.OutOfMemory;
    }
    return .{ .stat = if (stat.ok()) std.mem.trim(u8, stat.stdout, "\n") else "", .diff = text };
}

/// gh installed and signed in to `host`; null when ready.
pub fn checkAuth(runner: Runner, arena: std.mem.Allocator, cwd: []const u8, host: []const u8) error{OutOfMemory}!?Failure {
    const args = authStatusArgs(host);
    const result = runner.run(arena, cwd, &args, AUTH_TIMEOUT_MS) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.GhMissing => return gh_missing,
    };
    if (result.ok()) return null;
    // A timeout or network problem says nothing about the account; any other
    // failure means it cannot be used.
    if (result.timed_out) return ghFailure(result);
    const output = if (std.mem.trim(u8, result.stderr, " \t\r\n").len > 0) result.stderr else result.stdout;
    if (classifyGhFailure(output) == .network) return ghFailure(result);
    return unauthenticated;
}

/// The open PR whose head is `branch`, if any.
pub fn findOpen(runner: Runner, arena: std.mem.Allocator, cwd: []const u8, repo: GithubRepo, branch: []const u8) error{OutOfMemory}!Outcome(?PullRequest) {
    const slug = repo.slug(arena) catch return error.OutOfMemory;
    const args = listArgs(slug, branch);
    const result = runner.run(arena, cwd, &args, LIST_TIMEOUT_MS) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.GhMissing => return .{ .failed = gh_missing },
    };
    if (!result.ok()) return .{ .failed = ghFailure(result) };
    const found = parseOpenList(arena, result.stdout) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .failed = .{ .code = proto.ERR_GH_FAILED, .message = "gh returned an unexpected pull request list." } },
    };
    return .{ .ok = found };
}

pub const Created = struct {
    pull_request: PullRequest,
    /// gh reported a PR already open for the branch.
    existing: bool = false,
};

/// `gh pr create`. A PR already open for the head is returned, not failed.
pub fn create(runner: Runner, arena: std.mem.Allocator, cwd: []const u8, options: CreateArgs) error{OutOfMemory}!Outcome(Created) {
    const args = createArgs(arena, options) catch return error.OutOfMemory;
    const result = runner.run(arena, cwd, args, CREATE_TIMEOUT_MS) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.GhMissing => return .{ .failed = gh_missing },
    };
    // gh prints the URL even when a later step (labels, attachments) fails.
    if (findPullRequestUrl(result.stdout)) |found| {
        return .{ .ok = .{ .pull_request = .{ .number = found.number, .url = found.url, .title = options.title, .draft = options.draft } } };
    }
    if (result.ok()) return .{ .failed = .{ .code = proto.ERR_GH_FAILED, .message = "gh did not print the pull request URL." } };
    if (!result.timed_out and classifyGhFailure(result.stderr) == .already_exists) {
        if (findPullRequestUrl(result.stderr)) |found| {
            return .{ .ok = .{ .pull_request = .{ .number = found.number, .url = found.url }, .existing = true } };
        }
    }
    return .{ .failed = ghFailure(result) };
}

/// The eligible repository among `roots` (first wins), or the problem of
/// the one that got furthest.
pub fn inspectFirstEligible(git: *Git, roots: []const []const u8) Error!Outcome(Branch) {
    if (roots.len == 0) return .{ .failed = .{ .code = proto.ERR_NOT_GITHUB, .message = "This chat has no git repository." } };
    const branches = git.arena.alloc(Branch, roots.len) catch return error.OutOfMemory;
    const problems = git.arena.alloc(?Problem, roots.len) catch return error.OutOfMemory;
    for (roots, branches, problems) |root, *branch, *problem| {
        branch.* = try inspect(git, root);
        problem.* = branch.problem();
    }
    const pick = pickCandidate(problems);
    if (pick.problem) |problem| return .{ .failed = try problemFailure(git.arena, problem, branches[pick.index].facts) };
    return .{ .ok = branches[pick.index] };
}

pub const Prepared = struct {
    branch: Branch,
    repo: GithubRepo,
    base: []const u8,
    /// Oldest first.
    commits: []const Commit,
    fallback: Text,
    existing: ?PullRequest,
};

/// Everything `pr_prepare` answers for an eligible branch: gh is installed
/// and signed in, any PR already open, and fallback text from the commits.
pub fn prepare(git: *Git, runner: Runner, branch: Branch) Error!Outcome(Prepared) {
    const arena = git.arena;
    if (branch.problem()) |problem| return .{ .failed = try problemFailure(arena, problem, branch.facts) };
    const repo = branch.repo.?;
    if (try checkAuth(runner, arena, branch.root, repo.host)) |failure| return .{ .failed = failure };
    const existing = switch (try findOpen(runner, arena, branch.root, repo, branch.facts.branch.?)) {
        .ok => |value| value,
        .failed => |failure| return .{ .failed = failure },
    };
    const commits = try commitsAhead(git, branch.root, branch.base_ref.?);
    return .{ .ok = .{
        .branch = branch,
        .repo = repo,
        .base = branch.facts.default_branch.?,
        .commits = commits,
        .fallback = try fallbackText(arena, commits, branch.facts.branch.?),
        .existing = existing,
    } };
}

pub const CreateInput = struct {
    title: []const u8,
    body: []const u8 = "",
    draft: bool = false,
    /// Distinguishes concurrent body files.
    nonce: u64 = 0,
};

/// `pr_create` for an eligible branch: re-checks it, returns a PR already
/// open for it, else creates one with the confirmed text.
pub fn createForBranch(git: *Git, runner: Runner, branch: Branch, input: CreateInput) Error!Outcome(Created) {
    const arena = git.arena;
    if (validateText(input.title, input.body)) |failure| return .{ .failed = failure };
    if (branch.problem()) |problem| return .{ .failed = try problemFailure(arena, problem, branch.facts) };
    const repo = branch.repo.?;
    const head = branch.facts.branch.?;
    if (try checkAuth(runner, arena, branch.root, repo.host)) |failure| return .{ .failed = failure };
    switch (try findOpen(runner, arena, branch.root, repo, head)) {
        .ok => |found| if (found) |pr| return .{ .ok = .{ .pull_request = pr, .existing = true } },
        .failed => |failure| return .{ .failed = failure },
    }
    const git_dir = git.output(branch.root, &.{ "rev-parse", "--absolute-git-dir" }, .{}) catch return error.NotARepository;
    const body_file = fmt(arena, "{s}/verde-pr-body-{d}.md", .{ git_dir, input.nonce }) catch return error.OutOfMemory;
    var threaded: std.Io.Threaded = .init(arena, .{});
    defer threaded.deinit();
    const io = threaded.io();
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = body_file, .data = input.body }) catch return error.CommitFailed;
    defer std.Io.Dir.cwd().deleteFile(io, body_file) catch {};
    return create(runner, arena, branch.root, .{
        .repo_slug = try repo.slug(arena),
        .base = branch.facts.default_branch.?,
        .head = head,
        .title = std.mem.trim(u8, input.title, " \t\r\n"),
        .body_file = body_file,
        .draft = input.draft,
    });
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

test "github remotes parse to host, owner and repository" {
    const cases = .{
        .{ "git@github.com:acme/app.git", "github.com", "acme", "app" },
        .{ "git@github.com:acme/app", "github.com", "acme", "app" },
        .{ "ssh://git@github.com/acme/app.git", "github.com", "acme", "app" },
        .{ "ssh://git@ssh.github.com:443/acme/app.git", "github.com", "acme", "app" },
        .{ "https://github.com/acme/app.git\n", "github.com", "acme", "app" },
        .{ "https://token@GitHub.com/acme/my.app/", "github.com", "acme", "my.app" },
        .{ "https://octo.ghe.com/team/svc", "octo.ghe.com", "team", "svc" },
    };
    inline for (cases) |case| {
        const repo = parseGithubRemote(case[0]).?;
        try testing.expectEqualStrings(case[1], repo.host);
        try testing.expectEqualStrings(case[2], repo.owner);
        try testing.expectEqualStrings(case[3], repo.name);
    }
    for ([_][]const u8{
        "git@gitlab.com:acme/app.git",
        "https://github.example.com/acme/app",
        "https://github.com/acme",
        "https://github.com/acme/app/extra",
        "/srv/git/app.git",
        "../app",
        "file:///srv/git/app.git",
        "https://github.com/ac me/app",
        "",
    }) |url| try testing.expect(parseGithubRemote(url) == null);

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const repo = parseGithubRemote("git@github.com:acme/app.git").?;
    try testing.expectEqualStrings("github.com/acme/app", try repo.slug(arena_state.allocator()));
    try testing.expectEqualStrings("acme/app", try repo.display(arena_state.allocator()));
}

test "pull request eligibility needs a pushed GitHub feature branch ahead of the default" {
    const ready: BranchFacts = .{ .branch = "feature/x", .default_branch = "main", .upstream = "origin/feature/x", .has_remote = true, .ahead_of_default = 2, .github = true };
    try testing.expect(branchProblem(ready) == null);

    var facts = ready;
    facts.branch = null;
    try testing.expectEqual(Problem.detached_head, branchProblem(facts).?);
    facts = ready;
    facts.branch = "main";
    try testing.expectEqual(Problem.on_default_branch, branchProblem(facts).?);
    facts = ready;
    facts.default_branch = null;
    try testing.expectEqual(Problem.no_default_branch, branchProblem(facts).?);
    facts = ready;
    facts.github = false;
    try testing.expectEqual(Problem.not_github, branchProblem(facts).?);
    facts = ready;
    facts.ahead_of_default = 0;
    try testing.expectEqual(Problem.nothing_ahead, branchProblem(facts).?);
    facts = ready;
    facts.unpushed = 3;
    try testing.expectEqual(Problem.not_pushed, branchProblem(facts).?);
    facts = ready;
    facts.upstream = null;
    try testing.expectEqual(Problem.not_pushed, branchProblem(facts).?);

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    facts = ready;
    facts.unpushed = 1;
    const not_pushed = try problemFailure(arena, .not_pushed, facts);
    try testing.expectEqualStrings(proto.ERR_NOT_PUSHED, not_pushed.code);
    try testing.expectEqualStrings("Push feature/x first: 1 commit is not on GitHub yet.", not_pushed.message);
    facts.upstream = null;
    try testing.expectEqualStrings("Push feature/x first: it is not on GitHub yet.", (try problemFailure(arena, .not_pushed, facts)).message);
    facts = ready;
    facts.branch = "main";
    try testing.expectEqualStrings("main is the default branch. Commit on a feature branch to open a pull request.", (try problemFailure(arena, .on_default_branch, facts)).message);
    try testing.expectEqualStrings("This repository has no remote on GitHub.", (try problemFailure(arena, .not_github, .{ .branch = "x", .default_branch = "main" })).message);
    try testing.expectEqualStrings("feature/x has no commits that main doesn't have.", (try problemFailure(arena, .nothing_ahead, ready)).message);

    // The furthest repository's reason is reported; an eligible one wins.
    try testing.expectEqual(@as(usize, 1), pickCandidate(&.{ .on_default_branch, .not_pushed, .not_github }).index);
    const eligible = pickCandidate(&.{ .on_default_branch, null });
    try testing.expectEqual(@as(usize, 1), eligible.index);
    try testing.expect(eligible.problem == null);

    try testing.expect(validateText("Add dark mode", "body") == null);
    try testing.expectEqualStrings("invalid_params", validateText("  ", "").?.code);
    try testing.expect(validateText("two\nlines", "") != null);
    try testing.expect(validateText("t" ** (MAX_TITLE_BYTES + 1), "") != null);
}

test "gh arguments never prompt, push or guess the repository" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const auth = authStatusArgs("github.com");
    try testing.expectEqualStrings("auth status --hostname github.com", try std.mem.join(arena, " ", &auth));
    const list = listArgs("github.com/acme/app", "feature/x");
    try testing.expectEqualStrings(
        "pr list --repo github.com/acme/app --head feature/x --state open --limit 1 --json number,url,title,isDraft",
        try std.mem.join(arena, " ", &list),
    );
    const args = try createArgs(arena, .{ .repo_slug = "github.com/acme/app", .base = "main", .head = "feature/x", .title = "--draft is a title", .body_file = "/r/.git/verde-pr-body-1.md" });
    try testing.expectEqualStrings(
        "pr create --repo github.com/acme/app --base main --head feature/x --title --draft is a title --body-file /r/.git/verde-pr-body-1.md",
        try std.mem.join(arena, " ", args),
    );
    // The title is one argv entry, so a leading `--` cannot become a flag.
    try testing.expectEqualStrings("--draft is a title", args[9]);
    const draft = try createArgs(arena, .{ .repo_slug = "r", .base = "main", .head = "h", .title = "t", .body_file = "f", .draft = true });
    try testing.expectEqualStrings("--draft", draft[draft.len - 1]);
}

test "gh output parsing finds urls, existing pull requests and failures" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const created = findPullRequestUrl("Creating pull request for feature/x into main in acme/app\n\nhttps://github.com/acme/app/pull/42\n").?;
    try testing.expectEqualStrings("https://github.com/acme/app/pull/42", created.url);
    try testing.expectEqual(@as(u32, 42), created.number);
    try testing.expect(findPullRequestUrl("see https://github.com/acme/app/pulls and https://github.com/acme/app/pull/x") == null);

    const exists = "a pull request for branch \"feature/x\" into branch \"main\" already exists:\nhttps://github.com/acme/app/pull/7\n";
    try testing.expectEqual(GhFailureKind.already_exists, classifyGhFailure(exists));
    try testing.expectEqual(@as(u32, 7), findPullRequestUrl(exists).?.number);
    try testing.expectEqual(GhFailureKind.not_authenticated, classifyGhFailure("To get started with GitHub CLI, please run:  gh auth login\n"));
    try testing.expectEqual(GhFailureKind.not_authenticated, classifyGhFailure("HTTP 401: Bad credentials (https://api.github.com/graphql)"));
    try testing.expectEqual(GhFailureKind.not_pushed, classifyGhFailure("pull request create failed: GraphQL: Head sha can't be blank, Base sha can't be blank, No commits between main and x, Head ref must be a branch (createPullRequest)"));
    try testing.expectEqual(GhFailureKind.nothing_ahead, classifyGhFailure("pull request create failed: GraphQL: No commits between main and feature/x (createPullRequest)"));
    try testing.expectEqual(GhFailureKind.network, classifyGhFailure("error connecting to api.github.com\ncheck your internet connection or https://githubstatus.com\nPost \"https://api.github.com/graphql\": dial tcp: lookup api.github.com: no such host"));
    try testing.expectEqual(GhFailureKind.other, classifyGhFailure("GraphQL: Resource not accessible by integration (createPullRequest)"));

    try testing.expectEqualStrings("GraphQL: Resource not accessible by integration (createPullRequest)", ghFailure(.{ .exit_code = 1, .stderr = "GraphQL: Resource not accessible by integration (createPullRequest)\n" }).message);
    try testing.expectEqualStrings(proto.ERR_GH_UNAUTHENTICATED, ghFailure(.{ .exit_code = 4, .stderr = "gh auth login" }).code);
    try testing.expectEqualStrings(proto.ERR_GH_FAILED, ghFailure(.{ .exit_code = null, .timed_out = true }).code);
    try testing.expectEqualStrings("unknown flag: --nope", ghMessage("unknown flag: --nope\n\nUsage:  gh pr create [flags]\n"));

    const open = (try parseOpenList(arena, "[{\"number\":12,\"url\":\"https://github.com/acme/app/pull/12\",\"title\":\"Add X\",\"isDraft\":true}]\n")).?;
    try testing.expectEqual(@as(u32, 12), open.number);
    try testing.expectEqualStrings("Add X", open.title);
    try testing.expect(open.draft);
    try testing.expect((try parseOpenList(arena, "[]\n")) == null);
    try testing.expect((try parseOpenList(arena, "")) == null);
    try testing.expectError(error.GitUnavailable, parseOpenList(arena, "not json"));
}

test "pull request text falls back to commits and splits generated replies" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const log_out = "aaa\x1fAdd dark mode\x1fUses the theme tokens.\n\nCloses #3\x1e\nbbb\x1fFix contrast\x1f\x1e\n";
    const commits = try parseLog(arena, log_out);
    try testing.expectEqual(@as(usize, 2), commits.len);
    try testing.expectEqualStrings("Uses the theme tokens.\n\nCloses #3", commits[0].body);
    try testing.expectEqualStrings("", commits[1].body);

    const one = try fallbackText(arena, commits[0..1], "feature/dark");
    try testing.expectEqualStrings("Add dark mode", one.title);
    try testing.expectEqualStrings("Uses the theme tokens.\n\nCloses #3", one.body);
    const many = try fallbackText(arena, commits, "feature/dark-mode_v2");
    try testing.expectEqualStrings("Dark mode v2", many.title);
    try testing.expectEqualStrings("- Add dark mode\n- Fix contrast", many.body);
    try testing.expectEqualStrings("Fix contrast", (try fallbackText(arena, commits, "feature/--")).title);

    const plain = (try splitGeneratedText(arena, "Add dark mode toggle\n\nAdds a toggle.\n- uses tokens")).?;
    try testing.expectEqualStrings("Add dark mode toggle", plain.title);
    try testing.expectEqualStrings("Adds a toggle.\n- uses tokens", plain.body);
    const labelled = (try splitGeneratedText(arena, "```markdown\n# Title: **Add dark mode**\n\nDescription:\nAdds a toggle.\n```")).?;
    try testing.expectEqualStrings("Add dark mode", labelled.title);
    try testing.expectEqualStrings("Adds a toggle.", labelled.body);
    try testing.expect((try splitGeneratedText(arena, "  \n ")) == null);

    const prompt = try buildPrompt(arena, .{ .branch = "feature/x", .base = "main", .chat_title = "Dark mode", .commits = commits, .stat = " a.zig | 2 +-", .diff = "diff --git a/a.zig b/a.zig" });
    try testing.expect(std.mem.indexOf(u8, prompt, "Branch: feature/x into main") != null);
    try testing.expect(std.mem.indexOf(u8, prompt, "- Add dark mode\n  Uses the theme tokens.") != null);
    try testing.expect(std.mem.indexOf(u8, prompt, "diff --git a/a.zig b/a.zig") != null);

    try testing.expectEqualStrings(
        "Opened draft pull request #4: Add X\nhttps://github.com/acme/app/pull/4",
        try rowBody(arena, .{ .number = 4, .url = "https://github.com/acme/app/pull/4", .draft = true }, "Add X\nbody"),
    );
}

/// Scripted gh: answers by subcommand and records each call.
const FakeGh = struct {
    arena: std.mem.Allocator,
    missing: bool = false,
    auth: RunResult = .{ .exit_code = 0 },
    list: RunResult = .{ .exit_code = 0, .stdout = "[]" },
    create: RunResult = .{ .exit_code = 0, .stdout = "https://github.com/acme/app/pull/9\n" },
    calls: std.ArrayList([]const u8) = .empty,
    body_seen: []const u8 = "",

    fn runner(self: *FakeGh) Runner {
        return .{ .context = self, .runFn = run };
    }

    fn run(context: *anyopaque, arena: std.mem.Allocator, cwd: []const u8, args: []const []const u8, timeout_ms: i64) RunError!RunResult {
        _ = cwd;
        const self: *FakeGh = @ptrCast(@alignCast(context));
        std.debug.assert(timeout_ms > 0);
        if (self.missing) return error.GhMissing;
        self.calls.append(self.arena, std.mem.join(self.arena, " ", args) catch return error.OutOfMemory) catch return error.OutOfMemory;
        if (std.mem.eql(u8, args[0], "auth")) return self.auth;
        if (std.mem.eql(u8, args[1], "list")) return self.list;
        for (args, 0..) |arg, index| {
            if (!std.mem.eql(u8, arg, "--body-file")) continue;
            var threaded: std.Io.Threaded = .init(arena, .{});
            defer threaded.deinit();
            self.body_seen = std.Io.Dir.cwd().readFileAlloc(threaded.io(), args[index + 1], self.arena, .limited(MAX_BODY_BYTES)) catch "";
        }
        return self.create;
    }
};

const TestRepo = struct {
    tmp: testing.TmpDir,
    root: [:0]u8,
    arena_state: std.heap.ArenaAllocator,

    /// Null when git is unavailable (the test is skipped).
    fn init() !?TestRepo {
        var threaded: std.Io.Threaded = .init(testing.allocator, .{});
        defer threaded.deinit();
        var tmp = testing.tmpDir(.{});
        const root = tmp.dir.realPathFileAlloc(threaded.io(), ".", testing.allocator) catch |err| {
            tmp.cleanup();
            return err;
        };
        var self: TestRepo = .{ .tmp = tmp, .root = root, .arena_state = .init(testing.allocator) };
        var ready = false;
        defer if (!ready) self.deinit();
        var runner = Git.init(self.arena_state.allocator()) catch return null;
        defer runner.deinit();
        for ([_][]const []const u8{
            &.{ "init", "-q", "-b", "main" },
            &.{ "config", "user.email", "test@example.com" },
            &.{ "config", "user.name", "Test" },
            &.{ "config", "commit.gpgsign", "false" },
        }) |args| {
            const result = try runner.run(root, args, .{ .read_only = false });
            if (!result.ok()) return null;
        }
        ready = true;
        return self;
    }

    fn deinit(self: *TestRepo) void {
        testing.allocator.free(self.root);
        self.arena_state.deinit();
        self.tmp.cleanup();
    }

    fn git(self: *TestRepo, args: []const []const u8) ![]const u8 {
        var runner = try Git.init(self.arena_state.allocator());
        defer runner.deinit();
        const result = try runner.run(self.root, args, .{ .read_only = false });
        if (!result.ok()) return error.TestGitFailed;
        return std.mem.trim(u8, result.stdout, " \t\r\n");
    }

    fn commit(self: *TestRepo, path: []const u8, data: []const u8, message: []const u8) !void {
        var threaded: std.Io.Threaded = .init(testing.allocator, .{});
        defer threaded.deinit();
        try self.tmp.dir.writeFile(threaded.io(), .{ .sub_path = path, .data = data });
        _ = try self.git(&.{ "add", "-A" });
        _ = try self.git(&.{ "commit", "-q", "-m", message });
    }

    /// Records what a fetch from a GitHub `origin` would leave behind,
    /// without any network: remote-tracking refs and the upstream config.
    fn publish(self: *TestRepo, branch: []const u8) !void {
        const ref = try std.fmt.allocPrint(self.arena_state.allocator(), "refs/remotes/origin/{s}", .{branch});
        _ = try self.git(&.{ "update-ref", ref, "HEAD" });
        const remote_key = try std.fmt.allocPrint(self.arena_state.allocator(), "branch.{s}.remote", .{branch});
        const merge_key = try std.fmt.allocPrint(self.arena_state.allocator(), "branch.{s}.merge", .{branch});
        const merge = try std.fmt.allocPrint(self.arena_state.allocator(), "refs/heads/{s}", .{branch});
        _ = try self.git(&.{ "config", remote_key, "origin" });
        _ = try self.git(&.{ "config", merge_key, merge });
    }
};

test "prepare and create run against a scripted gh, never the network" {
    var repo = (try TestRepo.init()) orelse return error.SkipZigTest;
    defer repo.deinit();
    try repo.commit("a.txt", "a\n", "init");
    _ = try repo.git(&.{ "remote", "add", "origin", "git@github.com:acme/app.git" });
    try repo.publish("main");
    _ = try repo.git(&.{ "symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/main" });

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var git = try Git.init(arena);
    defer git.deinit();
    var fake: FakeGh = .{ .arena = arena };

    // On the default branch: refused locally, gh is never asked.
    const on_main = try inspectFirstEligible(&git, &.{repo.root});
    try testing.expectEqualStrings(proto.ERR_ON_DEFAULT_BRANCH, on_main.failed.code);
    const main_extras = try statusExtras(&git, repo.root, try git_changes.repoStatus(&git, repo.root));
    try testing.expect(main_extras.github);
    try testing.expect(main_extras.ahead_of_default == null);

    _ = try repo.git(&.{ "checkout", "-q", "-b", "feature/dark-mode" });
    try repo.commit("b.txt", "b\n", "Add dark mode\n\nUses theme tokens.");
    // Unpublished branch: push first.
    const unpublished = try inspectFirstEligible(&git, &.{repo.root});
    try testing.expectEqualStrings(proto.ERR_NOT_PUSHED, unpublished.failed.code);
    try repo.publish("feature/dark-mode");

    const branch = (try inspectFirstEligible(&git, &.{repo.root})).ok;
    try testing.expectEqual(@as(u32, 1), branch.facts.ahead_of_default);
    try testing.expectEqualStrings("refs/remotes/origin/main", branch.base_ref.?);
    const extras = try statusExtras(&git, repo.root, try git_changes.repoStatus(&git, repo.root));
    try testing.expect(extras.github);
    try testing.expectEqual(@as(?u32, 1), extras.ahead_of_default);

    const prepared = (try prepare(&git, fake.runner(), branch)).ok;
    try testing.expectEqualStrings("main", prepared.base);
    try testing.expectEqualStrings("Add dark mode", prepared.fallback.title);
    try testing.expectEqualStrings("Uses theme tokens.", prepared.fallback.body);
    try testing.expect(prepared.existing == null);
    try testing.expectEqualStrings("auth status --hostname github.com", fake.calls.items[0]);

    const created = (try createForBranch(&git, fake.runner(), branch, .{ .title = " Add dark mode ", .body = "Body **md**", .draft = true, .nonce = 3 })).ok;
    try testing.expectEqual(@as(u32, 9), created.pull_request.number);
    try testing.expect(!created.existing);
    try testing.expect(created.pull_request.draft);
    try testing.expectEqualStrings("Body **md**", fake.body_seen);
    const create_call = fake.calls.items[fake.calls.items.len - 1];
    try testing.expect(std.mem.startsWith(u8, create_call, "pr create --repo github.com/acme/app --base main --head feature/dark-mode --title Add dark mode --body-file "));
    try testing.expect(std.mem.endsWith(u8, create_call, " --draft"));
    // The body file is gone afterwards.
    const git_dir = try repo.git(&.{ "rev-parse", "--absolute-git-dir" });
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const leftover = try std.fmt.allocPrint(arena, "{s}/verde-pr-body-3.md", .{git_dir});
    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(threaded.io(), leftover, .{}));

    // A PR already open is returned, not created again.
    fake.list = .{ .exit_code = 0, .stdout = "[{\"number\":5,\"url\":\"https://github.com/acme/app/pull/5\",\"title\":\"Old\",\"isDraft\":false}]" };
    const calls_before = fake.calls.items.len;
    const existing = (try createForBranch(&git, fake.runner(), branch, .{ .title = "Add dark mode" })).ok;
    try testing.expect(existing.existing);
    try testing.expectEqual(@as(u32, 5), existing.pull_request.number);
    try testing.expectEqual(calls_before + 2, fake.calls.items.len);
    try testing.expectEqual(@as(u32, 5), (try prepare(&git, fake.runner(), branch)).ok.existing.?.number);

    // gh racing another client: "already exists" with the URL is success.
    fake.list = .{ .exit_code = 0, .stdout = "[]" };
    fake.create = .{ .exit_code = 1, .stderr = "a pull request for branch \"feature/dark-mode\" into branch \"main\" already exists:\nhttps://github.com/acme/app/pull/6\n" };
    const raced = (try createForBranch(&git, fake.runner(), branch, .{ .title = "Add dark mode" })).ok;
    try testing.expect(raced.existing);
    try testing.expectEqual(@as(u32, 6), raced.pull_request.number);

    // Soft, specific failures.
    fake.create = .{ .exit_code = null, .timed_out = true };
    try testing.expectEqualStrings(proto.ERR_GH_FAILED, (try createForBranch(&git, fake.runner(), branch, .{ .title = "t" })).failed.code);
    fake.auth = .{ .exit_code = 1, .stderr = "You are not logged into any GitHub hosts. To log in, run: gh auth login\n" };
    try testing.expectEqualStrings(proto.ERR_GH_UNAUTHENTICATED, (try prepare(&git, fake.runner(), branch)).failed.code);
    fake.missing = true;
    try testing.expectEqualStrings(proto.ERR_GH_MISSING, (try prepare(&git, fake.runner(), branch)).failed.code);
    try testing.expectEqualStrings("invalid_params", (try createForBranch(&git, fake.runner(), branch, .{ .title = "" })).failed.code);

    // New local commits: push first.
    try repo.commit("c.txt", "c\n", "More");
    try testing.expectEqualStrings(proto.ERR_NOT_PUSHED, (try inspectFirstEligible(&git, &.{repo.root})).failed.code);
    // A non-GitHub remote.
    _ = try repo.git(&.{ "remote", "set-url", "origin", "https://gitlab.com/acme/app.git" });
    try repo.publish("feature/dark-mode");
    try testing.expectEqualStrings(proto.ERR_NOT_GITHUB, (try inspectFirstEligible(&git, &.{repo.root})).failed.code);
    // Detached HEAD.
    _ = try repo.git(&.{ "checkout", "-q", "--detach" });
    try testing.expectEqualStrings(proto.ERR_DETACHED_HEAD, (try inspectFirstEligible(&git, &.{repo.root})).failed.code);
}
