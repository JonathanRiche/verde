const std = @import("std");
const builtin = @import("builtin");
const headless = @import("headless");

const app_state = @import("../state.zig");
const state_storage = @import("../state/storage.zig");
const browser_runtime = @import("../browser/mod.zig");
const browser_ui = @import("../ui/browser.zig");
const command_palette = @import("../ui/command_palette.zig");
const herdr = @import("../workspace/herdr.zig");
const loop_wakeup = @import("loop_wakeup");
const platform_ipc = @import("../platform/ipc.zig");
const live_endpoint = @import("../platform/live_endpoint.zig");
const platform_runtime = @import("platform_runtime");
const provider_types = @import("../providers/types.zig");
const terminal = @import("../terminal/terminal.zig");

pub const PROTOCOL_VERSION: u32 = 1;
pub const SOCKET_NAME = live_endpoint.SOCKET_NAME;
const LIVE_MAX_RESPONSE_BYTES = platform_ipc.DEFAULT_MAX_RESPONSE_BYTES;

const Mutex = struct {
    inner: std.Io.Mutex = .init,

    fn lock(self: *Mutex) void {
        var threaded = std.Io.Threaded.init_single_threaded;
        self.inner.lockUncancelable(threaded.io());
    }

    fn unlock(self: *Mutex) void {
        var threaded = std.Io.Threaded.init_single_threaded;
        self.inner.unlock(threaded.io());
    }
};

const Condition = struct {
    inner: std.Io.Condition = .init,

    fn wait(self: *Condition, mutex: *Mutex) void {
        var threaded = std.Io.Threaded.init_single_threaded;
        self.inner.waitUncancelable(threaded.io(), &mutex.inner);
    }

    fn broadcast(self: *Condition) void {
        var threaded = std.Io.Threaded.init_single_threaded;
        self.inner.broadcast(threaded.io());
    }
};

const Command = struct {
    request_json: []u8,
    response_json: ?[]u8 = null,
    done: bool = false,
};

pub const LiveServer = struct {
    allocator: std.mem.Allocator,
    path: []u8,
    thread: ?std.Thread = null,
    mutex: Mutex = .{},
    condition: Condition = .{},
    pending: std.ArrayList(*Command) = .empty,
    shutdown: bool = false,

    pub fn init(allocator: std.mem.Allocator, pref_path: []const u8) !LiveServer {
        const path = try live_endpoint.alloc(allocator, pref_path);
        errdefer allocator.free(path);
        return .{
            .allocator = allocator,
            .path = path,
        };
    }

    pub fn start(self: *LiveServer) !void {
        self.thread = try std.Thread.spawn(.{}, serverThreadMain, .{self});
    }

    pub fn deinit(self: *LiveServer) void {
        self.mutex.lock();
        self.shutdown = true;
        self.condition.broadcast();
        self.mutex.unlock();

        platform_ipc.wake(self.allocator, self.path, .{});
        if (self.thread) |thread| thread.join();

        for (self.pending.items) |command| {
            self.allocator.free(command.request_json);
            if (command.response_json) |response| self.allocator.free(response);
            self.allocator.destroy(command);
        }
        self.pending.deinit(self.allocator);
        self.allocator.free(self.path);
        self.* = undefined;
    }

    pub fn processPending(self: *LiveServer, state: *app_state.AppState) bool {
        var local: std.ArrayList(*Command) = .empty;
        defer local.deinit(self.allocator);

        self.mutex.lock();
        while (self.pending.items.len > 0) {
            const command = self.pending.orderedRemove(0);
            local.append(self.allocator, command) catch {
                command.response_json = errorResponseAlloc(self.allocator, null, "internal_error", "failed to drain live command") catch null;
                command.done = true;
                self.condition.broadcast();
            };
        }
        self.mutex.unlock();

        var handled = false;
        for (local.items) |command| {
            command.response_json = handleRequest(self.allocator, state, command.request_json) catch |err|
                errorResponseAlloc(self.allocator, null, "internal_error", @errorName(err)) catch null;
            command.done = true;
            handled = true;
        }

        if (handled) {
            self.mutex.lock();
            self.condition.broadcast();
            self.mutex.unlock();
        }
        return handled;
    }

    fn enqueueAndWait(self: *LiveServer, request_json: []u8) ![]u8 {
        const command = self.allocator.create(Command) catch |err| {
            self.allocator.free(request_json);
            return err;
        };
        command.* = .{ .request_json = request_json };

        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.shutdown) {
            self.allocator.free(request_json);
            self.allocator.destroy(command);
            return error.ShuttingDown;
        }
        self.pending.append(self.allocator, command) catch |err| {
            self.allocator.free(request_json);
            self.allocator.destroy(command);
            return err;
        };
        loop_wakeup.notify();
        self.condition.broadcast();
        while (!command.done and !self.shutdown) self.condition.wait(&self.mutex);
        if (self.shutdown and !command.done) {
            for (self.pending.items, 0..) |pending, index| {
                if (pending == command) {
                    _ = self.pending.orderedRemove(index);
                    break;
                }
            }
            self.allocator.free(request_json);
            self.allocator.destroy(command);
            return error.ShuttingDown;
        }

        const response = command.response_json orelse try errorResponseAlloc(self.allocator, null, "internal_error", "missing response");
        self.allocator.free(command.request_json);
        self.allocator.destroy(command);
        return response;
    }
};

fn serverThreadMain(server: *LiveServer) void {
    platform_ipc.serve(server.allocator, server.path, .{
        .context = server,
        .should_stop = transportShouldStop,
        .handle_request = transportHandleRequest,
    }, .{}) catch {};
}

fn transportShouldStop(context: *anyopaque) bool {
    const server: *LiveServer = @ptrCast(@alignCast(context));
    server.mutex.lock();
    defer server.mutex.unlock();
    return server.shutdown;
}

fn transportHandleRequest(context: *anyopaque, request_json: []u8) ![]u8 {
    const server: *LiveServer = @ptrCast(@alignCast(context));
    return server.enqueueAndWait(request_json) catch |err|
        errorResponseAlloc(server.allocator, null, "server_unavailable", @errorName(err));
}

fn handleRequest(allocator: std.mem.Allocator, state: *app_state.AppState, request_json: []const u8) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, request_json, .{});
    defer parsed.deinit();
    const root = parsed.value;
    if (root != .object) return try errorResponseAlloc(allocator, null, "invalid_request", "request must be a JSON object");
    const id_value = root.object.get("id") orelse .null;
    const method = jsonString(root.object.get("method") orelse .null) orelse
        return try errorResponseAlloc(allocator, id_value, "invalid_request", "missing method");
    const params = root.object.get("params") orelse .null;

    if (std.mem.eql(u8, method, "status")) return try statusResponse(allocator, id_value, state);
    if (std.mem.eql(u8, method, "capabilities")) return try capabilitiesResponse(allocator, id_value);
    if (std.mem.eql(u8, method, "workspaces") or std.mem.eql(u8, method, "projects")) return try workspacesResponse(allocator, id_value, state);
    if (std.mem.eql(u8, method, "panes")) return try panesResponse(allocator, id_value, state, params);
    if (std.mem.eql(u8, method, "active")) return try activeResponse(allocator, id_value, state);
    if (std.mem.eql(u8, method, "threads")) return try threadsResponse(allocator, id_value, state, params);
    if (std.mem.eql(u8, method, "terminals")) return try terminalsResponse(allocator, id_value, state, params);
    if (std.mem.eql(u8, method, "herdr.open")) return try herdrOpenResponse(allocator, id_value, state, params);
    if (std.mem.eql(u8, method, "herdr.handoff")) return try herdrHandoffResponse(allocator, id_value, state, params);
    if (std.mem.eql(u8, method, "herdr.unlink")) return try herdrUnlinkResponse(allocator, id_value, state, params);
    if (std.mem.eql(u8, method, "herdr.status")) return try herdrStatusResponse(allocator, id_value, state);
    if (std.mem.eql(u8, method, "surfaces") or std.mem.eql(u8, method, "surface.list")) return try surfacesResponse(allocator, id_value, state, params);
    if (std.mem.eql(u8, method, "surface.inspect")) return try surfaceInspectResponse(allocator, id_value, state, params);
    if (std.mem.eql(u8, method, "surface.focus")) return try surfaceFocusResponse(allocator, id_value, state, params);
    if (std.mem.eql(u8, method, "surface.clearAttention")) return try surfaceClearAttentionResponse(allocator, id_value, state, params);
    if (std.mem.eql(u8, method, "notification.create") or std.mem.eql(u8, method, "notification.update")) return try notificationUpdateResponse(allocator, id_value, state, params);
    if (std.mem.eql(u8, method, "notification.clear")) return try notificationClearResponse(allocator, id_value, state, params);
    if (std.mem.eql(u8, method, "processes")) return try workspaceProcessesResponse(allocator, id_value, state, params);
    if (std.mem.eql(u8, method, "inspect")) return try inspectResponse(allocator, id_value, state, params);
    if (std.mem.startsWith(u8, method, "workspace.")) return try workspaceCommandResponse(allocator, id_value, state, params, method["workspace.".len..]);
    if (std.mem.startsWith(u8, method, "pane.")) return try paneCommandResponse(allocator, id_value, state, params, method["pane.".len..]);
    if (std.mem.startsWith(u8, method, "chat.")) return try chatCommandResponse(allocator, id_value, state, params, method["chat.".len..]);
    if (std.mem.startsWith(u8, method, "browser.")) return try browserCommandResponse(allocator, id_value, state, params, method["browser.".len..]);
    if (std.mem.startsWith(u8, method, "palette.")) return try paletteCommandResponse(allocator, id_value, state, params, method["palette.".len..]);
    if (std.mem.startsWith(u8, method, "terminal.")) return try terminalCommandResponse(allocator, id_value, state, params, method["terminal.".len..]);
    if (std.mem.startsWith(u8, method, "process.")) return try processCommandResponse(allocator, id_value, state, params, method["process.".len..]);
    if (std.mem.startsWith(u8, method, "agent.")) return try agentCommandResponse(allocator, id_value, state, params, method["agent.".len..]);
    if (std.mem.startsWith(u8, method, "stack.")) return try stackCommandResponse(allocator, id_value, state, params, method["stack.".len..]);

    return try errorResponseAlloc(allocator, id_value, "method_not_found", method);
}

fn statusResponse(allocator: std.mem.Allocator, id_value: std.json.Value, state: *app_state.AppState) ![]u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    var s: std.json.Stringify = .{ .writer = &writer.writer, .options = .{} };
    try beginOk(&s, id_value);
    try s.objectField("result");
    try s.beginObject();
    try s.objectField("protocol_version");
    try s.write(PROTOCOL_VERSION);
    try s.objectField("pid");
    try s.write(platform_runtime.processId());
    try s.objectField("workspace_count");
    try s.write(state.project_controller.projects.items.len);
    try s.objectField("selected_workspace_index");
    try s.write(state.project_controller.selected_index);
    try s.objectField("focused_pane_id");
    if (state.project_controller.projects.items.len > 0) {
        if (state.project_controller.projects.items[state.project_controller.selected_index].workspace_layout.focused_pane_id) |pane_id| try s.write(pane_id) else try s.write(null);
    } else {
        try s.write(null);
    }
    try s.objectField("pending_send_count");
    try s.write(state.pendingSendCount());
    try s.objectField("focus");
    try writeFocusStatus(&s, state);
    try s.objectField("browser");
    try writeBrowserStatus(&s, state);
    try s.objectField("panes");
    try writeSelectedProjectPanes(&s, state);
    try s.objectField("terminals");
    try writeTerminalsArray(&s, state, null);
    try s.objectField("processes");
    try writeManagedProcessesArray(&s, state, null);
    try s.endObject();
    try s.endObject();
    return try writer.toOwnedSlice();
}

fn writeFocusStatus(s: *std.json.Stringify, state: *app_state.AppState) !void {
    try s.beginObject();
    try s.objectField("browser_pane_focused");
    try s.write(state.isBrowserPaneFocused());
    try s.objectField("native_browser_surface_focused");
    try s.write(state.isNativeBrowserSurfaceFocused());
    try s.objectField("browser_address_focused");
    try s.write(state.browser_controller.address_focused);
    try s.objectField("composer_focused");
    try s.write(state.composer_controller.focused);
    try s.objectField("terminal_focused");
    try s.write(state.terminal_controller.focused);
    try s.objectField("palette_modal_text_focus");
    try s.write(state.paletteModalTextFocusName());
    try s.endObject();
}

fn writeBrowserStatus(s: *std.json.Stringify, state: *app_state.AppState) !void {
    const browser = state.browserStateConst();
    const location = state.browserWorkspaceLocation();
    try s.beginObject();
    try s.objectField("runtime_kind");
    try s.write(@tagName(browser.controller.runtimeKind()));
    try s.objectField("presentation_kind");
    try s.write(@tagName(browser.controller.presentationKind()));
    try s.objectField("runtime_initialized");
    try s.write(browser.controller.runtimeInitialized());
    try s.objectField("capabilities");
    try s.beginObject();
    try s.objectField("restart");
    try s.write(true);
    try s.objectField("reset");
    try s.write(true);
    try s.objectField("low_level_pointer");
    try s.write(browser.controller.supportsLowLevelPointer());
    try s.objectField("javascript_eval");
    try s.write(browser.controller.supportsEval());
    try s.objectField("explicit_waits");
    try s.write(false);
    try s.objectField("diagnostics");
    try s.write(false);
    try s.objectField("viewport_emulation");
    try s.write(false);
    try s.objectField("cache_control");
    try s.write(false);
    try s.endObject();
    try s.objectField("status");
    try s.write(browser.statusLabel());
    try s.objectField("visible");
    try s.write(state.isBrowserRuntimeActive());
    try s.objectField("suspended");
    try s.write(state.isBrowserSurfaceSuspendedForLayout() or state.isBrowserSurfaceSuspendedForPaletteOverlay() or state.isBrowserSurfaceSuspendedForEmptyState());
    try s.objectField("workspace_index");
    if (location) |loc| try s.write(loc.index) else try s.write(null);
    try s.objectField("workspace_id");
    if (location) |loc| try s.write(state.project_controller.projects.items[loc.index].id) else try s.write(null);
    try s.objectField("pane_id");
    if (location) |loc| try s.write(loc.pane_id) else try s.write(null);
    try s.objectField("pane_focused");
    try s.write(state.isBrowserPaneFocused());
    try s.objectField("address_focused");
    try s.write(state.browser_controller.address_focused);
    try s.objectField("url");
    if (browser.current_url) |url| try s.write(url) else try s.write(null);
    try s.objectField("address");
    try s.write(browser.addressInput());
    try s.objectField("inspector_enabled");
    try s.write(browser.inspectorEnabled());
    try s.objectField("inspector_mode");
    try s.write(browser.inspectorMode().jsValue());
    try s.objectField("inspector_menu_open");
    try s.write(state.isBrowserInspectorMenuOpen());
    try s.objectField("surface_suspended_for_palette_overlay");
    try s.write(state.isBrowserSurfaceSuspendedForPaletteOverlay());
    try s.objectField("surface_suspended_for_layout");
    try s.write(state.isBrowserSurfaceSuspendedForLayout());
    try s.objectField("surface_suspended_for_empty_state");
    try s.write(state.isBrowserSurfaceSuspendedForEmptyState());
    try s.objectField("workspace_header_open_menu_open");
    try s.write(state.isWorkspaceHeaderOpenMenuOpen());
    try s.objectField("sidebar_context_menu_open");
    try s.write(state.isSidebarContextMenuOpen());
    try s.objectField("composer_menu_open");
    try s.write(state.isComposerMenuOpen());
    try s.objectField("workspace_import_modal_open");
    try s.write(state.isProjectImportModalOpen());
    try s.objectField("thread_import_modal_open");
    try s.write(state.isThreadImportModalOpen());
    try s.objectField("image_modal_open");
    try s.write(state.isImageModalOpen());
    try s.objectField("transcript_selection_modal_open");
    try s.write(state.isTranscriptSelectionModalOpen());
    try s.objectField("palette_modal_text_focus");
    try s.write(state.paletteModalTextFocusName());
    try s.objectField("last_error");
    if (browser.last_error) |message| try s.write(message) else try s.write(null);
    try s.objectField("last_js_message");
    if (browser.last_js_message) |message| try s.write(message) else try s.write(null);
    try s.objectField("last_eval_result");
    if (browser.last_eval_result) |result| try s.write(result) else try s.write(null);
    if (browser.controller.macosAppKitDiagnostics(state.allocator)) |diagnostics| {
        defer state.allocator.free(diagnostics);
        try s.objectField("macos_appkit_diagnostics");
        try s.write(diagnostics);
    }
    try s.endObject();
}

fn browserStatusResponse(allocator: std.mem.Allocator, id_value: std.json.Value, state: *app_state.AppState) ![]u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    var s: std.json.Stringify = .{ .writer = &writer.writer, .options = .{} };
    try beginOk(&s, id_value);
    try s.objectField("result");
    try writeBrowserStatus(&s, state);
    try s.endObject();
    return try writer.toOwnedSlice();
}

fn capabilitiesResponse(allocator: std.mem.Allocator, id_value: std.json.Value) ![]u8 {
    return try okValueResponse(allocator, id_value, .{
        .protocol_version = PROTOCOL_VERSION,
        .commands = &.{
            "status",                             "capabilities",                        "workspaces",                          "panes",
            "active",                             "inspect",                             "threads",                             "terminals",
            "herdr.open",                         "herdr.handoff",                       "herdr.unlink",                        "herdr.status",
            "surfaces",                           "surface.list",                        "surface.inspect",                     "surface.focus",
            "surface.clearAttention",             "notification.create",                 "notification.update",                 "notification.clear",
            "processes",                          "workspace.select",                    "workspace.create",                    "workspace.rename",
            "workspace.close",                    "workspace.reopen",                    "workspace.archive",                   "pane.focus",
            "pane.split",                         "pane.resize",                         "pane.move",                           "pane.maximize",
            "pane.close",                         "chat.open",                           "chat.status",                         "chat.transcript",
            "chat.draft.set",                     "chat.draft.append",                   "chat.send",                           "chat.followup",
            "chat.stop",                          "chat.approve",                        "browser.open",                        "browser.navigate",
            "browser.status",                     "browser.close",                       "browser.toggle",                      "browser.back",
            "browser.forward",                    "browser.reload",                      "browser.focus",                       "browser.blur",
            "browser.restart",                    "browser.reset",                       "browser.pointerDown",                 "browser.pointerMove",
            "browser.pointerUp",                  "browser.toolbarHit",                  "browser.selectAllFocused",            "browser.copyFocused",
            "browser.pasteTextFocused",           "browser.eval",                        "browser.postJson",                    "browser.screenshot",
            "browser.inspector.enable",           "browser.inspector.disable",           "browser.inspector.toggle",            "browser.inspector.mode",
            "browser.inspector.menuOpen",         "browser.inspector.menuClose",         "browser.overlay.workspaceMenuOpen",   "browser.overlay.workspaceMenuClose",
            "browser.overlay.sidebarMenuOpen",    "browser.overlay.sidebarMenuClose",    "browser.overlay.composerMenuOpen",    "browser.overlay.composerMenuClose",
            "browser.overlay.workspaceModalOpen", "browser.overlay.workspaceModalClose", "browser.overlay.threadModalOpen",     "browser.overlay.threadModalClose",
            "browser.overlay.imageModalOpen",     "browser.overlay.imageModalClose",     "browser.overlay.transcriptModalOpen", "browser.overlay.transcriptModalClose",
            "palette.list",                       "palette.run",                         "terminal.write",                      "terminal.key",
            "terminal.tail",                      "terminal.screen",                     "process.list",                        "process.inspect",
            "process.start",                      "process.stop",                        "process.restart",                     "process.logs",
            "agent.open",                         "stack.status",                        "stack.start",                         "stack.stop",
            "stack.restart",                      "workspace.processes",                 "workspace.checkCommand",              "workspace.acquireLease",
            "workspace.releaseLease",
        },
        .events = &.{},
        .encodings = &.{"json"},
        .terminal_binary_frames = false,
        .mcp_bridge = true,
        .auth = "local-user-socket",
    });
}

fn workspacesResponse(allocator: std.mem.Allocator, id_value: std.json.Value, state: *app_state.AppState) ![]u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    var s: std.json.Stringify = .{ .writer = &writer.writer, .options = .{} };
    try beginOk(&s, id_value);
    try s.objectField("result");
    try s.beginObject();
    try s.objectField("selected_workspace_index");
    try s.write(state.project_controller.selected_index);
    try s.objectField("workspaces");
    try s.beginArray();
    for (state.project_controller.projects.items, 0..) |project, index| {
        try s.beginObject();
        try s.objectField("index");
        try s.write(index);
        try s.objectField("id");
        try s.write(project.id);
        try s.objectField("label");
        try s.write(project.label);
        try s.objectField("path");
        try s.write(project.path);
        try s.objectField("archived");
        try s.write(project.archived);
        try s.objectField("thread_count");
        try s.write(project.threads.items.len);
        try s.objectField("pane_count");
        try s.write(project.workspace_layout.panes.items.len);
        try s.endObject();
    }
    try s.endArray();
    try s.objectField("closed_workspaces");
    try s.beginArray();
    for (state.project_controller.archived_projects.items, 0..) |project, index| {
        try s.beginObject();
        try s.objectField("index");
        try s.write(index);
        try s.objectField("id");
        try s.write(project.id);
        try s.objectField("label");
        try s.write(project.label);
        try s.objectField("path");
        try s.write(project.path);
        try s.objectField("closed");
        try s.write(true);
        try s.objectField("thread_count");
        try s.write(project.threads.items.len);
        try s.objectField("pane_count");
        try s.write(project.workspace_layout.panes.items.len);
        try s.endObject();
    }
    try s.endArray();
    try s.endObject();
    try s.endObject();
    return try writer.toOwnedSlice();
}

fn panesResponse(allocator: std.mem.Allocator, id_value: std.json.Value, state: *app_state.AppState, params: std.json.Value) ![]u8 {
    const project_index = resolveProjectIndex(state, params) orelse
        return try errorResponseAlloc(allocator, id_value, "not_found", "workspace not found");
    return try panesResponseForProject(allocator, id_value, state, project_index);
}

fn panesResponseForProject(allocator: std.mem.Allocator, id_value: std.json.Value, state: *app_state.AppState, project_index: usize) ![]u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    var s: std.json.Stringify = .{ .writer = &writer.writer, .options = .{} };
    try beginOk(&s, id_value);
    try s.objectField("result");
    try writeProjectPanes(&s, state, project_index);
    try s.endObject();
    return try writer.toOwnedSlice();
}

fn activeResponse(allocator: std.mem.Allocator, id_value: std.json.Value, state: *app_state.AppState) ![]u8 {
    if (state.project_controller.projects.items.len == 0) return try errorResponseAlloc(allocator, id_value, "not_found", "no workspaces");
    const project = &state.project_controller.projects.items[state.project_controller.selected_index];
    return try okValueResponse(allocator, id_value, .{
        .workspace_index = state.project_controller.selected_index,
        .workspace_id = project.id,
        .focused_pane_id = project.workspace_layout.focused_pane_id,
        .maximized_pane_id = project.workspace_layout.maximized_pane_id,
    });
}

fn threadsResponse(allocator: std.mem.Allocator, id_value: std.json.Value, state: *app_state.AppState, params: std.json.Value) ![]u8 {
    const project_index = resolveProjectIndex(state, params) orelse
        return try errorResponseAlloc(allocator, id_value, "not_found", "workspace not found");
    const project = &state.project_controller.projects.items[project_index];

    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    var s: std.json.Stringify = .{ .writer = &writer.writer, .options = .{} };
    try beginOk(&s, id_value);
    try s.objectField("result");
    try s.beginObject();
    try s.objectField("workspace_index");
    try s.write(project_index);
    try s.objectField("selected_thread_index");
    try s.write(project.selected_thread_index);
    try s.objectField("threads");
    try s.beginArray();
    for (project.threads.items, 0..) |thread, index| {
        try writeThreadSummary(&s, thread, index);
    }
    try s.endArray();
    try s.endObject();
    try s.endObject();
    return try writer.toOwnedSlice();
}

fn terminalsResponse(allocator: std.mem.Allocator, id_value: std.json.Value, state: *app_state.AppState, params: std.json.Value) ![]u8 {
    const project_index = resolveProjectIndexNullable(state, params);
    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    var s: std.json.Stringify = .{ .writer = &writer.writer, .options = .{} };
    try beginOk(&s, id_value);
    try s.objectField("result");
    try s.beginObject();
    try s.objectField("terminals");
    try writeTerminalsArray(&s, state, project_index);
    try s.endObject();
    try s.endObject();
    return try writer.toOwnedSlice();
}

fn herdrOpenResponse(allocator: std.mem.Allocator, id_value: std.json.Value, state: *app_state.AppState, params: std.json.Value) ![]u8 {
    if (params != .object) return try errorResponseAlloc(allocator, id_value, "invalid_request", "herdr.open requires params");
    const session = stringParam(params, "session") orelse
        return try errorResponseAlloc(allocator, id_value, "invalid_request", "herdr.open requires session");
    const workspace = stringParam(params, "herdr_workspace") orelse stringParam(params, "herdr-workspace") orelse
        return try errorResponseAlloc(allocator, id_value, "invalid_request", "herdr.open requires herdr_workspace");
    const request: herdr.OpenRequest = .{
        .session = session,
        .herdr_workspace = workspace,
        .remote = stringParam(params, "remote"),
        .cwd = stringParam(params, "cwd"),
        .remote_cwd = stringParam(params, "remote_cwd") orelse stringParam(params, "remote-cwd"),
        .local_dir = stringParam(params, "local_dir") orelse stringParam(params, "local-dir"),
        .pane = stringParam(params, "pane"),
    };
    const result = state.openOrCreateHerdrWorkspace(request) catch |err| switch (err) {
        error.MissingHerdrSession, error.MissingHerdrWorkspace, error.EmptyProjectPath => return try errorResponseAlloc(allocator, id_value, "invalid_request", @errorName(err)),
        error.FileNotFound, error.NotDir, error.AccessDenied => return try errorResponseAlloc(allocator, id_value, "not_found", "workspace directory not found"),
        else => return try errorResponseAlloc(allocator, id_value, "internal_error", @errorName(err)),
    };
    return try okValueResponse(allocator, id_value, result);
}

