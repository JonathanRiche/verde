//! Pure conversion of streamed chat events into durable transcript rows.
//!
//! This module intentionally has no desktop state, Palette, or SDL dependency.
//! Its ordering and merge rules mirror the GUI's pending timeline reducer so a
//! daemon commit can produce the same transcript as the live desktop.

const std = @import("std");
const headless = @import("headless");
const store_protocol = headless.store_protocol;

pub const ChatEvent = struct {
    kind: []const u8,
    payload_json: []const u8,
};

pub const Event = ChatEvent;

pub const WorkerStatus = enum {
    completed,
    failed,
    aborted,
    interrupted,
};

pub const WorkerOutcome = struct {
    status: WorkerStatus,
    provider: []const u8 = "",
    reply_text: []const u8 = "",
    failure_message: ?[]const u8 = null,
    /// Compatibility spelling for worker implementations that call this an error.
    error_message: ?[]const u8 = null,
    followup_pending: bool = false,
    local_command: bool = false,
};

pub const Outcome = WorkerOutcome;
pub const FinalWorkerOutcome = WorkerOutcome;

const Row = struct {
    message: store_protocol.Message,
    tool_title: ?[]u8 = null,
    tool_input: ?[]u8 = null,
    tool_output: ?[]u8 = null,
    tool_error: ?[]u8 = null,
    tool_locations: ?[]u8 = null,
    tool_raw: ?[]u8 = null,
};

const DiffFile = struct {
    path: []u8,
    additions: i64,
    deletions: i64,
    patch: ?[]u8,
};

const ParsedObject = struct {
    parsed: std.json.Parsed(std.json.Value),

    fn object(self: *const ParsedObject) !std.json.ObjectMap {
        if (self.parsed.value != .object) return error.InvalidDaemonResponse;
        return self.parsed.value.object;
    }
};

/// Apply an ordered stream and its terminal worker outcome into owned store rows.
pub fn apply(
    allocator: std.mem.Allocator,
    events: []const ChatEvent,
    outcome: WorkerOutcome,
) ![]store_protocol.Message {
    var rows: std.ArrayListUnmanaged(Row) = .empty;
    defer freeRows(allocator, &rows);
    var diff_files: std.ArrayListUnmanaged(DiffFile) = .empty;
    defer freeDiffFiles(allocator, &diff_files);
    var diff_has_turn_snapshot = false;
    var partial_text: std.ArrayListUnmanaged(u8) = .empty;
    defer partial_text.deinit(allocator);

    for (events) |event| {
        if (std.mem.eql(u8, event.kind, "assistant_delta")) {
            var payload = try parseObject(allocator, event.payload_json);
            defer payload.parsed.deinit();
            const object = try payload.object();
            const text = jsonString(object, "text") orelse continue;
            try partial_text.appendSlice(allocator, text);
        } else if (std.mem.eql(u8, event.kind, "message") or std.mem.eql(u8, event.kind, "steer")) {
            try flushAssistant(allocator, &rows, &partial_text, outcome.provider);
            try appendMessageEvent(allocator, &rows, event.payload_json);
        } else if (std.mem.eql(u8, event.kind, "tool_call")) {
            var payload = try parseObject(allocator, event.payload_json);
            defer payload.parsed.deinit();
            const object = try payload.object();
            const update = ToolUpdate.fromJson(object);
            // Content-less think events only toggle the GUI's liveness label.
            if (update.isTransientThink()) continue;
            try flushAssistant(allocator, &rows, &partial_text, outcome.provider);
            try upsertTool(allocator, &rows, update);
        } else if (std.mem.eql(u8, event.kind, "diff")) {
            try applyDiffEvent(
                allocator,
                &rows,
                &diff_files,
                &diff_has_turn_snapshot,
                event.payload_json,
                &partial_text,
                outcome.provider,
            );
        }
        // thread_id, turn_id, and unknown event kinds carry turn metadata, not
        // transcript rows, so they intentionally do not affect ordering.
    }

    try flushAssistant(allocator, &rows, &partial_text, outcome.provider);
    cancelLingeringTools(allocator, &rows);

    switch (outcome.status) {
        .completed => {
            if (!containsAssistant(rows.items) and visibleText(outcome.reply_text)) {
                _ = try appendOwnedRow(allocator, &rows, "assistant", providerLabel(outcome.provider), outcome.reply_text, null);
            }
        },
        .failed => {
            const failure = outcome.failure_message orelse outcome.error_message orelse "Provider request failed.";
            _ = try appendOwnedRow(allocator, &rows, "system", "System", failure, null);
        },
        .aborted, .interrupted => {
            if (!outcome.local_command and !outcome.followup_pending) {
                _ = try appendOwnedRow(
                    allocator,
                    &rows,
                    "system",
                    "Conversation interrupted",
                    "Tell the model what to do differently.",
                    null,
                );
            } else if (outcome.local_command and rows.items.len == 0) {
                _ = try appendOwnedRow(
                    allocator,
                    &rows,
                    "system",
                    "Command cancelled",
                    "The workspace command was cancelled before it completed.",
                    null,
                );
            }
        },
    }

    const result = try allocator.alloc(store_protocol.Message, rows.items.len);
    var detached: usize = 0;
    errdefer {
        for (result[0..detached]) |*message| freeMessage(allocator, message);
        allocator.free(result);
    }
    for (rows.items, 0..) |*row, index| {
        result[index] = row.message;
        row.message = undefined;
        freeToolMetadata(allocator, row);
        detached += 1;
    }
    rows.clearRetainingCapacity();
    return result;
}

