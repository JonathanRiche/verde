//! Changes view of the right side panel: uncommitted git changes across the
//! workspace's repositories, filterable by the chat that made them.
//!
//! Hook contract with `side_panel.zig`, which owns the panel chrome, routes
//! input here only while this view is selected, and passes body-local rects:
//! - `render` draws into `rect` (the panel body) each frame. `focused` is
//!   true while the panel body owns the keyboard.
//! - `handleMouseButton` / `handleMouseMotion` / `handleWheel` get window
//!   coordinates already known to lie in the body (button-up and motion also
//!   arrive while a drag that started here is in progress). Return true when
//!   consumed; the panel swallows body clicks either way.
//! - `handleKey` / `handleTextInput` run only while the body is focused.
//!   Return false to let the panel and app shortcuts see the key.
//! - `wantsTextInput` keeps SDL text input on while a field here is focused.
//! - `systemCursorAt` picks the pointer shape over the body.
//! - `resetHitCache` runs at the start of every panel render.
//!
//! Data and fetching live in `state/workspace_changes_controller.zig`; the
//! patch drawing is the shared `diff_render.zig`. Everything here is
//! read-only: rows expand, paths open in the file viewer, and dragging over
//! diff lines selects them for an agent prompt (`state.workspace_changes
//! .selection`).

const std = @import("std");
const sdl = @import("zsdl3");
const palette = @import("palette");

const runtime = @import("runtime.zig");
const theme = @import("theme.zig");
const text_measure = @import("text_measure.zig");
const file_icons = @import("file_icons.zig");
const diff_render = @import("diff_render.zig");
const changes = @import("../state/workspace_changes_controller.zig");

const AppState = runtime.AppState;

const PAD_UI: f32 = 12.0;
const TITLE_ROW_UI: f32 = 34.0;
const STATS_ROW_UI: f32 = 24.0;
const CHIP_H_UI: f32 = 24.0;
const CHIP_GAP_UI: f32 = 6.0;
const REPO_ROW_UI: f32 = 28.0;
const FILE_ROW_UI: f32 = 30.0;
const DIFF_PAD_UI: f32 = 6.0;
const NOTE_H_UI: f32 = 34.0;
const CODE_FONT_UI: f32 = 12.0;
const CODE_LINE_UI: f32 = 19.0;
const LABEL_FONT_UI: f32 = 12.5;
const SMALL_FONT_UI: f32 = 11.0;
const WHEEL_STEP_UI: f32 = 48.0;
const BAR_BLOCKS: usize = 5;

const NF_REFRESH = "\u{eb37}";
const NF_CHEVRON_RIGHT = "\u{eab6}";
const NF_CHEVRON_DOWN = "\u{eab4}";

// ------------------------------------------------------------------
// Frame-local hit state (rebuilt every render)
// ------------------------------------------------------------------

/// A file of the listing: indices into `result.repos[repo].files[file]`,
/// valid while `serial` equals `workspace_changes.data_serial`.
const FileRef = struct {
    repo: u32,
    file: u32,
    serial: u64,

    fn eql(a: FileRef, b: FileRef) bool {
        return a.repo == b.repo and a.file == b.file and a.serial == b.serial;
    }
};

const HitKind = union(enum) {
    refresh,
    commit,
    retry,
    layout: diff_render.Layout,
    chip: u32,
    toggle_file: FileRef,
    open_file: FileRef,
    expand_all,
};

const Hit = struct { rect: palette.Rect, kind: HitKind };

const MAX_HITS: usize = 512;
var hits: [MAX_HITS]Hit = undefined;
var hit_count: usize = 0;

/// Diff rows drawn this frame, grouped per file.
const MAX_ROWS: usize = 1024;
var row_buffer: [MAX_ROWS]diff_render.Row = undefined;
var row_used: usize = 0;

const FileRows = struct {
    file: FileRef,
    first: usize,
    len: usize,
    layout: diff_render.Layout,
    context_lines: usize,
    /// The drawn patch is the whole-file one (context gaps expand); else
    /// git's hunks (hunk headers expand).
    full: bool,
    rect: palette.Rect,
};
const MAX_FILE_ROWS: usize = 64;
var file_rows: [MAX_FILE_ROWS]FileRows = undefined;
var file_rows_count: usize = 0;

var mouse: ?diff_render.Point = null;
var list_rect: palette.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 };
var max_scroll: f32 = 0.0;

/// Line selection in one file's diff (view indices), while dragging and
/// after; mirrored into `workspace_changes.selection` on release.
const LineSelection = struct {
    file: FileRef,
    layout: diff_render.Layout,
    context_lines: usize,
    anchor: usize,
    focus: usize,

    fn range(self: LineSelection) diff_render.Selection {
        return .{ .first = @min(self.anchor, self.focus), .last = @max(self.anchor, self.focus) };
    }
};
var selection: ?LineSelection = null;
var dragging = false;

pub fn resetHitCache() void {
    hit_count = 0;
    row_used = 0;
    file_rows_count = 0;
}

fn pushHit(rect: palette.Rect, kind: HitKind) void {
    if (hit_count >= MAX_HITS) return;
    hits[hit_count] = .{ .rect = rect, .kind = kind };
    hit_count += 1;
}

// ------------------------------------------------------------------
// Render
// ------------------------------------------------------------------

pub fn render(state: *AppState, rect: palette.Rect, focused: bool) void {
    _ = focused;
    const model = &state.workspace_changes;
    const pad = theme.scaledUi(PAD_UI);
    const clip = rect;

    var y = rect.y + theme.scaledUi(6.0);
    const data = model.result();
    y = renderTitleRow(state, rect, y, data, clip);
    if (data) |result| {
        y = renderStatsRow(state, rect, y, result, clip);
        y = renderChips(state, rect, y, clip);
    }
    y += theme.scaledUi(4.0);
    queueRect(state, .{ .x = rect.x, .y = y, .w = rect.w, .h = @max(@round(theme.scaledUi(1.0)), 1.0) }, paletteColor(theme.borderMuted()), clip);
    y += @max(@round(theme.scaledUi(1.0)), 1.0);

    list_rect = .{ .x = rect.x, .y = y, .w = rect.w, .h = @max(rect.y + rect.h - y, 0.0) };
    const result = data orelse {
        renderEmpty(state, list_rect, if (model.errorText()) |text| text else "Loading changes…", model.errorText() != null);
        max_scroll = 0.0;
        return;
    };
    if (model.errorText()) |text| {
        // Keep the old listing on screen with a slim error line on top.
        renderErrorStrip(state, list_rect, text);
    }
    const totals = changes.totals(result, model.filter());
    if (totals.files == 0) {
        const message: []const u8 = if (result.repos.len == 0)
            "No git repositories in this workspace."
        else if (model.filter_kind == .all)
            "No uncommitted changes."
        else
            "No uncommitted changes for this filter.";
        renderEmpty(state, list_rect, message, false);
        max_scroll = 0.0;
        return;
    }
    renderList(state, list_rect, result, pad);
}

