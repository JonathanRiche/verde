const std = @import("std");
const builtin = @import("builtin");

const args = @import("cli_args.zig");
const completion = @import("cli_completion.zig");
const output = @import("cli_output.zig");
const spec = @import("cli_spec.zig");
const db_client = @import("db/client.zig");
const db_types = @import("db/types.zig");

const VERSION = "0.0.0";
const SOCKET_NAME = "verde.sock";

pub const Result = enum {
    handled,
    launch_app,
};

pub fn dispatch(allocator: std.mem.Allocator, io: std.Io, process_args: std.process.Args) !Result {
    var iterator = try std.process.Args.Iterator.initAllocator(process_args, allocator);
    defer iterator.deinit();

    var argv_list: std.ArrayList([]const u8) = .empty;
    defer argv_list.deinit(allocator);
    while (iterator.next()) |arg| {
        try argv_list.append(allocator, arg);
    }
    const argv = argv_list.items;
    return try dispatchArgs(allocator, io, argv);
}

fn dispatchArgs(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8) !Result {
    if (argv.len <= 1) return .launch_app;

    const out: output.Output = .{ .io = io };
    const parsed = args.parse(argv);
    if (std.mem.eql(u8, parsed.command, "app")) return .launch_app;
    if (std.mem.eql(u8, parsed.command, "--help") or std.mem.eql(u8, parsed.command, "-h") or std.mem.eql(u8, parsed.command, "help")) {
        try printHelp(out);
        return .handled;
    }
    if (std.mem.eql(u8, parsed.command, "version")) {
        try printVersion(allocator, out, parsed.json);
        return .handled;
    }
    if (std.mem.eql(u8, parsed.command, "capabilities")) {
        try printCapabilities(allocator, out, parsed.json);
        return .handled;
    }
    if (std.mem.eql(u8, parsed.command, "completion")) {
        try handleCompletion(allocator, out, parsed.rest);
        return .handled;
    }
    if (std.mem.eql(u8, parsed.command, "state")) {
        try handleState(allocator, out, parsed.rest);
        return .handled;
    }
    if (std.mem.eql(u8, parsed.command, "live")) {
        try handleLive(allocator, out, io, parsed.rest);
        return .handled;
    }
    if (std.mem.eql(u8, parsed.command, "mcp")) {
        try handleMcp(allocator, out, io);
        return .handled;
    }

    try out.stderr("unknown verde command: {s}\n\n", .{parsed.command});
    try printHelp(out);
    std.process.exit(2);
}

fn printHelp(out: output.Output) !void {
    try out.stdout(
        \\Usage:
        \\  verde                         Launch the desktop app
        \\  verde app                     Launch the desktop app explicitly
        \\  verde --help                  Show this help
        \\  verde version [--json]        Print version metadata
        \\  verde capabilities [--json]   Print CLI capability metadata
        \\  verde completion <shell>       Print shell completion script
        \\  verde state <command>         Read persisted state with the app closed
        \\  verde live <command>          Talk to the running app
        \\  verde mcp                     Run the stdio MCP bridge
        \\
        \\State commands:
        \\  path
        \\  projects [--json]
        \\  panes --project <id|index|current> [--json]
        \\  threads --project <id|index|current> [--json]
        \\  transcript --project <id|index|current> --thread <index|provider-id> [--json]
        \\
        \\Live commands:
        \\  status [--json]
        \\  capabilities [--json]
        \\  projects [--json]
        \\  panes [--project <id|index|current>] [--json]
        \\  active [--json]
        \\  threads [--project <id|index|current>] [--json]
        \\  terminals [--project <id|index|current>] [--json]
        \\  inspect --pane <id> [--project <id|index|current>] [--json]
        \\  pane focus|split|resize|minimize|maximize|restore|close ...
        \\  chat status|transcript|send|followup|stop|approve|draft ...
        \\  browser eval|post-json ...
        \\  terminal write|tail|screen --pane <id> ...
        \\  process list|inspect|start|stop|restart|logs ...
        \\  stack status|start|stop|restart ...
        \\
        \\Completion shells:
        \\  bash
        \\  zsh
        \\  fish
        \\
    , .{});
}

fn printVersion(allocator: std.mem.Allocator, out: output.Output, json: bool) !void {
    if (json) {
        try out.jsonValue(allocator, .{
            .name = "verde",
            .version = VERSION,
        });
        return;
    }
    try out.stdout("verde {s}\n", .{VERSION});
}

fn printCapabilities(allocator: std.mem.Allocator, out: output.Output, json: bool) !void {
    const caps = .{
        .app = "verde",
        .version = VERSION,
        .protocol_version = 1,
        .cli = .{
            .state = spec.state_commands[0..],
            .live = spec.live_capabilities[0..],
            .completion = spec.shells[0..],
            .encodings = spec.encodings[0..],
        },
        .ipc = .{
            .transport = "unix",
            .socket_name = SOCKET_NAME,
            .terminal_binary_frames = false,
            .mcp_bridge = true,
        },
    };
    if (json) {
        try out.jsonValue(allocator, caps);
        return;
    }
    try out.stdout(
        \\verde CLI capabilities
        \\  protocol: 1
        \\  state: path, projects, panes, threads, transcript
        \\  live: status, projects, panes, pane control, chat control, terminal/process control
        \\  completion: bash, zsh, fish
        \\  encodings: json, jsonl
        \\  terminal binary frames: no
        \\
    , .{});
}

