const std = @import("std");

const app_state = @import("../state.zig");
const browser_runtime = @import("../browser/mod.zig");
const browser_ui = @import("../ui/browser.zig");
const provider_types = @import("../provider_types.zig");

pub const PROTOCOL_VERSION: u32 = 1;
pub const SOCKET_NAME = "verde.sock";

const Mutex = struct {
    inner: std.atomic.Mutex = .unlocked,

    fn lock(self: *Mutex) void {
        while (!self.inner.tryLock()) std.atomic.spinLoopHint();
    }

    fn unlock(self: *Mutex) void {
        self.inner.unlock();
    }
};

const Condition = struct {
    fn wait(_: *Condition, mutex: *Mutex) void {
        mutex.unlock();
        std.atomic.spinLoopHint();
        mutex.lock();
    }

    fn broadcast(_: *Condition) void {}
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
        const path = try std.fs.path.join(allocator, &.{ pref_path, SOCKET_NAME });
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

        wakeServer(self.path);
        if (self.thread) |thread| thread.join();

        for (self.pending.items) |command| {
            self.allocator.free(command.request_json);
            if (command.response_json) |response| self.allocator.free(response);
            self.allocator.destroy(command);
        }
        self.pending.deinit(self.allocator);
        deleteSocketPath(self.path);
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
        const command = try self.allocator.create(Command);
        command.* = .{ .request_json = request_json };
        errdefer self.allocator.destroy(command);

        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.shutdown) return error.ShuttingDown;
        try self.pending.append(self.allocator, command);
        self.condition.broadcast();
        while (!command.done and !self.shutdown) self.condition.wait(&self.mutex);
        if (self.shutdown and !command.done) return error.ShuttingDown;

        const response = command.response_json orelse try errorResponseAlloc(self.allocator, null, "internal_error", "missing response");
        self.allocator.free(command.request_json);
        self.allocator.destroy(command);
        return response;
    }
};

fn serverThreadMain(server: *LiveServer) void {
    var threaded = std.Io.Threaded.init_single_threaded;
    deleteSocketPath(server.path);

    const address = std.Io.net.UnixAddress.init(server.path) catch return;
    var listener = address.listen(threaded.io(), .{}) catch return;
    defer listener.deinit(threaded.io());
    defer deleteSocketPath(server.path);

    while (true) {
        server.mutex.lock();
        const should_stop = server.shutdown;
        server.mutex.unlock();
        if (should_stop) break;

        const stream = listener.accept(threaded.io()) catch |err| switch (err) {
            error.WouldBlock, error.ConnectionAborted => continue,
            else => break,
        };
        handleClient(server, threaded.io(), stream);
    }
}

