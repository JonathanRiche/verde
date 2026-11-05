//! Google Antigravity provider harness backed by the Antigravity CLI ACP
//! server (`agy acp`). Generic ACP transport/protocol machinery lives in
//! `acp.zig`; this module owns agy binary discovery, argv construction, and
//! agy's model catalog, which it publishes as ACP `models.availableModels`
//! in session responses and switches through `session/set_model` (agy acp
//! has no `--model` flag). ACP session ids are agy conversation ids, so a GUI
//! thread reopens in the TUI with `agy --conversation <id>`.

const std = @import("std");
const acp = @import("acp.zig");
const platform_process = @import("../platform/process.zig");
const provider_mcp = @import("mcp.zig");
const process_env = @import("../platform/env.zig");
const provider_types = @import("types.zig");
const runtime_log = @import("../runtime/log.zig");

const DEFAULT_EXECUTABLE = "agy";
// The official installer (`curl -fsSL https://antigravity.google/cli/install.sh | bash`)
// places the binary here, which desktop launch environments often lack on PATH.
const INSTALL_FALLBACK_RELATIVE = ".local/bin/agy";
/// Verde's sentinel for deferring to agy's own persisted model selection.
const DEFAULT_MODEL = "default";
/// `session/set_model` request id, outside the shared handlers' 1/2/3
/// sequence so its response passes through `acp.handleSendPromptLine`.
const SET_MODEL_REQUEST_ID: i64 = 12;

/// Auth probes spawn the full ACP agent; a wedged handshake must end before
/// the next readiness poll instead of piling up.
const AUTH_PROBE_DEADLINE_MS: u64 = 10_000;

/// agy reports account eligibility/license failures (#3501) as an ordinary
/// assistant chunk followed by `end_turn`, so the raw notice would otherwise
/// be committed as the model's reply.
const ACCOUNT_INELIGIBLE_MESSAGE =
    \\**Antigravity account not eligible**
    \\
    \\Antigravity refused this turn because the signed-in Google account has no valid Antigravity license. Sign in with an eligible account (run `agy acp --login`, or start `agy` and use `/login`), then try again.
    \\
    \\Technical details: `PERMISSION_DENIED (#3501)`
;

const ACP_HARNESS: acp.Harness = .{
    .diagnostics_category = .antigravity_acp,
    .assistant_author = "Antigravity",
    .permission_default_title = "Antigravity permission request",
    .agent_error_message = antigravityAgentErrorMessage,
};

var active_process_state: acp.ActiveProcessState = .{};

fn antigravityAgentErrorMessage(text: []const u8) ?[]const u8 {
    if (std.mem.indexOf(u8, text, "valid license of this product") != null or
        std.mem.indexOf(u8, text, "(#3501)") != null or
        std.mem.indexOf(u8, text, "not eligible for Antigravity") != null)
    {
        return ACCOUNT_INELIGIBLE_MESSAGE;
    }
    return null;
}

/// agy's command list arrives live through `available_commands_update` and is
/// merged by the harness; no static catalog is needed.
pub fn providerSlashCommands() []const provider_types.ProviderSlashCommand {
    return &.{};
}

pub const Config = struct {
    executable: []const u8 = DEFAULT_EXECUTABLE,
    cwd: ?[]const u8 = null,
    // agy persists its own model selection per conversation; null or
    // "default" defers to it.
    model: ?[]const u8 = null,
};