fn handleCompletion(allocator: std.mem.Allocator, out: output.Output, argv: []const []const u8) !void {
    if (args.hasFlag(argv, "--help") or args.hasFlag(argv, "-h")) {
        try printCompletionHelp(out);
        return;
    }
    const shell = args.positional(argv, 0) orelse {
        try out.stderr("missing completion shell; expected bash, zsh, or fish\n", .{});
        std.process.exit(2);
    };
    if (std.mem.eql(u8, shell, "help")) {
        try printCompletionHelp(out);
        return;
    }
    if (!try completion.print(allocator, out, shell)) {
        try out.stderr("unsupported completion shell: {s}; expected bash, zsh, or fish\n", .{shell});
        std.process.exit(2);
    }
}

fn printCompletionHelp(out: output.Output) !void {
    try out.stdout(
        \\Usage:
        \\  verde completion bash
        \\  verde completion zsh
        \\  verde completion fish
        \\
    , .{});
}

fn handleState(allocator: std.mem.Allocator, out: output.Output, argv: []const []const u8) !void {
    const command = args.positional(argv, 0) orelse {
        try out.stderr("missing state command\n", .{});
        std.process.exit(2);
    };
    const json = args.hasFlag(argv, "--json");
    const pref_path = try prefPath(allocator);
    defer allocator.free(pref_path);

    if (std.mem.eql(u8, command, "path")) {
        const db_path = try db_client.Client.pathForPrefPath(allocator, pref_path);
        defer allocator.free(db_path);
        if (json) {
            try out.jsonValue(allocator, .{ .pref_path = pref_path, .state_path = db_path });
        } else {
            try out.stdout("{s}\n", .{db_path});
        }
        return;
    }

    var client = try db_client.Client.init(allocator, pref_path);
    defer client.deinit();
    var loaded = try client.load(allocator) orelse {
        if (json) {
            try out.jsonValue(allocator, .{ .projects = &.{} });
        } else {
            try out.stdout("No persisted Verde state found at {s}\n", .{client.path});
        }
        return;
    };
    defer loaded.deinit();

    if (std.mem.eql(u8, command, "projects")) {
        try writeStateProjects(allocator, out, loaded.value, json);
    } else if (std.mem.eql(u8, command, "panes")) {
        const project_index = try resolvePersistedProject(out, loaded.value, args.optionValue(argv, "--project") orelse "current");
        try writeStatePanes(allocator, out, loaded.value, project_index, json);
    } else if (std.mem.eql(u8, command, "threads")) {
        const project_index = try resolvePersistedProject(out, loaded.value, args.optionValue(argv, "--project") orelse "current");
        try writeStateThreads(allocator, out, loaded.value, project_index, json);
    } else if (std.mem.eql(u8, command, "transcript")) {
        const project_index = try resolvePersistedProject(out, loaded.value, args.optionValue(argv, "--project") orelse "current");
        const thread_ref = args.optionValue(argv, "--thread") orelse {
            try out.stderr("state transcript requires --thread\n", .{});
            std.process.exit(2);
        };
        try writeStateTranscript(allocator, out, loaded.value, project_index, thread_ref, json);
    } else {
        try out.stderr("unknown state command: {s}\n", .{command});
        std.process.exit(2);
    }
}

fn handleLive(allocator: std.mem.Allocator, out: output.Output, io: std.Io, argv: []const []const u8) !void {
    const command = args.positional(argv, 0) orelse {
        try out.stderr("missing live command\n", .{});
        std.process.exit(2);
    };
    const json = args.hasFlag(argv, "--json");
    if (std.mem.eql(u8, command, "capabilities")) {
        try printCapabilities(allocator, out, json);
        return;
    }
    if (std.mem.eql(u8, command, "status") or
        std.mem.eql(u8, command, "projects") or
        std.mem.eql(u8, command, "active") or
        std.mem.eql(u8, command, "processes"))
    {
        try sendLiveRequest(allocator, out, io, command, .{}, json);
        return;
    }
    if (std.mem.eql(u8, command, "panes") or
        std.mem.eql(u8, command, "threads") or
        std.mem.eql(u8, command, "terminals"))
    {
        try sendLiveRequest(allocator, out, io, command, .{ .project = args.optionValue(argv, "--project") }, json);
        return;
    }
    if (std.mem.eql(u8, command, "inspect")) {
        try sendLiveRequest(allocator, out, io, "inspect", commonPaneParams(argv), json);
        return;
    }
    if (std.mem.eql(u8, command, "pane")) {
        try handleLivePane(allocator, out, io, argv, json);
        return;
    }
    if (std.mem.eql(u8, command, "chat")) {
        try handleLiveChat(allocator, out, io, argv, json);
        return;
    }
    if (std.mem.eql(u8, command, "browser")) {
        try handleLiveBrowser(allocator, out, io, argv, json);
        return;
    }
    if (std.mem.eql(u8, command, "terminal")) {
        try handleLiveTerminal(allocator, out, io, argv, json);
        return;
    }
    if (std.mem.eql(u8, command, "process")) {
        try handleLiveProcess(allocator, out, io, argv, json);
        return;
    }
    if (std.mem.eql(u8, command, "stack")) {
        try handleLiveStack(allocator, out, io, argv, json);
        return;
    }
    try out.stderr("unknown live command: {s}\n", .{command});
    std.process.exit(2);
}