fn herdrHandoffResponse(allocator: std.mem.Allocator, id_value: std.json.Value, state: *app_state.AppState, params: std.json.Value) ![]u8 {
    if (params != .object) return try errorResponseAlloc(allocator, id_value, "invalid_request", "herdr.handoff requires params");
    const request: herdr.HandoffRequest = .{
        .session = stringParam(params, "session") orelse "default",
        .remote = stringParam(params, "remote"),
        .remote_cwd = stringParam(params, "remote_cwd") orelse stringParam(params, "remote-cwd"),
        .workspace = stringParam(params, "workspace") orelse stringParam(params, "project"),
        .all = boolParam(params, "all") orelse false,
        .dry_run = boolParam(params, "dry_run") orelse boolParam(params, "dry-run") orelse false,
    };
    var result = state.handoffHerdrWorkspaces(allocator, request) catch |err| switch (err) {
        error.MissingHerdrSession, error.EmptyHerdrWorkspaceSelector => return try errorResponseAlloc(allocator, id_value, "invalid_request", @errorName(err)),
        error.NoProjectSelected => return try errorResponseAlloc(allocator, id_value, "not_found", "workspace not found"),
        error.HerdrCommandFailed => return try errorResponseAlloc(allocator, id_value, "rejected", "Herdr command failed"),
        error.InvalidHerdrResponse => return try errorResponseAlloc(allocator, id_value, "rejected", "Herdr returned an unexpected response"),
        else => return try errorResponseAlloc(allocator, id_value, "internal_error", @errorName(err)),
    };
    defer result.deinit(allocator);
    return try okValueResponse(allocator, id_value, result);
}

fn herdrUnlinkResponse(allocator: std.mem.Allocator, id_value: std.json.Value, state: *app_state.AppState, params: std.json.Value) ![]u8 {
    if (params != .object) return try errorResponseAlloc(allocator, id_value, "invalid_request", "herdr.unlink requires params");
    const request: herdr.UnlinkRequest = .{
        .workspace = stringParam(params, "workspace") orelse stringParam(params, "project"),
        .all = boolParam(params, "all") orelse false,
    };
    var result = state.unlinkHerdrWorkspaces(allocator, request) catch |err| switch (err) {
        error.AmbiguousHerdrWorkspaceSelector, error.EmptyHerdrWorkspaceSelector => return try errorResponseAlloc(allocator, id_value, "invalid_request", @errorName(err)),
        error.NoProjectSelected => return try errorResponseAlloc(allocator, id_value, "not_found", "workspace not found"),
        else => return try errorResponseAlloc(allocator, id_value, "internal_error", @errorName(err)),
    };
    defer result.deinit(allocator);
    return try okValueResponse(allocator, id_value, result);
}

fn herdrStatusResponse(allocator: std.mem.Allocator, id_value: std.json.Value, state: *app_state.AppState) ![]u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    var s: std.json.Stringify = .{ .writer = &writer.writer, .options = .{} };
    try beginOk(&s, id_value);
    try s.objectField("result");
    try s.beginObject();
    try s.objectField("workspace_count");
    try s.write(state.project_controller.projects.items.len);
    try s.objectField("links");
    try s.beginArray();
    for (state.project_controller.projects.items, 0..) |*project, index| {
        const link = project.herdr_link orelse continue;
        try writeHerdrStatusLink(&s, state, project, index, link);
    }
    try s.endArray();
    try s.endObject();
    try s.endObject();
    return try writer.toOwnedSlice();
}

fn writeHerdrStatusLink(
    s: *std.json.Stringify,
    state: *app_state.AppState,
    project: *const app_state.Project,
    project_index: usize,
    link: app_state.HerdrWorkspaceLink,
) !void {
    try s.beginObject();
    try s.objectField("workspace_index");
    try s.write(project_index);
    try s.objectField("workspace_id");
    try s.write(project.id);
    try s.objectField("label");
    try s.write(project.label);
    try s.objectField("path");
    try s.write(project.path);
    try s.objectField("remote");
    try s.write(link.remote_alias);
    try s.objectField("session");
    try s.write(link.session_name);
    try s.objectField("herdr_workspace");
    try s.write(link.workspace_id);
    try s.objectField("remote_cwd");
    if (link.remote_cwd) |value| try s.write(value) else try s.write(null);
    try s.objectField("herdr_pane");
    if (link.last_pane_id) |value| try s.write(value) else try s.write(null);
    try s.objectField("terminal_dock_id");
    if (link.attach_dock_id) |value| try s.write(value) else try s.write(null);
    try s.objectField("terminal_pane_id");
    if (link.attach_pane_id) |value| try s.write(value) else try s.write(null);
    try s.objectField("terminal_running");
    if (link.attach_dock_id) |dock_id| {
        if (state.projectTerminalDock(project_index, dock_id)) |dock| {
            try s.write(dock.hasRunningSession());
        } else {
            try s.write(false);
        }
    } else {
        try s.write(false);
    }
    try s.objectField("pane_links");
    try writeHerdrPaneLinks(s, link.pane_links.items);
    try s.objectField("updated_at_ms");
    try s.write(link.updated_at_ms);
    try s.endObject();
}

fn writeHerdrPaneLinks(s: *std.json.Stringify, pane_links: []const app_state.HerdrPaneLink) !void {
    try s.beginArray();
    for (pane_links) |pane_link| {
        try s.beginObject();
        try s.objectField("verde_pane_id");
        try s.write(pane_link.verde_pane_id);
        try s.objectField("herdr_tab_id");
        if (pane_link.herdr_tab_id) |value| try s.write(value) else try s.write(null);
        try s.objectField("herdr_pane_id");
        if (pane_link.herdr_pane_id) |value| try s.write(value) else try s.write(null);
        try s.objectField("provider");
        try s.write(@tagName(pane_link.provider));
        try s.objectField("presentation");
        try s.write(@tagName(pane_link.presentation));
        try s.objectField("provider_thread_id");
        if (pane_link.provider_thread_id) |value| try s.write(value) else try s.write(null);
        try s.objectField("provider_session_ref");
        if (pane_link.provider_session_ref) |value| try s.write(value) else try s.write(null);
        try s.objectField("cwd");
        if (pane_link.cwd) |value| try s.write(value) else try s.write(null);
        try s.objectField("title");
        if (pane_link.title) |value| try s.write(value) else try s.write(null);
        try s.objectField("updated_at_ms");
        try s.write(pane_link.updated_at_ms);
        try s.endObject();
    }
    try s.endArray();
}

fn surfacesResponse(allocator: std.mem.Allocator, id_value: std.json.Value, state: *app_state.AppState, params: std.json.Value) ![]u8 {
    _ = params;
    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    var s: std.json.Stringify = .{ .writer = &writer.writer, .options = .{} };
    try beginOk(&s, id_value);
    try s.objectField("result");
    try s.beginObject();
    try s.objectField("surfaces");
    try s.beginArray();
    for (state.surface_controller.surfaces.items) |*surface| try writeSurface(&s, surface);
    try s.endArray();
    try s.endObject();
    try s.endObject();
    return try writer.toOwnedSlice();
}

fn surfaceInspectResponse(allocator: std.mem.Allocator, id_value: std.json.Value, state: *app_state.AppState, params: std.json.Value) ![]u8 {
    const session_id = stringParam(params, "session_id") orelse stringParam(params, "session") orelse
        return try errorResponseAlloc(allocator, id_value, "invalid_request", "surface.inspect requires session_id");
    const surface = state.surfaceBySessionId(session_id) orelse
        return try errorResponseAlloc(allocator, id_value, "not_found", "surface not found");
    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    var s: std.json.Stringify = .{ .writer = &writer.writer, .options = .{} };
    try beginOk(&s, id_value);
    try s.objectField("result");
    try s.beginObject();
    try s.objectField("surface");
    try writeSurface(&s, surface);
    try s.endObject();
    try s.endObject();
    return try writer.toOwnedSlice();
}

fn surfaceFocusResponse(allocator: std.mem.Allocator, id_value: std.json.Value, state: *app_state.AppState, params: std.json.Value) ![]u8 {
    const session_id = stringParam(params, "session_id") orelse stringParam(params, "session") orelse
        return try errorResponseAlloc(allocator, id_value, "invalid_request", "surface.focus requires session_id");
    const surface = state.surfaceBySessionId(session_id) orelse
        return try errorResponseAlloc(allocator, id_value, "not_found", "surface not found");
    const pane_id = surface.pane_id orelse return try errorResponseAlloc(allocator, id_value, "not_found", "surface has no pane");
    const project_index = resolveSurfaceProjectIndex(state, surface) orelse
        return try errorResponseAlloc(allocator, id_value, "not_found", "surface workspace not found");
    state.project_controller.selected_index = project_index;
    const changed = state.focusCurrentProjectWorkspacePane(pane_id);
    _ = state.clearSurfaceAttentionBySession(session_id);
    return try okValueResponse(allocator, id_value, .{ .session_id = session_id, .workspace_index = project_index, .pane_id = pane_id, .focused = changed });
}

fn surfaceClearAttentionResponse(allocator: std.mem.Allocator, id_value: std.json.Value, state: *app_state.AppState, params: std.json.Value) ![]u8 {
    const session_id = stringParam(params, "session_id") orelse stringParam(params, "session") orelse
        return try errorResponseAlloc(allocator, id_value, "invalid_request", "surface.clearAttention requires session_id");
    const changed = state.clearSurfaceAttentionBySession(session_id);
    return try okValueResponse(allocator, id_value, .{ .session_id = session_id, .changed = changed });
}

fn notificationUpdateResponse(allocator: std.mem.Allocator, id_value: std.json.Value, state: *app_state.AppState, params: std.json.Value) ![]u8 {
    const session_id = stringParam(params, "session_id") orelse stringParam(params, "session") orelse
        return try errorResponseAlloc(allocator, id_value, "invalid_request", "notification requires session_id");
    const status = if (stringParam(params, "status")) |value| parseSurfaceStatus(value) orelse
        return try errorResponseAlloc(allocator, id_value, "invalid_request", "invalid surface status") else null;
    const status_requests_attention = if (status) |value| value == .waiting or value == .@"error" else false;
    const requested_attention = boolParam(params, "attention") orelse if (status_requests_attention) true else null;
    const proof = surfaceCommitProof(params);
    const status_changed_at_ms = intParam(params, "store_status_changed_at_ms");
    const completed_at_ms = intParam(params, "store_completed_at_ms");
    const durability: app_state.SurfaceDurability = if (proof) |commit_proof| verified: {
        const status_value = status orelse break :verified .durable;
        if (status_changed_at_ms == null or completed_at_ms == null) break :verified .durable;
        if (status_value == .idle) {
            switch (state.storage.classifySurfaceClearCommitProof(commit_proof, session_id) catch .invalid) {
                .current => break :verified .presentation_only,
                .superseded => return try supersededSurfaceResponse(allocator, id_value, session_id),
                .invalid => break :verified .durable,
            }
        }
        const provider_value = if (stringParam(params, "provider")) |value|
            if (parseSurfaceProvider(value)) |parsed| @tagName(parsed) else null
        else
            null;
        const durable_surface: headless.store.SurfaceState = .{
            .session_id = session_id,
            .workspace_id = stringParam(params, "workspace_id") orelse stringParam(params, "workspace") orelse "",
            .workspace_path = stringParam(params, "workspace_path") orelse "",
            .dock_id = u32Param(params, "dock_id") orelse u32Param(params, "dock") orelse 0,
            .pane_id = u32Param(params, "pane_id") orelse u32Param(params, "pane"),
            .provider = provider_value,
            .provider_thread_id = stringParam(params, "provider_thread_id"),
            .title = stringParam(params, "label") orelse stringParam(params, "title") orelse "",
            .status = @tagName(status_value),
            .status_changed_at_ms = status_changed_at_ms.?,
            .completed_at_ms = completed_at_ms.?,
            .last_event_title = stringParam(params, "title") orelse stringParam(params, "label"),
            .last_event_body = stringParam(params, "body"),
        };
        switch (state.storage.classifySurfaceUpsertCommitProof(commit_proof, durable_surface) catch .invalid) {
            .current => {
                // Focus acknowledgement clears presentation before its
                // targeted Store clear finishes. Replaying that exact receipt
                // must not resurrect the completion during this window.
                const canonical = state_storage.protocolSurfaceToPersisted(durable_surface) orelse break :verified .durable;
                if (status_value == .done and state.containsSurfaceCompletionAcknowledgement(canonical)) {
                    return try supersededSurfaceResponse(allocator, id_value, session_id);
                }
                break :verified .presentation_only;
            },
            .superseded => return try supersededSurfaceResponse(allocator, id_value, session_id),
            .invalid => break :verified .durable,
        }
    } else .durable;
    const surface = try state.updateSurface(.{
        .session_id = session_id,
        .workspace_id = stringParam(params, "workspace_id") orelse stringParam(params, "workspace"),
        .workspace_path = stringParam(params, "workspace_path"),
        .dock_id = u32Param(params, "dock_id") orelse u32Param(params, "dock"),
        .pane_id = u32Param(params, "pane_id") orelse u32Param(params, "pane"),
        .provider = if (stringParam(params, "provider")) |value| parseSurfaceProvider(value) else null,
        .provider_thread_id = stringParam(params, "provider_thread_id"),
        .title = stringParam(params, "label") orelse stringParam(params, "title"),
        .status = status,
        .progress = floatParam(params, "progress"),
        .attention = requested_attention,
        .unread_increment = if (requested_attention orelse false) 1 else 0,
        .last_event_title = stringParam(params, "title") orelse stringParam(params, "label"),
        .last_event_body = stringParam(params, "body"),
        .status_changed_at_ms = if (durability == .presentation_only) status_changed_at_ms else null,
        .completed_at_ms = if (durability == .presentation_only) completed_at_ms else null,
        .durability = durability,
    });
    return try surfaceResultResponse(allocator, id_value, surface);
}

fn notificationClearResponse(allocator: std.mem.Allocator, id_value: std.json.Value, state: *app_state.AppState, params: std.json.Value) ![]u8 {
    const session_id = stringParam(params, "session_id") orelse stringParam(params, "session") orelse
        return try errorResponseAlloc(allocator, id_value, "invalid_request", "notification.clear requires session_id");
    const durability: app_state.SurfaceDurability = if (surfaceCommitProof(params)) |proof| classified: {
        switch (state.storage.classifySurfaceClearCommitProof(proof, session_id) catch .invalid) {
            .current => break :classified .presentation_only,
            .superseded => return try supersededSurfaceResponse(allocator, id_value, session_id),
            .invalid => break :classified .durable,
        }
    } else .durable;
    const surface = try state.updateSurface(.{
        .session_id = session_id,
        .clear = true,
        .durability = durability,
    });
    return try surfaceResultResponse(allocator, id_value, surface);
}

fn inspectResponse(allocator: std.mem.Allocator, id_value: std.json.Value, state: *app_state.AppState, params: std.json.Value) ![]u8 {
    const target = resolvePaneTarget(state, params) orelse
        return try errorResponseAlloc(allocator, id_value, "not_found", "pane not found");
    return try inspectPaneResponse(allocator, id_value, state, target.project_index, target.pane_id);
}

fn workspaceCommandResponse(allocator: std.mem.Allocator, id_value: std.json.Value, state: *app_state.AppState, params: std.json.Value, command: []const u8) ![]u8 {
    if (std.mem.eql(u8, command, "processes")) {
        return try workspaceProcessesResponse(allocator, id_value, state, params);
    }
    if (std.mem.eql(u8, command, "checkCommand")) {
        return try workspaceCheckCommandResponse(allocator, id_value, state, params, false);
    }
    if (std.mem.eql(u8, command, "acquireLease")) {
        return try workspaceAcquireLeaseResponse(allocator, id_value, state, params);
    }
    if (std.mem.eql(u8, command, "releaseLease")) {
        return try workspaceReleaseLeaseResponse(allocator, id_value, state, params);
    }
    if (std.mem.eql(u8, command, "select")) {
        const project_index = resolveProjectIndex(state, params) orelse
            return try errorResponseAlloc(allocator, id_value, "not_found", "workspace not found");
        if (!state.selectProjectAtIndex(project_index)) return try errorResponseAlloc(allocator, id_value, "rejected", "workspace select did not apply");
        return try workspacesResponse(allocator, id_value, state);
    }

    if (std.mem.eql(u8, command, "create")) {
        const path = stringParam(params, "path") orelse
            return try errorResponseAlloc(allocator, id_value, "invalid_request", "workspace.create requires path");
        _ = state.createProjectFromPath(path) catch |err| switch (err) {
            error.EmptyProjectPath => return try errorResponseAlloc(allocator, id_value, "invalid_request", "workspace path cannot be empty"),
            error.ProjectAlreadyExists => return try errorResponseAlloc(allocator, id_value, "rejected", "workspace already exists"),
            error.FileNotFound, error.NotDir, error.AccessDenied => return try errorResponseAlloc(allocator, id_value, "not_found", "workspace path not found"),
            else => return try errorResponseAlloc(allocator, id_value, "internal_error", @errorName(err)),
        };
        return try workspacesResponse(allocator, id_value, state);
    }

    if (std.mem.eql(u8, command, "rename")) {
        const project_index = resolveProjectIndex(state, params) orelse
            return try errorResponseAlloc(allocator, id_value, "not_found", "workspace not found");
        const label = stringParam(params, "label") orelse stringParam(params, "name") orelse
            return try errorResponseAlloc(allocator, id_value, "invalid_request", "workspace.rename requires label");
        state.renameProjectAtIndex(project_index, label) catch |err| switch (err) {
            error.ProjectNotFound => return try errorResponseAlloc(allocator, id_value, "not_found", "workspace not found"),
            error.EmptyProjectName => return try errorResponseAlloc(allocator, id_value, "invalid_request", "workspace name cannot be empty"),
            else => return try errorResponseAlloc(allocator, id_value, "internal_error", @errorName(err)),
        };
        return try workspacesResponse(allocator, id_value, state);
    }

    if (std.mem.eql(u8, command, "close") or std.mem.eql(u8, command, "archive")) {
        const project_index = resolveProjectIndex(state, params) orelse
            return try errorResponseAlloc(allocator, id_value, "not_found", "workspace not found");
        if (!state.closeProjectAtIndexResult(project_index)) {
            return try errorResponseAlloc(allocator, id_value, "rejected", "workspace close did not apply");
        }
        return try workspacesResponse(allocator, id_value, state);
    }

    if (std.mem.eql(u8, command, "reopen")) {
        const archived_index = resolveClosedProjectIndex(state, params) orelse
            return try errorResponseAlloc(allocator, id_value, "not_found", "closed workspace not found");
        if (!state.reopenClosedProjectAtIndex(archived_index)) {
            return try errorResponseAlloc(allocator, id_value, "rejected", "workspace reopen did not apply");
        }
        return try workspacesResponse(allocator, id_value, state);
    }

    return try errorResponseAlloc(allocator, id_value, "method_not_found", command);
}

fn paneCommandResponse(allocator: std.mem.Allocator, id_value: std.json.Value, state: *app_state.AppState, params: std.json.Value, command: []const u8) ![]u8 {
    const target = resolvePaneTarget(state, params) orelse
        return try errorResponseAlloc(allocator, id_value, "not_found", "pane not found");

    var changed = false;
    if (std.mem.eql(u8, command, "focus")) {
        changed = state.focusWorkspacePane(target.project_index, target.pane_id);
    } else if (std.mem.eql(u8, command, "split")) {
        const kind = stringParam(params, "kind") orelse return try errorResponseAlloc(allocator, id_value, "invalid_request", "pane.split requires kind");
        const axis = parseAxis(stringParam(params, "axis") orelse "horizontal") orelse
            return try errorResponseAlloc(allocator, id_value, "invalid_request", "invalid split axis");
        changed = if (std.mem.eql(u8, kind, "chat"))
            state.splitWorkspacePaneWithChatAxis(target.project_index, target.pane_id, axis)
        else if (std.mem.eql(u8, kind, "terminal"))
            state.splitWorkspacePaneWithTerminalAxis(target.project_index, target.pane_id, axis)
        else
            return try errorResponseAlloc(allocator, id_value, "invalid_request", "invalid split kind");
    } else if (std.mem.eql(u8, command, "resize")) {
        const first: app_state.WorkspacePaneId = @intCast(intParam(params, "first") orelse return try errorResponseAlloc(allocator, id_value, "invalid_request", "pane.resize requires first"));
        const second: app_state.WorkspacePaneId = @intCast(intParam(params, "second") orelse return try errorResponseAlloc(allocator, id_value, "invalid_request", "pane.resize requires second"));
        const axis = parseAxis(stringParam(params, "axis") orelse "horizontal") orelse
            return try errorResponseAlloc(allocator, id_value, "invalid_request", "invalid resize axis");
        const ratio = floatParam(params, "ratio") orelse return try errorResponseAlloc(allocator, id_value, "invalid_request", "pane.resize requires ratio");
        changed = state.resizeWorkspaceSplit(target.project_index, first, second, axis, ratio);
    } else if (std.mem.eql(u8, command, "move")) {
        const direction = parsePaneDirection(stringParam(params, "direction") orelse "right") orelse
            return try errorResponseAlloc(allocator, id_value, "invalid_request", "invalid pane direction");
        changed = state.moveWorkspacePaneInDirection(target.project_index, target.pane_id, direction);
    } else if (std.mem.eql(u8, command, "maximize")) {
        changed = state.maximizeWorkspacePane(target.project_index, target.pane_id);
    } else if (std.mem.eql(u8, command, "close")) {
        changed = state.closeWorkspacePane(target.project_index, target.pane_id);
    } else {
        return try errorResponseAlloc(allocator, id_value, "method_not_found", command);
    }

    if (!changed) return try errorResponseAlloc(allocator, id_value, "rejected", "pane operation did not apply");
    return try panesResponseForProject(allocator, id_value, state, target.project_index);
}

fn chatCommandResponse(allocator: std.mem.Allocator, id_value: std.json.Value, state: *app_state.AppState, params: std.json.Value, command: []const u8) ![]u8 {
    if (std.mem.eql(u8, command, "open")) return try chatOpenResponse(allocator, id_value, state, params);

    const target = resolvePaneTarget(state, params) orelse
        return try errorResponseAlloc(allocator, id_value, "not_found", "chat pane not found");
    if (!targetIsChat(state, target)) return try errorResponseAlloc(allocator, id_value, "invalid_target", "target pane is not a chat pane");

    if (std.mem.eql(u8, command, "status")) return try chatStatusResponse(allocator, id_value, state, target.project_index, target.pane_id);
    if (std.mem.eql(u8, command, "transcript")) return try chatTranscriptResponse(allocator, id_value, state, target.project_index, target.pane_id);

    var accepted = false;
    if (std.mem.eql(u8, command, "draft.set")) {
        const text = stringParam(params, "text") orelse "";
        accepted = try state.setWorkspaceChatPaneDraftForProject(target.project_index, target.pane_id, text, false);
    } else if (std.mem.eql(u8, command, "draft.append")) {
        const text = stringParam(params, "text") orelse return try errorResponseAlloc(allocator, id_value, "invalid_request", "chat.draft.append requires text");
        accepted = try state.setWorkspaceChatPaneDraftForProject(target.project_index, target.pane_id, text, true);
    } else if (std.mem.eql(u8, command, "send")) {
        accepted = try state.sendWorkspaceChatPanePromptForProject(target.project_index, target.pane_id, stringParam(params, "prompt"));
    } else if (std.mem.eql(u8, command, "followup")) {
        const prompt = stringParam(params, "prompt") orelse return try errorResponseAlloc(allocator, id_value, "invalid_request", "chat.followup requires prompt");
        accepted = try state.followupWorkspaceChatPanePromptForProject(target.project_index, target.pane_id, prompt);
    } else if (std.mem.eql(u8, command, "stop")) {
        accepted = state.stopWorkspaceChatPaneForProject(target.project_index, target.pane_id);
    } else if (std.mem.eql(u8, command, "approve")) {
        const decision = parseApprovalDecision(stringParam(params, "decision") orelse return try errorResponseAlloc(allocator, id_value, "invalid_request", "chat.approve requires decision")) orelse
            return try errorResponseAlloc(allocator, id_value, "invalid_request", "invalid approval decision");
        accepted = state.approveWorkspaceChatPaneForProject(target.project_index, target.pane_id, decision);
    } else {
        return try errorResponseAlloc(allocator, id_value, "method_not_found", command);
    }

    if (!accepted) return try errorResponseAlloc(allocator, id_value, "rejected", "chat operation did not apply");
    return try chatStatusResponse(allocator, id_value, state, target.project_index, target.pane_id);
}

const ParsedChatOpenSettings = struct {
    reasoning_effort: ?app_state.ReasoningEffort,
    reasoning_variant: ?[]const u8,
    fast_mode: ?app_state.FastMode,
};

fn parseChatOpenSettings(params: std.json.Value) error{
    InvalidReasoningEffortType,
    InvalidReasoningEffortValue,
    InvalidReasoningVariantType,
    InvalidFastModeType,
}!ParsedChatOpenSettings {
    const reasoning_effort_name = stringParam(params, "reasoning_effort");
    if (paramIsNonNull(params, "reasoning_effort") and reasoning_effort_name == null) {
        return error.InvalidReasoningEffortType;
    }
    const reasoning_effort = if (reasoning_effort_name) |name|
        std.meta.stringToEnum(app_state.ReasoningEffort, name) orelse return error.InvalidReasoningEffortValue
    else
        null;
    const reasoning_variant = stringParam(params, "reasoning_variant");
    if (paramIsNonNull(params, "reasoning_variant") and reasoning_variant == null) {
        return error.InvalidReasoningVariantType;
    }
    if (paramIsNonNull(params, "fast_mode") and boolParam(params, "fast_mode") == null) {
        return error.InvalidFastModeType;
    }
    const fast_mode: ?app_state.FastMode = if (boolParam(params, "fast_mode")) |enabled|
        if (enabled) .on else .off
    else
        null;
    return .{
        .reasoning_effort = reasoning_effort,
        .reasoning_variant = reasoning_variant,
        .fast_mode = fast_mode,
    };
}