pub const Client = struct {
    allocator: std.mem.Allocator,
    config: Config,

    pub fn init(allocator: std.mem.Allocator, config: Config) !Client {
        return .{ .allocator = allocator, .config = config };
    }

    pub fn deinit(self: *Client) void {
        _ = self;
    }

    pub fn slashCommands(self: *Client) []const provider_types.ProviderSlashCommand {
        _ = self;
        return providerSlashCommands();
    }

    // agy resolves `/name args` itself (built-in commands, skills, and the
    // commands it advertises over ACP), so every command is a prompt turn
    // whose reply becomes the transcript row.
    pub fn runSlashCommand(
        self: *Client,
        allocator: std.mem.Allocator,
        request: provider_types.RunSlashCommandRequest,
    ) !provider_types.RunSlashCommandResult {
        const command_name = acp.slashCommandRoot(request.raw_text) orelse return error.UnsupportedOperation;
        const prompt = std.mem.trim(u8, request.raw_text, " \t\r\n");

        const reply = try self.sendPrompt(allocator, .{
            .thread_id = request.thread_id,
            .prompt = prompt,
            .cwd = request.cwd,
        });
        errdefer allocator.free(reply.thread_id);
        defer allocator.free(reply.reply_text);

        const body = std.mem.trim(u8, reply.reply_text, " \t\r\n");
        const transcript_body = try allocator.dupe(u8, if (body.len == 0) "Done." else body);
        errdefer allocator.free(transcript_body);
        const transcript_title = try allocator.dupe(u8, command_name);
        errdefer allocator.free(transcript_title);
        const notice = try std.fmt.allocPrint(allocator, "Antigravity ran {s}.", .{command_name});

        return .{
            .handled = true,
            .thread_id = reply.thread_id,
            .notice = notice,
            .transcript_title = transcript_title,
            .transcript_body = transcript_body,
        };
    }

    // agy has no status subcommand; ACP initialize is the auth probe. It
    // reuses cached credentials and fails initialize with a sign-in error
    // when none exist, which the shared layer maps to AcpSignedOut.
    pub fn authState(self: *Client) !provider_types.AuthState {
        var proc = self.spawnAcp(self.allocator, false) catch |err| switch (err) {
            error.FileNotFound => return .unknown,
            else => return err,
        };
        defer proc.deinit();
        var deadline: acp.ProcessDeadline = .{ .child = &proc.process, .deadline_ms = AUTH_PROBE_DEADLINE_MS };
        deadline.start() catch return .unknown;
        defer deadline.finish();

        proc.writeLine(acp.makeInitializeRequestAlloc(self.allocator, 1) catch return .unknown) catch return .unknown;
        proc.closeStdin() catch return .unknown;

        var read_buffer: [16 * 1024]u8 = undefined;
        var reader = proc.process.child.stdout.?.reader(proc.threaded.io(), &read_buffer);
        while (true) {
            const raw_line = (acp.takeLineAlloc(self.allocator, &reader) catch return .unknown) orelse return .unknown;
            defer self.allocator.free(raw_line);
            const line = std.mem.trim(u8, raw_line, " \t\r");
            if (line.len == 0) continue;
            var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, line, .{}) catch return .unknown;
            defer parsed.deinit();
            acp.failIfJsonRpcError(ACP_HARNESS, parsed.value) catch |err| switch (err) {
                error.AcpSignedOut => return .signed_out,
                else => return .unknown,
            };
            if (acp.responseId(parsed.value)) |id| {
                if (id == 1) {
                    deadline.finish();
                    proc.stop();
                    return .signed_in;
                }
            }
        }
    }

    pub fn listThreads(self: *Client, allocator: std.mem.Allocator) ![]provider_types.ChatThreadSummary {
        return self.listThreadsAcp(allocator) catch |err| return mapAcpError(err);
    }

    pub fn listModels(self: *Client, allocator: std.mem.Allocator) ![]provider_types.ModelInfo {
        return self.listModelsAcp(allocator) catch |err| return mapAcpError(err);
    }

    pub fn readThread(
        self: *Client,
        allocator: std.mem.Allocator,
        thread_id: []const u8,
    ) !provider_types.ReadThreadResult {
        return self.readThreadAcp(allocator, thread_id) catch |err| return mapAcpError(err);
    }

    pub fn sendPrompt(
        self: *Client,
        allocator: std.mem.Allocator,
        request: provider_types.SendPromptRequest,
    ) !provider_types.SendPromptResult {
        return self.sendPromptAcp(allocator, request) catch |err| return mapAcpError(err);
    }

    pub fn interruptThread(self: *Client, request: provider_types.InterruptThreadRequest) !void {
        _ = self;
        active_process_state.lock();
        defer active_process_state.unlock();

        const child = active_process_state.child orelse return;
        const session_id = active_process_state.session_id orelse return;
        if (!std.mem.eql(u8, session_id, request.thread_id)) return;
        if (active_process_state.stdin) |stdin| {
            const line = try acp.makeCancelNotificationAlloc(std.heap.page_allocator, session_id);
            defer std.heap.page_allocator.free(line);
            acp.writeJsonLineToFile(std.heap.page_allocator, stdin, line) catch {
                child.terminateTree();
            };
        } else {
            child.terminateTree();
        }
    }

    pub fn steerThread(self: *Client, request: provider_types.SteerThreadRequest) !void {
        _ = self;
        _ = request;
        return error.UnsupportedOperation;
    }

    fn listThreadsAcp(self: *Client, allocator: std.mem.Allocator) ![]provider_types.ChatThreadSummary {
        var proc = try self.spawnAcp(allocator, false);
        defer proc.deinit();

        var state: acp.ListThreadsState = .{};
        errdefer state.deinit(allocator);

        try proc.writeLine(try acp.makeInitializeRequestAlloc(allocator, 1));
        try proc.writeLine(try acp.makeSessionListRequestAlloc(allocator, 2, try self.cwdAbsoluteAlloc(allocator)));
        try proc.closeStdin();

        var read_buffer: [16 * 1024]u8 = undefined;
        var reader = proc.process.child.stdout.?.reader(proc.threaded.io(), &read_buffer);
        while (try acp.takeLineAlloc(allocator, &reader)) |raw_line| {
            defer allocator.free(raw_line);
            const line = std.mem.trim(u8, raw_line, " \t\r");
            if (line.len == 0) continue;
            if (try acp.handleListThreadsLine(allocator, ACP_HARNESS, line, &state)) break;
        }

        proc.stop();
        const threads = try state.threads.toOwnedSlice(allocator);
        state.threads = .empty;
        return threads;
    }

    // agy publishes its model catalog only in session responses. Resuming the
    // newest existing conversation (no history replay) avoids minting an
    // empty conversation on every refresh; session/new is the first-run
    // fallback.
    fn listModelsAcp(self: *Client, allocator: std.mem.Allocator) ![]provider_types.ModelInfo {
        var proc = try self.spawnAcp(allocator, false);
        defer proc.deinit();

        const cwd = try self.cwdAbsoluteAlloc(allocator);
        defer allocator.free(cwd);

        try proc.writeLine(try acp.makeInitializeRequestAlloc(allocator, 1));
        try proc.writeLine(try acp.makeSessionListRequestAlloc(allocator, 2, try allocator.dupe(u8, cwd)));

        var capabilities: acp.Capabilities = .{};
        var read_buffer: [16 * 1024]u8 = undefined;
        var reader = proc.process.child.stdout.?.reader(proc.threaded.io(), &read_buffer);
        while (try acp.takeLineAlloc(allocator, &reader)) |raw_line| {
            defer allocator.free(raw_line);
            const line = std.mem.trim(u8, raw_line, " \t\r");
            if (line.len == 0) continue;
            var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
            defer parsed.deinit();
            try acp.failIfJsonRpcError(ACP_HARNESS, parsed.value);
            const id = acp.responseId(parsed.value) orelse continue;
            if (id == 1) {
                capabilities = acp.parseCapabilities(parsed.value);
                continue;
            }
            if (id == 2) {
                const newest = try newestSessionIdAlloc(allocator, parsed.value);
                defer if (newest) |session_id| allocator.free(session_id);
                try proc.writeLine(try acp.makeTurnSessionRequestAlloc(allocator, 3, capabilities, .{
                    .cwd = cwd,
                    .session_id = newest,
                }));
                try proc.closeStdin();
                continue;
            }
            if (id == 3) {
                const models = try parseAvailableModelsAlloc(allocator, parsed.value);
                proc.stop();
                return models;
            }
        }
        return error.AcpFailed;
    }

    fn readThreadAcp(
        self: *Client,
        allocator: std.mem.Allocator,
        thread_id: []const u8,
    ) !provider_types.ReadThreadResult {
        var proc = try self.spawnAcp(allocator, false);
        defer proc.deinit();

        const cwd = try self.cwdAbsoluteAlloc(allocator);
        defer allocator.free(cwd);

        var state: acp.ReadThreadState = .{};
        errdefer state.deinit(allocator);

        try proc.writeLine(try acp.makeInitializeRequestAlloc(allocator, 1));
        try proc.writeLine(try acp.makeSessionLoadRequestWithHttpMcpAlloc(allocator, 2, thread_id, cwd, null));
        try proc.closeStdin();

        var read_buffer: [16 * 1024]u8 = undefined;
        var reader = proc.process.child.stdout.?.reader(proc.threaded.io(), &read_buffer);
        while (try acp.takeLineAlloc(allocator, &reader)) |raw_line| {
            defer allocator.free(raw_line);
            const line = std.mem.trim(u8, raw_line, " \t\r");
            if (line.len == 0) continue;
            if (try acp.handleReadThreadLine(allocator, ACP_HARNESS, line, thread_id, &state)) break;
        }

        proc.stop();
        const messages = try state.messages.toOwnedSlice(allocator);
        state.messages = .empty;
        const title = if (state.title) |title| title else try allocator.dupe(u8, thread_id);
        state.title = null;
        return .{
            .thread_id = try allocator.dupe(u8, thread_id),
            .title = title,
            .messages = messages,
        };
    }

    fn sendPromptAcp(
        self: *Client,
        allocator: std.mem.Allocator,
        request: provider_types.SendPromptRequest,
    ) !provider_types.SendPromptResult {
        // Full Access runs agy's own auto-approve mode so concurrent tool
        // permission requests never queue behind ACP's approval exchange.
        var proc = try self.spawnAcp(allocator, acp.shouldAutoApprovePermission(request));
        defer proc.deinit();

        const cwd = try self.cwdAbsoluteAllocForRequest(allocator, request);
        defer allocator.free(cwd);
        // agy reads Verde's MCP entry from ~/.gemini/config/mcp_config.json;
        // the per-session server is offered too but the shared layer drops it
        // unless agy advertises `mcpCapabilities.http`.
        var mcp_connection = if (provider_mcp.isInstalled(allocator, .antigravity))
            try provider_mcp.loadHttpConnection(allocator)
        else
            null;
        defer if (mcp_connection) |*connection| connection.deinit(allocator);
        const mcp_http: ?acp.McpHttpServer = if (mcp_connection) |connection| .{
            .url = connection.url,
            .authorization = connection.authorization,
            .client_name = "antigravity",
        } else null;

        var state: acp.SendPromptState = .{};
        defer state.deinit(allocator);
        const requested_model = requestedModel(request.model orelse self.config.model);
        var switch_model: ?[]u8 = null;
        defer if (switch_model) |model| allocator.free(model);
        var awaiting_model_switch = false;

        try proc.writeLine(try acp.makeInitializeRequestAlloc(allocator, 1));

        var read_buffer: [16 * 1024]u8 = undefined;
        var reader = proc.process.child.stdout.?.reader(proc.threaded.io(), &read_buffer);
        while (try acp.takeLineAlloc(allocator, &reader)) |raw_line| {
            defer allocator.free(raw_line);
            const line = std.mem.trim(u8, raw_line, " \t\r");
            if (line.len == 0) continue;
            if (state.session_id == null and switch_model == null) {
                switch_model = try sessionModelSwitchAlloc(allocator, line, requested_model, request.reasoning_effort);
            }
            if (awaiting_model_switch) {
                if (try modelSwitchResponse(allocator, line)) |switched| {
                    // A rejected switch goes through the shared error handler
                    // below; never submit a turn on an unintended model.
                    if (switched) {
                        awaiting_model_switch = false;
                        try submitPrompt(allocator, &proc, &state, request);
                        continue;
                    }
                }
            }
            const action = try acp.handleSendPromptLine(allocator, ACP_HARNESS, line, request, &state, proc.process.child.stdin);
            switch (action) {
                .continue_reading => {},
                .initialized => try proc.writeLine(try acp.makeTurnSessionRequestAlloc(allocator, 2, state.capabilities, .{
                    .cwd = cwd,
                    .session_id = request.thread_id,
                    .mcp_http = mcp_http,
                })),
                .session_ready => {
                    if (state.session_id) |session_id| {
                        active_process_state.register(&proc.process, proc.process.child.stdin, session_id);
                        if (request.on_thread_id) |on_thread_id| on_thread_id(request.stream_context, session_id);
                        if (request.on_turn_id) |on_turn_id| on_turn_id(request.stream_context, session_id);
                        // The prompt waits for the set_model reply so the
                        // turn never starts on the previous model.
                        if (switch_model) |model| {
                            try proc.writeLine(try acp.makeSetModelRequestAlloc(allocator, SET_MODEL_REQUEST_ID, session_id, model));
                            awaiting_model_switch = true;
                        } else {
                            try submitPrompt(allocator, &proc, &state, request);
                        }
                    }
                },
                .prompt_done => break,
            }
            if (request.on_should_stop) |should_stop| {
                if (should_stop(request.stream_context)) {
                    if (state.session_id) |session_id| {
                        try proc.writeLine(try acp.makeCancelNotificationAlloc(allocator, session_id));
                    }
                    return error.CodexTurnInterrupted;
                }
            }
        }

        active_process_state.unregister(&proc.process);
        try proc.closeStdin();
        proc.stop();

        const thread_id = state.session_id orelse return error.AcpFailed;
        state.session_id = null;
        const reply_text = try state.reply.toOwnedSlice(allocator);
        state.reply = .empty;
        return .{
            .thread_id = thread_id,
            .reply_text = reply_text,
        };
    }

    fn spawnAcp(self: *Client, allocator: std.mem.Allocator, auto_approve: bool) !acp.Process {
        var env_map = try process_env.buildAugmentedEnvMap(allocator);
        errdefer env_map.deinit();
        const executable = try resolveAgyExecutableAlloc(allocator, &env_map, self.config.executable);
        errdefer allocator.free(executable);

        var threaded: std.Io.Threaded = .init(allocator, .{});
        errdefer threaded.deinit();
        const argv_auto_approve = [_][]const u8{ executable, "acp", "--dangerously-skip-permissions" };
        const argv_default = [_][]const u8{ executable, "acp" };
        var child = try platform_process.spawn(allocator, threaded.io(), .{
            .argv = if (auto_approve) argv_auto_approve[0..] else argv_default[0..],
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .inherit,
            .cwd = if (self.config.cwd) |path| .{ .path = path } else .inherit,
            .environ_map = &env_map,
        });
        errdefer child.kill(threaded.io());

        return .{
            .allocator = allocator,
            .threaded = threaded,
            .process = child,
            .env_map = env_map,
            .executable = executable,
            .active_state = &active_process_state,
        };
    }

    fn cwdAbsoluteAlloc(self: *Client, allocator: std.mem.Allocator) ![]u8 {
        if (self.config.cwd) |cwd| return std.fs.path.resolve(allocator, &.{cwd});
        var threaded: std.Io.Threaded = .init(allocator, .{});
        defer threaded.deinit();
        return std.process.currentPathAlloc(threaded.io(), allocator);
    }

    fn cwdAbsoluteAllocForRequest(self: *Client, allocator: std.mem.Allocator, request: provider_types.SendPromptRequest) ![]u8 {
        if (request.cwd) |cwd| return std.fs.path.resolve(allocator, &.{cwd});
        return self.cwdAbsoluteAlloc(allocator);
    }
};