fn handleLivePane(allocator: std.mem.Allocator, out: output.Output, io: std.Io, argv: []const []const u8, json: bool) !void {
    const subcommand = args.positional(argv, 1) orelse {
        try out.stderr("missing live pane command\n", .{});
        std.process.exit(2);
    };
    if (std.mem.eql(u8, subcommand, "split")) {
        try sendLiveRequest(allocator, out, io, "pane.split", .{
            .project = args.optionValue(argv, "--project"),
            .pane = try paneOption(out, argv),
            .focused = args.hasFlag(argv, "--focused"),
            .kind = args.optionValue(argv, "--kind") orelse "chat",
            .axis = args.optionValue(argv, "--axis") orelse "horizontal",
        }, json);
        return;
    }
    if (std.mem.eql(u8, subcommand, "resize")) {
        try sendLiveRequest(allocator, out, io, "pane.resize", .{
            .project = args.optionValue(argv, "--project"),
            .pane = try paneOption(out, argv),
            .focused = args.hasFlag(argv, "--focused"),
            .first = try requiredIntOption(out, argv, "--first"),
            .second = try requiredIntOption(out, argv, "--second"),
            .axis = args.optionValue(argv, "--axis") orelse "horizontal",
            .ratio = try requiredFloatOption(out, argv, "--ratio"),
        }, json);
        return;
    }
    const method = try std.fmt.allocPrint(allocator, "pane.{s}", .{subcommand});
    defer allocator.free(method);
    try sendLiveRequest(allocator, out, io, method, commonPaneParams(argv), json);
}

fn handleLiveChat(allocator: std.mem.Allocator, out: output.Output, io: std.Io, argv: []const []const u8, json: bool) !void {
    const subcommand = args.positional(argv, 1) orelse {
        try out.stderr("missing live chat command\n", .{});
        std.process.exit(2);
    };
    if (std.mem.eql(u8, subcommand, "draft")) {
        const draft_command = args.positional(argv, 2) orelse {
            try out.stderr("missing live chat draft command\n", .{});
            std.process.exit(2);
        };
        const method = if (std.mem.eql(u8, draft_command, "set"))
            "chat.draft.set"
        else if (std.mem.eql(u8, draft_command, "append"))
            "chat.draft.append"
        else {
            try out.stderr("unknown live chat draft command: {s}\n", .{draft_command});
            std.process.exit(2);
        };
        try sendLiveRequest(allocator, out, io, method, .{
            .project = args.optionValue(argv, "--project"),
            .pane = try paneOption(out, argv),
            .focused = args.hasFlag(argv, "--focused"),
            .text = args.optionValue(argv, "--text") orelse trailingFreeArg(argv, 3) orelse "",
        }, json);
        return;
    }
    if (std.mem.eql(u8, subcommand, "send") or std.mem.eql(u8, subcommand, "followup")) {
        const prompt = args.optionValue(argv, "--prompt") orelse args.optionValue(argv, "--text") orelse trailingFreeArg(argv, 2);
        const method = if (std.mem.eql(u8, subcommand, "send")) "chat.send" else "chat.followup";
        try sendLiveRequest(allocator, out, io, method, .{
            .project = args.optionValue(argv, "--project"),
            .pane = try paneOption(out, argv),
            .focused = args.hasFlag(argv, "--focused"),
            .prompt = prompt,
        }, json);
        return;
    }
    if (std.mem.eql(u8, subcommand, "approve")) {
        try sendLiveRequest(allocator, out, io, "chat.approve", .{
            .project = args.optionValue(argv, "--project"),
            .pane = try paneOption(out, argv),
            .focused = args.hasFlag(argv, "--focused"),
            .call_id = args.optionValue(argv, "--call"),
            .decision = args.optionValue(argv, "--decision") orelse "approve",
        }, json);
        return;
    }
    const method = try std.fmt.allocPrint(allocator, "chat.{s}", .{subcommand});
    defer allocator.free(method);
    try sendLiveRequest(allocator, out, io, method, commonPaneParams(argv), json);
}