fn chatOpenResponse(allocator: std.mem.Allocator, id_value: std.json.Value, state: *app_state.AppState, params: std.json.Value) ![]u8 {
    _ = stringParam(params, "workspace_id") orelse
        return try errorResponseAlloc(allocator, id_value, "invalid_request", "chat.open requires an explicit workspace_id");
    const project_index = resolveProjectIndex(state, params) orelse
        return try errorResponseAlloc(allocator, id_value, "not_found", "workspace not found");

    const provider_name = stringParam(params, "provider") orelse
        return try errorResponseAlloc(allocator, id_value, "invalid_request", "chat.open requires provider");
    const provider = parseProvider(provider_name) orelse
        return try errorResponseAlloc(allocator, id_value, "unsupported_provider", "chat.open provider must be one of: opencode, codex, claude, cursor");

    const model_ref = stringParam(params, "model");
    if (paramIsNonNull(params, "model") and model_ref == null) {
        return try errorResponseAlloc(allocator, id_value, "invalid_request", "chat.open model must be a string");
    }
    const creation_settings = parseChatOpenSettings(params) catch |err| switch (err) {
        error.InvalidReasoningEffortType => return try errorResponseAlloc(allocator, id_value, "invalid_request", "chat.open reasoning_effort must be a string"),
        error.InvalidReasoningEffortValue => return try errorResponseAlloc(allocator, id_value, "invalid_request", "chat.open reasoning_effort must be one of: low, medium, high, xhigh, max"),
        error.InvalidReasoningVariantType => return try errorResponseAlloc(allocator, id_value, "invalid_request", "chat.open reasoning_variant must be a string"),
        error.InvalidFastModeType => return try errorResponseAlloc(allocator, id_value, "invalid_request", "chat.open fast_mode must be a boolean"),
    };
    const axis_name = stringParam(params, "axis") orelse "horizontal";
    const axis = parseAxis(axis_name) orelse
        return try errorResponseAlloc(allocator, id_value, "invalid_request", "invalid chat.open split axis");
    if (paramIsNonNull(params, "focus") and boolParam(params, "focus") == null) {
        return try errorResponseAlloc(allocator, id_value, "invalid_request", "chat.open focus must be a boolean");
    }
    const focus = boolParam(params, "focus") orelse true;

    const target_value = if (params == .object)
        params.object.get("target_pane_id") orelse params.object.get("pane")
    else
        null;
    var target_pane_id: ?app_state.WorkspacePaneId = null;
    if (target_value) |value| switch (value) {
        .null => {},
        else => {
            const raw_target = jsonInt(value) orelse
                return try errorResponseAlloc(allocator, id_value, "invalid_request", "chat.open target_pane_id must be a non-negative integer");
            if (raw_target < 0 or raw_target > std.math.maxInt(app_state.WorkspacePaneId)) {
                return try errorResponseAlloc(allocator, id_value, "invalid_request", "chat.open target_pane_id is out of range");
            }
            target_pane_id = @intCast(raw_target);
        },
    };

    const result = state.openWorkspaceChat(project_index, .{
        .provider = provider,
        .model_ref = model_ref,
        .reasoning_effort = creation_settings.reasoning_effort,
        .reasoning_variant = creation_settings.reasoning_variant,
        .fast_mode = creation_settings.fast_mode,
        .target_pane_id = target_pane_id,
        .axis = axis,
        .focus = focus,
    }) catch |err| switch (err) {
        error.ProjectNotFound => return try errorResponseAlloc(allocator, id_value, "not_found", "workspace not found"),
        error.TargetPaneNotFound => return try errorResponseAlloc(allocator, id_value, "not_found", "target pane not found"),
        error.InvalidModel => return try errorResponseAlloc(allocator, id_value, "invalid_model", "model is not available for the requested provider"),
        error.ConflictingReasoningSettings => return try errorResponseAlloc(allocator, id_value, "unsupported_combination", "reasoning_effort and reasoning_variant cannot both be set"),
        error.UnsupportedReasoningEffort => return try errorResponseAlloc(allocator, id_value, "unsupported_combination", "reasoning_effort is not supported by the requested provider and model"),
        error.UnsupportedReasoningVariant => return try errorResponseAlloc(allocator, id_value, "unsupported_combination", "reasoning_variant is not supported by the requested provider and model"),
        error.UnsupportedFastMode => return try errorResponseAlloc(allocator, id_value, "unsupported_combination", "fast_mode is not supported by the requested provider and model"),
        else => return try errorResponseAlloc(allocator, id_value, "internal_error", @errorName(err)),
    };
    const project = &state.project_controller.projects.items[project_index];
    const thread = &project.threads.items[result.thread_index];
    return try chatOpenResultResponse(
        allocator,
        id_value,
        project.id,
        project_index,
        result,
        thread.local_thread_id,
        thread.*,
    );
}

fn browserCommandResponse(allocator: std.mem.Allocator, id_value: std.json.Value, state: *app_state.AppState, params: std.json.Value, command: []const u8) ![]u8 {
    if (std.mem.eql(u8, command, "status")) {
        if (browserCommandHasProjectRef(params)) {
            const project_index = browserCommandProjectIndex(state, params) orelse
                return try errorResponseAlloc(allocator, id_value, "not_found", "workspace not found");
            if (state.browserPaneIdInWorkspace(project_index) == null)
                return try errorResponseAlloc(allocator, id_value, "rejected", "browser pane is not open in workspace");
            _ = state.activateBrowserInWorkspace(project_index) catch |err| switch (err) {
                error.BrowserDisabled => return try errorResponseAlloc(allocator, id_value, "unsupported", "browser runtime is disabled"),
                error.BrowserNotVisible => return try errorResponseAlloc(allocator, id_value, "rejected", "browser pane is not open in workspace"),
                else => return try errorResponseAlloc(allocator, id_value, "rejected", @errorName(err)),
            };
        }
        return try browserStatusResponse(allocator, id_value, state);
    }

    if (std.mem.eql(u8, command, "open")) {
        const project_index = resolveProjectIndex(state, params) orelse
            return try errorResponseAlloc(allocator, id_value, "not_found", "workspace not found");
        const result = state.openBrowserInWorkspace(project_index, stringParam(params, "url")) catch |err| switch (err) {
            error.WorkspaceNotFound => return try errorResponseAlloc(allocator, id_value, "not_found", "workspace not found"),
            error.BrowserDisabled => return try errorResponseAlloc(allocator, id_value, "unsupported", "browser runtime is disabled"),
            error.EmptyBrowserUrl => return try errorResponseAlloc(allocator, id_value, "invalid_request", "browser.open requires a non-empty url"),
            error.BrowserNavigationFailed => return try errorResponseAlloc(allocator, id_value, "rejected", "browser navigation failed"),
            error.BrowserOpenFailed => return try errorResponseAlloc(allocator, id_value, "rejected", "browser open failed"),
            else => return err,
        };
        return try okValueResponse(allocator, id_value, .{
            .accepted = true,
            .workspace_index = result.workspace_index,
            .workspace_id = state.project_controller.projects.items[result.workspace_index].id,
            .pane_id = result.pane_id,
            .moved_from_workspace = result.moved_from_workspace,
            .url = state.browserStateConst().current_url,
        });
    }

    if (std.mem.eql(u8, command, "close")) {
        const project_index = browserCommandProjectIndex(state, params) orelse
            return try errorResponseAlloc(allocator, id_value, "not_found", "workspace not found");
        _ = state.closeBrowserInWorkspace(project_index);
        return try okValueResponse(allocator, id_value, .{ .accepted = true });
    }

    if (std.mem.eql(u8, command, "toggle")) {
        state.toggleBrowser();
        return try okValueResponse(allocator, id_value, .{ .accepted = true });
    }

    const project_index = browserCommandProjectIndex(state, params) orelse
        return try errorResponseAlloc(allocator, id_value, "not_found", "workspace not found");
    _ = state.activateBrowserInWorkspace(project_index) catch |err| switch (err) {
        error.BrowserNotVisible => return try errorResponseAlloc(allocator, id_value, "rejected", "browser pane is not visible in workspace"),
        error.BrowserDisabled => return try errorResponseAlloc(allocator, id_value, "unsupported", "browser runtime is disabled"),
        else => return try errorResponseAlloc(allocator, id_value, "rejected", @errorName(err)),
    };
    if (!state.isBrowserRuntimeActive()) {
        return try errorResponseAlloc(allocator, id_value, "rejected", "browser runtime is not active");
    }

    if (std.mem.eql(u8, command, "restart") or std.mem.eql(u8, command, "reset")) {
        const restore_url = std.mem.eql(u8, command, "restart");
        state.recoverBrowser(restore_url) catch |err| {
            return try errorResponseAlloc(allocator, id_value, "browser_recovery_failed", @errorName(err));
        };
        return try okValueResponse(allocator, id_value, .{
            .accepted = true,
            .recovery = if (restore_url) "restarted" else "reset",
            .url = state.browserStateConst().current_url,
            .load_state = state.browserStateConst().statusLabel(),
        });
    }

    if (std.mem.eql(u8, command, "navigate")) {
        const url = stringParam(params, "url") orelse return try errorResponseAlloc(allocator, id_value, "invalid_request", "browser.navigate requires url");
        state.navigateBrowserToUrl(url) catch |err| switch (err) {
            error.EmptyBrowserUrl => return try errorResponseAlloc(allocator, id_value, "invalid_request", "browser.navigate requires a non-empty url"),
            error.BrowserNavigationFailed => return try errorResponseAlloc(allocator, id_value, "rejected", "browser navigation failed"),
            else => return err,
        };
        return try okValueResponse(allocator, id_value, .{
            .accepted = true,
            .url = state.browserStateConst().current_url,
        });
    }

    if (std.mem.eql(u8, command, "back")) {
        state.navigateBrowserHistory(-1);
        return try okValueResponse(allocator, id_value, .{ .accepted = true });
    }

    if (std.mem.eql(u8, command, "forward")) {
        state.navigateBrowserHistory(1);
        return try okValueResponse(allocator, id_value, .{ .accepted = true });
    }

    if (std.mem.eql(u8, command, "reload")) {
        state.reloadBrowser();
        return try okValueResponse(allocator, id_value, .{ .accepted = true });
    }

    if (std.mem.eql(u8, command, "focus")) {
        state.focusBrowserPane();
        return try okValueResponse(allocator, id_value, .{ .accepted = true });
    }

    if (std.mem.eql(u8, command, "blur")) {
        state.unfocusBrowserPane();
        return try okValueResponse(allocator, id_value, .{ .accepted = true });
    }

    if (std.mem.eql(u8, command, "toolbarHit")) {
        const target = stringParam(params, "target") orelse return try errorResponseAlloc(allocator, id_value, "invalid_request", "browser.toolbarHit requires target");
        const accepted = browser_ui.triggerPaletteToolbarHit(state, target);
        return try okValueResponse(allocator, id_value, .{ .accepted = accepted });
    }

    if (std.mem.eql(u8, command, "selectAllFocused")) {
        state.selectAllBrowserFocusedElement();
        return try okValueResponse(allocator, id_value, .{ .accepted = true });
    }

    if (std.mem.eql(u8, command, "copyFocused")) {
        state.copyBrowserFocusedSelection(false);
        return try okValueResponse(allocator, id_value, .{ .accepted = true });
    }

    if (std.mem.eql(u8, command, "cutFocused")) {
        state.copyBrowserFocusedSelection(true);
        return try okValueResponse(allocator, id_value, .{ .accepted = true });
    }

    if (std.mem.eql(u8, command, "pasteTextFocused")) {
        const text = stringParam(params, "text") orelse return try errorResponseAlloc(allocator, id_value, "invalid_request", "browser.pasteTextFocused requires text");
        state.pasteBrowserTextIntoFocusedElement(text);
        return try okValueResponse(allocator, id_value, .{ .accepted = true });
    }

    if (std.mem.eql(u8, command, "inspector.enable")) {
        state.enableBrowserInspector(true);
        return try okValueResponse(allocator, id_value, .{ .accepted = true });
    }

    if (std.mem.eql(u8, command, "inspector.disable")) {
        state.disableBrowserInspector(true);
        return try okValueResponse(allocator, id_value, .{ .accepted = true });
    }

    if (std.mem.eql(u8, command, "inspector.toggle")) {
        state.toggleBrowserInspector();
        return try okValueResponse(allocator, id_value, .{ .accepted = true });
    }

    if (std.mem.eql(u8, command, "inspector.mode")) {
        const raw_mode = stringParam(params, "mode") orelse return try errorResponseAlloc(allocator, id_value, "invalid_request", "browser.inspector.mode requires mode");
        const mode = parseInspectorMode(raw_mode) orelse return try errorResponseAlloc(allocator, id_value, "invalid_request", "invalid browser inspector mode");
        state.setBrowserInspectorMode(mode);
        return try okValueResponse(allocator, id_value, .{ .accepted = true });
    }

    if (std.mem.eql(u8, command, "inspector.menuOpen")) {
        if (!state.setBrowserInspectorMenuOpen(true)) return try errorResponseAlloc(allocator, id_value, "rejected", "browser inspector menu cannot be opened");
        return try okValueResponse(allocator, id_value, .{ .accepted = true });
    }

    if (std.mem.eql(u8, command, "inspector.menuClose")) {
        _ = state.setBrowserInspectorMenuOpen(false);
        return try okValueResponse(allocator, id_value, .{ .accepted = true });
    }

    if (std.mem.eql(u8, command, "overlay.workspaceMenuOpen")) {
        state.setWorkspaceHeaderOpenMenuOpen(true);
        return try okValueResponse(allocator, id_value, .{ .accepted = true });
    }

    if (std.mem.eql(u8, command, "overlay.workspaceMenuClose")) {
        state.setWorkspaceHeaderOpenMenuOpen(false);
        return try okValueResponse(allocator, id_value, .{ .accepted = true });
    }

    if (std.mem.eql(u8, command, "overlay.sidebarMenuOpen")) {
        state.setSidebarContextMenuOpen(true);
        return try okValueResponse(allocator, id_value, .{ .accepted = true });
    }

    if (std.mem.eql(u8, command, "overlay.sidebarMenuClose")) {
        state.setSidebarContextMenuOpen(false);
        return try okValueResponse(allocator, id_value, .{ .accepted = true });
    }

    if (std.mem.eql(u8, command, "overlay.composerMenuOpen")) {
        state.setComposerMenuOpen(true);
        return try okValueResponse(allocator, id_value, .{ .accepted = true });
    }

    if (std.mem.eql(u8, command, "overlay.composerMenuClose")) {
        state.setComposerMenuOpen(false);
        return try okValueResponse(allocator, id_value, .{ .accepted = true });
    }

    if (std.mem.eql(u8, command, "overlay.workspaceModalOpen") or std.mem.eql(u8, command, "overlay.projectModalOpen")) {
        state.setProjectImportModalOpen(true);
        return try okValueResponse(allocator, id_value, .{ .accepted = true });
    }

    if (std.mem.eql(u8, command, "overlay.workspaceModalClose") or std.mem.eql(u8, command, "overlay.projectModalClose")) {
        state.setProjectImportModalOpen(false);
        return try okValueResponse(allocator, id_value, .{ .accepted = true });
    }

    if (std.mem.eql(u8, command, "overlay.threadModalOpen")) {
        state.setThreadImportModalOpen(true);
        return try okValueResponse(allocator, id_value, .{ .accepted = true });
    }

    if (std.mem.eql(u8, command, "overlay.threadModalClose")) {
        state.setThreadImportModalOpen(false);
        return try okValueResponse(allocator, id_value, .{ .accepted = true });
    }

    if (std.mem.eql(u8, command, "overlay.imageModalOpen")) {
        state.setImageModalOpen(true);
        return try okValueResponse(allocator, id_value, .{ .accepted = true });
    }

    if (std.mem.eql(u8, command, "overlay.imageModalClose")) {
        state.setImageModalOpen(false);
        return try okValueResponse(allocator, id_value, .{ .accepted = true });
    }

    if (std.mem.eql(u8, command, "overlay.transcriptModalOpen")) {
        state.setTranscriptSelectionModalOpen(true);
        return try okValueResponse(allocator, id_value, .{ .accepted = true });
    }

    if (std.mem.eql(u8, command, "overlay.transcriptModalClose")) {
        state.setTranscriptSelectionModalOpen(false);
        return try okValueResponse(allocator, id_value, .{ .accepted = true });
    }

    if (std.mem.eql(u8, command, "eval")) {
        if (!state.browserStateConst().controller.supportsEval()) {
            return try errorResponseAlloc(allocator, id_value, "unsupported", "browser backend does not support JavaScript evaluation");
        }
        const script = stringParam(params, "script") orelse return try errorResponseAlloc(allocator, id_value, "invalid_request", "browser.eval requires script");
        if (script.len == 0) return try errorResponseAlloc(allocator, id_value, "invalid_request", "browser.eval requires script");
        state.browserState().controller.eval(script) catch |err| {
            return try errorResponseAlloc(allocator, id_value, "browser_eval_failed", @errorName(err));
        };
        return try okValueResponse(allocator, id_value, .{ .accepted = true });
    }

    if (std.mem.eql(u8, command, "pointerDown") or
        std.mem.eql(u8, command, "pointerMove") or
        std.mem.eql(u8, command, "pointerUp"))
    {
        if (!state.browserStateConst().controller.supportsLowLevelPointer()) {
            return try errorResponseAlloc(allocator, id_value, "unsupported", "browser backend does not support low-level pointer injection");
        }
        const x = floatParam(params, "x") orelse return try errorResponseAlloc(allocator, id_value, "invalid_request", "browser pointer input requires x");
        const y = floatParam(params, "y") orelse return try errorResponseAlloc(allocator, id_value, "invalid_request", "browser pointer input requires y");
        const button = browser_runtime.parseMouseButton(stringParam(params, "button") orelse "left") orelse
            return try errorResponseAlloc(allocator, id_value, "invalid_request", "invalid browser pointer button");
        const is_move = std.mem.eql(u8, command, "pointerMove");
        state.injectBrowserPointer(.{
            .x = x,
            .y = y,
            .button = if (is_move) null else button,
            .pressed = std.mem.eql(u8, command, "pointerDown"),
            .ctrl = boolParam(params, "ctrl") orelse false,
            .shift = boolParam(params, "shift") orelse false,
            .alt = boolParam(params, "alt") orelse false,
            .super = boolParam(params, "super") orelse false,
        }) catch |err| {
            if (err == error.UnsupportedBrowserCapability) {
                return try errorResponseAlloc(allocator, id_value, "unsupported", "browser backend does not support low-level pointer injection");
            }
            return try errorResponseAlloc(allocator, id_value, "browser_input_failed", @errorName(err));
        };
        return try okValueResponse(allocator, id_value, .{ .accepted = true, .x = x, .y = y });
    }

    if (std.mem.eql(u8, command, "screenshot")) {
        var capture = state.captureBrowserScreenshot() catch |err| switch (err) {
            error.BrowserNotVisible => return try errorResponseAlloc(allocator, id_value, "rejected", "browser pane is not visible"),
            error.BrowserScreenshotUnavailable => return try errorResponseAlloc(allocator, id_value, "unsupported", "browser backend does not expose a CPU frame for screenshots"),
            else => return try errorResponseAlloc(allocator, id_value, "browser_screenshot_failed", @errorName(err)),
        };
        defer capture.deinit(state.allocator);
        const encoded_len = std.base64.standard.Encoder.calcSize(capture.png_bytes.len);
        const encoded = try allocator.alloc(u8, encoded_len);
        defer allocator.free(encoded);
        _ = std.base64.standard.Encoder.encode(encoded, capture.png_bytes);
        return try okValueResponse(allocator, id_value, .{
            .accepted = true,
            .url = state.browserStateConst().current_url,
            .path = capture.path,
            .mime_type = "image/png",
            .width = capture.width,
            .height = capture.height,
            .byte_len = capture.png_bytes.len,
            .data_base64 = encoded,
        });
    }

    if (std.mem.eql(u8, command, "postJson")) {
        const payload = stringParam(params, "json") orelse return try errorResponseAlloc(allocator, id_value, "invalid_request", "browser.post-json requires json payload");
        if (payload.len == 0) return try errorResponseAlloc(allocator, id_value, "invalid_request", "browser.post-json requires json payload");
        state.browserState().controller.postJson(payload) catch |err| {
            return try errorResponseAlloc(allocator, id_value, "browser_post_json_failed", @errorName(err));
        };
        return try okValueResponse(allocator, id_value, .{ .accepted = true });
    }

    return try errorResponseAlloc(allocator, id_value, "method_not_found", command);
}

fn paletteCommandResponse(allocator: std.mem.Allocator, id_value: std.json.Value, state: *app_state.AppState, params: std.json.Value, command: []const u8) ![]u8 {
    if (std.mem.eql(u8, command, "list")) {
        var writer: std.Io.Writer.Allocating = .init(allocator);
        errdefer writer.deinit();
        var s: std.json.Stringify = .{ .writer = &writer.writer, .options = .{} };
        try beginOk(&s, id_value);
        try s.objectField("result");
        try s.beginObject();
        try s.objectField("commands");
        try s.beginArray();
        var index: usize = 0;
        while (index < command_palette.staticCommandCount()) : (index += 1) {
            const info = command_palette.staticCommandInfo(state, index) orelse continue;
            try s.write(info);
        }
        try s.endArray();
        try s.endObject();
        try s.endObject();
        return try writer.toOwnedSlice();
    }

    if (std.mem.eql(u8, command, "run")) {
        const command_id = stringParam(params, "command") orelse stringParam(params, "id") orelse
            return try errorResponseAlloc(allocator, id_value, "invalid_request", "palette.run requires command");
        return switch (command_palette.runStaticCommandById(state, command_id)) {
            .ran => try okValueResponse(allocator, id_value, .{ .accepted = true, .command = command_id }),
            .not_found => try errorResponseAlloc(allocator, id_value, "not_found", "palette command not found"),
            .disabled => try errorResponseAlloc(allocator, id_value, "rejected", "palette command is disabled"),
        };
    }

    return try errorResponseAlloc(allocator, id_value, "method_not_found", command);
}

fn terminalCommandResponse(allocator: std.mem.Allocator, id_value: std.json.Value, state: *app_state.AppState, params: std.json.Value, command: []const u8) ![]u8 {
    const target = resolvePaneTarget(state, params) orelse
        return try errorResponseAlloc(allocator, id_value, "not_found", "terminal pane not found");
    if (!targetIsTerminal(state, target)) return try errorResponseAlloc(allocator, id_value, "invalid_target", "target pane is not a terminal pane");

    if (std.mem.eql(u8, command, "write")) {
        const text = stringParam(params, "text") orelse return try errorResponseAlloc(allocator, id_value, "invalid_request", "terminal.write requires text");
        if (!try state.writeWorkspaceTerminalPaneForProject(target.project_index, target.pane_id, text)) return try errorResponseAlloc(allocator, id_value, "rejected", "terminal write did not apply");
        return try inspectPaneResponse(allocator, id_value, state, target.project_index, target.pane_id);
    }
    if (std.mem.eql(u8, command, "key")) {
        const chord = terminalKeyChordParam(params) catch |err| return switch (err) {
            error.MissingKey => try errorResponseAlloc(allocator, id_value, "invalid_key", "terminal.key requires exactly one of key or chord"),
            error.ConflictingKeySpec => try errorResponseAlloc(allocator, id_value, "invalid_key", "terminal.key accepts key plus modifiers or chord, not both"),
            error.InvalidModifier => try errorResponseAlloc(allocator, id_value, "invalid_key", "terminal.key modifiers must be booleans"),
            error.InvalidKey => try errorResponseAlloc(allocator, id_value, "invalid_key", "unsupported terminal key or chord"),
        };
        if (!try state.writeWorkspaceTerminalKeyForProject(target.project_index, target.pane_id, chord)) {
            return try errorResponseAlloc(allocator, id_value, "rejected", "terminal key did not apply");
        }
        return try okValueResponse(allocator, id_value, .{
            .accepted = true,
            .workspace_index = target.project_index,
            .pane_id = target.pane_id,
            .key = chord.key.text(),
            .modifiers = .{
                .ctrl = chord.modifiers.ctrl,
                .alt = chord.modifiers.alt,
                .shift = chord.modifiers.shift,
                .super = chord.modifiers.super,
            },
        });
    }
    if (std.mem.eql(u8, command, "tail")) {
        const max_bytes = @as(usize, @intCast((intParam(params, "lines") orelse 200) * 240));
        const output = (try state.terminalPaneOutputTailForProject(target.project_index, target.pane_id, max_bytes)) orelse
            return try errorResponseAlloc(allocator, id_value, "not_found", "terminal output not found");
        defer state.allocator.free(output);
        return try okValueResponse(allocator, id_value, .{
            .workspace_index = target.project_index,
            .pane_id = target.pane_id,
            .truncated = output.len >= max_bytes,
            .text = output,
        });
    }
    if (std.mem.eql(u8, command, "screen")) {
        const screen = (try state.terminalPaneScreenTextForProject(target.project_index, target.pane_id)) orelse
            return try errorResponseAlloc(allocator, id_value, "not_found", "terminal screen not found");
        defer state.allocator.free(screen);
        return try okValueResponse(allocator, id_value, .{
            .workspace_index = target.project_index,
            .pane_id = target.pane_id,
            .text = screen,
        });
    }
    return try errorResponseAlloc(allocator, id_value, "method_not_found", command);
}

const TerminalKeyParamError = error{
    MissingKey,
    ConflictingKeySpec,
    InvalidModifier,
    InvalidKey,
};

fn terminalKeyChordParam(params: std.json.Value) TerminalKeyParamError!terminal.TerminalKeyChord {
    const chord_value = stringParam(params, "chord");
    const key_value = stringParam(params, "key");
    if ((paramIsNonNull(params, "chord") and chord_value == null) or
        (paramIsNonNull(params, "key") and key_value == null))
    {
        return error.InvalidKey;
    }

    var modifiers: terminal.TerminalKeyModifiers = .{};
    inline for (.{ "ctrl", "alt", "shift", "super" }) |name| {
        if (paramIsNonNull(params, name)) {
            const value = boolParam(params, name) orelse return error.InvalidModifier;
            @field(modifiers, name) = value;
        }
    }

    if (chord_value) |value| {
        if (key_value != null or @as(u4, @bitCast(modifiers)) != 0) return error.ConflictingKeySpec;
        return terminal.TerminalKeyChord.parse(value) catch return error.InvalidKey;
    }
    const key_text = key_value orelse return error.MissingKey;
    return .{
        .key = terminal.TerminalKey.parse(key_text) orelse return error.InvalidKey,
        .modifiers = modifiers,
    };
}