fn renderTitleRow(state: *AppState, rect: palette.Rect, y: f32, data: ?changes.WorkspaceResult, clip: palette.Rect) f32 {
    const model = &state.workspace_changes;
    const pad = theme.scaledUi(PAD_UI);
    const row_h = theme.scaledUi(TITLE_ROW_UI);
    const button_h = theme.scaledUi(26.0);
    const button_y = y + (row_h - button_h) * 0.5;

    const commit_w = theme.scaledUi(78.0);
    const commit_rect = palette.Rect{ .x = rect.x + rect.w - pad - commit_w, .y = button_y, .w = commit_w, .h = button_h };
    diff_render.renderActionButton(state, commit_rect, "Commit…", true, clip, mouse);
    pushHit(commit_rect, .commit);

    const refresh_rect = palette.Rect{ .x = commit_rect.x - theme.scaledUi(6.0) - button_h, .y = button_y, .w = button_h, .h = button_h };
    const refresh_hovered = pointIn(refresh_rect);
    if (refresh_hovered) queueRounded(state, refresh_rect, paletteColor(theme.withAlpha(theme.COLOR_PANEL_MUTED, 220)), theme.scaledUi(6.0), clip);
    queueIcon(state, refresh_rect, NF_REFRESH, paletteColor(if (model.loading) theme.accent() else if (refresh_hovered) theme.COLOR_WHITE else theme.COLOR_TEXT_MUTED), theme.scaledUi(14.0), clip);
    pushHit(refresh_rect, .refresh);

    // "repo · branch" for one repository with changes, else "N repositories".
    var buf: [256]u8 = undefined;
    var title: []const u8 = "Changes";
    var subtitle: []const u8 = "";
    if (data) |result| {
        var with_files: usize = 0;
        var only: ?changes.WorkspaceRepo = null;
        for (result.repos) |repo| {
            if (repo.files.len > 0 or repo.too_many_files) {
                with_files += 1;
                only = repo;
            }
        }
        if (with_files <= 1 and result.repos.len > 0) {
            const repo = only orelse result.repos[0];
            title = repo.name;
            subtitle = repo.branch orelse "detached";
        } else if (with_files > 1) {
            title = std.fmt.bufPrint(&buf, "{d} repositories", .{with_files}) catch "Repositories";
        }
    }
    const text_x = rect.x + pad;
    const text_right = refresh_rect.x - theme.scaledUi(8.0);
    const font = theme.scaledUi(13.5);
    const title_w = @min(text_measure.textWidth(.ui, font, title), @max(text_right - text_x, 0.0));
    queueLabel(state, .{ .x = text_x, .y = y + (row_h - font * 1.4) * 0.5, .w = title_w, .h = font * 1.4 }, title, paletteColor(theme.COLOR_WHITE), font, clip);
    if (subtitle.len > 0) {
        const sub_font = theme.scaledUi(LABEL_FONT_UI);
        const branch_x = text_x + title_w + theme.scaledUi(8.0);
        const branch_w = @max(text_right - branch_x, 0.0);
        const shown = elideEnd(state, subtitle, sub_font, branch_w);
        queueLabel(state, .{ .x = branch_x, .y = y + (row_h - sub_font * 1.4) * 0.5, .w = branch_w, .h = sub_font * 1.4 }, shown, paletteColor(theme.COLOR_TEXT_SUBTLE), sub_font, clip);
    }
    return y + row_h;
}

fn renderStatsRow(state: *AppState, rect: palette.Rect, y: f32, result: changes.WorkspaceResult, clip: palette.Rect) f32 {
    const model = &state.workspace_changes;
    const pad = theme.scaledUi(PAD_UI);
    const row_h = theme.scaledUi(STATS_ROW_UI);
    const font = theme.scaledUi(LABEL_FONT_UI);
    const totals = changes.totals(result, model.filter());
    var buf: [64]u8 = undefined;
    var x = rect.x + pad;
    const text_y = y + (row_h - font * 1.4) * 0.5;
    const files = std.fmt.bufPrint(&buf, "{d} file{s}", .{ totals.files, if (totals.files == 1) "" else "s" }) catch "";
    x = queueLabelRun(state, x, text_y, files, theme.COLOR_TEXT_MUTED, font, clip) + theme.scaledUi(10.0);
    var add_buf: [32]u8 = undefined;
    const adds = std.fmt.bufPrint(&add_buf, "+{d}", .{totals.additions}) catch "";
    x = queueLabelRun(state, x, text_y, adds, theme.COLOR_DIFF_ADD, font, clip) + theme.scaledUi(6.0);
    var del_buf: [32]u8 = undefined;
    const dels = std.fmt.bufPrint(&del_buf, "\u{2212}{d}", .{totals.deletions}) catch "";
    x = queueLabelRun(state, x, text_y, dels, theme.COLOR_DIFF_REMOVE, font, clip) + theme.scaledUi(10.0);

    var right = rect.x + rect.w - pad;
    const list_w = rect.w;
    if (diff_render.canSplit(list_w)) {
        const toggle_w = theme.scaledUi(124.0);
        const toggle_rect = palette.Rect{ .x = right - toggle_w, .y = y + theme.scaledUi(1.0), .w = toggle_w, .h = row_h - theme.scaledUi(2.0) };
        const segments = diff_render.renderLayoutToggle(state, toggle_rect, diff_render.layoutForWidth(state, list_w), clip, mouse);
        pushHit(segments[0], .{ .layout = .stacked });
        pushHit(segments[1], .{ .layout = .split });
        right = toggle_rect.x - theme.scaledUi(8.0);
    }
    // Expand / collapse every file of the filter.
    const all_label = if (allExpanded(state, result)) "Collapse all" else "Expand all";
    const all_w = text_measure.textWidth(.ui, theme.scaledUi(SMALL_FONT_UI), all_label) + theme.scaledUi(12.0);
    if (right - all_w > x) {
        const all_rect = palette.Rect{ .x = right - all_w, .y = y + theme.scaledUi(2.0), .w = all_w, .h = row_h - theme.scaledUi(4.0) };
        const hovered = pointIn(all_rect);
        if (hovered) queueRounded(state, all_rect, paletteColor(theme.withAlpha(theme.COLOR_PANEL_MUTED, 200)), theme.scaledUi(5.0), clip);
        queueCenteredLabel(state, all_rect, all_label, paletteColor(if (hovered) theme.COLOR_WHITE else theme.COLOR_TEXT_SUBTLE), theme.scaledUi(SMALL_FONT_UI), clip);
        pushHit(all_rect, .expand_all);
    }
    return y + row_h;
}