fn handleLiveBrowser(allocator: std.mem.Allocator, out: output.Output, io: std.Io, argv: []const []const u8, json: bool) !void {
    const subcommand = args.positional(argv, 1) orelse {
        try out.stderr("missing live browser command\n", .{});
        std.process.exit(2);
    };
    if (std.mem.eql(u8, subcommand, "eval")) {
        try sendLiveRequest(allocator, out, io, "browser.eval", .{
            .script = args.optionValue(argv, "--script") orelse trailingFreeArg(argv, 2) orelse "",
        }, json);
        return;
    }
    if (std.mem.eql(u8, subcommand, "post-json")) {
        try sendLiveRequest(allocator, out, io, "browser.postJson", .{
            .json = args.optionValue(argv, "--json-payload") orelse trailingFreeArg(argv, 2) orelse "",
        }, json);
        return;
    }
    try out.stderr("unknown live browser command: {s}\n", .{subcommand});
    std.process.exit(2);
}

fn handleLiveTerminal(allocator: std.mem.Allocator, out: output.Output, io: std.Io, argv: []const []const u8, json: bool) !void {
    const subcommand = args.positional(argv, 1) orelse {
        try out.stderr("missing live terminal command\n", .{});
        std.process.exit(2);
    };
    if (std.mem.eql(u8, subcommand, "write")) {
        try sendLiveRequest(allocator, out, io, "terminal.write", .{
            .project = args.optionValue(argv, "--project"),
            .pane = try paneOption(out, argv),
            .focused = args.hasFlag(argv, "--focused"),
            .text = args.optionValue(argv, "--text") orelse trailingFreeArg(argv, 2) orelse "",
        }, json);
        return;
    }
    if (std.mem.eql(u8, subcommand, "tail")) {
        try sendLiveRequest(allocator, out, io, "terminal.tail", .{
            .project = args.optionValue(argv, "--project"),
            .pane = try paneOption(out, argv),
            .focused = args.hasFlag(argv, "--focused"),
            .lines = parseOptionalU32(args.optionValue(argv, "--lines")),
        }, json);
        return;
    }
    if (std.mem.eql(u8, subcommand, "screen")) {
        try sendLiveRequest(allocator, out, io, "terminal.screen", commonPaneParams(argv), json);
        return;
    }
    try out.stderr("unknown live terminal command: {s}\n", .{subcommand});
    std.process.exit(2);
}

fn handleLiveProcess(allocator: std.mem.Allocator, out: output.Output, io: std.Io, argv: []const []const u8, json: bool) !void {
    const subcommand = args.positional(argv, 1) orelse {
        try out.stderr("missing live process command\n", .{});
        std.process.exit(2);
    };
    if (std.mem.eql(u8, subcommand, "inspect")) {
        try sendLiveRequest(allocator, out, io, "process.inspect", processParams(argv), json);
        return;
    }
    if (std.mem.eql(u8, subcommand, "list") or
        std.mem.eql(u8, subcommand, "start") or
        std.mem.eql(u8, subcommand, "stop") or
        std.mem.eql(u8, subcommand, "restart") or
        std.mem.eql(u8, subcommand, "logs"))
    {
        const method = try std.fmt.allocPrint(allocator, "process.{s}", .{subcommand});
        defer allocator.free(method);
        try sendLiveRequest(allocator, out, io, method, processParams(argv), json);
        return;
    }
    const method = try std.fmt.allocPrint(allocator, "process.{s}", .{subcommand});
    defer allocator.free(method);
    try sendLiveRequest(allocator, out, io, method, commonPaneParams(argv), json);
}

fn handleLiveStack(allocator: std.mem.Allocator, out: output.Output, io: std.Io, argv: []const []const u8, json: bool) !void {
    const subcommand = args.positional(argv, 1) orelse {
        try out.stderr("missing live stack command\n", .{});
        std.process.exit(2);
    };
    if (std.mem.eql(u8, subcommand, "status") or
        std.mem.eql(u8, subcommand, "start") or
        std.mem.eql(u8, subcommand, "stop") or
        std.mem.eql(u8, subcommand, "restart"))
    {
        const method = try std.fmt.allocPrint(allocator, "stack.{s}", .{subcommand});
        defer allocator.free(method);
        try sendLiveRequest(allocator, out, io, method, .{ .project = args.optionValue(argv, "--project") }, json);
        return;
    }
    try out.stderr("unknown live stack command: {s}\n", .{subcommand});
    std.process.exit(2);
}

fn sendLiveRequest(allocator: std.mem.Allocator, out: output.Output, io: std.Io, method: []const u8, params: anytype, json: bool) !void {
    const response = sendLiveRequestAlloc(allocator, io, method, params, 1) catch |err| {
        liveUnavailable(out, err);
    };
    defer allocator.free(response);
    if (json) {
        try out.stdout("{s}\n", .{response});
    } else {
        try printLiveResponse(out, response);
    }
}