fn processCommandResponse(allocator: std.mem.Allocator, id_value: std.json.Value, state: *app_state.AppState, params: std.json.Value, command: []const u8) ![]u8 {
    if (std.mem.eql(u8, command, "inspect") and stringParam(params, "name") == null) {
        const target = resolvePaneTarget(state, params) orelse
            return try errorResponseAlloc(allocator, id_value, "not_found", "pane not found");
        return try inspectPaneResponse(allocator, id_value, state, target.project_index, target.pane_id);
    }
    const project_index = resolveProjectIndex(state, params) orelse return try errorResponseAlloc(allocator, id_value, "not_found", "workspace not found");
    if (std.mem.eql(u8, command, "list")) {
        if (try refreshStackConfigOrError(allocator, id_value, state, project_index)) |response| return response;
        return try managedProcessesResponseForProject(allocator, id_value, state, project_index);
    }
    if (std.mem.eql(u8, command, "inspect")) {
        const name = stringParam(params, "name") orelse return try errorResponseAlloc(allocator, id_value, "invalid_request", "process.inspect requires --name or --pane");
        const process = state.managedProcessByNameConst(project_index, name) catch |err| switch (err) {
            error.InvalidStackConfig => return try errorResponseAlloc(allocator, id_value, "invalid_stack_config", stackConfigErrorMessage(state, project_index, err)),
            else => return err,
        };
        _ = process orelse
            return try errorResponseAlloc(allocator, id_value, "not_found", "process not found");
        return try managedProcessResponse(allocator, id_value, state, project_index, name);
    }
    if (std.mem.eql(u8, command, "start") or std.mem.eql(u8, command, "stop") or std.mem.eql(u8, command, "restart")) {
        const name = stringParam(params, "name") orelse return try errorResponseAlloc(allocator, id_value, "invalid_request", "process command requires --name");
        const changed = (if (std.mem.eql(u8, command, "start"))
            state.startManagedProcess(project_index, name)
        else if (std.mem.eql(u8, command, "stop"))
            state.stopManagedProcess(project_index, name)
        else
            state.restartManagedProcess(project_index, name)) catch |err| switch (err) {
            error.InvalidStackConfig => return try errorResponseAlloc(allocator, id_value, "invalid_stack_config", stackConfigErrorMessage(state, project_index, err)),
            else => return err,
        };
        if (!changed) return try errorResponseAlloc(allocator, id_value, "not_found", "process not found");
        return try managedProcessResponse(allocator, id_value, state, project_index, name);
    }
    if (std.mem.eql(u8, command, "logs")) {
        const name = stringParam(params, "name") orelse return try errorResponseAlloc(allocator, id_value, "invalid_request", "process.logs requires --name");
        const max_bytes = @as(usize, @intCast((intParam(params, "lines") orelse 200) * 240));
        const output = (try state.managedProcessLogs(project_index, name, max_bytes)) orelse
            return try errorResponseAlloc(allocator, id_value, "not_found", "process logs not found");
        defer state.allocator.free(output);
        return try okValueResponse(allocator, id_value, .{
            .workspace_index = project_index,
            .name = name,
            .truncated = output.len >= max_bytes,
            .text = output,
        });
    }
    return try errorResponseAlloc(allocator, id_value, "method_not_found", command);
}

fn agentCommandResponse(allocator: std.mem.Allocator, id_value: std.json.Value, state: *app_state.AppState, params: std.json.Value, command: []const u8) ![]u8 {
    const project_index = resolveProjectIndex(state, params) orelse return try errorResponseAlloc(allocator, id_value, "not_found", "workspace not found");
    if (std.mem.eql(u8, command, "open")) {
        const provider_name = stringParam(params, "provider") orelse "codex";
        const provider: app_state.AgentTuiProvider = if (std.mem.eql(u8, provider_name, "codex"))
            .codex
        else if (std.mem.eql(u8, provider_name, "claude"))
            .claude
        else if (std.mem.eql(u8, provider_name, "opencode"))
            .opencode
        else if (std.mem.eql(u8, provider_name, "cursor"))
            .cursor
        else if (std.mem.eql(u8, provider_name, "grok"))
            .grok
        else
            return try errorResponseAlloc(allocator, id_value, "unsupported_provider", "agent.open provider must be one of: codex, claude, opencode, cursor, grok");
        const changed = try state.openAgentTui(project_index, provider);
        if (!changed) {
            if (provider == .grok and !app_state.AppState.grokTuiInstalled()) {
                return try errorResponseAlloc(allocator, id_value, "provider_not_installed", "Grok Build is not installed; see https://docs.x.ai/build/overview#install");
            }
            return try errorResponseAlloc(allocator, id_value, "not_found", "workspace not found");
        }
        return try managedProcessResponse(allocator, id_value, state, project_index, @tagName(provider));
    }
    return try errorResponseAlloc(allocator, id_value, "method_not_found", command);
}

fn stackCommandResponse(allocator: std.mem.Allocator, id_value: std.json.Value, state: *app_state.AppState, params: std.json.Value, command: []const u8) ![]u8 {
    const project_index = resolveProjectIndex(state, params) orelse return try errorResponseAlloc(allocator, id_value, "not_found", "workspace not found");
    if (std.mem.eql(u8, command, "status")) {
        if (try refreshStackConfigOrError(allocator, id_value, state, project_index)) |response| return response;
        return try managedProcessesResponseForProject(allocator, id_value, state, project_index);
    }
    if (std.mem.eql(u8, command, "start") or std.mem.eql(u8, command, "stop") or std.mem.eql(u8, command, "restart")) {
        const count = (if (std.mem.eql(u8, command, "start"))
            state.startProjectStack(project_index)
        else if (std.mem.eql(u8, command, "stop"))
            state.stopProjectStack(project_index)
        else
            state.restartProjectStack(project_index)) catch |err| switch (err) {
            error.InvalidStackConfig => return try errorResponseAlloc(allocator, id_value, "invalid_stack_config", stackConfigErrorMessage(state, project_index, err)),
            else => return err,
        };
        _ = count;
        return try managedProcessesResponseForProject(allocator, id_value, state, project_index);
    }
    return try errorResponseAlloc(allocator, id_value, "method_not_found", command);
}

const PaneTarget = struct {
    project_index: usize,
    pane_id: app_state.WorkspacePaneId,
};

fn resolvePaneTarget(state: *app_state.AppState, params: std.json.Value) ?PaneTarget {
    const project_index = resolveProjectIndex(state, params) orelse return null;
    const project = &state.project_controller.projects.items[project_index];
    if (boolParam(params, "focused") orelse false) {
        const pane_id = project.workspace_layout.focused_pane_id orelse return null;
        return .{ .project_index = project_index, .pane_id = pane_id };
    }
    const pane_id_raw = intParam(params, "pane") orelse intParam(params, "pane_id") orelse return null;
    const pane_id: app_state.WorkspacePaneId = @intCast(pane_id_raw);
    if (project.workspace_layout.paneById(pane_id) == null) return null;
    return .{ .project_index = project_index, .pane_id = pane_id };
}

fn resolveProjectIndex(state: *app_state.AppState, params: std.json.Value) ?usize {
    if (state.project_controller.projects.items.len == 0) return null;
    if (params == .object) {
        if (jsonString(params.object.get("workspace_id") orelse params.object.get("workspace") orelse params.object.get("project") orelse .null)) |project_ref| {
            if (std.mem.eql(u8, project_ref, "current")) return state.project_controller.selected_index;
            if (std.fmt.parseInt(usize, project_ref, 10)) |index| {
                if (index < state.project_controller.projects.items.len) return index;
            } else |_| {}
            for (state.project_controller.projects.items, 0..) |project, index| {
                if (std.mem.eql(u8, project.id, project_ref) or std.mem.eql(u8, project.path, project_ref)) return index;
            }
            return null;
        }
    }
    return state.project_controller.selected_index;
}

fn browserCommandProjectIndex(state: *app_state.AppState, params: std.json.Value) ?usize {
    if (state.project_controller.projects.items.len == 0) return null;
    const explicit_project_index = if (browserCommandHasProjectRef(params))
        resolveProjectIndex(state, params) orelse return null
    else
        null;
    return chooseBrowserCommandProjectIndex(
        state.browserWorkspaceIndex(),
        state.project_controller.selected_index,
        explicit_project_index,
    );
}

fn chooseBrowserCommandProjectIndex(active_project_index: ?usize, selected_project_index: usize, explicit_project_index: ?usize) usize {
    return explicit_project_index orelse active_project_index orelse selected_project_index;
}

fn browserCommandHasProjectRef(params: std.json.Value) bool {
    if (params != .object) return false;
    const project_ref = params.object.get("workspace_id") orelse
        params.object.get("workspace") orelse
        params.object.get("project") orelse
        .null;
    return jsonString(project_ref) != null;
}

fn resolveClosedProjectIndex(state: *app_state.AppState, params: std.json.Value) ?usize {
    if (state.project_controller.archived_projects.items.len == 0) return null;
    if (params == .object) {
        if (jsonString(params.object.get("workspace") orelse params.object.get("project") orelse .null)) |project_ref| {
            if (std.mem.eql(u8, project_ref, "last") or std.mem.eql(u8, project_ref, "current")) return state.project_controller.archived_projects.items.len - 1;
            if (std.fmt.parseInt(usize, project_ref, 10)) |index| {
                if (index < state.project_controller.archived_projects.items.len) return index;
            } else |_| {}
            for (state.project_controller.archived_projects.items, 0..) |project, index| {
                if (std.mem.eql(u8, project.id, project_ref) or std.mem.eql(u8, project.path, project_ref) or std.mem.eql(u8, project.label, project_ref)) return index;
            }
            return null;
        }
    }
    return state.project_controller.archived_projects.items.len - 1;
}

fn resolveProjectIndexNullable(state: *app_state.AppState, params: std.json.Value) ?usize {
    if (params == .object and
        (params.object.get("workspace_id") != null or params.object.get("workspace") != null or params.object.get("project") != null))
    {
        return resolveProjectIndex(state, params);
    }
    return null;
}

fn targetIsChat(state: *app_state.AppState, target: PaneTarget) bool {
    const pane = state.project_controller.projects.items[target.project_index].workspace_layout.paneById(target.pane_id) orelse return false;
    return pane.ref == .chat;
}

fn targetIsTerminal(state: *app_state.AppState, target: PaneTarget) bool {
    const pane = state.project_controller.projects.items[target.project_index].workspace_layout.paneById(target.pane_id) orelse return false;
    return pane.ref == .terminal;
}

fn writeSelectedProjectPanes(s: *std.json.Stringify, state: *app_state.AppState) !void {
    if (state.project_controller.projects.items.len == 0) {
        try s.write(null);
        return;
    }
    try writeProjectPanes(s, state, state.project_controller.selected_index);
}

fn writeProjectPanes(s: *std.json.Stringify, state: *app_state.AppState, project_index: usize) !void {
    const project = &state.project_controller.projects.items[project_index];
    try s.beginObject();
    try s.objectField("workspace_index");
    try s.write(project_index);
    try s.objectField("workspace_id");
    try s.write(project.id);
    try s.objectField("focused_pane_id");
    if (project.workspace_layout.focused_pane_id) |pane_id| try s.write(pane_id) else try s.write(null);
    try s.objectField("maximized_pane_id");
    if (project.workspace_layout.maximized_pane_id) |pane_id| try s.write(pane_id) else try s.write(null);
    try s.objectField("panes");
    try s.beginArray();
    for (project.workspace_layout.panes.items) |pane| {
        try writePane(s, state, project_index, pane);
    }
    try s.endArray();
    try s.endObject();
}

fn writePane(s: *std.json.Stringify, state: *app_state.AppState, project_index: usize, pane: app_state.WorkspacePane) !void {
    const project = &state.project_controller.projects.items[project_index];
    try s.beginObject();
    try s.objectField("pane_id");
    try s.write(pane.id);
    try s.objectField("focused");
    try s.write(project.workspace_layout.focused_pane_id != null and project.workspace_layout.focused_pane_id.? == pane.id);
    try s.objectField("maximized");
    try s.write(project.workspace_layout.maximized_pane_id != null and project.workspace_layout.maximized_pane_id.? == pane.id);
    switch (pane.ref) {
        .chat => |ref| {
            try s.objectField("kind");
            try s.write("chat");
            try s.objectField("thread_index");
            try s.write(ref.thread_index);
            if (ref.thread_index < project.threads.items.len) {
                const thread = &project.threads.items[ref.thread_index];
                try s.objectField("thread_title");
                try s.write(thread.title);
                try s.objectField("provider");
                try s.write(@tagName(thread.provider));
                try s.objectField("model");
                if (thread.model_ref) |model| try s.write(model) else try s.write(null);
                try s.objectField("send_pending");
                try s.write(thread.isSendPendingForUi());
                try s.objectField("completion_pending");
                try s.write(thread.completion_pending);
                try s.objectField("completed_at_ms");
                if (thread.completion_pending) try s.write(thread.completed_at_ms) else try s.write(null);
                const pending_approval = threadHasPendingApproval(thread);
                try s.objectField("pending_approval");
                try s.write(pending_approval);
                try s.objectField("attention");
                try s.write(pending_approval or thread.completion_pending);
                try s.objectField("attention_reasons");
                try s.beginArray();
                if (pending_approval) try s.write("pending_approval");
                if (thread.completion_pending) try s.write("completed");
                try s.endArray();
            }
        },
        .terminal => |ref| {
            try s.objectField("kind");
            try s.write("terminal");
            try s.objectField("dock_id");
            try s.write(ref.dock_id);
            if (state.projectTerminalDock(project_index, ref.dock_id)) |dock| {
                try s.objectField("running");
                try s.write(dock.hasRunningSession());
                try s.objectField("active_tab_index");
                try s.write(dock.active_tab_index);
                try s.objectField("tab_count");
                try s.write(dock.tabs.items.len);
                try s.objectField("cwd");
                if (dock.cwd) |cwd| try s.write(cwd) else try s.write(null);
            }
            const attention = terminalDockHasAttention(state, project_index, project, ref.dock_id);
            try s.objectField("attention");
            try s.write(attention);
            try s.objectField("attention_reasons");
            try writeTerminalAttentionReasons(s, state, project_index, project, ref.dock_id);
        },
        .browser => {
            try s.objectField("kind");
            try s.write("browser");
            try s.objectField("visible");
            try s.write(state.isBrowserRuntimeActiveInWorkspace(project_index));
        },
    }
    try s.endObject();
}

fn writeThreadSummary(s: *std.json.Stringify, thread: app_state.ChatThread, index: usize) !void {
    try s.beginObject();
    try s.objectField("index");
    try s.write(index);
    try s.objectField("title");
    try s.write(thread.title);
    try s.objectField("provider");
    try s.write(@tagName(thread.provider));
    try s.objectField("model");
    if (thread.model_ref) |model| try s.write(model) else try s.write(null);
    try writeThreadCreationSettings(s, thread);
    try s.objectField("provider_thread_id");
    if (thread.provider_thread_id) |thread_id| try s.write(thread_id) else try s.write(null);
    try s.objectField("message_count");
    try s.write(thread.messages.items.len);
    try s.objectField("send_pending");
    try s.write(thread.isSendPendingForUi());
    try s.objectField("completion_pending");
    try s.write(thread.completion_pending);
    try s.objectField("completed_at_ms");
    if (thread.completion_pending) try s.write(thread.completed_at_ms) else try s.write(null);
    try s.endObject();
}

fn writeThreadCreationSettings(s: *std.json.Stringify, thread: app_state.ChatThread) !void {
    try s.objectField("reasoning_effort");
    if (thread.reasoning_effort) |effort| try s.write(@tagName(effort)) else try s.write(null);
    try s.objectField("reasoning_variant");
    if (thread.opencode_reasoning_variant) |variant| try s.write(variant) else try s.write(null);
    try s.objectField("fast_mode");
    try s.write(thread.fast_mode == .on);
    try s.objectField("service_tier");
    if (thread.provider == .codex) {
        try s.write(if (thread.fast_mode == .on) "fast" else "default");
    } else {
        try s.write(null);
    }
}

fn writeTerminalsArray(s: *std.json.Stringify, state: *app_state.AppState, maybe_project_index: ?usize) !void {
    try s.beginArray();
    for (state.project_controller.projects.items, 0..) |project, project_index| {
        if (maybe_project_index) |wanted| {
            if (wanted != project_index) continue;
        }
        for (project.workspace_layout.panes.items) |pane| {
            if (pane.ref != .terminal) continue;
            const ref = pane.ref.terminal;
            try s.beginObject();
            try s.objectField("workspace_index");
            try s.write(project_index);
            try s.objectField("workspace_id");
            try s.write(project.id);
            try s.objectField("pane_id");
            try s.write(pane.id);
            try s.objectField("dock_id");
            try s.write(ref.dock_id);
            if (state.projectTerminalDock(project_index, ref.dock_id)) |dock| {
                try s.objectField("running");
                try s.write(dock.hasRunningSession());
                try s.objectField("active_tab_index");
                try s.write(dock.active_tab_index);
                try s.objectField("tab_count");
                try s.write(dock.tabs.items.len);
                try s.objectField("cwd");
                if (dock.cwd) |cwd| try s.write(cwd) else try s.write(null);
            }
            for (project.managed_processes.items) |process| {
                if (process.dock_id == null or process.dock_id.? != ref.dock_id) continue;
                try s.objectField("process");
                try s.beginObject();
                try s.objectField("name");
                try s.write(process.name);
                try s.objectField("status");
                try s.write(@tagName(process.status));
                try s.endObject();
                break;
            }
            const attention = terminalDockHasAttention(state, project_index, &project, ref.dock_id);
            try s.objectField("attention");
            try s.write(attention);
            try s.objectField("attention_reasons");
            try writeTerminalAttentionReasons(s, state, project_index, &project, ref.dock_id);
            try s.endObject();
        }
    }
    try s.endArray();
}

fn workspaceProcessesResponse(allocator: std.mem.Allocator, id_value: std.json.Value, state: *app_state.AppState, params: std.json.Value) ![]u8 {
    const project_index = resolveProjectIndexNullable(state, params);
    if (project_index) |index| {
        if (index >= state.project_controller.projects.items.len) return try errorResponseAlloc(allocator, id_value, "not_found", "workspace not found");
        if (try refreshStackConfigOrError(allocator, id_value, state, index)) |response| return response;
        state.pollWorkspaceTerminalProcessLifecyclesForLiveRead(index);
        state.pruneExpiredWorkspaceLeases(index);
    } else {
        var index: usize = 0;
        while (index < state.project_controller.projects.items.len) : (index += 1) {
            if (try refreshStackConfigOrError(allocator, id_value, state, index)) |response| return response;
            state.pollWorkspaceTerminalProcessLifecyclesForLiveRead(index);
            state.pruneExpiredWorkspaceLeases(index);
        }
    }

    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    var s: std.json.Stringify = .{ .writer = &writer.writer, .options = .{} };
    try beginOk(&s, id_value);
    try s.objectField("result");
    try s.beginObject();
    try s.objectField("processes");
    try writeWorkspaceProcessesArray(&s, state, project_index);
    try s.objectField("leases");
    try writeWorkspaceLeasesArray(&s, state, project_index);
    try s.objectField("polled_at_ms");
    try s.write(platform_runtime.unixTimestampMs());
    try s.endObject();
    try s.endObject();
    return try writer.toOwnedSlice();
}

fn writeWorkspaceProcessesArray(s: *std.json.Stringify, state: *app_state.AppState, maybe_project_index: ?usize) !void {
    try s.beginArray();
    for (state.project_controller.projects.items, 0..) |*project, project_index| {
        if (maybe_project_index) |wanted| if (wanted != project_index) continue;
        state.refreshManagedProcessStatuses(project_index);
        for (project.managed_processes.items) |*process| try writeManagedProcess(s, state, project_index, process);

        for (project.terminal_docks.items) |*entry| {
            if (managedProcessUsesDock(project, entry.id)) continue;
            try writeTerminalWorkspaceProcess(s, state, project_index, entry.id, &entry.dock);
        }
        try writeTerminalWorkspaceProcess(s, state, project_index, 0, &project.terminal_dock);
        for (project.tracked_terminal_processes.items) |*tracked| {
            if (tracked.missing_since_ms == null or managedProcessUsesDock(project, tracked.dock_id)) continue;
            try writePendingTerminalWorkspaceProcess(s, project_index, project, tracked);
        }
        project.pruneTerminalProcessOutcomes(state.allocator, platform_runtime.unixTimestampMs());
        for (project.terminal_process_outcomes.items) |*outcome| {
            if (managedProcessUsesDock(project, outcome.dock_id)) continue;
            try writeTerminalWorkspaceOutcome(s, project_index, project, outcome);
        }

        for (project.threads.items, 0..) |*thread, thread_index| {
            try writeGuiAgentWorkspaceProcess(s, project, project_index, thread, thread_index);
            try writeBackgroundWorkspaceProcesses(s, project, project_index, thread, thread_index, false);
        }
        for (project.archived_threads.items, 0..) |*thread, thread_index| {
            try writeBackgroundWorkspaceProcesses(s, project, project_index, thread, thread_index, true);
        }
    }
    try s.endArray();
}

fn managedProcessUsesDock(project: *const app_state.Project, dock_id: u32) bool {
    for (project.managed_processes.items) |process| {
        if (process.dock_id != null and process.dock_id.? == dock_id) return true;
    }
    return false;
}

fn writeTerminalWorkspaceProcess(
    s: *std.json.Stringify,
    state: *app_state.AppState,
    project_index: usize,
    dock_id: u32,
    dock: anytype,
) !void {
    const snapshot = dock.activeRuntimeProcessSnapshot() orelse return;
    if (!snapshot.running) return;
    const session_id = dock.activeSessionId() orelse return;
    const project = &state.project_controller.projects.items[project_index];
    const tracked = project.terminalProcessActiveForSession(session_id) orelse return;
    var label_buffer: [96]u8 = undefined;
    const command = dock.activeForegroundProcessName(&label_buffer) orelse dock.activeProcessLabel(&label_buffer);
    const surface = state.surfaceBySessionIdConst(session_id);

    try s.beginObject();
    try s.objectField("id");
    try s.write(tracked.process_id);
    try s.objectField("source");
    try s.write("terminal");
    try s.objectField("workspace_index");
    try s.write(project_index);
    try s.objectField("workspace_id");
    try s.write(project.id);
    try s.objectField("name");
    try s.write(command);
    try s.objectField("command");
    try s.write(command);
    try s.objectField("cwd");
    if (dock.cwd) |cwd| try s.write(cwd) else try s.write(project.path);
    try s.objectField("status");
    try s.write("running");
    try s.objectField("classification");
    try s.write(@tagName(app_state.classifyWorkspaceCommand(command)));
    try s.objectField("resources");
    try writeWorkspaceResources(s, &.{}, command);
    try s.objectField("pid");
    if (snapshot.pid) |pid| try s.write(pid) else try s.write(null);
    try s.objectField("process_group");
    if (snapshot.process_group) |process_group| try s.write(process_group) else try s.write(null);
    try s.objectField("started_at_ms");
    try s.write(snapshot.started_at_ms);
    try s.objectField("dock_id");
    try s.write(dock_id);
    try s.objectField("pane_id");
    if (workspacePaneIdForDock(project, dock_id)) |pane_id| try s.write(pane_id) else try s.write(null);
    try s.objectField("owner");
    try s.beginObject();
    try s.objectField("id");
    try s.write(session_id);
    try s.objectField("kind");
    try s.write(if (surface != null and surface.?.provider != null) "agent" else "terminal");
    try s.objectField("session_id");
    try s.write(session_id);
    try s.objectField("title");
    if (surface) |owner_surface| try s.write(owner_surface.title) else try s.write(command);
    try s.objectField("provider");
    if (surface) |owner_surface| {
        if (owner_surface.provider) |provider| try s.write(@tagName(provider)) else try s.write(null);
    } else try s.write(null);
    try s.objectField("cancel_method");
    try s.write("terminal.write Ctrl-C or close the pane");
    try s.endObject();
    try s.endObject();
}

fn writePendingTerminalWorkspaceProcess(
    s: *std.json.Stringify,
    project_index: usize,
    project: *const app_state.Project,
    tracked: *const app_state.TrackedTerminalProcess,
) !void {
    try s.beginObject();
    try s.objectField("id");
    try s.write(tracked.process_id);
    try s.objectField("source");
    try s.write("terminal");
    try s.objectField("workspace_index");
    try s.write(project_index);
    try s.objectField("workspace_id");
    try s.write(project.id);
    try s.objectField("name");
    try s.write(tracked.command);
    try s.objectField("command");
    try s.write(tracked.command);
    try s.objectField("cwd");
    try s.write(tracked.cwd);
    try s.objectField("status");
    try s.write("stopping");
    try s.objectField("classification");
    try s.write(@tagName(app_state.classifyWorkspaceCommand(tracked.command)));
    try s.objectField("resources");
    try s.beginArray();
    try s.endArray();
    try s.objectField("pid");
    if (tracked.pid) |pid| try s.write(pid) else try s.write(null);
    try s.objectField("process_group");
    if (tracked.process_group) |process_group| try s.write(process_group) else try s.write(null);
    try s.objectField("started_at_ms");
    try s.write(tracked.started_at_ms);
    try s.objectField("dock_id");
    try s.write(tracked.dock_id);
    try s.objectField("pane_id");
    if (tracked.pane_id) |pane_id| try s.write(pane_id) else try s.write(null);
    try s.objectField("owner");
    try s.beginObject();
    try s.objectField("id");
    try s.write(tracked.session_id);
    try s.objectField("kind");
    try s.write(tracked.owner_kind);
    try s.objectField("session_id");
    try s.write(tracked.session_id);
    try s.objectField("title");
    try s.write(tracked.owner_title);
    try s.objectField("provider");
    if (tracked.provider) |provider| try s.write(provider) else try s.write(null);
    try s.objectField("cancel_method");
    try s.write("terminal.write Ctrl-C or close the pane");
    try s.endObject();
    try s.endObject();
}