/// Alias used by callers that prefer the operation's verb in its name.
pub fn applyEvents(
    allocator: std.mem.Allocator,
    events: []const ChatEvent,
    outcome: WorkerOutcome,
) ![]store_protocol.Message {
    return apply(allocator, events, outcome);
}

/// Release rows returned by `apply`.
pub fn freeMessages(allocator: std.mem.Allocator, messages: []store_protocol.Message) void {
    for (messages) |*message| freeMessage(allocator, message);
    allocator.free(messages);
}

const ToolUpdate = struct {
    call_id: []const u8 = "",
    title: []const u8 = "",
    kind: ?[]const u8 = null,
    status: ?[]const u8 = null,
    input: ?[]const u8 = null,
    output: ?[]const u8 = null,
    error_text: ?[]const u8 = null,
    locations: ?[]const u8 = null,
    raw: ?[]const u8 = null,

    fn fromJson(object: std.json.ObjectMap) ToolUpdate {
        return .{
            .call_id = jsonString(object, "call_id") orelse "",
            .title = jsonString(object, "title") orelse "",
            .kind = canonicalKind(jsonString(object, "kind")),
            .status = canonicalStatus(jsonString(object, "status")),
            .input = jsonString(object, "input"),
            .output = jsonString(object, "output"),
            .error_text = jsonString(object, "error_text"),
            .locations = jsonString(object, "locations"),
            .raw = jsonString(object, "raw"),
        };
    }

    fn isTransientThink(self: ToolUpdate) bool {
        if (self.kind == null or !std.mem.eql(u8, self.kind.?, "think")) return false;
        if (hasToolContent(self.input, self.output, self.error_text)) return false;
        const status = self.status orelse return false;
        return std.mem.eql(u8, status, "pending") or std.mem.eql(u8, status, "in_progress");
    }

    fn isTerminalThink(self: ToolUpdate) bool {
        if (self.kind == null or !std.mem.eql(u8, self.kind.?, "think")) return false;
        const status = self.status orelse return false;
        return (std.mem.eql(u8, status, "completed") or
            std.mem.eql(u8, status, "failed") or
            std.mem.eql(u8, status, "cancelled")) and
            !hasToolContent(self.input, self.output, self.error_text);
    }
};

fn parseObject(allocator: std.mem.Allocator, bytes: []const u8) !ParsedObject {
    return .{ .parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) };
}

fn jsonString(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    return if (value == .string) value.string else null;
}

fn jsonInteger(object: std.json.ObjectMap, key: []const u8) i64 {
    const value = object.get(key) orelse return 0;
    return if (value == .integer) value.integer else 0;
}

fn visibleText(value: []const u8) bool {
    return std.mem.trim(u8, value, &std.ascii.whitespace).len > 0;
}

fn hasToolContent(input: ?[]const u8, output: ?[]const u8, error_text: ?[]const u8) bool {
    return (input != null and visibleText(input.?)) or
        (output != null and visibleText(output.?)) or
        (error_text != null and visibleText(error_text.?));
}

fn canonicalKind(value: ?[]const u8) ?[]const u8 {
    const text = value orelse return null;
    const known = [_][]const u8{ "read", "edit", "delete", "move", "search", "execute", "think", "fetch", "mcp", "subagent" };
    for (known) |item| if (std.mem.eql(u8, text, item)) return item;
    return "other";
}

fn canonicalStatus(value: ?[]const u8) ?[]const u8 {
    const text = value orelse return null;
    const known = [_][]const u8{ "pending", "in_progress", "completed", "failed", "cancelled" };
    for (known) |item| if (std.mem.eql(u8, text, item)) return item;
    return "unknown";
}

