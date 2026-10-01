//! "Commit changes" dialog for one chat's git changes, plus the header's
//! default-branch confirmation ("Commit & push to main?").
//!
//! The dialog shows the branch, a plain list of the files about to be
//! committed (Edit switches to per-file and per-hunk ticks with an inline
//! diff), an optional message whose placeholder is the generated message,
//! and Cancel / Commit on new branch / Commit. State and daemon calls live in
//! state/git_changes_controller.zig; this file only lays out, draws, and maps
//! pointer/keyboard input onto that state. Hits are registered from
//! `refreshPaletteModalHits` before input and dispatched by the
//! PaletteModalAction handlers in layout.zig.

const std = @import("std");
const palette = @import("palette");
const runtime = @import("runtime.zig");
const text_measure = @import("text_measure.zig");
const theme = @import("theme.zig");
const git_changes = @import("../state/git_changes_controller.zig");

const log = std.log.scoped(.native_shell);
const page = std.heap.page_allocator;

const Sheet = git_changes.Sheet;
const Quick = git_changes.Quick;
const ReviewFile = git_changes.ReviewFile;
const TickState = git_changes.TickState;

/// Buttons in the dialog and the confirmation; the ordinal is the
/// `commit_sheet_control` hit index.
pub const Control = enum(u8) {
    cancel,
    primary,
    new_branch,
    regenerate,
    pull_push,
    reload,
    edit_toggle,
    confirm_abort,
    confirm_direct,
    confirm_branch,
    /// The sheet's other action (Commit & push from Commit, or Commit).
    alternate,
};

// Geometry tokens (CSS px, scaled at use).
const MODAL_MIN_W_CSS: f32 = 480.0;
const MODAL_MAX_W_CSS: f32 = 560.0;
const CONFIRM_MIN_W_CSS: f32 = 440.0;
const CONFIRM_MAX_W_CSS: f32 = 520.0;
const MODAL_EDGE_CSS: f32 = 16.0;
const MODAL_RADIUS_CSS: f32 = 12.0;
const PAD_CSS: f32 = 20.0;
const TITLE_FONT_CSS: f32 = 16.0;
const BODY_FONT_CSS: f32 = 13.0;
const SMALL_FONT_CSS: f32 = 12.0;
const MONO_FONT_CSS: f32 = 11.5;
const MESSAGE_FONT_CSS: f32 = 13.5;
const MESSAGE_VISIBLE_LINES: f32 = 4.0;
const MESSAGE_PAD_CSS: f32 = 8.0;
/// Square ↻ button in the message box's top-right corner.
const REGEN_CSS: f32 = 24.0;
const BUTTON_H_CSS: f32 = 32.0;
const BUTTON_PAD_X_CSS: f32 = 14.0;
const BUTTON_MIN_W_CSS: f32 = 76.0;
const BUTTON_GAP_CSS: f32 = 8.0;
const CARD_RADIUS_CSS: f32 = 10.0;
const CARD_PAD_X_CSS: f32 = 12.0;
const BRANCH_ROW_H_CSS: f32 = 36.0;
const FILES_HEAD_H_CSS: f32 = 32.0;
const TOTALS_H_CSS: f32 = 30.0;
const LIST_MIN_H_CSS: f32 = 52.0;
const LIST_MAX_H_CSS: f32 = 340.0;
const STATE_BODY_H_CSS: f32 = 104.0;
const CHECKBOX_CSS: f32 = 16.0;
/// Clickable column around each checkbox, wider than the box itself.
const CHECK_COLUMN_CSS: f32 = 30.0;
const ROW_PLAIN_H_CSS: f32 = 26.0;
const ROW_REPO_H_CSS: f32 = 28.0;
const ROW_FILE_H_CSS: f32 = 30.0;
const ROW_NOTE_H_CSS: f32 = 22.0;
const ROW_HUNK_H_CSS: f32 = 26.0;
const ROW_LINE_H_CSS: f32 = 16.0;
const ROW_MORE_H_CSS: f32 = 20.0;
const GROUP_GAP_CSS: f32 = 6.0;
/// Diff preview lines drawn per hunk before a "… N more lines" row.
const MAX_HUNK_LINES: usize = 80;
/// Wrapped message lines tracked for caret placement.
const MAX_MESSAGE_LINES: usize = 1024;

const SUBTITLE = "Review and confirm your commit. Leave the message blank to use the generated one.";

const RowKind = enum { repo, plain, file, note, hunk, line, more };

const Row = struct {
    kind: RowKind,
    /// Content-space top (before scrolling).
    y: f32,
    h: f32,
    repo: usize = 0,
    file: usize = 0,
    hunk: usize = 0,
    text: []const u8 = "",
};

const Geometry = struct {
    modal: palette.Rect,
    title_y: f32,
    subtitle: palette.Rect,
    notice: ?palette.Rect,
    /// Rounded card (branch, files, totals) while ready; otherwise the state
    /// body (loading, error, push outcome).
    card: palette.Rect,
    branch_row: palette.Rect,
    files_head: palette.Rect,
    edit: palette.Rect,
    list: palette.Rect,
    totals: palette.Rect,
    /// Present only while the review is ready (message + commit buttons).
    message_label_y: ?f32,
    message: palette.Rect,
    regenerate: palette.Rect,
    error_rect: ?palette.Rect,
    footer_y: f32,
    cancel: palette.Rect,
    new_branch: ?palette.Rect,
    alternate: ?palette.Rect,
    primary: ?palette.Rect,
    new_branch_label: []const u8,
};

fn scaled(value: f32) f32 {
    return theme.scaledUi(value);
}

fn messageLineHeight() f32 {
    return scaled(MESSAGE_FONT_CSS) * 1.35;
}

fn buttonWidth(label: []const u8) f32 {
    const natural = text_measure.textWidth(.ui, scaled(BODY_FONT_CSS), label) + scaled(BUTTON_PAD_X_CSS) * 2.0;
    return @max(natural, scaled(BUTTON_MIN_W_CSS));
}

fn modalWidth(width: f32, min_css: f32, max_css: f32) f32 {
    const edge = scaled(MODAL_EDGE_CSS);
    return @min(theme.clampf(width * 0.5, scaled(min_css), scaled(max_css)), @max(width - edge * 2.0, scaled(240.0)));
}

/// Primary button text: the dialog's action, or its progress.
fn primaryLabel(sheet: *const Sheet) []const u8 {
    return actionLabel(sheet, sheet.mode);
}

/// Text of the button for `action` (not on a new branch): its label, or
/// its progress while it runs.
fn actionLabel(sheet: *const Sheet, action: git_changes.Action) []const u8 {
    if (sheet.busy) |busy| if (!sheet.busy_new_branch and busy == action) return busy.busyLabel();
    if (sheet.pending_new_branch) |pending| if (!pending and sheet.pending_action == action) return "Writing message\u{2026}";
    return action.label();
}

/// The alternate action is offered when it can run: plain Commit always,
/// Commit & push only when a repository has a remote.
fn showsAlternate(sheet: *const Sheet) bool {
    return sheet.mode == .commit_and_push or git_changes.sheetHasRemote(sheet);
}

fn newBranchLabel(sheet: *const Sheet, short: bool) []const u8 {
    if (sheet.busy) |busy| if (sheet.busy_new_branch) return busy.busyLabel();
    if (sheet.pending_new_branch) |pending| if (pending) return "Writing message\u{2026}";
    return if (short) "On new branch" else sheet.mode.newBranchLabel();
}

fn subtitleLines(inner_w: f32) usize {
    var lines: [4]Line = undefined;
    return @max(wrapLines(SUBTITLE, scaled(SMALL_FONT_CSS), inner_w, &lines), 1);
}

