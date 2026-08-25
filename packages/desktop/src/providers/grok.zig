//! Grok provider harness backed by the Grok Build CLI ACP server
//! (`grok agent stdio`). Generic ACP transport/protocol machinery lives in
//! `acp.zig`; this module owns grok binary discovery, argv construction, the
//! explicit `authenticate` handshake grok requires before any session
//! request, and grok's model catalog, which it publishes in the initialize
//! response (`_meta.modelState`) rather than through ACP `configOptions`.

const std = @import("std");
const acp = @import("acp.zig");
const platform_process = @import("../platform/process.zig");
const process_env = @import("../platform/env.zig");
const provider_types = @import("types.zig");
const runtime_log = @import("../runtime/log.zig");

const DEFAULT_EXECUTABLE = "grok";
// The Grok Build installer places the binary here, which desktop launch
// environments often lack on PATH.
const INSTALL_FALLBACK_RELATIVE = ".grok/bin/grok";
// grok answers session/new and session/load with AuthorizationRequired until
// the client authenticates explicitly. The cached credential written by
// `grok login` (or XAI_API_KEY) is the only non-interactive method.
const AUTH_METHOD_ID = "cached_token";
/// grok 1.0.x advertises `promptCapabilities.image: false` yet its session
/// turn parses standard ACP `image` blocks and feeds them to the model
/// (verified live: a 512px block is described correctly; images under
/// grok's 512-pixel vision floor are dropped server-side without error).
/// Trust the observed behavior over the flag so screenshots reach Grok.
const GROK_ACCEPTS_IMAGES = true;
// Request ids outside the shared handlers' 1/2/3 sequence so their responses
// pass through `acp.handle*Line` untouched.
const AUTHENTICATE_REQUEST_ID: i64 = 10;
const SET_MODEL_REQUEST_ID: i64 = 11;

const ACP_HARNESS: acp.Harness = .{
    .diagnostics_category = .grok_acp,
    .assistant_author = "Grok",
    .permission_default_title = "Grok permission request",
};

var active_process_state: acp.ActiveProcessState = .{};

// grok resolves `/name args` prompt text itself and streams the outcome as a
// normal turn, so this list only seeds the picker with its built-in commands
// (captured from `available_commands_update`); any other advertised command or
// skill still reaches grok through the unknown-command path in state.zig.
const GROK_SLASH_COMMANDS = [_]provider_types.ProviderSlashCommand{
    .{
        .id = .compact,
        .name = "/compact",
        .summary = "Compress the Grok conversation history to save context window.",
        .usage = "/compact [what to preserve]",
        .requires_thread = true,
    },
    .{
        .id = .custom,
        .name = "/context",
        .summary = "Show Grok context window usage and session stats.",
        .usage = "/context",
        .requires_thread = true,
    },
    .{
        .id = .custom,
        .name = "/session-info",
        .summary = "Show Grok session details (model, turns, context usage).",
        .usage = "/session-info",
        .requires_thread = true,
    },
    .{
        .id = .custom,
        .name = "/always-approve",
        .summary = "Toggle Grok always-approve mode (skip permission prompts).",
        .usage = "/always-approve on|off",
        .requires_thread = true,
        .destructive_or_sensitive = true,
    },
    .{
        .id = .custom,
        .name = "/feedback",
        .summary = "Send feedback about the current Grok session to xAI.",
        .usage = "/feedback <text>",
        .requires_thread = false,
    },
    .{
        .id = .review,
        .name = "/review",
        .summary = "Run a Grok reviewer subagent against local changes, a branch, or a PR.",
        .usage = "/review [--local | --branch <name> | --pr <number-or-url>]",
        .requires_thread = false,
    },
    .{
        .id = .custom,
        .name = "/implement",
        .summary = "Run Grok's implement-review-fix loop with implementer and reviewer personas.",
        .usage = "/implement [--effort N] <description>",
        .requires_thread = false,
    },
    .{
        .id = .custom,
        .name = "/design",
        .summary = "Run Grok's design-doc writer/reviewer loop until consensus.",
        .usage = "/design <description>",
        .requires_thread = false,
    },
    .{
        .id = .custom,
        .name = "/deep-research",
        .summary = "Research with bounded parallel Grok agents and cross-checked evidence.",
        .usage = "/deep-research <query>",
        .requires_thread = false,
    },
    .{
        .id = .goal,
        .name = "/goal",
        .summary = "Set, manage, or check an autonomous Grok goal.",
        .usage = "/goal <objective> [--budget <tokens>] | status | pause | resume | clear",
        .requires_thread = false,
    },
    .{
        .id = .custom,
        .name = "/loop",
        .summary = "Run a prompt in Grok on a recurring interval.",
        .usage = "/loop [interval] <prompt>",
        .requires_thread = false,
    },
    .{
        .id = .custom,
        .name = "/workflow",
        .summary = "Launch a saved Grok workflow or manage a run.",
        .usage = "/workflow <name> [args] | pause|resume|stop|save [name]",
        .requires_thread = false,
    },
    .{
        .id = .custom,
        .name = "/plugins",
        .summary = "Manage Grok plugins.",
        .usage = "/plugins list | reload | trust <path> | add <path> | remove <path>",
        .requires_thread = false,
    },
    .{
        .id = .custom,
        .name = "/hooks-list",
        .summary = "Show hooks loaded in this Grok session.",
        .usage = "/hooks-list",
        .requires_thread = true,
    },
};