pub fn shutdownOwnedServer() void {
    active_process_state.lock();
    defer active_process_state.unlock();
    if (active_process_state.child) |child| child.terminateTree();
}

/// Maps provider-neutral ACP errors to Antigravity error names so user-facing
/// messaging can address agy specifically (e.g. suggest `agy acp --login`).
fn mapAcpError(err: anyerror) anyerror {
    return switch (err) {
        error.AcpFailed => error.AntigravityAcpFailed,
        error.AcpRefused => error.AntigravityAcpRefused,
        error.AcpSignedOut => error.AntigravitySignedOut,
        error.AcpMessageTooLarge => error.AntigravityAcpMessageTooLarge,
        error.AcpAttachmentsUnsupported => error.AntigravityAttachmentsUnsupported,
        else => err,
    };
}

fn submitPrompt(
    allocator: std.mem.Allocator,
    proc: *acp.Process,
    state: *acp.SendPromptState,
    request: provider_types.SendPromptRequest,
) !void {
    const session_id = state.session_id orelse return error.AcpFailed;
    try proc.writeLine(try acp.makePromptRequestAlloc(allocator, 3, session_id, request, state.capabilities.image));
    state.prompt_submitted = true;
}

/// Outcome of the `session/set_model` exchange carried by `line`: true when
/// agy accepted it, false when it answered with an error, and null when the
/// line is anything else.
fn modelSwitchResponse(allocator: std.mem.Allocator, line: []const u8) !?bool {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch return null;
    defer parsed.deinit();
    if (acp.serverRequestId(parsed.value) != null) return null;
    if ((acp.responseId(parsed.value) orelse return null) != SET_MODEL_REQUEST_ID) return null;
    return acp.getObjectField(parsed.value, "error") == null;
}