fn computeGeometry(sheet: *const Sheet, rows: []const Row, width: f32, height: f32) Geometry {
    const edge = scaled(MODAL_EDGE_CSS);
    const modal_w = modalWidth(width, MODAL_MIN_W_CSS, MODAL_MAX_W_CSS);
    const pad = scaled(PAD_CSS);
    const inner_w = modal_w - pad * 2.0;
    const ready = sheet.phase == .ready;
    const review = sheet.reviewValue();

    // Fixed heights, top to bottom; the file list takes what is left.
    const title_h = scaled(24.0);
    const small_line = scaled(SMALL_FONT_CSS) * 1.3;
    const subtitle_h = small_line * @as(f32, @floatFromInt(subtitleLines(inner_w)));
    const notice_h: f32 = if (ready and review != null and review.?.turn_running) scaled(28.0) else 0.0;
    const card_fixed = scaled(4.0) + scaled(BRANCH_ROW_H_CSS) + scaled(1.0) + scaled(FILES_HEAD_H_CSS) + scaled(TOTALS_H_CSS) + scaled(4.0);
    const message_h = messageLineHeight() * MESSAGE_VISIBLE_LINES + scaled(MESSAGE_PAD_CSS) * 2.0;
    const message_block: f32 = if (ready) scaled(16.0) + scaled(20.0) + scaled(6.0) + message_h else 0.0;
    const error_h: f32 = if (ready and sheet.error_len > 0) scaled(8.0) + scaled(34.0) else 0.0;
    const footer_h = scaled(20.0) + scaled(BUTTON_H_CSS);
    const head_h = title_h + subtitle_h + scaled(14.0) + (if (notice_h > 0.0) notice_h + scaled(10.0) else 0.0);

    var card_h: f32 = scaled(STATE_BODY_H_CSS);
    var list_h: f32 = 0.0;
    if (ready) {
        const fixed = pad * 2.0 + head_h + card_fixed + message_block + error_h + footer_h;
        const room = @max(height - edge * 2.0 - fixed, scaled(LIST_MIN_H_CSS));
        const content = @max(contentHeight(rows), scaled(LIST_MIN_H_CSS));
        list_h = @min(@min(content, room), scaled(LIST_MAX_H_CSS));
        card_h = card_fixed + list_h;
    }
    const natural_h = pad * 2.0 + head_h + card_h + message_block + error_h + footer_h;
    const modal_h = @min(natural_h, @max(height - edge * 2.0, scaled(200.0)));
    const modal: palette.Rect = .{ .x = (width - modal_w) * 0.5, .y = (height - modal_h) * 0.5, .w = modal_w, .h = modal_h };
    const inner_x = modal.x + pad;

    const title_y = modal.y + pad;
    var y = title_y + title_h;
    const subtitle: palette.Rect = .{ .x = inner_x, .y = y, .w = inner_w, .h = subtitle_h };
    y += subtitle_h + scaled(14.0);
    var notice: ?palette.Rect = null;
    if (notice_h > 0.0) {
        notice = .{ .x = inner_x, .y = y, .w = inner_w, .h = notice_h };
        y += notice_h + scaled(10.0);
    }

    const card: palette.Rect = .{ .x = inner_x, .y = y, .w = inner_w, .h = card_h };
    const card_x = card.x + scaled(CARD_PAD_X_CSS);
    const card_w = card.w - scaled(CARD_PAD_X_CSS) * 2.0;
    var cy = card.y + scaled(4.0);
    const branch_row: palette.Rect = .{ .x = card_x, .y = cy, .w = card_w, .h = scaled(BRANCH_ROW_H_CSS) };
    cy += branch_row.h + scaled(1.0);
    const files_head: palette.Rect = .{ .x = card_x, .y = cy, .w = card_w, .h = scaled(FILES_HEAD_H_CSS) };
    const edit_w = @max(text_measure.textWidth(.ui, scaled(SMALL_FONT_CSS), "Hide diffs"), text_measure.textWidth(.ui, scaled(SMALL_FONT_CSS), "Show diffs")) + scaled(20.0);
    const edit_h = scaled(24.0);
    const edit: palette.Rect = .{ .x = files_head.x + files_head.w - edit_w + scaled(4.0), .y = files_head.y + (files_head.h - edit_h) * 0.5, .w = edit_w, .h = edit_h };
    cy += files_head.h;
    const list: palette.Rect = .{ .x = card.x + scaled(4.0), .y = cy, .w = card.w - scaled(8.0), .h = list_h };
    cy += list_h;
    const totals: palette.Rect = .{ .x = card_x, .y = cy, .w = card_w, .h = scaled(TOTALS_H_CSS) };
    y = card.y + card.h;

    var message_label_y: ?f32 = null;
    var message: palette.Rect = .{ .x = inner_x, .y = y, .w = inner_w, .h = 0.0 };
    var regenerate: palette.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 };
    if (ready) {
        y += scaled(16.0);
        message_label_y = y;
        y += scaled(20.0) + scaled(6.0);
        message = .{ .x = inner_x, .y = y, .w = inner_w, .h = message_h };
        const regen = scaled(REGEN_CSS);
        regenerate = .{ .x = message.x + message.w - regen - scaled(5.0), .y = message.y + scaled(5.0), .w = regen, .h = regen };
        y += message_h;
    }
    var error_rect: ?palette.Rect = null;
    if (error_h > 0.0) {
        error_rect = .{ .x = inner_x, .y = y + scaled(8.0), .w = inner_w, .h = scaled(34.0) };
    }

    const button_h = scaled(BUTTON_H_CSS);
    const footer_y = modal.y + modal.h - pad - button_h;
    const gap = scaled(BUTTON_GAP_CSS);
    var right = inner_x + inner_w;
    var primary: ?palette.Rect = null;
    var new_branch: ?palette.Rect = null;
    var alternate: ?palette.Rect = null;
    var new_branch_label: []const u8 = "";
    const cancel_label: []const u8 = if (sheet.phase == .result) "Done" else "Cancel";
    const cancel_w = buttonWidth(cancel_label);
    switch (sheet.phase) {
        .ready => {
            const primary_w = buttonWidth(primaryLabel(sheet));
            primary = .{ .x = right - primary_w, .y = footer_y, .w = primary_w, .h = button_h };
            right -= primary_w + gap;
            var used = primary_w;
            if (showsAlternate(sheet)) {
                const alternate_w = buttonWidth(actionLabel(sheet, sheet.mode.other()));
                alternate = .{ .x = right - alternate_w, .y = footer_y, .w = alternate_w, .h = button_h };
                right -= alternate_w + gap;
                used += alternate_w + gap;
            }
            new_branch_label = newBranchLabel(sheet, false);
            var new_branch_w = buttonWidth(new_branch_label);
            if (used + new_branch_w + cancel_w + gap * 2.0 > inner_w) {
                new_branch_label = newBranchLabel(sheet, true);
                new_branch_w = @min(buttonWidth(new_branch_label), @max(inner_w - used - cancel_w - gap * 2.0, scaled(60.0)));
            }
            new_branch = .{ .x = right - new_branch_w, .y = footer_y, .w = new_branch_w, .h = button_h };
            right -= new_branch_w + gap;
        },
        .result => {
            const w = buttonWidth(if (sheet.pull_push_busy) "Pulling & pushing\u{2026}" else "Pull & push");
            primary = .{ .x = right - w, .y = footer_y, .w = w, .h = button_h };
            right -= w + gap;
        },
        .load_error => {
            const w = buttonWidth("Retry");
            primary = .{ .x = right - w, .y = footer_y, .w = w, .h = button_h };
            right -= w + gap;
        },
        .loading => {},
    }
    const cancel: palette.Rect = .{ .x = right - cancel_w, .y = footer_y, .w = cancel_w, .h = button_h };
    return .{
        .modal = modal,
        .title_y = title_y,
        .subtitle = subtitle,
        .notice = notice,
        .card = card,
        .branch_row = branch_row,
        .files_head = files_head,
        .edit = edit,
        .list = list,
        .totals = totals,
        .message_label_y = message_label_y,
        .message = message,
        .regenerate = regenerate,
        .error_rect = error_rect,
        .footer_y = footer_y,
        .cancel = cancel,
        .new_branch = new_branch,
        .alternate = alternate,
        .primary = primary,
        .new_branch_label = new_branch_label,
    };
}

/// Rows plus the geometry sized around them, shared by hits, wheel and
/// rendering so every rect agrees.
const Layout = struct {
    arena: std.heap.ArenaAllocator,
    rows: []const Row,
    geo: Geometry,

    fn init(sheet: *Sheet, width: f32, height: f32) Layout {
        var arena: std.heap.ArenaAllocator = .init(page);
        const rows: []const Row = buildRows(arena.allocator(), sheet) catch &[_]Row{};
        const geo = computeGeometry(sheet, rows, width, height);
        clampScroll(sheet, rows, geo.list);
        return .{ .arena = arena, .rows = rows, .geo = geo };
    }

    fn deinit(self: *Layout) void {
        self.arena.deinit();
    }
};

// ------------------------------------------------------------------
// File list rows
// ------------------------------------------------------------------

fn expandable(file: ReviewFile) bool {
    return file.hunks.len > 0 or file.binary or file.preview_truncated;
}

/// Flattens the review into drawable rows: one line per file in the plain
/// list, or checkboxes, hunks and diff lines while editing. Repository
/// headers appear only when the chat touched more than one repository.
fn buildRows(allocator: std.mem.Allocator, sheet: *const Sheet) ![]Row {
    var rows: std.ArrayList(Row) = .empty;
    const review = sheet.reviewValue() orelse return rows.toOwnedSlice(allocator);
    const grouped = review.repos.len > 1;
    var y: f32 = 0.0;
    var flat: usize = 0;
    for (review.repos, 0..) |repo, repo_index| {
        if (grouped) {
            if (repo_index > 0) y += scaled(GROUP_GAP_CSS);
            try rows.append(allocator, .{ .kind = .repo, .y = y, .h = scaled(ROW_REPO_H_CSS), .repo = repo_index });
            y += scaled(ROW_REPO_H_CSS);
        }
        for (repo.files) |file| {
            defer flat += 1;
            // Every file row carries its checkbox; hunks show once expanded.
            try rows.append(allocator, .{ .kind = .file, .y = y, .h = scaled(ROW_FILE_H_CSS), .repo = repo_index, .file = flat });
            y += scaled(ROW_FILE_H_CSS);
            if (flat >= sheet.expanded.len or !sheet.expanded[flat]) continue;
            const note: ?[]const u8 = if (file.binary)
                "Binary file \u{2014} can only be committed whole."
            else if (file.preview_truncated)
                "Diff too large to preview \u{2014} can only be committed whole."
            else if (!git_changes.canSelectHunks(file))
                "This file can only be committed whole."
            else
                null;
            if (note) |text| {
                try rows.append(allocator, .{ .kind = .note, .y = y, .h = scaled(ROW_NOTE_H_CSS), .file = flat, .text = text });
                y += scaled(ROW_NOTE_H_CSS);
            }
            if (file.binary or file.preview_truncated) continue;
            for (file.hunks, 0..) |hunk, hunk_position| {
                try rows.append(allocator, .{ .kind = .hunk, .y = y, .h = scaled(ROW_HUNK_H_CSS), .file = flat, .hunk = hunk_position, .text = hunk.header });
                y += scaled(ROW_HUNK_H_CSS);
                var lines = std.mem.splitScalar(u8, hunk.text, '\n');
                // The first line repeats the `@@` header drawn above.
                if (std.mem.startsWith(u8, hunk.text, "@@")) _ = lines.next();
                var emitted: usize = 0;
                var remaining: usize = 0;
                while (lines.next()) |raw| {
                    const line = std.mem.trimEnd(u8, raw, "\r");
                    if (line.len == 0 and lines.peek() == null) break;
                    if (emitted >= MAX_HUNK_LINES) {
                        remaining += 1;
                        continue;
                    }
                    try rows.append(allocator, .{ .kind = .line, .y = y, .h = scaled(ROW_LINE_H_CSS), .file = flat, .hunk = hunk_position, .text = line });
                    y += scaled(ROW_LINE_H_CSS);
                    emitted += 1;
                }
                if (remaining > 0) {
                    const text = try std.fmt.allocPrint(allocator, "\u{2026} {d} more {s}", .{ remaining, if (remaining == 1) "line" else "lines" });
                    try rows.append(allocator, .{ .kind = .more, .y = y, .h = scaled(ROW_MORE_H_CSS), .file = flat, .text = text });
                    y += scaled(ROW_MORE_H_CSS);
                }
            }
        }
    }
    return rows.toOwnedSlice(allocator);
}

fn contentHeight(rows: []const Row) f32 {
    if (rows.len == 0) return 0.0;
    const last = rows[rows.len - 1];
    return last.y + last.h + scaled(4.0);
}

fn clampScroll(sheet: *Sheet, rows: []const Row, list: palette.Rect) void {
    const max_scroll = @max(0.0, contentHeight(rows) - list.h);
    sheet.scroll_y = theme.clampf(sheet.scroll_y, 0.0, max_scroll);
}

fn rowRect(row: Row, list: palette.Rect, scroll: f32) palette.Rect {
    return .{ .x = list.x, .y = list.y + row.y - scroll, .w = list.w, .h = row.h };
}

fn checkColumn(row_rect: palette.Rect, indent: f32) palette.Rect {
    return .{ .x = row_rect.x + indent, .y = row_rect.y, .w = scaled(CHECK_COLUMN_CSS), .h = row_rect.h };
}

fn chevronColumn(row_rect: palette.Rect) palette.Rect {
    return .{ .x = row_rect.x + scaled(CHECK_COLUMN_CSS) - scaled(2.0), .y = row_rect.y, .w = scaled(18.0), .h = row_rect.h };
}

fn intersect(a: palette.Rect, b: palette.Rect) ?palette.Rect {
    const x0 = @max(a.x, b.x);
    const y0 = @max(a.y, b.y);
    const x1 = @min(a.x + a.w, b.x + b.w);
    const y1 = @min(a.y + a.h, b.y + b.h);
    if (x1 <= x0 or y1 <= y0) return null;
    return .{ .x = x0, .y = y0, .w = x1 - x0, .h = y1 - y0 };
}

fn pointInRect(x: f32, y: f32, rect: palette.Rect) bool {
    return x >= rect.x and y >= rect.y and x <= rect.x + rect.w and y <= rect.y + rect.h;
}

// ------------------------------------------------------------------
// Default-branch confirmation
// ------------------------------------------------------------------

const ConfirmGeometry = struct {
    modal: palette.Rect,
    title_y: f32,
    body: palette.Rect,
    abort: palette.Rect,
    direct: palette.Rect,
    branch: palette.Rect,
};