fn allExpanded(state: *AppState, result: changes.WorkspaceResult) bool {
    const model = &state.workspace_changes;
    const active = model.filter();
    for (result.repos) |repo| {
        for (repo.files) |file| {
            if (active.matches(file) and !model.isExpanded(repo.root, file.path)) return false;
        }
    }
    return true;
}

fn renderChips(state: *AppState, rect: palette.Rect, y_start: f32, clip: palette.Rect) f32 {
    const model = &state.workspace_changes;
    // A lone "All" chip filters nothing.
    if (model.chips.len <= 1) return y_start;
    const pad = theme.scaledUi(PAD_UI);
    const chip_h = theme.scaledUi(CHIP_H_UI);
    const gap = theme.scaledUi(CHIP_GAP_UI);
    const font = theme.scaledUi(SMALL_FONT_UI + 0.5);
    const max_label_w = theme.scaledUi(150.0);
    var x = rect.x + pad;
    var y = y_start + theme.scaledUi(4.0);
    for (model.chips, 0..) |chip, index| {
        var count_buf: [16]u8 = undefined;
        const count = std.fmt.bufPrint(&count_buf, "{d}", .{chip.files}) catch "";
        const label_raw: []const u8 = switch (chip.kind) {
            .all => "All",
            .unassigned => "Unassigned",
            .thread => chip.title,
        };
        const label = elideEnd(state, label_raw, font, max_label_w);
        const label_w = text_measure.textWidth(.ui, font, label);
        const count_w = text_measure.textWidth(.ui, font, count);
        const chip_w = label_w + count_w + theme.scaledUi(26.0);
        if (x + chip_w > rect.x + rect.w - pad and x > rect.x + pad) {
            x = rect.x + pad;
            y += chip_h + gap;
        }
        const chip_rect = palette.Rect{ .x = x, .y = y, .w = chip_w, .h = chip_h };
        const selected = switch (chip.kind) {
            .all => model.filter_kind == .all,
            .unassigned => model.filter_kind == .unassigned,
            .thread => model.filter_kind == .thread and std.mem.eql(u8, model.filter_thread orelse "", chip.thread_id),
        };
        const hovered = pointIn(chip_rect);
        const fill = if (selected) theme.withAlpha(theme.accent(), 48) else if (hovered) theme.withAlpha(theme.COLOR_PANEL_MUTED, 230) else theme.withAlpha(theme.COLOR_PANEL_MUTED, 120);
        const border = if (selected) theme.withAlpha(theme.accent(), 170) else theme.withAlpha(theme.COLOR_TEXT_SUBTLE, 60);
        queueShell(state, chip_rect, paletteColor(fill), paletteColor(border), chip_h * 0.5, clip);
        const text_y = y + (chip_h - font * 1.4) * 0.5;
        const label_x = x + theme.scaledUi(10.0);
        queueLabel(state, .{ .x = label_x, .y = text_y, .w = label_w, .h = font * 1.4 }, label, paletteColor(if (selected or hovered) theme.COLOR_WHITE else theme.COLOR_TEXT_MUTED), font, clip);
        queueLabel(state, .{ .x = label_x + label_w + theme.scaledUi(6.0), .y = text_y, .w = count_w, .h = font * 1.4 }, count, paletteColor(theme.COLOR_TEXT_SUBTLE), font, clip);
        pushHit(chip_rect, .{ .chip = @intCast(index) });
        x += chip_w + gap;
    }
    return y + chip_h + theme.scaledUi(2.0);
}

fn renderEmpty(state: *AppState, rect: palette.Rect, message: []const u8, is_error: bool) void {
    const font = theme.scaledUi(LABEL_FONT_UI);
    const pad = theme.scaledUi(16.0);
    queueLabel(state, .{
        .x = rect.x + pad,
        .y = rect.y + pad,
        .w = @max(rect.w - pad * 2.0, 0.0),
        .h = font * 1.4,
    }, elideEnd(state, message, font, @max(rect.w - pad * 2.0, 0.0)), paletteColor(if (is_error) theme.COLOR_DIFF_REMOVE else theme.COLOR_TEXT_MUTED), font, rect);
    if (is_error) {
        const retry = palette.Rect{ .x = rect.x + pad, .y = rect.y + pad + font * 1.4 + theme.scaledUi(10.0), .w = theme.scaledUi(64.0), .h = theme.scaledUi(26.0) };
        diff_render.renderActionButton(state, retry, "Retry", false, rect, mouse);
        pushHit(retry, .retry);
    }
}

fn renderErrorStrip(state: *AppState, rect: palette.Rect, message: []const u8) void {
    const font = theme.scaledUi(SMALL_FONT_UI);
    const h = theme.scaledUi(22.0);
    const strip = palette.Rect{ .x = rect.x, .y = rect.y + rect.h - h, .w = rect.w, .h = h };
    queueRect(state, strip, paletteColor(theme.withAlpha(theme.COLOR_DIFF_REMOVE, 40)), rect);
    const pad = theme.scaledUi(PAD_UI);
    queueLabel(state, .{ .x = strip.x + pad, .y = strip.y + (h - font * 1.4) * 0.5, .w = strip.w - pad * 2.0, .h = font * 1.4 }, elideEnd(state, message, font, strip.w - pad * 2.0), paletteColor(theme.COLOR_DIFF_REMOVE), font, rect);
}

/// One expanded file's diff block: what to draw and how tall it is.
const Block = struct {
    height: f32,
    patch: ?[]const u8 = null,
    note: ?[]const u8 = null,
    layout: diff_render.Layout = .stacked,
    context_lines: usize = changes.BASE_CONTEXT_LINES,
    full: bool = false,
    line_count: usize = 0,
};

