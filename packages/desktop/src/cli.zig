const std = @import("std");
const builtin = @import("builtin");

const args = @import("cli_args.zig");
const completion = @import("cli_completion.zig");
const output = @import("cli_output.zig");
const spec = @import("cli_spec.zig");
const db_client = @import("db/client.zig");
const db_types = @import("db/types.zig");
const sessionizer = @import("terminal/sessionizer.zig");

const VERSION = "0.0.0";
const SOCKET_NAME = "verde.sock";
const TERMINAL_GET_WINSIZE_IOCTL: c_int = switch (builtin.os.tag) {
    .macos => @bitCast(@as(u32, 0x40087468)),
    else => @intCast(std.c.T.IOCGWINSZ),
};

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
    if (std.mem.eql(u8, parsed.command, "__session-daemon")) {
        const pref_path = try prefPath(allocator);
        defer allocator.free(pref_path);
        try sessionizer.runDaemon(allocator, pref_path);
        return .handled;
    }
    if (std.mem.eql(u8, parsed.command, "session")) {
        try handleSession(allocator, out, io, argv[0], parsed.rest);
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
        \\  verde session <command>       Manage persistent terminal sessions
        \\  verde live <command>          Talk to the running app
        \\  verde mcp                     Run the stdio MCP bridge
        \\
        \\State commands:
        \\  path
        \\  workspaces [--json]
        \\  panes --workspace <id|index|current> [--json]
        \\  threads --workspace <id|index|current> [--json]
        \\  transcript --workspace <id|index|current> --thread <index|provider-id> [--json]
        \\
        \\Session commands:
        \\  list [--json]
        \\  inspect --id <session-id> [--json]
        \\  new --workspace <id|index|current> [--name <name>] [-- <command>...]
        \\  attach --id <session-id>
        \\  attach --workspace <id|index|current> --pane <pane-id>
        \\  write --id <session-id> --text <text>
        \\  tail --id <session-id> [--lines <n>] [--json]
        \\  screen --id <session-id> [--json]
        \\  kill --id <session-id>
        \\  cleanup
        \\
        \\Live commands:
        \\  status [--json]
        \\  capabilities [--json]
        \\  workspaces [--json]
        \\  panes [--workspace <id|index|current>] [--json]
        \\  active [--json]
        \\  threads [--workspace <id|index|current>] [--json]
        \\  terminals [--workspace <id|index|current>] [--json]
        \\  inspect --pane <id> [--workspace <id|index|current>] [--json]
        \\  pane focus|split|resize|minimize|maximize|restore|close ...
        \\  chat status|transcript|send|followup|stop|approve|draft ...
        \\  browser open|close|toggle|back|forward|reload|eval|post-json|inspector-* ...
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
            .session = spec.session_commands[0..],
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
        \\  state: path, workspaces, panes, threads, transcript
        \\  session: list, inspect, new, attach, write, tail, screen, kill, cleanup
        \\  live: status, workspaces, panes, pane control, chat control, terminal/process control
        \\  completion: bash, zsh, fish
        \\  encodings: json, jsonl
        \\  terminal binary frames: no
        \\
    , .{});
}