const ConfirmText = struct {
    title_buf: [192]u8 = undefined,
    body_buf: [640]u8 = undefined,
    direct_buf: [192]u8 = undefined,
    title: []const u8 = "",
    body: []const u8 = "",
    direct: []const u8 = "",

    fn fill(self: *ConfirmText, quick: *const Quick) void {
        const branch = quick.branchName();
        self.title = git_changes.confirmTitle(&self.title_buf, branch);
        const subject: ?[]const u8 = if (quick.generated_len > 0)
            git_changes.messageSubject(quick.generated())
        else if (quick.message_status == .failed)
            "no message yet"
        else
            null;
        self.body = git_changes.confirmBody(&self.body_buf, quick.files, branch, subject);
        self.direct = std.fmt.bufPrint(&self.direct_buf, "Commit & push to {s}", .{branch}) catch "Commit & push";
    }
};

const CONFIRM_BRANCH_LABEL = "Create branch & continue";

fn confirmGeometry(text: *const ConfirmText, width: f32, height: f32) ConfirmGeometry {
    const pad = scaled(PAD_CSS);
    const modal_w = modalWidth(width, CONFIRM_MIN_W_CSS, CONFIRM_MAX_W_CSS);
    const inner_w = modal_w - pad * 2.0;
    var lines: [12]Line = undefined;
    const count = wrapLines(text.body, scaled(BODY_FONT_CSS), inner_w, &lines);
    const body_h = scaled(BODY_FONT_CSS) * 1.4 * @as(f32, @floatFromInt(@max(count, 1)));
    const button_h = scaled(BUTTON_H_CSS);
    const natural_h = pad + scaled(26.0) + scaled(8.0) + body_h + scaled(22.0) + button_h + pad;
    const modal_h = @min(natural_h, @max(height - scaled(MODAL_EDGE_CSS) * 2.0, scaled(160.0)));
    const modal: palette.Rect = .{ .x = (width - modal_w) * 0.5, .y = (height - modal_h) * 0.5, .w = modal_w, .h = modal_h };
    const title_y = modal.y + pad;
    const body: palette.Rect = .{ .x = modal.x + pad, .y = title_y + scaled(26.0) + scaled(8.0), .w = inner_w, .h = body_h };
    const footer_y = modal.y + modal.h - pad - button_h;
    const gap = scaled(BUTTON_GAP_CSS);
    const branch_w = buttonWidth(CONFIRM_BRANCH_LABEL);
    const abort_w = buttonWidth("Abort");
    const direct_w = @min(buttonWidth(text.direct), @max(inner_w - branch_w - abort_w - gap * 2.0, scaled(80.0)));
    var right = modal.x + pad + inner_w;
    const branch: palette.Rect = .{ .x = right - branch_w, .y = footer_y, .w = branch_w, .h = button_h };
    right -= branch_w + gap;
    const direct: palette.Rect = .{ .x = right - direct_w, .y = footer_y, .w = direct_w, .h = button_h };
    right -= direct_w + gap;
    const abort: palette.Rect = .{ .x = right - abort_w, .y = footer_y, .w = abort_w, .h = button_h };
    return .{ .modal = modal, .title_y = title_y, .body = body, .abort = abort, .direct = direct, .branch = branch };
}

fn registerConfirmHits(state: *runtime.AppState, quick: *const Quick, width: f32, height: f32, queue_hit: QueueHit) void {
    var text: ConfirmText = .{};
    text.fill(quick);
    const geo = confirmGeometry(&text, width, height);
    queue_hit(state, .{ .x = 0, .y = 0, .w = width, .h = height }, .modal_dismiss, 0);
    queue_hit(state, geo.modal, .modal_block, 0);
    queue_hit(state, geo.abort, .commit_sheet_control, @intFromEnum(Control.confirm_abort));
    queue_hit(state, geo.direct, .commit_sheet_control, @intFromEnum(Control.confirm_direct));
    queue_hit(state, geo.branch, .commit_sheet_control, @intFromEnum(Control.confirm_branch));
}

fn renderConfirm(state: *runtime.AppState, quick: *const Quick, width: f32, height: f32) void {
    var text: ConfirmText = .{};
    text.fill(quick);
    const geo = confirmGeometry(&text, width, height);
    const modal = geo.modal;
    const full: palette.Rect = .{ .x = 0, .y = 0, .w = width, .h = height };
    roundedRect(state, full, theme.scrim(0.68), 0.0, full);
    roundedRect(state, modal, theme.COLOR_PANEL, scaled(MODAL_RADIUS_CSS), full);
    border(state, modal, theme.withAlpha(theme.borderMuted(), 110), scaled(MODAL_RADIUS_CSS), scaled(1.0), full);
    var title_trunc: [256]u8 = undefined;
    labelText(state, .{ .x = geo.body.x, .y = geo.title_y, .w = geo.body.w, .h = scaled(22.0) }, truncatedLabel(&title_trunc, text.title, geo.body.w, scaled(TITLE_FONT_CSS)), theme.COLOR_WHITE, scaled(TITLE_FONT_CSS), .ui_bold, modal);
    labelWrappedSpaced(state, geo.body, text.body, theme.COLOR_TEXT_MUTED, scaled(BODY_FONT_CSS), 1.4, modal);
    drawSecondaryButton(state, geo.abort, "Abort", true, modal);
    drawSecondaryButton(state, geo.direct, text.direct, true, modal);
    drawActionButton(state, geo.branch, CONFIRM_BRANCH_LABEL, true, modal);
}

// ------------------------------------------------------------------
// Hits
// ------------------------------------------------------------------

pub const QueueHit = *const fn (*runtime.AppState, palette.Rect, runtime.PaletteModalAction, usize) void;

/// Registers the dialog's (or the confirmation's) hit targets; later hits win.
pub fn registerHits(state: *runtime.AppState, width: f32, height: f32, queue_hit: QueueHit) void {
    const sheet = state.commitSheet() orelse {
        if (state.gitQuickConfirm()) |quick| registerConfirmHits(state, quick, width, height, queue_hit);
        return;
    };
    var layout = Layout.init(sheet, width, height);
    defer layout.deinit();
    const geo = &layout.geo;
    queue_hit(state, .{ .x = 0, .y = 0, .w = width, .h = height }, if (sheet.busy != null) .modal_block else .modal_dismiss, 0);
    queue_hit(state, geo.modal, .modal_block, 0);

    const locked = sheet.locked();
    if (sheet.phase == .ready) {
        if (!locked) {
            for (layout.rows) |row| {
                const rect = rowRect(row, geo.list, sheet.scroll_y);
                const visible = intersect(rect, geo.list) orelse continue;
                switch (row.kind) {
                    .file => {
                        const found = sheet.fileAt(row.file) orelse continue;
                        // Clicking a row ticks it; the chevron beside the
                        // checkbox expands its hunks.
                        queue_hit(state, visible, .commit_sheet_file_toggle, row.file);
                        if (expandable(found.file)) {
                            if (intersect(chevronColumn(rect), geo.list)) |chevron| queue_hit(state, chevron, .commit_sheet_file_expand, row.file);
                        }
                    },
                    .hunk => {
                        const found = sheet.fileAt(row.file) orelse continue;
                        if (!git_changes.canSelectHunks(found.file)) continue;
                        queue_hit(state, visible, .commit_sheet_hunk_toggle, (row.file << 16) | row.hunk);
                    },
                    else => {},
                }
            }
        }
        // Remember the message field so drags and line navigation map onto
        // the same wrap as the frame being drawn.
        state.modal_text_input_rect = geo.message;
        state.modal_text_input_font_size = scaled(MESSAGE_FONT_CSS);
        if (!locked) {
            queue_hit(state, geo.edit, .commit_sheet_control, @intFromEnum(Control.edit_toggle));
            queue_hit(state, geo.message, .commit_sheet_message_input, 0);
            queue_hit(state, geo.regenerate, .commit_sheet_control, @intFromEnum(Control.regenerate));
            if (geo.new_branch) |rect| queue_hit(state, rect, .commit_sheet_control, @intFromEnum(Control.new_branch));
            if (geo.alternate) |rect| queue_hit(state, rect, .commit_sheet_control, @intFromEnum(Control.alternate));
            if (geo.primary) |rect| queue_hit(state, rect, .commit_sheet_control, @intFromEnum(Control.primary));
        }
    } else if (sheet.phase == .result) {
        if (geo.primary) |rect| {
            if (!sheet.pull_push_busy) queue_hit(state, rect, .commit_sheet_control, @intFromEnum(Control.pull_push));
        }
    } else if (sheet.phase == .load_error) {
        if (geo.primary) |rect| queue_hit(state, rect, .commit_sheet_control, @intFromEnum(Control.reload));
    }
    if (sheet.busy == null) queue_hit(state, geo.cancel, .commit_sheet_control, @intFromEnum(Control.cancel));
}

/// Applies a `commit_sheet_control` hit.
pub fn applyControl(state: *runtime.AppState, index: usize) void {
    if (index >= @typeInfo(Control).@"enum".fields.len) return;
    const control: Control = @enumFromInt(index);
    switch (control) {
        .cancel => state.closeCommitSheet(),
        .primary => state.commitSheetCommit(false),
        .new_branch => state.commitSheetCommit(true),
        .regenerate => state.generateCommitMessage(true),
        .pull_push => state.commitSheetPullPush(),
        .reload => state.reloadCommitSheet(),
        .edit_toggle => state.commitSheetToggleEditing(),
        .confirm_abort => state.gitQuickAbort(),
        .confirm_direct => state.gitQuickContinue(false),
        .confirm_branch => state.gitQuickContinue(true),
        .alternate => state.commitSheetCommitAlternate(),
    }
}

pub fn applyHunkToggle(state: *runtime.AppState, packed_index: usize) void {
    state.commitSheetToggleHunk(packed_index >> 16, packed_index & 0xffff);
}

/// Marks the frame dirty when the pointer moves between targets so hover
/// styling follows the mouse.
pub fn updateHover(state: *runtime.AppState, x: f32, y: f32) void {
    if (!state.commitSheetOpen()) return;
    const hover = &state.git_changes;
    var action: u16 = 0;
    var index: usize = 0;
    var found = false;
    var i = state.palette_modal_hits.items.len;
    while (i > 0) {
        i -= 1;
        const hit = state.palette_modal_hits.items[i];
        if (!pointInRect(x, y, hit.rect)) continue;
        action = @intFromEnum(hit.action);
        index = hit.index;
        found = true;
        break;
    }
    if (found == hover.hover_valid and action == hover.hover_action and index == hover.hover_index) return;
    hover.hover_valid = found;
    hover.hover_action = action;
    hover.hover_index = index;
    state.markDirty();
}

/// Scrolls the file list or the message field under the pointer.
pub fn handleWheel(state: *runtime.AppState, width: f32, height: f32, x: f32, y: f32, wheel_y: f32) bool {
    const sheet = state.commitSheet() orelse return state.commitSheetOpen();
    var layout = Layout.init(sheet, width, height);
    defer layout.deinit();
    const geo = &layout.geo;
    if (sheet.phase == .ready and pointInRect(x, y, geo.message)) {
        sheet.message_scroll_y = @max(0.0, sheet.message_scroll_y - wheel_y * messageLineHeight());
        state.markDirty();
        return true;
    }
    if (sheet.phase == .ready and pointInRect(x, y, geo.list)) {
        sheet.scroll_y -= wheel_y * scaled(48.0);
        clampScroll(sheet, layout.rows, geo.list);
        state.markDirty();
    }
    // The dialog is modal: wheel never reaches the panes underneath.
    return true;
}