fn providerLabel(provider: []const u8) []const u8 {
    if (std.ascii.eqlIgnoreCase(provider, "opencode") or std.mem.eql(u8, provider, "OpenCode")) return "OpenCode";
    if (std.ascii.eqlIgnoreCase(provider, "codex") or std.mem.eql(u8, provider, "Codex")) return "Codex";
    if (std.ascii.eqlIgnoreCase(provider, "claude") or std.mem.eql(u8, provider, "Claude")) return "Claude";
    if (std.ascii.eqlIgnoreCase(provider, "cursor") or std.mem.eql(u8, provider, "Cursor")) return "Cursor";
    if (std.ascii.eqlIgnoreCase(provider, "pi") or std.mem.eql(u8, provider, "Pi")) return "Pi";
    if (std.ascii.eqlIgnoreCase(provider, "fx") or std.mem.eql(u8, provider, "FX")) return "FX";
    if (std.ascii.eqlIgnoreCase(provider, "grok") or std.mem.eql(u8, provider, "Grok")) return "Grok";
    if (std.ascii.eqlIgnoreCase(provider, "muse") or std.mem.eql(u8, provider, "Muse")) return "Muse";
    return if (provider.len == 0) "System" else provider;
}

fn flushAssistant(
    allocator: std.mem.Allocator,
    rows: *std.ArrayListUnmanaged(Row),
    partial_text: *std.ArrayListUnmanaged(u8),
    provider: []const u8,
) !void {
    if (partial_text.items.len == 0) return;
    if (!visibleText(partial_text.items)) {
        partial_text.clearRetainingCapacity();
        return;
    }
    _ = try appendOwnedRow(allocator, rows, "assistant", providerLabel(provider), partial_text.items, null);
    partial_text.clearRetainingCapacity();
}

fn appendMessageEvent(
    allocator: std.mem.Allocator,
    rows: *std.ArrayListUnmanaged(Row),
    payload_json: []const u8,
) !void {
    var payload = try parseObject(allocator, payload_json);
    defer payload.parsed.deinit();
    const object = try payload.object();
    const title = jsonString(object, "title") orelse "System";
    const body = jsonString(object, "body") orelse "";
    const index = try appendOwnedRow(allocator, rows, "system", title, body, object.get("message_id"));
    errdefer {
        freeRow(allocator, &rows.items[index]);
        _ = rows.orderedRemove(index);
    }
    try copyMessageAttachments(allocator, &rows.items[index].message, object);
}

fn appendOwnedRow(
    allocator: std.mem.Allocator,
    rows: *std.ArrayListUnmanaged(Row),
    role: []const u8,
    author: []const u8,
    body: []const u8,
    message_id_value: ?std.json.Value,
) !usize {
    var row: Row = .{
        .message = .{
            .message_id = "",
            .role = role,
            .author = try allocator.dupe(u8, author),
            .body = undefined,
        },
    };
    errdefer freeRow(allocator, &row);
    row.message.body = try allocator.dupe(u8, body);
    if (message_id_value) |value| if (value == .string and value.string.len > 0) {
        row.message.message_id = try allocator.dupe(u8, value.string);
    };
    try rows.append(allocator, row);
    return rows.items.len - 1;
}

fn copyMessageAttachments(
    allocator: std.mem.Allocator,
    message: *store_protocol.Message,
    object: std.json.ObjectMap,
) !void {
    if (object.get("images")) |value| if (value == .array) {
        var images = try allocator.alloc(store_protocol.Attachment, value.array.items.len);
        var count: usize = 0;
        errdefer {
            for (images[0..count]) |*image| freeAttachment(allocator, image);
            allocator.free(images);
        }
        for (value.array.items) |image_value| {
            images[count] = try copyAttachment(allocator, image_value);
            count += 1;
        }
        message.images = images;
    };
    if (object.get("image")) |value| if (value != .null) {
        message.image = try copyAttachment(allocator, value);
    };
}

fn copyAttachment(allocator: std.mem.Allocator, value: std.json.Value) !store_protocol.Attachment {
    if (value != .object) return error.InvalidDaemonResponse;
    const path = jsonString(value.object, "path") orelse "";
    const mime = jsonString(value.object, "mime") orelse "";
    return .{
        .path = try allocator.dupe(u8, path),
        .mime = try allocator.dupe(u8, mime),
        .byte_size = if (jsonInteger(value.object, "byte_size") > 0) @intCast(jsonInteger(value.object, "byte_size")) else 0,
        .attachment_id = if (jsonString(value.object, "attachment_id")) |id| try allocator.dupe(u8, id) else null,
    };
}