fn writeTerminalWorkspaceOutcome(
    s: *std.json.Stringify,
    project_index: usize,
    project: *const app_state.Project,
    outcome: *const app_state.TerminalProcessOutcome,
) !void {
    try s.beginObject();
    try s.objectField("id");
    try s.write(outcome.process_id);
    try s.objectField("source");
    try s.write("terminal");
    try s.objectField("workspace_index");
    try s.write(project_index);
    try s.objectField("workspace_id");
    try s.write(project.id);
    try s.objectField("name");
    try s.write(outcome.command);
    try s.objectField("command");
    try s.write(outcome.command);
    try s.objectField("cwd");
    try s.write(outcome.cwd);
    try s.objectField("status");
    try s.write(@tagName(outcome.status));
    try s.objectField("classification");
    try s.write(@tagName(app_state.classifyWorkspaceCommand(outcome.command)));
    try s.objectField("resources");
    try s.beginArray();
    try s.endArray();
    try s.objectField("pid");
    if (outcome.pid) |pid| try s.write(pid) else try s.write(null);
    try s.objectField("process_group");
    if (outcome.process_group) |process_group| try s.write(process_group) else try s.write(null);
    try s.objectField("started_at_ms");
    try s.write(outcome.started_at_ms);
    try s.objectField("finished_at_ms");
    try s.write(outcome.finished_at_ms);
    try s.objectField("exit_code");
    if (outcome.exit_code) |exit_code| try s.write(exit_code) else try s.write(null);
    try s.objectField("signal");
    if (outcome.signal) |signal| try s.write(signal) else try s.write(null);
    try s.objectField("cancellation_reason");
    if (outcome.cancellation_reason) |reason| try s.write(reason) else try s.write(null);
    try s.objectField("dock_id");
    try s.write(outcome.dock_id);
    try s.objectField("pane_id");
    if (outcome.pane_id) |pane_id| try s.write(pane_id) else try s.write(null);
    try s.objectField("owner");
    try s.beginObject();
    try s.objectField("id");
    try s.write(outcome.session_id);
    try s.objectField("kind");
    try s.write(outcome.owner_kind);
    try s.objectField("session_id");
    try s.write(outcome.session_id);
    try s.objectField("title");
    try s.write(outcome.owner_title);
    try s.objectField("provider");
    if (outcome.provider) |provider| try s.write(provider) else try s.write(null);
    try s.objectField("cancel_method");
    try s.write("none (process finished)");
    try s.endObject();
    try s.endObject();
}

fn workspacePaneIdForDock(project: *const app_state.Project, dock_id: u32) ?app_state.WorkspacePaneId {
    for (project.workspace_layout.panes.items) |pane| {
        switch (pane.ref) {
            .terminal => |ref| if (ref.dock_id == dock_id) return pane.id,
            else => {},
        }
    }
    return null;
}

fn writeGuiAgentWorkspaceProcess(
    s: *std.json.Stringify,
    project: *const app_state.Project,
    project_index: usize,
    thread: *const app_state.ChatThread,
    thread_index: usize,
) !void {
    if (!thread.isSendPendingForUi()) return;
    var id_buffer: [160]u8 = undefined;
    const process_id = std.fmt.bufPrint(&id_buffer, "turn:{s}", .{thread.local_thread_id}) catch thread.local_thread_id;
    var command_buffer: [96]u8 = undefined;
    const command = std.fmt.bufPrint(&command_buffer, "{s} GUI agent", .{@tagName(thread.provider)}) catch "GUI agent";
    try s.beginObject();
    try s.objectField("id");
    try s.write(process_id);
    try s.objectField("source");
    try s.write("gui_agent");
    try s.objectField("workspace_index");
    try s.write(project_index);
    try s.objectField("workspace_id");
    try s.write(project.id);
    try s.objectField("name");
    try s.write(thread.title);
    try s.objectField("command");
    try s.write(command);
    try s.objectField("cwd");
    try s.write(project.path);
    try s.objectField("status");
    try s.write("running");
    try s.objectField("classification");
    try s.write("other");
    try s.objectField("resources");
    try s.beginArray();
    try s.endArray();
    try s.objectField("pid");
    try s.write(null);
    try s.objectField("process_group");
    try s.write(null);
    try s.objectField("started_at_ms");
    if (thread.sendStartedAtMsForUi()) |started_at_ms| try s.write(started_at_ms) else try s.write(null);
    try s.objectField("thread_index");
    try s.write(thread_index);
    try s.objectField("thread_id");
    try s.write(thread.local_thread_id);
    try s.objectField("owner");
    try s.beginObject();
    try s.objectField("id");
    try s.write(thread.local_thread_id);
    try s.objectField("kind");
    try s.write("gui_agent");
    try s.objectField("thread_id");
    try s.write(thread.local_thread_id);
    try s.objectField("provider");
    try s.write(@tagName(thread.provider));
    try s.objectField("title");
    try s.write(thread.title);
    try s.objectField("cancel_method");
    try s.write("chat.stop");
    try s.endObject();
    try s.endObject();
}

fn writeBackgroundWorkspaceProcesses(
    s: *std.json.Stringify,
    project: *const app_state.Project,
    project_index: usize,
    thread: *const app_state.ChatThread,
    thread_index: usize,
    archived: bool,
) !void {
    for (thread.background_tasks.items, 0..) |task, task_index| {
        var id_buffer: [256]u8 = undefined;
        const process_id = if (task.task_id) |task_id|
            std.fmt.bufPrint(&id_buffer, "task:{s}", .{task_id}) catch task_id
        else
            std.fmt.bufPrint(&id_buffer, "task:{s}:{d}", .{ thread.local_thread_id, task_index }) catch thread.local_thread_id;
        try s.beginObject();
        try s.objectField("id");
        try s.write(process_id);
        try s.objectField("source");
        try s.write("background_task");
        try s.objectField("workspace_index");
        try s.write(project_index);
        try s.objectField("workspace_id");
        try s.write(project.id);
        try s.objectField("name");
        try s.write(task.command);
        try s.objectField("command");
        try s.write(task.command);
        try s.objectField("cwd");
        try s.write(task.cwd orelse project.path);
        try s.objectField("status");
        try s.write(@tagName(task.status));
        try s.objectField("classification");
        try s.write(@tagName(app_state.classifyWorkspaceCommand(task.command)));
        try s.objectField("resources");
        try writeWorkspaceResources(s, &.{}, task.command);
        try s.objectField("pid");
        if (task.pid) |pid| try s.write(pid) else try s.write(null);
        try s.objectField("process_group");
        if (task.pid) |pid| try s.write(pid) else try s.write(null);
        try s.objectField("provider_process_id");
        if (task.process_id) |provider_process_id| try s.write(provider_process_id) else try s.write(null);
        try s.objectField("started_at_ms");
        try s.write(task.started_at_ms);
        try s.objectField("updated_at_ms");
        try s.write(task.updated_at_ms);
        try s.objectField("thread_index");
        try s.write(thread_index);
        try s.objectField("thread_id");
        try s.write(thread.local_thread_id);
        try s.objectField("archived_thread");
        try s.write(archived);
        try s.objectField("owner");
        try s.beginObject();
        try s.objectField("id");
        try s.write(thread.local_thread_id);
        try s.objectField("kind");
        try s.write("gui_agent");
        try s.objectField("thread_id");
        try s.write(thread.local_thread_id);
        try s.objectField("provider");
        try s.write(@tagName(thread.provider));
        try s.objectField("title");
        try s.write(thread.title);
        try s.objectField("cancel_method");
        try s.write("stop the owning agent or background PID");
        try s.endObject();
        try s.endObject();
    }
}

fn writeWorkspaceResources(s: *std.json.Stringify, explicit: anytype, command: []const u8) !void {
    try s.beginArray();
    for (explicit) |resource| try s.write(resource);
    if (app_state.inferredWorkspaceResource(command)) |inferred| {
        var duplicate = false;
        for (explicit) |resource| {
            if (std.mem.eql(u8, resource, inferred)) {
                duplicate = true;
                break;
            }
        }
        if (!duplicate) try s.write(inferred);
    }
    try s.endArray();
}

fn writeWorkspaceLeasesArray(s: *std.json.Stringify, state: *app_state.AppState, maybe_project_index: ?usize) !void {
    try s.beginArray();
    for (state.project_controller.projects.items, 0..) |*project, project_index| {
        if (maybe_project_index) |wanted| if (wanted != project_index) continue;
        for (project.workspace_leases.items) |*lease| {
            try s.beginObject();
            try s.objectField("id");
            try s.write(lease.id);
            try s.objectField("workspace_index");
            try s.write(project_index);
            try s.objectField("workspace_id");
            try s.write(project.id);
            try s.objectField("owner");
            try s.write(lease.owner);
            try s.objectField("command");
            try s.write(lease.command);
            try s.objectField("resources");
            try s.beginArray();
            for (lease.resources.items) |resource| try s.write(resource);
            try s.endArray();
            try s.objectField("created_at_ms");
            try s.write(lease.created_at_ms);
            try s.objectField("expires_at_ms");
            try s.write(lease.expires_at_ms);
            try s.endObject();
        }
    }
    try s.endArray();
}

const WorkspaceResourceRequest = struct {
    storage: [16][]const u8 = undefined,
    len: usize = 0,

    fn items(self: *const WorkspaceResourceRequest) []const []const u8 {
        return self.storage[0..self.len];
    }

    fn append(self: *WorkspaceResourceRequest, resource: []const u8) !void {
        const trimmed = std.mem.trim(u8, resource, " \t\r\n");
        if (trimmed.len == 0 or trimmed.len > 128) return error.InvalidResource;
        for (self.items()) |existing| {
            if (std.mem.eql(u8, existing, trimmed)) return;
        }
        if (self.len >= self.storage.len) return error.TooManyResources;
        self.storage[self.len] = trimmed;
        self.len += 1;
    }
};

fn workspaceResourceRequest(params: std.json.Value, command: []const u8) !WorkspaceResourceRequest {
    var request: WorkspaceResourceRequest = .{};
    if (params == .object) {
        if (params.object.get("resources")) |resources| {
            if (resources != .array) return error.InvalidResource;
            for (resources.array.items) |resource| {
                const value = jsonString(resource) orelse return error.InvalidResource;
                try request.append(value);
            }
        }
        if (stringParam(params, "resource")) |resource| try request.append(resource);
    }
    if (app_state.inferredWorkspaceResource(command)) |resource| try request.append(resource);
    return request;
}

fn workspaceCheckCommandResponse(
    allocator: std.mem.Allocator,
    id_value: std.json.Value,
    state: *app_state.AppState,
    params: std.json.Value,
    acquire_rejected: bool,
) ![]u8 {
    const project_index = resolveProjectIndex(state, params) orelse
        return try errorResponseAlloc(allocator, id_value, "not_found", "workspace not found");
    const command = stringParam(params, "command") orelse "";
    const owner = stringParam(params, "owner") orelse "";
    const resource_request = workspaceResourceRequest(params, command) catch |err|
        return try errorResponseAlloc(allocator, id_value, "invalid_request", @errorName(err));
    if (command.len == 0 and resource_request.len == 0) {
        return try errorResponseAlloc(allocator, id_value, "invalid_request", "workspace.checkCommand requires command or resources");
    }
    state.pollWorkspaceTerminalProcessLifecyclesForLiveRead(project_index);
    state.pruneExpiredWorkspaceLeases(project_index);

    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    var s: std.json.Stringify = .{ .writer = &writer.writer, .options = .{} };
    try beginOk(&s, id_value);
    try s.objectField("result");
    try s.beginObject();
    try s.objectField("workspace_index");
    try s.write(project_index);
    try s.objectField("workspace_id");
    try s.write(state.project_controller.projects.items[project_index].id);
    try s.objectField("command");
    try s.write(command);
    try s.objectField("classification");
    try s.write(@tagName(app_state.classifyWorkspaceCommand(command)));
    try s.objectField("resources");
    try s.beginArray();
    for (resource_request.items()) |resource| try s.write(resource);
    try s.endArray();
    try s.objectField("conflicts");
    const conflict_count = try writeWorkspaceConflicts(&s, state, project_index, owner, resource_request.items());
    try s.objectField("allowed");
    try s.write(conflict_count == 0);
    try s.objectField("conflict_count");
    try s.write(conflict_count);
    if (acquire_rejected) {
        try s.objectField("acquired");
        try s.write(false);
    }
    try s.objectField("warning");
    if (conflict_count > 0) try s.write("Another command owns a requested workspace resource.") else try s.write(null);
    try s.objectField("options");
    try s.beginArray();
    try s.write("wait");
    try s.write("cancel_existing");
    try s.write("run_anyway");
    try s.write("open_owner");
    try s.endArray();
    try s.endObject();
    try s.endObject();
    return try writer.toOwnedSlice();
}

fn workspaceAcquireLeaseResponse(allocator: std.mem.Allocator, id_value: std.json.Value, state: *app_state.AppState, params: std.json.Value) ![]u8 {
    const project_index = resolveProjectIndex(state, params) orelse
        return try errorResponseAlloc(allocator, id_value, "not_found", "workspace not found");
    const owner = stringParam(params, "owner") orelse
        return try errorResponseAlloc(allocator, id_value, "invalid_request", "workspace.acquireLease requires owner");
    const command = stringParam(params, "command") orelse "";
    const resources = workspaceResourceRequest(params, command) catch |err|
        return try errorResponseAlloc(allocator, id_value, "invalid_request", @errorName(err));
    if (resources.len == 0) return try errorResponseAlloc(allocator, id_value, "invalid_request", "workspace.acquireLease requires resources or a classified command");
    const force = boolParam(params, "force") orelse false;
    const ttl_ms = std.math.clamp(intParam(params, "ttl_ms") orelse 120_000, 1_000, 3_600_000);

    state.pollWorkspaceTerminalProcessLifecyclesForLiveRead(project_index);
    if (!force and workspaceProcessConflictCount(state, project_index, owner, resources.items()) > 0) {
        return try workspaceCheckCommandResponse(allocator, id_value, state, params, true);
    }
    const lease = state.acquireWorkspaceLease(project_index, owner, command, resources.items(), ttl_ms, force) catch |err| switch (err) {
        error.LeaseConflict => return try workspaceCheckCommandResponse(allocator, id_value, state, params, true),
        error.LeaseOwnerRequired, error.LeaseResourcesRequired => return try errorResponseAlloc(allocator, id_value, "invalid_request", @errorName(err)),
        else => return err,
    };
    if (force) notifyForcedWorkspaceConflictOwners(state, project_index, owner, command, resources.items());

    return try okValueResponse(allocator, id_value, .{
        .acquired = true,
        .forced = force,
        .workspace_index = project_index,
        .workspace_id = state.project_controller.projects.items[project_index].id,
        .lease_id = lease.id,
        .owner = lease.owner,
        .command = lease.command,
        .resources = lease.resources.items,
        .created_at_ms = lease.created_at_ms,
        .expires_at_ms = lease.expires_at_ms,
    });
}

fn workspaceReleaseLeaseResponse(allocator: std.mem.Allocator, id_value: std.json.Value, state: *app_state.AppState, params: std.json.Value) ![]u8 {
    const project_index = resolveProjectIndex(state, params) orelse
        return try errorResponseAlloc(allocator, id_value, "not_found", "workspace not found");
    const owner = stringParam(params, "owner") orelse
        return try errorResponseAlloc(allocator, id_value, "invalid_request", "workspace.releaseLease requires owner");
    const lease_id = stringParam(params, "lease_id") orelse stringParam(params, "id");
    const released = state.releaseWorkspaceLease(project_index, owner, lease_id);
    return try okValueResponse(allocator, id_value, .{
        .released = released,
        .workspace_index = project_index,
        .workspace_id = state.project_controller.projects.items[project_index].id,
        .lease_id = lease_id,
        .owner = owner,
    });
}

fn writeWorkspaceConflicts(
    s: *std.json.Stringify,
    state: *app_state.AppState,
    project_index: usize,
    request_owner: []const u8,
    request_resources: []const []const u8,
) !usize {
    var count: usize = 0;
    const project = &state.project_controller.projects.items[project_index];
    try s.beginArray();
    for (project.managed_processes.items) |*process| {
        if (!managedProcessStatusActive(process.status)) continue;
        const command = if (process.command.len > 0) process.command else process.name;
        const resource = conflictingWorkspaceResource(request_resources, process.resources.items, command) orelse continue;
        const dock = if (process.dock_id) |dock_id| state.projectTerminalDock(project_index, dock_id) else null;
        const session_id = if (dock) |process_dock| process_dock.activeSessionId() else null;
        if (session_id != null and std.mem.eql(u8, request_owner, session_id.?)) continue;
        const id = try std.fmt.allocPrint(state.allocator, "proc:{s}:{s}", .{ project.id, process.name });
        defer state.allocator.free(id);
        try writeWorkspaceConflict(s, .{
            .kind = "process",
            .source = "configured",
            .resource = resource,
            .id = id,
            .owner = session_id orelse id,
            .owner_kind = if (process.kind == .agent) "agent" else "managed_process",
            .session_id = session_id,
            .pane_id = process.pane_id,
            .command = command,
            .status = @tagName(process.status),
            .started_at_ms = process.last_start_ms,
            .cancel_method = "process.stop",
        });
        count += 1;
    }
    for (project.terminal_docks.items) |*entry| {
        if (managedProcessUsesDock(project, entry.id)) continue;
        count += try writeTerminalWorkspaceConflict(s, state, project_index, entry.id, &entry.dock, request_owner, request_resources);
    }
    count += try writeTerminalWorkspaceConflict(s, state, project_index, 0, &project.terminal_dock, request_owner, request_resources);
    for (project.threads.items) |*thread| count += try writeBackgroundWorkspaceConflicts(s, thread, request_owner, request_resources);
    for (project.archived_threads.items) |*thread| count += try writeBackgroundWorkspaceConflicts(s, thread, request_owner, request_resources);

    for (project.workspace_leases.items) |*lease| {
        if (std.mem.eql(u8, request_owner, lease.owner)) continue;
        const resource = firstWorkspaceResourceOverlap(request_resources, lease.resources.items) orelse continue;
        try writeWorkspaceConflict(s, .{
            .kind = "lease",
            .source = "lease",
            .resource = resource,
            .id = lease.id,
            .owner = lease.owner,
            .owner_kind = "agent",
            .command = lease.command,
            .status = "leased",
            .started_at_ms = lease.created_at_ms,
            .expires_at_ms = lease.expires_at_ms,
            .cancel_method = "workspace.releaseLease (owner only)",
        });
        count += 1;
    }
    try s.endArray();
    return count;
}

const WorkspaceConflict = struct {
    kind: []const u8,
    source: []const u8,
    resource: []const u8,
    id: []const u8,
    owner: []const u8,
    owner_kind: []const u8,
    session_id: ?[]const u8 = null,
    pane_id: ?u32 = null,
    thread_id: ?[]const u8 = null,
    command: []const u8,
    status: []const u8,
    started_at_ms: i64 = 0,
    expires_at_ms: ?i64 = null,
    cancel_method: []const u8,
};

fn writeWorkspaceConflict(s: *std.json.Stringify, conflict: WorkspaceConflict) !void {
    try s.beginObject();
    inline for (.{
        .{ "kind", conflict.kind },
        .{ "source", conflict.source },
        .{ "resource", conflict.resource },
        .{ "id", conflict.id },
        .{ "owner", conflict.owner },
        .{ "owner_kind", conflict.owner_kind },
        .{ "command", conflict.command },
        .{ "status", conflict.status },
        .{ "cancel_method", conflict.cancel_method },
    }) |field| {
        try s.objectField(field[0]);
        try s.write(field[1]);
    }
    try s.objectField("session_id");
    if (conflict.session_id) |value| try s.write(value) else try s.write(null);
    try s.objectField("pane_id");
    if (conflict.pane_id) |value| try s.write(value) else try s.write(null);
    try s.objectField("thread_id");
    if (conflict.thread_id) |value| try s.write(value) else try s.write(null);
    try s.objectField("started_at_ms");
    try s.write(conflict.started_at_ms);
    try s.objectField("expires_at_ms");
    if (conflict.expires_at_ms) |value| try s.write(value) else try s.write(null);
    try s.endObject();
}

fn writeTerminalWorkspaceConflict(
    s: *std.json.Stringify,
    state: *app_state.AppState,
    project_index: usize,
    dock_id: u32,
    dock: anytype,
    request_owner: []const u8,
    request_resources: []const []const u8,
) !usize {
    const snapshot = dock.activeRuntimeProcessSnapshot() orelse return 0;
    if (!snapshot.running) return 0;
    const session_id = dock.activeSessionId() orelse return 0;
    const project = &state.project_controller.projects.items[project_index];
    const tracked = project.terminalProcessActiveForSession(session_id) orelse return 0;
    if (std.mem.eql(u8, request_owner, session_id)) return 0;
    var label_buffer: [96]u8 = undefined;
    const command = dock.activeForegroundProcessName(&label_buffer) orelse dock.activeProcessLabel(&label_buffer);
    const resource = conflictingWorkspaceResource(request_resources, &.{}, command) orelse return 0;
    try writeWorkspaceConflict(s, .{
        .kind = "process",
        .source = "terminal",
        .resource = resource,
        .id = tracked.process_id,
        .owner = session_id,
        .owner_kind = if (state.surfaceBySessionIdConst(session_id) != null) "agent" else "terminal",
        .session_id = session_id,
        .pane_id = workspacePaneIdForDock(project, dock_id),
        .command = command,
        .status = "running",
        .started_at_ms = snapshot.started_at_ms,
        .cancel_method = "terminal.write Ctrl-C or close the pane",
    });
    return 1;
}

fn writeBackgroundWorkspaceConflicts(
    s: *std.json.Stringify,
    thread: *const app_state.ChatThread,
    request_owner: []const u8,
    request_resources: []const []const u8,
) !usize {
    if (std.mem.eql(u8, request_owner, thread.local_thread_id)) return 0;
    var count: usize = 0;
    for (thread.background_tasks.items, 0..) |task, task_index| {
        if (task.status != .running) continue;
        const resource = conflictingWorkspaceResource(request_resources, &.{}, task.command) orelse continue;
        var id_buffer: [256]u8 = undefined;
        const process_id = if (task.task_id) |task_id|
            std.fmt.bufPrint(&id_buffer, "task:{s}", .{task_id}) catch task_id
        else
            std.fmt.bufPrint(&id_buffer, "task:{s}:{d}", .{ thread.local_thread_id, task_index }) catch thread.local_thread_id;
        try writeWorkspaceConflict(s, .{
            .kind = "process",
            .source = "background_task",
            .resource = resource,
            .id = process_id,
            .owner = thread.local_thread_id,
            .owner_kind = "gui_agent",
            .thread_id = thread.local_thread_id,
            .command = task.command,
            .status = "running",
            .started_at_ms = task.started_at_ms,
            .cancel_method = "stop the owning agent or background PID",
        });
        count += 1;
    }
    return count;
}

fn managedProcessStatusActive(status: app_state.ManagedProcessStatus) bool {
    return status == .starting or status == .running or status == .stopping or status == .restarting;
}

fn conflictingWorkspaceResource(request: []const []const u8, explicit: anytype, command: []const u8) ?[]const u8 {
    if (firstWorkspaceResourceOverlap(request, explicit)) |resource| return resource;
    const inferred = app_state.inferredWorkspaceResource(command) orelse return null;
    for (request) |resource| if (std.mem.eql(u8, resource, inferred)) return resource;
    return null;
}

fn firstWorkspaceResourceOverlap(left: anytype, right: anytype) ?[]const u8 {
    for (left) |left_resource| {
        for (right) |right_resource| {
            if (std.mem.eql(u8, left_resource, right_resource)) return left_resource;
        }
    }
    return null;
}

fn workspaceProcessConflictCount(state: *app_state.AppState, project_index: usize, owner: []const u8, resources: []const []const u8) usize {
    if (project_index >= state.project_controller.projects.items.len) return 0;
    const project = &state.project_controller.projects.items[project_index];
    var count: usize = 0;
    for (project.managed_processes.items) |*process| {
        if (!managedProcessStatusActive(process.status)) continue;
        const command = if (process.command.len > 0) process.command else process.name;
        if (conflictingWorkspaceResource(resources, process.resources.items, command) == null) continue;
        const session_id = if (process.dock_id) |dock_id|
            if (state.projectTerminalDock(project_index, dock_id)) |dock| dock.activeSessionId() else null
        else
            null;
        if (session_id != null and std.mem.eql(u8, owner, session_id.?)) continue;
        count += 1;
    }
    for (project.terminal_docks.items) |*entry| {
        if (managedProcessUsesDock(project, entry.id)) continue;
        count += terminalWorkspaceConflictCount(&entry.dock, owner, resources);
    }
    count += terminalWorkspaceConflictCount(&project.terminal_dock, owner, resources);
    for (project.threads.items) |*thread| count += backgroundWorkspaceConflictCount(thread, owner, resources);
    for (project.archived_threads.items) |*thread| count += backgroundWorkspaceConflictCount(thread, owner, resources);
    return count;
}

fn terminalWorkspaceConflictCount(dock: anytype, owner: []const u8, resources: []const []const u8) usize {
    const snapshot = dock.activeRuntimeProcessSnapshot() orelse return 0;
    if (!snapshot.running) return 0;
    const session_id = dock.activeSessionId() orelse return 0;
    if (std.mem.eql(u8, owner, session_id)) return 0;
    var label_buffer: [96]u8 = undefined;
    const command = dock.activeForegroundProcessName(&label_buffer) orelse dock.activeProcessLabel(&label_buffer);
    return if (conflictingWorkspaceResource(resources, &.{}, command) != null) 1 else 0;
}

fn backgroundWorkspaceConflictCount(thread: *const app_state.ChatThread, owner: []const u8, resources: []const []const u8) usize {
    if (std.mem.eql(u8, owner, thread.local_thread_id)) return 0;
    var count: usize = 0;
    for (thread.background_tasks.items) |task| {
        if (task.status == .running and conflictingWorkspaceResource(resources, &.{}, task.command) != null) count += 1;
    }
    return count;
}

