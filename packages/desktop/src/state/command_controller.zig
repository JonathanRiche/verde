//! Command-palette query, selection, scope, and action-menu state.

const std = @import("std");
const headless = @import("headless");
const keybinds = @import("../app/keybinds.zig");
const daemon_client = @import("../daemon/client.zig");
const loop_wakeup = @import("loop_wakeup");
const runtime_log = @import("../runtime/log.zig");
const provider_models = @import("provider_models.zig");
const state_sync = @import("sync.zig");

const Provider = provider_models.Provider;
const Harness = provider_models.Harness;
const provider_types = headless.provider_types;
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
    command: provider_types.ProviderSlashCommandId = .usage,
    display_name: ?[]u8 = null,
    started_at_ms: i64 = 0,
    result: ?provider_types.RunSlashCommandResult = null,
    error_message: ?[]u8 = null,
};

pub const PendingSlashCommandDetails = struct {
    provider: Provider,
    command: provider_types.ProviderSlashCommandId,
    display_name: []const u8,
    started_at_ms: i64,
};

pub const SlashCommandWorkerRequest = struct {
    provider: Provider,
    harness: Harness,
    pref_path: []u8,
    project_path: []u8,
    thread_id: ?[]u8,
    command: provider_types.ProviderSlashCommandId,
    raw_text: []u8,
    args: []u8,
};

const ProviderSlashCatalogStatus = enum {
    idle,
    pending,
    completed,
};

const ProviderSlashCatalogRequest = struct {
    provider: Provider,
    pref_path: []u8,
    project_path: []u8,

    fn deinit(self: *ProviderSlashCatalogRequest) void {
        const allocator = std.heap.page_allocator;
        allocator.free(self.pref_path);
        allocator.free(self.project_path);
        allocator.destroy(self);
    }
};

pub const ProviderSlashCatalogState = struct {
    mutex: Mutex = .{},
    status: ProviderSlashCatalogStatus = .idle,
    worker: ?std.Thread = null,
    request: ?*ProviderSlashCatalogRequest = null,
    result: ?[]const provider_types.ProviderSlashCommand = null,
    failed: bool = false,
    cached_provider: ?Provider = null,
    cached_project_path: ?[]u8 = null,
    commands: []const provider_types.ProviderSlashCommand = &.{},
};

fn freeProviderSlashCommands(commands: []const provider_types.ProviderSlashCommand) void {
    const allocator = std.heap.page_allocator;
    for (commands) |command| {
        allocator.free(command.name);
        allocator.free(command.summary);
        allocator.free(command.usage);
    }
    allocator.free(commands);
}

fn providerSlashCatalogWorker(state: *ProviderSlashCatalogState, request: *const ProviderSlashCatalogRequest) void {
    const allocator = std.heap.page_allocator;
    var transport: daemon_client.HeadlessTransport = .{ .allocator = allocator, .pref_path = request.pref_path };
    var client = daemon_client.headlessClient(allocator, &transport);
    const commands = blk: {
        var parsed = client.callProviderSlashList(headless.Capabilities.phase1(), .{
            .provider = providerProtocolTag(request.provider),
            .project_path = request.project_path,
        }) catch break :blk null;
        defer parsed.deinit();
        const response = client.decodeProviderSlashList(&parsed) catch break :blk null;
        if (response.provider != providerProtocolTag(request.provider)) {
            freeProviderSlashCommands(response.commands);
            break :blk null;
        }
        break :blk response.commands;
    };

    state.mutex.lock();
    defer state.mutex.unlock();
    state.result = commands;
    state.failed = commands == null;
    state.status = .completed;
    loop_wakeup.notify();
}

pub fn slashCommandWorker(state: *SlashCommandState, request: *SlashCommandWorkerRequest) void {
    const page_alloc = std.heap.page_allocator;
    defer {
        page_alloc.free(request.project_path);
        page_alloc.free(request.pref_path);
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
) !provider_types.RunSlashCommandResult {
    if (request.harness != .local_cli) return error.UnsupportedHarnessMode;
    var transport: daemon_client.HeadlessTransport = .{
        .allocator = allocator,
        .pref_path = request.pref_path,
    };
    var client = daemon_client.headlessClient(allocator, &transport);
    var parsed = try client.callProviderSlashRun(headless.Capabilities.phase1(), .{
        .provider = providerProtocolTag(request.provider),
        .project_path = request.project_path,
        .thread_id = request.thread_id,
        .command = request.command,
        .raw_text = request.raw_text,
        .args = request.args,
    });
    defer parsed.deinit();
    const response = try client.decodeProviderSlashRun(&parsed);
    if (response.provider != providerProtocolTag(request.provider)) {
        response.result.deinit(allocator);
        return error.InvalidDaemonResponse;
    }
    return response.result;
}

fn providerProtocolTag(provider: Provider) provider_types.Provider {
    return switch (provider) {
        .opencode => .opencode,
        .codex => .codex,
        .claude => .claude,
        .cursor => .cursor,
        .pi => .pi,
        .fx => .fx,
        .grok => .grok,
        .muse => .muse,
    };
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
        .muse => switch (err) {
            error.UnsupportedOperation => "Muse does not support this slash command yet.",
            else => "Muse slash command failed.",
        },
    };
    return allocator.dupe(u8, message);
}