fn upsertTool(
    allocator: std.mem.Allocator,
    rows: *std.ArrayListUnmanaged(Row),
    update: ToolUpdate,
) !void {
    if (update.call_id.len > 0) {
        for (rows.items, 0..) |*row, index| {
            const existing_id = row.message.tool_call_id orelse continue;
            if (!std.mem.eql(u8, existing_id, update.call_id)) continue;
            try mergeTool(allocator, row, update);
            if (isTerminalThinkRow(row)) {
                freeRow(allocator, &row.*);
                _ = rows.orderedRemove(index);
            }
            return;
        }
    }
    if (update.isTerminalThink()) return;

    const kind = update.kind orelse "other";
    const status = update.status orelse "unknown";
    const title = if (visibleText(update.title)) update.title else toolDefaultTitle(kind, status);
    const author = toolDisplayAuthor(kind, status);
    const body = try toolBodyAlloc(allocator, update, title, author);
    defer allocator.free(body);
    const index = try appendOwnedRow(allocator, rows, "system", author, body, null);
    errdefer {
        freeRow(allocator, &rows.items[index]);
        _ = rows.orderedRemove(index);
    }
    const row = &rows.items[index];
    row.message.tool_call_id = if (update.call_id.len > 0) try allocator.dupe(u8, update.call_id) else null;
    row.message.tool_call_kind = try allocator.dupe(u8, kind);
    row.message.tool_call_status = try allocator.dupe(u8, status);
    row.tool_title = if (visibleText(update.title)) try allocator.dupe(u8, update.title) else null;
    row.tool_input = try dupeOptional(allocator, update.input);
    row.tool_output = try dupeOptional(allocator, update.output);
    row.tool_error = try dupeOptional(allocator, update.error_text);
    row.tool_locations = try dupeOptional(allocator, update.locations);
    row.tool_raw = try dupeOptional(allocator, update.raw);
}

fn mergeTool(allocator: std.mem.Allocator, row: *Row, update: ToolUpdate) !void {
    if (visibleText(update.title)) try replaceOptional(allocator, &row.tool_title, update.title);
    if (update.input) |value| try replaceOptional(allocator, &row.tool_input, value);
    if (update.output) |value| try replaceOptional(allocator, &row.tool_output, value);
    if (update.error_text) |value| try replaceOptional(allocator, &row.tool_error, value);
    if (update.locations) |value| try replaceOptional(allocator, &row.tool_locations, value);
    if (update.raw) |value| try replaceOptional(allocator, &row.tool_raw, value);
    if (update.kind) |value| try replaceMessageOptional(allocator, &row.message.tool_call_kind, value);
    if (update.status) |value| try replaceMessageOptional(allocator, &row.message.tool_call_status, value);

    const kind = row.message.tool_call_kind orelse "other";
    const status = row.message.tool_call_status orelse "unknown";
    const title = row.tool_title orelse "";
    const author = toolDisplayAuthor(kind, status);
    const body = try toolBodyAlloc(allocator, .{
        .call_id = row.message.tool_call_id orelse "",
        .title = title,
        .kind = kind,
        .status = status,
        .input = row.tool_input,
        .output = row.tool_output,
        .error_text = row.tool_error,
        .locations = row.tool_locations,
        .raw = row.tool_raw,
    }, title, author);
    defer allocator.free(body);
    allocator.free(row.message.author);
    allocator.free(row.message.body);
    row.message.author = try allocator.dupe(u8, author);
    row.message.body = try allocator.dupe(u8, body);
}

fn replaceOptional(allocator: std.mem.Allocator, target: *?[]u8, value: []const u8) !void {
    const owned = try allocator.dupe(u8, value);
    if (target.*) |old| allocator.free(old);
    target.* = owned;
}

fn replaceMessageOptional(allocator: std.mem.Allocator, target: *?[]const u8, value: []const u8) !void {
    const owned = try allocator.dupe(u8, value);
    if (target.*) |old| allocator.free(old);
    target.* = owned;
}

fn dupeOptional(allocator: std.mem.Allocator, value: ?[]const u8) !?[]u8 {
    return if (value) |text| try allocator.dupe(u8, text) else null;
}

fn isTerminalThinkRow(row: *const Row) bool {
    const kind = row.message.tool_call_kind orelse return false;
    const status = row.message.tool_call_status orelse return false;
    return std.mem.eql(u8, kind, "think") and
        (std.mem.eql(u8, status, "completed") or std.mem.eql(u8, status, "failed") or std.mem.eql(u8, status, "cancelled")) and
        !hasToolContent(row.tool_input, row.tool_output, row.tool_error);
}

fn toolDefaultTitle(kind: []const u8, status: []const u8) []const u8 {
    if (std.mem.eql(u8, kind, "read")) return "Read";
    if (std.mem.eql(u8, kind, "edit")) return "Edit";
    if (std.mem.eql(u8, kind, "delete")) return "Delete";
    if (std.mem.eql(u8, kind, "move")) return "Move";
    if (std.mem.eql(u8, kind, "search")) return "Search";
    if (std.mem.eql(u8, kind, "execute")) return if (std.mem.eql(u8, status, "failed")) "Command failed" else "Ran command";
    if (std.mem.eql(u8, kind, "think")) return if (std.mem.eql(u8, status, "pending") or std.mem.eql(u8, status, "in_progress")) "Thinking" else "Think";
    if (std.mem.eql(u8, kind, "fetch")) return "Fetch";
    if (std.mem.eql(u8, kind, "mcp")) return "MCP tool";
    if (std.mem.eql(u8, kind, "subagent")) return "Subagent";
    return "Cursor tool";
}