fn notifyForcedWorkspaceConflictOwners(
    state: *app_state.AppState,
    project_index: usize,
    request_owner: []const u8,
    command: []const u8,
    resources: []const []const u8,
) void {
    if (project_index >= state.project_controller.projects.items.len) return;
    const project = &state.project_controller.projects.items[project_index];
    for (project.terminal_docks.items) |*entry| {
        notifyForcedWorkspaceDockOwner(state, &entry.dock, request_owner, command, resources);
    }
    notifyForcedWorkspaceDockOwner(state, &project.terminal_dock, request_owner, command, resources);
}

fn notifyForcedWorkspaceDockOwner(
    state: *app_state.AppState,
    dock: anytype,
    request_owner: []const u8,
    command: []const u8,
    resources: []const []const u8,
) void {
    if (terminalWorkspaceConflictCount(dock, request_owner, resources) == 0) return;
    const session_id = dock.activeSessionId() orelse return;
    if (state.surfaceBySessionIdConst(session_id) == null) return;
    _ = state.updateSurface(.{
        .session_id = session_id,
        .attention = true,
        .unread_increment = 1,
        .last_event_title = "Conflicting command started",
        .last_event_body = command,
    }) catch {};
}

fn managedProcessesResponse(allocator: std.mem.Allocator, id_value: std.json.Value, state: *app_state.AppState, params: std.json.Value) ![]u8 {
    const project_index = resolveProjectIndexNullable(state, params);
    if (project_index) |index| {
        if (index >= state.project_controller.projects.items.len) return try errorResponseAlloc(allocator, id_value, "not_found", "workspace not found");
        if (try refreshStackConfigOrError(allocator, id_value, state, index)) |response| return response;
    } else {
        var index: usize = 0;
        while (index < state.project_controller.projects.items.len) : (index += 1) {
            if (try refreshStackConfigOrError(allocator, id_value, state, index)) |response| return response;
        }
    }

    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    var s: std.json.Stringify = .{ .writer = &writer.writer, .options = .{} };
    try beginOk(&s, id_value);
    try s.objectField("result");
    try s.beginObject();
    try s.objectField("processes");
    try writeManagedProcessesArray(&s, state, project_index);
    try s.endObject();
    try s.endObject();
    return try writer.toOwnedSlice();
}

fn managedProcessesResponseForProject(allocator: std.mem.Allocator, id_value: std.json.Value, state: *app_state.AppState, project_index: usize) ![]u8 {
    if (project_index >= state.project_controller.projects.items.len) return try errorResponseAlloc(allocator, id_value, "not_found", "workspace not found");
    state.refreshManagedProcessStatuses(project_index);

    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    var s: std.json.Stringify = .{ .writer = &writer.writer, .options = .{} };
    try beginOk(&s, id_value);
    try s.objectField("result");
    try s.beginObject();
    try s.objectField("workspace_index");
    try s.write(project_index);
    try s.objectField("workspace_id");
    try s.write(state.project_controller.projects.items[project_index].id);
    try s.objectField("stack_config_error");
    if (state.project_controller.projects.items[project_index].stack_config_error) |message| try s.write(message) else try s.write(null);
    try s.objectField("processes");
    try writeManagedProcessesArray(&s, state, project_index);
    try s.endObject();
    try s.endObject();
    return try writer.toOwnedSlice();
}

fn managedProcessResponse(allocator: std.mem.Allocator, id_value: std.json.Value, state: *app_state.AppState, project_index: usize, name: []const u8) ![]u8 {
    if (project_index >= state.project_controller.projects.items.len) return try errorResponseAlloc(allocator, id_value, "not_found", "workspace not found");
    state.refreshManagedProcessStatuses(project_index);
    const project = &state.project_controller.projects.items[project_index];
    const process = project.managedProcessByName(name) orelse
        return try errorResponseAlloc(allocator, id_value, "not_found", "process not found");

    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    var s: std.json.Stringify = .{ .writer = &writer.writer, .options = .{} };
    try beginOk(&s, id_value);
    try s.objectField("result");
    try writeManagedProcess(&s, state, project_index, process);
    try s.endObject();
    return try writer.toOwnedSlice();
}

fn writeManagedProcessesArray(s: *std.json.Stringify, state: *app_state.AppState, maybe_project_index: ?usize) !void {
    try s.beginArray();
    for (state.project_controller.projects.items, 0..) |*project, project_index| {
        if (maybe_project_index) |wanted| {
            if (wanted != project_index) continue;
        }
        state.refreshProjectStackConfig(project_index) catch {};
        state.refreshManagedProcessStatuses(project_index);
        for (project.managed_processes.items) |*process| {
            try writeManagedProcess(s, state, project_index, process);
        }
    }
    try s.endArray();
}

fn writeManagedProcess(s: *std.json.Stringify, state: *app_state.AppState, project_index: usize, process: *const app_state.ManagedProcess) !void {
    const project = &state.project_controller.projects.items[project_index];
    const process_id = try std.fmt.allocPrint(state.allocator, "proc:{s}:{s}", .{ project.id, process.name });
    defer state.allocator.free(process_id);
    const dock = if (process.dock_id) |dock_id| state.projectTerminalDock(project_index, dock_id) else null;
    const runtime_process = if (dock) |active_dock| active_dock.activeRuntimeProcessSnapshot() else null;
    const session_id = if (dock) |active_dock| active_dock.activeSessionId() else null;
    try s.beginObject();
    try s.objectField("id");
    try s.write(process_id);
    try s.objectField("source");
    try s.write("configured");
    try s.objectField("workspace_index");
    try s.write(project_index);
    try s.objectField("workspace_id");
    try s.write(project.id);
    try s.objectField("name");
    try s.write(process.name);
    try s.objectField("kind");
    try s.write(@tagName(process.kind));
    try s.objectField("command");
    try s.write(process.command);
    try s.objectField("cwd");
    try s.write(process.cwd);
    try s.objectField("restart");
    try s.write(@tagName(process.restart));
    try s.objectField("provider");
    if (process.provider) |provider| try s.write(@tagName(provider)) else try s.write(null);
    try s.objectField("revive");
    try s.write(@tagName(process.revive));
    try s.objectField("notify");
    try s.write(process.notify);
    try s.objectField("mcp");
    try s.write(process.mcp);
    try s.objectField("hooks");
    try s.write(process.hooks);
    try s.objectField("status");
    try s.write(@tagName(process.status));
    try s.objectField("classification");
    try s.write(@tagName(app_state.classifyWorkspaceCommand(if (process.command.len > 0) process.command else process.name)));
    try s.objectField("resources");
    try writeWorkspaceResources(s, process.resources.items, if (process.command.len > 0) process.command else process.name);
    try s.objectField("owner");
    try s.beginObject();
    try s.objectField("id");
    if (session_id) |value| try s.write(value) else try s.write(process_id);
    try s.objectField("kind");
    try s.write(if (process.kind == .agent) "agent" else "managed_process");
    try s.objectField("session_id");
    if (session_id) |value| try s.write(value) else try s.write(null);
    try s.objectField("cancel_method");
    try s.write("process.stop");
    try s.endObject();
    try s.objectField("pid");
    if (runtime_process) |snapshot| {
        if (snapshot.pid) |pid| try s.write(pid) else try s.write(null);
    } else try s.write(null);
    try s.objectField("process_group");
    if (runtime_process) |snapshot| {
        if (snapshot.process_group) |process_group| try s.write(process_group) else try s.write(null);
    } else try s.write(null);
    try s.objectField("exit_code");
    if (process.exit_code) |exit_code| try s.write(exit_code) else try s.write(null);
    try s.objectField("signal");
    if (process.signal) |signal| try s.write(signal) else try s.write(null);
    try s.objectField("last_start_ms");
    try s.write(process.last_start_ms);
    try s.objectField("last_exit_ms");
    try s.write(process.last_exit_ms);
    try s.objectField("next_restart_ms");
    try s.write(process.next_restart_ms);
    try s.objectField("restart_count");
    try s.write(process.restart_count);
    try s.objectField("watch_trigger_count");
    try s.write(process.watch_trigger_count);
    try s.objectField("last_watch_scan_ms");
    try s.write(process.last_watch_scan_ms);
    try s.objectField("last_watch_change_ms");
    try s.write(process.last_watch_change_ms);
    try s.objectField("pending_watch_restart_ms");
    try s.write(process.pending_watch_restart_ms);
    try s.objectField("watch_ready");
    try s.write(process.watch_ready);
    try s.objectField("watch_error_count");
    try s.write(process.watch_error_count);
    try s.objectField("explicit_stop");
    try s.write(process.explicit_stop);
    try s.objectField("watch");
    try s.beginArray();
    for (process.watch.items) |pattern| try s.write(pattern);
    try s.endArray();
    try s.objectField("dock_id");
    if (process.dock_id) |dock_id| try s.write(dock_id) else try s.write(null);
    try s.objectField("pane_id");
    if (process.pane_id) |pane_id| try s.write(pane_id) else try s.write(null);
    try s.objectField("attention");
    try s.write(process.status == .crashed or process.pending_watch_restart_ms != 0);
    try s.objectField("attention_reasons");
    try s.beginArray();
    if (process.status == .crashed) try s.write("process_crashed");
    if (process.pending_watch_restart_ms != 0) try s.write("watch_restart_pending");
    try s.endArray();
    if (process.dock_id) |dock_id| {
        if (state.projectTerminalDock(project_index, dock_id)) |process_dock| {
            try s.objectField("running");
            try s.write(process_dock.hasRunningSession());
            try s.objectField("active_tab_index");
            try s.write(process_dock.active_tab_index);
            try s.objectField("tab_count");
            try s.write(process_dock.tabs.items.len);
            try s.objectField("terminal_cwd");
            if (process_dock.cwd) |cwd| try s.write(cwd) else try s.write(null);
        }
    }
    try s.endObject();
}

fn refreshStackConfigOrError(allocator: std.mem.Allocator, id_value: std.json.Value, state: *app_state.AppState, project_index: usize) !?[]u8 {
    state.refreshProjectStackConfig(project_index) catch |err| switch (err) {
        error.InvalidStackConfig => return try errorResponseAlloc(allocator, id_value, "invalid_stack_config", stackConfigErrorMessage(state, project_index, err)),
        else => return err,
    };
    return null;
}

fn stackConfigErrorMessage(state: *app_state.AppState, project_index: usize, err: anyerror) []const u8 {
    if (project_index < state.project_controller.projects.items.len) {
        if (state.project_controller.projects.items[project_index].stack_config_error) |message| return message;
    }
    return @errorName(err);
}

fn threadHasPendingApproval(thread: *const app_state.ChatThread) bool {
    const send_state = thread.send_state;
    if (!send_state.mutex.tryLock()) return true;
    defer send_state.mutex.unlock();
    return send_state.status == .pending and send_state.pending_approval != null;
}

fn terminalDockHasAttention(state: *const app_state.AppState, project_index: usize, project: *const app_state.Project, dock_id: u32) bool {
    if (state.terminalDockSurfaceAttention(project_index, dock_id)) return true;
    for (project.managed_processes.items) |process| {
        if (process.dock_id == null or process.dock_id.? != dock_id) continue;
        if (process.status == .crashed or process.pending_watch_restart_ms != 0) return true;
    }
    return false;
}

fn writeTerminalAttentionReasons(s: *std.json.Stringify, state: *const app_state.AppState, project_index: usize, project: *const app_state.Project, dock_id: u32) !void {
    try s.beginArray();
    if (state.terminalDockSurfaceAttention(project_index, dock_id)) try s.write("surface_attention");
    for (project.managed_processes.items) |process| {
        if (process.dock_id == null or process.dock_id.? != dock_id) continue;
        if (process.status == .crashed) try s.write("process_crashed");
        if (process.pending_watch_restart_ms != 0) try s.write("watch_restart_pending");
    }
    try s.endArray();
}

fn writeSurface(s: *std.json.Stringify, surface: *const app_state.SurfaceState) !void {
    try s.beginObject();
    try s.objectField("session_id");
    try s.write(surface.session_id);
    try s.objectField("workspace_id");
    try s.write(surface.workspace_id);
    try s.objectField("workspace_path");
    try s.write(surface.workspace_path);
    try s.objectField("dock_id");
    try s.write(surface.dock_id);
    try s.objectField("pane_id");
    if (surface.pane_id) |value| try s.write(value) else try s.write(null);
    try s.objectField("provider");
    if (surface.provider) |value| try s.write(@tagName(value)) else try s.write(null);
    try s.objectField("provider_thread_id");
    if (surface.provider_thread_id) |value| try s.write(value) else try s.write(null);
    try s.objectField("title");
    try s.write(surface.title);
    try s.objectField("status");
    try s.write(@tagName(surface.status));
    try s.objectField("display_status");
    try s.write(@tagName(surface.displayStatus()));
    try s.objectField("completion_pending");
    try s.write(surface.completion_pending);
    try s.objectField("completed_at_ms");
    if (surface.completion_pending) try s.write(surface.completed_at_ms) else try s.write(null);
    try s.objectField("progress");
    if (surface.progress) |value| try s.write(value) else try s.write(null);
    try s.objectField("attention");
    try s.write(surface.attention);
    try s.objectField("unread_count");
    try s.write(surface.unread_count);
    try s.objectField("last_event_title");
    if (surface.last_event_title) |value| try s.write(value) else try s.write(null);
    try s.objectField("last_event_body");
    if (surface.last_event_body) |value| try s.write(value) else try s.write(null);
    try s.objectField("last_event_at_ms");
    try s.write(surface.last_event_at_ms);
    try s.endObject();
}

fn surfaceResultResponse(allocator: std.mem.Allocator, id_value: std.json.Value, surface: *const app_state.SurfaceState) ![]u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    var s: std.json.Stringify = .{ .writer = &writer.writer, .options = .{} };
    try beginOk(&s, id_value);
    try s.objectField("result");
    try s.beginObject();
    try s.objectField("surface");
    try writeSurface(&s, surface);
    try s.endObject();
    try s.endObject();
    return try writer.toOwnedSlice();
}

fn supersededSurfaceResponse(allocator: std.mem.Allocator, id_value: std.json.Value, session_id: []const u8) ![]u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    var s: std.json.Stringify = .{ .writer = &writer.writer, .options = .{} };
    try beginOk(&s, id_value);
    try s.objectField("result");
    try s.beginObject();
    try s.objectField("session_id");
    try s.write(session_id);
    try s.objectField("ignored");
    try s.write(true);
    try s.objectField("superseded");
    try s.write(true);
    try s.endObject();
    try s.endObject();
    return try writer.toOwnedSlice();
}

fn resolveSurfaceProjectIndex(state: *const app_state.AppState, surface: *const app_state.SurfaceState) ?usize {
    for (state.project_controller.projects.items, 0..) |project, index| {
        if (surface.workspace_id.len > 0 and std.mem.eql(u8, surface.workspace_id, project.id)) return index;
        if (surface.workspace_path.len > 0 and std.mem.eql(u8, surface.workspace_path, project.path)) return index;
    }
    return null;
}

fn chatStatusResponse(allocator: std.mem.Allocator, id_value: std.json.Value, state: *app_state.AppState, project_index: usize, pane_id: app_state.WorkspacePaneId) ![]u8 {
    const project = &state.project_controller.projects.items[project_index];
    const pane = project.workspace_layout.paneById(pane_id) orelse return try errorResponseAlloc(allocator, id_value, "not_found", "pane not found");
    const ref = switch (pane.ref) {
        .chat => |chat_ref| chat_ref,
        else => return try errorResponseAlloc(allocator, id_value, "invalid_target", "target pane is not a chat pane"),
    };
    if (ref.thread_index >= project.threads.items.len) return try errorResponseAlloc(allocator, id_value, "not_found", "thread not found");
    const thread = &project.threads.items[ref.thread_index];

    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    var s: std.json.Stringify = .{ .writer = &writer.writer, .options = .{} };
    try beginOk(&s, id_value);
    try s.objectField("result");
    try s.beginObject();
    try s.objectField("workspace_index");
    try s.write(project_index);
    try s.objectField("pane_id");
    try s.write(pane_id);
    try s.objectField("thread");
    try writeThreadSummary(&s, thread.*, ref.thread_index);
    try s.objectField("draft_len");
    try s.write(std.mem.sliceTo(thread.draft_storage[0..], 0).len);
    try s.objectField("pending_approval");
    try writePendingApproval(&s, thread);
    try s.endObject();
    try s.endObject();
    return try writer.toOwnedSlice();
}

fn chatOpenResultResponse(
    allocator: std.mem.Allocator,
    id_value: std.json.Value,
    workspace_id: []const u8,
    workspace_index: usize,
    result: app_state.OpenChatResult,
    thread_id: []const u8,
    thread: app_state.ChatThread,
) ![]u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    var s: std.json.Stringify = .{ .writer = &writer.writer, .options = .{} };
    try beginOk(&s, id_value);
    try s.objectField("result");
    try s.beginObject();
    try s.objectField("workspace_id");
    try s.write(workspace_id);
    try s.objectField("workspace_index");
    try s.write(workspace_index);
    try s.objectField("pane_id");
    try s.write(result.pane_id);
    try s.objectField("thread_id");
    try s.write(thread_id);
    // The GUI Live arm keys threads by local_thread_id; emit it alongside the
    // legacy thread_id (same value) so both open_chat arms expose one stable id.
    try s.objectField("local_thread_id");
    try s.write(thread_id);
    try s.objectField("created");
    try s.write(true);
    try s.objectField("presented");
    try s.write(true);
    try s.objectField("thread_index");
    try s.write(result.thread_index);
    try s.objectField("provider");
    try s.write(@tagName(thread.provider));
    try s.objectField("model");
    if (thread.model_ref) |model| try s.write(model) else try s.write(null);
    try writeThreadCreationSettings(&s, thread);
    try s.objectField("focused");
    try s.write(result.focused);
    try s.endObject();
    try s.endObject();
    return try writer.toOwnedSlice();
}

fn chatTranscriptResponse(allocator: std.mem.Allocator, id_value: std.json.Value, state: *app_state.AppState, project_index: usize, pane_id: app_state.WorkspacePaneId) ![]u8 {
    const project = &state.project_controller.projects.items[project_index];
    const pane = project.workspace_layout.paneById(pane_id) orelse return try errorResponseAlloc(allocator, id_value, "not_found", "pane not found");
    const ref = switch (pane.ref) {
        .chat => |chat_ref| chat_ref,
        else => return try errorResponseAlloc(allocator, id_value, "invalid_target", "target pane is not a chat pane"),
    };
    if (ref.thread_index >= project.threads.items.len) return try errorResponseAlloc(allocator, id_value, "not_found", "thread not found");
    const thread = &project.threads.items[ref.thread_index];
    if (!transcriptFitsLiveResponse(thread.messages.items, LIVE_MAX_RESPONSE_BYTES)) {
        return try errorResponseAlloc(
            allocator,
            id_value,
            "response_too_large",
            "transcript exceeds the live response limit; use `verde state transcript` for the complete offline transcript",
        );
    }

    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    var s: std.json.Stringify = .{ .writer = &writer.writer, .options = .{} };
    try beginOk(&s, id_value);
    try s.objectField("result");
    try s.beginObject();
    try s.objectField("workspace_index");
    try s.write(project_index);
    try s.objectField("pane_id");
    try s.write(pane_id);
    try s.objectField("thread_index");
    try s.write(ref.thread_index);
    try s.objectField("messages");
    try s.beginArray();
    for (thread.messages.items) |message| {
        try s.beginObject();
        try s.objectField("role");
        try s.write(@tagName(message.role));
        try s.objectField("author");
        try s.write(message.author);
        try s.objectField("body");
        try s.write(message.body);
        try s.endObject();
    }
    try s.endArray();
    try s.endObject();
    try s.endObject();
    return try writer.toOwnedSlice();
}

/// JSON escaping can expand each input byte to six bytes. Reserve fixed syntax
/// space per row so the transcript writer cannot cross the transport cap.
fn transcriptFitsLiveResponse(messages: []const app_state.ChatMessage, max_bytes: usize) bool {
    var remaining = max_bytes;
    if (remaining < 512) return false;
    remaining -= 512;
    for (messages) |message| {
        if (remaining < 64) return false;
        remaining -= 64;
        const role = @tagName(message.role);
        for ([_][]const u8{ role, message.author, message.body }) |text| {
            if (text.len > remaining / 6) return false;
            remaining -= text.len * 6;
        }
    }
    return true;
}

fn inspectPaneResponse(allocator: std.mem.Allocator, id_value: std.json.Value, state: *app_state.AppState, project_index: usize, pane_id: app_state.WorkspacePaneId) ![]u8 {
    const project = &state.project_controller.projects.items[project_index];
    const pane = project.workspace_layout.paneById(pane_id) orelse return try errorResponseAlloc(allocator, id_value, "not_found", "pane not found");
    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    var s: std.json.Stringify = .{ .writer = &writer.writer, .options = .{} };
    try beginOk(&s, id_value);
    try s.objectField("result");
    try writePane(&s, state, project_index, pane.*);
    try s.endObject();
    return try writer.toOwnedSlice();
}

fn writePendingApproval(s: *std.json.Stringify, thread: *const app_state.ChatThread) !void {
    const send_state = thread.send_state;
    send_state.mutex.lock();
    defer send_state.mutex.unlock();
    if (send_state.status != .pending or send_state.pending_approval == null) {
        try s.write(null);
        return;
    }
    const approval = send_state.pending_approval.?;
    try s.beginObject();
    try s.objectField("call_id");
    try s.write(approval.call_id);
    try s.objectField("title");
    try s.write(approval.title);
    try s.objectField("body");
    try s.write(approval.body);
    try s.endObject();
}

fn beginOk(s: *std.json.Stringify, id_value: std.json.Value) !void {
    try s.beginObject();
    try s.objectField("id");
    try writeJsonValue(s, id_value);
    try s.objectField("ok");
    try s.write(true);
}

fn okValueResponse(allocator: std.mem.Allocator, id_value: std.json.Value, value: anytype) ![]u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    var s: std.json.Stringify = .{ .writer = &writer.writer, .options = .{} };
    try beginOk(&s, id_value);
    try s.objectField("result");
    try s.write(value);
    try s.endObject();
    return try writer.toOwnedSlice();
}

fn errorResponseAlloc(allocator: std.mem.Allocator, id_value: ?std.json.Value, code: []const u8, message: []const u8) ![]u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    var s: std.json.Stringify = .{ .writer = &writer.writer, .options = .{} };
    try s.beginObject();
    try s.objectField("id");
    if (id_value) |value| try writeJsonValue(&s, value) else try s.write(null);
    try s.objectField("ok");
    try s.write(false);
    try s.objectField("error");
    try s.beginObject();
    try s.objectField("code");
    try s.write(code);
    try s.objectField("message");
    try s.write(message);
    try s.endObject();
    try s.endObject();
    return try writer.toOwnedSlice();
}

fn writeJsonValue(s: *std.json.Stringify, value: std.json.Value) !void {
    switch (value) {
        .integer => |v| try s.write(v),
        .float => |v| try s.write(v),
        .number_string => |v| try s.write(v),
        .string => |v| try s.write(v),
        .bool => |v| try s.write(v),
        .null => try s.write(null),
        else => try s.write(null),
    }
}

fn stringParam(params: std.json.Value, name: []const u8) ?[]const u8 {
    if (params != .object) return null;
    return jsonString(params.object.get(name) orelse .null);
}

fn intParam(params: std.json.Value, name: []const u8) ?i64 {
    if (params != .object) return null;
    return jsonInt(params.object.get(name) orelse .null);
}

fn u32Param(params: std.json.Value, name: []const u8) ?u32 {
    const value = intParam(params, name) orelse return null;
    if (value < 0 or value > std.math.maxInt(u32)) return null;
    return @intCast(value);
}

fn u64Param(params: std.json.Value, name: []const u8) ?u64 {
    const value = intParam(params, name) orelse return null;
    if (value < 0) return null;
    return @intCast(value);
}

fn surfaceCommitProof(params: std.json.Value) ?app_state.SurfaceCommitProof {
    return .{
        .request_key = stringParam(params, "store_request_key") orelse return null,
        .store_revision = u64Param(params, "store_revision") orelse return null,
    };
}

fn floatParam(params: std.json.Value, name: []const u8) ?f32 {
    if (params != .object) return null;
    const value = params.object.get(name) orelse .null;
    return switch (value) {
        .integer => |i| @floatFromInt(i),
        .float => |f| @floatCast(f),
        .number_string => |text| blk: {
            if (std.fmt.parseFloat(f32, text)) |parsed| break :blk parsed else |_| break :blk null;
        },
        else => null,
    };
}

fn boolParam(params: std.json.Value, name: []const u8) ?bool {
    if (params != .object) return null;
    return switch (params.object.get(name) orelse .null) {
        .bool => |value| value,
        else => null,
    };
}

fn paramIsNonNull(params: std.json.Value, name: []const u8) bool {
    if (params != .object) return false;
    return switch (params.object.get(name) orelse .null) {
        .null => false,
        else => true,
    };
}

fn parseSurfaceStatus(value: []const u8) ?app_state.SurfaceStatus {
    inline for (std.meta.fields(app_state.SurfaceStatus)) |field| {
        if (std.mem.eql(u8, value, field.name)) return @enumFromInt(field.value);
    }
    return null;
}

fn parseProvider(value: []const u8) ?app_state.Provider {
    inline for (std.meta.fields(app_state.Provider)) |field| {
        if (std.mem.eql(u8, value, field.name)) return @enumFromInt(field.value);
    }
    return null;
}

fn parseSurfaceProvider(value: []const u8) ?app_state.SurfaceProvider {
    inline for (std.meta.fields(app_state.SurfaceProvider)) |field| {
        if (std.mem.eql(u8, value, field.name)) return @enumFromInt(field.value);
    }
    return null;
}

fn parseInspectorMode(value: []const u8) ?browser_runtime.InspectorMode {
    if (std.mem.eql(u8, value, "point")) return .point;
    if (std.mem.eql(u8, value, "draw-box") or std.mem.eql(u8, value, "draw_box")) return .draw_box;
    if (std.mem.eql(u8, value, "draw-freeform") or std.mem.eql(u8, value, "draw_freeform")) return .draw_freeform;
    return null;
}

fn jsonString(value: std.json.Value) ?[]const u8 {
    return switch (value) {
        .string => |text| text,
        else => null,
    };
}