fn requestedModel(model: ?[]const u8) ?[]const u8 {
    const value = model orelse return null;
    if (value.len == 0 or std.mem.eql(u8, value, DEFAULT_MODEL)) return null;
    return value;
}

/// Effort tiers agy folds into model ids, as `<base>-<tier>`.
const EFFORT_TIERS = [_][]const u8{ "low", "medium", "high", "xhigh", "max" };

const SplitModelId = struct { base: []const u8, effort: ?[]const u8 };

/// Splits an agy model id into its base model and thinking tier:
/// `gemini-3.8-flash-high` is base `gemini-3.8-flash`, tier `high`. Ids
/// without a tier suffix (`claude-sonnet-4-6`) are their own base.
fn splitModelId(id: []const u8) SplitModelId {
    for (EFFORT_TIERS) |tier| {
        if (id.len > tier.len + 1 and std.mem.endsWith(u8, id, tier) and id[id.len - tier.len - 1] == '-') {
            return .{ .base = id[0 .. id.len - tier.len - 1], .effort = id[id.len - tier.len ..] };
        }
    }
    return .{ .base = id, .effort = null };
}

fn catalogHasModel(entries: []const std.json.Value, id: []const u8) bool {
    for (entries) |entry| {
        const listed = acp.getOptionalObjectString(entry, "modelId") orelse continue;
        if (std.mem.eql(u8, listed, id)) return true;
    }
    return false;
}