fn workspaceOption(argv: []const []const u8) ?[]const u8 {
    return args.optionValue(argv, "--workspace") orelse args.optionValue(argv, "--project");
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
            try out.jsonValue(allocator, .{ .workspaces = &.{} });
        } else {
            try out.stdout("No persisted Verde state found at {s}\n", .{client.path});
        }
        return;
    };
    defer loaded.deinit();

    if (std.mem.eql(u8, command, "workspaces") or std.mem.eql(u8, command, "projects")) {
        try writeStateProjects(allocator, out, loaded.value, json);
    } else if (std.mem.eql(u8, command, "panes")) {
        const project_index = try resolvePersistedProject(out, loaded.value, workspaceOption(argv) orelse "current");
        try writeStatePanes(allocator, out, loaded.value, project_index, json);
    } else if (std.mem.eql(u8, command, "threads")) {
        const project_index = try resolvePersistedProject(out, loaded.value, workspaceOption(argv) orelse "current");
        try writeStateThreads(allocator, out, loaded.value, project_index, json);
    } else if (std.mem.eql(u8, command, "transcript")) {
        const project_index = try resolvePersistedProject(out, loaded.value, workspaceOption(argv) orelse "current");
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

const PersistedSessionRef = struct {
    session_id: []const u8,
    workspace_index: usize,
    workspace_id: []const u8,
    workspace_path: []const u8,
    dock_id: u32,
    pane_id: u32,
    label: []const u8 = "",
    revive_policy: []const u8 = "attach_or_create",
    daemon_status: []const u8 = "metadata_only",
};

fn handleSession(allocator: std.mem.Allocator, out: output.Output, io: std.Io, exe_path: []const u8, argv: []const []const u8) !void {
    const command = args.positional(argv, 0) orelse {
        try out.stderr("missing session command\n", .{});
        std.process.exit(2);
    };
    const json = args.hasFlag(argv, "--json");

    if (std.mem.eql(u8, command, "list")) {
        if (sendSessionRequestAlloc(allocator, io, "session.list", .{}, 1)) |response| {
            defer allocator.free(response);
            try out.stdout("{s}\n", .{response});
            return;
        } else |_| {}
    }

    if (std.mem.eql(u8, command, "inspect")) {
        const wanted_id = args.optionValue(argv, "--id") orelse {
            try out.stderr("session inspect requires --id\n", .{});
            std.process.exit(2);
        };
        if (sendSessionRequestAlloc(allocator, io, "session.inspect", .{ .id = wanted_id }, 1)) |response| {
            defer allocator.free(response);
            try out.stdout("{s}\n", .{response});
            return;
        } else |_| {}
    }

    if (std.mem.eql(u8, command, "list") or std.mem.eql(u8, command, "inspect")) {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const arena_allocator = arena.allocator();

        const pref_path = try prefPath(allocator);
        defer allocator.free(pref_path);
        var client = try db_client.Client.init(allocator, pref_path);
        defer client.deinit();
        var loaded = try client.load(allocator) orelse {
            if (json) {
                try out.jsonValue(allocator, .{ .daemon_running = false, .sessions = &.{} });
            } else {
                try out.stdout("No persisted Verde state found at {s}\n", .{client.path});
            }
            return;
        };
        defer loaded.deinit();

        const sessions = try collectPersistedSessionRefs(arena_allocator, loaded.value);
        if (std.mem.eql(u8, command, "list")) {
            if (json) {
                try out.jsonValue(allocator, .{
                    .daemon_running = false,
                    .socket_name = sessionizer.SOCKET_NAME,
                    .sessions = sessions,
                });
                return;
            }
            try out.stdout("SESSION_ID  WORKSPACE  DOCK  PANE  STATUS  LABEL\n", .{});
            for (sessions) |session| {
                try out.stdout("{s}  {s}  {d}  {d}  {s}  {s}\n", .{
                    session.session_id,
                    session.workspace_id,
                    session.dock_id,
                    session.pane_id,
                    session.daemon_status,
                    session.label,
                });
            }
            return;
        }

        const wanted_id = args.optionValue(argv, "--id") orelse {
            try out.stderr("session inspect requires --id\n", .{});
            std.process.exit(2);
        };
        for (sessions) |session| {
            if (!std.mem.eql(u8, session.session_id, wanted_id)) continue;
            if (json) {
                try out.jsonValue(allocator, .{
                    .daemon_running = false,
                    .session = session,
                });
            } else {
                try out.stdout(
                    \\Session: {s}
                    \\Workspace: {s}
                    \\Path: {s}
                    \\Dock: {d}
                    \\Pane: {d}
                    \\Status: {s}
                    \\Label: {s}
                    \\Revive policy: {s}
                    \\
                , .{
                    session.session_id,
                    session.workspace_id,
                    session.workspace_path,
                    session.dock_id,
                    session.pane_id,
                    session.daemon_status,
                    session.label,
                    session.revive_policy,
                });
            }
            return;
        }
        try out.stderr("session not found: {s}\n", .{wanted_id});
        std.process.exit(4);
    }

    if (std.mem.eql(u8, command, "new")) {
        try ensureSessionDaemon(allocator, io, exe_path);
        const session_id = try sessionIdForNewCommand(allocator, argv);
        defer allocator.free(session_id);
        const workspace_ref = workspaceOption(argv);
        const cwd = args.optionValue(argv, "--cwd") orelse workspace_ref orelse ".";
        const command_argv = commandAfterDoubleDash(argv);
        const response = try sendSessionRequestAlloc(allocator, io, "session.create", .{
            .id = session_id,
            .workspace_id = workspace_ref orelse "",
            .workspace_path = cwd,
            .cwd = cwd,
            .label = args.optionValue(argv, "--name") orelse "",
            .command = command_argv,
            .cols = parseOptionalU32(args.optionValue(argv, "--cols")) orelse sessionizer.DEFAULT_COLS,
            .rows = parseOptionalU32(args.optionValue(argv, "--rows")) orelse sessionizer.DEFAULT_ROWS,
        }, 1);
        defer allocator.free(response);
        try out.stdout("{s}\n", .{response});
        return;
    }

    if (std.mem.eql(u8, command, "attach")) {
        try handleSessionAttach(allocator, out, io, exe_path, argv);
        return;
    }

    if (std.mem.eql(u8, command, "write")) {
        try ensureSessionDaemon(allocator, io, exe_path);
        const wanted_id = args.optionValue(argv, "--id") orelse {
            try out.stderr("session write requires --id\n", .{});
            std.process.exit(2);
        };
        const text = args.optionValue(argv, "--text") orelse trailingFreeArg(argv, 1) orelse "";
        const response = try sendSessionRequestAlloc(allocator, io, "session.write", .{ .id = wanted_id, .text = text }, 1);
        defer allocator.free(response);
        try out.stdout("{s}\n", .{response});
        return;
    }

    if (std.mem.eql(u8, command, "tail") or std.mem.eql(u8, command, "screen")) {
        try ensureSessionDaemon(allocator, io, exe_path);
        const wanted_id = args.optionValue(argv, "--id") orelse {
            try out.stderr("session {s} requires --id\n", .{command});
            std.process.exit(2);
        };
        const method = if (std.mem.eql(u8, command, "screen")) "session.screen" else "session.tail";
        const response = try sendSessionRequestAlloc(allocator, io, method, .{
            .id = wanted_id,
            .lines = parseOptionalU32(args.optionValue(argv, "--lines")),
        }, 1);
        defer allocator.free(response);
        try out.stdout("{s}\n", .{response});
        return;
    }

    if (std.mem.eql(u8, command, "kill")) {
        try ensureSessionDaemon(allocator, io, exe_path);
        const wanted_id = args.optionValue(argv, "--id") orelse {
            try out.stderr("session kill requires --id\n", .{});
            std.process.exit(2);
        };
        const response = try sendSessionRequestAlloc(allocator, io, "session.kill", .{ .id = wanted_id }, 1);
        defer allocator.free(response);
        try out.stdout("{s}\n", .{response});
        return;
    }

    if (std.mem.eql(u8, command, "cleanup")) {
        try ensureSessionDaemon(allocator, io, exe_path);
        const response = try sendSessionRequestAlloc(allocator, io, "session.cleanup", .{}, 1);
        defer allocator.free(response);
        try out.stdout("{s}\n", .{response});
        return;
    }

    try out.stderr("unknown session command: {s}\n", .{command});
    std.process.exit(2);
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
        std.mem.eql(u8, command, "workspaces") or
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
        try sendLiveRequest(allocator, out, io, command, .{ .workspace = workspaceOption(argv) }, json);
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
            .workspace = workspaceOption(argv),
            .pane = try paneOption(out, argv),
            .focused = args.hasFlag(argv, "--focused"),
            .kind = args.optionValue(argv, "--kind") orelse "chat",
            .axis = args.optionValue(argv, "--axis") orelse "horizontal",
        }, json);
        return;
    }
    if (std.mem.eql(u8, subcommand, "resize")) {
        try sendLiveRequest(allocator, out, io, "pane.resize", .{
            .workspace = workspaceOption(argv),
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
            .workspace = workspaceOption(argv),
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
            .workspace = workspaceOption(argv),
            .pane = try paneOption(out, argv),
            .focused = args.hasFlag(argv, "--focused"),
            .prompt = prompt,
        }, json);
        return;
    }
    if (std.mem.eql(u8, subcommand, "approve")) {
        try sendLiveRequest(allocator, out, io, "chat.approve", .{
            .workspace = workspaceOption(argv),
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
    if (std.mem.eql(u8, subcommand, "open")) {
        try sendLiveRequest(allocator, out, io, "browser.open", .{}, json);
        return;
    }
    if (std.mem.eql(u8, subcommand, "close")) {
        try sendLiveRequest(allocator, out, io, "browser.close", .{}, json);
        return;
    }
    if (std.mem.eql(u8, subcommand, "toggle")) {
        try sendLiveRequest(allocator, out, io, "browser.toggle", .{}, json);
        return;
    }
    if (std.mem.eql(u8, subcommand, "back")) {
        try sendLiveRequest(allocator, out, io, "browser.back", .{}, json);
        return;
    }
    if (std.mem.eql(u8, subcommand, "forward")) {
        try sendLiveRequest(allocator, out, io, "browser.forward", .{}, json);
        return;
    }
    if (std.mem.eql(u8, subcommand, "reload")) {
        try sendLiveRequest(allocator, out, io, "browser.reload", .{}, json);
        return;
    }
    if (std.mem.eql(u8, subcommand, "focus")) {
        try sendLiveRequest(allocator, out, io, "browser.focus", .{}, json);
        return;
    }
    if (std.mem.eql(u8, subcommand, "blur")) {
        try sendLiveRequest(allocator, out, io, "browser.blur", .{}, json);
        return;
    }
    if (std.mem.eql(u8, subcommand, "toolbar-hit")) {
        try sendLiveRequest(allocator, out, io, "browser.toolbarHit", .{
            .target = args.optionValue(argv, "--target") orelse trailingFreeArg(argv, 2) orelse "",
        }, json);
        return;
    }
    if (std.mem.eql(u8, subcommand, "select-all")) {
        try sendLiveRequest(allocator, out, io, "browser.selectAllFocused", .{}, json);
        return;
    }
    if (std.mem.eql(u8, subcommand, "copy")) {
        try sendLiveRequest(allocator, out, io, "browser.copyFocused", .{}, json);
        return;
    }
    if (std.mem.eql(u8, subcommand, "cut")) {
        try sendLiveRequest(allocator, out, io, "browser.cutFocused", .{}, json);
        return;
    }
    if (std.mem.eql(u8, subcommand, "paste-text")) {
        try sendLiveRequest(allocator, out, io, "browser.pasteTextFocused", .{
            .text = args.optionValue(argv, "--text") orelse trailingFreeArg(argv, 2) orelse "",
        }, json);
        return;
    }
    if (std.mem.eql(u8, subcommand, "inspector-enable")) {
        try sendLiveRequest(allocator, out, io, "browser.inspector.enable", .{}, json);
        return;
    }
    if (std.mem.eql(u8, subcommand, "inspector-disable")) {
        try sendLiveRequest(allocator, out, io, "browser.inspector.disable", .{}, json);
        return;
    }
    if (std.mem.eql(u8, subcommand, "inspector-toggle")) {
        try sendLiveRequest(allocator, out, io, "browser.inspector.toggle", .{}, json);
        return;
    }
    if (std.mem.eql(u8, subcommand, "inspector-mode")) {
        try sendLiveRequest(allocator, out, io, "browser.inspector.mode", .{
            .mode = args.optionValue(argv, "--mode") orelse trailingFreeArg(argv, 2) orelse "",
        }, json);
        return;
    }
    if (std.mem.eql(u8, subcommand, "inspector-menu-open")) {
        try sendLiveRequest(allocator, out, io, "browser.inspector.menuOpen", .{}, json);
        return;
    }
    if (std.mem.eql(u8, subcommand, "inspector-menu-close")) {
        try sendLiveRequest(allocator, out, io, "browser.inspector.menuClose", .{}, json);
        return;
    }
    if (std.mem.eql(u8, subcommand, "workspace-menu-open")) {
        try sendLiveRequest(allocator, out, io, "browser.overlay.workspaceMenuOpen", .{}, json);
        return;
    }
    if (std.mem.eql(u8, subcommand, "workspace-menu-close")) {
        try sendLiveRequest(allocator, out, io, "browser.overlay.workspaceMenuClose", .{}, json);
        return;
    }
    if (std.mem.eql(u8, subcommand, "sidebar-menu-open")) {
        try sendLiveRequest(allocator, out, io, "browser.overlay.sidebarMenuOpen", .{}, json);
        return;
    }
    if (std.mem.eql(u8, subcommand, "sidebar-menu-close")) {
        try sendLiveRequest(allocator, out, io, "browser.overlay.sidebarMenuClose", .{}, json);
        return;
    }
    if (std.mem.eql(u8, subcommand, "composer-menu-open")) {
        try sendLiveRequest(allocator, out, io, "browser.overlay.composerMenuOpen", .{}, json);
        return;
    }
    if (std.mem.eql(u8, subcommand, "composer-menu-close")) {
        try sendLiveRequest(allocator, out, io, "browser.overlay.composerMenuClose", .{}, json);
        return;
    }
    if (std.mem.eql(u8, subcommand, "workspace-modal-open")) {
        try sendLiveRequest(allocator, out, io, "browser.overlay.workspaceModalOpen", .{}, json);
        return;
    }
    if (std.mem.eql(u8, subcommand, "workspace-modal-close")) {
        try sendLiveRequest(allocator, out, io, "browser.overlay.workspaceModalClose", .{}, json);
        return;
    }
    if (std.mem.eql(u8, subcommand, "thread-modal-open")) {
        try sendLiveRequest(allocator, out, io, "browser.overlay.threadModalOpen", .{}, json);
        return;
    }
    if (std.mem.eql(u8, subcommand, "thread-modal-close")) {
        try sendLiveRequest(allocator, out, io, "browser.overlay.threadModalClose", .{}, json);
        return;
    }
    if (std.mem.eql(u8, subcommand, "image-modal-open")) {
        try sendLiveRequest(allocator, out, io, "browser.overlay.imageModalOpen", .{}, json);
        return;
    }
    if (std.mem.eql(u8, subcommand, "image-modal-close")) {
        try sendLiveRequest(allocator, out, io, "browser.overlay.imageModalClose", .{}, json);
        return;
    }
    if (std.mem.eql(u8, subcommand, "transcript-modal-open")) {
        try sendLiveRequest(allocator, out, io, "browser.overlay.transcriptModalOpen", .{}, json);
        return;
    }
    if (std.mem.eql(u8, subcommand, "transcript-modal-close")) {
        try sendLiveRequest(allocator, out, io, "browser.overlay.transcriptModalClose", .{}, json);
        return;
    }
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
            .workspace = workspaceOption(argv),
            .pane = try paneOption(out, argv),
            .focused = args.hasFlag(argv, "--focused"),
            .text = args.optionValue(argv, "--text") orelse trailingFreeArg(argv, 2) orelse "",
        }, json);
        return;
    }
    if (std.mem.eql(u8, subcommand, "tail")) {
        try sendLiveRequest(allocator, out, io, "terminal.tail", .{
            .workspace = workspaceOption(argv),
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
        try sendLiveRequest(allocator, out, io, method, .{ .workspace = workspaceOption(argv) }, json);
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

fn sendSessionRequestAlloc(allocator: std.mem.Allocator, _: std.Io, method: []const u8, params: anytype, request_id: u64) ![]u8 {
    const pref_path = try prefPath(allocator);
    defer allocator.free(pref_path);
    return try sessionizer.requestAlloc(allocator, pref_path, method, params, request_id);
}

const SessionReadResult = struct {
    text: []u8,
    running: bool,
    next_offset: usize,

    fn deinit(self: *SessionReadResult, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        self.* = undefined;
    }
};

const AttachSize = struct {
    cols: u16,
    rows: u16,
};

fn handleSessionAttach(
    allocator: std.mem.Allocator,
    out: output.Output,
    io: std.Io,
    exe_path: []const u8,
    argv: []const []const u8,
) !void {
    try ensureSessionDaemon(allocator, io, exe_path);
    const session_id = try resolveAttachSessionId(allocator, out, argv);
    defer allocator.free(session_id);

    const attach_id = attachSessionClient(allocator, io, session_id, "verde-cli") catch null;
    defer if (attach_id) |id| allocator.free(id);
    defer if (attach_id) |id| detachSessionClient(allocator, io, session_id, id);

    const explicit_cols = parseOptionalU32(args.optionValue(argv, "--cols"));
    const explicit_rows = parseOptionalU32(args.optionValue(argv, "--rows"));
    var current_size = terminalAttachSize(explicit_cols, explicit_rows);
    const resize_response = try sendSessionRequestAlloc(allocator, io, "session.resize", .{
        .id = session_id,
        .attach_id = attach_id orelse "",
        .cols = current_size.cols,
        .rows = current_size.rows,
    }, 1);
    allocator.free(resize_response);

    const terminal_mode = enterRawMode() catch null;
    defer if (terminal_mode) |mode| restoreTerminalMode(mode);

    const stdin_nonblock: ?c_int = setFdNonBlocking(std.posix.STDIN_FILENO) catch null;
    defer if (stdin_nonblock) |flags| restoreFdFlags(std.posix.STDIN_FILENO, flags);

    var next_offset: usize = 0;
    var stdin_eof = false;
    var detach_requested = false;
    while (true) {
        if (explicit_cols == null or explicit_rows == null) {
            const next_size = terminalAttachSize(explicit_cols, explicit_rows);
            if (next_size.cols != current_size.cols or next_size.rows != current_size.rows) {
                current_size = next_size;
                const response = try sendSessionRequestAlloc(allocator, io, "session.resize", .{
                    .id = session_id,
                    .attach_id = attach_id orelse "",
                    .cols = current_size.cols,
                    .rows = current_size.rows,
                }, 1);
                allocator.free(response);
            }
        }

        try drainAttachInput(allocator, io, session_id, attach_id orelse "", &stdin_eof, &detach_requested);
        if (detach_requested) break;

        var read_result = try readSessionOutput(allocator, io, session_id, attach_id orelse "", next_offset);
        defer read_result.deinit(allocator);
        if (read_result.text.len > 0) {
            try writeStdout(read_result.text);
            next_offset = read_result.next_offset;
        } else {
            next_offset = read_result.next_offset;
        }

        if (!read_result.running and stdin_eof) break;
        if (!read_result.running and read_result.text.len == 0) break;
        try std.Io.sleep(io, .fromMilliseconds(20), .awake);
    }
}

fn attachSessionClient(allocator: std.mem.Allocator, io: std.Io, session_id: []const u8, label: []const u8) ![]u8 {
    const response = try sendSessionRequestAlloc(allocator, io, "session.attach", .{ .id = session_id, .label = label }, 1);
    defer allocator.free(response);
    return try sessionResultStringAlloc(allocator, response, "attach_id");
}

fn detachSessionClient(allocator: std.mem.Allocator, io: std.Io, session_id: []const u8, attach_id: []const u8) void {
    const response = sendSessionRequestAlloc(allocator, io, "session.detach", .{ .id = session_id, .attach_id = attach_id }, 1) catch return;
    allocator.free(response);
}

fn terminalAttachSize(explicit_cols: ?u32, explicit_rows: ?u32) AttachSize {
    const detected = readTerminalAttachSize();
    const cols = explicit_cols orelse if (detected) |size| size.cols else sessionizer.DEFAULT_COLS;
    const rows = explicit_rows orelse if (detected) |size| size.rows else sessionizer.DEFAULT_ROWS;
    return .{
        .cols = @intCast(@max(@min(cols, std.math.maxInt(u16)), 1)),
        .rows = @intCast(@max(@min(rows, std.math.maxInt(u16)), 1)),
    };
}

fn readTerminalAttachSize() ?AttachSize {
    var winsize: std.posix.winsize = undefined;
    if (std.c.ioctl(std.posix.STDOUT_FILENO, TERMINAL_GET_WINSIZE_IOCTL, &winsize) != 0 and
        std.c.ioctl(std.posix.STDIN_FILENO, TERMINAL_GET_WINSIZE_IOCTL, &winsize) != 0)
    {
        return null;
    }
    if (winsize.col == 0 or winsize.row == 0) return null;
    return .{ .cols = winsize.col, .rows = winsize.row };
}

fn resolveAttachSessionId(allocator: std.mem.Allocator, out: output.Output, argv: []const []const u8) ![]u8 {
    if (args.optionValue(argv, "--id")) |id| return allocator.dupe(u8, id);

    const pane_value = args.optionValue(argv, "--pane") orelse {
        try out.stderr("session attach requires --id or --workspace and --pane\n", .{});
        std.process.exit(2);
    };
    const pane_id = std.fmt.parseInt(u32, pane_value, 10) catch {
        try out.stderr("invalid --pane value: {s}\n", .{pane_value});
        std.process.exit(2);
    };
    const pref_path = try prefPath(allocator);
    defer allocator.free(pref_path);
    var client = try db_client.Client.init(allocator, pref_path);
    defer client.deinit();
    var loaded = try client.load(allocator) orelse {
        try out.stderr("no persisted Verde state found at {s}\n", .{client.path});
        std.process.exit(4);
    };
    defer loaded.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const sessions = try collectPersistedSessionRefs(arena.allocator(), loaded.value);
    const project_index = try resolvePersistedProject(out, loaded.value, workspaceOption(argv) orelse "current");
    for (sessions) |session| {
        if (session.workspace_index == project_index and session.pane_id == pane_id) return allocator.dupe(u8, session.session_id);
    }
    try out.stderr("session not found for workspace {d} pane {d}\n", .{ project_index, pane_id });
    std.process.exit(4);
}

fn drainAttachInput(
    allocator: std.mem.Allocator,
    io: std.Io,
    session_id: []const u8,
    attach_id: []const u8,
    stdin_eof: *bool,
    detach_requested: *bool,
) !void {
    if (stdin_eof.*) return;
    var poll_fds = [_]std.posix.pollfd{.{
        .fd = std.posix.STDIN_FILENO,
        .events = std.posix.POLL.IN | std.posix.POLL.HUP | std.posix.POLL.ERR,
        .revents = 0,
    }};
    _ = std.posix.poll(&poll_fds, 0) catch return;
    if (poll_fds[0].revents & std.posix.POLL.IN == 0) {
        if (poll_fds[0].revents & (std.posix.POLL.HUP | std.posix.POLL.ERR) != 0) stdin_eof.* = true;
        return;
    }

    var buffer: [4096]u8 = undefined;
    while (true) {
        const read_raw = std.c.read(std.posix.STDIN_FILENO, &buffer, buffer.len);
        if (read_raw > 0) {
            const input = buffer[0..@intCast(read_raw)];
            if (std.mem.indexOfScalar(u8, input, 0x1d) != null) {
                detach_requested.* = true;
                stdin_eof.* = true;
                return;
            }
            const response = try sendSessionRequestAlloc(allocator, io, "session.write", .{ .id = session_id, .attach_id = attach_id, .text = input }, 1);
            allocator.free(response);
            continue;
        }
        if (read_raw == 0) {
            stdin_eof.* = true;
            return;
        }
        const err = std.c._errno().*;
        if (err == @intFromEnum(std.c.E.AGAIN)) return;
        if (err == @intFromEnum(std.c.E.INTR)) continue;
        stdin_eof.* = true;
        return;
    }
}

fn readSessionOutput(allocator: std.mem.Allocator, io: std.Io, session_id: []const u8, attach_id: []const u8, offset: usize) !SessionReadResult {
    const response = try sendSessionRequestAlloc(allocator, io, "session.tail", .{ .id = session_id, .attach_id = attach_id, .offset = offset }, 1);
    defer allocator.free(response);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, response, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidSessionResponse;
    if (parsed.value.object.get("error")) |_| return error.SessionAttachFailed;
    const result = parsed.value.object.get("result") orelse return error.InvalidSessionResponse;
    if (result != .object) return error.InvalidSessionResponse;
    const text = jsonString(result.object.get("text") orelse .null) orelse "";
    return .{
        .text = try allocator.dupe(u8, text),
        .running = jsonBool(result.object.get("running") orelse .null) orelse false,
        .next_offset = jsonUsize(result.object.get("next_offset") orelse .null) orelse offset,
    };
}

const TerminalMode = struct {
    original: std.posix.termios,
};

fn enterRawMode() !TerminalMode {
    const original = try std.posix.tcgetattr(std.posix.STDIN_FILENO);
    var raw = original;
    raw.iflag.BRKINT = false;
    raw.iflag.ICRNL = false;
    raw.iflag.INPCK = false;
    raw.iflag.ISTRIP = false;
    raw.iflag.IXON = false;
    raw.oflag.OPOST = false;
    raw.cflag.CSIZE = .CS8;
    raw.cflag.PARENB = false;
    raw.lflag.ECHO = false;
    raw.lflag.ICANON = false;
    raw.lflag.IEXTEN = false;
    raw.lflag.ISIG = false;
    raw.cc[@intFromEnum(std.posix.V.MIN)] = 1;
    raw.cc[@intFromEnum(std.posix.V.TIME)] = 0;
    try std.posix.tcsetattr(std.posix.STDIN_FILENO, .FLUSH, raw);
    return .{ .original = original };
}

fn restoreTerminalMode(mode: TerminalMode) void {
    std.posix.tcsetattr(std.posix.STDIN_FILENO, .FLUSH, mode.original) catch {};
}

fn setFdNonBlocking(fd: std.posix.fd_t) !c_int {
    const current = std.c.fcntl(fd, std.c.F.GETFL, @as(c_int, 0));
    if (current < 0) return error.FcntlFailed;
    const nonblock = @as(usize, 1) << @bitOffsetOf(std.posix.O, "NONBLOCK");
    if (std.c.fcntl(fd, std.c.F.SETFL, current | @as(c_int, @intCast(nonblock))) < 0) return error.FcntlFailed;
    return current;
}

fn restoreFdFlags(fd: std.posix.fd_t, flags: c_int) void {
    _ = std.c.fcntl(fd, std.c.F.SETFL, flags);
}

fn writeStdout(bytes: []const u8) !void {
    var remaining = bytes;
    while (remaining.len > 0) {
        const written_raw = std.c.write(std.posix.STDOUT_FILENO, remaining.ptr, remaining.len);
        if (written_raw < 0) {
            if (std.c._errno().* == @intFromEnum(std.c.E.INTR)) continue;
            return error.StdoutWriteFailed;
        }
        const written: usize = @intCast(written_raw);
        if (written == 0) return error.StdoutWriteFailed;
        remaining = remaining[written..];
    }
}

fn ensureSessionDaemon(allocator: std.mem.Allocator, io: std.Io, exe_path: []const u8) !void {
    _ = io;
    const pref_path = try prefPath(allocator);
    defer allocator.free(pref_path);
    try sessionizer.ensureDaemon(allocator, pref_path, exe_path);
}

fn sessionIdForNewCommand(allocator: std.mem.Allocator, argv: []const []const u8) ![]u8 {
    if (args.optionValue(argv, "--id")) |id| return allocator.dupe(u8, id);
    if (args.optionValue(argv, "--name")) |name| {
        var safe_name: std.ArrayList(u8) = .empty;
        defer safe_name.deinit(allocator);
        for (name) |byte| {
            const safe = (byte >= 'a' and byte <= 'z') or
                (byte >= 'A' and byte <= 'Z') or
                (byte >= '0' and byte <= '9') or
                byte == '-' or byte == '_' or byte == '.';
            try safe_name.append(allocator, if (safe) byte else '_');
        }
        return try std.fmt.allocPrint(allocator, "verde:cli:{s}", .{if (safe_name.items.len > 0) safe_name.items else "session"});
    }
    return try std.fmt.allocPrint(allocator, "verde:cli:{d}", .{std.c.getpid()});
}

fn commandAfterDoubleDash(argv: []const []const u8) []const []const u8 {
    for (argv, 0..) |arg, index| {
        if (std.mem.eql(u8, arg, "--")) {
            if (index + 1 >= argv.len) return &.{};
            return argv[index + 1 ..];
        }
    }
    return &.{};
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
    const workspace = mcpArgString(arguments, "workspace") orelse mcpArgString(arguments, "project");
    const process_name = mcpArgString(arguments, "name");
    const lines = mcpArgU32(arguments, "lines");

    const response = blk: {
        if (std.mem.eql(u8, tool_name, "list_processes")) {
            break :blk sendLiveRequestAlloc(allocator, io, "processes", .{ .workspace = workspace }, 1);
        }
        if (std.mem.eql(u8, tool_name, "inspect_process")) {
            const name = process_name orelse return try mcpError(allocator, out, id_value, -32602, "inspect_process requires name");
            break :blk sendLiveRequestAlloc(allocator, io, "process.inspect", .{ .workspace = workspace, .name = name }, 1);
        }
        if (std.mem.eql(u8, tool_name, "tail_process_logs")) {
            const name = process_name orelse return try mcpError(allocator, out, id_value, -32602, "tail_process_logs requires name");
            break :blk sendLiveRequestAlloc(allocator, io, "process.logs", .{ .workspace = workspace, .name = name, .lines = lines }, 1);
        }
        if (std.mem.eql(u8, tool_name, "restart_process")) {
            const name = process_name orelse return try mcpError(allocator, out, id_value, -32602, "restart_process requires name");
            break :blk sendLiveRequestAlloc(allocator, io, "process.restart", .{ .workspace = workspace, .name = name }, 1);
        }
        if (std.mem.eql(u8, tool_name, "stop_process")) {
            const name = process_name orelse return try mcpError(allocator, out, id_value, -32602, "stop_process requires name");
            break :blk sendLiveRequestAlloc(allocator, io, "process.stop", .{ .workspace = workspace, .name = name }, 1);
        }
        if (std.mem.eql(u8, tool_name, "start_process")) {
            const name = process_name orelse return try mcpError(allocator, out, id_value, -32602, "start_process requires name");
            break :blk sendLiveRequestAlloc(allocator, io, "process.start", .{ .workspace = workspace, .name = name }, 1);
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

fn sessionResultStringAlloc(allocator: std.mem.Allocator, response: []const u8, field: []const u8) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, response, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidSessionResponse;
    if (parsed.value.object.get("error")) |_| return error.SessionRequestFailed;
    const result = parsed.value.object.get("result") orelse return error.InvalidSessionResponse;
    if (result != .object) return error.InvalidSessionResponse;
    const text = jsonString(result.object.get(field) orelse .null) orelse return error.InvalidSessionResponse;
    return try allocator.dupe(u8, text);
}

fn jsonString(value: std.json.Value) ?[]const u8 {
    return switch (value) {
        .string => |text| text,
        else => null,
    };
}

fn jsonBool(value: std.json.Value) ?bool {
    return switch (value) {
        .bool => |bool_value| bool_value,
        else => null,
    };
}

fn jsonInt(value: std.json.Value) ?i64 {
    return switch (value) {
        .integer => |int| int,
        .float => |float| @intFromFloat(float),
        .number_string => |text| std.fmt.parseInt(i64, text, 10) catch null,
        else => null,
    };
}

fn jsonUsize(value: std.json.Value) ?usize {
    return switch (value) {
        .integer => |int| if (int >= 0) @intCast(int) else null,
        .number_string => |text| std.fmt.parseInt(usize, text, 10) catch null,
        else => null,
    };
}

fn liveUnavailable(out: output.Output, err: anyerror) noreturn {
    out.stderr("verde live server is not running: {s}\n", .{@errorName(err)}) catch {};
    std.process.exit(3);
}

fn commonPaneParams(argv: []const []const u8) struct { workspace: ?[]const u8, pane: ?u32, focused: bool } {
    return .{
        .workspace = workspaceOption(argv),
        .pane = parseOptionalU32(args.optionValue(argv, "--pane")),
        .focused = args.hasFlag(argv, "--focused"),
    };
}

fn processParams(argv: []const []const u8) struct { workspace: ?[]const u8, pane: ?u32, focused: bool, name: ?[]const u8, lines: ?u32 } {
    return .{
        .workspace = workspaceOption(argv),
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
    return std.mem.eql(u8, name, "--workspace") or
        std.mem.eql(u8, name, "--project") or
        std.mem.eql(u8, name, "--id") or
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

fn collectPersistedSessionRefs(allocator: std.mem.Allocator, state: db_types.PersistedState) ![]const PersistedSessionRef {
    var sessions: std.ArrayList(PersistedSessionRef) = .empty;
    defer sessions.deinit(allocator);

    for (state.projects, 0..) |project, project_index| {
        if (project.terminal_layout_json) |layout_json| {
            try collectLayoutSessionRefs(allocator, &sessions, project, project_index, 0, layout_json);
        }
        if (project.terminal_docks_json) |docks_json| {
            try collectTerminalDockSessionRefs(allocator, &sessions, project, project_index, docks_json);
        }
    }

    return try sessions.toOwnedSlice(allocator);
}

fn collectTerminalDockSessionRefs(
    allocator: std.mem.Allocator,
    sessions: *std.ArrayList(PersistedSessionRef),
    project: db_types.PersistedProject,
    project_index: usize,
    docks_json: []const u8,
) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, docks_json, .{});
    defer parsed.deinit();
    if (parsed.value != .array) return;
    for (parsed.value.array.items) |entry| {
        if (entry != .object) continue;
        const dock_id: u32 = @intCast(jsonInt(entry.object.get("id") orelse .null) orelse continue);
        const layout_json = jsonString(entry.object.get("layout") orelse .null) orelse continue;
        try collectLayoutSessionRefs(allocator, sessions, project, project_index, dock_id, layout_json);
    }
}

fn collectLayoutSessionRefs(
    allocator: std.mem.Allocator,
    sessions: *std.ArrayList(PersistedSessionRef),
    project: db_types.PersistedProject,
    project_index: usize,
    dock_id: u32,
    layout_json: []const u8,
) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, layout_json, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return;
    const tabs = parsed.value.object.get("tabs") orelse return;
    if (tabs != .array) return;

    const project_id = project.id orelse project.path;
    for (tabs.array.items) |tab| {
        if (tab != .object) continue;
        const tab_title = jsonString(tab.object.get("title") orelse .null) orelse "";
        const nodes = tab.object.get("nodes") orelse continue;
        if (nodes != .array) continue;
        for (nodes.array.items) |node| {
            if (node != .object) continue;
            const kind = jsonString(node.object.get("kind") orelse .null) orelse continue;
            if (!std.mem.eql(u8, kind, "leaf")) continue;
            const pane_id: u32 = @intCast(jsonInt(node.object.get("pane_id") orelse .null) orelse continue);
            const raw_session_id = jsonString(node.object.get("session_id") orelse .null);
            const session_id = if (raw_session_id) |id|
                try allocator.dupe(u8, id)
            else
                try sessionizer.stableSessionId(allocator, project_id, dock_id, pane_id);
            const label = jsonString(node.object.get("launch_label") orelse .null) orelse tab_title;
            const revive_policy = jsonString(node.object.get("revive_policy") orelse .null) orelse "attach_or_create";
            try sessions.append(allocator, .{
                .session_id = session_id,
                .workspace_index = project_index,
                .workspace_id = try allocator.dupe(u8, project_id),
                .workspace_path = try allocator.dupe(u8, project.path),
                .dock_id = dock_id,
                .pane_id = pane_id,
                .label = try allocator.dupe(u8, label),
                .revive_policy = try allocator.dupe(u8, revive_policy),
            });
        }
    }
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
            .workspace = project.id orelse project.path,
            .workspace_layout_json = project.workspace_layout_json,
            .terminal_docks_json = project.terminal_docks_json,
            .live = false,
        });
        return;
    }
    try out.stdout("Workspace: {s}\n", .{project.label});
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
            .workspace = project.id orelse project.path,
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
        try out.stderr("no workspaces in persisted state\n", .{});
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
    try out.stderr("workspace not found: {s}\n", .{ref});
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
    const argv = [_][]const u8{ "verde", "state", "workspaces", "--json" };
    const parsed = args.parse(&argv);
    try std.testing.expectEqualStrings("state", parsed.command);
    try std.testing.expect(parsed.json);
}