fn jsonInt(value: std.json.Value) ?i64 {
    return switch (value) {
        .integer => |int| int,
        .number_string => |text| std.fmt.parseInt(i64, text, 10) catch null,
        else => null,
    };
}

fn parseAxis(value: []const u8) ?app_state.WorkspaceSplitAxis {
    if (std.mem.eql(u8, value, "horizontal")) return .horizontal;
    if (std.mem.eql(u8, value, "vertical")) return .vertical;
    return null;
}

fn parsePaneDirection(value: []const u8) ?app_state.WorkspacePaneDirection {
    if (std.mem.eql(u8, value, "left")) return .left;
    if (std.mem.eql(u8, value, "right")) return .right;
    if (std.mem.eql(u8, value, "up")) return .up;
    if (std.mem.eql(u8, value, "down")) return .down;
    return null;
}

fn parseApprovalDecision(value: []const u8) ?provider_types.ApprovalDecision {
    if (std.mem.eql(u8, value, "approve") or std.mem.eql(u8, value, "approved") or std.mem.eql(u8, value, "allow")) return .approve;
    if (std.mem.eql(u8, value, "deny") or std.mem.eql(u8, value, "reject") or std.mem.eql(u8, value, "rejected")) return .deny;
    return null;
}

test "live transcript response budget is bounded before JSON allocation" {
    const messages = [_]app_state.ChatMessage{.{
        .role = .user,
        .author = "You",
        .body = "hello",
    }};
    try std.testing.expect(transcriptFitsLiveResponse(&messages, 1024));
    try std.testing.expect(!transcriptFitsLiveResponse(&messages, 512));
}

test "browser commands resolve explicit MCP workspace before active runtime owner" {
    try std.testing.expectEqual(@as(usize, 2), chooseBrowserCommandProjectIndex(0, 1, 2));
    try std.testing.expectEqual(@as(usize, 0), chooseBrowserCommandProjectIndex(0, 1, null));
    try std.testing.expectEqual(@as(usize, 1), chooseBrowserCommandProjectIndex(null, 1, null));
}

test "chat open response exposes stable identifiers" {
    const allocator = std.testing.allocator;
    var thread: app_state.ChatThread = undefined;
    thread.provider = .codex;
    thread.model_ref = app_state.DEFAULT_CODEX_MODEL;
    thread.reasoning_effort = .high;
    thread.opencode_reasoning_variant = null;
    thread.fast_mode = .off;
    const response = try chatOpenResultResponse(
        allocator,
        .{ .integer = 9 },
        "workspace-1",
        2,
        .{ .pane_id = 7, .thread_index = 3, .focused = true },
        "chat-123",
        thread,
    );
    defer allocator.free(response);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, response, .{});
    defer parsed.deinit();
    const result = parsed.value.object.get("result").?.object;
    try std.testing.expectEqualStrings("workspace-1", jsonString(result.get("workspace_id").?).?);
    try std.testing.expectEqual(@as(i64, 7), jsonInt(result.get("pane_id").?).?);
    try std.testing.expectEqualStrings("chat-123", jsonString(result.get("thread_id").?).?);
    try std.testing.expectEqualStrings(
        jsonString(result.get("thread_id").?).?,
        jsonString(result.get("local_thread_id").?).?,
    );
    try std.testing.expect(boolParam(.{ .object = result }, "created").?);
    try std.testing.expect(boolParam(.{ .object = result }, "presented").?);
    try std.testing.expectEqualStrings("codex", jsonString(result.get("provider").?).?);
    try std.testing.expectEqualStrings("gpt-5.6-sol", jsonString(result.get("model").?).?);
    try std.testing.expectEqualStrings("high", jsonString(result.get("reasoning_effort").?).?);
    try std.testing.expect(!(boolParam(.{ .object = result }, "fast_mode").?));
    try std.testing.expectEqualStrings("default", jsonString(result.get("service_tier").?).?);
    try std.testing.expect(boolParam(.{ .object = result }, "focused").?);
}

test "chat open IPC parses typed creation settings without losing false" {
    const allocator = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        \\{"reasoning_effort":"medium","reasoning_variant":null,"fast_mode":false}
    ,
        .{},
    );
    defer parsed.deinit();
    const settings = try parseChatOpenSettings(parsed.value);
    try std.testing.expectEqual(app_state.ReasoningEffort.medium, settings.reasoning_effort.?);
    try std.testing.expect(settings.reasoning_variant == null);
    try std.testing.expectEqual(app_state.FastMode.off, settings.fast_mode.?);

    var invalid = try std.json.parseFromSlice(std.json.Value, allocator, "{\"reasoning_effort\":\"extreme\"}", .{});
    defer invalid.deinit();
    try std.testing.expectError(error.InvalidReasoningEffortValue, parseChatOpenSettings(invalid.value));
}

test "GUI provider parser excludes terminal-only providers" {
    try std.testing.expectEqual(app_state.Provider.opencode, parseProvider("opencode").?);
    try std.testing.expectEqual(app_state.Provider.codex, parseProvider("codex").?);
    try std.testing.expectEqual(app_state.Provider.claude, parseProvider("claude").?);
    try std.testing.expectEqual(app_state.Provider.cursor, parseProvider("cursor").?);
    try std.testing.expect(parseProvider("amp") == null);
    try std.testing.expect(parseProvider("other") == null);
}

test "surface provider parser includes terminal-only providers" {
    try std.testing.expectEqual(app_state.SurfaceProvider.grok, parseSurfaceProvider("grok").?);
    try std.testing.expectEqual(app_state.SurfaceProvider.amp, parseSurfaceProvider("amp").?);
    try std.testing.expect(parseSurfaceProvider("other") == null);
}

test "terminal lifecycle reaches workspace processes with the exact final wait identity" {
    const allocator = std.testing.allocator;
    if (comptime builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;
    var state: app_state.AppState = undefined;
    state.allocator = allocator;
    state.project_controller.projects = .empty;
    state.project_controller.selected_index = 0;
    state.surface_controller = .{};
    defer {
        for (state.project_controller.projects.items) |*project| project.deinit(allocator);
        state.project_controller.projects.deinit(allocator);
        state.surface_controller.surfaces.deinit(allocator);
    }

    var project = try app_state.Project.init(allocator, "workspace-1", "Workspace", "/tmp", 0);
    try project.terminal_dock.restartWithProfile(allocator, project.path, .{});
    try terminal.lifecycle_testing.assignActiveSessionId(&project.terminal_dock, allocator, "workspace-failure-session");
    state.project_controller.projects.append(allocator, project) catch |err| {
        project.deinit(allocator);
        return err;
    };
    try std.testing.expect(try state.project_controller.projects.items[0].terminal_dock.writeInputToActivePane(
        "sleep 2; exit 17\n",
    ));

    var active_id: ?[]u8 = null;
    var attempts: usize = 0;
    while (attempts < 300 and active_id == null) : (attempts += 1) {
        const dock = &state.project_controller.projects.items[0].terminal_dock;
        _ = try dock.poll(allocator);
        state.syncTerminalDockProcessLifecycle(0, 0, dock, null);
        if (state.project_controller.projects.items[0].tracked_terminal_processes.items.len > 0) {
            active_id = try allocator.dupe(u8, state.project_controller.projects.items[0].tracked_terminal_processes.items[0].process_id);
        } else {
            try std.Io.sleep(std.testing.io, .fromMilliseconds(10), .awake);
        }
    }
    const process_id = active_id orelse return error.MissingActiveTerminalProcess;
    defer allocator.free(process_id);
    const active_response = try workspaceProcessesTestResponseAlloc(allocator, &state, 0);
    defer allocator.free(active_response);

    attempts = 0;
    while (attempts < 400 and state.project_controller.projects.items[0].terminal_process_outcomes.items.len == 0) : (attempts += 1) {
        const dock = &state.project_controller.projects.items[0].terminal_dock;
        _ = try dock.poll(allocator);
        state.syncTerminalDockProcessLifecycle(0, 0, dock, null);
        if (state.project_controller.projects.items[0].terminal_process_outcomes.items.len == 0) {
            try std.Io.sleep(std.testing.io, .fromMilliseconds(10), .awake);
        }
    }
    try std.testing.expect(state.project_controller.projects.items[0].terminalProcessActiveForSession(
        state.project_controller.projects.items[0].terminal_process_outcomes.items[0].session_id,
    ) == null);
    try std.testing.expectEqualStrings(process_id, state.project_controller.projects.items[0].terminal_process_outcomes.items[0].process_id);
    {
        const dock = &state.project_controller.projects.items[0].terminal_dock;
        try dock.closeTab(allocator, 0);
        state.syncTerminalDockProcessLifecycle(0, 0, dock, null);
        state.pollPendingTerminalSessionTeardowns(0);
    }
    try std.testing.expectEqual(@as(usize, 1), state.project_controller.projects.items[0].terminal_process_outcomes.items.len);
    try std.testing.expectEqual(app_state.TerminalProcessOutcomeStatus.failed, state.project_controller.projects.items[0].terminal_process_outcomes.items[0].status);
    try std.testing.expectEqual(@as(?u32, 17), state.project_controller.projects.items[0].terminal_process_outcomes.items[0].exit_code);

    const final_response = try workspaceProcessesTestResponseAlloc(allocator, &state, 0);
    defer allocator.free(final_response);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, final_response, .{});
    defer parsed.deinit();
    const processes = workspaceProcessesFromResponse(parsed.value) orelse return error.MissingWorkspaceProcesses;
    const result = workspaceProcessObjectById(processes, process_id) orelse return error.MissingRetainedTerminalProcess;
    try std.testing.expectEqualStrings("failed", jsonString(result.get("status").?).?);
    try std.testing.expectEqual(@as(i64, 17), jsonInt(result.get("exit_code").?).?);
    const wait_responses = [_][]const u8{ active_response, final_response };
    var wait_transport: TestWorkspaceProcessesTransport = .{ .responses = &wait_responses };
    const wait_result = try @import("../cli/main.zig").waitForWorkspaceProcessWithTransportAlloc(
        allocator,
        std.testing.io,
        null,
        process_id,
        1_000,
        .{ .context = &wait_transport, .request = TestWorkspaceProcessesTransport.request },
        0,
    );
    defer allocator.free(wait_result);
    var wait_parsed = try std.json.parseFromSlice(std.json.Value, allocator, wait_result, .{});
    defer wait_parsed.deinit();
    try std.testing.expectEqualStrings("completed", jsonString(wait_parsed.value.object.get("outcome").?).?);
    const waited_process = wait_parsed.value.object.get("process").?.object;
    try std.testing.expectEqualStrings(process_id, jsonString(waited_process.get("id").?).?);
    try std.testing.expectEqualStrings("failed", jsonString(waited_process.get("status").?).?);
}

test "stopped unconfirmed terminal remains waitable through disappearance grace" {
    const allocator = std.testing.allocator;
    if (comptime builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;
    var state: app_state.AppState = undefined;
    state.allocator = allocator;
    state.project_controller.projects = .empty;
    state.project_controller.selected_index = 0;
    state.surface_controller = .{};
    defer {
        for (state.project_controller.projects.items) |*project| project.deinit(allocator);
        state.project_controller.projects.deinit(allocator);
        state.surface_controller.surfaces.deinit(allocator);
    }

    var project = try app_state.Project.init(allocator, "workspace-grace", "Workspace grace", "/tmp", 0);
    try project.terminal_dock.restartWithProfile(allocator, project.path, .{});
    try terminal.lifecycle_testing.assignActiveSessionId(&project.terminal_dock, allocator, "session-grace");
    state.project_controller.projects.append(allocator, project) catch |err| {
        project.deinit(allocator);
        return err;
    };
    const dock = &state.project_controller.projects.items[0].terminal_dock;
    try std.testing.expect(try dock.writeInputToActivePane("sleep 30\n"));

    var active_id: ?[]u8 = null;
    var attempts: usize = 0;
    while (attempts < 300 and active_id == null) : (attempts += 1) {
        _ = try dock.poll(allocator);
        state.syncTerminalDockProcessLifecycle(0, 0, dock, null);
        if (state.project_controller.projects.items[0].terminalProcessActiveForSession("session-grace")) |tracked| {
            active_id = try allocator.dupe(u8, tracked.process_id);
        } else {
            try std.Io.sleep(std.testing.io, .fromMilliseconds(10), .awake);
        }
    }
    const process_id = active_id orelse return error.MissingActiveTerminalProcess;
    defer allocator.free(process_id);

    const resources = [_][]const u8{"build"};
    _ = try state.acquireWorkspaceLease(0, "session-grace", "mise run build", &resources, 60_000, false);
    try terminal.lifecycle_testing.simulateActiveDaemonUnavailable(dock, false);
    defer terminal.lifecycle_testing.restoreActiveLocal(dock);
    state.syncTerminalDockProcessLifecycle(0, 0, dock, null);

    const tracked = state.project_controller.projects.items[0].terminalProcessActiveForSession("session-grace") orelse
        return error.MissingStoppingTerminalProcess;
    try std.testing.expectEqualStrings(process_id, tracked.process_id);
    try std.testing.expect(tracked.missing_since_ms != null);
    try std.testing.expectEqual(@as(usize, 1), state.activeWorkspaceLeaseCount(0));
    try std.testing.expectEqualStrings(
        "session-grace",
        state.project_controller.projects.items[0].workspace_leases.items[0].owner,
    );

    const pending_response = try workspaceProcessesTestResponseAlloc(allocator, &state, 0);
    defer allocator.free(pending_response);
    var pending = try std.json.parseFromSlice(std.json.Value, allocator, pending_response, .{});
    defer pending.deinit();
    const pending_processes = workspaceProcessesFromResponse(pending.value) orelse return error.MissingWorkspaceProcesses;
    const pending_process = workspaceProcessObjectById(pending_processes, process_id) orelse return error.MissingPendingTerminalProcess;
    try std.testing.expectEqualStrings("stopping", jsonString(pending_process.get("status").?).?);
    try std.testing.expectEqual(
        @import("../cli/main.zig").WorkspaceProcessPollOutcome.active,
        @import("../cli/main.zig").workspaceProcessPoll(pending.value, process_id).outcome,
    );

    try std.Io.sleep(
        std.testing.io,
        .fromMilliseconds(@intCast(app_state.TERMINAL_PROCESS_EXIT_GRACE_MS + 20)),
        .awake,
    );
    state.syncTerminalDockProcessLifecycle(0, 0, dock, null);
    try std.testing.expect(
        state.project_controller.projects.items[0].terminalProcessActiveForSession("session-grace") == null,
    );
    try std.testing.expectEqual(@as(usize, 1), state.activeWorkspaceLeaseCount(0));

    const final_response = try workspaceProcessesTestResponseAlloc(allocator, &state, 0);
    defer allocator.free(final_response);
    var final = try std.json.parseFromSlice(std.json.Value, allocator, final_response, .{});
    defer final.deinit();
    const final_processes = workspaceProcessesFromResponse(final.value) orelse return error.MissingWorkspaceProcesses;
    const final_process = workspaceProcessObjectById(final_processes, process_id) orelse return error.MissingRetainedTerminalProcess;
    try std.testing.expectEqualStrings("unknown", jsonString(final_process.get("status").?).?);
    try std.testing.expectEqual(
        @import("../cli/main.zig").WorkspaceProcessPollOutcome.completed,
        @import("../cli/main.zig").workspaceProcessPoll(final.value, process_id).outcome,
    );

    const wait_responses = [_][]const u8{ pending_response, final_response };
    var wait_transport: TestWorkspaceProcessesTransport = .{ .responses = &wait_responses };
    const wait_result = try @import("../cli/main.zig").waitForWorkspaceProcessWithTransportAlloc(
        allocator,
        std.testing.io,
        null,
        process_id,
        1_000,
        .{ .context = &wait_transport, .request = TestWorkspaceProcessesTransport.request },
        0,
    );
    defer allocator.free(wait_result);
    var wait_parsed = try std.json.parseFromSlice(std.json.Value, allocator, wait_result, .{});
    defer wait_parsed.deinit();
    try std.testing.expectEqualStrings("completed", jsonString(wait_parsed.value.object.get("outcome").?).?);
    const waited_process = wait_parsed.value.object.get("process").?.object;
    try std.testing.expectEqualStrings(process_id, jsonString(waited_process.get("id").?).?);
    try std.testing.expectEqualStrings("unknown", jsonString(waited_process.get("status").?).?);
}

test "terminal lifecycle preserves an observed signal in workspace processes" {
    const allocator = std.testing.allocator;
    if (comptime builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;
    var state: app_state.AppState = undefined;
    state.allocator = allocator;
    state.project_controller.projects = .empty;
    state.project_controller.selected_index = 0;
    state.surface_controller = .{};
    defer {
        for (state.project_controller.projects.items) |*project| project.deinit(allocator);
        state.project_controller.projects.deinit(allocator);
        state.surface_controller.surfaces.deinit(allocator);
    }

    var project = try app_state.Project.init(allocator, "workspace-signal", "Workspace signal", "/tmp", 0);
    try project.terminal_dock.restartWithProfile(allocator, project.path, .{
        .kind = .custom,
        .label = "signaled lifecycle",
        .command = &.{ "/bin/sh", "-c", "sleep 0.3; kill -TERM $$" },
    });
    try terminal.lifecycle_testing.assignActiveSessionId(&project.terminal_dock, allocator, "workspace-signal-session");
    state.project_controller.projects.append(allocator, project) catch |err| {
        project.deinit(allocator);
        return err;
    };

    var process_id: ?[]u8 = null;
    var attempts: usize = 0;
    while (attempts < 100 and process_id == null) : (attempts += 1) {
        const dock = &state.project_controller.projects.items[0].terminal_dock;
        _ = try dock.poll(allocator);
        state.syncTerminalDockProcessLifecycle(0, 0, dock, null);
        if (state.project_controller.projects.items[0].tracked_terminal_processes.items.len > 0) {
            process_id = try allocator.dupe(u8, state.project_controller.projects.items[0].tracked_terminal_processes.items[0].process_id);
        } else {
            try std.Io.sleep(std.testing.io, .fromMilliseconds(10), .awake);
        }
    }
    const active_id = process_id orelse return error.MissingActiveTerminalProcess;
    defer allocator.free(active_id);

    attempts = 0;
    while (attempts < 150 and state.project_controller.projects.items[0].terminal_process_outcomes.items.len == 0) : (attempts += 1) {
        const dock = &state.project_controller.projects.items[0].terminal_dock;
        _ = try dock.poll(allocator);
        state.syncTerminalDockProcessLifecycle(0, 0, dock, null);
        if (state.project_controller.projects.items[0].terminal_process_outcomes.items.len == 0) {
            try std.Io.sleep(std.testing.io, .fromMilliseconds(10), .awake);
        }
    }

    var writer: std.Io.Writer.Allocating = .init(allocator);
    defer writer.deinit();
    var s: std.json.Stringify = .{ .writer = &writer.writer, .options = .{} };
    try writeWorkspaceProcessesTestResponse(&s, &state, 0);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, writer.written(), .{});
    defer parsed.deinit();
    const processes = workspaceProcessesFromResponse(parsed.value) orelse return error.MissingWorkspaceProcesses;
    const result = workspaceProcessObjectById(processes, active_id) orelse return error.MissingRetainedTerminalProcess;
    try std.testing.expectEqualStrings("crashed", jsonString(result.get("status").?).?);
    try std.testing.expectEqual(@as(i64, 15), jsonInt(result.get("signal").?).?);
    const wait_poll = @import("../cli/main.zig").workspaceProcessPoll(parsed.value, active_id);
    try std.testing.expectEqual(@import("../cli/main.zig").WorkspaceProcessPollOutcome.completed, wait_poll.outcome);
}

test "terminal duplicate generations remain unambiguous and unknown exits never report success" {
    const allocator = std.testing.allocator;
    if (comptime builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;
    var state: app_state.AppState = undefined;
    state.allocator = allocator;
    state.project_controller.projects = .empty;
    state.project_controller.selected_index = 0;
    state.surface_controller = .{};
    defer {
        for (state.project_controller.projects.items) |*project| project.deinit(allocator);
        state.project_controller.projects.deinit(allocator);
        state.surface_controller.surfaces.deinit(allocator);
    }

    var project = try app_state.Project.init(allocator, "workspace-shell", "Workspace shell", "/tmp", 0);
    try project.terminal_dock.restartWithProfile(allocator, project.path, .{});
    try terminal.lifecycle_testing.assignActiveSessionId(&project.terminal_dock, allocator, "workspace-shell-session");
    state.project_controller.projects.append(allocator, project) catch |err| {
        project.deinit(allocator);
        return err;
    };

    var generation_ids: [2][]u8 = undefined;
    var generation_count: usize = 0;
    var second_generation_active_response: ?[]u8 = null;
    defer for (generation_ids[0..generation_count]) |id| allocator.free(id);
    defer if (second_generation_active_response) |response| allocator.free(response);
    while (generation_count < generation_ids.len) : (generation_count += 1) {
        const dock = &state.project_controller.projects.items[0].terminal_dock;
        try std.testing.expect(try dock.writeInputToActivePane("sleep 0.3; false\n"));
        var attempts: usize = 0;
        while (attempts < 100) : (attempts += 1) {
            _ = try dock.poll(allocator);
            state.syncTerminalDockProcessLifecycle(0, 0, dock, null);
            if (state.project_controller.projects.items[0].tracked_terminal_processes.items.len > 0) break;
            try std.Io.sleep(std.testing.io, .fromMilliseconds(10), .awake);
        }
        if (state.project_controller.projects.items[0].tracked_terminal_processes.items.len == 0) {
            return error.MissingActiveTerminalProcess;
        }
        const active = state.project_controller.projects.items[0].tracked_terminal_processes.items[0];
        generation_ids[generation_count] = try allocator.dupe(u8, active.process_id);
        if (generation_count == 1) {
            second_generation_active_response = try workspaceProcessesTestResponseAlloc(allocator, &state, 0);
        }

        attempts = 0;
        while (attempts < 150 and state.project_controller.projects.items[0].terminalProcessActiveForSession(active.session_id) != null) : (attempts += 1) {
            _ = try dock.poll(allocator);
            state.syncTerminalDockProcessLifecycle(0, 0, dock, null);
            if (state.project_controller.projects.items[0].terminalProcessActiveForSession(active.session_id) != null) {
                try std.Io.sleep(std.testing.io, .fromMilliseconds(10), .awake);
            }
        }
    }
    try std.testing.expect(!std.mem.eql(u8, generation_ids[0], generation_ids[1]));

    const final_response = try workspaceProcessesTestResponseAlloc(allocator, &state, 0);
    defer allocator.free(final_response);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, final_response, .{});
    defer parsed.deinit();
    const processes = workspaceProcessesFromResponse(parsed.value) orelse return error.MissingWorkspaceProcesses;
    for (generation_ids) |process_id| {
        const result = workspaceProcessObjectById(processes, process_id) orelse return error.MissingRetainedTerminalProcess;
        try std.testing.expectEqualStrings("unknown", jsonString(result.get("status").?).?);
        try std.testing.expect(result.get("exit_code").? == .null);
        try std.testing.expect(result.get("signal").? == .null);
    }
    const active_response = second_generation_active_response orelse return error.MissingActiveWorkspaceProcesses;
    const old_generation_responses = [_][]const u8{active_response};
    var old_generation_transport: TestWorkspaceProcessesTransport = .{ .responses = &old_generation_responses };
    const old_generation_wait = try @import("../cli/main.zig").waitForWorkspaceProcessWithTransportAlloc(
        allocator,
        std.testing.io,
        null,
        generation_ids[0],
        1_000,
        .{ .context = &old_generation_transport, .request = TestWorkspaceProcessesTransport.request },
        0,
    );
    defer allocator.free(old_generation_wait);
    var old_wait_parsed = try std.json.parseFromSlice(std.json.Value, allocator, old_generation_wait, .{});
    defer old_wait_parsed.deinit();
    try std.testing.expectEqualStrings("completed", jsonString(old_wait_parsed.value.object.get("outcome").?).?);
    try std.testing.expectEqualStrings(
        generation_ids[0],
        jsonString(old_wait_parsed.value.object.get("process").?.object.get("id").?).?,
    );

    const current_generation_responses = [_][]const u8{ active_response, final_response };
    var current_generation_transport: TestWorkspaceProcessesTransport = .{ .responses = &current_generation_responses };
    const current_generation_wait = try @import("../cli/main.zig").waitForWorkspaceProcessWithTransportAlloc(
        allocator,
        std.testing.io,
        null,
        generation_ids[1],
        1_000,
        .{ .context = &current_generation_transport, .request = TestWorkspaceProcessesTransport.request },
        0,
    );
    defer allocator.free(current_generation_wait);
    var current_wait_parsed = try std.json.parseFromSlice(std.json.Value, allocator, current_generation_wait, .{});
    defer current_wait_parsed.deinit();
    try std.testing.expectEqualStrings("completed", jsonString(current_wait_parsed.value.object.get("outcome").?).?);
    try std.testing.expectEqualStrings(
        generation_ids[1],
        jsonString(current_wait_parsed.value.object.get("process").?.object.get("id").?).?,
    );
    const separator = std.mem.lastIndexOfScalar(u8, generation_ids[0], ':') orelse return error.InvalidTerminalProcessId;
    const replaced_id = try std.fmt.allocPrint(allocator, "{s}0", .{generation_ids[0][0 .. separator + 1]});
    defer allocator.free(replaced_id);
    const replaced_poll = @import("../cli/main.zig").workspaceProcessPoll(parsed.value, replaced_id);
    try std.testing.expectEqual(@import("../cli/main.zig").WorkspaceProcessPollOutcome.replaced, replaced_poll.outcome);
}

fn writeWorkspaceProcessesTestResponse(
    s: *std.json.Stringify,
    state: *app_state.AppState,
    project_index: usize,
) !void {
    try s.beginObject();
    try s.objectField("ok");
    try s.write(true);
    try s.objectField("result");
    try s.beginObject();
    try s.objectField("processes");
    try writeWorkspaceProcessesArray(s, state, project_index);
    try s.endObject();
    try s.endObject();
}

fn workspaceProcessesTestResponseAlloc(
    allocator: std.mem.Allocator,
    state: *app_state.AppState,
    project_index: usize,
) ![]u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    var s: std.json.Stringify = .{ .writer = &writer.writer, .options = .{} };
    try writeWorkspaceProcessesTestResponse(&s, state, project_index);
    return writer.toOwnedSlice();
}

