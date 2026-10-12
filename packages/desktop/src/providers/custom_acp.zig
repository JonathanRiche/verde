//! Harness for user-defined ACP agents (`chat.custom_acp_agents`).
//! Generic ACP transport/protocol machinery lives in `acp.zig`; this module
//! resolves the agent named by a thread's model ref (`<agent-id>[/<model>]`)
//! from verde.json on every operation, so Settings edits apply to the next
//! turn without restarting the daemon, then spawns the configured command
//! with its args and extra environment.

const std = @import("std");
const acp = @import("acp.zig");
const custom_agents = @import("../app/custom_acp_agents.zig");
const platform_process = @import("../platform/process.zig");
const provider_mcp = @import("mcp.zig");
const process_env = @import("../platform/env.zig");
const provider_types = @import("types.zig");
const runtime_log = @import("../runtime/log.zig");

/// Request id for `session/set_config_option`, outside the shared 1/2/3
/// sequence so its response passes through `acp.handleSendPromptLine`.
const SET_MODEL_REQUEST_ID: i64 = 12;

var active_process_state: acp.ActiveProcessState = .{};

pub fn providerSlashCommands() []const provider_types.ProviderSlashCommand {
    return &.{};
}

pub const Config = struct {
    cwd: ?[]const u8 = null,
    /// Thread model ref: `<agent-id>` or `<agent-id>/<agent model id>`.
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

    /// Ready when at least one agent is configured and its command resolves.
    /// Probing every agent with an ACP handshake would launch arbitrary user
    /// commands on each readiness poll; sign-in problems surface on the turn
    /// itself with the agent's own error text.
    pub fn authState(self: *Client) !provider_types.AuthState {
        const agents = custom_agents.loadFromConfigFileAlloc(self.allocator) catch return .unknown;
        defer custom_agents.freeAgents(self.allocator, agents);
        if (agents.len == 0) return .signed_out;
        var env_map = process_env.buildAugmentedEnvMap(self.allocator) catch return .unknown;
        defer env_map.deinit();
        for (agents) |agent| {
            const resolved = process_env.resolveExecutableInEnvMapAlloc(self.allocator, &env_map, agent.command) catch continue;
            self.allocator.free(resolved);
            return .signed_in;
        }
        return .signed_out;
    }

    pub fn listThreads(self: *Client, allocator: std.mem.Allocator) ![]provider_types.ChatThreadSummary {
        _ = self;
        _ = allocator;
        return error.UnsupportedOperation;
    }

    /// One entry per configured agent; the model id is the agent id, which
    /// becomes the thread's model ref. No agent process is launched.
    pub fn listModels(self: *Client, allocator: std.mem.Allocator) ![]provider_types.ModelInfo {
        _ = self;
        const agents = try custom_agents.loadFromConfigFileAlloc(allocator);
        defer custom_agents.freeAgents(allocator, agents);
        var models: std.ArrayList(provider_types.ModelInfo) = .empty;
        errdefer {
            for (models.items) |model| model.deinit(allocator);
            models.deinit(allocator);
        }
        for (agents) |agent| {
            const provider_id = try allocator.dupe(u8, "custom_acp");
            errdefer allocator.free(provider_id);
            const provider_name = try allocator.dupe(u8, "Custom ACP");
            errdefer allocator.free(provider_name);
            const model_id = try allocator.dupe(u8, agent.id);
            errdefer allocator.free(model_id);
            const model_name = try allocator.dupe(u8, agent.name);
            errdefer allocator.free(model_name);
            try models.append(allocator, .{
                .provider_id = provider_id,
                .provider_name = provider_name,
                .model_id = model_id,
                .model_name = model_name,
            });
        }
        return models.toOwnedSlice(allocator);
    }

    pub fn readThread(
        self: *Client,
        allocator: std.mem.Allocator,
        thread_id: []const u8,
    ) !provider_types.ReadThreadResult {
        var agent = try self.resolveAgent(allocator, self.config.model);
        defer agent.deinit(allocator);
        return self.readThreadAcp(allocator, agent, thread_id) catch |err| return mapAcpError(err);
    }

    pub fn sendPrompt(
        self: *Client,
        allocator: std.mem.Allocator,
        request: provider_types.SendPromptRequest,
    ) !provider_types.SendPromptResult {
        const model_ref = request.model orelse self.config.model;
        var agent = try self.resolveAgent(allocator, model_ref);
        defer agent.deinit(allocator);
        const agent_model = if (model_ref) |value| (if (custom_agents.parseModelRef(value)) |ref| ref.model else null) else null;
        return self.sendPromptAcp(allocator, agent, agent_model, request) catch |err| return mapAcpError(err);
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

    /// Owned copy of the agent named by `model_ref`, or the first configured
    /// agent when the ref is missing or the "default" sentinel.
    fn resolveAgent(self: *Client, allocator: std.mem.Allocator, model_ref: ?[]const u8) !custom_agents.Agent {
        _ = self;
        const agents = try custom_agents.loadFromConfigFileAlloc(allocator);
        defer custom_agents.freeAgents(allocator, agents);
        if (agents.len == 0) return error.CustomAcpAgentNotConfigured;
        const ref = if (model_ref) |value|
            (if (std.mem.eql(u8, value, "default")) null else custom_agents.parseModelRef(value))
        else
            null;
        if (ref) |parsed| {
            const agent = custom_agents.findById(agents, parsed.agent_id) orelse {
                runtime_log.diagnostic("custom ACP agent not found in chat.custom_acp_agents", .{});
                return error.CustomAcpAgentNotConfigured;
            };
            return agent.clone(allocator);
        }
        return agents[0].clone(allocator);
    }

    fn readThreadAcp(
        self: *Client,
        allocator: std.mem.Allocator,
        agent: custom_agents.Agent,
        thread_id: []const u8,
    ) !provider_types.ReadThreadResult {
        var proc = try spawnAgent(allocator, agent, self.config.cwd);
        defer proc.deinit();

        const cwd = try self.cwdAbsoluteAlloc(allocator, null);
        defer allocator.free(cwd);
        const harness = harnessFor(agent);

        var state: acp.ReadThreadState = .{};
        errdefer state.deinit(allocator);

        try proc.writeLine(try acp.makeInitializeRequestAlloc(allocator, 1));
        try proc.writeLine(try acp.makeSessionLoadRequestAlloc(allocator, 2, thread_id, cwd, null));

        var read_buffer: [16 * 1024]u8 = undefined;
        var reader = proc.process.child.stdout.?.reader(proc.threaded.io(), &read_buffer);
        while (try acp.takeLineAlloc(allocator, &reader)) |raw_line| {
            defer allocator.free(raw_line);
            const line = std.mem.trim(u8, raw_line, " \t\r");
            if (line.len == 0) continue;
            if (try acp.handleReadThreadLine(allocator, harness, line, thread_id, &state)) break;
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
        agent: custom_agents.Agent,
        agent_model: ?[]const u8,
        request: provider_types.SendPromptRequest,
    ) !provider_types.SendPromptResult {
        var proc = try spawnAgent(allocator, agent, self.config.cwd);
        defer proc.deinit();

        const cwd = try self.cwdAbsoluteAlloc(allocator, request.cwd);
        defer allocator.free(cwd);
        const harness = harnessFor(agent);

        // Offer Verde's own MCP server when the user enabled the integration;
        // the shared builder drops it for agents without HTTP MCP support.
        var mcp_connection = provider_mcp.loadHttpConnection(allocator) catch null;
        defer if (mcp_connection) |*connection| connection.deinit(allocator);
        const mcp_http: ?acp.McpHttpServer = if (mcp_connection) |connection| .{
            .url = connection.url,
            .authorization = connection.authorization,
            .client_name = "custom_acp",
        } else null;

        var state: acp.SendPromptState = .{};
        errdefer state.deinit(allocator);

        try proc.writeLine(try acp.makeInitializeRequestAlloc(allocator, 1));

        var read_buffer: [16 * 1024]u8 = undefined;
        var reader = proc.process.child.stdout.?.reader(proc.threaded.io(), &read_buffer);
        while (try acp.takeLineAlloc(allocator, &reader)) |raw_line| {
            defer allocator.free(raw_line);
            const line = std.mem.trim(u8, raw_line, " \t\r");
            if (line.len == 0) continue;
            const action = try acp.handleSendPromptLine(allocator, harness, line, request, &state, proc.process.child.stdin);
            switch (action) {
                .continue_reading => {},
                .initialized => {
                    if (request.thread_id != null and !state.capabilities.load_session and !state.capabilities.resume_session) {
                        return error.CustomAcpCannotResume;
                    }
                    try proc.writeLine(try acp.makeTurnSessionRequestAlloc(allocator, 2, state.capabilities, .{
                        .cwd = cwd,
                        .session_id = request.thread_id,
                        .mcp_http = mcp_http,
                    }));
                },
                .session_ready => {
                    if (state.session_id) |session_id| {
                        active_process_state.register(&proc.process, proc.process.child.stdin, session_id);
                        if (request.on_thread_id) |on_thread_id| on_thread_id(request.stream_context, session_id);
                        if (request.on_turn_id) |on_turn_id| on_turn_id(request.stream_context, session_id);
                        if (agent_model) |model| {
                            try proc.writeLine(try makeSetModelOptionRequestAlloc(allocator, SET_MODEL_REQUEST_ID, session_id, model));
                        }
                        try proc.writeLine(try acp.makePromptRequestAlloc(allocator, 3, session_id, request, state.capabilities.image));
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

    fn cwdAbsoluteAlloc(self: *Client, allocator: std.mem.Allocator, request_cwd: ?[]const u8) ![]u8 {
        if (request_cwd orelse self.config.cwd) |cwd| return std.fs.path.resolve(allocator, &.{cwd});
        var threaded: std.Io.Threaded = .init(allocator, .{});
        defer threaded.deinit();
        return std.process.currentPathAlloc(threaded.io(), allocator);
    }
};

pub fn shutdownOwnedServer() void {
    active_process_state.lock();
    defer active_process_state.unlock();
    if (active_process_state.child) |child| child.terminateTree();
}

/// The returned harness borrows `agent.name`; keep the agent alive for the
/// exchange.
fn harnessFor(agent: custom_agents.Agent) acp.Harness {
    return .{
        .diagnostics_category = .custom_acp,
        .assistant_author = agent.name,
        .permission_default_title = "Agent permission request",
    };
}

fn spawnAgent(allocator: std.mem.Allocator, agent: custom_agents.Agent, cwd: ?[]const u8) !acp.Process {
    var env_map = try process_env.buildAugmentedEnvMap(allocator);
    errdefer env_map.deinit();
    for (agent.env) |entry| try env_map.put(entry.name, entry.value);

    const executable = process_env.resolveExecutableInEnvMapAlloc(allocator, &env_map, agent.command) catch |err| switch (err) {
        error.FileNotFound, error.AccessDenied => {
            runtime_log.diagnostic("custom ACP agent command not found; check its command in Settings > Providers.", .{});
            return error.CustomAcpCommandNotFound;
        },
        else => return err,
    };
    errdefer allocator.free(executable);

    const argv = try allocator.alloc([]const u8, agent.args.len + 1);
    defer allocator.free(argv);
    argv[0] = executable;
    for (agent.args, 0..) |arg, index| argv[index + 1] = arg;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    errdefer threaded.deinit();
    var child = try platform_process.spawn(allocator, threaded.io(), .{
        .argv = argv,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .inherit,
        .cwd = if (cwd) |path| .{ .path = path } else .inherit,
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

/// Standard ACP `session/set_config_option` for the `model` option.
fn makeSetModelOptionRequestAlloc(allocator: std.mem.Allocator, id: i64, session_id: []const u8, model: []const u8) ![]u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    var stringify: std.json.Stringify = .{ .writer = &writer.writer, .options = .{} };
    try stringify.write(.{
        .jsonrpc = "2.0",
        .id = id,
        .method = "session/set_config_option",
        .params = .{ .sessionId = session_id, .configId = "model", .value = model },
    });
    return writer.toOwnedSlice();
}

/// Maps provider-neutral ACP errors to custom-agent error names so the GUI
/// can explain them without naming a specific vendor CLI.
fn mapAcpError(err: anyerror) anyerror {
    return switch (err) {
        error.AcpFailed => error.CustomAcpFailed,
        error.AcpRefused => error.CustomAcpRefused,
        error.AcpSignedOut => error.CustomAcpSignedOut,
        error.AcpMessageTooLarge => error.CustomAcpMessageTooLarge,
        error.AcpAttachmentsUnsupported => error.CustomAcpAttachmentsUnsupported,
        else => err,
    };
}

test "makeSetModelOptionRequestAlloc emits a standard config option request" {
    const json = try makeSetModelOptionRequestAlloc(std.testing.allocator, 12, "s-1", "anthropic/claude");
    defer std.testing.allocator.free(json);
    try std.testing.expectEqualStrings(
        \\{"jsonrpc":"2.0","id":12,"method":"session/set_config_option","params":{"sessionId":"s-1","configId":"model","value":"anthropic/claude"}}
    , json);
}

test "harnessFor labels replies with the agent name" {
    var args = [_][]u8{};
    const agent: custom_agents.Agent = .{
        .id = @constCast("my-agent"),
        .name = @constCast("My Agent"),
        .command = @constCast("agent"),
        .args = &args,
    };
    const harness = harnessFor(agent);
    try std.testing.expectEqualStrings("My Agent", harness.assistant_author);
}