fn handleClient(server: *LiveServer, io: std.Io, stream: std.Io.net.Stream) void {
    defer stream.close(io);
    var read_buffer: [64 * 1024]u8 = undefined;
    var reader = stream.reader(io, &read_buffer);
    const line = reader.interface.takeDelimiter('\n') catch return orelse return;
    const request_json = server.allocator.dupe(u8, std.mem.trim(u8, line, "\r")) catch return;
    const response_json = server.enqueueAndWait(request_json) catch |err|
        errorResponseAlloc(server.allocator, null, "server_unavailable", @errorName(err)) catch return;
    defer server.allocator.free(response_json);

    var write_buffer: [64 * 1024]u8 = undefined;
    var writer = stream.writer(io, &write_buffer);
    writer.interface.writeAll(response_json) catch return;
    writer.interface.writeByte('\n') catch return;
    writer.interface.flush() catch return;
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
    if (std.mem.eql(u8, method, "projects")) return try projectsResponse(allocator, id_value, state);
    if (std.mem.eql(u8, method, "panes")) return try panesResponse(allocator, id_value, state, params);
    if (std.mem.eql(u8, method, "active")) return try activeResponse(allocator, id_value, state);
    if (std.mem.eql(u8, method, "threads")) return try threadsResponse(allocator, id_value, state, params);
    if (std.mem.eql(u8, method, "terminals")) return try terminalsResponse(allocator, id_value, state, params);
    if (std.mem.eql(u8, method, "processes")) return try managedProcessesResponse(allocator, id_value, state, params);
    if (std.mem.eql(u8, method, "inspect")) return try inspectResponse(allocator, id_value, state, params);
    if (std.mem.startsWith(u8, method, "pane.")) return try paneCommandResponse(allocator, id_value, state, params, method["pane.".len..]);
    if (std.mem.startsWith(u8, method, "chat.")) return try chatCommandResponse(allocator, id_value, state, params, method["chat.".len..]);
    if (std.mem.startsWith(u8, method, "browser.")) return try browserCommandResponse(allocator, id_value, state, params, method["browser.".len..]);
    if (std.mem.startsWith(u8, method, "terminal.")) return try terminalCommandResponse(allocator, id_value, state, params, method["terminal.".len..]);
    if (std.mem.startsWith(u8, method, "process.")) return try processCommandResponse(allocator, id_value, state, params, method["process.".len..]);
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
    try s.write(std.c.getpid());
    try s.objectField("project_count");
    try s.write(state.projects.items.len);
    try s.objectField("selected_project_index");
    try s.write(state.selected_project_index);
    try s.objectField("focused_pane_id");
    if (state.projects.items.len > 0) {
        if (state.projects.items[state.selected_project_index].workspace_layout.focused_pane_id) |pane_id| try s.write(pane_id) else try s.write(null);
    } else {
        try s.write(null);
    }
    try s.objectField("pending_send_count");
    try s.write(state.pending_send_count);
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
    try s.write(state.browser_address_focused);
    try s.objectField("composer_focused");
    try s.write(state.composer_focused);
    try s.objectField("terminal_focused");
    try s.write(state.terminal_focused);
    try s.objectField("palette_modal_text_focus");
    try s.write(state.paletteModalTextFocusName());
    try s.endObject();
}