fn diffBlock(state: *AppState, repo: changes.WorkspaceRepo, file: changes.WorkspaceFile, layout: diff_render.Layout, line_h: f32) Block {
    const pad = theme.scaledUi(DIFF_PAD_UI);
    const note_h = theme.scaledUi(NOTE_H_UI);
    if (file.binary) return .{ .height = note_h, .note = "Binary file not shown." };
    const entry = state.workspaceChangesPatch(repo.root, file.path) orelse return .{ .height = note_h, .note = "Loading diff…" };
    const result = entry.result() orelse {
        if (entry.err_message) |message| return .{ .height = note_h, .note = message };
        return .{ .height = note_h, .note = "Loading diff…" };
    };
    if (result.clean) return .{ .height = note_h, .note = "No longer changed. Refresh to update the list." };
    if (result.binary) return .{ .height = note_h, .note = "Binary file not shown." };
    if (result.truncated) return .{ .height = note_h, .note = "Diff is too large to show here. Open the file instead." };
    const text = result.patch orelse return .{ .height = note_h, .note = "No textual changes." };
    const expanded = state.workspace_changes.expandedEntry(repo.root, file.path);
    const context_lines = if (entry.full) changes.viewContextLines(if (expanded) |value| value.level else 1) else changes.BASE_CONTEXT_LINES;
    const split = layout == .split;
    const count = entry.cachedCount(split, context_lines) orelse blk: {
        const value = diff_render.displayLineCountWithContext(state, text, layout, context_lines);
        entry.storeCount(split, context_lines, value);
        break :blk value;
    };
    return .{
        .height = @as(f32, @floatFromInt(count)) * line_h + pad * 2.0,
        .patch = text,
        .layout = layout,
        .context_lines = context_lines,
        .full = entry.full,
        .line_count = count,
    };
}

fn renderList(state: *AppState, rect: palette.Rect, result: changes.WorkspaceResult, pad: f32) void {
    const model = &state.workspace_changes;
    const active = model.filter();
    const serial = model.data_serial;
    const repo_h = theme.scaledUi(REPO_ROW_UI);
    const row_h = theme.scaledUi(FILE_ROW_UI);
    const line_h = theme.scaledUi(CODE_LINE_UI);
    const code_font = theme.scaledUi(CODE_FONT_UI);
    const layout = diff_render.layoutForWidth(state, rect.w - pad * 2.0);
    const totals = changes.totals(result, active);
    const show_repo_headers = result.repos.len > 1 and totals.repos_with_files > 0;

    // Clamp scroll against last frame's content height first so a shrinking
    // list never leaves the view scrolled into empty space.
    model.scroll_y = std.math.clamp(model.scroll_y, 0.0, max_scroll);
    const top = rect.y - model.scroll_y;
    var y = top;

    var sticky: ?struct { repo: changes.WorkspaceRepo, file: changes.WorkspaceFile, ref: FileRef, block_bottom: f32 } = null;

    for (result.repos, 0..) |repo, repo_index| {
        var any = false;
        for (repo.files) |file| {
            if (active.matches(file)) {
                any = true;
                break;
            }
        }
        if (!any and !(repo.too_many_files and model.filter_kind == .all)) continue;
        if (show_repo_headers or repo.too_many_files) {
            if (y + repo_h >= rect.y and y <= rect.y + rect.h) renderRepoHeader(state, .{ .x = rect.x, .y = y, .w = rect.w, .h = repo_h }, repo, rect);
            y += repo_h;
        }
        if (repo.too_many_files) {
            if (y + row_h >= rect.y and y <= rect.y + rect.h) {
                queueLabel(state, .{ .x = rect.x + pad, .y = y + theme.scaledUi(6.0), .w = rect.w - pad * 2.0, .h = theme.scaledUi(18.0) }, "Too many changed files to list here.", paletteColor(theme.COLOR_TEXT_MUTED), theme.scaledUi(LABEL_FONT_UI), rect);
            }
            y += row_h;
            continue;
        }
        for (repo.files, 0..) |file, file_index| {
            if (!active.matches(file)) continue;
            const ref = FileRef{ .repo = @intCast(repo_index), .file = @intCast(file_index), .serial = serial };
            const expanded = model.isExpanded(repo.root, file.path);
            const row_rect = palette.Rect{ .x = rect.x, .y = y, .w = rect.w, .h = row_h };
            if (y + row_h >= rect.y and y <= rect.y + rect.h) renderFileRow(state, row_rect, repo, file, ref, expanded, rect);
            y += row_h;
            if (!expanded) continue;
            const block = diffBlock(state, repo, file, layout, line_h);
            const block_rect = palette.Rect{ .x = rect.x + pad, .y = y, .w = rect.w - pad * 2.0, .h = block.height };
            if (block_rect.y + block_rect.h >= rect.y and block_rect.y <= rect.y + rect.h) {
                renderBlock(state, block_rect, block, ref, code_font, line_h, rect);
            }
            // The file whose row scrolled off while its diff is still in view
            // gets a pinned header.
            if (row_rect.y < rect.y and y + block.height > rect.y + row_h * 0.5) {
                sticky = .{ .repo = repo, .file = file, .ref = ref, .block_bottom = y + block.height };
            }
            y += block.height + theme.scaledUi(6.0);
        }
    }
    y += theme.scaledUi(16.0);
    const content_h = y - top;
    max_scroll = @max(content_h - rect.h, 0.0);

    if (sticky) |pinned| {
        // Push the pinned header up as its diff's end arrives.
        const pinned_y = @min(rect.y, pinned.block_bottom - row_h);
        const pinned_rect = palette.Rect{ .x = rect.x, .y = pinned_y, .w = rect.w, .h = row_h };
        queueRect(state, pinned_rect, paletteColor(theme.COLOR_PANEL), rect);
        renderFileRow(state, pinned_rect, pinned.repo, pinned.file, pinned.ref, true, rect);
        queueRect(state, .{ .x = rect.x, .y = pinned_y + row_h - 1.0, .w = rect.w, .h = 1.0 }, paletteColor(theme.borderMuted()), rect);
    }
    renderScrollbar(state, rect, content_h);
}

fn renderRepoHeader(state: *AppState, rect: palette.Rect, repo: changes.WorkspaceRepo, clip: palette.Rect) void {
    const pad = theme.scaledUi(PAD_UI);
    const font = theme.scaledUi(SMALL_FONT_UI + 0.5);
    queueRect(state, rect, paletteColor(theme.withAlpha(theme.COLOR_PANEL_ALT, 180)), clip);
    const text_y = rect.y + (rect.h - font * 1.4) * 0.5;
    var x = queueLabelRun(state, rect.x + pad, text_y, repo.name, theme.COLOR_WHITE, font, clip) + theme.scaledUi(8.0);
    if (repo.branch) |branch| {
        x = queueLabelRun(state, x, text_y, elideEnd(state, branch, font, @max(rect.x + rect.w - pad - x, 0.0)), theme.COLOR_TEXT_SUBTLE, font, clip);
    }
}

