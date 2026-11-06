//! Provider background tasks in the transcript, as the desktop shows them
//! (desktop `chat/background_tasks.zig`): each task's "Background command" row
//! and its end ("Background task completed/failed/stopped") become one
//! `background_task` row, metadata lines never reach the body, and the Codex
//! background snapshot rows are hidden after marking released tasks completed.
const std = @import("std");
const m = @import("chat_models.zig");

pub const CODEX_SNAPSHOT_AUTHOR = "__verde_codex_background_snapshot";
pub const KIND = "background_task";

pub const Projected = struct { rows: []const m.Row, running: []const m.BackgroundTask };

pub fn statusFor(author: []const u8) ?[]const u8 {
    if (eq(author, "Background command") or eq(author, "Backgrounded command")) return "running";
    if (eq(author, "Background task completed")) return "completed";
    if (eq(author, "Background task failed")) return "failed";
    if (eq(author, "Background task stopped")) return "stopped";
    return null;
}

/// Value of one "Label: value" metadata line.
pub fn metadata(body: []const u8, label: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, "\r\t ");
        if (!std.mem.startsWith(u8, line, label)) continue;
        const value = std.mem.trim(u8, line[label.len..], "\r\t ");
        return if (value.len > 0) value else null;
    }
    return null;
}

/// The command: the body's first paragraph without an "Input:"/"Command:"/"Tool:" label
/// (desktop `commandPreviewFromBody`).
pub fn command(body_raw: []const u8) []const u8 {
    const body = std.mem.trim(u8, body_raw, "\n\r\t ");
    var text = if (std.mem.indexOf(u8, body, "\n\n")) |end| std.mem.trim(u8, body[0..end], "\n\r\t ") else body;
    for ([_][]const u8{ "Input:", "Command:", "Tool:" }) |label| {
        if (std.mem.startsWith(u8, text, label)) {
            text = std.mem.trim(u8, text[label.len..], "\n\r\t ");
            break;
        }
    }
    return text;
}

const Entry = struct { key: []const u8, index: usize, item_id: ?[]const u8, provider_thread_id: ?[]const u8 };

/// Identity in desktop `backgroundCommandBodiesMatch` order: Verde task, Codex item, process, command.
fn identity(a: std.mem.Allocator, body: []const u8) ![]const u8 {
    if (metadata(body, "Verde task ID:")) |id| return std.fmt.allocPrint(a, "t\x1f{s}", .{id});
    const thread = metadata(body, "Provider thread ID:");
    if (metadata(body, "Codex item ID:")) |item| if (thread) |t| return std.fmt.allocPrint(a, "c\x1f{s}\x1f{s}", .{ item, t });
    if (metadata(body, "Process ID:")) |pid| if (thread) |t| return std.fmt.allocPrint(a, "p\x1f{s}\x1f{s}", .{ pid, t });
    return std.fmt.allocPrint(a, "x\x1f{s}", .{command(body)});
}

pub fn project(a: std.mem.Allocator, rows: []const m.Row) std.mem.Allocator.Error!Projected {
    var out: std.ArrayList(m.Row) = .empty;
    var tasks: std.ArrayList(Entry) = .empty;
    for (rows) |row| {
        if (!eq(row.role, "system")) {
            try out.append(a, row);
            continue;
        }
        if (eq(row.author, CODEX_SNAPSHOT_AUTHOR)) {
            applySnapshot(out.items, tasks.items, row);
            continue;
        }
        const status = statusFor(row.author) orelse {
            try out.append(a, row);
            continue;
        };
        const running = eq(status, "running");
        const key = try identity(a, row.body);
        var known: ?*m.Background = null;
        for (tasks.items) |task| if (eq(task.key, key)) {
            known = &out.items[task.index].background.?;
        };
        if (known) |task| {
            // An end wins over a repeated start; a repeated start never revives an ended task.
            if (!running) {
                task.status = status;
                task.finished_at_ms = row.created_at_ms orelse task.finished_at_ms;
            }
            continue;
        }
        const text = command(row.body);
        const first = std.mem.trim(u8, if (std.mem.indexOfScalar(u8, text, '\n')) |end| text[0..end] else text, "\r\t ");
        var merged = row;
        merged.kind = KIND;
        merged.body = text;
        merged.background = .{
            .label = if (first.len > 0) first else "Background command",
            .status = status,
            .task_id = metadata(row.body, "Verde task ID:") orelse metadata(row.body, "Codex item ID:") orelse metadata(row.body, "Process ID:"),
            .started_at_ms = if (running) row.created_at_ms else null,
            .finished_at_ms = if (running) null else row.created_at_ms,
        };
        try tasks.append(a, .{ .key = key, .index = out.items.len, .item_id = metadata(row.body, "Codex item ID:"), .provider_thread_id = metadata(row.body, "Provider thread ID:") });
        try out.append(a, merged);
    }
    var running: std.ArrayList(m.BackgroundTask) = .empty;
    for (tasks.items) |task| {
        const row = out.items[task.index];
        const bg = row.background.?;
        if (!eq(bg.status, "running")) continue;
        try running.append(a, .{ .row_id = row.id, .task_id = bg.task_id, .label = bg.label, .status = bg.status, .started_at_ms = bg.started_at_ms });
    }
    return .{ .rows = out.items, .running = running.items };
}

/// Desktop `applyCodexBackgroundSnapshot`: a running Codex terminal of the snapshot's
/// provider thread that the snapshot no longer lists has been released, so it completed.
fn applySnapshot(rows: []m.Row, tasks: []const Entry, snapshot: m.Row) void {
    const thread = metadata(snapshot.body, "Provider thread ID:") orelse return;
    for (tasks) |task| {
        const item = task.item_id orelse continue;
        const bg = &rows[task.index].background.?;
        if (!eq(bg.status, "running") or task.provider_thread_id == null or !eq(task.provider_thread_id.?, thread)) continue;
        var listed = false;
        var lines = std.mem.splitScalar(u8, snapshot.body, '\n');
        while (lines.next()) |line| {
            const prefix = "Codex item ID:";
            if (std.mem.startsWith(u8, line, prefix) and eq(std.mem.trim(u8, line[prefix.len..], " \t\r"), item)) listed = true;
        }
        if (listed) continue;
        bg.status = "completed";
        bg.finished_at_ms = snapshot.created_at_ms orelse bg.finished_at_ms;
    }
}

fn eq(x: []const u8, y: []const u8) bool {
    return std.mem.eql(u8, x, y);
}