pub fn providerSlashCommands() []const provider_types.ProviderSlashCommand {
    return GROK_SLASH_COMMANDS[0..];
}

pub const Config = struct {
    executable: []const u8 = DEFAULT_EXECUTABLE,
    cwd: ?[]const u8 = null,
    // grok persists its own model selection per session; null defers to it.
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

    // Every grok command is a prompt turn: the agent parses the leading
    // `/name` server-side (session/slash_commands.rs) and answers through the
    // usual message chunks, so the collected reply becomes the transcript row.
    pub fn runSlashCommand(
        self: *Client,
        allocator: std.mem.Allocator,
        request: provider_types.RunSlashCommandRequest,
    ) !provider_types.RunSlashCommandResult {
        const command_name = slashCommandRoot(request.raw_text) orelse return error.UnsupportedOperation;
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
        const notice = try std.fmt.allocPrint(allocator, "Grok ran {s}.", .{command_name});

        return .{
            .handled = true,
            .thread_id = reply.thread_id,
            .notice = notice,
            .transcript_title = transcript_title,
            .transcript_body = transcript_body,
        };
    }

    // grok has no status subcommand; the ACP `authenticate` request is the
    // auth probe. It fails with a JSON-RPC error when `grok login` has never
    // cached a token, which the shared layer maps to AcpSignedOut.
    pub fn authState(self: *Client) !provider_types.AuthState {
        var proc = self.spawnAcp(self.allocator, null, null) catch |err| switch (err) {
            error.FileNotFound => return .unknown,
            else => return err,
        };
        defer proc.deinit();

        proc.writeLine(acp.makeInitializeRequestAlloc(self.allocator, 1) catch return .unknown) catch return .unknown;
        proc.writeLine(makeAuthenticateRequestAlloc(self.allocator, AUTHENTICATE_REQUEST_ID) catch return .unknown) catch return .unknown;

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
                if (id == AUTHENTICATE_REQUEST_ID) {
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

    // grok exits as soon as stdin reaches EOF, cancelling in-flight requests,
    // so unlike fx every exchange keeps stdin open until its answer arrives.
    fn listThreadsAcp(self: *Client, allocator: std.mem.Allocator) ![]provider_types.ChatThreadSummary {
        var proc = try self.spawnAcp(allocator, null, null);
        defer proc.deinit();

        var state: acp.ListThreadsState = .{};
        errdefer state.deinit(allocator);

        try proc.writeLine(try acp.makeInitializeRequestAlloc(allocator, 1));
        try proc.writeLine(try makeAuthenticateRequestAlloc(allocator, AUTHENTICATE_REQUEST_ID));
        try proc.writeLine(try acp.makeSessionListRequestAlloc(allocator, 2, try self.cwdAbsoluteAlloc(allocator)));

        var read_buffer: [16 * 1024]u8 = undefined;
        var reader = proc.process.child.stdout.?.reader(proc.threaded.io(), &read_buffer);
        while (try acp.takeLineAlloc(allocator, &reader)) |raw_line| {
            defer allocator.free(raw_line);
            const line = std.mem.trim(u8, raw_line, " \t\r");
            if (line.len == 0) continue;
            if (try acp.handleListThreadsLine(allocator, ACP_HARNESS, line, &state)) break;
        }

        try proc.closeStdin();
        proc.stop();
        const threads = try state.threads.toOwnedSlice(allocator);
        state.threads = .empty;
        return threads;
    }

    // grok publishes its model catalog (with per-model reasoning efforts) in
    // the initialize response, so discovery needs neither auth nor a session.
    fn listModelsAcp(self: *Client, allocator: std.mem.Allocator) ![]provider_types.ModelInfo {
        var proc = try self.spawnAcp(allocator, null, null);
        defer proc.deinit();

        try proc.writeLine(try acp.makeInitializeRequestAlloc(allocator, 1));

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
                const models = try parseAvailableModelsAlloc(allocator, parsed.value);
                try proc.closeStdin();
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
        var proc = try self.spawnAcp(allocator, null, null);
        defer proc.deinit();

        const cwd = try self.cwdAbsoluteAlloc(allocator);
        defer allocator.free(cwd);

        var state: acp.ReadThreadState = .{};
        errdefer state.deinit(allocator);

        try proc.writeLine(try acp.makeInitializeRequestAlloc(allocator, 1));
        try proc.writeLine(try makeAuthenticateRequestAlloc(allocator, AUTHENTICATE_REQUEST_ID));
        // grok already registers Verde's MCP server from its own global
        // config, so client-supplied servers stay empty to avoid a duplicate.
        try proc.writeLine(try acp.makeSessionLoadRequestAlloc(allocator, 2, thread_id, cwd, null));

        var read_buffer: [16 * 1024]u8 = undefined;
        var reader = proc.process.child.stdout.?.reader(proc.threaded.io(), &read_buffer);
        while (try acp.takeLineAlloc(allocator, &reader)) |raw_line| {
            defer allocator.free(raw_line);
            const line = std.mem.trim(u8, raw_line, " \t\r");
            if (line.len == 0) continue;
            if (try acp.handleReadThreadLine(allocator, ACP_HARNESS, line, thread_id, &state)) break;
        }

        try proc.closeStdin();
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
        // `grok agent -m <id> --reasoning-effort <e> stdio` only shapes new
        // sessions; a loaded session restores its persisted model, so resumed
        // threads re-apply overrides through session/set_model below.
        // "default" is Verde's sentinel for deferring to grok's own selection.
        const requested_model = request.model orelse self.config.model;
        const model_arg = if (requested_model) |model|
            (if (std.mem.eql(u8, model, "default")) null else model)
        else
            null;
        const effort_arg = if (request.reasoning_effort) |effort| reasoningEffortArg(effort) else null;

        var proc = try self.spawnAcp(allocator, model_arg, effort_arg);
        defer proc.deinit();

        const cwd = try self.cwdAbsoluteAllocForRequest(allocator, request);
        defer allocator.free(cwd);

        var state: acp.SendPromptState = .{};
        errdefer state.deinit(allocator);
        var resumed_model: ?[]u8 = null;
        defer if (resumed_model) |model| allocator.free(model);

        try proc.writeLine(try acp.makeInitializeRequestAlloc(allocator, 1));
        try proc.writeLine(try makeAuthenticateRequestAlloc(allocator, AUTHENTICATE_REQUEST_ID));
        if (request.thread_id) |thread_id| {
            try proc.writeLine(try acp.makeSessionLoadRequestAlloc(allocator, 2, thread_id, cwd, null));
        } else {
            try proc.writeLine(try acp.makeSessionNewRequestAlloc(allocator, 2, cwd, null));
        }

        var read_buffer: [16 * 1024]u8 = undefined;
        var reader = proc.process.child.stdout.?.reader(proc.threaded.io(), &read_buffer);
        while (try acp.takeLineAlloc(allocator, &reader)) |raw_line| {
            defer allocator.free(raw_line);
            const line = std.mem.trim(u8, raw_line, " \t\r");
            if (line.len == 0) continue;
            // A loaded session reports the model it restored; keep it so an
            // effort-only override can still be applied via session/set_model.
            if (request.thread_id != null and state.session_id == null and resumed_model == null) {
                resumed_model = try currentModelIdFromSessionResponseAlloc(allocator, line);
            }
            const action = try acp.handleSendPromptLine(allocator, ACP_HARNESS, line, request, &state, proc.process.child.stdin);
            switch (action) {
                .continue_reading => {},
                .session_ready => {
                    if (state.session_id) |session_id| {
                        active_process_state.register(&proc.process, proc.process.child.stdin, session_id);
                        if (request.on_thread_id) |on_thread_id| on_thread_id(request.stream_context, session_id);
                        if (request.on_turn_id) |on_turn_id| on_turn_id(request.stream_context, session_id);
                        if (request.thread_id != null and (model_arg != null or effort_arg != null)) {
                            if (model_arg orelse resumed_model) |model| {
                                try proc.writeLine(try makeSetModelRequestAlloc(allocator, SET_MODEL_REQUEST_ID, session_id, model, effort_arg));
                            }
                        }
                        try proc.writeLine(try acp.makePromptRequestAlloc(allocator, 3, session_id, request, GROK_ACCEPTS_IMAGES));
                        state.prompt_submitted = true;
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

    fn spawnAcp(self: *Client, allocator: std.mem.Allocator, model_arg: ?[]const u8, effort_arg: ?[]const u8) !acp.Process {
        var env_map = try process_env.buildAugmentedEnvMap(allocator);
        errdefer env_map.deinit();
        const executable = try resolveGrokExecutableAlloc(allocator, &env_map, self.config.executable);
        errdefer allocator.free(executable);

        var threaded: std.Io.Threaded = .init(allocator, .{});
        errdefer threaded.deinit();
        var argv_storage: [7][]const u8 = undefined;
        const argv = buildArgv(&argv_storage, executable, model_arg, effort_arg);
        var child = try platform_process.spawn(allocator, threaded.io(), .{
            .argv = argv,
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

/// Maps provider-neutral ACP errors to Grok error names so user-facing error
/// messaging can address grok specifically (e.g. suggest `grok login`).
fn slashCommandRoot(raw_text: []const u8) ?[]const u8 {
    const text = std.mem.trim(u8, raw_text, " \t\r\n");
    if (!std.mem.startsWith(u8, text, "/")) return null;
    const root_end = std.mem.indexOfAny(u8, text, " \t\r\n") orelse text.len;
    if (root_end <= 1) return null;
    return text[0..root_end];
}

test "grok slash commands expose builtins and parse the command root" {
    const commands = providerSlashCommands();
    try std.testing.expect(commands.len > 0);
    try std.testing.expectEqualStrings("/compact", commands[0].name);
    try std.testing.expectEqual(provider_types.ProviderSlashCommandId.compact, commands[0].id);
    try std.testing.expect(commands[0].requires_thread);
    try std.testing.expectEqualStrings("/context", slashCommandRoot("  /context \n").?);
    try std.testing.expectEqualStrings("/loop", slashCommandRoot("/loop 5m run tests").?);
    try std.testing.expect(slashCommandRoot("plain text") == null);
    try std.testing.expect(slashCommandRoot("/") == null);
}

fn mapAcpError(err: anyerror) anyerror {
    return switch (err) {
        error.AcpFailed => error.GrokAcpFailed,
        error.AcpSignedOut => error.GrokSignedOut,
        error.AcpMessageTooLarge => error.GrokAcpMessageTooLarge,
        error.AcpAttachmentsUnsupported => error.GrokAttachmentsUnsupported,
        else => err,
    };
}

// The model/effort flags belong to `grok agent`, ahead of the `stdio`
// subcommand.
fn buildArgv(storage: *[7][]const u8, executable: []const u8, model_arg: ?[]const u8, effort_arg: ?[]const u8) []const []const u8 {
    var len: usize = 0;
    storage[len] = executable;
    len += 1;
    storage[len] = "agent";
    len += 1;
    if (model_arg) |model| {
        storage[len] = "--model";
        storage[len + 1] = model;
        len += 2;
    }
    if (effort_arg) |effort| {
        storage[len] = "--reasoning-effort";
        storage[len + 1] = effort;
        len += 2;
    }
    storage[len] = "stdio";
    len += 1;
    return storage[0..len];
}

/// grok reasoning efforts top out at `xhigh`; Verde's `max` tier is clamped
/// rather than rejected so an over-ambitious persisted thread still sends.
fn reasoningEffortArg(effort: provider_types.ReasoningEffort) []const u8 {
    return switch (effort) {
        .low => "low",
        .medium => "medium",
        .high => "high",
        .xhigh, .max => "xhigh",
    };
}

fn makeAuthenticateRequestAlloc(allocator: std.mem.Allocator, id: i64) ![]u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    var stringify: std.json.Stringify = .{ .writer = &writer.writer, .options = .{} };
    try stringify.beginObject();
    try writeJsonRpcHead(&stringify, id, "authenticate");
    try stringify.objectField("params");
    try stringify.beginObject();
    try stringify.objectField("methodId");
    try stringify.write(AUTH_METHOD_ID);
    try stringify.endObject();
    try stringify.endObject();
    return writer.toOwnedSlice();
}

// grok's session/set_model accepts an extension `reasoningEffort` alongside
// the standard `modelId`; there is no set_config_option surface for effort.
fn makeSetModelRequestAlloc(
    allocator: std.mem.Allocator,
    id: i64,
    session_id: []const u8,
    model_id: []const u8,
    effort_arg: ?[]const u8,
) ![]u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    var stringify: std.json.Stringify = .{ .writer = &writer.writer, .options = .{} };
    try stringify.beginObject();
    try writeJsonRpcHead(&stringify, id, "session/set_model");
    try stringify.objectField("params");
    try stringify.beginObject();
    try stringify.objectField("sessionId");
    try stringify.write(session_id);
    try stringify.objectField("modelId");
    try stringify.write(model_id);
    if (effort_arg) |effort| {
        try stringify.objectField("reasoningEffort");
        try stringify.write(effort);
    }
    try stringify.endObject();
    try stringify.endObject();
    return writer.toOwnedSlice();
}

fn writeJsonRpcHead(stringify: *std.json.Stringify, id: i64, method: []const u8) !void {
    try stringify.objectField("jsonrpc");
    try stringify.write("2.0");
    try stringify.objectField("id");
    try stringify.write(id);
    try stringify.objectField("method");
    try stringify.write(method);
}

// Extracts `result.models.currentModelId` from the id-2 session/new or
// session/load response line; null for any other line.
fn currentModelIdFromSessionResponseAlloc(allocator: std.mem.Allocator, line: []const u8) !?[]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
    defer parsed.deinit();
    const id = acp.responseId(parsed.value) orelse return null;
    if (id != 2) return null;
    const result = acp.getObjectField(parsed.value, "result") orelse return null;
    const models = acp.getObjectField(result, "models") orelse return null;
    const current = acp.getOptionalObjectString(models, "currentModelId") orelse return null;
    return try allocator.dupe(u8, current);
}

// Parses the model catalog from an initialize response
// (`result._meta.modelState.availableModels`) or a session response
// (`result.models.availableModels`): entries carry {modelId, name}.
fn parseAvailableModelsAlloc(allocator: std.mem.Allocator, value: std.json.Value) ![]provider_types.ModelInfo {
    var models: std.ArrayList(provider_types.ModelInfo) = .empty;
    errdefer {
        for (models.items) |model| model.deinit(allocator);
        models.deinit(allocator);
    }

    const result = acp.getObjectField(value, "result") orelse return error.AcpFailed;
    const model_state = acp.getObjectField(result, "models") orelse blk: {
        const meta = acp.getObjectField(result, "_meta") orelse return error.AcpFailed;
        break :blk acp.getObjectField(meta, "modelState") orelse return error.AcpFailed;
    };
    const entries = acp.getObjectField(model_state, "availableModels") orelse return error.AcpFailed;
    if (entries != .array) return error.AcpFailed;
    for (entries.array.items) |entry| {
        if (entry != .object) continue;
        const id = acp.getOptionalObjectString(entry, "modelId") orelse continue;
        const name = acp.getOptionalObjectString(entry, "name") orelse id;
        try models.append(allocator, .{
            .provider_id = try allocator.dupe(u8, "grok"),
            .provider_name = try allocator.dupe(u8, "Grok"),
            .model_id = try allocator.dupe(u8, id),
            .model_name = try allocator.dupe(u8, name),
        });
    }
    if (models.items.len == 0) return error.AcpFailed;
    return models.toOwnedSlice(allocator);
}

fn resolveGrokExecutableAlloc(
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

    runtime_log.diagnostic("grok CLI not found; install Grok Build (https://docs.x.ai/build/overview#install), ensure `grok` is on PATH, then run `grok login`.", .{});
    return error.FileNotFound;
}

test "resolveGrokExecutableAlloc reports missing grok binary" {
    var env_map = std.process.Environ.Map.init(std.testing.allocator);
    defer env_map.deinit();
    try env_map.put("PATH", "/definitely/missing");
    try env_map.put("HOME", "/definitely/missing-home");
    try std.testing.expectError(error.FileNotFound, resolveGrokExecutableAlloc(std.testing.allocator, &env_map, "missing-grok"));
}

test "buildArgv places model and effort flags ahead of the stdio subcommand" {
    var storage: [7][]const u8 = undefined;
    const plain = buildArgv(&storage, "/bin/grok", null, null);
    try std.testing.expectEqual(@as(usize, 3), plain.len);
    try std.testing.expectEqualStrings("agent", plain[1]);
    try std.testing.expectEqualStrings("stdio", plain[2]);

    var storage_full: [7][]const u8 = undefined;
    const full = buildArgv(&storage_full, "/bin/grok", "grok-4.5", reasoningEffortArg(.max));
    try std.testing.expectEqual(@as(usize, 7), full.len);
    try std.testing.expectEqualStrings("--model", full[2]);
    try std.testing.expectEqualStrings("grok-4.5", full[3]);
    try std.testing.expectEqualStrings("--reasoning-effort", full[4]);
    // Verde's max tier clamps to grok's top effort.
    try std.testing.expectEqualStrings("xhigh", full[5]);
    try std.testing.expectEqualStrings("stdio", full[6]);
}

test "makeAuthenticateRequestAlloc uses the cached token method" {
    const json = try makeAuthenticateRequestAlloc(std.testing.allocator, AUTHENTICATE_REQUEST_ID);
    defer std.testing.allocator.free(json);
    try std.testing.expectEqualStrings(
        \\{"jsonrpc":"2.0","id":10,"method":"authenticate","params":{"methodId":"cached_token"}}
    , json);
}

test "makeSetModelRequestAlloc carries the optional reasoning effort" {
    const with_effort = try makeSetModelRequestAlloc(std.testing.allocator, SET_MODEL_REQUEST_ID, "s-1", "grok-4.6", "low");
    defer std.testing.allocator.free(with_effort);
    try std.testing.expectEqualStrings(
        \\{"jsonrpc":"2.0","id":11,"method":"session/set_model","params":{"sessionId":"s-1","modelId":"grok-4.6","reasoningEffort":"low"}}
    , with_effort);

    const model_only = try makeSetModelRequestAlloc(std.testing.allocator, SET_MODEL_REQUEST_ID, "s-1", "grok-4.6", null);
    defer std.testing.allocator.free(model_only);
    try std.testing.expectEqualStrings(
        \\{"jsonrpc":"2.0","id":11,"method":"session/set_model","params":{"sessionId":"s-1","modelId":"grok-4.6"}}
    , model_only);
}

test "currentModelIdFromSessionResponseAlloc reads the restored model from a session response" {
    const session_line =
        \\{"jsonrpc":"2.0","id":2,"result":{"sessionId":"s-1","models":{"currentModelId":"grok-4.6","availableModels":[]}}}
    ;
    const model = (try currentModelIdFromSessionResponseAlloc(std.testing.allocator, session_line)).?;
    defer std.testing.allocator.free(model);
    try std.testing.expectEqualStrings("grok-4.6", model);

    const update_line =
        \\{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s-1","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"hi"}}}}
    ;
    try std.testing.expectEqual(@as(?[]u8, null), try currentModelIdFromSessionResponseAlloc(std.testing.allocator, update_line));
}

test "parseAvailableModelsAlloc reads the initialize modelState catalog" {
    const payload =
        \\{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":1,"agentCapabilities":{"loadSession":true},
        \\"_meta":{"modelState":{"currentModelId":"grok-4.6","availableModels":[
        \\{"modelId":"grok-4.6","name":"Grok 4.6","_meta":{"supportsReasoningEffort":true}},
        \\{"modelId":"grok-4.5","name":"Grok 4.5"}]}}}}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, payload, .{});
    defer parsed.deinit();
    const models = try parseAvailableModelsAlloc(std.testing.allocator, parsed.value);
    defer provider_types.freeModelInfos(std.testing.allocator, models);
    try std.testing.expectEqual(@as(usize, 2), models.len);
    try std.testing.expectEqualStrings("grok", models[0].provider_id);
    try std.testing.expectEqualStrings("Grok", models[0].provider_name);
    try std.testing.expectEqualStrings("grok-4.6", models[0].model_id);
    try std.testing.expectEqualStrings("Grok 4.6", models[0].model_name);
    try std.testing.expectEqualStrings("grok-4.5", models[1].model_id);
}

test "parseAvailableModelsAlloc reads a session/new models catalog" {
    const payload =
        \\{"jsonrpc":"2.0","id":2,"result":{"sessionId":"s-1","models":{"currentModelId":"grok-4.5","availableModels":[{"modelId":"grok-4.5","name":"Grok 4.5"}]}}}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, payload, .{});
    defer parsed.deinit();
    const models = try parseAvailableModelsAlloc(std.testing.allocator, parsed.value);
    defer provider_types.freeModelInfos(std.testing.allocator, models);
    try std.testing.expectEqual(@as(usize, 1), models.len);
    try std.testing.expectEqualStrings("grok-4.5", models[0].model_id);
}

test "parseAvailableModelsAlloc fails without a model catalog" {
    const payload =
        \\{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":1,"_meta":{}}}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, payload, .{});
    defer parsed.deinit();
    try std.testing.expectError(error.AcpFailed, parseAvailableModelsAlloc(std.testing.allocator, parsed.value));
}

const StreamCapture = struct {
    deltas: std.ArrayList(u8) = .empty,
    tool_titles: std.ArrayList(u8) = .empty,

    fn onDelta(ctx: ?*anyopaque, text: []const u8) void {
        const self: *StreamCapture = @ptrCast(@alignCast(ctx.?));
        self.deltas.appendSlice(std.testing.allocator, text) catch unreachable;
    }

    fn onEvent(ctx: ?*anyopaque, event: provider_types.StreamEvent) void {
        const self: *StreamCapture = @ptrCast(@alignCast(ctx.?));
        switch (event) {
            .tool_call => |call| self.tool_titles.appendSlice(std.testing.allocator, call.title) catch unreachable,
            else => {},
        }
    }

    fn deinit(self: *StreamCapture) void {
        self.deltas.deinit(std.testing.allocator);
        self.tool_titles.deinit(std.testing.allocator);
    }
};

test "sendPrompt stream capture forwards grok message chunks and tool calls" {
    var capture: StreamCapture = .{};
    defer capture.deinit();
    var state: acp.SendPromptState = .{ .prompt_submitted = true };
    defer state.deinit(std.testing.allocator);
    const request = provider_types.SendPromptRequest{
        .thread_id = "grok-session",
        .prompt = "hello",
        .stream_context = &capture,
        .on_stream_delta = StreamCapture.onDelta,
        .on_stream_event = StreamCapture.onEvent,
    };
    // Shapes copied from a live `grok agent stdio` turn.
    const chunk =
        \\{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"grok-session","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Hi there"}}}}
    ;
    const tool =
        \\{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"grok-session","update":{"sessionUpdate":"tool_call","toolCallId":"call_1","title":"ls","kind":"execute","status":"in_progress","rawInput":{"command":"ls"}}}}
    ;
    const done =
        \\{"jsonrpc":"2.0","id":3,"result":{"stopReason":"end_turn"}}
    ;

    try std.testing.expectEqual(acp.SendLineAction.continue_reading, try acp.handleSendPromptLine(std.testing.allocator, ACP_HARNESS, chunk, request, &state, null));
    try std.testing.expectEqual(acp.SendLineAction.continue_reading, try acp.handleSendPromptLine(std.testing.allocator, ACP_HARNESS, tool, request, &state, null));
    try std.testing.expectEqual(acp.SendLineAction.prompt_done, try acp.handleSendPromptLine(std.testing.allocator, ACP_HARNESS, done, request, &state, null));
    try std.testing.expectEqualStrings("Hi there", capture.deltas.items);
    try std.testing.expectEqualStrings("Hi there", state.reply.items);
    try std.testing.expect(std.mem.indexOf(u8, capture.tool_titles.items, "ls") != null);
}