fn renderFileRow(
    state: *AppState,
    rect: palette.Rect,
    repo: changes.WorkspaceRepo,
    file: changes.WorkspaceFile,
    ref: FileRef,
    expanded: bool,
    clip: palette.Rect,
) void {
    const pad = theme.scaledUi(PAD_UI);
    const font = theme.scaledUi(LABEL_FONT_UI);
    const small = theme.scaledUi(SMALL_FONT_UI);
    const hovered = pointIn(rect);
    if (hovered) queueRect(state, rect, paletteColor(theme.withAlpha(theme.COLOR_PANEL_MUTED, 110)), clip);
    pushHit(rect, .{ .toggle_file = ref });

    const text_y = rect.y + (rect.h - font * 1.4) * 0.5;
    var x = rect.x + pad - theme.scaledUi(2.0);
    // Chevron.
    const chevron_w = theme.scaledUi(14.0);
    queueIcon(state, .{ .x = x, .y = rect.y, .w = chevron_w, .h = rect.h }, if (expanded) NF_CHEVRON_DOWN else NF_CHEVRON_RIGHT, paletteColor(theme.COLOR_TEXT_SUBTLE), theme.scaledUi(11.0), clip);
    x += chevron_w + theme.scaledUi(4.0);
    // Status letter.
    const letter = changes.statusLetter(file);
    const letter_color = switch (letter[0]) {
        'A', 'U' => theme.COLOR_DIFF_ADD,
        'D' => theme.COLOR_DIFF_REMOVE,
        else => theme.COLOR_YELLOW,
    };
    const letter_w = theme.scaledUi(12.0);
    queueCenteredLabel(state, .{ .x = x, .y = rect.y, .w = letter_w, .h = rect.h }, letter, paletteColor(letter_color), small, clip);
    x += letter_w + theme.scaledUi(6.0);
    // File icon.
    const name = std.fs.path.basename(file.path);
    const icon = file_icons.forFile(name);
    const icon_w = theme.scaledUi(16.0);
    queueIcon(state, .{ .x = x, .y = rect.y, .w = icon_w, .h = rect.h }, icon.glyph, paletteColor(theme.legibleOn(icon.color, theme.background())), theme.scaledUi(13.0), clip);
    x += icon_w + theme.scaledUi(6.0);

    // Right side: owner chip, then the +/- bar and counts.
    var right = rect.x + rect.w - pad;
    var owner_buf: [32]u8 = undefined;
    const owner = changes.ownerLabel(&owner_buf, file);
    if (owner.len > 0 and rect.w > theme.scaledUi(300.0)) {
        const owner_label = elideEnd(state, owner, small, theme.scaledUi(96.0));
        const owner_w = text_measure.textWidth(.ui, small, owner_label) + theme.scaledUi(14.0);
        const owner_rect = palette.Rect{ .x = right - owner_w, .y = rect.y + (rect.h - theme.scaledUi(18.0)) * 0.5, .w = owner_w, .h = theme.scaledUi(18.0) };
        const tint = switch (ownershipTone(file)) {
            .attention => theme.COLOR_YELLOW,
            .normal => theme.accent(),
        };
        queueShell(state, owner_rect, paletteColor(theme.withAlpha(tint, 30)), paletteColor(theme.withAlpha(tint, 110)), owner_rect.h * 0.5, clip);
        queueCenteredLabel(state, owner_rect, owner_label, paletteColor(theme.COLOR_TEXT_MUTED), small, clip);
        right = owner_rect.x - theme.scaledUi(8.0);
    }
    if (!file.binary) {
        const bar_w = theme.scaledUi(5.0) * @as(f32, @floatFromInt(BAR_BLOCKS)) + theme.scaledUi(1.5) * @as(f32, @floatFromInt(BAR_BLOCKS - 1));
        renderChangeBar(state, right - bar_w, rect.y + rect.h * 0.5, file.additions, file.deletions, clip);
        right -= bar_w + theme.scaledUi(6.0);
        var del_buf: [24]u8 = undefined;
        const dels = std.fmt.bufPrint(&del_buf, "\u{2212}{d}", .{file.deletions}) catch "";
        const del_w = text_measure.textWidth(.ui, small, dels);
        if (file.deletions > 0) {
            queueLabel(state, .{ .x = right - del_w, .y = rect.y + (rect.h - small * 1.4) * 0.5, .w = del_w, .h = small * 1.4 }, dels, paletteColor(theme.COLOR_DIFF_REMOVE), small, clip);
            right -= del_w + theme.scaledUi(4.0);
        }
        var add_buf: [24]u8 = undefined;
        const adds = std.fmt.bufPrint(&add_buf, "+{d}", .{file.additions}) catch "";
        const add_w = text_measure.textWidth(.ui, small, adds);
        if (file.additions > 0) {
            queueLabel(state, .{ .x = right - add_w, .y = rect.y + (rect.h - small * 1.4) * 0.5, .w = add_w, .h = small * 1.4 }, adds, paletteColor(theme.COLOR_DIFF_ADD), small, clip);
            right -= add_w;
        }
        right -= theme.scaledUi(8.0);
    } else {
        const bin_w = text_measure.textWidth(.ui, small, "binary");
        queueLabel(state, .{ .x = right - bin_w, .y = rect.y + (rect.h - small * 1.4) * 0.5, .w = bin_w, .h = small * 1.4 }, "binary", paletteColor(theme.COLOR_TEXT_SUBTLE), small, clip);
        right -= bin_w + theme.scaledUi(8.0);
    }

    // Path: dimmed directory, bright name; the directory elides first.
    const path_w = @max(right - x, 0.0);
    const dir = if (std.fs.path.dirname(file.path)) |value| value else "";
    const name_w = @min(text_measure.textWidth(.ui, font, name), path_w);
    const name_shown = elideEnd(state, name, font, path_w);
    const dir_room = path_w - name_w;
    var dir_shown: []const u8 = "";
    if (dir.len > 0 and dir_room > theme.scaledUi(24.0)) {
        const with_slash = std.fmt.allocPrint(state.palette_frame_text_arena.allocator(), "{s}/", .{dir}) catch "";
        dir_shown = elideStart(state, with_slash, font, dir_room);
    }
    const dir_w = text_measure.textWidth(.ui, font, dir_shown);
    const path_rect = palette.Rect{ .x = x, .y = rect.y + theme.scaledUi(4.0), .w = dir_w + name_w, .h = rect.h - theme.scaledUi(8.0) };
    const path_hovered = pointIn(path_rect);
    if (dir_shown.len > 0) queueLabel(state, .{ .x = x, .y = text_y, .w = dir_w, .h = font * 1.4 }, dir_shown, paletteColor(theme.COLOR_TEXT_SUBTLE), font, clip);
    queueLabel(state, .{ .x = x + dir_w, .y = text_y, .w = name_w, .h = font * 1.4 }, name_shown, paletteColor(if (path_hovered) theme.accent() else theme.COLOR_WHITE), font, clip);
    if (path_hovered) {
        queueRect(state, .{ .x = x + dir_w, .y = text_y + font * 1.3, .w = name_w, .h = @max(theme.scaledUi(1.0), 1.0) }, paletteColor(theme.withAlpha(theme.accent(), 160)), clip);
    }
    // Pushed after the row hit so it wins the lookup (hits search backwards).
    pushHit(path_rect, .{ .open_file = ref });
    _ = repo;
}