// ------------------------------------------------------------------
// Commit message field (multi-line, word-wrapped)
// ------------------------------------------------------------------

pub const Line = struct { start: usize, end: usize };

/// Word-wraps `text` into visual lines no wider than `max_w`. Hard newlines
/// end a line (the newline byte belongs to neither line); soft breaks keep
/// trailing spaces on the upper line. Returns the number of lines written.
pub fn wrapLines(text: []const u8, font_size: f32, max_w: f32, out: []Line) usize {
    if (out.len == 0) return 0;
    var count: usize = 0;
    var para_start: usize = 0;
    while (true) {
        const para_end = std.mem.indexOfScalarPos(u8, text, para_start, '\n') orelse text.len;
        var line_start = para_start;
        while (true) {
            if (count + 1 >= out.len) {
                out[count] = .{ .start = line_start, .end = text.len };
                return count + 1;
            }
            const rest = text[line_start..para_end];
            if (rest.len == 0 or text_measure.textWidth(.ui, font_size, rest) <= max_w) {
                out[count] = .{ .start = line_start, .end = para_end };
                count += 1;
                break;
            }
            const cut = fitBreak(rest, font_size, max_w);
            out[count] = .{ .start = line_start, .end = line_start + cut };
            count += 1;
            line_start += cut;
        }
        if (para_end >= text.len) break;
        para_start = para_end + 1;
    }
    return count;
}

/// Byte count of `rest` that fits on one line: after the last space that
/// fits, else as many codepoints as fit (at least one).
fn fitBreak(rest: []const u8, font_size: f32, max_w: f32) usize {
    var fit: usize = 0;
    var last_space_end: usize = 0;
    var i: usize = 0;
    while (i < rest.len) {
        const step = std.unicode.utf8ByteSequenceLength(rest[i]) catch 1;
        const next = @min(i + step, rest.len);
        if (text_measure.textPrefixWidth(.ui, rest, font_size, next) > max_w and rest[i] != ' ') break;
        fit = next;
        if (rest[i] == ' ') last_space_end = next;
        i = next;
    }
    if (last_space_end > 0 and fit < rest.len) return last_space_end;
    return @max(fit, @min(std.unicode.utf8ByteSequenceLength(rest[0]) catch 1, rest.len));
}

/// Visual line holding `cursor`; a cursor on a soft break shows at the start
/// of the lower line.
pub fn lineForCursor(lines: []const Line, cursor: usize) usize {
    if (lines.len == 0) return 0;
    var index: usize = 0;
    while (index < lines.len) : (index += 1) {
        const line = lines[index];
        if (cursor < line.start) return if (index == 0) 0 else index - 1;
        if (cursor < line.end) return index;
        if (cursor == line.end) {
            const soft = index + 1 < lines.len and lines[index + 1].start == line.end;
            if (!soft) return index;
        }
    }
    return lines.len - 1;
}

fn messageTextRect(field: palette.Rect) palette.Rect {
    const pad = scaled(MESSAGE_PAD_CSS);
    // The right edge leaves room for the ↻ button in the corner.
    return .{ .x = field.x + pad + scaled(2.0), .y = field.y + pad, .w = field.w - pad * 2.0 - scaled(6.0) - scaled(REGEN_CSS), .h = field.h - pad * 2.0 };
}

const Wrapped = struct {
    lines: [MAX_MESSAGE_LINES]Line = undefined,
    count: usize = 0,

    fn slice(self: *const Wrapped) []const Line {
        return self.lines[0..self.count];
    }
};

fn wrapMessage(sheet: *const Sheet, field: palette.Rect, out: *Wrapped) void {
    const text_rect = messageTextRect(field);
    out.count = wrapLines(sheet.message(), scaled(MESSAGE_FONT_CSS), @max(text_rect.w, scaled(20.0)), &out.lines);
}

fn offsetInLine(text: []const u8, line: Line, font_size: f32, rel: f32) usize {
    const slice = text[line.start..line.end];
    if (rel <= 0.0 or slice.len == 0) return line.start;
    var i: usize = 0;
    while (i < slice.len) {
        const step = std.unicode.utf8ByteSequenceLength(slice[i]) catch 1;
        const next = @min(i + step, slice.len);
        const before = text_measure.textPrefixWidth(.ui, slice, font_size, i);
        const after = text_measure.textPrefixWidth(.ui, slice, font_size, next);
        if (after > rel) return line.start + (if (rel - before <= after - rel) i else next);
        i = next;
    }
    // Past the end of a soft-wrapped line: stay before its trailing space so
    // the caret remains on this line.
    if (line.end > line.start and text[line.end - 1] == ' ' and line.end < text.len and text[line.end] != '\n') return line.end - 1;
    return line.end;
}

fn messageOffsetAt(sheet: *const Sheet, field: palette.Rect, x: f32, y: f32) usize {
    var wrapped: Wrapped = .{};
    wrapMessage(sheet, field, &wrapped);
    const lines = wrapped.slice();
    if (lines.len == 0) return 0;
    const text_rect = messageTextRect(field);
    const line_h = messageLineHeight();
    const rel_y = y - text_rect.y + sheet.message_scroll_y;
    const raw_index: isize = @intFromFloat(@floor(rel_y / line_h));
    const index: usize = @intCast(std.math.clamp(raw_index, 0, @as(isize, @intCast(lines.len - 1))));
    return offsetInLine(sheet.message(), lines[index], scaled(MESSAGE_FONT_CSS), x - text_rect.x);
}

fn isWordByte(b: u8) bool {
    return std.ascii.isAlphanumeric(b) or b == '_' or b == '-' or b >= 0x80;
}

/// Click in the message field: caret at the pointer, double-click selects a
/// word, triple-click selects the whole message.
pub fn focusMessageAt(state: *runtime.AppState, x: f32, y: f32, clicks: u8) void {
    const sheet = state.commitSheet() orelse return;
    if (state.palette_modal_text_focus != .commit_message) {
        state.palette_modal_text_focus = .commit_message;
        state.modal_text_selection_anchor = null;
    }
    const text = sheet.message();
    const offset = messageOffsetAt(sheet, state.modal_text_input_rect, x, y);
    if (clicks >= 3) {
        state.modal_text_selection_anchor = 0;
        sheet.message_cursor = text.len;
        state.modal_text_drag_active = false;
    } else if (clicks == 2) {
        var start = @min(offset, text.len);
        var end = start;
        while (start > 0 and isWordByte(text[start - 1])) start -= 1;
        while (end < text.len and isWordByte(text[end])) end += 1;
        state.modal_text_selection_anchor = start;
        sheet.message_cursor = end;
        state.modal_text_drag_active = false;
    } else {
        sheet.message_cursor = offset;
        state.modal_text_selection_anchor = offset;
        state.modal_text_drag_active = true;
    }
    state.markDirty();
}

/// Extends the selection while dragging inside the message field.
pub fn dragMessageTo(state: *runtime.AppState, x: f32, y: f32) void {
    const sheet = state.commitSheet() orelse return;
    sheet.message_cursor = messageOffsetAt(sheet, state.modal_text_input_rect, x, y);
    state.markDirty();
}

/// Caret target one visual line up or down, keeping the x position.
pub fn verticalTarget(state: *runtime.AppState, down: bool) usize {
    const sheet = state.commitSheet() orelse return 0;
    var wrapped: Wrapped = .{};
    wrapMessage(sheet, state.modal_text_input_rect, &wrapped);
    const lines = wrapped.slice();
    const text = sheet.message();
    if (lines.len == 0) return 0;
    const cursor = @min(sheet.message_cursor, text.len);
    const index = lineForCursor(lines, cursor);
    if (!down and index == 0) return 0;
    if (down and index + 1 >= lines.len) return text.len;
    const font_size = scaled(MESSAGE_FONT_CSS);
    const line = lines[index];
    const x = text_measure.textPrefixWidth(.ui, text[line.start..line.end], font_size, cursor - line.start);
    return offsetInLine(text, lines[if (down) index + 1 else index - 1], font_size, x);
}

/// Start or end of the caret's visual line.
pub fn lineEdgeTarget(state: *runtime.AppState, start: bool) usize {
    const sheet = state.commitSheet() orelse return 0;
    var wrapped: Wrapped = .{};
    wrapMessage(sheet, state.modal_text_input_rect, &wrapped);
    const lines = wrapped.slice();
    const text = sheet.message();
    if (lines.len == 0) return 0;
    const line = lines[lineForCursor(lines, @min(sheet.message_cursor, text.len))];
    if (start) return line.start;
    if (line.end > line.start and line.end < text.len and text[line.end] != '\n' and text[line.end - 1] == ' ') return line.end - 1;
    return line.end;
}

// ------------------------------------------------------------------
// Rendering
// ------------------------------------------------------------------

/// Renders the dialog (or the default-branch confirmation) when open.
pub fn render(state: *runtime.AppState, width: f32, height: f32) void {
    const sheet = state.commitSheet() orelse {
        if (state.gitQuickConfirm()) |quick| renderConfirm(state, quick, width, height);
        return;
    };
    var layout = Layout.init(sheet, width, height);
    defer layout.deinit();
    const geo = &layout.geo;
    const modal = geo.modal;
    const full: palette.Rect = .{ .x = 0, .y = 0, .w = width, .h = height };

    // Chrome: scrim, card, border (matches the other centered modals).
    roundedRect(state, full, theme.scrim(0.68), 0.0, full);
    roundedRect(state, modal, theme.COLOR_PANEL, scaled(MODAL_RADIUS_CSS), full);
    border(state, modal, theme.withAlpha(theme.borderMuted(), 110), scaled(MODAL_RADIUS_CSS), scaled(1.0), full);

    labelText(state, .{ .x = geo.subtitle.x, .y = geo.title_y, .w = geo.subtitle.w, .h = scaled(22.0) }, "Commit changes", theme.COLOR_WHITE, scaled(TITLE_FONT_CSS), .ui_bold, modal);
    labelWrapped(state, geo.subtitle, SUBTITLE, theme.COLOR_TEXT_MUTED, scaled(SMALL_FONT_CSS), modal);

    if (geo.notice) |notice| {
        roundedRect(state, notice, theme.wash(theme.COLOR_YELLOW, 30), scaled(7.0), modal);
        var notice_buf: [256]u8 = undefined;
        labelText(state, .{ .x = notice.x + scaled(10.0), .y = notice.y + (notice.h - scaled(16.0)) * 0.5, .w = notice.w - scaled(20.0), .h = scaled(16.0) }, truncatedLabel(&notice_buf, "This chat is still working, so this shows its changes as of now.", notice.w - scaled(20.0), scaled(SMALL_FONT_CSS)), theme.COLOR_YELLOW, scaled(SMALL_FONT_CSS), .ui, modal);
    }

    // Card surface.
    const card_radius = scaled(CARD_RADIUS_CSS);
    roundedRect(state, geo.card, theme.sink(theme.COLOR_PANEL_ALT, 0.03), card_radius, modal);
    border(state, geo.card, theme.COLOR_PANEL_MUTED, card_radius, scaled(1.0), modal);
    switch (sheet.phase) {
        .loading => cardMessage(state, geo.card, "Loading changes\u{2026}", theme.COLOR_TEXT_SUBTLE),
        .load_error => cardMessage(state, geo.card, if (sheet.error_len > 0) sheet.errorText() else "Could not load this chat's changes.", theme.COLOR_YELLOW),
        .result => drawResult(state, sheet, geo.card),
        .ready => {
            drawBranchRow(state, sheet, geo.branch_row, geo.card);
            roundedRect(state, .{ .x = geo.card.x, .y = geo.branch_row.y + geo.branch_row.h, .w = geo.card.w, .h = scaled(1.0) }, theme.COLOR_PANEL_MUTED, 0.0, geo.card);
            drawFilesHeader(state, sheet, geo);
            drawRows(state, sheet, layout.rows, geo.list);
            drawTotals(state, sheet, geo.totals, geo.card);
        },
    }

    if (sheet.phase == .ready) {
        drawMessageSection(state, sheet, geo);
        if (geo.error_rect) |rect| {
            labelWrapped(state, rect, sheet.errorText(), theme.COLOR_YELLOW, scaled(SMALL_FONT_CSS), modal);
        }
    }

    const busy = sheet.busy != null;
    const locked = sheet.locked();
    drawSecondaryButton(state, geo.cancel, if (sheet.phase == .result) "Done" else "Cancel", !busy, modal);
    switch (sheet.phase) {
        .ready => {
            const enabled = !locked and sheet.selectedFileCount() > 0;
            if (geo.new_branch) |rect| drawSecondaryButton(state, rect, geo.new_branch_label, enabled, modal);
            if (geo.alternate) |rect| drawSecondaryButton(state, rect, actionLabel(sheet, sheet.mode.other()), enabled, modal);
            if (geo.primary) |rect| drawActionButton(state, rect, primaryLabel(sheet), enabled, modal);
        },
        .result => if (geo.primary) |rect| drawActionButton(state, rect, if (sheet.pull_push_busy) "Pulling & pushing\u{2026}" else "Pull & push", !sheet.pull_push_busy, modal),
        .load_error => if (geo.primary) |rect| drawActionButton(state, rect, "Retry", true, modal),
        .loading => {},
    }
}