fn toolDisplayAuthor(kind: []const u8, status: []const u8) []const u8 {
    if (std.mem.eql(u8, kind, "mcp")) return "MCP tool";
    if (std.mem.eql(u8, kind, "subagent")) return "Subagent";
    return toolDefaultTitle(kind, status);
}

fn toolBodyAlloc(
    allocator: std.mem.Allocator,
    update: ToolUpdate,
    title: []const u8,
    author: []const u8,
) ![]u8 {
    const Field = struct { label: []const u8, value: ?[]const u8 };
    const fields = [_]Field{
        .{ .label = "Input", .value = update.input },
        .{ .label = "Output", .value = update.output },
        .{ .label = "Error", .value = update.error_text },
        .{ .label = "Locations", .value = update.locations },
    };
    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    var wrote = false;
    const generic_mcp = std.mem.eql(u8, update.kind orelse "other", "mcp") and
        (std.ascii.eqlIgnoreCase(title, "MCP: tool") or std.ascii.eqlIgnoreCase(title, "MCP tool"));
    if (visibleText(title) and !generic_mcp and !std.mem.eql(u8, title, author)) {
        try writer.writer.print("Tool:\n{s}", .{title});
        wrote = true;
    }
    for (fields) |field| {
        const value = field.value orelse continue;
        const trimmed = std.mem.trim(u8, value, &std.ascii.whitespace);
        if (trimmed.len == 0) continue;
        const pretty = if (std.mem.eql(u8, update.kind orelse "other", "mcp"))
            try prettyJsonAlloc(allocator, trimmed)
        else
            null;
        defer if (pretty) |owned| allocator.free(owned);
        if (wrote) try writer.writer.writeAll("\n\n");
        try writer.writer.print("{s}:\n{s}", .{ field.label, pretty orelse trimmed });
        wrote = true;
    }
    if (!wrote) {
        const raw = update.raw orelse "";
        const trimmed = std.mem.trim(u8, raw, &std.ascii.whitespace);
        if (trimmed.len > 0) {
            try writer.writer.print("Raw event:\n{s}", .{trimmed});
            wrote = true;
        }
    }
    if (!wrote) try writer.writer.writeAll(if (std.mem.eql(u8, update.kind orelse "other", "think")) "…" else update.status orelse "unknown");
    return try writer.toOwnedSlice();
}

fn prettyJsonAlloc(allocator: std.mem.Allocator, text: []const u8) !?[]u8 {
    if (text.len < 2 or (text[0] != '{' and text[0] != '[')) return null;
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, text, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object and parsed.value != .array) return null;
    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    var stringify: std.json.Stringify = .{ .writer = &writer.writer, .options = .{ .whitespace = .indent_2 } };
    try stringify.write(parsed.value);
    return try writer.toOwnedSlice();
}

fn applyDiffEvent(
    allocator: std.mem.Allocator,
    rows: *std.ArrayListUnmanaged(Row),
    diff_files: *std.ArrayListUnmanaged(DiffFile),
    has_turn_snapshot: *bool,
    payload_json: []const u8,
    partial_text: *std.ArrayListUnmanaged(u8),
    provider: []const u8,
) !void {
    var payload = try parseObject(allocator, payload_json);
    defer payload.parsed.deinit();
    const object = try payload.object();
    const files_value = object.get("files") orelse return error.InvalidDaemonResponse;
    if (files_value != .array) return error.InvalidDaemonResponse;
    const snapshot = std.mem.eql(u8, jsonString(object, "scope") orelse "incremental", "turn_snapshot");
    if (!snapshot and has_turn_snapshot.*) return;
    if (snapshot) freeDiffFiles(allocator, diff_files);
    if (snapshot) has_turn_snapshot.* = true;
    if (files_value.array.items.len == 0) return;
    for (files_value.array.items) |file_value| {
        if (file_value != .object) continue;
        const path = jsonString(file_value.object, "path") orelse continue;
        const additions = jsonInteger(file_value.object, "additions");
        const deletions = jsonInteger(file_value.object, "deletions");
        const patch = jsonString(file_value.object, "patch");
        var found = false;
        for (diff_files.items) |*existing| {
            if (!std.mem.eql(u8, existing.path, path)) continue;
            existing.additions = additions;
            existing.deletions = deletions;
            if (existing.patch) |old| allocator.free(old);
            existing.patch = try dupeOptional(allocator, patch);
            found = true;
            break;
        }
        if (!found) try diff_files.append(allocator, .{
            .path = try allocator.dupe(u8, path),
            .additions = additions,
            .deletions = deletions,
            .patch = try dupeOptional(allocator, patch),
        });
    }
    if (diff_files.items.len == 0) return;
    try flushAssistant(allocator, rows, partial_text, provider);
    const body = try diffBodyAlloc(allocator, diff_files.items);
    defer allocator.free(body);
    for (rows.items) |*row| {
        if (std.mem.eql(u8, row.message.role, "system") and std.mem.eql(u8, row.message.author, "Changed files") and std.mem.startsWith(u8, row.message.body, "VERDE_DIFF_V2\n")) {
            allocator.free(row.message.body);
            row.message.body = try allocator.dupe(u8, body);
            return;
        }
    }
    _ = try appendOwnedRow(allocator, rows, "system", "Changed files", body, null);
}