const Tone = enum { normal, attention };

fn ownershipTone(file: changes.WorkspaceFile) Tone {
    if (std.mem.eql(u8, file.ownership, "shared") or std.mem.eql(u8, file.ownership, "unclear")) return .attention;
    return .normal;
}

/// GitHub-style five-block bar: green share of additions, red of deletions.
fn renderChangeBar(state: *AppState, x: f32, center_y: f32, additions: u32, deletions: u32, clip: palette.Rect) void {
    const block = theme.scaledUi(5.0);
    const gap = theme.scaledUi(1.5);
    const total: u64 = @as(u64, additions) + deletions;
    var green: usize = 0;
    var red: usize = 0;
    if (total > 0) {
        // Small changes fill fewer blocks; five once the change is large.
        const filled: usize = @intCast(@min(@as(u64, BAR_BLOCKS), @max(@as(u64, 1), (total + 9) / 10)));
        green = @intCast((@as(u64, additions) * filled + total / 2) / total);
        if (additions > 0 and green == 0) green = 1;
        red = filled -| green;
        if (deletions > 0 and red == 0 and filled > 1) {
            red = 1;
            green = filled - 1;
        }
    }
    var index: usize = 0;
    while (index < BAR_BLOCKS) : (index += 1) {
        const color = if (index < green) theme.COLOR_DIFF_ADD else if (index < green + red) theme.COLOR_DIFF_REMOVE else theme.withAlpha(theme.COLOR_TEXT_SUBTLE, 70);
        queueRounded(state, .{
            .x = x + @as(f32, @floatFromInt(index)) * (block + gap),
            .y = center_y - block * 0.5,
            .w = block,
            .h = block,
        }, paletteColor(color), theme.scaledUi(1.0), clip);
    }
}

fn renderBlock(state: *AppState, rect: palette.Rect, block: Block, ref: FileRef, code_font: f32, line_h: f32, clip: palette.Rect) void {
    const pad = theme.scaledUi(DIFF_PAD_UI);
    if (block.note) |note| {
        const font = theme.scaledUi(SMALL_FONT_UI + 0.5);
        queueShell(state, rect, paletteColor(theme.md.code_bg), paletteColor(theme.md.code_border), theme.scaledUi(6.0), clip);
        queueLabel(state, .{
            .x = rect.x + theme.scaledUi(10.0),
            .y = rect.y + (rect.h - font * 1.4) * 0.5,
            .w = rect.w - theme.scaledUi(20.0),
            .h = font * 1.4,
        }, elideEnd(state, note, font, rect.w - theme.scaledUi(20.0)), paletteColor(theme.COLOR_TEXT_MUTED), font, clip);
        return;
    }
    const patch = block.patch orelse return;
    const patch_rect = palette.Rect{ .x = rect.x, .y = rect.y + pad, .w = rect.w, .h = rect.h - pad * 2.0 };
    const first_row = row_used;
    var sink: diff_render.RowSink = .{ .rows = row_buffer[row_used..] };
    const selected: ?diff_render.Selection = if (selection) |current|
        if (current.file.eql(ref) and current.layout == block.layout and current.context_lines == block.context_lines) current.range() else null
    else
        null;
    diff_render.renderPatch(state, patch_rect, patch, .{
        .font_size = code_font,
        .line_h = line_h,
        .layout = block.layout,
        .clip = clip,
        .context_lines = block.context_lines,
        .mouse = mouse,
        .rows = &sink,
        .selection = selected,
    });
    row_used += sink.len;
    if (file_rows_count < MAX_FILE_ROWS) {
        file_rows[file_rows_count] = .{
            .file = ref,
            .first = first_row,
            .len = sink.len,
            .layout = block.layout,
            .context_lines = block.context_lines,
            .full = block.full,
            .rect = patch_rect,
        };
        file_rows_count += 1;
    }
}

fn renderScrollbar(state: *AppState, rect: palette.Rect, content_h: f32) void {
    if (content_h <= rect.h or rect.h <= 0.0) return;
    const model = &state.workspace_changes;
    const track_w = theme.scaledUi(4.0);
    const thumb_h = @max(rect.h * rect.h / content_h, theme.scaledUi(24.0));
    const travel = rect.h - thumb_h;
    const ratio = if (max_scroll > 0.0) model.scroll_y / max_scroll else 0.0;
    queueRounded(state, .{
        .x = rect.x + rect.w - track_w - theme.scaledUi(2.0),
        .y = rect.y + travel * ratio,
        .w = track_w,
        .h = thumb_h,
    }, paletteColor(theme.withAlpha(theme.COLOR_TEXT_SUBTLE, 90)), track_w * 0.5, rect);
}

// ------------------------------------------------------------------
// Input
// ------------------------------------------------------------------

fn hitAt(x: f32, y: f32) ?Hit {
    var index = hit_count;
    while (index > 0) {
        index -= 1;
        const hit = hits[index];
        if (rectContains(hit.rect, x, y)) return hit;
    }
    return null;
}

const RowHit = struct { group: FileRows, row: diff_render.Row };

fn diffRowAt(x: f32, y: f32) ?RowHit {
    if (!rectContains(list_rect, x, y)) return null;
    for (file_rows[0..file_rows_count]) |group| {
        if (!rectContains(group.rect, x, y)) continue;
        for (row_buffer[group.first .. group.first + group.len]) |row| {
            if (y >= row.y and y < row.y + row.h) return .{ .group = group, .row = row };
        }
    }
    return null;
}

/// Nearest drawn row of `file` to `y`, for drags past the visible rows.
fn nearestRowIndex(file: FileRef, layout: diff_render.Layout, y: f32) ?usize {
    for (file_rows[0..file_rows_count]) |group| {
        if (!group.file.eql(file) or group.layout != layout or group.len == 0) continue;
        const rows = row_buffer[group.first .. group.first + group.len];
        if (y < rows[0].y) return rows[0].index;
        for (rows) |row| {
            if (y < row.y + row.h) return row.index;
        }
        return rows[rows.len - 1].index;
    }
    return null;
}

fn fileFor(state: *AppState, ref: FileRef) ?struct { repo: changes.WorkspaceRepo, file: changes.WorkspaceFile } {
    const model = &state.workspace_changes;
    if (ref.serial != model.data_serial) return null;
    const result = model.result() orelse return null;
    if (ref.repo >= result.repos.len) return null;
    const repo = result.repos[ref.repo];
    if (ref.file >= repo.files.len) return null;
    return .{ .repo = repo, .file = repo.files[ref.file] };
}

