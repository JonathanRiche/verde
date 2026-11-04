//! FX provider harness backed by the fx CLI ACP server (`fx acp`).
//! Generic ACP transport/protocol machinery lives in `acp.zig`; this module
//! owns fx binary discovery, argv construction, fx's handshake-based
//! auth/model discovery, and fx's ACP extensions (0.0.16):
//! - `configOptions` carry per-model `effort` (reasoning) and `fast` selects,
//!   set per session with `session/set_config_option`. Model discovery reads
//!   them from ACP rather than `fx models --json`, which prints the whole
//!   gateway catalog with exit 0 when signed out and omits Codex/Grok tiers.
//! - `_meta.fx.steering` in initialize: a `session/prompt` with
//!   `_meta.fx.steer` joins the running turn at its next safe boundary.
//! Permission modes are deliberately left alone: fx persists `session/set_mode`
//! into its global settings, so switching them would change the user's CLI.

const std = @import("std");
const acp = @import("acp.zig");
const platform_process = @import("../platform/process.zig");
const provider_mcp = @import("mcp.zig");
const process_env = @import("../platform/env.zig");
const provider_types = @import("types.zig");
const runtime_log = @import("../runtime/log.zig");

const DEFAULT_EXECUTABLE = "fx";
// The fx installer (`curl -fsSL https://fx.sh/setup.sh | bash`) places the
// binary here, which desktop launch environments often lack on PATH.
const INSTALL_FALLBACK_RELATIVE = ".local/bin/fx";

/// Auth probes spawn the full ACP agent; a wedged handshake must end before
/// the next readiness poll instead of piling up.
const AUTH_PROBE_DEADLINE_MS: u64 = 10_000;

/// Request ids outside the shared 1/2/3 sequence (initialize, session setup,
/// prompt), so fx-only replies never reach the shared turn handler.
const SET_EFFORT_REQUEST_ID: i64 = 10;
const SET_FAST_REQUEST_ID: i64 = 11;
/// Model discovery switches its throwaway session through each catalog model.
const MODEL_PROBE_REQUEST_ID_BASE: i64 = 100;
const MAX_PROBED_MODELS: usize = 512;
/// Steering prompts count up from here; fx answers each when its turn ends.
const STEER_REQUEST_ID_BASE: i64 = 1_000_000;

const ACP_HARNESS: acp.Harness = .{
    .diagnostics_category = .fx_acp,
    .assistant_author = "FX",
    .permission_default_title = "FX permission request",
    // fx prefixes its first chunk with skill-loader diagnostics that would
    // otherwise be committed as the start of the assistant reply.
    .diagnostic_chunk_prefix = "skill discovery warning:",
    .diagnostic_event_title = "FX warning",
};

var active_process_state: acp.ActiveProcessState = .{};

/// Steering bookkeeping for the registered turn, guarded by
/// `active_process_state`'s mutex. `child` scopes it to one fx process so a
/// newer turn's steers never hold an older turn open.
const SteerState = struct {
    child: ?*platform_process.OwnedChild = null,
    supported: bool = false,
    next_id: i64 = STEER_REQUEST_ID_BASE,
    /// Steering prompts written but not yet answered. fx answers each when
    /// the turn that absorbed it ends, or runs it as the next turn when it
    /// arrived after the turn stopped taking input, so the reader stays
    /// attached until all of them settle.
    pending: u32 = 0,
};
var steer_state: SteerState = .{};

pub fn providerSlashCommands() []const provider_types.ProviderSlashCommand {
    return &.{};
}