fn sendLiveRequestAlloc(allocator: std.mem.Allocator, _: std.Io, method: []const u8, params: anytype, request_id: u64) ![]u8 {
    var threaded = std.Io.Threaded.init_single_threaded;
    const live_io = threaded.io();
    const pref_path = try prefPath(allocator);
    defer allocator.free(pref_path);
    const socket_path = try std.fs.path.join(allocator, &.{ pref_path, SOCKET_NAME });
    defer allocator.free(socket_path);

    var request_writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer request_writer.deinit();
    var s: std.json.Stringify = .{ .writer = &request_writer.writer, .options = .{} };
    try s.beginObject();
    try s.objectField("id");
    try s.write(request_id);
    try s.objectField("method");
    try s.write(method);
    try s.objectField("params");
    try s.write(params);
    try s.endObject();
    const request_json = try request_writer.toOwnedSlice();
    defer allocator.free(request_json);

    const address = try std.Io.net.UnixAddress.init(socket_path);
    const stream = try address.connect(live_io);
    defer stream.close(live_io);

    var write_buffer: [64 * 1024]u8 = undefined;
    var writer = stream.writer(live_io, &write_buffer);
    try writer.interface.writeAll(request_json);
    try writer.interface.writeByte('\n');
    try writer.interface.flush();

    var read_buffer: [256 * 1024]u8 = undefined;
    var reader = stream.reader(live_io, &read_buffer);
    const line = try reader.interface.takeDelimiter('\n') orelse return error.ConnectionAborted;
    const response = std.mem.trim(u8, line, "\r");
    return try allocator.dupe(u8, response);
}

fn printLiveResponse(out: output.Output, response: []const u8) !void {
    try out.stdout("{s}\n", .{response});
}

fn handleMcp(allocator: std.mem.Allocator, out: output.Output, io: std.Io) !void {
    const stdin_file = std.Io.File.stdin();
    var read_buffer: [256 * 1024]u8 = undefined;
    var reader = stdin_file.reader(io, &read_buffer);
    while (true) {
        const maybe_line = try reader.interface.takeDelimiter('\n');
        const raw_line = maybe_line orelse break;
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch |err| {
            try mcpError(allocator, out, .null, -32700, @errorName(err));
            continue;
        };
        defer parsed.deinit();
        if (parsed.value != .object) {
            try mcpError(allocator, out, .null, -32600, "request must be an object");
            continue;
        }
        const id_value = parsed.value.object.get("id") orelse .null;
        const method = jsonString(parsed.value.object.get("method") orelse .null) orelse {
            try mcpError(allocator, out, id_value, -32600, "missing method");
            continue;
        };
        const params = parsed.value.object.get("params") orelse .null;

        if (std.mem.eql(u8, method, "initialize")) {
            try mcpInitialize(allocator, out, id_value);
        } else if (std.mem.eql(u8, method, "tools/list")) {
            try mcpToolsList(allocator, out, id_value);
        } else if (std.mem.eql(u8, method, "tools/call")) {
            try mcpToolsCall(allocator, out, io, id_value, params);
        } else if (std.mem.eql(u8, method, "notifications/initialized")) {
            continue;
        } else {
            try mcpError(allocator, out, id_value, -32601, "method not found");
        }
    }
}

fn mcpInitialize(allocator: std.mem.Allocator, out: output.Output, id_value: std.json.Value) !void {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    defer writer.deinit();
    var s: std.json.Stringify = .{ .writer = &writer.writer, .options = .{} };
    try mcpBeginResult(&s, id_value);
    try s.beginObject();
    try s.objectField("protocolVersion");
    try s.write("2024-11-05");
    try s.objectField("capabilities");
    try s.beginObject();
    try s.objectField("tools");
    try s.beginObject();
    try s.endObject();
    try s.endObject();
    try s.objectField("serverInfo");
    try s.beginObject();
    try s.objectField("name");
    try s.write("verde");
    try s.objectField("version");
    try s.write(VERSION);
    try s.endObject();
    try s.endObject();
    try s.endObject();
    try out.stdout("{s}\n", .{writer.written()});
}

fn mcpToolsList(allocator: std.mem.Allocator, out: output.Output, id_value: std.json.Value) !void {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    defer writer.deinit();
    var s: std.json.Stringify = .{ .writer = &writer.writer, .options = .{} };
    try mcpBeginResult(&s, id_value);
    try s.beginObject();
    try s.objectField("tools");
    try s.beginArray();
    try writeMcpTool(&s, "list_processes", "List configured Verde processes.");
    try writeMcpTool(&s, "inspect_process", "Inspect a configured Verde process.");
    try writeMcpTool(&s, "tail_process_logs", "Read recent output for a configured Verde process.");
    try writeMcpTool(&s, "restart_process", "Restart a configured Verde process.");
    try writeMcpTool(&s, "stop_process", "Stop a configured Verde process.");
    try writeMcpTool(&s, "start_process", "Start a configured Verde process.");
    try s.endArray();
    try s.endObject();
    try s.endObject();
    try out.stdout("{s}\n", .{writer.written()});
}