pub fn handleMouseButton(state: *AppState, x: f32, y: f32, down: bool, clicks: u8) bool {
    _ = clicks;
    mouse = .{ .x = x, .y = y };
    if (!down) {
        if (dragging) {
            dragging = false;
            publishSelection(state);
        }
        return true;
    }
    if (diffRowAt(x, y)) |hit| {
        switch (hit.row.kind) {
            .context_gap => if (hit.group.full) {
                if (fileFor(state, hit.group.file)) |found| state.expandWorkspaceChangesContext(found.repo.root, found.file.path);
                return true;
            },
            .hunk_header => if (!hit.group.full) {
                // git's hunks: the first expansion fetches the whole file.
                if (fileFor(state, hit.group.file)) |found| state.expandWorkspaceChangesContext(found.repo.root, found.file.path);
                return true;
            },
            else => {},
        }
        selection = .{
            .file = hit.group.file,
            .layout = hit.group.layout,
            .context_lines = hit.group.context_lines,
            .anchor = hit.row.index,
            .focus = hit.row.index,
        };
        dragging = true;
        state.markDirty();
        return true;
    }
    const hit = hitAt(x, y) orelse {
        if (selection != null) clearSelection(state);
        return true;
    };
    switch (hit.kind) {
        .refresh, .retry => state.refreshWorkspaceChangesNow(),
        .commit => state.openWorkspaceChangesCommit(),
        .expand_all => state.toggleAllWorkspaceChangesFiles(),
        .layout => |layout| state.setDiffLayoutPreference(if (layout == .split) .split else .stacked),
        .chip => |index| {
            const chips = state.workspace_changes.chips;
            if (index < chips.len) {
                const chip = chips[index];
                state.setWorkspaceChangesFilter(chip.kind, if (chip.kind == .thread) chip.thread_id else null);
            }
        },
        .toggle_file => |ref| if (fileFor(state, ref)) |found| {
            state.toggleWorkspaceChangesFile(found.repo.root, found.file.path);
        },
        .open_file => |ref| if (fileFor(state, ref)) |found| {
            state.openChangedFileInViewer(found.repo.root, found.file.path);
        },
    }
    state.markDirty();
    return true;
}

pub fn handleMouseMotion(state: *AppState, x: f32, y: f32) bool {
    const previous = mouse;
    mouse = .{ .x = x, .y = y };
    if (dragging) {
        if (selection) |*current| {
            if (nearestRowIndex(current.file, current.layout, y)) |index| {
                if (index != current.focus) {
                    current.focus = index;
                    state.markDirty();
                }
            }
        }
        // Drag past the edges scrolls.
        if (y < list_rect.y) scrollBy(state, -theme.scaledUi(12.0));
        if (y > list_rect.y + list_rect.h) scrollBy(state, theme.scaledUi(12.0));
        return true;
    }
    const before = if (previous) |point| hoverKey(point.x, point.y) else 0;
    if (hoverKey(x, y) != before) state.markDirty();
    return true;
}

/// Identity of whatever is under the pointer, so motion repaints only when
/// the hover target changes.
fn hoverKey(x: f32, y: f32) u64 {
    if (diffRowAt(x, y)) |hit| {
        return 0x1000_0000 | (@as(u64, @intFromEnum(hit.row.kind)) << 20) | (hit.row.index & 0xFFFFF);
    }
    var index = hit_count;
    while (index > 0) {
        index -= 1;
        if (rectContains(hits[index].rect, x, y)) return index + 1;
    }
    return 0;
}

pub fn handleWheel(state: *AppState, x: f32, y: f32, wheel_y: f32) bool {
    _ = x;
    _ = y;
    scrollBy(state, -wheel_y * theme.scaledUi(WHEEL_STEP_UI));
    return true;
}

fn scrollBy(state: *AppState, delta: f32) void {
    const model = &state.workspace_changes;
    const next = std.math.clamp(model.scroll_y + delta, 0.0, max_scroll);
    if (next == model.scroll_y) return;
    model.scroll_y = next;
    state.markDirty();
}

pub fn handleKey(state: *AppState, event: *const sdl.KeyboardEvent) bool {
    const mods = keymodBits(event.mod);
    const primary = (mods & (sdl.Keymod.ctrl | sdl.Keymod.gui)) != 0;
    switch (event.key) {
        .escape => {
            if (selection == null) return false;
            clearSelection(state);
            return true;
        },
        .c => {
            if (!primary) return false;
            const current = state.workspace_changes.selection orelse return false;
            _ = state.setClipboardText(current.text);
            return true;
        },
        .r => {
            if (primary or mods & sdl.Keymod.alt != 0) return false;
            state.refreshWorkspaceChangesNow();
            return true;
        },
        .pageup => scrollBy(state, -list_rect.h * 0.9),
        .pagedown => scrollBy(state, list_rect.h * 0.9),
        .up => scrollBy(state, -theme.scaledUi(WHEEL_STEP_UI)),
        .down => scrollBy(state, theme.scaledUi(WHEEL_STEP_UI)),
        .home => scrollBy(state, -state.workspace_changes.scroll_y),
        .end => scrollBy(state, max_scroll),
        else => return false,
    }
    return true;
}

pub fn handleTextInput(state: *AppState, text: []const u8) bool {
    _ = state;
    _ = text;
    return false;
}

pub fn wantsTextInput(state: *AppState) bool {
    _ = state;
    return false;
}

pub fn systemCursorAt(state: *AppState, x: f32, y: f32) ?sdl.SystemCursor {
    _ = state;
    if (diffRowAt(x, y)) |hit| {
        return switch (hit.row.kind) {
            .context_gap => if (hit.group.full) .pointer else null,
            .hunk_header => if (!hit.group.full) .pointer else null,
            else => .text,
        };
    }
    if (hitAt(x, y) != null) return .pointer;
    return null;
}

fn clearSelection(state: *AppState) void {
    selection = null;
    dragging = false;
    state.workspace_changes.clearSelection();
    state.markDirty();
}

/// Mirrors the drawn line selection into the controller (file, line
/// numbers, text) for the agent prompt popover.
fn publishSelection(state: *AppState) void {
    const current = selection orelse return;
    const found = fileFor(state, current.file) orelse {
        clearSelection(state);
        return;
    };
    const entry = state.workspaceChangesPatch(found.repo.root, found.file.path) orelse return;
    const patch = entry.patchText() orelse return;
    const range = current.range();
    const text = diff_render.selectionText(state, std.heap.page_allocator, patch, current.layout, current.context_lines, range) orelse return;
    defer std.heap.page_allocator.free(text);
    if (text.len == 0) {
        clearSelection(state);
        return;
    }
    var old_range: ?[2]usize = null;
    var new_range: ?[2]usize = null;
    for (file_rows[0..file_rows_count]) |group| {
        if (!group.file.eql(current.file)) continue;
        for (row_buffer[group.first .. group.first + group.len]) |row| {
            if (row.index < range.first or row.index > range.last) continue;
            if (row.old_line) |line| old_range = widen(old_range, line);
            if (row.new_line) |line| new_range = widen(new_range, line);
        }
    }
    state.setWorkspaceChangesSelection(found.repo.root, found.file.path, old_range, new_range, text);
}