fn diffBodyAlloc(allocator: std.mem.Allocator, files: []const DiffFile) ![]u8 {
    var body: std.ArrayListUnmanaged(u8) = .empty;
    errdefer body.deinit(allocator);
    try body.appendSlice(allocator, "VERDE_DIFF_V2\n");
    for (files) |file| {
        const patch = file.patch orelse "";
        const header = try std.fmt.allocPrint(allocator, "FILE\t{d}\t{d}\t{d}\t{d}\n", .{ file.path.len, file.additions, file.deletions, patch.len });
        defer allocator.free(header);
        try body.appendSlice(allocator, header);
        try body.appendSlice(allocator, file.path);
        try body.appendSlice(allocator, patch);
    }
    return body.toOwnedSlice(allocator);
}

fn containsAssistant(rows: []const Row) bool {
    for (rows) |row| if (std.mem.eql(u8, row.message.role, "assistant")) return true;
    return false;
}

fn cancelLingeringTools(allocator: std.mem.Allocator, rows: *std.ArrayListUnmanaged(Row)) void {
    var index = rows.items.len;
    while (index > 0) {
        index -= 1;
        const row = &rows.items[index];
        const status = row.message.tool_call_status orelse continue;
        if (!std.mem.eql(u8, status, "pending") and !std.mem.eql(u8, status, "in_progress")) continue;
        const kind: []const u8 = row.message.tool_call_kind orelse "other";
        if (kind.len > 0 and
            std.mem.eql(u8, kind, "think") and
            !hasToolContent(row.tool_input, row.tool_output, row.tool_error))
        {
            freeRow(allocator, row);
            _ = rows.orderedRemove(index);
        } else {
            replaceMessageOptionalNoFail(allocator, &row.message.tool_call_status, "cancelled");
        }
    }
}

fn replaceMessageOptionalNoFail(allocator: std.mem.Allocator, target: *?[]const u8, value: []const u8) void {
    const owned = allocator.dupe(u8, value) catch return;
    if (target.*) |old| allocator.free(old);
    target.* = owned;
}

fn freeRows(allocator: std.mem.Allocator, rows: *std.ArrayListUnmanaged(Row)) void {
    for (rows.items) |*row| freeRow(allocator, row);
    rows.deinit(allocator);
    rows.* = .empty;
}

fn freeRow(allocator: std.mem.Allocator, row: *Row) void {
    freeMessage(allocator, &row.message);
    freeToolMetadata(allocator, row);
}

fn freeToolMetadata(allocator: std.mem.Allocator, row: *Row) void {
    if (row.tool_title) |value| allocator.free(value);
    if (row.tool_input) |value| allocator.free(value);
    if (row.tool_output) |value| allocator.free(value);
    if (row.tool_error) |value| allocator.free(value);
    if (row.tool_locations) |value| allocator.free(value);
    if (row.tool_raw) |value| allocator.free(value);
    row.tool_title = null;
    row.tool_input = null;
    row.tool_output = null;
    row.tool_error = null;
    row.tool_locations = null;
    row.tool_raw = null;
}

fn freeMessage(allocator: std.mem.Allocator, message: *store_protocol.Message) void {
    if (message.message_id.len > 0) allocator.free(message.message_id);
    allocator.free(message.author);
    allocator.free(message.body);
    if (message.images.len > 0) {
        for (@constCast(message.images)) |*image| freeAttachment(allocator, image);
        allocator.free(message.images);
    }
    if (message.image) |*image| freeAttachment(allocator, image);
    if (message.tool_call_id) |value| allocator.free(value);
    if (message.tool_call_kind) |value| allocator.free(value);
    if (message.tool_call_status) |value| allocator.free(value);
    message.* = undefined;
}