/// The agy model id to pass to `session/set_model` once the session is up,
/// or null when the session already runs it or agy lists no match. Verde
/// threads store agy's base model (`gemini-3.8-flash`) and a separate
/// reasoning effort; agy serves the pair as one id (`gemini-3.8-flash-low`).
/// A null or "default" model keeps the session's current base, and a null
/// effort keeps the session's current tier when the base offers it. Exact
/// catalog ids (older thread refs such as `gemini-3.8-flash-low`) still
/// resolve. agy rejects ids outside its catalog, so a stale model or tier
/// keeps the session's current model rather than failing the turn.
fn sessionModelSwitchAlloc(
    allocator: std.mem.Allocator,
    line: []const u8,
    requested_model: ?[]const u8,
    requested_effort: ?provider_types.ReasoningEffort,
) !?[]u8 {
    if (requested_model == null and requested_effort == null) return null;
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch return null;
    defer parsed.deinit();
    if ((acp.responseId(parsed.value) orelse return null) != 2) return null;
    const result = acp.getObjectField(parsed.value, "result") orelse return null;
    const models = acp.getObjectField(result, "models") orelse return null;
    const entries_value = acp.getObjectField(models, "availableModels") orelse return null;
    if (entries_value != .array) return null;
    const entries = entries_value.array.items;
    const current = acp.getOptionalObjectString(models, "currentModelId");
    const current_split: ?SplitModelId = if (current) |id| splitModelId(id) else null;

    var target_buffer: [256]u8 = undefined;
    const target: []const u8 = blk: {
        if (requested_model) |model| {
            // An exact catalog id names its own tier unless an effort overrides it.
            if (requested_effort == null and catalogHasModel(entries, model)) break :blk model;
        }
        const base = if (requested_model) |model| splitModelId(model).base else (if (current_split) |split| split.base else return null);
        const effort: ?[]const u8 = if (requested_effort) |effort|
            @tagName(effort)
        else if (requested_model) |model|
            (splitModelId(model).effort orelse if (current_split) |split| split.effort else null)
        else
            null;
        if (effort) |tier| {
            const id = std.fmt.bufPrint(&target_buffer, "{s}-{s}", .{ base, tier }) catch return null;
            if (catalogHasModel(entries, id)) break :blk id;
        }
        if (catalogHasModel(entries, base)) break :blk base;
        // The base exists only with tiers: keep the session's tier when it
        // is on the same base, else agy's top tier for that base.
        if (current_split) |split| {
            if (std.mem.eql(u8, split.base, base)) return null;
        }
        for ([_][]const u8{ "high", "medium", "low" }) |tier| {
            const id = std.fmt.bufPrint(&target_buffer, "{s}-{s}", .{ base, tier }) catch return null;
            if (catalogHasModel(entries, id)) break :blk id;
        }
        return null;
    };
    if (current) |id| {
        if (std.mem.eql(u8, id, target)) return null;
    }
    return try allocator.dupe(u8, target);
}