fn cardMessage(state: *runtime.AppState, card: palette.Rect, text: []const u8, color: [4]f32) void {
    const pad = scaled(CARD_PAD_X_CSS);
    labelWrapped(state, .{ .x = card.x + pad, .y = card.y + pad, .w = card.w - pad * 2.0, .h = card.h - pad * 2.0 }, text, color, scaled(BODY_FONT_CSS), card);
}

fn drawResult(state: *runtime.AppState, sheet: *const Sheet, card: palette.Rect) void {
    const pad = scaled(CARD_PAD_X_CSS);
    const x = card.x + pad;
    const w = card.w - pad * 2.0;
    labelWrapped(state, .{ .x = x, .y = card.y + pad, .w = w, .h = scaled(34.0) }, sheet.outcomeText(), theme.COLOR_WHITE, scaled(BODY_FONT_CSS), card);
    labelWrapped(state, .{ .x = x, .y = card.y + pad + scaled(36.0), .w = w, .h = scaled(32.0) }, "The remote has commits this branch does not. Pull & push rebases onto them and pushes again.", theme.COLOR_TEXT_MUTED, scaled(SMALL_FONT_CSS), card);
    if (sheet.error_len > 0) {
        labelWrapped(state, .{ .x = x, .y = card.y + pad + scaled(70.0), .w = w, .h = scaled(16.0) }, sheet.errorText(), theme.COLOR_YELLOW, scaled(SMALL_FONT_CSS), card);
    }
}

/// `Branch <name>`, with an amber warning when a selected file's repository
/// is on its default branch.
fn drawBranchRow(state: *runtime.AppState, sheet: *const Sheet, row: palette.Rect, clip: palette.Rect) void {
    const review = sheet.reviewValue() orelse return;
    const font = scaled(BODY_FONT_CSS);
    const small = scaled(SMALL_FONT_CSS);
    const text_y = row.y + (row.h - font * 1.25) * 0.5;
    const label = "Branch";
    const label_w = text_measure.textWidth(.ui, font, label);
    labelText(state, .{ .x = row.x, .y = text_y, .w = label_w + scaled(2.0), .h = font * 1.25 }, label, theme.COLOR_TEXT_MUTED, font, .ui, clip);

    var right = row.x + row.w;
    if (sheet.selectionOnDefaultBranch()) {
        const warning = "Warning: default branch";
        const warn_w = text_measure.textWidth(.ui, small, warning);
        const icon_w = scaled(16.0);
        right -= warn_w;
        labelText(state, .{ .x = right, .y = row.y + (row.h - small * 1.25) * 0.5, .w = warn_w + scaled(2.0), .h = small * 1.25 }, warning, theme.COLOR_YELLOW, small, .ui, clip);
        right -= icon_w + scaled(2.0);
        labelText(state, .{ .x = right, .y = row.y + (row.h - small * 1.25) * 0.5, .w = icon_w, .h = small * 1.25 }, "\u{EA6C}", theme.COLOR_YELLOW, small, .icon, clip);
        right -= scaled(12.0);
    }

    // The repository holding the first selected file names the branch.
    var shown_repo: ?git_changes.ReviewRepo = if (review.repos.len > 0) review.repos[0] else null;
    var index: usize = 0;
    outer: for (review.repos) |repo| {
        for (repo.files) |file| {
            defer index += 1;
            if (index < sheet.ticks.len and sheet.ticks[index].state(file) != .none) {
                shown_repo = repo;
                break :outer;
            }
        }
    }
    const repo = shown_repo orelse return;
    var name_buf: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&name_buf);
    writer.writeAll(repo.branch orelse "detached HEAD") catch {};
    if (review.repos.len > 1) writer.print("  \u{00B7} {s} +{d}", .{ repo.name, review.repos.len - 1 }) catch {};
    const x = row.x + label_w + scaled(12.0);
    const max_w = @max(right - x, 0.0);
    var trunc_buf: [288]u8 = undefined;
    const mono = scaled(MONO_FONT_CSS + 0.5);
    const name = truncatedLabelRole(&trunc_buf, writer.buffered(), max_w, mono, .mono);
    labelText(state, .{ .x = x, .y = row.y + (row.h - mono * 1.25) * 0.5, .w = max_w + scaled(2.0), .h = mono * 1.25 }, name, theme.COLOR_WHITE, mono, .mono, clip);
}

fn drawFilesHeader(state: *runtime.AppState, sheet: *const Sheet, geo: *const Geometry) void {
    const row = geo.files_head;
    const font = scaled(BODY_FONT_CSS);
    labelText(state, .{ .x = row.x, .y = row.y + (row.h - font * 1.25) * 0.5, .w = scaled(80.0), .h = font * 1.25 }, "Files", theme.COLOR_WHITE, font, .ui_bold, geo.card);
    const enabled = !sheet.locked();
    const hovered = enabled and pointInRect(state.transcript_controller.palette_mouse_x, state.transcript_controller.palette_mouse_y, geo.edit);
    if (hovered) roundedRect(state, geo.edit, controlHoverSurface(), scaled(6.0), geo.card);
    if (sheet.editing) {
        roundedRect(state, geo.edit, theme.wash(theme.accent(), 40), scaled(6.0), geo.card);
    } else {
        border(state, geo.edit, theme.withAlpha(theme.COLOR_WHITE, 30), scaled(6.0), scaled(1.0), geo.card);
    }
    const color = if (!enabled) theme.COLOR_TEXT_SUBTLE else if (sheet.editing) theme.accent() else theme.COLOR_WHITE;
    centeredLabel(state, geo.edit, if (sheet.editing) "Hide diffs" else "Show diffs", color, scaled(SMALL_FONT_CSS), geo.card);
}

fn drawTotals(state: *runtime.AppState, sheet: *const Sheet, row: palette.Rect, clip: palette.Rect) void {
    const totals = sheet.selectedTotals();
    const small = scaled(SMALL_FONT_CSS);
    const text_y = row.y + (row.h - small * 1.25) * 0.5;
    var count_buf: [96]u8 = undefined;
    const all = sheet.fileCount();
    const count = if (totals.files == all)
        std.fmt.bufPrint(&count_buf, "{d} {s}", .{ all, if (all == 1) "file" else "files" }) catch ""
    else
        std.fmt.bufPrint(&count_buf, "{d} of {d} files", .{ totals.files, all }) catch "";
    labelText(state, .{ .x = row.x, .y = text_y, .w = row.w * 0.5, .h = small * 1.25 }, count, theme.COLOR_TEXT_MUTED, small, .ui, clip);
    _ = drawCounts(state, row.x + row.w, text_y, totals.additions, totals.deletions, small, 1.0, clip);
}

/// Right-aligned `+a / −d` ending at `right`; returns its left edge.
fn drawCounts(state: *runtime.AppState, right: f32, y: f32, additions: u64, deletions: u64, font: f32, alpha: f32, clip: palette.Rect) f32 {
    var add_buf: [24]u8 = undefined;
    const add = std.fmt.bufPrint(&add_buf, "+{d}", .{additions}) catch "";
    var del_buf: [24]u8 = undefined;
    const del = std.fmt.bufPrint(&del_buf, "\u{2212}{d}", .{deletions}) catch "";
    const sep = " / ";
    const add_w = text_measure.textWidth(.mono, font, add);
    const sep_w = text_measure.textWidth(.mono, font, sep);
    const del_w = text_measure.textWidth(.mono, font, del);
    var x = right - del_w;
    labelText(state, .{ .x = x, .y = y, .w = del_w + scaled(2.0), .h = font * 1.25 }, del, fade(theme.COLOR_DIFF_REMOVE, alpha), font, .mono, clip);
    x -= sep_w;
    labelText(state, .{ .x = x, .y = y, .w = sep_w + scaled(2.0), .h = font * 1.25 }, sep, fade(theme.COLOR_TEXT_SUBTLE, alpha), font, .mono, clip);
    x -= add_w;
    labelText(state, .{ .x = x, .y = y, .w = add_w + scaled(2.0), .h = font * 1.25 }, add, fade(theme.COLOR_DIFF_ADD, alpha), font, .mono, clip);
    return x;
}

fn fade(color: [4]f32, alpha: f32) [4]f32 {
    return .{ color[0], color[1], color[2], color[3] * alpha };
}

