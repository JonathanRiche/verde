//! Native chat views. Byte counts and local/stream cursors are decimal strings.
const h = @import("host.zig");
const p = @import("projection.zig");
/// `index` is the image's position within its stored message (for `attachment_fetch`); null for drafts.
pub const Attachment = struct { local_id: []const u8, name: []const u8, mime: []const u8, byte_size: []const u8, attachment_id: ?[]const u8 = null, reference: ?[]const u8 = null, uploaded_bytes: []const u8 = "0", status: []const u8 = "local", @"error": ?h.LocalError = null, index: ?u32 = null };
/// Display fields parsed from the row body (desktop tool-row parity); `row.body` stays the raw text.
/// `title`: the "Tool:" section's first line without backticks, else the row author; a trailing copy
/// of the summary is dropped ("Edit `src/x.ts`" → "Edit"), and a title that was only the summary
/// becomes the author ("Ran command"). `summary`: one plain line (≤240 bytes) naming what the call
/// acts on (execute: command; read/edit/delete/move: path; search: pattern; fetch: url; mcp: tool
/// name; else a telling input field or the first input line); never raw JSON, never equal to the
/// title. `input`/`output`/`error`: the trimmed "Input:"/"Output:"/"Error:" sections. Null when absent.
pub const Tool = struct { id: []const u8, kind: []const u8, status: []const u8, title: ?[]const u8 = null, summary: ?[]const u8 = null, input: ?[]const u8 = null, output: ?[]const u8 = null, @"error": ?[]const u8 = null };
/// A provider background task (desktop's background-command rows), one per task. `label`: the
/// command's first line. `status`: running, completed, failed or stopped (the latest event; a
/// Codex snapshot that drops the task completes it). `task_id`: the Verde task ID, else the
/// Codex item ID or process ID. Times are the start and end rows' `created_at_ms` when known.
pub const Background = struct { label: []const u8, status: []const u8, task_id: ?[]const u8 = null, started_at_ms: ?i64 = null, finished_at_ms: ?i64 = null };
/// A running background task for the bar above the composer; `row_id` is its transcript row.
pub const BackgroundTask = struct { row_id: []const u8, task_id: ?[]const u8 = null, label: []const u8, status: []const u8, started_at_ms: ?i64 = null };
/// `message_id` is the stored message's ID (null for optimistic rows or legacy rows without one).
/// `kind` "background_task" rows carry `background`; their `body` is the command alone.
pub const Row = struct { id: []const u8, role: []const u8, kind: []const u8 = "message", author: []const u8 = "", body: []const u8, created_at_ms: ?i64 = null, delivery: []const u8 = "committed", attachments: []const Attachment = &.{}, tool: ?Tool = null, message_id: ?[]const u8 = null, background: ?Background = null };
pub const Turn = struct { turn_id: []const u8, status: []const u8, after_seq: []const u8 = "0", started_at_ms: ?i64 = null, elapsed_ms: i64 = 0, stop_pending: bool = false };
pub const Approval = struct { turn_id: []const u8, call_id: []const u8, title: []const u8, body: []const u8, resolution: []const u8 = "idle", @"error": ?h.LocalError = null };
pub const Followup = struct { id: []const u8, kind: []const u8, state: []const u8 = "pending", delivery: []const u8 = "unsent", turn_id: []const u8, steer_id: []const u8, next_turn_id: []const u8, text: []const u8, attachments: []const Attachment = &.{}, voice: bool = false, paused: bool = false, can_retry: bool = false, can_pull_back: bool = true, @"error": ?h.LocalError = null };
pub const Selection = struct { provider: ?[]const u8 = null, model: ?[]const u8 = null, effort: ?[]const u8 = null, access: ?[]const u8 = null, speed: ?[]const u8 = null };
pub const Choice = struct { id: []const u8, label: []const u8, enabled: bool = true, reason: ?[]const u8 = null, favorite: bool = false };
/// `default_model_label`: the concrete model behind the provider's `default` model choice (e.g.
/// "Opus 5.5"), from the host's model list or the provider's built-in default; null when the
/// catalog has no `default` choice or the provider resolves it from its own config.
/// `default_effort_label`: the same for the `""` effort choice; null while hosts do not report the
/// provider's per-model default effort (the CLI applies it), which is true of every provider today.
pub const Catalogs = struct { models: []const Choice = &.{}, efforts: []const Choice = &.{}, access: []const Choice = &.{}, speeds: []const Choice = &.{}, slash: []const Choice = &.{}, default_model_label: ?[]const u8 = null, default_effort_label: ?[]const u8 = null };
pub const Draft = struct { revision: []const u8, text: []const u8, attachments: []const Attachment, persisted: bool };
pub const Mention = struct { path: []const u8, label: []const u8 };
pub const ShellConfirmation = struct { id: []const u8, command: []const u8, cwd: []const u8 };
pub const UsageLimit = struct { label: []const u8, percent_left: u8, reset: []const u8 };
pub const UsageStat = struct { label: []const u8, value: []const u8 };
pub const Usage = struct { provider: []const u8, limits: []const UsageLimit = &.{}, stats: []const UsageStat = &.{}, recent: []const UsageStat = &.{} };
pub const Page = struct { has_older: bool, cursor: ?[]const u8, loading: bool };
/// `background_tasks`: the thread's running background tasks, oldest first, for the bar above the composer.
pub const LinkedAgent = struct { link_id: []const u8 = "", workspace_id: []const u8 = "", local_thread_id: []const u8 = "", title: []const u8 = "", provider: []const u8 = "", model: []const u8 = "", status: []const u8 = "idle", status_label: []const u8 = "Idle", summary: []const u8 = "", updated_at_ms: i64 = 0, hidden: bool = false, needs_you: bool = false };
pub const Orchestration = struct { links: []const LinkedAgent = &.{}, loaded: bool = false, loading: bool = false, @"error": ?h.LocalError = null, waiting_count: u32 = 0, working_count: u32 = 0, approval_count: u32 = 0, input_count: u32 = 0, needs_you: bool = false, title: []const u8 = "", summary: []const u8 = "" };
pub const ThreadView = struct { orchestration: ?Orchestration = null, thread: p.ThreadSummary, rows: []const Row, page: Page, turn: ?Turn, approval: ?Approval, usage: ?Usage, stale: bool, @"error": ?h.LocalError, background_tasks: []const BackgroundTask = &.{} };
pub const ComposerView = struct { draft: Draft, selection: Selection, catalogs: Catalogs, mentions: []const Mention, provider_ready: bool, can_send: bool, can_stop: bool, send_operation: ?h.Operation, followup: ?Followup, shell_confirmation: ?ShellConfirmation, @"error": ?h.LocalError };