// agy session/list entries carry sessionId/cwd/title/updatedAt (ISO-8601, so
// lexicographic comparison orders chronologically).
fn newestSessionIdAlloc(allocator: std.mem.Allocator, value: std.json.Value) !?[]u8 {
    const result = acp.getObjectField(value, "result") orelse return null;
    const sessions = acp.getObjectField(result, "sessions") orelse return null;
    if (sessions != .array) return null;

    var newest_id: ?[]const u8 = null;
    var newest_stamp: []const u8 = "";
    for (sessions.array.items) |session| {
        if (session != .object) continue;
        const id = acp.getOptionalObjectString(session, "sessionId") orelse continue;
        const stamp = acp.getOptionalObjectString(session, "updatedAt") orelse "";
        if (newest_id == null or std.mem.order(u8, stamp, newest_stamp) != .lt) {
            newest_id = id;
            newest_stamp = stamp;
        }
    }
    const id = newest_id orelse return null;
    return try allocator.dupe(u8, id);
}

// Parses `result.models.availableModels` ({modelId, name}) from a session
// response into one row per base model. agy folds its thinking level into the
// id (`gemini-3.8-flash-high` / name `Gemini 3.8 Flash (High)`); Verde shows
// the base model and offers those tiers in its separate reasoning menu, so
// each row carries its tiers in `grok_effort_values` (the shared per-model
// effort catalog field).
fn parseAvailableModelsAlloc(allocator: std.mem.Allocator, value: std.json.Value) ![]provider_types.ModelInfo {
    var models: std.ArrayList(provider_types.ModelInfo) = .empty;
    errdefer {
        for (models.items) |model| model.deinit(allocator);
        models.deinit(allocator);
    }
    var tiers: std.ArrayList(std.ArrayList([:0]const u8)) = .empty;
    defer {
        for (tiers.items) |*list| {
            for (list.items) |tier| allocator.free(tier);
            list.deinit(allocator);
        }
        tiers.deinit(allocator);
    }

    const result = acp.getObjectField(value, "result") orelse return error.AcpFailed;
    const model_state = acp.getObjectField(result, "models") orelse return error.AcpFailed;
    const entries = acp.getObjectField(model_state, "availableModels") orelse return error.AcpFailed;
    if (entries != .array) return error.AcpFailed;
    for (entries.array.items) |entry| {
        if (entry != .object) continue;
        const id = acp.getOptionalObjectString(entry, "modelId") orelse continue;
        const split = splitModelId(id);
        const index = for (models.items, 0..) |model, i| {
            if (std.mem.eql(u8, model.model_id, split.base)) break i;
        } else blk: {
            const name = baseModelName(acp.getOptionalObjectString(entry, "name") orelse split.base);
            const description = acp.getOptionalObjectString(entry, "description");
            const owned_description: ?[]const u8 = if (description) |text| try allocator.dupe(u8, text) else null;
            errdefer if (owned_description) |text| allocator.free(text);
            try models.append(allocator, .{
                .provider_id = try allocator.dupe(u8, "antigravity"),
                .provider_name = try allocator.dupe(u8, "Antigravity"),
                .model_id = try allocator.dupe(u8, split.base),
                .model_name = try allocator.dupe(u8, name),
                .description = owned_description,
                .reasoning_supported = false,
            });
            try tiers.append(allocator, .empty);
            break :blk models.items.len - 1;
        };
        if (split.effort) |tier| {
            const owned = try allocator.dupeZ(u8, tier);
            errdefer allocator.free(owned);
            try tiers.items[index].append(allocator, owned);
        }
    }
    if (models.items.len == 0) return error.AcpFailed;
    for (models.items, tiers.items) |*model, *list| {
        if (list.items.len == 0) continue;
        model.reasoning_supported = true;
        model.grok_effort_values = try list.toOwnedSlice(allocator);
    }
    return models.toOwnedSlice(allocator);
}