fn drawRows(state: *runtime.AppState, sheet: *Sheet, rows: []const Row, list: palette.Rect) void {
    if (rows.len == 0) {
        const small = scaled(SMALL_FONT_CSS);
        labelText(state, .{ .x = list.x + scaled(8.0), .y = list.y + scaled(6.0), .w = list.w - scaled(16.0), .h = small * 1.25 }, "No uncommitted changes for this chat.", theme.COLOR_TEXT_SUBTLE, small, .ui, list);
        return;
    }
    const review = sheet.reviewValue() orelse return;
    const mouse_x = state.transcript_controller.palette_mouse_x;
    const mouse_y = state.transcript_controller.palette_mouse_y;
    const interactive = !sheet.locked();
    for (rows) |row| {
        const rect = rowRect(row, list, sheet.scroll_y);
        const clip = intersect(rect, list) orelse continue;
        const hovered = interactive and pointInRect(mouse_x, mouse_y, clip);
        switch (row.kind) {
            .repo => drawRepoRow(state, review.repos[row.repo], rect, clip),
            .plain => drawPlainRow(state, sheet, row.file, rect, clip),
            .file => drawFileRow(state, sheet, row.file, rect, clip, hovered),
            .note => labelText(state, .{ .x = rect.x + scaled(CHECK_COLUMN_CSS + 22.0), .y = rect.y + (rect.h - scaled(15.0)) * 0.5, .w = rect.w - scaled(CHECK_COLUMN_CSS + 30.0), .h = scaled(15.0) }, row.text, theme.COLOR_TEXT_SUBTLE, scaled(SMALL_FONT_CSS), .ui, clip),
            .hunk => drawHunkRow(state, sheet, row, rect, clip, hovered),
            .line => drawDiffLine(state, row.text, rect, clip),
            .more => labelText(state, .{ .x = rect.x + scaled(CHECK_COLUMN_CSS + 22.0), .y = rect.y + (rect.h - scaled(15.0)) * 0.5, .w = rect.w - scaled(CHECK_COLUMN_CSS + 30.0), .h = scaled(15.0) }, row.text, theme.COLOR_TEXT_SUBTLE, scaled(SMALL_FONT_CSS), .ui, clip),
        }
    }
    // Scroll hint: a thin thumb on the right edge when the list overflows.
    const content_h = contentHeight(rows);
    if (content_h > list.h) {
        const thumb_h = @max(list.h * list.h / content_h, scaled(20.0));
        const travel = list.h - thumb_h;
        const t = sheet.scroll_y / (content_h - list.h);
        roundedRect(state, .{ .x = list.x + list.w - scaled(3.0), .y = list.y + travel * t, .w = scaled(3.0), .h = thumb_h }, theme.withAlpha(theme.COLOR_WHITE, 40), scaled(1.5), list);
    }
}

fn drawRepoRow(state: *runtime.AppState, repo: git_changes.ReviewRepo, rect: palette.Rect, clip: palette.Rect) void {
    const small = scaled(SMALL_FONT_CSS);
    const text_y = rect.y + (rect.h - small * 1.25) * 0.5;
    const x = rect.x + scaled(8.0);
    const name_w = text_measure.textWidth(.ui_bold, small, repo.name);
    labelText(state, .{ .x = x, .y = text_y, .w = name_w + scaled(2.0), .h = small * 1.25 }, repo.name, theme.COLOR_TEXT_MUTED, small, .ui_bold, clip);
    if (repo.branch) |branch| {
        const bx = x + name_w + scaled(8.0);
        var branch_buf: [256]u8 = undefined;
        const max_w = @max(rect.x + rect.w - scaled(8.0) - bx, 0.0);
        const shown = truncatedLabelRole(&branch_buf, branch, max_w, small, .mono);
        labelText(state, .{ .x = bx, .y = text_y, .w = max_w, .h = small * 1.25 }, shown, theme.COLOR_TEXT_SUBTLE, small, .mono, clip);
    }
}

/// Plain list row: path, a tag for files that are not wholly this chat's
/// (or are partially selected), and `+a / −d`. Unselected files are dimmed.
fn drawPlainRow(state: *runtime.AppState, sheet: *const Sheet, flat: usize, rect: palette.Rect, clip: palette.Rect) void {
    const found = sheet.fileAt(flat) orelse return;
    const file = found.file;
    const tick: TickState = if (flat < sheet.ticks.len) sheet.ticks[flat].state(file) else .none;
    const selected = tick != .none;
    const mono = scaled(MONO_FONT_CSS + 0.5);
    const small = scaled(SMALL_FONT_CSS);
    const text_y = rect.y + (rect.h - mono * 1.25) * 0.5;
    const alpha: f32 = if (selected) 1.0 else 0.45;
    var right = drawCounts(state, rect.x + rect.w - scaled(8.0), text_y, file.additions, file.deletions, mono, alpha, clip) - scaled(10.0);

    const mine = std.mem.eql(u8, file.ownership, "mine");
    const tag: ?[]const u8 = if (!mine)
        file.ownership
    else if (tick == .partial)
        "partial"
    else if (!selected)
        "excluded"
    else
        null;
    if (tag) |value| {
        const pill_font = scaled(10.5);
        const color = if (std.mem.eql(u8, value, "shared") or std.mem.eql(u8, value, "unclear"))
            theme.COLOR_YELLOW
        else if (tick == .partial)
            theme.accent()
        else
            theme.COLOR_TEXT_MUTED;
        const tag_w = text_measure.textWidth(.ui, pill_font, value);
        const pill_pad = scaled(6.0);
        const pill_h = scaled(17.0);
        const pill: palette.Rect = .{ .x = right - tag_w - pill_pad * 2.0, .y = rect.y + (rect.h - pill_h) * 0.5, .w = tag_w + pill_pad * 2.0, .h = pill_h };
        roundedRect(state, pill, theme.wash(color, if (selected) 36 else 22), pill_h * 0.5, clip);
        labelText(state, .{ .x = pill.x + pill_pad, .y = pill.y + (pill_h - pill_font * 1.25) * 0.5, .w = tag_w + scaled(2.0), .h = pill_font * 1.25 }, value, fade(color, if (selected) 1.0 else 0.75), pill_font, .ui, clip);
        right = pill.x - scaled(8.0);
    }
    _ = small;

    const x = rect.x + scaled(8.0);
    var path_buf: [512]u8 = undefined;
    const max_w = @max(right - x, 0.0);
    const path = truncatedLabelRole(&path_buf, file.path, max_w, mono, .mono);
    labelText(state, .{ .x = x, .y = text_y, .w = max_w + scaled(2.0), .h = mono * 1.25 }, path, if (selected) theme.COLOR_WHITE else theme.COLOR_TEXT_SUBTLE, mono, .mono, clip);
}

fn drawFileRow(state: *runtime.AppState, sheet: *const Sheet, flat: usize, rect: palette.Rect, clip: palette.Rect, hovered: bool) void {
    const found = sheet.fileAt(flat) orelse return;
    const file = found.file;
    if (hovered) roundedRect(state, rect, theme.withAlpha(theme.COLOR_WHITE, 10), scaled(6.0), clip);
    const tick: TickState = if (flat < sheet.ticks.len) sheet.ticks[flat].state(file) else .none;
    drawCheckbox(state, checkColumn(rect, 0.0), tick, clip);

    var x = rect.x + scaled(CHECK_COLUMN_CSS);
    const font = scaled(MONO_FONT_CSS + 0.5);
    const small = scaled(SMALL_FONT_CSS);
    const expanded = flat < sheet.expanded.len and sheet.expanded[flat];
    if (expandable(file)) {
        const chevron: []const u8 = if (expanded) "\u{25BE}" else "\u{25B8}";
        labelText(state, .{ .x = x, .y = rect.y + (rect.h - small * 1.25) * 0.5, .w = scaled(14.0), .h = small * 1.25 }, chevron, theme.COLOR_TEXT_MUTED, small, .ui, clip);
    }
    x += scaled(16.0);
    const status = statusLetter(file.status);
    labelText(state, .{ .x = x, .y = rect.y + (rect.h - scaled(MONO_FONT_CSS) * 1.25) * 0.5, .w = scaled(14.0), .h = scaled(MONO_FONT_CSS) * 1.25 }, status.letter, status.color, scaled(MONO_FONT_CSS), .mono, clip);
    x += scaled(16.0);

    // Right block: ownership pill then +/− counts.
    const counts_y = rect.y + (rect.h - font * 1.25) * 0.5;
    var right = drawCounts(state, rect.x + rect.w - scaled(8.0), counts_y, file.additions, file.deletions, font, 1.0, clip) - scaled(10.0);

    var owner_buf: [256]u8 = undefined;
    const owner_full = git_changes.ownershipLabel(&owner_buf, file);
    const mine = std.mem.eql(u8, file.ownership, "mine");
    const unassigned = std.mem.eql(u8, file.ownership, "unassigned");
    const pill_color = if (mine) theme.accent() else if (unassigned) theme.COLOR_TEXT_MUTED else theme.COLOR_YELLOW;
    const pill_font = scaled(10.5);
    const max_pill_text = @max((right - x) * 0.4, scaled(36.0));
    var owner_trunc: [256]u8 = undefined;
    const owner = truncatedLabel(&owner_trunc, owner_full, max_pill_text, pill_font);
    const pill_text_w = text_measure.textWidth(.ui, pill_font, owner);
    const pill_pad = scaled(6.0);
    const pill_h = scaled(17.0);
    const pill: palette.Rect = .{ .x = right - pill_text_w - pill_pad * 2.0, .y = rect.y + (rect.h - pill_h) * 0.5, .w = pill_text_w + pill_pad * 2.0, .h = pill_h };
    roundedRect(state, pill, theme.wash(pill_color, 36), pill_h * 0.5, clip);
    labelText(state, .{ .x = pill.x + pill_pad, .y = pill.y + (pill_h - pill_font * 1.25) * 0.5, .w = pill_text_w + scaled(2.0), .h = pill_font * 1.25 }, owner, pill_color, pill_font, .ui, clip);
    right = pill.x - scaled(8.0);

    var path_buf: [512]u8 = undefined;
    const path = truncatedLabelRole(&path_buf, file.path, @max(right - x, 0.0), font, .mono);
    labelText(state, .{ .x = x, .y = rect.y + (rect.h - font * 1.25) * 0.5, .w = @max(right - x, 0.0), .h = font * 1.25 }, path, theme.COLOR_WHITE, font, .mono, clip);
}

fn drawHunkRow(state: *runtime.AppState, sheet: *const Sheet, row: Row, rect: palette.Rect, clip: palette.Rect, hovered: bool) void {
    const found = sheet.fileAt(row.file) orelse return;
    const selectable = git_changes.canSelectHunks(found.file);
    const indent = scaled(CHECK_COLUMN_CSS);
    if (hovered and selectable) roundedRect(state, rect, theme.withAlpha(theme.COLOR_WHITE, 10), scaled(5.0), clip);
    if (selectable and row.file < sheet.ticks.len) {
        const ticked = sheet.ticks[row.file].hunkTicked(row.hunk);
        drawCheckbox(state, checkColumn(rect, indent), if (ticked) .all else .none, clip);
    }
    const x = rect.x + indent + scaled(CHECK_COLUMN_CSS);
    const font = scaled(MONO_FONT_CSS);
    labelText(state, .{ .x = x, .y = rect.y + (rect.h - font * 1.25) * 0.5, .w = rect.x + rect.w - x - scaled(8.0), .h = font * 1.25 }, row.text, theme.accent(), font, .mono, clip);
}