test "sendPrompt maps grok authorization failures to GrokSignedOut" {
    // grok answers session/new with this exact error when `grok login` has
    // not cached a token; the public API must surface it as a sign-in error.
    var state: acp.SendPromptState = .{};
    defer state.deinit(std.testing.allocator);
    const request = provider_types.SendPromptRequest{ .prompt = "hello" };
    const line =
        \\{"jsonrpc":"2.0","id":2,"error":{"code":-32000,"message":"AuthorizationRequired: run `grok login` or authenticate"}}
    ;
    const result = acp.handleSendPromptLine(std.testing.allocator, ACP_HARNESS, line, request, &state, null);
    try std.testing.expectError(error.GrokSignedOut, mapAcpErrorResult(result));
}

test "sendPrompt forwards image attachments despite grok's image=false flag" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "shot.png", .data = "PNGBYTES" });
    var dir_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(std.testing.io, &dir_buf);
    const path = try std.fs.path.join(std.testing.allocator, &.{ dir_buf[0..dir_len], "shot.png" });
    defer std.testing.allocator.free(path);
    const request = provider_types.SendPromptRequest{
        .prompt = "describe",
        .images = &.{.{ .path = path }},
    };
    const line = try acp.makePromptRequestAlloc(std.testing.allocator, 3, "grok-session", request, GROK_ACCEPTS_IMAGES);
    defer std.testing.allocator.free(line);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"type\":\"image\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"mimeType\":\"image/png\"") != null);
}

fn mapAcpErrorResult(result: anytype) !void {
    _ = result catch |err| return mapAcpError(err);
}