/// "Gemini 3.8 Flash (High)" -> "Gemini 3.8 Flash"; other names unchanged.
fn baseModelName(name: []const u8) []const u8 {
    const open = std.mem.lastIndexOf(u8, name, " (") orelse return name;
    if (!std.mem.endsWith(u8, name, ")")) return name;
    const inner = name[open + 2 .. name.len - 1];
    for ([_][]const u8{ "Low", "Medium", "High", "XHigh", "Extra High", "Max" }) |tier| {
        if (std.ascii.eqlIgnoreCase(inner, tier)) return name[0..open];
    }
    return name;
}

fn resolveAgyExecutableAlloc(
    allocator: std.mem.Allocator,
    env_map: *const std.process.Environ.Map,
    configured: []const u8,
) ![]u8 {
    const candidates = [_][]const u8{ configured, DEFAULT_EXECUTABLE };
    var tried: [2][]const u8 = .{ "", "" };
    var tried_len: usize = 0;
    for (candidates) |candidate| {
        if (candidate.len == 0) continue;
        var duplicate = false;
        for (tried[0..tried_len]) |old| {
            if (std.mem.eql(u8, old, candidate)) duplicate = true;
        }
        if (duplicate) continue;
        tried[tried_len] = candidate;
        tried_len += 1;
        return process_env.resolveExecutableInEnvMapAlloc(allocator, env_map, candidate) catch |err| switch (err) {
            error.FileNotFound, error.AccessDenied => continue,
            else => return err,
        };
    }

    if (env_map.get("HOME")) |home| {
        if (home.len > 0) {
            const fallback = try std.fs.path.join(allocator, &.{ home, INSTALL_FALLBACK_RELATIVE });
            defer allocator.free(fallback);
            if (process_env.resolveExecutableInEnvMapAlloc(allocator, env_map, fallback)) |resolved| {
                return resolved;
            } else |err| switch (err) {
                error.FileNotFound, error.AccessDenied => {},
                else => return err,
            }
        }
    }

    runtime_log.diagnostic("agy CLI not found; install it with `curl -fsSL https://antigravity.google/cli/install.sh | bash`, ensure `agy` is on PATH, then run `agy acp --login`.", .{});
    return error.FileNotFound;
}

test "parseAvailableModelsAlloc groups agy tiers under base models" {
    const payload =
        \\{"jsonrpc":"2.0","id":3,"result":{"sessionId":"s-1","models":{"availableModels":[
        \\{"modelId":"gemini-3.8-flash-high","name":"Gemini 3.8 Flash (High)"},
        \\{"modelId":"gemini-3.8-flash-medium","name":"Gemini 3.8 Flash (Medium)"},
        \\{"modelId":"gemini-3.8-flash-low","name":"Gemini 3.8 Flash (Low)"},
        \\{"modelId":"claude-sonnet-4-6","name":"Claude Sonnet 4.6 (Thinking)"}],
        \\"currentModelId":"gemini-3.8-flash-high"},"modes":{"currentModeId":"default","availableModes":[]}}}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, payload, .{});
    defer parsed.deinit();
    const models = try parseAvailableModelsAlloc(std.testing.allocator, parsed.value);
    defer provider_types.freeModelInfos(std.testing.allocator, models);
    try std.testing.expectEqual(@as(usize, 2), models.len);
    try std.testing.expectEqualStrings("antigravity", models[0].provider_id);
    try std.testing.expectEqualStrings("gemini-3.8-flash", models[0].model_id);
    try std.testing.expectEqualStrings("Gemini 3.8 Flash", models[0].model_name);
    try std.testing.expect(models[0].reasoning_supported);
    const tiers = models[0].grok_effort_values.?;
    try std.testing.expectEqual(@as(usize, 3), tiers.len);
    try std.testing.expectEqualStrings("high", tiers[0]);
    try std.testing.expectEqualStrings("low", tiers[2]);
    try std.testing.expectEqualStrings("claude-sonnet-4-6", models[1].model_id);
    try std.testing.expectEqualStrings("Claude Sonnet 4.6 (Thinking)", models[1].model_name);
    try std.testing.expect(!models[1].reasoning_supported);
    try std.testing.expectEqual(@as(?[][:0]const u8, null), models[1].grok_effort_values);

    var missing = try std.json.parseFromSlice(std.json.Value, std.testing.allocator,
        \\{"jsonrpc":"2.0","id":3,"result":{"sessionId":"s-1"}}
    , .{});
    defer missing.deinit();
    try std.testing.expectError(error.AcpFailed, parseAvailableModelsAlloc(std.testing.allocator, missing.value));
}