fn freeAttachment(allocator: std.mem.Allocator, attachment: *store_protocol.Attachment) void {
    allocator.free(attachment.path);
    allocator.free(attachment.mime);
    if (attachment.attachment_id) |value| allocator.free(value);
}

fn freeDiffFiles(allocator: std.mem.Allocator, files: *std.ArrayListUnmanaged(DiffFile)) void {
    for (files.items) |file| {
        allocator.free(file.path);
        if (file.patch) |patch| allocator.free(patch);
    }
    files.deinit(allocator);
    files.* = .empty;
}

test "delta flushes at message, tool, and diff boundaries" {
    const allocator = std.testing.allocator;
    const events = [_]ChatEvent{
        .{ .kind = "assistant_delta", .payload_json = "{\"text\":\"hello\"}" },
        .{ .kind = "message", .payload_json = "{\"title\":\"Notice\",\"body\":\"ready\"}" },
        .{ .kind = "assistant_delta", .payload_json = "{\"text\":\"again\"}" },
        .{ .kind = "tool_call", .payload_json = "{\"call_id\":\"c1\",\"kind\":\"read\",\"status\":\"completed\",\"input\":\"file\"}" },
        .{ .kind = "assistant_delta", .payload_json = "{\"text\":\"last\"}" },
        .{ .kind = "diff", .payload_json = "{\"files\":[{\"path\":\"a.zig\",\"additions\":1,\"deletions\":0}]}" },
        .{ .kind = "diff", .payload_json = "{\"scope\":\"turn_snapshot\",\"files\":[{\"path\":\"b.zig\",\"additions\":2,\"deletions\":1}]}" },
        .{ .kind = "diff", .payload_json = "{\"files\":[{\"path\":\"a.zig\",\"additions\":9,\"deletions\":9}]}" },
    };
    const messages = try apply(allocator, &events, .{ .status = .completed, .provider = "codex", .reply_text = "" });
    defer freeMessages(allocator, messages);
    try std.testing.expectEqual(@as(usize, 6), messages.len);
    try std.testing.expectEqualStrings("assistant", messages[0].role);
    try std.testing.expectEqualStrings("hello", messages[0].body);
    try std.testing.expectEqualStrings("Notice", messages[1].author);
    try std.testing.expectEqualStrings("again", messages[2].body);
    try std.testing.expectEqualStrings("Read", messages[3].author);
    try std.testing.expectEqualStrings("last", messages[4].body);
    try std.testing.expectEqualStrings("Changed files", messages[5].author);
    try std.testing.expect(std.mem.startsWith(u8, messages[5].body, "VERDE_DIFF_V2\n"));
    try std.testing.expect(std.mem.indexOf(u8, messages[5].body, "b.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, messages[5].body, "a.zig") == null);
}

test "tool calls upsert and merge while retaining one row" {
    const allocator = std.testing.allocator;
    const events = [_]ChatEvent{
        .{ .kind = "tool_call", .payload_json = "{\"call_id\":\"c1\",\"kind\":\"execute\",\"status\":\"in_progress\",\"input\":\"echo hi\"}" },
        .{ .kind = "tool_call", .payload_json = "{\"call_id\":\"c1\",\"status\":\"completed\",\"output\":\"hi\"}" },
    };
    const messages = try apply(allocator, &events, .{ .status = .completed, .provider = "codex" });
    defer freeMessages(allocator, messages);
    try std.testing.expectEqual(@as(usize, 1), messages.len);
    try std.testing.expectEqualStrings("c1", messages[0].tool_call_id.?);
    try std.testing.expectEqualStrings("execute", messages[0].tool_call_kind.?);
    try std.testing.expectEqualStrings("completed", messages[0].tool_call_status.?);
    try std.testing.expectEqualStrings("Input:\necho hi\n\nOutput:\nhi", messages[0].body);
}

test "lingering tools downgrade and content-less think is transient" {
    const allocator = std.testing.allocator;
    const events = [_]ChatEvent{
        .{ .kind = "tool_call", .payload_json = "{\"kind\":\"think\",\"status\":\"in_progress\"}" },
        .{ .kind = "tool_call", .payload_json = "{\"call_id\":\"c1\",\"kind\":\"execute\",\"status\":\"in_progress\",\"input\":\"ls\"}" },
        .{ .kind = "tool_call", .payload_json = "{\"call_id\":\"c2\",\"kind\":\"think\",\"status\":\"in_progress\",\"output\":\"reason\"}" },
        .{ .kind = "tool_call", .payload_json = "{\"call_id\":\"c2\",\"status\":\"completed\"}" },
    };
    const messages = try apply(allocator, &events, .{ .status = .completed, .provider = "codex" });
    defer freeMessages(allocator, messages);
    try std.testing.expectEqual(@as(usize, 2), messages.len);
    try std.testing.expectEqualStrings("cancelled", messages[0].tool_call_status.?);
    try std.testing.expectEqualStrings("think", messages[1].tool_call_kind.?);
    try std.testing.expectEqualStrings("completed", messages[1].tool_call_status.?);
    try std.testing.expect(std.mem.indexOf(u8, messages[1].body, "reason") != null);
}

test "aborted outcome honors followup_pending both ways" {
    const allocator = std.testing.allocator;
    const no_followup = try apply(allocator, &.{}, .{ .status = .aborted, .provider = "codex" });
    defer freeMessages(allocator, no_followup);
    try std.testing.expectEqual(@as(usize, 1), no_followup.len);
    try std.testing.expectEqualStrings("Conversation interrupted", no_followup[0].author);

    const followup = try apply(allocator, &.{}, .{ .status = .aborted, .provider = "codex", .followup_pending = true });
    defer freeMessages(allocator, followup);
    try std.testing.expectEqual(@as(usize, 0), followup.len);
}

test "failed outcome appends GUI failure row and preserves images" {
    const allocator = std.testing.allocator;
    const events = [_]ChatEvent{.{
        .kind = "message",
        .payload_json = "{\"message_id\":\"m1\",\"title\":\"System\",\"body\":\"with images\",\"images\":[{\"path\":\"a.png\",\"mime\":\"image/png\"},{\"path\":\"b.png\",\"mime\":\"image/png\"}]}",
    }};
    const messages = try apply(allocator, &events, .{ .status = .failed, .failure_message = "No provider" });
    defer freeMessages(allocator, messages);
    try std.testing.expectEqual(@as(usize, 2), messages.len);
    try std.testing.expectEqual(@as(usize, 2), messages[0].images.len);
    try std.testing.expectEqualStrings("a.png", messages[0].images[0].path);
    try std.testing.expectEqualStrings("No provider", messages[1].body);
}

test "accepted steer event becomes an identified durable system row" {
    const allocator = std.testing.allocator;
    const events = [_]ChatEvent{.{
        .kind = "steer",
        .payload_json = "{\"steer_id\":\"s1\",\"message_id\":\"turn:t1:steer:s1\",\"title\":\"Steering current turn\",\"body\":\"change direction\",\"images\":[{\"path\":\"a.png\",\"mime\":\"image/png\",\"byte_size\":4}]}",
    }};
    const messages = try apply(allocator, &events, .{ .status = .completed, .provider = "claude" });
    defer freeMessages(allocator, messages);
    try std.testing.expectEqual(@as(usize, 1), messages.len);
    try std.testing.expectEqualStrings("system", messages[0].role);
    try std.testing.expectEqualStrings("Steering current turn", messages[0].author);
    try std.testing.expectEqualStrings("change direction", messages[0].body);
    try std.testing.expectEqualStrings("turn:t1:steer:s1", messages[0].message_id);
    try std.testing.expectEqualStrings("a.png", messages[0].images[0].path);
}

test "golden event stream matches the ordered GUI rows" {
    const allocator = std.testing.allocator;
    const events = [_]ChatEvent{
        .{ .kind = "assistant_delta", .payload_json = "{\"text\":\"First \"}" },
        .{ .kind = "assistant_delta", .payload_json = "{\"text\":\"reply\"}" },
        .{ .kind = "tool_call", .payload_json = "{\"call_id\":\"tool-1\",\"title\":\"Edit file\",\"kind\":\"edit\",\"status\":\"in_progress\",\"input\":\"a.zig\"}" },
        .{ .kind = "tool_call", .payload_json = "{\"call_id\":\"tool-1\",\"status\":\"completed\",\"output\":\"done\"}" },
        .{ .kind = "assistant_delta", .payload_json = "{\"text\":\"Second reply\"}" },
        .{ .kind = "message", .payload_json = "{\"title\":\"Notice\",\"body\":\"checkpoint\"}" },
    };
    const messages = try apply(allocator, &events, .{ .status = .completed, .provider = "codex", .reply_text = "final" });
    defer freeMessages(allocator, messages);
    try std.testing.expectEqual(@as(usize, 4), messages.len);
    try std.testing.expectEqualStrings("Codex", messages[0].author);
    try std.testing.expectEqualStrings("First reply", messages[0].body);
    try std.testing.expectEqualStrings("Edit", messages[1].author);
    try std.testing.expectEqualStrings("Tool:\nEdit file\n\nInput:\na.zig\n\nOutput:\ndone", messages[1].body);
    try std.testing.expectEqualStrings("Codex", messages[2].author);
    try std.testing.expectEqualStrings("Second reply", messages[2].body);
    try std.testing.expectEqualStrings("Notice", messages[3].author);
    try std.testing.expectEqualStrings("checkpoint", messages[3].body);
}