fn writeBrowserStatus(s: *std.json.Stringify, state: *app_state.AppState) !void {
    const browser = state.browserStateConst();
    try s.beginObject();
    try s.objectField("runtime_kind");
    try s.write(@tagName(browser.controller.runtimeKind()));
    try s.objectField("presentation_kind");
    try s.write(@tagName(browser.controller.presentationKind()));
    try s.objectField("runtime_initialized");
    try s.write(browser.controller.runtimeInitialized());
    try s.objectField("status");
    try s.write(browser.statusLabel());
    try s.objectField("visible");
    try s.write(state.isBrowserVisible());
    try s.objectField("pane_focused");
    try s.write(state.isBrowserPaneFocused());
    try s.objectField("address_focused");
    try s.write(state.browser_address_focused);
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
    try s.objectField("workspace_header_open_menu_open");
    try s.write(state.isWorkspaceHeaderOpenMenuOpen());
    try s.objectField("sidebar_context_menu_open");
    try s.write(state.isSidebarContextMenuOpen());
    try s.objectField("composer_menu_open");
    try s.write(state.isComposerMenuOpen());
    try s.objectField("project_import_modal_open");
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

fn capabilitiesResponse(allocator: std.mem.Allocator, id_value: std.json.Value) ![]u8 {
    return try okValueResponse(allocator, id_value, .{
        .protocol_version = PROTOCOL_VERSION,
        .commands = &.{
            "status",                            "capabilities",                        "projects",                             "panes",
            "active",                            "inspect",                             "threads",                              "terminals",
            "processes",                         "pane.focus",                          "pane.split",                           "pane.resize",
            "pane.minimize",                     "pane.maximize",                       "pane.restore",                         "pane.close",
            "chat.status",                       "chat.transcript",                     "chat.draft.set",                       "chat.draft.append",
            "chat.send",                         "chat.followup",                       "chat.stop",                            "chat.approve",
            "browser.open",                      "browser.close",                       "browser.toggle",                       "browser.back",
            "browser.forward",                   "browser.reload",                      "browser.focus",                        "browser.blur",
            "browser.toolbarHit",                "browser.selectAllFocused",            "browser.copyFocused",                  "browser.cutFocused",
            "browser.pasteTextFocused",          "browser.eval",                        "browser.postJson",                     "browser.inspector.enable",
            "browser.inspector.disable",         "browser.inspector.toggle",            "browser.inspector.mode",               "browser.inspector.menuOpen",
            "browser.inspector.menuClose",       "browser.overlay.workspaceMenuOpen",   "browser.overlay.workspaceMenuClose",   "browser.overlay.sidebarMenuOpen",
            "browser.overlay.sidebarMenuClose",  "browser.overlay.composerMenuOpen",    "browser.overlay.composerMenuClose",    "browser.overlay.projectModalOpen",
            "browser.overlay.projectModalClose", "browser.overlay.threadModalOpen",     "browser.overlay.threadModalClose",     "browser.overlay.imageModalOpen",
            "browser.overlay.imageModalClose",   "browser.overlay.transcriptModalOpen", "browser.overlay.transcriptModalClose", "terminal.write",
            "terminal.tail",                     "terminal.screen",                     "process.list",                         "process.inspect",
            "process.start",                     "process.stop",                        "process.restart",                      "process.logs",
            "stack.status",                      "stack.start",                         "stack.stop",                           "stack.restart",
        },
        .events = &.{},
        .encodings = &.{"json"},
        .terminal_binary_frames = false,
        .mcp_bridge = true,
        .auth = "local-user-socket",
    });
}

fn projectsResponse(allocator: std.mem.Allocator, id_value: std.json.Value, state: *app_state.AppState) ![]u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    var s: std.json.Stringify = .{ .writer = &writer.writer, .options = .{} };
    try beginOk(&s, id_value);
    try s.objectField("result");
    try s.beginObject();
    try s.objectField("selected_project_index");
    try s.write(state.selected_project_index);
    try s.objectField("projects");
    try s.beginArray();
    for (state.projects.items, 0..) |project, index| {
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
    try s.endObject();
    try s.endObject();
    return try writer.toOwnedSlice();
}

fn panesResponse(allocator: std.mem.Allocator, id_value: std.json.Value, state: *app_state.AppState, params: std.json.Value) ![]u8 {
    const project_index = resolveProjectIndex(state, params) orelse
        return try errorResponseAlloc(allocator, id_value, "not_found", "project not found");
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
    if (state.projects.items.len == 0) return try errorResponseAlloc(allocator, id_value, "not_found", "no projects");
    const project = &state.projects.items[state.selected_project_index];
    return try okValueResponse(allocator, id_value, .{
        .project_index = state.selected_project_index,
        .project_id = project.id,
        .focused_pane_id = project.workspace_layout.focused_pane_id,
        .maximized_pane_id = project.workspace_layout.maximized_pane_id,
    });
}

fn threadsResponse(allocator: std.mem.Allocator, id_value: std.json.Value, state: *app_state.AppState, params: std.json.Value) ![]u8 {
    const project_index = resolveProjectIndex(state, params) orelse
        return try errorResponseAlloc(allocator, id_value, "not_found", "project not found");
    const project = &state.projects.items[project_index];

    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    var s: std.json.Stringify = .{ .writer = &writer.writer, .options = .{} };
    try beginOk(&s, id_value);
    try s.objectField("result");
    try s.beginObject();
    try s.objectField("project_index");
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

fn inspectResponse(allocator: std.mem.Allocator, id_value: std.json.Value, state: *app_state.AppState, params: std.json.Value) ![]u8 {
    const target = resolvePaneTarget(state, params) orelse
        return try errorResponseAlloc(allocator, id_value, "not_found", "pane not found");
    return try inspectPaneResponse(allocator, id_value, state, target.project_index, target.pane_id);
}

fn paneCommandResponse(allocator: std.mem.Allocator, id_value: std.json.Value, state: *app_state.AppState, params: std.json.Value, command: []const u8) ![]u8 {
    const target = resolvePaneTarget(state, params) orelse
        return try errorResponseAlloc(allocator, id_value, "not_found", "pane not found");
    state.selected_project_index = target.project_index;

    var changed = false;
    if (std.mem.eql(u8, command, "focus")) {
        changed = state.focusCurrentProjectWorkspacePane(target.pane_id);
    } else if (std.mem.eql(u8, command, "split")) {
        const kind = stringParam(params, "kind") orelse return try errorResponseAlloc(allocator, id_value, "invalid_request", "pane.split requires kind");
        const axis = parseAxis(stringParam(params, "axis") orelse "horizontal") orelse
            return try errorResponseAlloc(allocator, id_value, "invalid_request", "invalid split axis");
        changed = if (std.mem.eql(u8, kind, "chat"))
            state.splitCurrentProjectWorkspacePaneWithChatAxis(target.pane_id, axis)
        else if (std.mem.eql(u8, kind, "terminal"))
            state.splitCurrentProjectWorkspacePaneWithTerminalAxis(target.pane_id, axis)
        else
            return try errorResponseAlloc(allocator, id_value, "invalid_request", "invalid split kind");
    } else if (std.mem.eql(u8, command, "resize")) {
        const first: app_state.WorkspacePaneId = @intCast(intParam(params, "first") orelse return try errorResponseAlloc(allocator, id_value, "invalid_request", "pane.resize requires first"));
        const second: app_state.WorkspacePaneId = @intCast(intParam(params, "second") orelse return try errorResponseAlloc(allocator, id_value, "invalid_request", "pane.resize requires second"));
        const axis = parseAxis(stringParam(params, "axis") orelse "horizontal") orelse
            return try errorResponseAlloc(allocator, id_value, "invalid_request", "invalid resize axis");
        const ratio = floatParam(params, "ratio") orelse return try errorResponseAlloc(allocator, id_value, "invalid_request", "pane.resize requires ratio");
        state.resizeCurrentProjectWorkspaceSplit(first, second, axis, ratio);
        changed = true;
    } else if (std.mem.eql(u8, command, "minimize")) {
        changed = state.minimizeCurrentProjectWorkspacePane(target.pane_id);
    } else if (std.mem.eql(u8, command, "maximize")) {
        const project = &state.projects.items[target.project_index];
        changed = project.workspace_layout.maximized_pane_id == target.pane_id or state.toggleCurrentProjectWorkspacePaneMaximized(target.pane_id);
    } else if (std.mem.eql(u8, command, "restore")) {
        changed = state.restoreCurrentProjectWorkspacePane(target.pane_id);
    } else if (std.mem.eql(u8, command, "close")) {
        changed = state.closeCurrentProjectWorkspacePane(target.pane_id);
    } else {
        return try errorResponseAlloc(allocator, id_value, "method_not_found", command);
    }

    if (!changed) return try errorResponseAlloc(allocator, id_value, "rejected", "pane operation did not apply");
    return try panesResponseForProject(allocator, id_value, state, target.project_index);
}

fn chatCommandResponse(allocator: std.mem.Allocator, id_value: std.json.Value, state: *app_state.AppState, params: std.json.Value, command: []const u8) ![]u8 {
    const target = resolvePaneTarget(state, params) orelse
        return try errorResponseAlloc(allocator, id_value, "not_found", "chat pane not found");
    state.selected_project_index = target.project_index;
    if (!targetIsChat(state, target)) return try errorResponseAlloc(allocator, id_value, "invalid_target", "target pane is not a chat pane");

    if (std.mem.eql(u8, command, "status")) return try chatStatusResponse(allocator, id_value, state, target.project_index, target.pane_id);
    if (std.mem.eql(u8, command, "transcript")) return try chatTranscriptResponse(allocator, id_value, state, target.project_index, target.pane_id);

    var accepted = false;
    if (std.mem.eql(u8, command, "draft.set")) {
        const text = stringParam(params, "text") orelse "";
        accepted = try state.setWorkspaceChatPaneDraft(target.pane_id, text, false);
    } else if (std.mem.eql(u8, command, "draft.append")) {
        const text = stringParam(params, "text") orelse return try errorResponseAlloc(allocator, id_value, "invalid_request", "chat.draft.append requires text");
        accepted = try state.setWorkspaceChatPaneDraft(target.pane_id, text, true);
    } else if (std.mem.eql(u8, command, "send")) {
        accepted = try state.sendWorkspaceChatPanePrompt(target.pane_id, stringParam(params, "prompt"));
    } else if (std.mem.eql(u8, command, "followup")) {
        const prompt = stringParam(params, "prompt") orelse return try errorResponseAlloc(allocator, id_value, "invalid_request", "chat.followup requires prompt");
        accepted = try state.followupWorkspaceChatPanePrompt(target.pane_id, prompt);
    } else if (std.mem.eql(u8, command, "stop")) {
        accepted = state.stopWorkspaceChatPane(target.pane_id);
    } else if (std.mem.eql(u8, command, "approve")) {
        const decision = parseApprovalDecision(stringParam(params, "decision") orelse return try errorResponseAlloc(allocator, id_value, "invalid_request", "chat.approve requires decision")) orelse
            return try errorResponseAlloc(allocator, id_value, "invalid_request", "invalid approval decision");
        accepted = state.approveWorkspaceChatPane(target.pane_id, decision);
    } else {
        return try errorResponseAlloc(allocator, id_value, "method_not_found", command);
    }

    if (!accepted) return try errorResponseAlloc(allocator, id_value, "rejected", "chat operation did not apply");
    return try chatStatusResponse(allocator, id_value, state, target.project_index, target.pane_id);
}

fn browserCommandResponse(allocator: std.mem.Allocator, id_value: std.json.Value, state: *app_state.AppState, params: std.json.Value, command: []const u8) ![]u8 {
    if (std.mem.eql(u8, command, "open")) {
        if (!state.isBrowserVisible()) state.toggleBrowser();
        return try okValueResponse(allocator, id_value, .{ .accepted = true });
    }

    if (std.mem.eql(u8, command, "close")) {
        if (state.isBrowserVisible()) state.closeBrowser();
        return try okValueResponse(allocator, id_value, .{ .accepted = true });
    }

    if (std.mem.eql(u8, command, "toggle")) {
        state.toggleBrowser();
        return try okValueResponse(allocator, id_value, .{ .accepted = true });
    }

    if (!state.isBrowserVisible()) {
        return try errorResponseAlloc(allocator, id_value, "rejected", "browser pane is not visible");
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

    if (std.mem.eql(u8, command, "overlay.projectModalOpen")) {
        state.setProjectImportModalOpen(true);
        return try okValueResponse(allocator, id_value, .{ .accepted = true });
    }

    if (std.mem.eql(u8, command, "overlay.projectModalClose")) {
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
        const script = stringParam(params, "script") orelse return try errorResponseAlloc(allocator, id_value, "invalid_request", "browser.eval requires script");
        if (script.len == 0) return try errorResponseAlloc(allocator, id_value, "invalid_request", "browser.eval requires script");
        state.browserState().controller.eval(script) catch |err| {
            return try errorResponseAlloc(allocator, id_value, "browser_eval_failed", @errorName(err));
        };
        return try okValueResponse(allocator, id_value, .{ .accepted = true });
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

fn terminalCommandResponse(allocator: std.mem.Allocator, id_value: std.json.Value, state: *app_state.AppState, params: std.json.Value, command: []const u8) ![]u8 {
    const target = resolvePaneTarget(state, params) orelse
        return try errorResponseAlloc(allocator, id_value, "not_found", "terminal pane not found");
    state.selected_project_index = target.project_index;
    if (!targetIsTerminal(state, target)) return try errorResponseAlloc(allocator, id_value, "invalid_target", "target pane is not a terminal pane");

    if (std.mem.eql(u8, command, "write")) {
        const text = stringParam(params, "text") orelse return try errorResponseAlloc(allocator, id_value, "invalid_request", "terminal.write requires text");
        if (!try state.writeWorkspaceTerminalPane(target.pane_id, text)) return try errorResponseAlloc(allocator, id_value, "rejected", "terminal write did not apply");
        return try inspectPaneResponse(allocator, id_value, state, target.project_index, target.pane_id);
    }
    if (std.mem.eql(u8, command, "tail")) {
        const max_bytes = @as(usize, @intCast((intParam(params, "lines") orelse 200) * 240));
        const output = (try state.terminalPaneOutputTail(target.pane_id, max_bytes)) orelse
            return try errorResponseAlloc(allocator, id_value, "not_found", "terminal output not found");
        defer state.allocator.free(output);
        return try okValueResponse(allocator, id_value, .{
            .project_index = target.project_index,
            .pane_id = target.pane_id,
            .truncated = output.len >= max_bytes,
            .text = output,
        });
    }
    if (std.mem.eql(u8, command, "screen")) {
        const screen = (try state.terminalPaneScreenText(target.pane_id)) orelse
            return try errorResponseAlloc(allocator, id_value, "not_found", "terminal screen not found");
        defer state.allocator.free(screen);
        return try okValueResponse(allocator, id_value, .{
            .project_index = target.project_index,
            .pane_id = target.pane_id,
            .text = screen,
        });
    }
    return try errorResponseAlloc(allocator, id_value, "method_not_found", command);
}

fn processCommandResponse(allocator: std.mem.Allocator, id_value: std.json.Value, state: *app_state.AppState, params: std.json.Value, command: []const u8) ![]u8 {
    if (std.mem.eql(u8, command, "inspect") and stringParam(params, "name") == null) {
        const target = resolvePaneTarget(state, params) orelse
            return try errorResponseAlloc(allocator, id_value, "not_found", "pane not found");
        return try inspectPaneResponse(allocator, id_value, state, target.project_index, target.pane_id);
    }
    const project_index = resolveProjectIndex(state, params) orelse return try errorResponseAlloc(allocator, id_value, "not_found", "project not found");
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
            .project_index = project_index,
            .name = name,
            .truncated = output.len >= max_bytes,
            .text = output,
        });
    }
    return try errorResponseAlloc(allocator, id_value, "method_not_found", command);
}

fn stackCommandResponse(allocator: std.mem.Allocator, id_value: std.json.Value, state: *app_state.AppState, params: std.json.Value, command: []const u8) ![]u8 {
    const project_index = resolveProjectIndex(state, params) orelse return try errorResponseAlloc(allocator, id_value, "not_found", "project not found");
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
    const project = &state.projects.items[project_index];
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
    if (state.projects.items.len == 0) return null;
    if (params == .object) {
        if (jsonString(params.object.get("project") orelse .null)) |project_ref| {
            if (std.mem.eql(u8, project_ref, "current")) return state.selected_project_index;
            if (std.fmt.parseInt(usize, project_ref, 10)) |index| {
                if (index < state.projects.items.len) return index;
            } else |_| {}
            for (state.projects.items, 0..) |project, index| {
                if (std.mem.eql(u8, project.id, project_ref) or std.mem.eql(u8, project.path, project_ref)) return index;
            }
            return null;
        }
    }
    return state.selected_project_index;
}

fn resolveProjectIndexNullable(state: *app_state.AppState, params: std.json.Value) ?usize {
    if (params == .object and (params.object.get("project") != null)) return resolveProjectIndex(state, params);
    return null;
}

fn targetIsChat(state: *app_state.AppState, target: PaneTarget) bool {
    const pane = state.projects.items[target.project_index].workspace_layout.paneById(target.pane_id) orelse return false;
    return pane.ref == .chat;
}

fn targetIsTerminal(state: *app_state.AppState, target: PaneTarget) bool {
    const pane = state.projects.items[target.project_index].workspace_layout.paneById(target.pane_id) orelse return false;
    return pane.ref == .terminal;
}

fn writeSelectedProjectPanes(s: *std.json.Stringify, state: *app_state.AppState) !void {
    if (state.projects.items.len == 0) {
        try s.write(null);
        return;
    }
    try writeProjectPanes(s, state, state.selected_project_index);
}

fn writeProjectPanes(s: *std.json.Stringify, state: *app_state.AppState, project_index: usize) !void {
    const project = &state.projects.items[project_index];
    try s.beginObject();
    try s.objectField("project_index");
    try s.write(project_index);
    try s.objectField("project_id");
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
    const project = &state.projects.items[project_index];
    try s.beginObject();
    try s.objectField("pane_id");
    try s.write(pane.id);
    try s.objectField("minimized");
    try s.write(pane.minimized);
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
                const pending_approval = threadHasPendingApproval(thread);
                try s.objectField("pending_approval");
                try s.write(pending_approval);
                try s.objectField("attention");
                try s.write(pending_approval);
                try s.objectField("attention_reasons");
                try s.beginArray();
                if (pending_approval) try s.write("pending_approval");
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
            const attention = terminalDockHasAttention(project, ref.dock_id);
            try s.objectField("attention");
            try s.write(attention);
            try s.objectField("attention_reasons");
            try writeTerminalAttentionReasons(s, project, ref.dock_id);
        },
        .browser => {
            try s.objectField("kind");
            try s.write("browser");
            try s.objectField("visible");
            try s.write(state.isBrowserVisible());
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
    try s.objectField("provider_thread_id");
    if (thread.provider_thread_id) |thread_id| try s.write(thread_id) else try s.write(null);
    try s.objectField("message_count");
    try s.write(thread.messages.items.len);
    try s.objectField("send_pending");
    try s.write(thread.isSendPendingForUi());
    try s.endObject();
}

fn writeTerminalsArray(s: *std.json.Stringify, state: *app_state.AppState, maybe_project_index: ?usize) !void {
    try s.beginArray();
    for (state.projects.items, 0..) |project, project_index| {
        if (maybe_project_index) |wanted| {
            if (wanted != project_index) continue;
        }
        for (project.workspace_layout.panes.items) |pane| {
            if (pane.ref != .terminal) continue;
            const ref = pane.ref.terminal;
            try s.beginObject();
            try s.objectField("project_index");
            try s.write(project_index);
            try s.objectField("project_id");
            try s.write(project.id);
            try s.objectField("pane_id");
            try s.write(pane.id);
            try s.objectField("dock_id");
            try s.write(ref.dock_id);
            try s.objectField("minimized");
            try s.write(pane.minimized);
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
            const attention = terminalDockHasAttention(&project, ref.dock_id);
            try s.objectField("attention");
            try s.write(attention);
            try s.objectField("attention_reasons");
            try writeTerminalAttentionReasons(s, &project, ref.dock_id);
            try s.endObject();
        }
    }
    try s.endArray();
}

fn managedProcessesResponse(allocator: std.mem.Allocator, id_value: std.json.Value, state: *app_state.AppState, params: std.json.Value) ![]u8 {
    const project_index = resolveProjectIndexNullable(state, params);
    if (project_index) |index| {
        if (index >= state.projects.items.len) return try errorResponseAlloc(allocator, id_value, "not_found", "project not found");
        if (try refreshStackConfigOrError(allocator, id_value, state, index)) |response| return response;
    } else {
        var index: usize = 0;
        while (index < state.projects.items.len) : (index += 1) {
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
    if (project_index >= state.projects.items.len) return try errorResponseAlloc(allocator, id_value, "not_found", "project not found");
    state.refreshManagedProcessStatuses(project_index);

    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    var s: std.json.Stringify = .{ .writer = &writer.writer, .options = .{} };
    try beginOk(&s, id_value);
    try s.objectField("result");
    try s.beginObject();
    try s.objectField("project_index");
    try s.write(project_index);
    try s.objectField("project_id");
    try s.write(state.projects.items[project_index].id);
    try s.objectField("stack_config_error");
    if (state.projects.items[project_index].stack_config_error) |message| try s.write(message) else try s.write(null);
    try s.objectField("processes");
    try writeManagedProcessesArray(&s, state, project_index);
    try s.endObject();
    try s.endObject();
    return try writer.toOwnedSlice();
}

fn managedProcessResponse(allocator: std.mem.Allocator, id_value: std.json.Value, state: *app_state.AppState, project_index: usize, name: []const u8) ![]u8 {
    if (project_index >= state.projects.items.len) return try errorResponseAlloc(allocator, id_value, "not_found", "project not found");
    state.refreshManagedProcessStatuses(project_index);
    const project = &state.projects.items[project_index];
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
    for (state.projects.items, 0..) |*project, project_index| {
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
    const project = &state.projects.items[project_index];
    try s.beginObject();
    try s.objectField("project_index");
    try s.write(project_index);
    try s.objectField("project_id");
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
    try s.objectField("status");
    try s.write(@tagName(process.status));
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
        if (state.projectTerminalDock(project_index, dock_id)) |dock| {
            try s.objectField("running");
            try s.write(dock.hasRunningSession());
            try s.objectField("active_tab_index");
            try s.write(dock.active_tab_index);
            try s.objectField("tab_count");
            try s.write(dock.tabs.items.len);
            try s.objectField("terminal_cwd");
            if (dock.cwd) |cwd| try s.write(cwd) else try s.write(null);
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
    if (project_index < state.projects.items.len) {
        if (state.projects.items[project_index].stack_config_error) |message| return message;
    }
    return @errorName(err);
}

fn threadHasPendingApproval(thread: *const app_state.ChatThread) bool {
    const send_state = thread.send_state;
    if (!send_state.mutex.tryLock()) return true;
    defer send_state.mutex.unlock();
    return send_state.status == .pending and send_state.pending_approval != null;
}

fn terminalDockHasAttention(project: *const app_state.Project, dock_id: u32) bool {
    for (project.managed_processes.items) |process| {
        if (process.dock_id == null or process.dock_id.? != dock_id) continue;
        if (process.status == .crashed or process.pending_watch_restart_ms != 0) return true;
    }
    return false;
}

fn writeTerminalAttentionReasons(s: *std.json.Stringify, project: *const app_state.Project, dock_id: u32) !void {
    try s.beginArray();
    for (project.managed_processes.items) |process| {
        if (process.dock_id == null or process.dock_id.? != dock_id) continue;
        if (process.status == .crashed) try s.write("process_crashed");
        if (process.pending_watch_restart_ms != 0) try s.write("watch_restart_pending");
    }
    try s.endArray();
}

fn chatStatusResponse(allocator: std.mem.Allocator, id_value: std.json.Value, state: *app_state.AppState, project_index: usize, pane_id: app_state.WorkspacePaneId) ![]u8 {
    const project = &state.projects.items[project_index];
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
    try s.objectField("project_index");
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

fn chatTranscriptResponse(allocator: std.mem.Allocator, id_value: std.json.Value, state: *app_state.AppState, project_index: usize, pane_id: app_state.WorkspacePaneId) ![]u8 {
    const project = &state.projects.items[project_index];
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
    try s.objectField("project_index");
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

fn inspectPaneResponse(allocator: std.mem.Allocator, id_value: std.json.Value, state: *app_state.AppState, project_index: usize, pane_id: app_state.WorkspacePaneId) ![]u8 {
    const project = &state.projects.items[project_index];
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

fn parseApprovalDecision(value: []const u8) ?provider_types.ApprovalDecision {
    if (std.mem.eql(u8, value, "approve") or std.mem.eql(u8, value, "approved") or std.mem.eql(u8, value, "allow")) return .approve;
    if (std.mem.eql(u8, value, "deny") or std.mem.eql(u8, value, "reject") or std.mem.eql(u8, value, "rejected")) return .deny;
    return null;
}

fn deleteSocketPath(path: []const u8) void {
    var threaded = std.Io.Threaded.init_single_threaded;
    std.Io.Dir.deleteFileAbsolute(threaded.io(), path) catch {};
}

fn wakeServer(path: []const u8) void {
    var threaded = std.Io.Threaded.init_single_threaded;
    const address = std.Io.net.UnixAddress.init(path) catch return;
    const stream = address.connect(threaded.io()) catch return;
    stream.close(threaded.io());
}