fn drawDiffLine(state: *runtime.AppState, text: []const u8, rect: palette.Rect, clip: palette.Rect) void {
    const indent = scaled(CHECK_COLUMN_CSS * 2.0);
    const line_rect: palette.Rect = .{ .x = rect.x + indent - scaled(6.0), .y = rect.y, .w = rect.w - indent + scaled(6.0), .h = rect.h };
    const kind: u8 = if (text.len > 0) text[0] else ' ';
    if (kind == '+') roundedRect(state, line_rect, theme.wash(theme.COLOR_DIFF_ADD, 34), 0.0, clip);
    if (kind == '-') roundedRect(state, line_rect, theme.wash(theme.COLOR_DIFF_REMOVE, 34), 0.0, clip);
    const color = switch (kind) {
        '+' => theme.mix(theme.COLOR_WHITE, theme.COLOR_DIFF_ADD, 0.35),
        '-' => theme.mix(theme.COLOR_WHITE, theme.COLOR_DIFF_REMOVE, 0.35),
        '\\' => theme.COLOR_TEXT_SUBTLE,
        else => theme.COLOR_TEXT_MUTED,
    };
    var expanded_buf: [1024]u8 = undefined;
    const shown = expandTabs(&expanded_buf, text);
    const font = scaled(MONO_FONT_CSS);
    labelText(state, .{ .x = rect.x + indent, .y = rect.y + (rect.h - font * 1.25) * 0.5, .w = rect.w - indent - scaled(8.0), .h = font * 1.25 }, shown, color, font, .mono, clip);
}

fn expandTabs(buf: []u8, text: []const u8) []const u8 {
    var n: usize = 0;
    for (text) |b| {
        if (b == '\t') {
            var spaces: usize = 4;
            while (spaces > 0 and n < buf.len) : (spaces -= 1) {
                buf[n] = ' ';
                n += 1;
            }
        } else if (n < buf.len) {
            buf[n] = b;
            n += 1;
        }
        if (n >= buf.len) break;
    }
    return buf[0..n];
}

const StatusMark = struct { letter: []const u8, color: [4]f32 };

fn statusLetter(status: []const u8) StatusMark {
    if (std.mem.eql(u8, status, "added")) return .{ .letter = "A", .color = theme.COLOR_DIFF_ADD };
    if (std.mem.eql(u8, status, "deleted")) return .{ .letter = "D", .color = theme.COLOR_DIFF_REMOVE };
    return .{ .letter = "M", .color = theme.COLOR_YELLOW };
}

fn drawCheckbox(state: *runtime.AppState, column: palette.Rect, tick: TickState, clip: palette.Rect) void {
    const size = scaled(CHECKBOX_CSS);
    const box: palette.Rect = .{ .x = column.x + (column.w - size) * 0.5, .y = column.y + (column.h - size) * 0.5, .w = size, .h = size };
    const radius = scaled(4.0);
    const accent = theme.accent();
    switch (tick) {
        .none => {
            roundedRect(state, box, theme.sink(theme.COLOR_PANEL_ALT, 0.02), radius, clip);
            border(state, box, theme.withAlpha(theme.COLOR_WHITE, 70), radius, scaled(1.0), clip);
        },
        .all => {
            roundedRect(state, box, accent, radius, clip);
            const font = scaled(11.5);
            const mark = "\u{2713}";
            const mark_w = text_measure.textWidth(.ui, font, mark);
            labelText(state, .{ .x = box.x + (size - mark_w) * 0.5, .y = box.y + (size - font * 1.25) * 0.5, .w = mark_w + scaled(2.0), .h = font * 1.25 }, mark, theme.foregroundOn(accent), font, .ui, clip);
        },
        .partial => {
            roundedRect(state, box, theme.wash(accent, 60), radius, clip);
            border(state, box, accent, radius, scaled(1.0), clip);
            const bar_w = size * 0.5;
            const bar_h = scaled(2.0);
            roundedRect(state, .{ .x = box.x + (size - bar_w) * 0.5, .y = box.y + (size - bar_h) * 0.5, .w = bar_w, .h = bar_h }, accent, bar_h * 0.5, clip);
        },
    }
}

fn drawMessageSection(state: *runtime.AppState, sheet: *Sheet, geo: *const Geometry) void {
    const modal = geo.modal;
    const label_y = geo.message_label_y orelse return;
    const small = scaled(SMALL_FONT_CSS);
    const label_h = scaled(20.0);
    const label = "Commit message";
    const label_w = text_measure.textWidth(.ui_bold, small, label);
    const text_y = label_y + (label_h - small * 1.25) * 0.5;
    labelText(state, .{ .x = geo.message.x, .y = text_y, .w = label_w + scaled(2.0), .h = small * 1.25 }, label, theme.COLOR_WHITE, small, .ui_bold, modal);
    const optional = " (optional)";
    const optional_w = text_measure.textWidth(.ui, small, optional);
    labelText(state, .{ .x = geo.message.x + label_w, .y = text_y, .w = optional_w + scaled(2.0), .h = small * 1.25 }, optional, theme.COLOR_TEXT_SUBTLE, small, .ui, modal);

    // Provider source (or failure), right-aligned.
    const status: []const u8 = switch (sheet.message_status) {
        .writing => "",
        .failed => "Couldn't write a message",
        .idle => if (sheet.source_len > 0) sheet.sourceText() else "",
    };
    if (status.len > 0) {
        var status_buf: [160]u8 = undefined;
        const max_w = @max(geo.message.w - label_w - optional_w - scaled(24.0), 0.0);
        const shown = truncatedLabel(&status_buf, status, max_w, small);
        const w = text_measure.textWidth(.ui, small, shown);
        const color = if (sheet.message_status == .failed) theme.COLOR_YELLOW else theme.COLOR_TEXT_SUBTLE;
        labelText(state, .{ .x = geo.message.x + geo.message.w - w, .y = text_y, .w = w + scaled(2.0), .h = small * 1.25 }, shown, color, small, .ui, modal);
    }

    drawMessageField(state, sheet, geo.message);

    const enabled = !sheet.locked() and sheet.message_status != .writing;
    const regen_hovered = enabled and pointInRect(state.transcript_controller.palette_mouse_x, state.transcript_controller.palette_mouse_y, geo.regenerate);
    if (regen_hovered) roundedRect(state, geo.regenerate, controlHoverSurface(), scaled(6.0), geo.message);
    const icon_font = scaled(14.0);
    labelText(state, .{
        .x = geo.regenerate.x + (geo.regenerate.w - icon_font) * 0.5,
        .y = geo.regenerate.y + (geo.regenerate.h - icon_font * 1.25) * 0.5,
        .w = icon_font + scaled(2.0),
        .h = icon_font * 1.25,
    }, "\u{EB37}", if (enabled) theme.COLOR_TEXT_MUTED else theme.COLOR_TEXT_SUBTLE, icon_font, .icon, geo.message);
}

/// Grey placeholder shown while nothing is typed: the generated message
/// (what an empty box commits), or its progress.
fn placeholderText(sheet: *const Sheet) []const u8 {
    if (sheet.message_status == .writing) return "Writing message\u{2026}";
    if (sheet.generated_len > 0) return sheet.generated();
    if (sheet.message_status == .failed) return "Describe the change";
    return "Describe the change, or leave blank to generate one";
}

fn drawMessageField(state: *runtime.AppState, sheet: *Sheet, field: palette.Rect) void {
    const focused = state.palette_modal_text_focus == .commit_message;
    roundedRect(state, field, theme.sink(theme.COLOR_PANEL_ALT, 0.03), scaled(8.0), field);
    border(state, field, if (focused) theme.accent() else theme.COLOR_PANEL_MUTED, scaled(8.0), scaled(1.0), field);
    const text_rect = messageTextRect(field);
    const font = scaled(MESSAGE_FONT_CSS);
    const line_h = messageLineHeight();
    const text = sheet.message();
    if (text.len == 0) {
        const hint = placeholderText(sheet);
        var hint_lines: [64]Line = undefined;
        const count = wrapLines(hint, font, @max(text_rect.w, scaled(20.0)), &hint_lines);
        for (hint_lines[0..count], 0..) |line, index| {
            const y = text_rect.y + @as(f32, @floatFromInt(index)) * line_h;
            if (y + line_h > text_rect.y + text_rect.h + scaled(1.0)) break;
            labelText(state, .{ .x = text_rect.x, .y = y + (line_h - font * 1.25) * 0.5, .w = text_rect.w + scaled(2.0), .h = font * 1.25 }, hint[line.start..line.end], theme.COLOR_TEXT_SUBTLE, font, .ui, text_rect);
        }
        sheet.message_scroll_y = 0.0;
        if (focused) {
            roundedRect(state, .{ .x = text_rect.x, .y = text_rect.y + scaled(2.0), .w = scaled(1.0), .h = line_h - scaled(4.0) }, theme.COLOR_WHITE, 0.0, text_rect);
        }
        return;
    }
    var wrapped: Wrapped = .{};
    wrapMessage(sheet, field, &wrapped);
    const lines = wrapped.slice();
    const cursor = @min(sheet.message_cursor, text.len);
    const caret_line = lineForCursor(lines, cursor);

    // Keep the caret line inside the field while editing.
    const content_h = @as(f32, @floatFromInt(@max(lines.len, 1))) * line_h;
    const max_scroll = @max(content_h - text_rect.h, 0.0);
    if (focused) {
        const caret_top = @as(f32, @floatFromInt(caret_line)) * line_h;
        if (caret_top < sheet.message_scroll_y) sheet.message_scroll_y = caret_top;
        if (caret_top + line_h > sheet.message_scroll_y + text_rect.h) sheet.message_scroll_y = caret_top + line_h - text_rect.h;
    }
    sheet.message_scroll_y = theme.clampf(sheet.message_scroll_y, 0.0, max_scroll);

    const selection: ?[2]usize = blk: {
        if (!focused) break :blk null;
        const anchor = state.modal_text_selection_anchor orelse break :blk null;
        const a = @min(anchor, text.len);
        if (a == cursor) break :blk null;
        break :blk .{ @min(a, cursor), @max(a, cursor) };
    };
    for (lines, 0..) |line, index| {
        const y = text_rect.y + @as(f32, @floatFromInt(index)) * line_h - sheet.message_scroll_y;
        if (y + line_h < text_rect.y or y > text_rect.y + text_rect.h) continue;
        const slice = text[line.start..line.end];
        if (selection) |sel| {
            const s0 = @max(sel[0], line.start);
            const s1 = @min(sel[1], line.end);
            if (s1 > s0) {
                const x0 = text_rect.x + text_measure.textPrefixWidth(.ui, slice, font, s0 - line.start);
                const x1 = text_rect.x + text_measure.textPrefixWidth(.ui, slice, font, s1 - line.start);
                roundedRect(state, .{ .x = x0, .y = y, .w = x1 - x0, .h = line_h }, theme.withAlpha(theme.selection(), 200), 0.0, text_rect);
            }
        }
        if (slice.len > 0) {
            labelText(state, .{ .x = text_rect.x, .y = y + (line_h - font * 1.25) * 0.5, .w = text_rect.w + scaled(2.0), .h = font * 1.25 }, slice, theme.COLOR_WHITE, font, .ui, text_rect);
        }
        if (focused and index == caret_line) {
            const caret_x = text_rect.x + text_measure.textPrefixWidth(.ui, slice, font, cursor - line.start);
            roundedRect(state, .{ .x = caret_x, .y = y + scaled(2.0), .w = scaled(1.0), .h = line_h - scaled(4.0) }, theme.COLOR_WHITE, 0.0, text_rect);
        }
    }
}

// ------------------------------------------------------------------
// Drawing helpers
// ------------------------------------------------------------------

fn controlSurface() [4]f32 {
    return theme.mix(theme.background(), theme.COLOR_WHITE, 0.14);
}

fn controlHoverSurface() [4]f32 {
    return theme.mix(theme.background(), theme.COLOR_WHITE, 0.20);
}

