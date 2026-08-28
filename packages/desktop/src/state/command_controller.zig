//! Command-palette query, selection, scope, and action-menu state.

const std = @import("std");
const keybinds = @import("../app/keybinds.zig");
const ai_harness = @import("../providers/harness.zig");
const loop_wakeup = @import("loop_wakeup");
const runtime_log = @import("../runtime/log.zig");
const provider_models = @import("provider_models.zig");
const state_sync = @import("sync.zig");

const Provider = provider_models.Provider;
const Harness = provider_models.Harness;
const Mutex = state_sync.Mutex;

pub const SlashCommandStatus = enum {
    idle,
    pending,
    completed,
    failed,
};

pub const SlashCommandState = struct {
    mutex: Mutex = .{},
    status: SlashCommandStatus = .idle,
    worker: ?std.Thread = null,
    project_index: usize = 0,
    thread_index: usize = 0,
    provider: Provider = .codex,
    command: ai_harness.ProviderSlashCommandId = .usage,
    display_name: ?[]u8 = null,
    started_at_ms: i64 = 0,
    result: ?ai_harness.RunSlashCommandResult = null,
    error_message: ?[]u8 = null,
};

pub const PendingSlashCommandDetails = struct {
    provider: Provider,
    command: ai_harness.ProviderSlashCommandId,
    display_name: []const u8,
    started_at_ms: i64,
};

pub const SlashCommandWorkerRequest = struct {
    provider: Provider,
    harness: Harness,
    project_path: []u8,
    thread_id: ?[]u8,
    command: ai_harness.ProviderSlashCommandId,
    raw_text: []u8,
    args: []u8,
};

pub fn slashCommandWorker(state: *SlashCommandState, request: *SlashCommandWorkerRequest) void {
    const page_alloc = std.heap.page_allocator;
    defer {
        page_alloc.free(request.project_path);
        if (request.thread_id) |thread_id| page_alloc.free(thread_id);
        page_alloc.free(request.raw_text);
        page_alloc.free(request.args);
        page_alloc.destroy(request);
    }

    runtime_log.diagnostic(
        "slash command worker begin provider={s} command={s} thread_id_len={d}",
        .{ @tagName(request.provider), @tagName(request.command), if (request.thread_id) |thread_id| thread_id.len else 0 },
    );

    const result = runSlashCommandWorker(page_alloc, request);

    state.mutex.lock();
    defer state.mutex.unlock();
    defer loop_wakeup.notify();

    if (result) |payload| {
        runtime_log.diagnostic("slash command worker completed provider={s} command={s}", .{ @tagName(request.provider), @tagName(request.command) });
        state.result = payload;
        state.error_message = null;
        state.status = .completed;
    } else |err| {
        runtime_log.diagnostic("slash command worker failed provider={s} command={s}: {s}", .{ @tagName(request.provider), @tagName(request.command), @errorName(err) });
        state.result = null;
        state.error_message = formatSlashCommandError(page_alloc, request.provider, err) catch null;
        state.status = .failed;
    }
}

fn runSlashCommandWorker(
    allocator: std.mem.Allocator,
    request: *const SlashCommandWorkerRequest,
) !ai_harness.RunSlashCommandResult {
    if (request.harness != .local_cli) return error.UnsupportedHarnessMode;
    const request_cwd = request.project_path;

    const provider_config = switch (request.provider) {
        .opencode => ai_harness.ProviderConfig{
            .opencode = .{
                .allocator = allocator,
                .working_directory = request_cwd,
                .launch_if_missing = true,
            },
        },
        .codex => ai_harness.ProviderConfig{
            .codex = .{
                .cwd = request_cwd,
                .launch_on_connect = true,
            },
        },
        .claude => ai_harness.ProviderConfig{
            .claude = .{
                .cwd = request_cwd,
            },
        },
        .cursor => ai_harness.ProviderConfig{
            .cursor = .{
                .cwd = request_cwd,
            },
        },
        .pi => ai_harness.ProviderConfig{
            .pi = .{
                .cwd = request_cwd,
            },
        },
        .fx => ai_harness.ProviderConfig{
            .fx = .{
                .cwd = request_cwd,
            },
        },
        .grok => ai_harness.ProviderConfig{
            .grok = .{
                .cwd = request_cwd,
            },
        },
    };

    var client = try ai_harness.connect(allocator, provider_config);
    defer client.deinit();

    return client.runSlashCommand(allocator, .{
        .thread_id = request.thread_id,
        .cwd = request_cwd,
        .command = request.command,
        .raw_text = request.raw_text,
        .args = request.args,
    });
}