const TestWorkspaceProcessesTransport = struct {
    responses: []const []const u8,
    next_index: usize = 0,

    fn request(
        raw_context: *anyopaque,
        allocator: std.mem.Allocator,
        _: std.Io,
        _: ?[]const u8,
    ) ![]u8 {
        const self: *TestWorkspaceProcessesTransport = @ptrCast(@alignCast(raw_context));
        if (self.next_index >= self.responses.len) return error.MissingWorkspaceProcessesResponse;
        const response = self.responses[self.next_index];
        self.next_index += 1;
        return allocator.dupe(u8, response);
    }
};

fn workspaceProcessesFromResponse(root: std.json.Value) ?std.json.Value {
    if (root != .object) return null;
    const result = root.object.get("result") orelse return null;
    if (result != .object) return null;
    return result.object.get("processes");
}

fn workspaceProcessObjectById(processes: std.json.Value, process_id: []const u8) ?std.json.ObjectMap {
    if (processes != .array) return null;
    for (processes.array.items) |process| {
        if (process != .object) continue;
        const candidate = jsonString(process.object.get("id") orelse .null) orelse continue;
        if (std.mem.eql(u8, candidate, process_id)) return process.object;
    }
    return null;
}

test "terminal retained outcome serialization preserves owner fields" {
    const allocator = std.testing.allocator;
    var project = try app_state.Project.init(allocator, "workspace-owner", "Workspace owner", "/tmp/workspace-owner", 0);
    defer project.deinit(allocator);
    try project.observeTerminalProcess(allocator, .{
        .process_identity = 42,
        .session_id = "session-1",
        .command = "mise run build",
        .cwd = "/tmp/workspace-owner",
        .started_at_ms = 100,
        .observed_at_ms = 150,
        .dock_id = 7,
        .owner_kind = "agent",
        .owner_title = "Build agent",
        .provider = "codex",
    }, .{});
    const active_id = try allocator.dupe(u8, project.terminalProcessActiveForSession("session-1").?.process_id);
    defer allocator.free(active_id);
    try std.testing.expect(try project.finishTerminalProcess(allocator, "session-1", .{ .exit_code = 2 }, 200));

    var outcome_writer: std.Io.Writer.Allocating = .init(allocator);
    defer outcome_writer.deinit();
    var outcome_s: std.json.Stringify = .{ .writer = &outcome_writer.writer, .options = .{} };
    try outcome_s.beginArray();
    try writeTerminalWorkspaceOutcome(&outcome_s, 0, &project, &project.terminal_process_outcomes.items[0]);
    try outcome_s.endArray();

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, outcome_writer.written(), .{});
    defer parsed.deinit();
    const result = parsed.value.array.items[0].object;
    try std.testing.expectEqualStrings(active_id, jsonString(result.get("id").?).?);
    try std.testing.expectEqualStrings("failed", jsonString(result.get("status").?).?);
    try std.testing.expectEqual(@as(i64, 200), jsonInt(result.get("finished_at_ms").?).?);
    try std.testing.expectEqual(@as(i64, 2), jsonInt(result.get("exit_code").?).?);
    try std.testing.expectEqual(@as(usize, 0), result.get("resources").?.array.items.len);
    const owner = result.get("owner").?.object;
    try std.testing.expectEqualStrings("session-1", jsonString(owner.get("id").?).?);
    try std.testing.expectEqualStrings("codex", jsonString(owner.get("provider").?).?);
}

test "terminal key command routes to a runnable target without changing focus" {
    if (comptime builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var state: app_state.AppState = undefined;
    state.allocator = allocator;
    state.project_controller.projects = .empty;
    state.project_controller.selected_index = 0;
    state.terminal_controller.focused = false;
    state.window_input_focus = true;
    defer {
        for (state.project_controller.projects.items) |*project| project.deinit(allocator);
        state.project_controller.projects.deinit(allocator);
    }

    var first = try app_state.Project.init(allocator, "first", "First", "/tmp/first", 0);
    state.project_controller.projects.append(allocator, first) catch |err| {
        first.deinit(allocator);
        return err;
    };
    var second = try app_state.Project.init(allocator, "second", "Second", "/tmp/second", 0);
    const terminal_pane_id = try second.workspace_layout.createTerminalPane(allocator, 7);
    var target_dock = try terminal.Dock.init(allocator);
    errdefer target_dock.deinit(allocator);
    try target_dock.restartWithProfile(allocator, "/tmp", .{
        .kind = .custom,
        .label = "terminal-key-target",
        .command = &.{"/bin/cat"},
    });
    target_dock.focus_requested = false;
    try second.terminal_docks.append(allocator, .{ .id = 7, .dock = target_dock });
    state.project_controller.projects.append(allocator, second) catch |err| {
        second.deinit(allocator);
        return err;
    };

    const selected_workspace_before = state.project_controller.selected_index;
    const first_focus_before = state.project_controller.projects.items[0].workspace_layout.focused_pane_id;
    const second_focus_before = state.project_controller.projects.items[1].workspace_layout.focused_pane_id;
    const terminal_focus_before = state.terminal_controller.focused;
    const window_focus_before = state.window_input_focus;
    const terminal_params_json = try std.fmt.allocPrint(
        allocator,
        "{{\"workspace\":\"second\",\"pane\":{d},\"key\":\"x\"}}",
        .{terminal_pane_id},
    );
    defer allocator.free(terminal_params_json);
    var terminal_params = try std.json.parseFromSlice(std.json.Value, allocator, terminal_params_json, .{});
    defer terminal_params.deinit();
    const response = try terminalCommandResponse(allocator, .{ .integer = 1 }, &state, terminal_params.value, "key");
    defer allocator.free(response);
    var parsed_response = try std.json.parseFromSlice(std.json.Value, allocator, response, .{});
    defer parsed_response.deinit();
    const result = parsed_response.value.object.get("result").?.object;
    try std.testing.expect(boolParam(.{ .object = result }, "accepted").?);
    try std.testing.expectEqual(@as(i64, 1), intParam(.{ .object = result }, "workspace_index").?);
    try std.testing.expectEqual(@as(i64, @intCast(terminal_pane_id)), intParam(.{ .object = result }, "pane_id").?);

    var routed_to_target = false;
    for (0..40) |_| {
        const dock = &state.project_controller.projects.items[1].terminalDockEntryById(7).?.dock;
        _ = try dock.poll(allocator);
        const output = (try dock.activeOutputTailAlloc(allocator, 256)) orelse {
            try std.Io.sleep(std.testing.io, .fromMilliseconds(25), .awake);
            continue;
        };
        defer allocator.free(output);
        if (std.mem.indexOfScalar(u8, output, 'x') != null) {
            routed_to_target = true;
            break;
        }
        try std.Io.sleep(std.testing.io, .fromMilliseconds(25), .awake);
    }
    try std.testing.expect(routed_to_target);
    try std.testing.expectEqual(selected_workspace_before, state.project_controller.selected_index);
    try std.testing.expectEqual(first_focus_before, state.project_controller.projects.items[0].workspace_layout.focused_pane_id);
    try std.testing.expectEqual(second_focus_before, state.project_controller.projects.items[1].workspace_layout.focused_pane_id);
    try std.testing.expectEqual(terminal_focus_before, state.terminal_controller.focused);
    try std.testing.expectEqual(window_focus_before, state.window_input_focus);
    try std.testing.expect(!state.project_controller.projects.items[1].terminalDockEntryById(7).?.dock.focus_requested);
}

test "terminal key command rejects non-terminal targets and invalid keys" {
    const allocator = std.testing.allocator;
    var state: app_state.AppState = undefined;
    state.allocator = allocator;
    state.project_controller.projects = .empty;
    state.project_controller.selected_index = 0;
    defer {
        for (state.project_controller.projects.items) |*project| project.deinit(allocator);
        state.project_controller.projects.deinit(allocator);
    }

    var first = try app_state.Project.init(allocator, "first", "First", "/tmp/first", 0);
    state.project_controller.projects.append(allocator, first) catch |err| {
        first.deinit(allocator);
        return err;
    };
    var second = try app_state.Project.init(allocator, "second", "Second", "/tmp/second", 0);
    const terminal_pane_id = try second.workspace_layout.createTerminalPane(allocator, 7);
    state.project_controller.projects.append(allocator, second) catch |err| {
        second.deinit(allocator);
        return err;
    };

    const chat_pane_id = state.project_controller.projects.items[0].workspace_layout.focused_pane_id orelse
        return error.MissingChatTarget;
    const chat_params_json = try std.fmt.allocPrint(
        allocator,
        "{{\"workspace\":\"first\",\"pane\":{d},\"key\":\"enter\"}}",
        .{chat_pane_id},
    );
    defer allocator.free(chat_params_json);
    var chat_params = try std.json.parseFromSlice(std.json.Value, allocator, chat_params_json, .{});
    defer chat_params.deinit();
    const non_terminal_response = try terminalCommandResponse(allocator, .{ .integer = 2 }, &state, chat_params.value, "key");
    defer allocator.free(non_terminal_response);
    var parsed_non_terminal = try std.json.parseFromSlice(std.json.Value, allocator, non_terminal_response, .{});
    defer parsed_non_terminal.deinit();
    const non_terminal_error = parsed_non_terminal.value.object.get("error").?.object;
    try std.testing.expectEqualStrings("invalid_target", jsonString(non_terminal_error.get("code").?).?);

    const invalid_params_json = try std.fmt.allocPrint(
        allocator,
        "{{\"workspace\":\"second\",\"pane\":{d},\"chord\":\"ctrl+raw-sequence\"}}",
        .{terminal_pane_id},
    );
    defer allocator.free(invalid_params_json);
    var invalid_params = try std.json.parseFromSlice(std.json.Value, allocator, invalid_params_json, .{});
    defer invalid_params.deinit();
    const invalid_key_response = try terminalCommandResponse(allocator, .{ .integer = 3 }, &state, invalid_params.value, "key");
    defer allocator.free(invalid_key_response);
    var parsed_invalid_key = try std.json.parseFromSlice(std.json.Value, allocator, invalid_key_response, .{});
    defer parsed_invalid_key.deinit();
    const invalid_key_error = parsed_invalid_key.value.object.get("error").?.object;
    try std.testing.expectEqualStrings("invalid_key", jsonString(invalid_key_error.get("code").?).?);
}

test "pane close response matches the next durable projection" {
    const allocator = std.testing.allocator;
    const daemon_store = @import("../daemon/store.zig");
    const db_client = @import("../db/client.zig");
    const persistence = @import("../state/persistence.zig");

    var state: app_state.AppState = undefined;
    state.allocator = allocator;
    state.project_controller.projects = .empty;
    state.project_controller.selected_index = 1;
    state.lifecycle = .{};
    @memset(&state.sidebar_notice_storage, 0);
    defer {
        for (state.project_controller.projects.items) |*project| project.deinit(allocator);
        state.project_controller.projects.deinit(allocator);
    }

    var target = try app_state.Project.init(allocator, "close-target", "Close target", "/tmp/close-target", 0);
    const second_thread_index = try target.addThread(allocator);
    const closed_pane_id = try target.workspace_layout.createChatPane(allocator, second_thread_index);
    try target.workspace_layout.splitPaneWithLeaf(allocator, 1, closed_pane_id, .horizontal, true);
    state.project_controller.projects.append(allocator, target) catch |err| {
        target.deinit(allocator);
        return err;
    };
    var selected = try app_state.Project.init(allocator, "selected", "Selected", "/tmp/selected", 0);
    state.project_controller.projects.append(allocator, selected) catch |err| {
        selected.deinit(allocator);
        return err;
    };

    const params_json = try std.fmt.allocPrint(
        allocator,
        "{{\"workspace\":\"close-target\",\"pane\":{d}}}",
        .{closed_pane_id},
    );
    defer allocator.free(params_json);
    var params = try std.json.parseFromSlice(std.json.Value, allocator, params_json, .{});
    defer params.deinit();
    const response_id: std.json.Value = .{ .integer = 77 };
    const close_response = try paneCommandResponse(allocator, response_id, &state, params.value, "close");
    defer allocator.free(close_response);

    var captured = try persistence.buildSnapshot(.{
        .projects = state.project_controller.projects.items,
        .archived_projects = &.{},
        .selected_project_index = state.project_controller.selected_index,
        .sidebar_collapsed = false,
    }, allocator);
    defer captured.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const pref_path = path_buf[0..path_len];
    const db_path = try std.fs.path.joinZ(allocator, &.{ pref_path, db_client.STATE_DB_NAME });
    defer allocator.free(db_path);
    var store = try daemon_store.Store.init(allocator, db_path);
    defer store.deinit();
    var protocol_arena = std.heap.ArenaAllocator.init(allocator);
    defer protocol_arena.deinit();
    const protocol_snapshot = try persistence.persistedStateToProtocolSnapshot(protocol_arena.allocator(), captured.value, 0);
    const write = try store.replaceSnapshot(.{
        .mutation = .{
            .request_key = "pane-close-projection",
            .client_id = "pane-close-test-client",
            .expected_store_revision = 0,
        },
        .snapshot = protocol_snapshot,
        .bootstrap = false,
    });
    try std.testing.expect(write.applied);

    var reader = try db_client.Client.initReadOnly(allocator, pref_path);
    defer reader.deinit();
    var reloaded = (try reader.load(allocator)).?;
    defer reloaded.deinit();
    try std.testing.expectEqual(@as(usize, 1), reloaded.value.selected_project_index);
    const layout_json = reloaded.value.projects[0].workspace_layout_json orelse return error.TestExpectedEqual;
    try state.project_controller.projects.items[0].workspace_layout.applyPersistedWorkspaceJson(allocator, layout_json);
    const projection_response = try panesResponseForProject(allocator, response_id, &state, 0);
    defer allocator.free(projection_response);
    try std.testing.expectEqualStrings(close_response, projection_response);
}

test "surface receipt proof is current while superseded delivery is inert" {
    const allocator = std.testing.allocator;
    const daemon_store = @import("../daemon/store.zig");
    const db_client = @import("../db/client.zig");
    const persistence = @import("../state/persistence.zig");
    const storage_mod = @import("../state/storage.zig");
    const app_config = @import("../app/config.zig");

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const pref_path = path_buf[0..path_len];
    const db_path = try std.fs.path.joinZ(allocator, &.{ pref_path, db_client.STATE_DB_NAME });
    defer allocator.free(db_path);
    var store = try daemon_store.Store.init(allocator, db_path);
    defer store.deinit();

    var project = try app_state.Project.init(allocator, "live-proof", "Live proof", "/tmp/live-proof", 0);
    defer project.deinit(allocator);
    project.threads.items[0].committed = true;
    const projects = [_]app_state.Project{project};
    var captured = try persistence.buildSnapshot(.{
        .projects = &projects,
        .archived_projects = &.{},
        .selected_project_index = 0,
        .sidebar_collapsed = false,
    }, allocator);
    defer captured.deinit();
    var protocol_arena = std.heap.ArenaAllocator.init(allocator);
    defer protocol_arena.deinit();
    const protocol_snapshot = try persistence.persistedStateToProtocolSnapshot(protocol_arena.allocator(), captured.value, 0);
    const snapshot_write = try store.replaceSnapshot(.{
        .mutation = .{
            .request_key = "live-proof-snapshot",
            .client_id = "live-proof-client",
            .expected_store_revision = 0,
        },
        .snapshot = protocol_snapshot,
        .bootstrap = false,
    });
    try std.testing.expectEqual(@as(u64, 1), snapshot_write.store_revision);

    const durable_surface: headless.store.SurfaceState = .{
        .session_id = "live-proof-session",
        .workspace_id = "live-proof",
        .workspace_path = "/tmp/live-proof",
        .dock_id = 7,
        .pane_id = 2,
        .provider = "codex",
        .provider_thread_id = "provider-thread-proof",
        .title = "Receipt surface",
        .status = "done",
        .status_changed_at_ms = 100,
        .completed_at_ms = 100,
        .last_event_title = "Ran command",
        .last_event_body = "exact body",
    };
    const upsert_write = try store.upsertSurface(.{
        .mutation = .{
            .request_key = "cli-live-upsert",
            .client_id = "live-proof-client",
            .expected_store_revision = 1,
        },
        .surface = durable_surface,
    });
    try std.testing.expectEqual(@as(u64, 2), upsert_write.store_revision);

    var storage = try storage_mod.Storage.initWithPrefPath(allocator, pref_path);
    defer storage.deinit();
    var state = try app_state.AppState.init(allocator, &storage, app_config.AppConfig{}, .{
        .gl_texture_uploads_enabled = false,
        .browser_textures_enabled = false,
    });
    defer {
        state.lifecycle.clearDirty();
        state.deinit();
    }
    try std.testing.expectEqual(app_state.SurfaceCommitProofClassification.current, try storage.classifySurfaceUpsertCommitProof(.{
        .request_key = "cli-live-upsert",
        .store_revision = 2,
    }, durable_surface));
    var spoofed_surface = durable_surface;
    spoofed_surface.title = "spoofed";
    try std.testing.expectEqual(app_state.SurfaceCommitProofClassification.invalid, try storage.classifySurfaceUpsertCommitProof(.{
        .request_key = "cli-live-upsert",
        .store_revision = 2,
    }, spoofed_surface));
    try std.testing.expectEqual(app_state.SurfaceCommitProofClassification.invalid, try storage.classifySurfaceUpsertCommitProof(.{
        .request_key = "cli-live-upsert",
        .store_revision = 99,
    }, durable_surface));
    try std.testing.expectEqual(app_state.SurfaceCommitProofClassification.invalid, try storage.classifySurfaceUpsertCommitProof(.{
        .request_key = "missing-receipt",
        .store_revision = 2,
    }, durable_surface));

    var update_params = try std.json.parseFromSlice(std.json.Value, allocator,
        \\{"session_id":"live-proof-session","workspace_id":"live-proof","workspace_path":"/tmp/live-proof","dock_id":7,"pane_id":2,"provider":"codex","provider_thread_id":"provider-thread-proof","label":"Receipt surface","title":"Ran command","body":"exact body","status":"done","store_request_key":"cli-live-upsert","store_revision":2,"store_status_changed_at_ms":100,"store_completed_at_ms":100}
    , .{});
    defer update_params.deinit();
    const update_response = try notificationUpdateResponse(allocator, .{ .integer = 90 }, &state, update_params.value);
    defer allocator.free(update_response);
    var parsed_update = try std.json.parseFromSlice(std.json.Value, allocator, update_response, .{});
    defer parsed_update.deinit();
    try std.testing.expect(parsed_update.value.object.get("ok").?.bool);
    try std.testing.expectEqual(@as(u64, 2), try store.storeRevision());
    const presented = state.surfaceBySessionIdConst("live-proof-session") orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(app_state.SurfaceStatus.done, presented.status);
    try std.testing.expectEqual(@as(i64, 100), presented.status_changed_at_ms);
    try std.testing.expect(presented.completion_pending);
    try std.testing.expectEqual(@as(i64, 100), presented.completed_at_ms);

    // Repeating the still-current done receipt does not change the durable
    // revision or recreate completion state.
    const repeated_response = try notificationUpdateResponse(allocator, .{ .integer = 91 }, &state, update_params.value);
    defer allocator.free(repeated_response);
    try std.testing.expectEqual(@as(u64, 2), try store.storeRevision());
    try std.testing.expect(state.surfaceBySessionIdConst("live-proof-session").?.completion_pending);
    try std.testing.expectEqual(@as(i64, 100), state.surfaceBySessionIdConst("live-proof-session").?.completed_at_ms);

    const clear_write = try store.clearSurface(.{
        .mutation = .{
            .request_key = "cli-live-clear",
            .client_id = "live-proof-client",
            .expected_store_revision = 2,
        },
        .session_id = "live-proof-session",
    });
    try std.testing.expectEqual(@as(u64, 3), clear_write.store_revision);
    try std.testing.expectEqual(app_state.SurfaceCommitProofClassification.current, try storage.classifySurfaceClearCommitProof(.{
        .request_key = "cli-live-clear",
        .store_revision = 3,
    }, "live-proof-session"));
    try std.testing.expectEqual(app_state.SurfaceCommitProofClassification.invalid, try storage.classifySurfaceClearCommitProof(.{
        .request_key = "cli-live-clear",
        .store_revision = 3,
    }, "different-session"));

    var clear_params = try std.json.parseFromSlice(std.json.Value, allocator,
        \\{"session_id":"live-proof-session","store_request_key":"cli-live-clear","store_revision":3}
    , .{});
    defer clear_params.deinit();
    const clear_response = try notificationClearResponse(allocator, .{ .integer = 92 }, &state, clear_params.value);
    defer allocator.free(clear_response);
    var parsed_clear = try std.json.parseFromSlice(std.json.Value, allocator, clear_response, .{});
    defer parsed_clear.deinit();
    try std.testing.expect(parsed_clear.value.object.get("ok").?.bool);
    try std.testing.expectEqual(@as(u64, 3), try store.storeRevision());
    try std.testing.expectEqual(app_state.SurfaceStatus.idle, state.surfaceBySessionIdConst("live-proof-session").?.status);

    // The old exact upsert receipt is historical after the clear. Delayed
    // delivery is acknowledged as superseded without Store or presentation.
    try std.testing.expectEqual(app_state.SurfaceCommitProofClassification.superseded, try storage.classifySurfaceUpsertCommitProof(.{
        .request_key = "cli-live-upsert",
        .store_revision = 2,
    }, durable_surface));
    const delayed_upsert = try notificationUpdateResponse(allocator, .{ .integer = 93 }, &state, update_params.value);
    defer allocator.free(delayed_upsert);
    var parsed_delayed_upsert = try std.json.parseFromSlice(std.json.Value, allocator, delayed_upsert, .{});
    defer parsed_delayed_upsert.deinit();
    try std.testing.expect(parsed_delayed_upsert.value.object.get("result").?.object.get("superseded").?.bool);
    try std.testing.expectEqual(@as(u64, 3), try store.storeRevision());
    try std.testing.expectEqual(app_state.SurfaceStatus.idle, state.surfaceBySessionIdConst("live-proof-session").?.status);
    try std.testing.expect(!state.surfaceBySessionIdConst("live-proof-session").?.completion_pending);

    var working_surface = durable_surface;
    working_surface.status = "working";
    working_surface.status_changed_at_ms = 200;
    working_surface.completed_at_ms = 0;
    const working_write = try store.upsertSurface(.{
        .mutation = .{
            .request_key = "cli-live-working",
            .client_id = "live-proof-client",
            .expected_store_revision = 3,
        },
        .surface = working_surface,
    });
    try std.testing.expectEqual(@as(u64, 4), working_write.store_revision);
    var working_params = try std.json.parseFromSlice(std.json.Value, allocator,
        \\{"session_id":"live-proof-session","workspace_id":"live-proof","workspace_path":"/tmp/live-proof","dock_id":7,"pane_id":2,"provider":"codex","provider_thread_id":"provider-thread-proof","label":"Receipt surface","title":"Ran command","body":"exact body","status":"working","store_request_key":"cli-live-working","store_revision":4,"store_status_changed_at_ms":200,"store_completed_at_ms":0}
    , .{});
    defer working_params.deinit();
    const working_response = try notificationUpdateResponse(allocator, .{ .integer = 94 }, &state, working_params.value);
    defer allocator.free(working_response);
    try std.testing.expectEqual(app_state.SurfaceStatus.working, state.surfaceBySessionIdConst("live-proof-session").?.status);
    try std.testing.expectEqual(@as(u64, 4), try store.storeRevision());

    // Conversely, the old clear receipt cannot hide the newer exact upsert.
    try std.testing.expectEqual(app_state.SurfaceCommitProofClassification.superseded, try storage.classifySurfaceClearCommitProof(.{
        .request_key = "cli-live-clear",
        .store_revision = 3,
    }, "live-proof-session"));
    const delayed_clear = try notificationClearResponse(allocator, .{ .integer = 95 }, &state, clear_params.value);
    defer allocator.free(delayed_clear);
    var parsed_delayed_clear = try std.json.parseFromSlice(std.json.Value, allocator, delayed_clear, .{});
    defer parsed_delayed_clear.deinit();
    try std.testing.expect(parsed_delayed_clear.value.object.get("result").?.object.get("superseded").?.bool);
    try std.testing.expectEqual(@as(u64, 4), try store.storeRevision());
    try std.testing.expectEqual(app_state.SurfaceStatus.working, state.surfaceBySessionIdConst("live-proof-session").?.status);

    // A receipt for the opposite operation is invalid, and incomplete proof
    // JSON is not recognized as proof at all; both therefore retain the raw
    // durable path instead of being silently ignored.
    try std.testing.expectEqual(app_state.SurfaceCommitProofClassification.invalid, try storage.classifySurfaceUpsertCommitProof(.{
        .request_key = "cli-live-clear",
        .store_revision = 3,
    }, working_surface));
    var incomplete = try std.json.parseFromSlice(std.json.Value, allocator,
        \\{"store_request_key":"cli-live-working"}
    , .{});
    defer incomplete.deinit();
    try std.testing.expect(surfaceCommitProof(incomplete.value) == null);

    storage.markPersistenceUnavailable();
    var invalid_clear_params = try std.json.parseFromSlice(std.json.Value, allocator,
        \\{"session_id":"live-proof-session","store_request_key":"cli-live-clear","store_revision":99}
    , .{});
    defer invalid_clear_params.deinit();
    try std.testing.expectError(error.SessionDaemonUnavailable, notificationClearResponse(allocator, .{ .integer = 96 }, &state, invalid_clear_params.value));
    var raw_clear_params = try std.json.parseFromSlice(std.json.Value, allocator,
        \\{"session_id":"live-proof-session"}
    , .{});
    defer raw_clear_params.deinit();
    try std.testing.expectError(error.SessionDaemonUnavailable, notificationClearResponse(allocator, .{ .integer = 97 }, &state, raw_clear_params.value));
    try std.testing.expectEqual(@as(u64, 4), try store.storeRevision());
    try std.testing.expectEqual(app_state.SurfaceStatus.working, state.surfaceBySessionIdConst("live-proof-session").?.status);
}
