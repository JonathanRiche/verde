const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");

const args = @import("cli_args.zig");
const completion = @import("cli_completion.zig");
const output = @import("cli_output.zig");
const herdr = @import("herdr.zig");
const platform_ipc = @import("platform/ipc.zig");
const live_endpoint = @import("platform/live_endpoint.zig");
const platform_paths = @import("platform_paths");
const platform_runtime = @import("platform_runtime");
const process_env = @import("process_env.zig");
const provider_hooks = @import("provider_hooks.zig");
const spec = @import("cli_spec.zig");
const db_client = @import("db/client.zig");
const db_types = @import("db/types.zig");
const sessionizer = @import("terminal/sessionizer.zig");
const app_config = @import("config.zig");
const theme_package = @import("theme_package.zig");
const update_installer = @import("update_installer.zig");
const ui_theme = @import("ui/theme.zig");

const VERSION = build_options.version;
const SOCKET_NAME = live_endpoint.SOCKET_NAME;
const LIVE_RESPONSE_TIMEOUT_MS: u32 = 5000;
const TERMINAL_GET_WINSIZE_IOCTL: c_int = switch (builtin.os.tag) {
    .macos => @bitCast(@as(u32, 0x40087468)),
    .windows => 0,
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
    if (std.mem.eql(u8, parsed.command, "update")) {
        try handleUpdate(allocator, out, parsed.rest, parsed.json);
        return .handled;
    }
    if (std.mem.eql(u8, parsed.command, "capabilities")) {
        try printCapabilities(allocator, out, parsed.json);
        return .handled;
    }
    if (std.mem.eql(u8, parsed.command, "open")) {
        try handleOpen(allocator, out, io, parsed.rest, parsed.json);
        return .handled;
    }
    if (std.mem.eql(u8, parsed.command, "herdr")) {
        try handleHerdr(allocator, out, io, argv[0], parsed.rest);
        return .handled;
    }
    if (std.mem.eql(u8, parsed.command, "completion")) {
        try handleCompletion(allocator, out, parsed.rest);
        return .handled;
    }
    if (std.mem.eql(u8, parsed.command, "theme")) {
        try handleTheme(allocator, out, parsed.rest);
        return .handled;
    }
    if (std.mem.eql(u8, parsed.command, "state")) {
        try handleState(allocator, out, parsed.rest);
        return .handled;
    }
    if (std.mem.eql(u8, parsed.command, "notify")) {
        try handleNotify(allocator, out, io, parsed.rest);
        return .handled;
    }
    if (std.mem.eql(u8, parsed.command, "integrations")) {
        try handleIntegrations(allocator, out, parsed.rest);
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
        \\  verde update [--json]         Install the latest Verde release
        \\  verde capabilities [--json]   Print CLI capability metadata
        \\  verde open <url>              Open a URL in this Verde workspace's browser pane
        \\  verde herdr <command>         Open or inspect Herdr-backed Verde workspaces
        \\  verde theme <command>         Import, validate, export, or reset themes
        \\  verde completion <shell>       Print shell completion script
        \\  verde state <command>         Read persisted state with the app closed
        \\  verde notify [options]        Update the current terminal surface
        \\  verde integrations <command>  Inspect optional provider hook support
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
        \\Herdr commands:
        \\  open --herdr-workspace <id> [--session <name>] [--profile <name>|--remote <ssh-alias>] [--cwd <path>] [--remote-cwd <path>] [--local-dir <path>] [--pane <herdr-pane-id>] [--json]
        \\  handoff [--workspace <id|index|path|current>] [--all] [--session <name>] [--profile <name>|--remote <ssh-alias>] [--remote-cwd <path>] [--dry-run] [--json]
        \\  unlink [--workspace <id|index|path|current>] [--all] [--json]
        \\  status [--json]
        \\
        \\Integration commands:
        \\  list [--json]
        \\  doctor [--json]
        \\  install <claude|codex|opencode|cursor>
        \\  remove <claude|codex|opencode|cursor>
        \\  disable <claude|codex|opencode|cursor>
        \\
        \\Theme commands:
        \\  import <file-or-url> [--dry-run] [--json]
        \\  validate <file-or-url> [--json]
        \\  export [file] [--name <name>] [--json]
        \\  reset [--json]
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
        \\  surfaces [--json]
        \\  inspect --pane <id> [--workspace <id|index|current>] [--json]
        \\  workspace select|create|rename|close|reopen ...
        \\  pane focus|split|resize|move|minimize|maximize|restore|close ...
        \\  chat status|transcript|send|followup|stop|approve|draft ...
        \\  browser open|navigate|status|close|toggle|back|forward|reload|eval|post-json|inspector-* ...
        \\  palette list|run ...
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

fn handleUpdate(allocator: std.mem.Allocator, out: output.Output, argv: []const []const u8, json: bool) !void {
    if (args.hasFlag(argv, "--help") or args.hasFlag(argv, "-h")) {
        try out.stdout(
            \\Usage:
            \\  verde update [--json]
            \\
            \\Installs the latest Verde release using the official platform installer.
            \\
        , .{});
        return;
    }

    const launch = update_installer.launch(allocator) catch |err| {
        if (json) {
            try out.jsonValue(allocator, .{
                .ok = false,
                .@"error" = .{ .code = "launch_failed", .message = @errorName(err) },
            });
        } else {
            try out.stderr("failed to start Verde updater: {s}\n", .{@errorName(err)});
        }
        std.process.exit(1);
    };

    const app_exit_required = launch == .started_and_exit_required;
    if (json) {
        try out.jsonValue(allocator, .{
            .ok = true,
            .result = .{
                .status = "started",
                .restart_required = !app_exit_required,
                .app_exit_required = app_exit_required,
            },
        });
        return;
    }
    if (app_exit_required) {
        try out.stdout("Verde updater started. Installation will continue after this process exits.\n", .{});
    } else {
        try out.stdout("Verde updater started. Restart Verde after installation completes.\n", .{});
    }
}

fn printCapabilities(allocator: std.mem.Allocator, out: output.Output, json: bool) !void {
    const caps = .{
        .app = "verde",
        .version = VERSION,
        .protocol_version = 2,
        .cli = .{
            .update = true,
            .state = spec.state_commands[0..],
            .herdr = spec.herdr_commands[0..],
            .integrations = spec.integration_commands[0..],
            .theme = spec.theme_commands[0..],
            .session = spec.session_commands[0..],
            .live = spec.live_capabilities[0..],
            .completion = spec.shells[0..],
            .encodings = spec.encodings[0..],
        },
        .ipc = .{
            .transport = live_endpoint.transportName(),
            .socket_name = SOCKET_NAME,
            .endpoint_env = live_endpoint.ENDPOINT_ENV,
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
        \\  update: yes
        \\  state: path, workspaces, panes, threads, transcript
        \\  herdr: open, handoff, unlink, profiles, status
        \\  integrations: list, doctor, install, remove, disable
        \\  theme: import, validate, export, reset
        \\  session: list, inspect, new, attach, write, tail, screen, kill, cleanup
        \\  live: status, workspaces, panes, pane control, chat control, terminal/process/agent control
        \\  completion: bash, zsh, fish, powershell
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
        try out.stderr("missing completion shell; expected bash, zsh, fish, or powershell\n", .{});
        std.process.exit(2);
    };
    if (std.mem.eql(u8, shell, "help")) {
        try printCompletionHelp(out);
        return;
    }
    if (!try completion.print(allocator, out, shell)) {
        try out.stderr("unsupported completion shell: {s}; expected bash, zsh, fish, or powershell\n", .{shell});
        std.process.exit(2);
    }
}

fn printCompletionHelp(out: output.Output) !void {
    try out.stdout(
        \\Usage:
        \\  verde completion bash
        \\  verde completion zsh
        \\  verde completion fish
        \\  verde completion powershell
        \\
    , .{});
}

fn handleTheme(allocator: std.mem.Allocator, out: output.Output, argv: []const []const u8) !void {
    if (args.hasFlag(argv, "--help") or args.hasFlag(argv, "-h")) {
        try printThemeHelp(out);
        return;
    }
    const command = args.positional(argv, 0) orelse {
        try out.stderr("missing theme command\n", .{});
        std.process.exit(2);
    };
    if (std.mem.eql(u8, command, "help")) {
        try printThemeHelp(out);
        return;
    }

    const json = args.hasFlag(argv, "--json");
    if (std.mem.eql(u8, command, "import") or std.mem.eql(u8, command, "validate")) {
        return handleThemeImportOrValidate(allocator, out, argv, command, json);
    }
    if (std.mem.eql(u8, command, "export")) return handleThemeExport(allocator, out, argv, json);
    if (std.mem.eql(u8, command, "reset")) return handleThemeReset(allocator, out, json);

    try out.stderr("unknown theme command: {s}\n", .{command});
    std.process.exit(2);
}

fn handleThemeImportOrValidate(
    allocator: std.mem.Allocator,
    out: output.Output,
    argv: []const []const u8,
    command: []const u8,
    json: bool,
) !void {
    const source = trailingFreeArg(argv, 1) orelse {
        try out.stderr("theme {s} requires a JSON file or HTTP(S) URL\n", .{command});
        std.process.exit(2);
    };
    const raw = readThemeSourceAlloc(allocator, source) catch |err| {
        failThemeCommand(allocator, out, json, "read theme", err);
    };
    defer allocator.free(raw);
    var package = theme_package.parse(allocator, raw) catch |err| {
        failThemeCommand(allocator, out, json, "validate theme", err);
    };
    defer package.deinit(allocator);
    const display_name = package.name orelse themeNameFromSource(source);

    const dry_run = std.mem.eql(u8, command, "validate") or args.hasFlag(argv, "--dry-run");
    if (!dry_run) {
        var config = app_config.loadAppConfig(allocator) catch |err| {
            failThemeCommand(allocator, out, json, "load Verde config", err);
        };
        defer config.deinit(allocator);
        const installed_index = config.installTheme(
            allocator,
            display_name,
            package.theme_config,
            package.font_size,
            package.terminal_font_size,
        ) catch |err| {
            failThemeCommand(allocator, out, json, "install theme", err);
        };
        config.selectThemeChoice(allocator, installed_index + 2) catch |err| {
            failThemeCommand(allocator, out, json, "activate theme", err);
        };
        app_config.saveAppConfig(allocator, &config) catch |err| {
            failThemeCommand(allocator, out, json, "save Verde config", err);
        };
    }
    return writeThemeImportResult(allocator, out, source, display_name, package, dry_run, json);
}

fn writeThemeImportResult(
    allocator: std.mem.Allocator,
    out: output.Output,
    source: []const u8,
    display_name: []const u8,
    package: theme_package.Package,
    dry_run: bool,
    json: bool,
) !void {
    if (json) {
        try out.jsonValue(allocator, .{
            .ok = true,
            .action = if (dry_run) "validated" else "imported",
            .source = source,
            .name = display_name,
            .theme_source = @tagName(package.theme_config.source),
            .ui_font_size = package.font_size,
            .terminal_font_size = package.terminal_font_size,
            .ignored_unsupported_fonts = package.ignored_font_settings,
        });
        return;
    }
    try out.stdout("Theme {s}: {s}\n", .{ if (dry_run) "validated" else "imported", display_name });
    if (package.ignored_font_settings) {
        try out.stderr("warning: unsupported font family settings were ignored; bundled Verde fonts remain active\n", .{});
    }
    if (!dry_run) try out.stdout("Installed and selected. You can switch themes from Settings → Appearance.\n", .{});
}

fn themeNameFromSource(source: []const u8) []const u8 {
    const without_query = std.mem.sliceTo(source, '?');
    const basename = std.fs.path.basename(without_query);
    const stem = std.fs.path.stem(basename);
    return if (stem.len > 0) stem else "Imported theme";
}

fn handleThemeExport(
    allocator: std.mem.Allocator,
    out: output.Output,
    argv: []const []const u8,
    json: bool,
) !void {
    var config = app_config.loadAppConfig(allocator) catch |err| {
        failThemeCommand(allocator, out, json, "load Verde config", err);
    };
    defer config.deinit(allocator);
    const name = args.optionValue(argv, "--name") orelse "Verde theme";
    const encoded = theme_package.exportAlloc(allocator, config, name) catch |err| {
        failThemeCommand(allocator, out, json, "export theme", err);
    };
    defer allocator.free(encoded);

    const raw_path = trailingFreeArg(argv, 1) orelse return out.stdout("{s}", .{encoded});
    const path = platform_paths.expandUserPath(allocator, raw_path) catch |err| {
        failThemeCommand(allocator, out, json, "resolve export path", err);
    };
    defer allocator.free(path);
    writeThemeFile(path, encoded) catch |err| {
        failThemeCommand(allocator, out, json, "write theme", err);
    };
    if (json) {
        try out.jsonValue(allocator, .{ .ok = true, .action = "exported", .path = path, .name = name });
    } else {
        try out.stdout("Theme exported to {s}\n", .{path});
    }
}

fn handleThemeReset(allocator: std.mem.Allocator, out: output.Output, json: bool) !void {
    var config = app_config.loadAppConfig(allocator) catch |err| {
        failThemeCommand(allocator, out, json, "load Verde config", err);
    };
    defer config.deinit(allocator);
    config.selectThemeChoice(allocator, 0) catch |err| {
        failThemeCommand(allocator, out, json, "select Verde theme", err);
    };
    config.font_size = ui_theme.DEFAULT_FONT_SIZE;
    config.terminal_font_size = app_config.DEFAULT_TERMINAL_FONT_SIZE;
    app_config.saveAppConfig(allocator, &config) catch |err| {
        failThemeCommand(allocator, out, json, "save Verde config", err);
    };
    if (json) {
        try out.jsonValue(allocator, .{ .ok = true, .action = "reset" });
    } else {
        try out.stdout("Theme reset to platform defaults. The running app will reload it automatically.\n", .{});
    }
}

fn printThemeHelp(out: output.Output) !void {
    try out.stdout(
        \\Usage:
        \\  verde theme import <file-or-url> [--dry-run] [--json]
        \\  verde theme validate <file-or-url> [--json]
        \\  verde theme export [file] [--name <name>] [--json]
        \\  verde theme reset [--json]
        \\
        \\Theme files are versioned JSON. Import also accepts a full verde.json
        \\theme section or a bare {{"theme":"default","colors":{{...}}}} object.
        \\GitHub file-page links and raw HTTP(S) JSON links are supported.
        \\
    , .{});
}

fn readThemeSourceAlloc(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    if (std.mem.startsWith(u8, source, "https://") or std.mem.startsWith(u8, source, "http://")) {
        return theme_package.readSourceAlloc(allocator, source);
    }
    const path = try platform_paths.expandUserPath(allocator, source);
    defer allocator.free(path);
    return theme_package.readSourceAlloc(allocator, path);
}

fn writeThemeFile(path: []const u8, encoded: []const u8) !void {
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    if (std.fs.path.dirname(path)) |parent| try std.Io.Dir.cwd().createDirPath(io, parent);
    var file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    var buffer: [4096]u8 = undefined;
    var writer = file.writer(io, &buffer);
    try writer.interface.writeAll(encoded);
    try writer.interface.flush();
}

fn failThemeCommand(
    allocator: std.mem.Allocator,
    out: output.Output,
    json: bool,
    action: []const u8,
    err: anyerror,
) noreturn {
    if (json) {
        out.jsonValue(allocator, .{
            .ok = false,
            .action = action,
            .@"error" = @errorName(err),
        }) catch {};
    } else {
        out.stderr("failed to {s}: {s}\n", .{ action, @errorName(err) }) catch {};
    }
    std.process.exit(1);
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

fn handleHerdr(allocator: std.mem.Allocator, out: output.Output, io: std.Io, exe_path: []const u8, argv: []const []const u8) !void {
    if (args.hasFlag(argv, "--help") or args.hasFlag(argv, "-h")) {
        try printHerdrHelp(out);
        return;
    }
    const command = args.positional(argv, 0) orelse {
        try out.stderr("missing herdr command\n", .{});
        std.process.exit(2);
    };
    const json = args.hasFlag(argv, "--json");
    if (std.mem.eql(u8, command, "help")) {
        try printHerdrHelp(out);
        return;
    }
    if (std.mem.eql(u8, command, "open")) {
        try handleHerdrOpen(allocator, out, io, exe_path, argv, json);
        return;
    }
    if (std.mem.eql(u8, command, "handoff")) {
        try handleHerdrHandoff(allocator, out, io, argv, json);
        return;
    }
    if (std.mem.eql(u8, command, "unlink")) {
        try handleHerdrUnlink(allocator, out, io, argv, json);
        return;
    }
    if (std.mem.eql(u8, command, "profiles")) {
        try handleHerdrProfiles(allocator, out, io, argv, json);
        return;
    }
    if (std.mem.eql(u8, command, "status")) {
        try handleHerdrStatus(allocator, out, io, json);
        return;
    }
    try out.stderr("unknown herdr command: {s}\n", .{command});
    std.process.exit(2);
}

fn printHerdrHelp(out: output.Output) !void {
    try out.stdout(
        \\Usage:
        \\  verde herdr open --herdr-workspace <id> [--session <name>] [--profile <name>|--remote <ssh-alias>] [--cwd <path>] [--remote-cwd <path>] [--local-dir <path>] [--pane <herdr-pane-id>] [--json]
        \\  verde herdr handoff [--workspace <id|index|path|current>] [--all] [--session <name>] [--profile <name>|--remote <ssh-alias>] [--remote-cwd <path>] [--dry-run] [--json]
        \\  verde herdr unlink [--workspace <id|index|path|current>] [--all] [--json]
        \\  verde herdr profiles <list|add|remove|test> [options]
        \\  verde herdr status [--json]
        \\
        \\Open creates or focuses a Verde workspace linked to the Herdr target.
        \\If Verde is not running, the request is queued and the app is launched.
        \\Handoff mirrors Verde workspaces into Herdr for terminal/TUI takeover.
        \\Unlink removes Verde's Herdr runtime mapping without deleting the Herdr workspace.
        \\Profiles store SSH aliases/session defaults only; credentials stay in SSH config.
        \\
    , .{});
}

fn handleHerdrOpen(
    allocator: std.mem.Allocator,
    out: output.Output,
    io: std.Io,
    exe_path: []const u8,
    argv: []const []const u8,
    json: bool,
) !void {
    var cwd_owned: ?[]u8 = null;
    defer if (cwd_owned) |cwd| allocator.free(cwd);
    var profile_defaults: HerdrProfileDefaults = .{};
    defer profile_defaults.deinit(allocator);
    const request = try parseHerdrOpenRequest(allocator, out, io, argv, &cwd_owned, &profile_defaults);

    if (sendLiveRequestAlloc(allocator, io, "herdr.open", request, 1)) |response| {
        defer allocator.free(response);
        if (liveResponseErrorCodeEquals(allocator, response, "method_not_found")) {
            // A stale running app can own the socket while the just-built CLI knows
            // about Herdr. Queue the cold-start request instead of dead-ending.
        } else {
            try out.stdout("{s}\n", .{response});
            return;
        }
    } else |_| {}

    const pref_path = try prefPath(allocator);
    defer allocator.free(pref_path);
    try herdr.writePendingOpen(allocator, io, pref_path, request);
    try launchVerdeAppDetached(allocator, exe_path);

    if (json) {
        try out.jsonValue(allocator, .{
            .id = 1,
            .ok = true,
            .result = .{
                .queued = true,
                .launched = true,
                .session = request.session,
                .herdr_workspace = request.herdr_workspace,
                .remote = herdr.remoteAlias(request),
                .pane = request.pane,
            },
        });
    } else {
        try out.stdout("Queued Herdr workspace {s}/{s} and launched Verde.\n", .{ request.session, request.herdr_workspace });
    }
}

fn handleHerdrHandoff(allocator: std.mem.Allocator, out: output.Output, io: std.Io, argv: []const []const u8, json: bool) !void {
    var profile_defaults: HerdrProfileDefaults = .{};
    defer profile_defaults.deinit(allocator);
    const request = try parseHerdrHandoffRequest(allocator, out, io, argv, &profile_defaults);
    herdr.validateHandoffRequest(request) catch |err| {
        try out.stderr("invalid herdr handoff request: {s}\n", .{@errorName(err)});
        std.process.exit(2);
    };
    if (sendLiveRequestAlloc(allocator, io, "herdr.handoff", request, 1)) |response| {
        defer allocator.free(response);
        if (liveResponseErrorCodeEquals(allocator, response, "method_not_found")) {
            try out.stderr("running Verde app does not support herdr handoff; rebuild/restart Verde\n", .{});
            std.process.exit(1);
        }
        try out.stdout("{s}\n", .{response});
        _ = json;
        return;
    } else |err| {
        try out.stderr("verde herdr handoff requires the Verde app to be running ({s})\n", .{@errorName(err)});
        std.process.exit(3);
    }
}

fn parseHerdrHandoffRequest(
    allocator: std.mem.Allocator,
    out: output.Output,
    io: std.Io,
    argv: []const []const u8,
    profile_defaults: *HerdrProfileDefaults,
) !herdr.HandoffRequest {
    try resolveHerdrProfileDefaults(allocator, out, io, argv, profile_defaults);
    return .{
        .session = args.optionValue(argv, "--session") orelse profile_defaults.session orelse "default",
        .remote = args.optionValue(argv, "--remote") orelse profile_defaults.remote,
        .remote_cwd = args.optionValue(argv, "--remote-cwd") orelse profile_defaults.remote_cwd,
        .workspace = workspaceOption(argv),
        .all = args.hasFlag(argv, "--all") or workspaceOption(argv) == null,
        .dry_run = args.hasFlag(argv, "--dry-run"),
    };
}

fn handleHerdrUnlink(allocator: std.mem.Allocator, out: output.Output, io: std.Io, argv: []const []const u8, json: bool) !void {
    const request = parseHerdrUnlinkRequest(argv);
    herdr.validateUnlinkRequest(request) catch |err| {
        try out.stderr("invalid herdr unlink request: {s}\n", .{@errorName(err)});
        std.process.exit(2);
    };
    if (sendLiveRequestAlloc(allocator, io, "herdr.unlink", request, 1)) |response| {
        defer allocator.free(response);
        if (liveResponseErrorCodeEquals(allocator, response, "method_not_found")) {
            try out.stderr("running Verde app does not support herdr unlink; rebuild/restart Verde\n", .{});
            std.process.exit(1);
        }
        try out.stdout("{s}\n", .{response});
        _ = json;
        return;
    } else |err| {
        try out.stderr("verde herdr unlink requires the Verde app to be running ({s})\n", .{@errorName(err)});
        std.process.exit(3);
    }
}

fn parseHerdrUnlinkRequest(argv: []const []const u8) herdr.UnlinkRequest {
    return .{
        .workspace = workspaceOption(argv),
        .all = args.hasFlag(argv, "--all"),
    };
}

fn handleHerdrProfiles(allocator: std.mem.Allocator, out: output.Output, io: std.Io, argv: []const []const u8, json: bool) !void {
    const command = args.positional(argv, 1) orelse "list";
    if (std.mem.eql(u8, command, "help") or args.hasFlag(argv, "--help") or args.hasFlag(argv, "-h")) {
        try printHerdrProfilesHelp(out);
        return;
    }
    if (std.mem.eql(u8, command, "list")) return try handleHerdrProfilesList(allocator, out, io, json);
    if (std.mem.eql(u8, command, "add")) return try handleHerdrProfilesAdd(allocator, out, io, argv, json);
    if (std.mem.eql(u8, command, "remove") or std.mem.eql(u8, command, "rm")) return try handleHerdrProfilesRemove(allocator, out, io, argv, json);
    if (std.mem.eql(u8, command, "test")) return try handleHerdrProfilesTest(allocator, out, io, argv, json);
    try out.stderr("unknown herdr profiles command: {s}\n", .{command});
    std.process.exit(2);
}

fn printHerdrProfilesHelp(out: output.Output) !void {
    try out.stdout(
        \\Usage:
        \\  verde herdr profiles list [--json]
        \\  verde herdr profiles add --name <name> --ssh-target <alias> [--session <name>] [--remote-cwd <path>] [--local-dir <path>] [--json]
        \\  verde herdr profiles remove <name> [--json]
        \\  verde herdr profiles test <name> [--json]
        \\
        \\Profiles store SSH aliases and defaults. Configure keys/passwords in SSH, not Verde.
        \\
    , .{});
}

fn handleHerdrProfilesList(allocator: std.mem.Allocator, out: output.Output, io: std.Io, json: bool) !void {
    const pref_path = try prefPath(allocator);
    defer allocator.free(pref_path);
    var loaded = try herdr.loadProfiles(allocator, io, pref_path);
    defer loaded.deinit();
    if (json) {
        try out.jsonValue(allocator, .{ .id = 1, .ok = true, .result = .{ .profiles = loaded.profiles } });
        return;
    }
    if (loaded.profiles.len == 0) {
        try out.stdout("No Herdr profiles configured.\n", .{});
        return;
    }
    try out.stdout("NAME  SSH_TARGET  SESSION  REMOTE_CWD\n", .{});
    for (loaded.profiles) |profile| {
        try out.stdout("{s}  {s}  {s}  {s}\n", .{
            profile.name,
            profile.ssh_target,
            profile.session,
            profile.remote_cwd orelse "",
        });
    }
}

fn handleHerdrProfilesAdd(allocator: std.mem.Allocator, out: output.Output, io: std.Io, argv: []const []const u8, json: bool) !void {
    const name = args.optionValue(argv, "--name") orelse {
        try out.stderr("verde herdr profiles add requires --name\n", .{});
        std.process.exit(2);
    };
    const ssh_target = args.optionValue(argv, "--ssh-target") orelse args.optionValue(argv, "--remote") orelse {
        try out.stderr("verde herdr profiles add requires --ssh-target\n", .{});
        std.process.exit(2);
    };
    const profile: herdr.Profile = .{
        .name = name,
        .ssh_target = ssh_target,
        .session = args.optionValue(argv, "--session") orelse "default",
        .remote_cwd = args.optionValue(argv, "--remote-cwd"),
        .local_dir = args.optionValue(argv, "--local-dir"),
        .updated_at_ms = unixTimestampMs(),
    };
    herdr.validateProfile(profile) catch |err| {
        try out.stderr("invalid herdr profile: {s}\n", .{@errorName(err)});
        std.process.exit(2);
    };

    const pref_path = try prefPath(allocator);
    defer allocator.free(pref_path);
    var loaded = try herdr.loadProfiles(allocator, io, pref_path);
    defer loaded.deinit();
    var next: std.ArrayList(herdr.Profile) = .empty;
    defer next.deinit(allocator);
    var updated = false;
    for (loaded.profiles) |existing| {
        if (std.mem.eql(u8, existing.name, profile.name)) {
            try next.append(allocator, profile);
            updated = true;
        } else {
            try next.append(allocator, existing);
        }
    }
    if (!updated) try next.append(allocator, profile);
    try herdr.saveProfiles(allocator, io, pref_path, next.items);

    if (json) {
        try out.jsonValue(allocator, .{ .id = 1, .ok = true, .result = .{ .profile = profile, .updated = updated } });
    } else {
        try out.stdout("{s} Herdr profile {s} -> {s}.\n", .{ if (updated) "Updated" else "Added", profile.name, profile.ssh_target });
    }
}

fn handleHerdrProfilesRemove(allocator: std.mem.Allocator, out: output.Output, io: std.Io, argv: []const []const u8, json: bool) !void {
    const name = args.optionValue(argv, "--name") orelse args.positional(argv, 2) orelse {
        try out.stderr("verde herdr profiles remove requires a profile name\n", .{});
        std.process.exit(2);
    };
    const pref_path = try prefPath(allocator);
    defer allocator.free(pref_path);
    var loaded = try herdr.loadProfiles(allocator, io, pref_path);
    defer loaded.deinit();
    var next: std.ArrayList(herdr.Profile) = .empty;
    defer next.deinit(allocator);
    var removed: ?herdr.Profile = null;
    for (loaded.profiles) |profile| {
        if (std.mem.eql(u8, profile.name, name)) {
            removed = profile;
        } else {
            try next.append(allocator, profile);
        }
    }
    const removed_profile = removed orelse {
        if (json) try out.jsonValue(allocator, .{ .id = 1, .ok = false, .@"error" = .{ .code = "not_found", .message = "Herdr profile not found" } }) else try out.stderr("Herdr profile not found: {s}\n", .{name});
        std.process.exit(4);
    };
    try herdr.saveProfiles(allocator, io, pref_path, next.items);
    if (json) {
        try out.jsonValue(allocator, .{ .id = 1, .ok = true, .result = .{ .removed = removed_profile } });
    } else {
        try out.stdout("Removed Herdr profile {s}.\n", .{removed_profile.name});
    }
}

fn handleHerdrProfilesTest(allocator: std.mem.Allocator, out: output.Output, io: std.Io, argv: []const []const u8, json: bool) !void {
    const name = args.optionValue(argv, "--name") orelse args.positional(argv, 2) orelse {
        try out.stderr("verde herdr profiles test requires a profile name\n", .{});
        std.process.exit(2);
    };
    const pref_path = try prefPath(allocator);
    defer allocator.free(pref_path);
    var loaded = try herdr.loadProfiles(allocator, io, pref_path);
    defer loaded.deinit();
    const index = herdr.profileIndex(loaded.profiles, name) orelse {
        if (json) try out.jsonValue(allocator, .{ .id = 1, .ok = false, .@"error" = .{ .code = "not_found", .message = "Herdr profile not found" } }) else try out.stderr("Herdr profile not found: {s}\n", .{name});
        std.process.exit(4);
    };
    const profile = loaded.profiles[index];
    const result = herdr.runCli(allocator, io, .{ .session = profile.session, .remote = profile.ssh_target }, &.{ "workspace", "list" }, 128 * 1024) catch |err| {
        if (json) try out.jsonValue(allocator, .{ .id = 1, .ok = false, .@"error" = .{ .code = "rejected", .message = @errorName(err) } }) else try out.stderr("Herdr profile test failed: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    const exit_code = runExitCode(result);
    const ok = exit_code == 0;
    if (json) {
        try out.jsonValue(allocator, .{
            .id = 1,
            .ok = ok,
            .result = .{
                .profile = profile.name,
                .ssh_target = profile.ssh_target,
                .session = profile.session,
                .exit_code = exit_code,
                .stdout = result.stdout,
                .stderr = result.stderr,
            },
        });
    } else if (ok) {
        try out.stdout("Herdr profile {s} is reachable at {s}.\n", .{ profile.name, profile.ssh_target });
    } else {
        try out.stderr("Herdr profile {s} failed with exit code {d}.\n{s}", .{ profile.name, exit_code, result.stderr });
    }
    if (!ok) std.process.exit(1);
}

fn runExitCode(result: std.process.RunResult) i64 {
    return switch (result.term) {
        .exited => |code| code,
        else => -1,
    };
}

fn unixTimestampMs() i64 {
    return platform_runtime.unixTimestampMs();
}

const HerdrProfileDefaults = struct {
    session: ?[]u8 = null,
    remote: ?[]u8 = null,
    remote_cwd: ?[]u8 = null,
    local_dir: ?[]u8 = null,

    fn deinit(self: *HerdrProfileDefaults, allocator: std.mem.Allocator) void {
        if (self.session) |value| allocator.free(value);
        if (self.remote) |value| allocator.free(value);
        if (self.remote_cwd) |value| allocator.free(value);
        if (self.local_dir) |value| allocator.free(value);
        self.* = .{};
    }
};

fn resolveHerdrProfileDefaults(
    allocator: std.mem.Allocator,
    out: output.Output,
    io: std.Io,
    argv: []const []const u8,
    defaults: *HerdrProfileDefaults,
) !void {
    const profile_name = args.optionValue(argv, "--profile") orelse return;
    if (args.optionValue(argv, "--remote") != null) {
        try out.stderr("use either --profile or --remote, not both\n", .{});
        std.process.exit(2);
    }

    const pref_path = try prefPath(allocator);
    defer allocator.free(pref_path);
    var loaded = try herdr.loadProfiles(allocator, io, pref_path);
    defer loaded.deinit();
    const index = herdr.profileIndex(loaded.profiles, profile_name) orelse {
        try out.stderr("Herdr profile not found: {s}\n", .{profile_name});
        std.process.exit(4);
    };
    const profile = loaded.profiles[index];
    defaults.* = .{};
    errdefer defaults.deinit(allocator);
    defaults.session = try allocator.dupe(u8, profile.session);
    defaults.remote = try allocator.dupe(u8, profile.ssh_target);
    defaults.remote_cwd = if (profile.remote_cwd) |value| try allocator.dupe(u8, value) else null;
    defaults.local_dir = if (profile.local_dir) |value| try allocator.dupe(u8, value) else null;
}

fn liveResponseErrorCodeEquals(allocator: std.mem.Allocator, response: []const u8, code: []const u8) bool {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, response, .{}) catch return false;
    defer parsed.deinit();
    if (parsed.value != .object) return false;
    const error_value = parsed.value.object.get("error") orelse return false;
    if (error_value != .object) return false;
    const actual = jsonString(error_value.object.get("code") orelse .null) orelse return false;
    return std.mem.eql(u8, actual, code);
}

fn parseHerdrOpenRequest(
    allocator: std.mem.Allocator,
    out: output.Output,
    io: std.Io,
    argv: []const []const u8,
    cwd_owned: *?[]u8,
    profile_defaults: *HerdrProfileDefaults,
) !herdr.OpenRequest {
    try resolveHerdrProfileDefaults(allocator, out, io, argv, profile_defaults);
    const session = args.optionValue(argv, "--session") orelse profile_defaults.session orelse {
        try out.stderr("verde herdr open requires --session\n", .{});
        std.process.exit(2);
    };
    const workspace = args.optionValue(argv, "--herdr-workspace") orelse {
        try out.stderr("verde herdr open requires --herdr-workspace\n", .{});
        std.process.exit(2);
    };
    const remote = args.optionValue(argv, "--remote") orelse profile_defaults.remote;
    const local_dir = args.optionValue(argv, "--local-dir") orelse profile_defaults.local_dir;
    const remote_cwd = args.optionValue(argv, "--remote-cwd") orelse profile_defaults.remote_cwd;
    const explicit_cwd = args.optionValue(argv, "--cwd");
    if (remote == null and explicit_cwd == null and local_dir == null) {
        cwd_owned.* = try currentWorkingDirectoryAlloc(allocator);
    }
    const request: herdr.OpenRequest = .{
        .session = session,
        .herdr_workspace = workspace,
        .remote = remote,
        .cwd = explicit_cwd orelse cwd_owned.*,
        .remote_cwd = remote_cwd,
        .local_dir = local_dir,
        .pane = args.optionValue(argv, "--pane"),
    };
    herdr.validateOpenRequest(request) catch |err| {
        try out.stderr("invalid herdr open request: {s}\n", .{@errorName(err)});
        std.process.exit(2);
    };
    return request;
}

fn handleHerdrStatus(allocator: std.mem.Allocator, out: output.Output, io: std.Io, json: bool) !void {
    if (sendLiveRequestAlloc(allocator, io, "herdr.status", .{}, 1)) |response| {
        defer allocator.free(response);
        if (!liveResponseErrorCodeEquals(allocator, response, "method_not_found")) {
            try out.stdout("{s}\n", .{response});
            return;
        }
    } else |_| {}
    try writeOfflineHerdrStatus(allocator, out, json);
}

fn writeOfflineHerdrStatus(allocator: std.mem.Allocator, out: output.Output, json: bool) !void {
    const pref_path = try prefPath(allocator);
    defer allocator.free(pref_path);
    var client = try db_client.Client.init(allocator, pref_path);
    defer client.deinit();
    var loaded = try client.load(allocator) orelse {
        if (json) {
            try out.jsonValue(allocator, .{ .id = 1, .ok = true, .result = .{ .daemon_running = false, .links = &.{} } });
        } else {
            try out.stdout("No persisted Verde Herdr links found.\n", .{});
        }
        return;
    };
    defer loaded.deinit();

    if (json) return try writeOfflineHerdrStatusJson(allocator, out, loaded.value);
    var count: usize = 0;
    try out.stdout("WORKSPACE  REMOTE  SESSION  HERDR_WORKSPACE  PATH\n", .{});
    for (loaded.value.projects) |project| {
        const link = project.herdr_link orelse continue;
        count += 1;
        try out.stdout("{s}  {s}  {s}  {s}  {s}\n", .{
            project.label,
            if (link.remote_alias.len > 0) link.remote_alias else "local",
            link.session_name,
            link.workspace_id,
            project.path,
        });
    }
    if (count == 0) try out.stdout("No persisted Verde Herdr links found.\n", .{});
}

fn writeOfflineHerdrStatusJson(allocator: std.mem.Allocator, out: output.Output, state: db_types.PersistedState) !void {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    defer writer.deinit();
    var s: std.json.Stringify = .{ .writer = &writer.writer, .options = .{} };
    try s.beginObject();
    try s.objectField("id");
    try s.write(1);
    try s.objectField("ok");
    try s.write(true);
    try s.objectField("result");
    try s.beginObject();
    try s.objectField("daemon_running");
    try s.write(false);
    try s.objectField("links");
    try s.beginArray();
    for (state.projects, 0..) |project, index| {
        const link = project.herdr_link orelse continue;
        try s.beginObject();
        try s.objectField("workspace_index");
        try s.write(index);
        try s.objectField("workspace_id");
        if (project.id) |id| try s.write(id) else try s.write(project.path);
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
        try s.objectField("pane_links");
        try writePersistedHerdrPaneLinksJson(allocator, &s, link.pane_links_json);
        try s.objectField("updated_at_ms");
        try s.write(link.updated_at_ms);
        try s.endObject();
    }
    try s.endArray();
    try s.endObject();
    try s.endObject();
    try out.stdout("{s}\n", .{writer.written()});
}

fn writePersistedHerdrPaneLinksJson(allocator: std.mem.Allocator, s: *std.json.Stringify, pane_links_json: ?[]const u8) !void {
    const raw = pane_links_json orelse {
        try s.beginArray();
        try s.endArray();
        return;
    };
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, raw, .{}) catch {
        try s.beginArray();
        try s.endArray();
        return;
    };
    defer parsed.deinit();
    if (parsed.value != .array) {
        try s.beginArray();
        try s.endArray();
        return;
    }
    try s.write(parsed.value);
}

fn currentWorkingDirectoryAlloc(allocator: std.mem.Allocator) ![]u8 {
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    return try std.Io.Dir.cwd().realPathFileAlloc(threaded.io(), ".", allocator);
}

fn launchVerdeAppDetached(allocator: std.mem.Allocator, exe_path: []const u8) !void {
    var env_map = try process_env.buildAugmentedEnvMap(allocator);
    defer env_map.deinit();
    const resolved = process_env.resolveExecutableInEnvMapAlloc(allocator, &env_map, exe_path) catch null;
    defer if (resolved) |path| allocator.free(path);
    const argv = [_][]const u8{ resolved orelse exe_path, "app" };
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    _ = try std.process.spawn(threaded.io(), .{
        .argv = &argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
        .environ_map = &env_map,
    });
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
        std.mem.eql(u8, command, "surfaces") or
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
    if (std.mem.eql(u8, command, "workspace")) {
        try handleLiveWorkspace(allocator, out, io, argv, json);
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
    if (std.mem.eql(u8, command, "palette")) {
        try handleLivePalette(allocator, out, io, argv, json);
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
    if (std.mem.eql(u8, command, "agent")) {
        try handleLiveAgent(allocator, out, io, argv, json);
        return;
    }
    if (std.mem.eql(u8, command, "stack")) {
        try handleLiveStack(allocator, out, io, argv, json);
        return;
    }
    try out.stderr("unknown live command: {s}\n", .{command});
    std.process.exit(2);
}

fn handleOpen(allocator: std.mem.Allocator, out: output.Output, io: std.Io, argv: []const []const u8, json: bool) !void {
    if (args.hasFlag(argv, "--help") or args.hasFlag(argv, "-h")) {
        try out.stdout(
            \\Usage:
            \\  verde open <url> [--project <id|index|path|current|self>] [--json]
            \\
            \\Opens or moves the singleton browser pane into the target workspace.
            \\Defaults to the calling Verde terminal workspace when available;
            \\otherwise defaults to the current desktop workspace.
            \\
        , .{});
        return;
    }

    const url = args.optionValue(argv, "--url") orelse trailingFreeArg(argv, 0) orelse {
        try out.stderr("verde open requires a URL\n", .{});
        std.process.exit(2);
    };
    try sendLiveRequest(allocator, out, io, "browser.open", .{
        .url = url,
        .project = try liveBrowserOpenProject(out, argv),
    }, json);
}

fn handleNotify(allocator: std.mem.Allocator, out: output.Output, io: std.Io, argv: []const []const u8) !void {
    if (args.hasFlag(argv, "--help") or args.hasFlag(argv, "-h")) {
        try out.stdout(
            \\Usage:
            \\  verde notify --title <text> [--body <text>] [--status idle|working|waiting|done|error]
            \\  verde notify --status working --progress <0..1> [--label <text>]
            \\  verde notify --clear
            \\
        , .{});
        return;
    }
    const explicit_session = args.optionValue(argv, "--session") orelse args.optionValue(argv, "--session-id");
    const env_session = getenvSlice("VERDE_SESSION_ID");
    const session_id = explicit_session orelse env_session orelse {
        try out.stderr("verde notify requires --session or VERDE_SESSION_ID\n", .{});
        std.process.exit(2);
    };
    const clear = args.hasFlag(argv, "--clear");
    const method = if (clear) "notification.clear" else "notification.create";
    const response = sendLiveRequestAlloc(allocator, io, method, .{
        .session_id = session_id,
        .workspace_id = args.optionValue(argv, "--workspace") orelse getenvSlice("VERDE_WORKSPACE_ID"),
        .workspace_path = getenvSlice("VERDE_WORKSPACE_PATH"),
        .dock_id = parseOptionalU32(args.optionValue(argv, "--dock") orelse getenvSlice("VERDE_DOCK_ID")),
        .pane_id = parseOptionalU32(args.optionValue(argv, "--pane") orelse getenvSlice("VERDE_PANE_ID")),
        .provider = args.optionValue(argv, "--provider") orelse getenvSlice("VERDE_PROVIDER"),
        .title = args.optionValue(argv, "--title"),
        .body = args.optionValue(argv, "--body"),
        .status = args.optionValue(argv, "--status"),
        .progress = parseOptionalF32(args.optionValue(argv, "--progress")),
        .label = args.optionValue(argv, "--label"),
        .attention = if (args.hasFlag(argv, "--attention")) true else null,
    }, 1) catch |err| {
        if (!args.hasFlag(argv, "--quiet")) try out.stderr("verde notify: running app unavailable ({s})\n", .{@errorName(err)});
        return;
    };
    defer allocator.free(response);
    if (args.hasFlag(argv, "--json")) {
        try out.stdout("{s}\n", .{response});
    } else if (!args.hasFlag(argv, "--quiet")) {
        try printLiveResponse(out, response);
    }
}

const IntegrationProvider = struct {
    name: []const u8,
    hook_state: []const u8,
    installable: bool,
    installed: bool,
    reason: []const u8,
};

const integration_providers = [_]IntegrationProvider{
    .{ .name = "claude", .hook_state = "project-local", .installable = true, .installed = false, .reason = "Claude Code hooks are supported through project-local .claude/settings.local.json when enabled for a Verde session." },
    .{ .name = "codex", .hook_state = "project-local", .installable = true, .installed = false, .reason = "Codex hooks are supported through project-local .codex/hooks.json when enabled for a Verde session." },
    .{ .name = "amp", .hook_state = "global-plugin", .installable = true, .installed = false, .reason = "Amp lifecycle events are supported through a global ~/.config/amp/plugins/verde-notify.ts plugin." },
    .{ .name = "opencode", .hook_state = "unsupported", .installable = false, .installed = false, .reason = "No stable documented hook installer is enabled in Verde yet." },
    .{ .name = "cursor", .hook_state = "unsupported", .installable = false, .installed = false, .reason = "No stable documented hook installer is enabled in Verde yet." },
};

fn handleIntegrations(allocator: std.mem.Allocator, out: output.Output, argv: []const []const u8) !void {
    if (args.hasFlag(argv, "--help") or args.hasFlag(argv, "-h")) {
        try out.stdout(
            \\Usage:
            \\  verde integrations list [--json]
            \\  verde integrations doctor [--json]
            \\  verde integrations install <claude|codex|amp|opencode|cursor> [--global]
            \\  verde integrations remove <claude|codex|amp|opencode|cursor> [--global]
            \\  verde integrations disable <claude|codex|amp|opencode|cursor>
            \\
            \\  --global installs Claude/Codex hooks in ~/.claude/settings.json or
            \\  ~/.codex/hooks.json, and installs Amp's plugin in ~/.config/amp/plugins
            \\  for all projects (no-op outside Verde panes); otherwise supported hooks
            \\  are project-local where the provider supports that.
            \\
            \\Provider hooks are optional. Verde does not overwrite provider config
            \\or change provider login/auth behavior.
            \\
        , .{});
        return;
    }

    const command = args.positional(argv, 0) orelse "list";
    const json = args.hasFlag(argv, "--json");
    if (std.mem.eql(u8, command, "list")) {
        try printIntegrationsList(allocator, out, json);
        return;
    }
    if (std.mem.eql(u8, command, "doctor")) {
        try printIntegrationsDoctor(allocator, out, json);
        return;
    }
    if (std.mem.eql(u8, command, "install") or
        std.mem.eql(u8, command, "remove") or
        std.mem.eql(u8, command, "disable"))
    {
        const provider_name = args.positional(argv, 1) orelse {
            try out.stderr("verde integrations {s} requires a provider name\n", .{command});
            std.process.exit(2);
        };
        const provider = findIntegrationProvider(provider_name) orelse {
            try out.stderr("unknown integration provider: {s}\n", .{provider_name});
            std.process.exit(2);
        };
        const global = args.hasFlag(argv, "--global");
        if (std.mem.eql(u8, command, "install")) return try installIntegration(allocator, out, json, provider, global);
        if (global and std.mem.eql(u8, provider.name, "claude")) {
            provider_hooks.removeClaudeGlobalHooks(allocator) catch |err| {
                try out.stderr("verde integrations {s} claude --global: {s}\n", .{ command, @errorName(err) });
                std.process.exit(1);
            };
            if (json) {
                try out.jsonValue(allocator, .{
                    .provider = provider.name,
                    .action = command,
                    .installed = false,
                    .changed = true,
                    .status = "removed",
                    .scope = "global",
                });
                return;
            }
            try out.stdout("verde integrations {s} claude --global: removed global Claude hooks from ~/.claude/settings.json\n", .{command});
            return;
        }
        if (global and std.mem.eql(u8, provider.name, "codex")) {
            provider_hooks.removeCodexGlobalHooks(allocator) catch |err| {
                try out.stderr("verde integrations {s} codex --global: {s}\n", .{ command, @errorName(err) });
                std.process.exit(1);
            };
            if (json) {
                try out.jsonValue(allocator, .{
                    .provider = provider.name,
                    .action = command,
                    .installed = false,
                    .changed = true,
                    .status = "removed",
                    .scope = "global",
                });
                return;
            }
            try out.stdout("verde integrations {s} codex --global: removed global Codex hooks from ~/.codex/hooks.json\n", .{command});
            return;
        }
        if (global and std.mem.eql(u8, provider.name, "amp")) {
            provider_hooks.removeAmpGlobalHooks(allocator) catch |err| {
                try out.stderr("verde integrations {s} amp --global: {s}\n", .{ command, @errorName(err) });
                std.process.exit(1);
            };
            if (json) {
                try out.jsonValue(allocator, .{
                    .provider = provider.name,
                    .action = command,
                    .installed = false,
                    .changed = true,
                    .status = "removed",
                    .scope = "global",
                });
                return;
            }
            try out.stdout("verde integrations {s} amp --global: removed global Amp plugin from ~/.config/amp/plugins/verde-notify.ts\n", .{command});
            return;
        }
        try printIntegrationNoInstalledHook(allocator, out, json, command, provider);
        return;
    }

    try out.stderr("unknown integrations command: {s}\n", .{command});
    std.process.exit(2);
}

fn findIntegrationProvider(name: []const u8) ?IntegrationProvider {
    for (integration_providers) |provider| {
        if (std.mem.eql(u8, provider.name, name)) return provider;
    }
    return null;
}

fn printIntegrationsList(allocator: std.mem.Allocator, out: output.Output, json: bool) !void {
    if (json) {
        try out.jsonValue(allocator, .{
            .providers = integration_providers[0..],
            .policy = .{
                .writes_config = true,
                .writes_project_config_only = false,
                .requires_verde_env = true,
                .changes_auth = false,
            },
        });
        return;
    }
    try out.stdout("Provider integrations:\n", .{});
    for (integration_providers) |provider| {
        try out.stdout("  {s}: {s} ({s})\n", .{ provider.name, provider.hook_state, provider.reason });
    }
}

fn printIntegrationsDoctor(allocator: std.mem.Allocator, out: output.Output, json: bool) !void {
    const verde_env = getenvSlice("VERDE") orelse "";
    const has_identity = getenvSlice("VERDE_SESSION_ID") != null and
        (getenvSlice("VERDE_LIVE_ENDPOINT") != null or
            getenvSlice("VERDE_SOCKET") != null or
            getenvSlice("VERDE_LIVE_SOCKET") != null or
            getenvSlice("VERDE_SESSIONIZER_SOCKET") != null);
    if (json) {
        try out.jsonValue(allocator, .{
            .verde_env = std.mem.eql(u8, verde_env, "1"),
            .has_terminal_identity = has_identity,
            .providers = integration_providers[0..],
            .summary = "Claude/Codex hooks and the Amp global plugin are available; other providers currently use generic verde notify, OSC, and MCP paths.",
        });
        return;
    }
    try out.stdout(
        \\Integration doctor:
        \\  VERDE=1: {s}
        \\  terminal identity: {s}
        \\  hook installers: claude, codex project-local/global; amp global plugin
        \\  generic paths: verde notify, OSC 777 notify, MCP surface tools
        \\
    , .{
        if (std.mem.eql(u8, verde_env, "1")) "yes" else "no",
        if (has_identity) "yes" else "no",
    });
}

fn installIntegration(allocator: std.mem.Allocator, out: output.Output, json: bool, provider: IntegrationProvider, global: bool) !void {
    const project_path = ".";
    if (std.mem.eql(u8, provider.name, "claude") and global) {
        provider_hooks.ensureClaudeGlobalHooks(allocator) catch |err| {
            if (json) {
                try out.jsonValue(allocator, .{
                    .provider = provider.name,
                    .action = "install",
                    .installed = false,
                    .status = "error",
                    .scope = "global",
                    .reason = @errorName(err),
                });
                return;
            }
            try out.stderr("verde integrations install claude --global: {s}\n", .{@errorName(err)});
            std.process.exit(1);
        };
        if (json) {
            try out.jsonValue(allocator, .{
                .provider = provider.name,
                .action = "install",
                .installed = true,
                .status = "installed",
                .scope = "global",
                .path = "~/.claude/settings.json",
            });
            return;
        }
        try out.stdout("verde integrations install claude --global: installed global Claude hooks in ~/.claude/settings.json\n", .{});
        return;
    }
    if (std.mem.eql(u8, provider.name, "claude")) {
        provider_hooks.ensureClaudeProjectHooks(allocator, project_path) catch |err| switch (err) {
            error.ClaudeSettingsExist => {
                if (json) {
                    try out.jsonValue(allocator, .{
                        .provider = provider.name,
                        .action = "install",
                        .installed = false,
                        .status = "blocked",
                        .reason = ".claude/settings.local.json already exists and is not managed by Verde; refusing to overwrite user settings.",
                    });
                    return;
                }
                try out.stderr("verde integrations install claude: .claude/settings.local.json already exists and is not managed by Verde; refusing to overwrite user settings\n", .{});
                std.process.exit(1);
            },
            else => return err,
        };
        if (json) {
            try out.jsonValue(allocator, .{
                .provider = provider.name,
                .action = "install",
                .installed = true,
                .status = "installed",
                .path = ".claude/settings.local.json",
            });
            return;
        }
        try out.stdout("verde integrations install claude: installed project-local Claude hooks in .claude/settings.local.json\n", .{});
        return;
    }

    if (std.mem.eql(u8, provider.name, "codex") and global) {
        provider_hooks.ensureCodexGlobalHooks(allocator) catch |err| {
            if (json) {
                try out.jsonValue(allocator, .{
                    .provider = provider.name,
                    .action = "install",
                    .installed = false,
                    .status = "error",
                    .scope = "global",
                    .reason = @errorName(err),
                });
                return;
            }
            try out.stderr("verde integrations install codex --global: {s}\n", .{@errorName(err)});
            std.process.exit(1);
        };
        if (json) {
            try out.jsonValue(allocator, .{
                .provider = provider.name,
                .action = "install",
                .installed = true,
                .status = "installed",
                .scope = "global",
                .path = "~/.codex/hooks.json",
            });
            return;
        }
        try out.stdout("verde integrations install codex --global: merged global Codex hooks into ~/.codex/hooks.json\n", .{});
        return;
    }

    if (std.mem.eql(u8, provider.name, "amp") and global) {
        provider_hooks.ensureAmpGlobalHooks(allocator) catch |err| {
            if (json) {
                try out.jsonValue(allocator, .{
                    .provider = provider.name,
                    .action = "install",
                    .installed = false,
                    .status = "error",
                    .scope = "global",
                    .reason = @errorName(err),
                });
                return;
            }
            try out.stderr("verde integrations install amp --global: {s}\n", .{@errorName(err)});
            std.process.exit(1);
        };
        if (json) {
            try out.jsonValue(allocator, .{
                .provider = provider.name,
                .action = "install",
                .installed = true,
                .status = "installed",
                .scope = "global",
                .path = "~/.config/amp/plugins/verde-notify.ts",
            });
            return;
        }
        try out.stdout("verde integrations install amp --global: installed global Amp plugin in ~/.config/amp/plugins/verde-notify.ts\n", .{});
        return;
    }

    if (!std.mem.eql(u8, provider.name, "codex")) {
        try printIntegrationInstallUnsupported(allocator, out, json, provider);
        std.process.exit(1);
    }

    provider_hooks.ensureCodexProjectHooks(allocator, project_path) catch |err| switch (err) {
        error.CodexHooksJsonExists => {
            if (json) {
                try out.jsonValue(allocator, .{
                    .provider = provider.name,
                    .action = "install",
                    .installed = false,
                    .status = "blocked",
                    .reason = ".codex/hooks.json already exists and is not managed by Verde; refusing to overwrite user hooks.",
                });
                return;
            }
            try out.stderr("verde integrations install codex: .codex/hooks.json already exists and is not managed by Verde; refusing to overwrite user hooks\n", .{});
            std.process.exit(1);
        },
        else => return err,
    };

    if (json) {
        try out.jsonValue(allocator, .{
            .provider = provider.name,
            .action = "install",
            .installed = true,
            .status = "installed",
            .path = ".codex/hooks.json",
        });
        return;
    }
    try out.stdout("verde integrations install codex: installed project-local Codex hooks in .codex/hooks.json\n", .{});
}

fn printIntegrationInstallUnsupported(allocator: std.mem.Allocator, out: output.Output, json: bool, provider: IntegrationProvider) !void {
    if (json) {
        try out.jsonValue(allocator, .{
            .provider = provider.name,
            .action = "install",
            .installed = false,
            .status = "unsupported",
            .reason = provider.reason,
        });
        return;
    }
    try out.stderr("verde integrations install {s}: {s}\n", .{ provider.name, provider.reason });
}

fn printIntegrationNoInstalledHook(allocator: std.mem.Allocator, out: output.Output, json: bool, action: []const u8, provider: IntegrationProvider) !void {
    if (json) {
        try out.jsonValue(allocator, .{
            .provider = provider.name,
            .action = action,
            .installed = false,
            .changed = false,
            .status = "not_installed",
        });
        return;
    }
    try out.stdout("verde integrations {s} {s}: no installed hook to change\n", .{ action, provider.name });
}

fn handleLiveWorkspace(allocator: std.mem.Allocator, out: output.Output, io: std.Io, argv: []const []const u8, json: bool) !void {
    const subcommand = args.positional(argv, 1) orelse {
        try out.stderr("missing live workspace command\n", .{});
        std.process.exit(2);
    };
    if (std.mem.eql(u8, subcommand, "select")) {
        try sendLiveRequest(allocator, out, io, "workspace.select", .{
            .workspace = workspaceOption(argv) orelse trailingFreeArg(argv, 2) orelse "current",
        }, json);
        return;
    }
    if (std.mem.eql(u8, subcommand, "create")) {
        const path = args.optionValue(argv, "--path") orelse trailingFreeArg(argv, 2) orelse {
            try out.stderr("verde live workspace create requires --path\n", .{});
            std.process.exit(2);
        };
        try sendLiveRequest(allocator, out, io, "workspace.create", .{ .path = path }, json);
        return;
    }
    if (std.mem.eql(u8, subcommand, "rename")) {
        const label = args.optionValue(argv, "--label") orelse args.optionValue(argv, "--name") orelse trailingFreeArg(argv, 2) orelse {
            try out.stderr("verde live workspace rename requires --label\n", .{});
            std.process.exit(2);
        };
        try sendLiveRequest(allocator, out, io, "workspace.rename", .{
            .workspace = workspaceOption(argv),
            .label = label,
        }, json);
        return;
    }
    if (std.mem.eql(u8, subcommand, "close") or std.mem.eql(u8, subcommand, "archive")) {
        try sendLiveRequest(allocator, out, io, "workspace.close", .{
            .workspace = workspaceOption(argv) orelse trailingFreeArg(argv, 2) orelse "current",
        }, json);
        return;
    }
    if (std.mem.eql(u8, subcommand, "reopen")) {
        try sendLiveRequest(allocator, out, io, "workspace.reopen", .{
            .workspace = workspaceOption(argv) orelse trailingFreeArg(argv, 2) orelse "last",
        }, json);
        return;
    }
    try out.stderr("unknown live workspace command: {s}\n", .{subcommand});
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
    if (std.mem.eql(u8, subcommand, "move")) {
        try sendLiveRequest(allocator, out, io, "pane.move", .{
            .workspace = workspaceOption(argv),
            .pane = try paneOption(out, argv),
            .focused = args.hasFlag(argv, "--focused"),
            .direction = args.optionValue(argv, "--direction") orelse trailingFreeArg(argv, 2) orelse "right",
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
        const url = args.optionValue(argv, "--url") orelse trailingFreeArg(argv, 2);
        try sendLiveRequest(allocator, out, io, "browser.open", .{
            .url = url,
            .project = try liveBrowserOpenProject(out, argv),
        }, json);
        return;
    }
    if (std.mem.eql(u8, subcommand, "navigate")) {
        const url = args.optionValue(argv, "--url") orelse trailingFreeArg(argv, 2) orelse {
            try out.stderr("verde live browser navigate requires --url\n", .{});
            std.process.exit(2);
        };
        try sendLiveRequest(allocator, out, io, "browser.navigate", .{ .url = url }, json);
        return;
    }
    if (std.mem.eql(u8, subcommand, "status")) {
        try sendLiveRequest(allocator, out, io, "browser.status", .{}, json);
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

fn handleLivePalette(allocator: std.mem.Allocator, out: output.Output, io: std.Io, argv: []const []const u8, json: bool) !void {
    const subcommand = args.positional(argv, 1) orelse {
        try out.stderr("missing live palette command\n", .{});
        std.process.exit(2);
    };
    if (std.mem.eql(u8, subcommand, "list")) {
        try sendLiveRequest(allocator, out, io, "palette.list", .{}, json);
        return;
    }
    if (std.mem.eql(u8, subcommand, "run")) {
        const command = args.optionValue(argv, "--command") orelse trailingFreeArg(argv, 2) orelse {
            try out.stderr("verde live palette run requires --command\n", .{});
            std.process.exit(2);
        };
        try sendLiveRequest(allocator, out, io, "palette.run", .{ .command = command }, json);
        return;
    }
    try out.stderr("unknown live palette command: {s}\n", .{subcommand});
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

fn handleLiveAgent(allocator: std.mem.Allocator, out: output.Output, io: std.Io, argv: []const []const u8, json: bool) !void {
    const subcommand = args.positional(argv, 1) orelse {
        try out.stderr("missing live agent command\n", .{});
        std.process.exit(2);
    };
    if (std.mem.eql(u8, subcommand, "open")) {
        try sendLiveRequest(allocator, out, io, "agent.open", .{
            .workspace = workspaceOption(argv),
            .provider = args.optionValue(argv, "--provider") orelse "codex",
        }, json);
        return;
    }
    try out.stderr("unknown live agent command: {s}\n", .{subcommand});
    std.process.exit(2);
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
    const pref_path = try prefPath(allocator);
    defer allocator.free(pref_path);
    const endpoint = try live_endpoint.alloc(allocator, pref_path);
    defer allocator.free(endpoint);

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
    return try platform_ipc.requestAlloc(allocator, endpoint, request_json, .{
        .timeout_ms = LIVE_RESPONSE_TIMEOUT_MS,
    });
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

    const attach_id = attachSessionClient(allocator, io, session_id, "verde-cli") catch |err| {
        try out.stderr("failed to attach to terminal session {s}: {s}\n", .{ session_id, @errorName(err) });
        return err;
    };
    defer allocator.free(attach_id);
    defer detachSessionClient(allocator, io, session_id, attach_id);

    const explicit_cols = parseOptionalU32(args.optionValue(argv, "--cols"));
    const explicit_rows = parseOptionalU32(args.optionValue(argv, "--rows"));
    var current_size = terminalAttachSize(explicit_cols, explicit_rows);
    const resize_response = try sendSessionRequestAlloc(allocator, io, "session.resize", .{
        .id = session_id,
        .attach_id = attach_id,
        .cols = current_size.cols,
        .rows = current_size.rows,
    }, 1);
    allocator.free(resize_response);

    const terminal_mode = enterRawMode() catch null;
    defer if (terminal_mode) |mode| restoreTerminalMode(mode);

    const input_polling = try beginAttachInputPolling();
    defer endAttachInputPolling(input_polling);

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
                    .attach_id = attach_id,
                    .cols = current_size.cols,
                    .rows = current_size.rows,
                }, 1);
                allocator.free(response);
            }
        }

        try forwardWindowsAttachControlEvents(allocator, io, session_id, attach_id);
        try drainAttachInput(allocator, io, session_id, attach_id, &stdin_eof, &detach_requested);
        if (detach_requested) break;

        var read_result = try readSessionOutput(allocator, io, session_id, attach_id, next_offset);
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
    if (builtin.os.tag == .windows) return readWindowsTerminalAttachSize();

    var winsize: std.posix.winsize = undefined;
    if (std.c.ioctl(std.posix.STDOUT_FILENO, TERMINAL_GET_WINSIZE_IOCTL, &winsize) != 0 and
        std.c.ioctl(std.posix.STDIN_FILENO, TERMINAL_GET_WINSIZE_IOCTL, &winsize) != 0)
    {
        return null;
    }
    if (winsize.col == 0 or winsize.row == 0) return null;
    return .{ .cols = winsize.col, .rows = winsize.row };
}

fn readWindowsTerminalAttachSize() ?AttachSize {
    var info: ConsoleScreenBufferInfo = undefined;
    if (GetConsoleScreenBufferInfo(std.Io.File.stdout().handle, &info) == .FALSE) return null;
    const cols = @as(i32, info.window.right) - @as(i32, info.window.left) + 1;
    const rows = @as(i32, info.window.bottom) - @as(i32, info.window.top) + 1;
    if (cols <= 0 or rows <= 0) return null;
    return .{ .cols = @intCast(cols), .rows = @intCast(rows) };
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
    if (builtin.os.tag == .windows) {
        return drainWindowsAttachInput(allocator, io, session_id, attach_id, stdin_eof, detach_requested);
    }
    return drainPosixAttachInput(allocator, io, session_id, attach_id, stdin_eof, detach_requested);
}

fn drainPosixAttachInput(
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

fn drainWindowsAttachInput(
    allocator: std.mem.Allocator,
    io: std.Io,
    session_id: []const u8,
    attach_id: []const u8,
    stdin_eof: *bool,
    detach_requested: *bool,
) !void {
    if (stdin_eof.*) return;
    const windows = std.os.windows;
    const stdin_handle = std.Io.File.stdin().handle;
    var buffer: [4096]u8 = undefined;

    while (windowsInputAvailable(stdin_handle)) |available| {
        if (available == 0) return;
        var read_len: windows.DWORD = 0;
        const wanted: windows.DWORD = @intCast(@min(buffer.len, available));
        if (ReadFile(stdin_handle, &buffer, wanted, &read_len, null) == .FALSE) {
            switch (windows.GetLastError()) {
                .BROKEN_PIPE, .NO_DATA => stdin_eof.* = true,
                else => {},
            }
            return;
        }
        if (read_len == 0) {
            stdin_eof.* = true;
            return;
        }
        const input = buffer[0..read_len];
        if (std.mem.indexOfScalar(u8, input, 0x1d) != null) {
            detach_requested.* = true;
            stdin_eof.* = true;
            return;
        }
        const response = try sendSessionRequestAlloc(allocator, io, "session.write", .{
            .id = session_id,
            .attach_id = attach_id,
            .text = input,
        }, 1);
        allocator.free(response);
    } else |_| {
        stdin_eof.* = true;
    }
}

fn windowsInputAvailable(handle: std.os.windows.HANDLE) !usize {
    var console_mode: std.os.windows.DWORD = 0;
    if (GetConsoleMode(handle, &console_mode) != .FALSE) {
        var event_count: std.os.windows.DWORD = 0;
        if (GetNumberOfConsoleInputEvents(handle, &event_count) == .FALSE) return error.ConsoleInputFailed;
        // ReadFile consumes the VT-encoded bytes represented by one or more
        // console input records. Its byte count is not the event count, so use
        // the full buffer whenever at least one record is ready.
        return if (event_count == 0) 0 else 4096;
    }

    var available: std.os.windows.DWORD = 0;
    if (PeekNamedPipe(handle, null, 0, null, &available, null) != .FALSE) return available;
    return switch (std.os.windows.GetLastError()) {
        .BROKEN_PIPE, .NO_DATA => error.EndOfStream,
        // Disk files are always synchronously readable; a failed pipe peek is
        // not by itself evidence that stdin is unavailable.
        .INVALID_HANDLE => 4096,
        else => error.InputUnavailable,
    };
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

const TerminalMode = if (builtin.os.tag == .windows) WindowsTerminalMode else PosixTerminalMode;

const PosixTerminalMode = struct {
    original: std.posix.termios,
};

const WindowsTerminalMode = struct {
    input_handle: std.os.windows.HANDLE,
    input_mode: std.os.windows.DWORD,
    output_handle: std.os.windows.HANDLE,
    output_mode: ?std.os.windows.DWORD,
    input_code_page: std.os.windows.UINT,
    output_code_page: std.os.windows.UINT,
    control_handler_installed: bool,
};

const SmallRect = extern struct {
    left: i16,
    top: i16,
    right: i16,
    bottom: i16,
};

const ConsoleScreenBufferInfo = extern struct {
    size: std.os.windows.COORD,
    cursor_position: std.os.windows.COORD,
    attributes: std.os.windows.WORD,
    window: SmallRect,
    maximum_window_size: std.os.windows.COORD,
};

const ENABLE_PROCESSED_INPUT: std.os.windows.DWORD = 0x0001;
const ENABLE_LINE_INPUT: std.os.windows.DWORD = 0x0002;
const ENABLE_ECHO_INPUT: std.os.windows.DWORD = 0x0004;
const ENABLE_WINDOW_INPUT: std.os.windows.DWORD = 0x0008;
const ENABLE_MOUSE_INPUT: std.os.windows.DWORD = 0x0010;
const ENABLE_QUICK_EDIT_MODE: std.os.windows.DWORD = 0x0040;
const ENABLE_EXTENDED_FLAGS: std.os.windows.DWORD = 0x0080;
const ENABLE_VIRTUAL_TERMINAL_INPUT: std.os.windows.DWORD = 0x0200;
const ENABLE_PROCESSED_OUTPUT: std.os.windows.DWORD = 0x0001;
const ENABLE_VIRTUAL_TERMINAL_PROCESSING: std.os.windows.DWORD = 0x0004;
const CP_UTF8: std.os.windows.UINT = 65001;
const CTRL_C_EVENT: std.os.windows.DWORD = 0;
const CTRL_BREAK_EVENT: std.os.windows.DWORD = 1;
const WINDOWS_ATTACH_CTRL_C: u8 = 1 << 0;
const WINDOWS_ATTACH_CTRL_BREAK: u8 = 1 << 1;

var windows_attach_control_events: std.atomic.Value(u8) = .init(0);

extern "kernel32" fn GetConsoleMode(handle: std.os.windows.HANDLE, mode: *std.os.windows.DWORD) callconv(.winapi) std.os.windows.BOOL;
extern "kernel32" fn SetConsoleMode(handle: std.os.windows.HANDLE, mode: std.os.windows.DWORD) callconv(.winapi) std.os.windows.BOOL;
extern "kernel32" fn GetNumberOfConsoleInputEvents(handle: std.os.windows.HANDLE, count: *std.os.windows.DWORD) callconv(.winapi) std.os.windows.BOOL;
extern "kernel32" fn GetConsoleScreenBufferInfo(handle: std.os.windows.HANDLE, info: *ConsoleScreenBufferInfo) callconv(.winapi) std.os.windows.BOOL;
extern "kernel32" fn PeekNamedPipe(handle: std.os.windows.HANDLE, buffer: ?*anyopaque, buffer_len: std.os.windows.DWORD, bytes_read: ?*std.os.windows.DWORD, total_available: ?*std.os.windows.DWORD, bytes_left: ?*std.os.windows.DWORD) callconv(.winapi) std.os.windows.BOOL;
extern "kernel32" fn ReadFile(handle: std.os.windows.HANDLE, buffer: [*]u8, bytes_to_read: std.os.windows.DWORD, bytes_read: *std.os.windows.DWORD, overlapped: ?*anyopaque) callconv(.winapi) std.os.windows.BOOL;
extern "kernel32" fn WriteFile(handle: std.os.windows.HANDLE, buffer: [*]const u8, bytes_to_write: std.os.windows.DWORD, bytes_written: *std.os.windows.DWORD, overlapped: ?*anyopaque) callconv(.winapi) std.os.windows.BOOL;
extern "kernel32" fn GetConsoleCP() callconv(.winapi) std.os.windows.UINT;
extern "kernel32" fn GetConsoleOutputCP() callconv(.winapi) std.os.windows.UINT;
extern "kernel32" fn SetConsoleCP(code_page: std.os.windows.UINT) callconv(.winapi) std.os.windows.BOOL;
extern "kernel32" fn SetConsoleOutputCP(code_page: std.os.windows.UINT) callconv(.winapi) std.os.windows.BOOL;
extern "kernel32" fn SetConsoleCtrlHandler(
    handler: ?*const fn (control_type: std.os.windows.DWORD) callconv(.winapi) std.os.windows.BOOL,
    add: std.os.windows.BOOL,
) callconv(.winapi) std.os.windows.BOOL;

fn enterRawMode() !TerminalMode {
    if (builtin.os.tag == .windows) return enterWindowsRawMode();

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
    if (builtin.os.tag == .windows) return restoreWindowsTerminalMode(mode);
    std.posix.tcsetattr(std.posix.STDIN_FILENO, .FLUSH, mode.original) catch {};
}

fn enterWindowsRawMode() !WindowsTerminalMode {
    const input_handle = std.Io.File.stdin().handle;
    const output_handle = std.Io.File.stdout().handle;
    var input_mode: std.os.windows.DWORD = 0;
    if (GetConsoleMode(input_handle, &input_mode) == .FALSE) return error.NotTerminal;

    const raw_input = (input_mode & ~@as(std.os.windows.DWORD, ENABLE_PROCESSED_INPUT |
        ENABLE_LINE_INPUT |
        ENABLE_ECHO_INPUT |
        ENABLE_WINDOW_INPUT |
        ENABLE_MOUSE_INPUT |
        ENABLE_QUICK_EDIT_MODE)) |
        ENABLE_EXTENDED_FLAGS |
        ENABLE_VIRTUAL_TERMINAL_INPUT;
    if (SetConsoleMode(input_handle, raw_input) == .FALSE) return error.ConsoleModeFailed;
    errdefer _ = SetConsoleMode(input_handle, input_mode);

    windows_attach_control_events.store(0, .release);
    if (SetConsoleCtrlHandler(&windowsAttachControlHandler, .TRUE) == .FALSE) return error.ConsoleControlHandlerFailed;
    errdefer _ = SetConsoleCtrlHandler(&windowsAttachControlHandler, .FALSE);

    var output_mode_value: std.os.windows.DWORD = 0;
    const output_mode: ?std.os.windows.DWORD = if (GetConsoleMode(output_handle, &output_mode_value) != .FALSE)
        output_mode_value
    else
        null;
    if (output_mode) |mode| {
        _ = SetConsoleMode(output_handle, mode | ENABLE_PROCESSED_OUTPUT | ENABLE_VIRTUAL_TERMINAL_PROCESSING);
    }

    const input_code_page = GetConsoleCP();
    const output_code_page = GetConsoleOutputCP();
    _ = SetConsoleCP(CP_UTF8);
    _ = SetConsoleOutputCP(CP_UTF8);
    return .{
        .input_handle = input_handle,
        .input_mode = input_mode,
        .output_handle = output_handle,
        .output_mode = output_mode,
        .input_code_page = input_code_page,
        .output_code_page = output_code_page,
        .control_handler_installed = true,
    };
}

fn restoreWindowsTerminalMode(mode: WindowsTerminalMode) void {
    _ = SetConsoleMode(mode.input_handle, mode.input_mode);
    if (mode.output_mode) |output_mode| _ = SetConsoleMode(mode.output_handle, output_mode);
    if (mode.input_code_page != 0) _ = SetConsoleCP(mode.input_code_page);
    if (mode.output_code_page != 0) _ = SetConsoleOutputCP(mode.output_code_page);
    if (mode.control_handler_installed) _ = SetConsoleCtrlHandler(&windowsAttachControlHandler, .FALSE);
    windows_attach_control_events.store(0, .release);
}

fn windowsAttachControlHandler(control_type: std.os.windows.DWORD) callconv(.winapi) std.os.windows.BOOL {
    const event_bit = windowsAttachControlEventBit(control_type) orelse return .FALSE;
    _ = windows_attach_control_events.fetchOr(event_bit, .release);
    return .TRUE;
}

fn windowsAttachControlEventBit(control_type: std.os.windows.DWORD) ?u8 {
    return switch (control_type) {
        CTRL_C_EVENT => WINDOWS_ATTACH_CTRL_C,
        CTRL_BREAK_EVENT => WINDOWS_ATTACH_CTRL_BREAK,
        else => null,
    };
}

fn forwardWindowsAttachControlEvents(
    allocator: std.mem.Allocator,
    io: std.Io,
    session_id: []const u8,
    attach_id: []const u8,
) !void {
    if (builtin.os.tag != .windows) return;
    const events = windows_attach_control_events.swap(0, .acquire);
    if (events == 0) return;

    // ConPTY consumes terminal input bytes rather than inheriting this console
    // process group. Translate both Windows control notifications to ETX, the
    // same interrupt byte produced by Ctrl+C in raw VT input mode.
    if (events & WINDOWS_ATTACH_CTRL_C != 0) {
        const response = try sendSessionRequestAlloc(allocator, io, "session.write", .{
            .id = session_id,
            .attach_id = attach_id,
            .text = "\x03",
        }, 1);
        allocator.free(response);
    }
    if (events & WINDOWS_ATTACH_CTRL_BREAK != 0) {
        const response = try sendSessionRequestAlloc(allocator, io, "session.write", .{
            .id = session_id,
            .attach_id = attach_id,
            .text = "\x03",
        }, 1);
        allocator.free(response);
    }
}

const AttachInputPolling = if (builtin.os.tag == .windows) struct {} else struct { original_flags: ?c_int };

fn beginAttachInputPolling() !AttachInputPolling {
    if (builtin.os.tag == .windows) return .{};
    return .{ .original_flags = setFdNonBlocking(std.posix.STDIN_FILENO) catch null };
}

fn endAttachInputPolling(state: AttachInputPolling) void {
    if (builtin.os.tag == .windows) return;
    if (state.original_flags) |flags| restoreFdFlags(std.posix.STDIN_FILENO, flags);
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
    if (builtin.os.tag == .windows) return writeWindowsStdout(bytes);

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

fn writeWindowsStdout(bytes: []const u8) !void {
    var remaining = bytes;
    const stdout_handle = std.Io.File.stdout().handle;
    while (remaining.len > 0) {
        var written: std.os.windows.DWORD = 0;
        const chunk_len: std.os.windows.DWORD = @intCast(@min(remaining.len, std.math.maxInt(std.os.windows.DWORD)));
        if (WriteFile(stdout_handle, remaining.ptr, chunk_len, &written, null) == .FALSE) return error.StdoutWriteFailed;
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
    return try std.fmt.allocPrint(allocator, "verde:cli:{d}", .{platform_runtime.processId()});
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
    try writeMcpTool(&s, "list_surfaces", "List live Verde terminal surfaces.");
    try writeMcpTool(&s, "inspect_surface", "Inspect one Verde terminal surface.");
    try writeMcpTool(&s, "focus_surface", "Focus a Verde terminal surface.");
    try writeMcpTool(&s, "read_surface_screen", "Read the current screen text for a terminal surface pane.");
    try writeMcpTool(&s, "tail_surface_output", "Read recent terminal output for a surface pane.");
    try writeMcpTool(&s, "write_surface_text", "Write text to a terminal surface pane.");
    try writeMcpTool(&s, "notify_surface", "Update terminal surface status or notification text.");
    try writeMcpTool(&s, "clear_surface_attention", "Clear terminal surface attention.");
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
    const session_id = mcpArgString(arguments, "session_id") orelse mcpArgString(arguments, "session");
    const pane_id = mcpArgU32(arguments, "pane_id") orelse mcpArgU32(arguments, "pane");
    const lines = mcpArgU32(arguments, "lines");

    const response = blk: {
        if (std.mem.eql(u8, tool_name, "list_surfaces")) {
            break :blk sendLiveRequestAlloc(allocator, io, "surfaces", .{}, 1);
        }
        if (std.mem.eql(u8, tool_name, "inspect_surface")) {
            const session = session_id orelse return try mcpError(allocator, out, id_value, -32602, "inspect_surface requires session_id");
            break :blk sendLiveRequestAlloc(allocator, io, "surface.inspect", .{ .session_id = session }, 1);
        }
        if (std.mem.eql(u8, tool_name, "focus_surface")) {
            const session = session_id orelse return try mcpError(allocator, out, id_value, -32602, "focus_surface requires session_id");
            break :blk sendLiveRequestAlloc(allocator, io, "surface.focus", .{ .session_id = session }, 1);
        }
        if (std.mem.eql(u8, tool_name, "read_surface_screen")) {
            const pane = pane_id orelse return try mcpError(allocator, out, id_value, -32602, "read_surface_screen requires pane_id");
            break :blk sendLiveRequestAlloc(allocator, io, "terminal.screen", .{ .workspace = workspace, .pane = pane }, 1);
        }
        if (std.mem.eql(u8, tool_name, "tail_surface_output")) {
            const pane = pane_id orelse return try mcpError(allocator, out, id_value, -32602, "tail_surface_output requires pane_id");
            break :blk sendLiveRequestAlloc(allocator, io, "terminal.tail", .{ .workspace = workspace, .pane = pane, .lines = lines }, 1);
        }
        if (std.mem.eql(u8, tool_name, "write_surface_text")) {
            const pane = pane_id orelse return try mcpError(allocator, out, id_value, -32602, "write_surface_text requires pane_id");
            const text = mcpArgString(arguments, "text") orelse return try mcpError(allocator, out, id_value, -32602, "write_surface_text requires text");
            break :blk sendLiveRequestAlloc(allocator, io, "terminal.write", .{ .workspace = workspace, .pane = pane, .text = text }, 1);
        }
        if (std.mem.eql(u8, tool_name, "notify_surface")) {
            const session = session_id orelse return try mcpError(allocator, out, id_value, -32602, "notify_surface requires session_id");
            break :blk sendLiveRequestAlloc(allocator, io, "notification.update", .{
                .session_id = session,
                .workspace = workspace,
                .pane = pane_id,
                .title = mcpArgString(arguments, "title"),
                .body = mcpArgString(arguments, "body"),
                .label = mcpArgString(arguments, "label"),
                .status = mcpArgString(arguments, "status"),
                .progress = mcpArgF32(arguments, "progress"),
                .attention = mcpArgBool(arguments, "attention"),
            }, 1);
        }
        if (std.mem.eql(u8, tool_name, "clear_surface_attention")) {
            const session = session_id orelse return try mcpError(allocator, out, id_value, -32602, "clear_surface_attention requires session_id");
            break :blk sendLiveRequestAlloc(allocator, io, "surface.clearAttention", .{ .session_id = session }, 1);
        }
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

fn mcpArgF32(arguments: std.json.Value, name: []const u8) ?f32 {
    if (arguments != .object) return null;
    const value = arguments.object.get(name) orelse .null;
    return switch (value) {
        .integer => |int| @floatFromInt(int),
        .float => |float| @floatCast(float),
        .number_string => |text| std.fmt.parseFloat(f32, text) catch null,
        else => null,
    };
}

fn mcpArgBool(arguments: std.json.Value, name: []const u8) ?bool {
    if (arguments != .object) return null;
    return switch (arguments.object.get(name) orelse .null) {
        .bool => |value| value,
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

fn liveBrowserOpenProject(out: output.Output, argv: []const []const u8) ![]const u8 {
    if (workspaceOption(argv)) |value| return try resolveLiveProjectSelector(out, value);
    if (getenvSlice("VERDE_WORKSPACE_ID")) |workspace_id| return workspace_id;
    return "current";
}

fn resolveLiveProjectSelector(out: output.Output, value: []const u8) ![]const u8 {
    if (!std.mem.eql(u8, value, "self")) return value;
    if (getenvSlice("VERDE_WORKSPACE_ID")) |workspace_id| return workspace_id;
    if (getenvSlice("VERDE_WORKSPACE_PATH")) |workspace_path| return workspace_path;
    try out.stderr("project selector 'self' requires VERDE_WORKSPACE_ID or VERDE_WORKSPACE_PATH\n", .{});
    std.process.exit(2);
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

fn parseOptionalF32(value: ?[]const u8) ?f32 {
    const raw = value orelse return null;
    return std.fmt.parseFloat(f32, raw) catch null;
}

fn getenvSlice(name: [:0]const u8) ?[]const u8 {
    const ptr = std.c.getenv(name) orelse return null;
    return std.mem.span(ptr);
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
        std.mem.eql(u8, name, "--herdr-workspace") or
        std.mem.eql(u8, name, "--project") or
        std.mem.eql(u8, name, "--id") or
        std.mem.eql(u8, name, "--pane") or
        std.mem.eql(u8, name, "--kind") or
        std.mem.eql(u8, name, "--axis") or
        std.mem.eql(u8, name, "--first") or
        std.mem.eql(u8, name, "--second") or
        std.mem.eql(u8, name, "--ratio") or
        std.mem.eql(u8, name, "--direction") or
        std.mem.eql(u8, name, "--path") or
        std.mem.eql(u8, name, "--url") or
        std.mem.eql(u8, name, "--text") or
        std.mem.eql(u8, name, "--target") or
        std.mem.eql(u8, name, "--title") or
        std.mem.eql(u8, name, "--body") or
        std.mem.eql(u8, name, "--status") or
        std.mem.eql(u8, name, "--progress") or
        std.mem.eql(u8, name, "--label") or
        std.mem.eql(u8, name, "--session") or
        std.mem.eql(u8, name, "--remote") or
        std.mem.eql(u8, name, "--cwd") or
        std.mem.eql(u8, name, "--remote-cwd") or
        std.mem.eql(u8, name, "--local-dir") or
        std.mem.eql(u8, name, "--session-id") or
        std.mem.eql(u8, name, "--dock") or
        std.mem.eql(u8, name, "--script") or
        std.mem.eql(u8, name, "--json-payload") or
        std.mem.eql(u8, name, "--mode") or
        std.mem.eql(u8, name, "--command") or
        std.mem.eql(u8, name, "--prompt") or
        std.mem.eql(u8, name, "--call") or
        std.mem.eql(u8, name, "--decision") or
        std.mem.eql(u8, name, "--name") or
        std.mem.eql(u8, name, "--provider") or
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
    return platform_paths.sdlPrefPathFallback(allocator, "verde", "Native");
}

test "cli args parse command and json flag" {
    const argv = [_][]const u8{ "verde", "state", "workspaces", "--json" };
    const parsed = args.parse(&argv);
    try std.testing.expectEqualStrings("state", parsed.command);
    try std.testing.expect(parsed.json);
}

test "update is advertised as a top-level command" {
    for (spec.top_level_commands) |command| {
        if (std.mem.eql(u8, command, "update")) return;
    }
    return error.MissingUpdateCommand;
}

test "open free arg skips project option value" {
    const argv = [_][]const u8{ "--project", "self", "https://example.com" };
    const url = trailingFreeArg(&argv, 0) orelse return error.MissingUrl;
    try std.testing.expectEqualStrings("https://example.com", url);
}

test "label consumes its value for trailing free arg parsing" {
    const argv = [_][]const u8{ "workspace", "rename", "--label", "new label" };
    try std.testing.expect(trailingFreeArg(&argv, 2) == null);
    try std.testing.expect(optionConsumesValue("--label"));
}

fn flagIsBare(name: []const u8) bool {
    return std.mem.eql(u8, name, "--help") or
        std.mem.eql(u8, name, "-h") or
        std.mem.eql(u8, name, "--json") or
        std.mem.eql(u8, name, "--focused") or
        std.mem.eql(u8, name, "--clear") or
        std.mem.eql(u8, name, "--quiet");
}

test "value-taking cli spec flags are covered by free arg parser" {
    for (spec.all_flags) |flag| {
        if (flagIsBare(flag)) continue;
        try std.testing.expect(optionConsumesValue(flag));
    }
}

test "Windows attach console handler catches only interrupt controls" {
    try std.testing.expectEqual(WINDOWS_ATTACH_CTRL_C, windowsAttachControlEventBit(CTRL_C_EVENT).?);
    try std.testing.expectEqual(WINDOWS_ATTACH_CTRL_BREAK, windowsAttachControlEventBit(CTRL_BREAK_EVENT).?);
    try std.testing.expect(windowsAttachControlEventBit(2) == null);
}