fn writeMcpTool(s: *std.json.Stringify, name: []const u8, description: []const u8) !void {
    try s.beginObject();
    try s.objectField("name");
    try s.write(name);
    try s.objectField("description");
    try s.write(description);
    try s.objectField("inputSchema");
    try s.beginObject();
    try s.objectField("type");
    try s.write("object");
    try s.objectField("additionalProperties");
    try s.write(true);
    try s.endObject();
    try s.endObject();
}

fn mcpToolsCall(allocator: std.mem.Allocator, out: output.Output, io: std.Io, id_value: std.json.Value, params: std.json.Value) !void {
    if (params != .object) return try mcpError(allocator, out, id_value, -32602, "tools/call params must be an object");
    const tool_name = jsonString(params.object.get("name") orelse .null) orelse
        return try mcpError(allocator, out, id_value, -32602, "tools/call requires name");
    const arguments = params.object.get("arguments") orelse .null;
    const project = mcpArgString(arguments, "project");
    const process_name = mcpArgString(arguments, "name");
    const lines = mcpArgU32(arguments, "lines");

    const response = blk: {
        if (std.mem.eql(u8, tool_name, "list_processes")) {
            break :blk sendLiveRequestAlloc(allocator, io, "processes", .{ .project = project }, 1);
        }
        if (std.mem.eql(u8, tool_name, "inspect_process")) {
            const name = process_name orelse return try mcpError(allocator, out, id_value, -32602, "inspect_process requires name");
            break :blk sendLiveRequestAlloc(allocator, io, "process.inspect", .{ .project = project, .name = name }, 1);
        }
        if (std.mem.eql(u8, tool_name, "tail_process_logs")) {
            const name = process_name orelse return try mcpError(allocator, out, id_value, -32602, "tail_process_logs requires name");
            break :blk sendLiveRequestAlloc(allocator, io, "process.logs", .{ .project = project, .name = name, .lines = lines }, 1);
        }
        if (std.mem.eql(u8, tool_name, "restart_process")) {
            const name = process_name orelse return try mcpError(allocator, out, id_value, -32602, "restart_process requires name");
            break :blk sendLiveRequestAlloc(allocator, io, "process.restart", .{ .project = project, .name = name }, 1);
        }
        if (std.mem.eql(u8, tool_name, "stop_process")) {
            const name = process_name orelse return try mcpError(allocator, out, id_value, -32602, "stop_process requires name");
            break :blk sendLiveRequestAlloc(allocator, io, "process.stop", .{ .project = project, .name = name }, 1);
        }
        if (std.mem.eql(u8, tool_name, "start_process")) {
            const name = process_name orelse return try mcpError(allocator, out, id_value, -32602, "start_process requires name");
            break :blk sendLiveRequestAlloc(allocator, io, "process.start", .{ .project = project, .name = name }, 1);
        }
        return try mcpError(allocator, out, id_value, -32602, "unknown tool");
    } catch |err| {
        return try mcpError(allocator, out, id_value, -32000, @errorName(err));
    };
    defer allocator.free(response);
    try mcpToolTextResult(allocator, out, id_value, response);
}

fn mcpToolTextResult(allocator: std.mem.Allocator, out: output.Output, id_value: std.json.Value, text: []const u8) !void {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    defer writer.deinit();
    var s: std.json.Stringify = .{ .writer = &writer.writer, .options = .{} };
    try mcpBeginResult(&s, id_value);
    try s.beginObject();
    try s.objectField("content");
    try s.beginArray();
    try s.beginObject();
    try s.objectField("type");
    try s.write("text");
    try s.objectField("text");
    try s.write(text);
    try s.endObject();
    try s.endArray();
    try s.endObject();
    try s.endObject();
    try out.stdout("{s}\n", .{writer.written()});
}

fn mcpError(allocator: std.mem.Allocator, out: output.Output, id_value: std.json.Value, code: i32, message: []const u8) !void {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    defer writer.deinit();
    var s: std.json.Stringify = .{ .writer = &writer.writer, .options = .{} };
    try s.beginObject();
    try s.objectField("jsonrpc");
    try s.write("2.0");
    try s.objectField("id");
    try writeJsonValue(&s, id_value);
    try s.objectField("error");
    try s.beginObject();
    try s.objectField("code");
    try s.write(code);
    try s.objectField("message");
    try s.write(message);
    try s.endObject();
    try s.endObject();
    try out.stdout("{s}\n", .{writer.written()});
}

fn mcpBeginResult(s: *std.json.Stringify, id_value: std.json.Value) !void {
    try s.beginObject();
    try s.objectField("jsonrpc");
    try s.write("2.0");
    try s.objectField("id");
    try writeJsonValue(s, id_value);
    try s.objectField("result");
}

fn mcpArgString(arguments: std.json.Value, name: []const u8) ?[]const u8 {
    if (arguments != .object) return null;
    return jsonString(arguments.object.get(name) orelse .null);
}