fn drawSecondaryButton(state: *runtime.AppState, rect: palette.Rect, label: []const u8, enabled: bool, clip: palette.Rect) void {
    const hovered = enabled and pointInRect(state.transcript_controller.palette_mouse_x, state.transcript_controller.palette_mouse_y, rect);
    const radius = scaled(7.0);
    roundedRect(state, rect, if (hovered) controlHoverSurface() else controlSurface(), radius, clip);
    border(state, rect, theme.withAlpha(theme.COLOR_WHITE, 30), radius, scaled(1.0), clip);
    centeredLabel(state, rect, label, if (enabled) theme.COLOR_WHITE else theme.COLOR_TEXT_SUBTLE, scaled(BODY_FONT_CSS), clip);
}

fn drawActionButton(state: *runtime.AppState, rect: palette.Rect, label: []const u8, enabled: bool, clip: palette.Rect) void {
    const hovered = enabled and pointInRect(state.transcript_controller.palette_mouse_x, state.transcript_controller.palette_mouse_y, rect);
    const accent = theme.accent();
    const base = if (enabled) accent else theme.mix(controlSurface(), accent, 0.35);
    const fill = if (hovered) theme.mix(base, theme.foregroundOn(base), 0.10) else base;
    roundedRect(state, rect, fill, scaled(7.0), clip);
    centeredLabel(state, rect, label, theme.foregroundOn(fill), scaled(BODY_FONT_CSS), clip);
}

fn centeredLabel(state: *runtime.AppState, rect: palette.Rect, value: []const u8, color: [4]f32, font_size: f32, clip: palette.Rect) void {
    const inner_w = @max(rect.w - scaled(8.0), scaled(4.0));
    var label_buf: [160]u8 = undefined;
    const label = truncatedLabel(&label_buf, value, inner_w, font_size);
    const text_w = @min(text_measure.textWidth(.ui, font_size, label), inner_w);
    const text_h = font_size * 1.25;
    labelText(state, .{
        .x = rect.x + (rect.w - text_w) * 0.5,
        .y = rect.y + (rect.h - text_h) * 0.5,
        .w = text_w + scaled(2.0),
        .h = text_h,
    }, label, color, font_size, .ui, intersect(clip, rect) orelse return);
}

/// Truncates `label` with a trailing ellipsis so it fits `max_w` using
/// Palette text metrics, cutting only at UTF-8 codepoint boundaries.
fn truncatedLabel(buffer: []u8, label: []const u8, max_w: f32, font_size: f32) []const u8 {
    return truncatedLabelRole(buffer, label, max_w, font_size, .ui);
}

fn truncatedLabelRole(buffer: []u8, label: []const u8, max_w: f32, font_size: f32, role: palette.FontRole) []const u8 {
    const ellipsis = "\u{2026}";
    const bounded = label[0..@min(label.len, buffer.len - ellipsis.len)];
    if (bounded.len == label.len and text_measure.textWidth(role, font_size, bounded) <= max_w) return label;
    const ellipsis_w = text_measure.textWidth(role, font_size, ellipsis);
    var end: usize = 0;
    var fit_end: usize = 0;
    while (end < bounded.len) {
        const cp_len = std.unicode.utf8ByteSequenceLength(bounded[end]) catch 1;
        const next = @min(end + cp_len, bounded.len);
        if (text_measure.textPrefixWidth(role, bounded, font_size, next) + ellipsis_w > max_w) break;
        fit_end = next;
        end = next;
    }
    @memcpy(buffer[0..fit_end], bounded[0..fit_end]);
    @memcpy(buffer[fit_end .. fit_end + ellipsis.len], ellipsis);
    return buffer[0 .. fit_end + ellipsis.len];
}

fn labelText(state: *runtime.AppState, rect: palette.Rect, value: []const u8, color: [4]f32, font_size: f32, role: palette.FontRole, clip: palette.Rect) void {
    if (value.len == 0) return;
    const stable_value = state.palette_frame_text_arena.allocator().dupe(u8, value) catch return;
    state.palette_overlay_batch.roleText(
        state.allocator,
        snapRect(rect),
        stable_value,
        paletteColor(color),
        font_size,
        role,
        null,
        clip,
    ) catch |err| {
        log.warn("failed to queue commit sheet text: {s}", .{@errorName(err)});
    };
}

/// Word-wrapped text inside `rect` (for errors and notices), wrapped with
/// measured widths so it matches the glyphs that are drawn.
fn labelWrapped(state: *runtime.AppState, rect: palette.Rect, value: []const u8, color: [4]f32, font_size: f32, clip: palette.Rect) void {
    labelWrappedSpaced(state, rect, value, color, font_size, 1.3, clip);
}

fn labelWrappedSpaced(state: *runtime.AppState, rect: palette.Rect, value: []const u8, color: [4]f32, font_size: f32, spacing: f32, clip: palette.Rect) void {
    if (value.len == 0) return;
    const line_clip = intersect(clip, rect) orelse return;
    var lines: [16]Line = undefined;
    const count = wrapLines(value, font_size, @max(rect.w, font_size), &lines);
    const line_h = font_size * spacing;
    for (lines[0..count], 0..) |line, index| {
        const y = rect.y + @as(f32, @floatFromInt(index)) * line_h;
        if (y >= rect.y + rect.h) break;
        labelText(state, .{ .x = rect.x, .y = y, .w = rect.w + 2.0, .h = font_size * 1.25 }, value[line.start..line.end], color, font_size, .ui, line_clip);
    }
}

fn snapRect(rect: palette.Rect) palette.Rect {
    return .{ .x = @round(rect.x), .y = @round(rect.y), .w = @round(rect.w), .h = @round(rect.h) };
}

fn roundedRect(state: *runtime.AppState, rect: palette.Rect, color: [4]f32, radius: f32, clip: palette.Rect) void {
    state.palette_overlay_batch.roundedRectClipped(state.allocator, rect, paletteColor(color), radius, clip) catch |err| {
        log.warn("failed to queue commit sheet rect: {s}", .{@errorName(err)});
    };
}

fn border(state: *runtime.AppState, rect: palette.Rect, color: [4]f32, radius: f32, width: f32, clip: palette.Rect) void {
    state.palette_overlay_batch.rectBorderClipped(state.allocator, rect, paletteColor(color), radius, width, clip) catch |err| {
        log.warn("failed to queue commit sheet border: {s}", .{@errorName(err)});
    };
}

fn paletteColor(value: [4]f32) palette.Color {
    return .{ .r = value[0], .g = value[1], .b = value[2], .a = value[3] };
}

// ------------------------------------------------------------------
// Tests
// ------------------------------------------------------------------

test "caret on a soft wrap shows at the start of the lower line" {
    const lines = [_]Line{ .{ .start = 0, .end = 6 }, .{ .start = 6, .end = 11 }, .{ .start = 12, .end = 15 } };
    try std.testing.expectEqual(@as(usize, 0), lineForCursor(&lines, 0));
    try std.testing.expectEqual(@as(usize, 1), lineForCursor(&lines, 6));
    // Cursor on the hard newline stays at the end of its line.
    try std.testing.expectEqual(@as(usize, 1), lineForCursor(&lines, 11));
    try std.testing.expectEqual(@as(usize, 2), lineForCursor(&lines, 12));
    try std.testing.expectEqual(@as(usize, 2), lineForCursor(&lines, 15));
}

test "wrap keeps hard newlines and empty lines" {
    var out: [8]Line = undefined;
    const count = wrapLines("Subject\n\nBody", 13.0, 10_000.0, &out);
    try std.testing.expectEqual(@as(usize, 3), count);
    try std.testing.expectEqual(Line{ .start = 0, .end = 7 }, out[0]);
    try std.testing.expectEqual(Line{ .start = 8, .end = 8 }, out[1]);
    try std.testing.expectEqual(Line{ .start = 9, .end = 13 }, out[2]);
    try std.testing.expectEqual(@as(usize, 1), wrapLines("", 13.0, 100.0, &out));
}

test "tabs expand in diff previews" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("+    x", expandTabs(&buf, "+\tx"));
}

test "control ordinals stay stable for hit indices" {
    try std.testing.expectEqual(@as(u8, 0), @intFromEnum(Control.cancel));
    try std.testing.expectEqual(@as(u8, 9), @intFromEnum(Control.confirm_branch));
    try std.testing.expectEqual(@as(u8, 10), @intFromEnum(Control.alternate));
}

fn reviewJson(comptime remote: bool) []const u8 {
    return "{\"review_id\":\"r\",\"workspace_id\":\"w\",\"local_thread_id\":\"t\",\"turn_running\":false," ++
        "\"default_action\":\"commit\",\"repos\":[{\"root\":\"/a\",\"name\":\"a\"}," ++
        "{\"root\":\"/b\",\"name\":\"b\",\"has_remote\":" ++ (if (remote) "true" else "false") ++ "}]}";
}

test "alternate button needs a remote and carries its own progress" {
    const sheet = try std.testing.allocator.create(Sheet);
    defer std.testing.allocator.destroy(sheet);
    sheet.* = .{};
    defer sheet.tick_arena.deinit();
    // No remote anywhere: a Commit sheet offers no Commit & push.
    sheet.review = try std.json.parseFromSlice(git_changes.ReviewResult, std.testing.allocator, reviewJson(false), .{});
    try std.testing.expect(!showsAlternate(sheet));
    // Plain Commit stays available from a Commit & push sheet.
    sheet.mode = .commit_and_push;
    try std.testing.expect(showsAlternate(sheet));
    sheet.review.?.deinit();

    sheet.review = try std.json.parseFromSlice(git_changes.ReviewResult, std.testing.allocator, reviewJson(true), .{});
    defer sheet.review.?.deinit();
    sheet.mode = .commit;
    try std.testing.expect(showsAlternate(sheet));
    try std.testing.expectEqualStrings("Commit", primaryLabel(sheet));
    try std.testing.expectEqualStrings("Commit & push", actionLabel(sheet, sheet.mode.other()));

    // Waiting for the message: only the clicked (alternate) button says so.
    sheet.pending_new_branch = false;
    sheet.pending_action = .commit_and_push;
    try std.testing.expectEqualStrings("Commit", primaryLabel(sheet));
    try std.testing.expectEqualStrings("Writing message\u{2026}", actionLabel(sheet, .commit_and_push));
    try std.testing.expectEqualStrings("Commit on new branch", newBranchLabel(sheet, false));

    // Running: the alternate shows progress, primary and new-branch do not.
    sheet.pending_new_branch = null;
    sheet.busy = .commit_and_push;
    sheet.busy_new_branch = false;
    try std.testing.expectEqualStrings("Commit", primaryLabel(sheet));
    try std.testing.expectEqualStrings(git_changes.Action.commit_and_push.busyLabel(), actionLabel(sheet, .commit_and_push));
    try std.testing.expectEqualStrings("Commit on new branch", newBranchLabel(sheet, false));

    // A new-branch commit keeps its progress on the new-branch button.
    sheet.busy = .commit;
    sheet.busy_new_branch = true;
    try std.testing.expectEqualStrings("Commit", primaryLabel(sheet));
    try std.testing.expectEqualStrings(git_changes.Action.commit.busyLabel(), newBranchLabel(sheet, false));
}