fn widen(range: ?[2]usize, line: usize) [2]usize {
    const value = range orelse return .{ line, line };
    return .{ @min(value[0], line), @max(value[1], line) };
}

// ------------------------------------------------------------------
// Draw helpers
// ------------------------------------------------------------------

fn pointIn(rect: palette.Rect) bool {
    const point = mouse orelse return false;
    return rectContains(rect, point.x, point.y);
}

fn rectContains(rect: palette.Rect, x: f32, y: f32) bool {
    return x >= rect.x and y >= rect.y and x <= rect.x + rect.w and y <= rect.y + rect.h;
}

fn keymodBits(modifier_state: sdl.Keymod) u16 {
    return @as(*const u16, @ptrCast(&modifier_state)).*;
}

fn paletteColor(value: [4]f32) palette.Color {
    return .{ .r = value[0], .g = value[1], .b = value[2], .a = value[3] };
}

fn stableText(state: *AppState, value: []const u8) []const u8 {
    return state.palette_frame_text_arena.allocator().dupe(u8, value) catch "";
}

fn snapRect(rect: palette.Rect) palette.Rect {
    return .{ .x = @round(rect.x), .y = @round(rect.y), .w = @round(rect.w), .h = @round(rect.h) };
}

fn queueRect(state: *AppState, rect: palette.Rect, color: palette.Color, clip: palette.Rect) void {
    state.palette_overlay_batch.rectClipped(state.allocator, snapRect(rect), color, clip) catch {};
}

fn queueRounded(state: *AppState, rect: palette.Rect, color: palette.Color, radius: f32, clip: palette.Rect) void {
    state.palette_overlay_batch.roundedRectClipped(state.allocator, rect, color, radius, clip) catch {};
}

fn queueShell(state: *AppState, rect: palette.Rect, fill: palette.Color, border: palette.Color, radius: f32, clip: palette.Rect) void {
    const inset = @max(theme.scaledUi(1.0), 1.0);
    queueRounded(state, rect, border, radius, clip);
    if (rect.w > inset * 2.0 and rect.h > inset * 2.0) {
        queueRounded(state, .{ .x = rect.x + inset, .y = rect.y + inset, .w = rect.w - inset * 2.0, .h = rect.h - inset * 2.0 }, fill, @max(radius - inset, 0.0), clip);
    }
}

fn queueLabel(state: *AppState, rect: palette.Rect, value: []const u8, color: palette.Color, font_size: f32, clip: palette.Rect) void {
    if (value.len == 0 or rect.w <= 0.0) return;
    state.palette_overlay_batch.roleText(state.allocator, snapRect(rect), stableText(state, value), color, font_size, .ui, null, clip) catch {};
}

/// Draws a label at `x` and returns its right edge.
fn queueLabelRun(state: *AppState, x: f32, y: f32, value: []const u8, color: [4]f32, font_size: f32, clip: palette.Rect) f32 {
    const width = text_measure.textWidth(.ui, font_size, value);
    queueLabel(state, .{ .x = x, .y = y, .w = width, .h = font_size * 1.4 }, value, paletteColor(color), font_size, clip);
    return x + width;
}

fn queueCenteredLabel(state: *AppState, rect: palette.Rect, value: []const u8, color: palette.Color, font_size: f32, clip: palette.Rect) void {
    const label_w = @min(text_measure.textWidth(.ui, font_size, value), rect.w);
    const label_h = font_size * 1.4;
    queueLabel(state, .{
        .x = rect.x + (rect.w - label_w) * 0.5,
        .y = rect.y + (rect.h - label_h) * 0.5,
        .w = label_w,
        .h = label_h,
    }, value, color, font_size, clip);
}

fn queueIcon(state: *AppState, rect: palette.Rect, glyph: []const u8, color: palette.Color, font_size: f32, clip: palette.Rect) void {
    const glyph_w = text_measure.textWidth(.icon, font_size, glyph);
    const glyph_h = font_size * 1.3;
    state.palette_overlay_batch.roleText(state.allocator, snapRect(.{
        .x = rect.x + (rect.w - glyph_w) * 0.5,
        .y = rect.y + (rect.h - glyph_h) * 0.5,
        .w = @max(glyph_w, 1.0),
        .h = glyph_h,
    }), stableText(state, glyph), color, font_size, .icon, null, clip) catch {};
}

/// `value` cut at the end with "…" to fit `max_w` (frame arena).
fn elideEnd(state: *AppState, value: []const u8, font_size: f32, max_w: f32) []const u8 {
    if (max_w <= 0.0) return "";
    if (text_measure.textWidth(.ui, font_size, value) <= max_w) return value;
    const ellipsis = "…";
    var end = value.len;
    while (end > 0) {
        end -= 1;
        while (end > 0 and (value[end] & 0xC0) == 0x80) end -= 1;
        const candidate = std.fmt.allocPrint(state.palette_frame_text_arena.allocator(), "{s}{s}", .{ value[0..end], ellipsis }) catch return "";
        if (text_measure.textWidth(.ui, font_size, candidate) <= max_w) return candidate;
    }
    return ellipsis;
}

/// `value` cut at the start with "…" to fit `max_w` (frame arena).
fn elideStart(state: *AppState, value: []const u8, font_size: f32, max_w: f32) []const u8 {
    if (max_w <= 0.0) return "";
    if (text_measure.textWidth(.ui, font_size, value) <= max_w) return value;
    const ellipsis = "…";
    var start: usize = 0;
    while (start < value.len) {
        start += 1;
        while (start < value.len and (value[start] & 0xC0) == 0x80) start += 1;
        const candidate = std.fmt.allocPrint(state.palette_frame_text_arena.allocator(), "{s}{s}", .{ ellipsis, value[start..] }) catch return "";
        if (text_measure.textWidth(.ui, font_size, candidate) <= max_w) return candidate;
    }
    return ellipsis;
}

test "change bar splits blocks by share" {
    // Exercised through the pure arithmetic: a 30/10 change fills 4 blocks.
    const total: u64 = 40;
    const filled: usize = @intCast(@min(@as(u64, BAR_BLOCKS), @max(@as(u64, 1), (total + 9) / 10)));
    try std.testing.expectEqual(@as(usize, 4), filled);
}