pub fn slashCommandFallbackName(command: provider_types.ProviderSlashCommandId) []const u8 {
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
    provider_slash_catalog: ProviderSlashCatalogState = .{},

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

pub fn pollProviderSlashCatalog(self: anytype) void {
    const catalog = &self.command_controller.provider_slash_catalog;
    catalog.mutex.lock();
    if (catalog.status != .completed) {
        catalog.mutex.unlock();
        return;
    }
    const worker = catalog.worker.?;
    const request = catalog.request.?;
    const result = catalog.result;
    const failed = catalog.failed;
    catalog.worker = null;
    catalog.request = null;
    catalog.result = null;
    catalog.failed = false;
    catalog.status = .idle;
    catalog.mutex.unlock();
    worker.join();

    if (!failed) {
        if (catalog.cached_provider != null) freeProviderSlashCommands(catalog.commands);
        if (catalog.cached_project_path) |path| std.heap.page_allocator.free(path);
        catalog.commands = result.?;
        catalog.cached_provider = request.provider;
        catalog.cached_project_path = std.heap.page_allocator.dupe(u8, request.project_path) catch null;
        if (catalog.cached_project_path == null) {
            freeProviderSlashCommands(catalog.commands);
            catalog.commands = &.{};
            catalog.cached_provider = null;
        }
        self.markDirty();
    } else if (result) |commands| {
        freeProviderSlashCommands(commands);
    }
    request.deinit();
}

pub fn ensureProviderSlashCatalog(self: anytype) bool {
    self.pollProviderSlashCatalog();
    if (self.project_controller.projects.items.len == 0 or
        self.project_controller.selected_index >= self.project_controller.projects.items.len)
    {
        return false;
    }
    const provider = self.currentThread().provider;
    const project_path = self.currentProject().path;
    const catalog = &self.command_controller.provider_slash_catalog;
    if (catalog.cached_provider == provider and catalog.cached_project_path != null and
        std.mem.eql(u8, catalog.cached_project_path.?, project_path))
    {
        return true;
    }

    catalog.mutex.lock();
    defer catalog.mutex.unlock();
    if (catalog.status == .pending) return false;
    const allocator = std.heap.page_allocator;
    const request = allocator.create(ProviderSlashCatalogRequest) catch return false;
    request.* = .{
        .provider = provider,
        .pref_path = allocator.dupe(u8, self.storage.pref_path) catch {
            allocator.destroy(request);
            return false;
        },
        .project_path = undefined,
    };
    request.project_path = allocator.dupe(u8, project_path) catch {
        allocator.free(request.pref_path);
        allocator.destroy(request);
        return false;
    };
    catalog.request = request;
    catalog.status = .pending;
    catalog.worker = std.Thread.spawn(.{}, providerSlashCatalogWorker, .{ catalog, request }) catch {
        catalog.request = null;
        catalog.status = .idle;
        request.deinit();
        return false;
    };
    return false;
}

pub fn providerSlashCommands(self: anytype) []const provider_types.ProviderSlashCommand {
    const catalog = &self.command_controller.provider_slash_catalog;
    if (self.project_controller.projects.items.len == 0 or catalog.cached_provider != self.currentThread().provider) return &.{};
    const project_path = catalog.cached_project_path orelse return &.{};
    if (!std.mem.eql(u8, project_path, self.currentProject().path)) return &.{};
    return catalog.commands;
}

pub fn finishProviderSlashCatalog(self: anytype) void {
    const catalog = &self.command_controller.provider_slash_catalog;
    catalog.mutex.lock();
    const worker = catalog.worker;
    catalog.mutex.unlock();
    if (worker) |thread| thread.join();
    catalog.mutex.lock();
    const request = catalog.request;
    const result = catalog.result;
    catalog.worker = null;
    catalog.request = null;
    catalog.result = null;
    catalog.status = .idle;
    catalog.mutex.unlock();
    if (request) |value| value.deinit();
    if (result) |commands| freeProviderSlashCommands(commands);
    if (catalog.cached_provider != null) freeProviderSlashCommands(catalog.commands);
    if (catalog.cached_project_path) |path| std.heap.page_allocator.free(path);
    catalog.commands = &.{};
    catalog.cached_project_path = null;
    catalog.cached_provider = null;
}

/// Opens the global or project-scoped command palette and transfers text focus.
pub fn openCommandPalette(self: anytype, scope_project: ?usize) void {
    self.command_controller.begin(scope_project);
    self.refreshPaletteHistory();
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
    self.clearPaletteHistory();
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