fn mcpArgU32(arguments: std.json.Value, name: []const u8) ?u32 {
    if (arguments != .object) return null;
    const value = arguments.object.get(name) orelse .null;
    return switch (value) {
        .integer => |int| if (int >= 0) @intCast(int) else null,
        .number_string => |text| std.fmt.parseInt(u32, text, 10) catch null,
        else => null,
    };
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

fn jsonString(value: std.json.Value) ?[]const u8 {
    return switch (value) {
        .string => |text| text,
        else => null,
    };
}

fn liveUnavailable(out: output.Output, err: anyerror) noreturn {
    out.stderr("verde live server is not running: {s}\n", .{@errorName(err)}) catch {};
    std.process.exit(3);
}

fn commonPaneParams(argv: []const []const u8) struct { project: ?[]const u8, pane: ?u32, focused: bool } {
    return .{
        .project = args.optionValue(argv, "--project"),
        .pane = parseOptionalU32(args.optionValue(argv, "--pane")),
        .focused = args.hasFlag(argv, "--focused"),
    };
}

fn processParams(argv: []const []const u8) struct { project: ?[]const u8, pane: ?u32, focused: bool, name: ?[]const u8, lines: ?u32 } {
    return .{
        .project = args.optionValue(argv, "--project"),
        .pane = parseOptionalU32(args.optionValue(argv, "--pane")),
        .focused = args.hasFlag(argv, "--focused"),
        .name = args.optionValue(argv, "--name"),
        .lines = parseOptionalU32(args.optionValue(argv, "--lines")),
    };
}

fn paneOption(out: output.Output, argv: []const []const u8) !?u32 {
    if (args.hasFlag(argv, "--focused")) return null;
    const value = args.optionValue(argv, "--pane") orelse {
        try out.stderr("missing --pane or --focused\n", .{});
        std.process.exit(2);
    };
    return std.fmt.parseInt(u32, value, 10) catch {
        try out.stderr("invalid --pane value: {s}\n", .{value});
        std.process.exit(2);
    };
}

fn requiredIntOption(out: output.Output, argv: []const []const u8, name: []const u8) !u32 {
    const value = args.optionValue(argv, name) orelse {
        try out.stderr("missing {s}\n", .{name});
        std.process.exit(2);
    };
    return std.fmt.parseInt(u32, value, 10) catch {
        try out.stderr("invalid {s} value: {s}\n", .{ name, value });
        std.process.exit(2);
    };
}

fn requiredFloatOption(out: output.Output, argv: []const []const u8, name: []const u8) !f32 {
    const value = args.optionValue(argv, name) orelse {
        try out.stderr("missing {s}\n", .{name});
        std.process.exit(2);
    };
    return std.fmt.parseFloat(f32, value) catch {
        try out.stderr("invalid {s} value: {s}\n", .{ name, value });
        std.process.exit(2);
    };
}

fn parseOptionalU32(value: ?[]const u8) ?u32 {
    const raw = value orelse return null;
    return std.fmt.parseInt(u32, raw, 10) catch null;
}

fn trailingFreeArg(argv: []const []const u8, positional_commands: usize) ?[]const u8 {
    var seen_commands: usize = 0;
    var skip_option_value = false;
    var trailing: ?[]const u8 = null;
    for (argv) |arg| {
        if (skip_option_value) {
            skip_option_value = false;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--")) {
            if (optionConsumesValue(arg)) skip_option_value = true;
            continue;
        }
        if (seen_commands < positional_commands) {
            seen_commands += 1;
            continue;
        }
        trailing = arg;
    }
    return trailing;
}

fn optionConsumesValue(name: []const u8) bool {
    return std.mem.eql(u8, name, "--project") or
        std.mem.eql(u8, name, "--pane") or
        std.mem.eql(u8, name, "--kind") or
        std.mem.eql(u8, name, "--axis") or
        std.mem.eql(u8, name, "--first") or
        std.mem.eql(u8, name, "--second") or
        std.mem.eql(u8, name, "--ratio") or
        std.mem.eql(u8, name, "--text") or
        std.mem.eql(u8, name, "--prompt") or
        std.mem.eql(u8, name, "--call") or
        std.mem.eql(u8, name, "--decision") or
        std.mem.eql(u8, name, "--name") or
        std.mem.eql(u8, name, "--lines") or
        std.mem.eql(u8, name, "--thread");
}

fn writeStateProjects(allocator: std.mem.Allocator, out: output.Output, state: db_types.PersistedState, json: bool) !void {
    if (json) {
        try out.jsonValue(allocator, state.projects);
        return;
    }
    try out.stdout("INDEX  ID  LABEL  PATH\n", .{});
    for (state.projects, 0..) |project, index| {
        try out.stdout("{d}  {s}  {s}  {s}\n", .{
            index,
            project.id orelse "",
            project.label,
            project.path,
        });
    }
}

fn writeStatePanes(allocator: std.mem.Allocator, out: output.Output, state: db_types.PersistedState, project_index: usize, json: bool) !void {
    const project = state.projects[project_index];
    if (json) {
        try out.jsonValue(allocator, .{
            .project = project.id orelse project.path,
            .workspace_layout_json = project.workspace_layout_json,
            .terminal_docks_json = project.terminal_docks_json,
            .live = false,
        });
        return;
    }
    try out.stdout("Project: {s}\n", .{project.label});
    if (project.workspace_layout_json) |layout| {
        try out.stdout("{s}\n", .{layout});
    } else {
        try out.stdout("No persisted workspace layout.\n", .{});
    }
}

fn writeStateThreads(allocator: std.mem.Allocator, out: output.Output, state: db_types.PersistedState, project_index: usize, json: bool) !void {
    const project = state.projects[project_index];
    const threads = project.threads orelse &.{};
    if (json) {
        try out.jsonValue(allocator, threads);
        return;
    }
    try out.stdout("INDEX  PROVIDER_THREAD_ID  TITLE\n", .{});
    for (threads, 0..) |thread, index| {
        try out.stdout("{d}  {s}  {s}\n", .{ index, thread.provider_thread_id orelse "", thread.title });
    }
}

fn writeStateTranscript(
    allocator: std.mem.Allocator,
    out: output.Output,
    state: db_types.PersistedState,
    project_index: usize,
    thread_ref: []const u8,
    json: bool,
) !void {
    const project = state.projects[project_index];
    const threads = project.threads orelse &.{};
    const thread_index = resolvePersistedThread(threads, thread_ref) orelse {
        try out.stderr("thread not found: {s}\n", .{thread_ref});
        std.process.exit(4);
    };
    const thread = threads[thread_index];
    if (json) {
        try out.jsonValue(allocator, .{
            .project = project.id orelse project.path,
            .thread_index = thread_index,
            .thread = thread,
        });
        return;
    }
    try out.stdout("# {s}\n\n", .{thread.title});
    for (thread.messages) |message| {
        try out.stdout("## {s}\n{s}\n\n", .{ message.author, message.body });
    }
}

fn resolvePersistedProject(out: output.Output, state: db_types.PersistedState, ref: []const u8) !usize {
    if (state.projects.len == 0) {
        try out.stderr("no projects in persisted state\n", .{});
        std.process.exit(4);
    }
    if (std.mem.eql(u8, ref, "current")) return @min(state.selected_project_index, state.projects.len - 1);
    if (std.fmt.parseInt(usize, ref, 10)) |index| {
        if (index < state.projects.len) return index;
    } else |_| {}
    for (state.projects, 0..) |project, index| {
        if (project.id) |id| {
            if (std.mem.eql(u8, id, ref)) return index;
        }
        if (std.mem.eql(u8, project.path, ref)) return index;
    }
    try out.stderr("project not found: {s}\n", .{ref});
    std.process.exit(4);
}

fn resolvePersistedThread(threads: []const db_types.PersistedThread, ref: []const u8) ?usize {
    if (std.fmt.parseInt(usize, ref, 10)) |index| {
        if (index < threads.len) return index;
    } else |_| {}
    for (threads, 0..) |thread, index| {
        if (thread.provider_thread_id) |provider_thread_id| {
            if (std.mem.eql(u8, provider_thread_id, ref)) return index;
        }
    }
    return null;
}

fn prefPath(allocator: std.mem.Allocator) ![]u8 {
    return switch (builtin.os.tag) {
        .linux, .freebsd, .openbsd, .netbsd => blk: {
            if (envVarOwned(allocator, "XDG_DATA_HOME")) |xdg| {
                defer allocator.free(xdg);
                break :blk try std.fs.path.join(allocator, &.{ xdg, "verde", "Native" });
            } else |_| {}
            const home = try envVarOwned(allocator, "HOME");
            defer allocator.free(home);
            break :blk try std.fs.path.join(allocator, &.{ home, ".local", "share", "verde", "Native" });
        },
        .macos => blk: {
            const home = try envVarOwned(allocator, "HOME");
            defer allocator.free(home);
            break :blk try std.fs.path.join(allocator, &.{ home, "Library", "Application Support", "verde", "Native" });
        },
        else => try std.fs.path.join(allocator, &.{ ".", "verde", "Native" }),
    };
}

fn envVarOwned(allocator: std.mem.Allocator, comptime name: [:0]const u8) ![]u8 {
    const value_ptr = std.c.getenv(name.ptr) orelse return error.EnvironmentVariableNotFound;
    return try allocator.dupe(u8, std.mem.sliceTo(value_ptr, 0));
}

test "cli args parse command and json flag" {
    const argv = [_][]const u8{ "verde", "state", "projects", "--json" };
    const parsed = args.parse(&argv);
    try std.testing.expectEqualStrings("state", parsed.command);
    try std.testing.expect(parsed.json);
}