pub const Config = struct {
    executable: []const u8 = DEFAULT_EXECUTABLE,
    cwd: ?[]const u8 = null,
    // fx persists its own model selection per session; null defers to it.
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

    pub fn runSlashCommand(
        self: *Client,
        allocator: std.mem.Allocator,
        request: provider_types.RunSlashCommandRequest,
    ) !provider_types.RunSlashCommandResult {
        _ = self;
        _ = allocator;
        _ = request;
        return error.UnsupportedOperation;
    }

    // fx has no status subcommand; ACP initialize is the auth probe. It fails
    // with a "Run fx login ..." JSON-RPC error when no usable Vercel AI
    // Gateway credential exists, which the shared layer maps to AcpSignedOut.
    pub fn authState(self: *Client) !provider_types.AuthState {
        var proc = self.spawnAcp(self.allocator, null) catch |err| switch (err) {
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

    /// Writes a `_meta.fx.steer` prompt into the running turn. fx defers its
    /// reply until that turn ends, so delivery is confirmed by the write
    /// alone. `SteerNotDelivered` (no steerable turn, images) lets callers
    /// queue the message as the next turn instead.
    pub fn steerThread(self: *Client, request: provider_types.SteerThreadRequest) !void {
        _ = self;
        // fx steering takes text blocks only; images wait for the next turn.
        if (request.images.len > 0) return error.SteerNotDelivered;
        if (std.mem.trim(u8, request.prompt, &std.ascii.whitespace).len == 0) return error.SteerNotDelivered;

        active_process_state.lock();
        defer active_process_state.unlock();
        const child = active_process_state.child orelse return error.SteerNotDelivered;
        const session_id = active_process_state.session_id orelse return error.SteerNotDelivered;
        const stdin = active_process_state.stdin orelse return error.SteerNotDelivered;
        if (!std.mem.eql(u8, session_id, request.thread_id)) return error.SteerNotDelivered;
        if (steer_state.child != child or !steer_state.supported) return error.SteerNotDelivered;

        const line = try makeSteerPromptRequestAlloc(std.heap.page_allocator, steer_state.next_id, session_id, request.prompt);
        defer std.heap.page_allocator.free(line);
        try acp.writeJsonLineToFile(std.heap.page_allocator, stdin, line);
        steer_state.next_id += 1;
        steer_state.pending += 1;
    }

    fn listThreadsAcp(self: *Client, allocator: std.mem.Allocator) ![]provider_types.ChatThreadSummary {
        var proc = try self.spawnAcp(allocator, null);
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

    // fx publishes its model catalog only in the `configOptions` of a
    // session response, and each model's reasoning tiers and Fast lane only
    // once that model is selected. A fresh session is free to probe: fx does
    // not save a session until its first prompt, so switching the throwaway
    // session through every model touches no saved session or setting.
    fn listModelsAcp(self: *Client, allocator: std.mem.Allocator) ![]provider_types.ModelInfo {
        var proc = try self.spawnAcp(allocator, null);
        defer proc.deinit();

        const cwd = try self.cwdAbsoluteAlloc(allocator);
        defer allocator.free(cwd);

        try proc.writeLine(try acp.makeInitializeRequestAlloc(allocator, 1));
        try proc.writeLine(try acp.makeSessionNewRequestAlloc(allocator, 2, cwd, null));

        var models: []provider_types.ModelInfo = &.{};
        errdefer provider_types.freeModelInfos(allocator, models);
        var probe_count: usize = 0;
        var probed: usize = 0;

        var read_buffer: [16 * 1024]u8 = undefined;
        var reader = proc.process.child.stdout.?.reader(proc.threaded.io(), &read_buffer);
        while (try acp.takeLineAlloc(allocator, &reader)) |raw_line| {
            defer allocator.free(raw_line);
            const line = std.mem.trim(u8, raw_line, " \t\r");
            if (line.len == 0) continue;
            var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
            defer parsed.deinit();
            const id = acp.responseId(parsed.value) orelse continue;
            if (id == 1) {
                try acp.failIfJsonRpcError(ACP_HARNESS, parsed.value);
                continue;
            }
            if (id == 2) {
                try acp.failIfJsonRpcError(ACP_HARNESS, parsed.value);
                models = try parseModelConfigOptionsAlloc(allocator, parsed.value);
                const session_id = acp.parseSessionId(parsed.value) orelse break;
                probe_count = @min(models.len, MAX_PROBED_MODELS);
                for (models[0..probe_count], 0..) |model, index| {
                    const probe_id = MODEL_PROBE_REQUEST_ID_BASE + @as(i64, @intCast(index));
                    try proc.writeLine(try acp.makeSetConfigOptionRequestAlloc(allocator, probe_id, session_id, "model", model.model_id));
                }
                try proc.closeStdin();
                if (probe_count == 0) break;
                continue;
            }
            if (id < MODEL_PROBE_REQUEST_ID_BASE) continue;
            const index: usize = @intCast(id - MODEL_PROBE_REQUEST_ID_BASE);
            if (index >= probe_count) continue;
            // A model fx refuses to select (missing provider login) keeps the
            // defaults: no reasoning tiers, no Fast toggle.
            if (acp.getObjectField(parsed.value, "error") == null) {
                try applySessionOptions(allocator, &models[index], parseSessionOptions(parsed.value));
            }
            probed += 1;
            if (probed == probe_count) break;
        }
        proc.stop();
        if (models.len == 0) return error.AcpFailed;
        return models;
    }

    fn readThreadAcp(
        self: *Client,
        allocator: std.mem.Allocator,
        thread_id: []const u8,
    ) !provider_types.ReadThreadResult {
        var proc = try self.spawnAcp(allocator, null);
        defer proc.deinit();

        const cwd = try self.cwdAbsoluteAlloc(allocator);
        defer allocator.free(cwd);
        var mcp_connection = if (provider_mcp.isInstalled(allocator, .fx))
            try provider_mcp.loadHttpConnection(allocator)
        else
            null;
        defer if (mcp_connection) |*connection| connection.deinit(allocator);
        const mcp_http: ?acp.McpHttpServer = if (mcp_connection) |connection| .{
            .url = connection.url,
            .authorization = connection.authorization,
            .client_name = "fx",
        } else null;

        var state: acp.ReadThreadState = .{};
        errdefer state.deinit(allocator);

        try proc.writeLine(try acp.makeInitializeRequestAlloc(allocator, 1));
        try proc.writeLine(try acp.makeSessionLoadRequestWithHttpMcpAlloc(allocator, 2, thread_id, cwd, mcp_http));
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
        // `fx acp --model <id>` overrides the session's stored model for this
        // process; effort and Fast are session config options applied once
        // the session is ready. "default" is Verde's sentinel for deferring
        // to fx's own persisted model selection.
        const requested_model = request.model orelse self.config.model;
        const model_arg = if (requested_model) |model|
            (if (std.mem.eql(u8, model, "default")) null else model)
        else
            null;

        var proc = try self.spawnAcp(allocator, model_arg);
        defer proc.deinit();

        const cwd = try self.cwdAbsoluteAllocForRequest(allocator, request);
        defer allocator.free(cwd);
        var mcp_connection = if (provider_mcp.isInstalled(allocator, .fx))
            try provider_mcp.loadHttpConnection(allocator)
        else
            null;
        defer if (mcp_connection) |*connection| connection.deinit(allocator);
        const mcp_http: ?acp.McpHttpServer = if (mcp_connection) |connection| .{
            .url = connection.url,
            .authorization = connection.authorization,
            .client_name = "fx",
        } else null;

        var state: acp.SendPromptState = .{};
        errdefer state.deinit(allocator);
        var session_options: SessionOptions = .{};
        var awaiting_steers = false;

        try proc.writeLine(try acp.makeInitializeRequestAlloc(allocator, 1));

        var read_buffer: [16 * 1024]u8 = undefined;
        var reader = proc.process.child.stdout.?.reader(proc.threaded.io(), &read_buffer);
        while (try acp.takeLineAlloc(allocator, &reader)) |raw_line| {
            defer allocator.free(raw_line);
            const line = std.mem.trim(u8, raw_line, " \t\r");
            if (line.len == 0) continue;
            switch (try interceptFxResponse(allocator, line, request, &session_options, &proc.process, awaiting_steers)) {
                .forward => {},
                .consumed => continue,
                .turn_finished => break,
            }
            const action = try acp.handleSendPromptLine(allocator, ACP_HARNESS, line, request, &state, proc.process.child.stdin);
            switch (action) {
                .continue_reading => {},
                .initialized => try proc.writeLine(try acp.makeTurnSessionRequestAlloc(allocator, 2, state.capabilities, .{
                    .cwd = cwd,
                    .session_id = request.thread_id,
                    .mcp_http = mcp_http,
                    .meta = writeSessionMeta,
                })),
                .session_ready => {
                    if (state.session_id) |session_id| {
                        active_process_state.lock();
                        steer_state = .{ .child = &proc.process, .supported = session_options.steering };
                        active_process_state.unlock();
                        active_process_state.register(&proc.process, proc.process.child.stdin, session_id);
                        if (request.on_thread_id) |on_thread_id| on_thread_id(request.stream_context, session_id);
                        if (request.on_turn_id) |on_turn_id| on_turn_id(request.stream_context, session_id);
                        // fx handles requests in order, so these settle
                        // before the prompt starts.
                        try writeTurnSettings(allocator, &proc, session_id, request, session_options);
                        try proc.writeLine(try acp.makePromptRequestAlloc(allocator, 3, session_id, request, state.capabilities.image));
                        state.prompt_submitted = true;
                    }
                },
                .prompt_done => {
                    if (finishTurnUnlessSteering(&proc.process)) break;
                    // fx answers absorbed steers just after the prompt reply,
                    // and runs one that missed this turn's input as the next
                    // turn; keep streaming into this reply until all settle.
                    awaiting_steers = true;
                },
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

    fn spawnAcp(self: *Client, allocator: std.mem.Allocator, model_arg: ?[]const u8) !acp.Process {
        var env_map = try process_env.buildAugmentedEnvMap(allocator);
        errdefer env_map.deinit();
        const executable = try resolveFxExecutableAlloc(allocator, &env_map, self.config.executable);
        errdefer allocator.free(executable);

        var threaded: std.Io.Threaded = .init(allocator, .{});
        errdefer threaded.deinit();
        const argv_with_model = [_][]const u8{ executable, "acp", "--model", model_arg orelse "" };
        const argv_default = [_][]const u8{ executable, "acp" };
        var child = try platform_process.spawn(allocator, threaded.io(), .{
            .argv = if (model_arg != null) argv_with_model[0..] else argv_default[0..],
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

// fx v0.0.13+ ignores the user's own `~/.fx/mcp.json` servers over ACP unless
// the client opts in; Verde passes its own server separately, so opt in to
// keep the user's servers available in GUI threads too.
fn writeSessionMeta(stringify: *std.json.Stringify) std.json.Stringify.Error!void {
    try stringify.write(.{ .fx = .{ .profileMcpServers = true } });
}

/// The fx `configOptions` that shape a turn, read from a session response
/// or a `session/set_config_option` reply (both carry the full list).
const SessionOptions = struct {
    /// `_meta.fx.steering` from initialize, not a config option.
    steering: bool = false,
    /// Verde-named tiers the active model offers; fx's `auto` (model default)
    /// and `ultra` have no Verde equivalent and are skipped.
    efforts: std.EnumSet(provider_types.ReasoningEffort) = .initEmpty(),
    current_effort: ?provider_types.ReasoningEffort = null,
    fast_available: bool = false,
    fast_on: bool = false,
};

fn parseSessionOptions(value: std.json.Value) SessionOptions {
    var options: SessionOptions = .{};
    const result = acp.getObjectField(value, "result") orelse return options;
    const config_options = acp.getObjectField(result, "configOptions") orelse return options;
    if (config_options != .array) return options;
    for (config_options.array.items) |option| {
        if (option != .object) continue;
        const option_id = acp.getOptionalObjectString(option, "id") orelse continue;
        const current = acp.getOptionalObjectString(option, "currentValue");
        if (std.mem.eql(u8, option_id, "effort")) {
            const entries = acp.getObjectField(option, "options") orelse continue;
            if (entries != .array) continue;
            for (entries.array.items) |entry| {
                const tier = acp.getOptionalObjectString(entry, "value") orelse continue;
                if (std.meta.stringToEnum(provider_types.ReasoningEffort, tier)) |effort| options.efforts.insert(effort);
            }
            if (current) |tier| options.current_effort = std.meta.stringToEnum(provider_types.ReasoningEffort, tier);
        } else if (std.mem.eql(u8, option_id, "fast")) {
            options.fast_available = true;
            options.fast_on = if (current) |flag| std.mem.eql(u8, flag, "true") else false;
        }
    }
    return options;
}

/// Records a probed model's tiers in the shared per-model effort field and
/// its Fast lane in the shared fast flag.
fn applySessionOptions(allocator: std.mem.Allocator, model: *provider_types.ModelInfo, options: SessionOptions) !void {
    model.cursor_fast_supported = options.fast_available;
    model.reasoning_supported = options.efforts.count() > 0;
    if (!model.reasoning_supported) return;
    var values: std.ArrayList([:0]const u8) = .empty;
    errdefer {
        for (values.items) |value| allocator.free(value);
        values.deinit(allocator);
    }
    var iterator = options.efforts.iterator();
    while (iterator.next()) |effort| try values.append(allocator, try allocator.dupeZ(u8, @tagName(effort)));
    model.grok_effort_values = try values.toOwnedSlice(allocator);
}

/// Applies Verde's effort and Fast choices to the session before the prompt.
/// fx keeps both per session, so Fast is written whenever it differs (Verde's
/// toggle is authoritative) while a "Default" effort leaves fx's tier alone.
/// Tiers the model does not offer are skipped rather than failing the turn.
fn writeTurnSettings(
    allocator: std.mem.Allocator,
    proc: *acp.Process,
    session_id: []const u8,
    request: provider_types.SendPromptRequest,
    options: SessionOptions,
) !void {
    if (request.reasoning_effort) |effort| {
        const already_set = if (options.current_effort) |current| current == effort else false;
        if (options.efforts.contains(effort) and !already_set) {
            try proc.writeLine(try acp.makeSetConfigOptionRequestAlloc(allocator, SET_EFFORT_REQUEST_ID, session_id, "effort", @tagName(effort)));
        }
    }
    if (options.fast_available) {
        const want_fast = if (request.service_tier) |tier| tier == .fast else false;
        if (want_fast != options.fast_on) {
            try proc.writeLine(try acp.makeSetConfigOptionRequestAlloc(allocator, SET_FAST_REQUEST_ID, session_id, "fast", if (want_fast) "true" else "false"));
        }
    }
}

const Intercept = enum { forward, consumed, turn_finished };

/// Reads fx-specific response details before the shared handler sees the
/// line, and keeps replies to fx-only requests (settings, steering) away from
/// it: the shared handler fails the turn on any JSON-RPC error.
fn interceptFxResponse(
    allocator: std.mem.Allocator,
    line: []const u8,
    request: provider_types.SendPromptRequest,
    options: *SessionOptions,
    child: *platform_process.OwnedChild,
    awaiting_steers: bool,
) !Intercept {
    // Requests and notifications carry an unescaped "method" key; responses
    // never do, so streaming updates skip the extra parse.
    if (std.mem.indexOf(u8, line, "\"method\"") != null) return .forward;
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch return .forward;
    defer parsed.deinit();
    const id = acp.responseId(parsed.value) orelse return .forward;
    const failed = acp.getObjectField(parsed.value, "error") != null;
    switch (id) {
        1 => {
            if (!failed) options.steering = initializeAdvertisesSteering(parsed.value);
            return .forward;
        },
        2 => {
            if (!failed) {
                const steering = options.steering;
                options.* = parseSessionOptions(parsed.value);
                options.steering = steering;
            }
            return .forward;
        },
        SET_EFFORT_REQUEST_ID, SET_FAST_REQUEST_ID => {
            if (failed) emitRejection(request, if (id == SET_EFFORT_REQUEST_ID) "FX reasoning effort not applied" else "FX Fast mode not applied", parsed.value);
            return .consumed;
        },
        else => {},
    }
    if (id < STEER_REQUEST_ID_BASE) return .forward;
    if (failed) emitRejection(request, "FX steering failed", parsed.value);
    active_process_state.lock();
    defer active_process_state.unlock();
    if (steer_state.child != child) return if (awaiting_steers) .turn_finished else .consumed;
    steer_state.pending -|= 1;
    if (!awaiting_steers or steer_state.pending > 0) return .consumed;
    clearRegistrationLocked(child);
    return .turn_finished;
}

/// True (and the turn is no longer steerable) when no steering reply is
/// outstanding. Deciding and unregistering under one lock keeps a steer from
/// landing between the last reply and the process shutting down.
fn finishTurnUnlessSteering(child: *platform_process.OwnedChild) bool {
    active_process_state.lock();
    defer active_process_state.unlock();
    if (steer_state.child == child and steer_state.pending > 0) return false;
    clearRegistrationLocked(child);
    return true;
}

fn clearRegistrationLocked(child: *platform_process.OwnedChild) void {
    if (steer_state.child == child) steer_state = .{};
    if (active_process_state.child == child) {
        active_process_state.child = null;
        active_process_state.stdin = null;
        active_process_state.session_id = null;
    }
}

fn initializeAdvertisesSteering(value: std.json.Value) bool {
    const result = acp.getObjectField(value, "result") orelse return false;
    const agent = acp.getObjectField(result, "agentCapabilities") orelse return false;
    const meta = acp.getObjectField(agent, "_meta") orelse return false;
    const fx_meta = acp.getObjectField(meta, "fx") orelse return false;
    return acp.getOptionalObjectBool(fx_meta, "steering") orelse false;
}

fn emitRejection(request: provider_types.SendPromptRequest, title: []const u8, value: std.json.Value) void {
    const on_stream_event = request.on_stream_event orelse return;
    const error_value = acp.getObjectField(value, "error") orelse return;
    const message = acp.getOptionalObjectString(error_value, "message") orelse "fx rejected the request.";
    on_stream_event(request.stream_context, .{ .message = .{ .title = title, .body = message } });
}

/// fx's steering extension: a `session/prompt` flagged `_meta.fx.steer`
/// joins the running turn instead of failing with "Prompt already in progress".
fn makeSteerPromptRequestAlloc(allocator: std.mem.Allocator, id: i64, session_id: []const u8, text: []const u8) ![]u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    var stringify: std.json.Stringify = .{ .writer = &writer.writer, .options = .{} };
    try stringify.write(.{
        .jsonrpc = "2.0",
        .id = id,
        .method = "session/prompt",
        .params = .{
            .sessionId = session_id,
            .prompt = .{.{ .type = "text", .text = text }},
            ._meta = .{ .fx = .{ .steer = true } },
        },
    });
    return writer.toOwnedSlice();
}

pub fn shutdownOwnedServer() void {
    active_process_state.lock();
    defer active_process_state.unlock();
    if (active_process_state.child) |child| child.terminateTree();
}

/// Maps provider-neutral ACP errors to FX error names so user-facing error
/// messaging can address fx specifically (e.g. suggest `fx login`).
fn mapAcpError(err: anyerror) anyerror {
    return switch (err) {
        error.AcpFailed => error.FxAcpFailed,
        error.AcpRefused => error.FxAcpRefused,
        error.AcpSignedOut => error.FxSignedOut,
        error.AcpMessageTooLarge => error.FxAcpMessageTooLarge,
        error.AcpAttachmentsUnsupported => error.FxAttachmentsUnsupported,
        else => err,
    };
}

// Parses the `configOptions` model select from a session/new or session/load
// response: {"id":"model","type":"select","currentValue":..,"options":[{value,name}]}.
fn parseModelConfigOptionsAlloc(allocator: std.mem.Allocator, value: std.json.Value) ![]provider_types.ModelInfo {
    var models: std.ArrayList(provider_types.ModelInfo) = .empty;
    errdefer {
        for (models.items) |model| model.deinit(allocator);
        models.deinit(allocator);
    }

    const result = acp.getObjectField(value, "result") orelse return error.AcpFailed;
    const config_options = acp.getObjectField(result, "configOptions") orelse return error.AcpFailed;
    if (config_options != .array) return error.AcpFailed;
    for (config_options.array.items) |option| {
        if (option != .object) continue;
        const option_id = acp.getOptionalObjectString(option, "id") orelse continue;
        if (!std.mem.eql(u8, option_id, "model")) continue;
        const entries = acp.getObjectField(option, "options") orelse continue;
        if (entries != .array) continue;
        for (entries.array.items) |entry| {
            if (entry != .object) continue;
            const id = acp.getOptionalObjectString(entry, "value") orelse continue;
            const name = acp.getOptionalObjectString(entry, "name") orelse id;
            try models.append(allocator, .{
                .provider_id = try allocator.dupe(u8, "fx"),
                .provider_name = try allocator.dupe(u8, "FX"),
                .model_id = try allocator.dupe(u8, id),
                .model_name = try allocator.dupe(u8, name),
            });
        }
    }
    if (models.items.len == 0) return error.AcpFailed;
    return models.toOwnedSlice(allocator);
}

fn resolveFxExecutableAlloc(
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

    runtime_log.diagnostic("fx CLI not found; install it with `curl -fsSL https://fx.sh/setup.sh | bash`, ensure `fx` is on PATH, then run `fx login`.", .{});
    return error.FileNotFound;
}

test "parseModelConfigOptionsAlloc reads fx configOptions model select" {
    const payload =
        \\{"jsonrpc":"2.0","id":3,"result":{"sessionId":"s-1","configOptions":[
        \\{"id":"provider","name":"Provider","category":"provider","type":"select","currentValue":"gateway","options":[{"value":"gateway","name":"gateway"}]},
        \\{"id":"model","name":"Model","category":"model","type":"select","currentValue":"anthropic/claude-sonnet-4.5","options":[
        \\{"value":"anthropic/claude-sonnet-4.5","name":"anthropic/claude-sonnet-4.5"},
        \\{"value":"openai/gpt-5.2","name":"openai/gpt-5.2"}]},
        \\{"id":"mode","name":"Mode","category":"mode","type":"select","currentValue":"code","options":[{"value":"ask","name":"Ask"},{"value":"code","name":"Code"}]}
        \\],"modes":{"currentModeId":"code","availableModes":[]}}}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, payload, .{});
    defer parsed.deinit();
    const models = try parseModelConfigOptionsAlloc(std.testing.allocator, parsed.value);
    defer provider_types.freeModelInfos(std.testing.allocator, models);
    try std.testing.expectEqual(@as(usize, 2), models.len);
    try std.testing.expectEqualStrings("fx", models[0].provider_id);
    try std.testing.expectEqualStrings("FX", models[0].provider_name);
    try std.testing.expectEqualStrings("anthropic/claude-sonnet-4.5", models[0].model_id);
    try std.testing.expectEqualStrings("openai/gpt-5.2", models[1].model_id);

    var missing = try std.json.parseFromSlice(std.json.Value, std.testing.allocator,
        \\{"jsonrpc":"2.0","id":3,"result":{"sessionId":"s-1","configOptions":[]}}
    , .{});
    defer missing.deinit();
    try std.testing.expectError(error.AcpFailed, parseModelConfigOptionsAlloc(std.testing.allocator, missing.value));
}

test "parseSessionOptions maps fx effort tiers and the fast select" {
    const payload =
        \\{"jsonrpc":"2.0","id":2,"result":{"sessionId":"s-1","configOptions":[
        \\{"id":"model","type":"select","currentValue":"gpt-6.1-sol","options":[{"value":"gpt-6.1-sol","name":"gpt-6.1-sol"}]},
        \\{"id":"effort","category":"thought_level","type":"select","currentValue":"high","options":[
        \\{"value":"auto","name":"default"},{"value":"low","name":"low"},{"value":"high","name":"high"},
        \\{"value":"max","name":"max"},{"value":"ultra","name":"ultra"}]},
        \\{"id":"fast","category":"model","type":"select","currentValue":"true","options":[{"value":"false","name":"off"},{"value":"true","name":"on"}]}
        \\]}}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, payload, .{});
    defer parsed.deinit();
    const options = parseSessionOptions(parsed.value);
    try std.testing.expect(options.efforts.contains(.low));
    try std.testing.expect(options.efforts.contains(.high));
    try std.testing.expect(options.efforts.contains(.max));
    try std.testing.expect(!options.efforts.contains(.medium));
    try std.testing.expectEqual(@as(usize, 3), options.efforts.count());
    try std.testing.expectEqual(@as(?provider_types.ReasoningEffort, .high), options.current_effort);
    try std.testing.expect(options.fast_available);
    try std.testing.expect(options.fast_on);

    var model: provider_types.ModelInfo = .{
        .provider_id = try std.testing.allocator.dupe(u8, "fx"),
        .provider_name = try std.testing.allocator.dupe(u8, "FX"),
        .model_id = try std.testing.allocator.dupe(u8, "gpt-6.1-sol"),
        .model_name = try std.testing.allocator.dupe(u8, "gpt-6.1-sol"),
    };
    defer model.deinit(std.testing.allocator);
    try applySessionOptions(std.testing.allocator, &model, options);
    try std.testing.expect(model.reasoning_supported);
    try std.testing.expect(model.cursor_fast_supported);
    const tiers = model.grok_effort_values.?;
    try std.testing.expectEqual(@as(usize, 3), tiers.len);
    try std.testing.expectEqualStrings("low", tiers[0]);
    try std.testing.expectEqualStrings("high", tiers[1]);
    try std.testing.expectEqualStrings("max", tiers[2]);

    // A model without an effort select reports no reasoning control.
    var bare = try std.json.parseFromSlice(std.json.Value, std.testing.allocator,
        \\{"jsonrpc":"2.0","id":101,"result":{"configOptions":[{"id":"model","type":"select","currentValue":"m","options":[]}]}}
    , .{});
    defer bare.deinit();
    const bare_options = parseSessionOptions(bare.value);
    try std.testing.expectEqual(@as(usize, 0), bare_options.efforts.count());
    try std.testing.expect(!bare_options.fast_available);
}

test "steering prompts carry the fx steer flag and text only" {
    const line = try makeSteerPromptRequestAlloc(std.testing.allocator, STEER_REQUEST_ID_BASE, "s-1", "use tabs");
    defer std.testing.allocator.free(line);
    try std.testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":1000000,\"method\":\"session/prompt\",\"params\":{\"sessionId\":\"s-1\",\"prompt\":[{\"type\":\"text\",\"text\":\"use tabs\"}],\"_meta\":{\"fx\":{\"steer\":true}}}}",
        line,
    );

    var init = try std.json.parseFromSlice(std.json.Value, std.testing.allocator,
        \\{"jsonrpc":"2.0","id":1,"result":{"agentCapabilities":{"loadSession":true,"_meta":{"fx":{"steering":true}}}}}
    , .{});
    defer init.deinit();
    try std.testing.expect(initializeAdvertisesSteering(init.value));
    var old = try std.json.parseFromSlice(std.json.Value, std.testing.allocator,
        \\{"jsonrpc":"2.0","id":1,"result":{"agentCapabilities":{"loadSession":true}}}
    , .{});
    defer old.deinit();
    try std.testing.expect(!initializeAdvertisesSteering(old.value));
}

test "fx-only replies stay away from the shared handler and steering holds the turn open" {
    var child: platform_process.OwnedChild = undefined;
    const request: provider_types.SendPromptRequest = .{ .prompt = "hi" };
    var options: SessionOptions = .{};
    defer {
        active_process_state.lock();
        clearRegistrationLocked(&child);
        active_process_state.unlock();
    }

    // initialize records steering support and still reaches the shared handler.
    try std.testing.expectEqual(Intercept.forward, try interceptFxResponse(std.testing.allocator,
        \\{"jsonrpc":"2.0","id":1,"result":{"agentCapabilities":{"_meta":{"fx":{"steering":true}}}}}
    , request, &options, &child, false));
    try std.testing.expect(options.steering);
    // A rejected setting is consumed, so it cannot fail the turn.
    try std.testing.expectEqual(Intercept.consumed, try interceptFxResponse(std.testing.allocator,
        \\{"jsonrpc":"2.0","id":10,"error":{"code":-32602,"message":"Reasoning effort is not available for the active model"}}
    , request, &options, &child, false));
    // Notifications skip the pre-parse.
    try std.testing.expectEqual(Intercept.forward, try interceptFxResponse(std.testing.allocator,
        \\{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s","update":{"sessionUpdate":"agent_message_chunk"}}}
    , request, &options, &child, false));

    active_process_state.lock();
    steer_state = .{ .child = &child, .supported = true, .pending = 2 };
    active_process_state.unlock();
    try std.testing.expect(!finishTurnUnlessSteering(&child));
    // First steer reply while the prompt is still running: consumed.
    try std.testing.expectEqual(Intercept.consumed, try interceptFxResponse(std.testing.allocator,
        \\{"jsonrpc":"2.0","id":1000000,"result":{"stopReason":"end_turn"}}
    , request, &options, &child, false));
    // Last steer reply after the prompt finished ends the turn.
    try std.testing.expectEqual(Intercept.turn_finished, try interceptFxResponse(std.testing.allocator,
        \\{"jsonrpc":"2.0","id":1000001,"result":{"stopReason":"end_turn"}}
    , request, &options, &child, true));
    try std.testing.expectEqual(@as(?*platform_process.OwnedChild, null), steer_state.child);
    try std.testing.expect(finishTurnUnlessSteering(&child));
}