test "sessionModelSwitchAlloc resolves base model plus effort to a listed agy id" {
    const allocator = std.testing.allocator;
    const line =
        \\{"jsonrpc":"2.0","id":2,"result":{"sessionId":"s-1","models":{"availableModels":[
        \\{"modelId":"gemini-3.8-flash-high","name":"High"},{"modelId":"gemini-3.8-flash-low","name":"Low"},
        \\{"modelId":"claude-sonnet-4-6","name":"Claude"}],
        \\"currentModelId":"gemini-3.8-flash-high"}}}
    ;
    const Case = struct { model: ?[]const u8, effort: ?provider_types.ReasoningEffort, expected: ?[]const u8 };
    const cases = [_]Case{
        // Base model + effort -> the folded id.
        .{ .model = "gemini-3.8-flash", .effort = .low, .expected = "gemini-3.8-flash-low" },
        // Already running it.
        .{ .model = "gemini-3.8-flash", .effort = .high, .expected = null },
        // Base model without effort keeps the session's tier.
        .{ .model = "gemini-3.8-flash", .effort = null, .expected = null },
        // Effort only (default model) changes the current model's tier.
        .{ .model = null, .effort = .low, .expected = "gemini-3.8-flash-low" },
        // An unlisted tier keeps the session's current model.
        .{ .model = "gemini-3.8-flash", .effort = .medium, .expected = null },
        // Older exact refs still resolve.
        .{ .model = "gemini-3.8-flash-low", .effort = null, .expected = "gemini-3.8-flash-low" },
        // A model without tiers ignores the effort.
        .{ .model = "claude-sonnet-4-6", .effort = .high, .expected = "claude-sonnet-4-6" },
        .{ .model = "retired-model", .effort = null, .expected = null },
        .{ .model = null, .effort = null, .expected = null },
    };
    for (cases) |case| {
        const switched = try sessionModelSwitchAlloc(allocator, line, case.model, case.effort);
        defer if (switched) |id| allocator.free(id);
        if (case.expected) |expected| {
            try std.testing.expectEqualStrings(expected, switched.?);
        } else {
            try std.testing.expectEqual(@as(?[]u8, null), switched);
        }
    }
    try std.testing.expectEqual(@as(?[]u8, null), try sessionModelSwitchAlloc(allocator, "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}", "gemini-3.8-flash", .low));
    try std.testing.expectEqual(@as(?[]const u8, null), requestedModel("default"));
    try std.testing.expectEqualStrings("gemini-3.8-flash", requestedModel("gemini-3.8-flash").?);
}

test "account eligibility notices become a readable error" {
    const raw = "\n⚠ You do not have a valid license of this product. Please contact your administrator to request a license. (#3501)\n";
    try std.testing.expectEqualStrings(ACCOUNT_INELIGIBLE_MESSAGE, antigravityAgentErrorMessage(raw).?);
    try std.testing.expectEqual(@as(?[]const u8, null), antigravityAgentErrorMessage("Here is the license file you asked about."));
}

test "modelSwitchResponse recognizes only the set_model reply" {
    const allocator = std.testing.allocator;
    try std.testing.expectEqual(@as(?bool, true), try modelSwitchResponse(allocator, "{\"jsonrpc\":\"2.0\",\"result\":{},\"id\":12}"));
    try std.testing.expectEqual(@as(?bool, false), try modelSwitchResponse(allocator, "{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32602,\"message\":\"unknown model\"},\"id\":12}"));
    try std.testing.expectEqual(@as(?bool, null), try modelSwitchResponse(allocator, "{\"jsonrpc\":\"2.0\",\"result\":{},\"id\":3}"));
    try std.testing.expectEqual(@as(?bool, null), try modelSwitchResponse(allocator, "{\"jsonrpc\":\"2.0\",\"method\":\"session/request_permission\",\"id\":12,\"params\":{}}"));
    try std.testing.expectEqual(@as(?bool, null), try modelSwitchResponse(allocator, "{\"jsonrpc\":\"2.0\",\"method\":\"session/update\",\"params\":{}}"));
}