fn formatSlashCommandError(allocator: std.mem.Allocator, provider: Provider, err: anyerror) ![]u8 {
    const message: []const u8 = switch (provider) {
        .codex => switch (err) {
            error.CodexRpcFailed => "Codex slash command failed.",
            error.ConnectionClosed => "Codex app-server connection closed.",
            error.NotConnected => "Could not connect to Codex app-server.",
            error.WebSocketUpgradeRejected => "Codex app-server rejected the connection.",
            error.FileNotFound => "The codex executable was not found on PATH.",
            error.UnsupportedOperation => "Codex does not support this slash command yet.",
            else => "Codex slash command failed.",
        },
        .opencode => switch (err) {
            error.UnsupportedOperation => "OpenCode does not support this slash command yet.",
            else => "OpenCode slash command failed.",
        },
        .claude => switch (err) {
            error.UnsupportedOperation => "Claude does not support this slash command yet.",
            else => "Claude slash command failed.",
        },
        .cursor => switch (err) {
            error.UnsupportedOperation => "Cursor does not support this slash command yet.",
            else => "Cursor slash command failed.",
        },
        .pi => switch (err) {
            error.UnsupportedOperation => "Pi does not support this slash command yet.",
            else => "Pi slash command failed.",
        },
        .fx => switch (err) {
            error.UnsupportedOperation => "FX does not support this slash command yet.",
            else => "FX slash command failed.",
        },
        .grok => switch (err) {
            error.UnsupportedOperation => "Grok does not support this slash command yet.",
            else => "Grok slash command failed.",
        },
    };
    return allocator.dupe(u8, message);
}

pub fn slashCommandFallbackName(command: ai_harness.ProviderSlashCommandId) []const u8 {
    return switch (command) {
        .usage => "/usage",
        .goal => "/goal",
        .compact => "/compact",
        .review => "/review",
        .shell => "/shell",
        .custom => "/command",
    };
}

pub const State = struct {
    open: bool = false,
    scope_project: ?usize = null,
    query_storage: [256:0]u8 = std.mem.zeroes([256:0]u8),
    cursor: usize = 0,
    selected: usize = 0,
    action_menu_open: bool = false,
    action_selected: usize = 0,
    keyboard_config: ?*const keybinds.NativeKeyboardConfig = null,

    pub fn begin(self: *State, scope_project: ?usize) void {
        self.open = true;
        self.scope_project = scope_project;
        self.query_storage[0] = 0;
        self.cursor = 0;
        self.selected = 0;
        self.action_menu_open = false;
        self.action_selected = 0;
    }

    pub fn close(self: *State) void {
        self.open = false;
        self.action_menu_open = false;
    }

    pub fn query(self: *const State) []const u8 {
        return std.mem.sliceTo(self.query_storage[0..], 0);
    }

    pub fn queryBuffer(self: *State) [:0]u8 {
        return self.query_storage[0 .. self.query_storage.len - 1 :0];
    }
};

/// Opens the global or project-scoped command palette and transfers text focus.
pub fn openCommandPalette(self: anytype, scope_project: ?usize) void {
    self.command_controller.begin(scope_project);
    self.modal_text_selection_anchor = null;
    self.palette_modal_text_focus = .command_palette;
    self.closeSidebarContextMenu();
    self.workspace_header_open_menu_open = false;
    self.workspace_header_open_menu_pane_id = null;
    self.blurPaletteComposer();
    self.noteInteraction();
    self.markDirty();
}

pub fn closeCommandPalette(self: anytype) void {
    if (!self.command_controller.open) return;
    self.command_controller.close();
    if (self.palette_modal_text_focus == .command_palette) self.palette_modal_text_focus = .none;
    self.modal_text_selection_anchor = null;
    self.markDirty();
}

pub fn commandPaletteQuery(self: anytype) []const u8 {
    return self.command_controller.query();
}

pub fn commandPaletteQueryBuffer(self: anytype) [:0]u8 {
    return self.command_controller.queryBuffer();
}

test "command state resets scope selection and focus-sensitive action state" {
    var state: State = .{};
    state.query_storage[0] = 'x';
    state.query_storage[1] = 0;
    state.cursor = 1;
    state.selected = 4;
    state.action_menu_open = true;
    state.action_selected = 2;

    state.begin(3);
    try std.testing.expect(state.open);
    try std.testing.expectEqual(@as(?usize, 3), state.scope_project);
    try std.testing.expectEqualStrings("", state.query());
    try std.testing.expectEqual(@as(usize, 0), state.cursor);
    try std.testing.expectEqual(@as(usize, 0), state.selected);
    try std.testing.expect(!state.action_menu_open);

    state.close();
    try std.testing.expect(!state.open);
    try std.testing.expect(!state.action_menu_open);
}
