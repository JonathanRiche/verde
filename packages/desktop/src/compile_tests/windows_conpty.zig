const windows_conpty = @import("../terminal/platform/windows_conpty.zig");
const sessionizer = @import("../terminal/sessionizer.zig");
const builtin = @import("builtin");
const std = @import("std");

test {
    _ = windows_conpty;
    _ = sessionizer;
}

test "sessionizer platform boundary compiles" {
    const endpoint = try sessionizer.socketPath(std.testing.allocator, if (builtin.os.tag == .windows) "C:\\verde-test" else "/tmp/verde-test");
    defer std.testing.allocator.free(endpoint);
    var daemon = sessionizer.Daemon.init(std.testing.allocator);
    defer daemon.deinit();
    // Referencing the daemon entry point exercises the platform boundary without
    // starting its blocking accept loop inside the test runner.
    _ = sessionizer.runDaemon;
}

test "Windows backend keeps an interactive ConPTY session alive" {
    if (builtin.os.tag != .windows) return;
    const command = try windows_conpty.commandForOptions(std.testing.allocator, &.{});
    defer {
        for (command) |arg| std.testing.allocator.free(arg);
        std.testing.allocator.free(command);
    }
    var backend = try windows_conpty.Backend.create(
        std.testing.allocator,
        ".",
        command,
        .{
            .session_id = "test",
            .project_id = "project",
            .project_path = ".",
            .dock_id = "0",
            .pane_id = "0",
            .sessionizer_endpoint = "\\\\.\\pipe\\verde-test",
            .live_endpoint = "",
            .cli_path = "verde.exe",
            .mcp_token = null,
        },
        80,
        24,
    );
    defer backend.deinit(std.testing.allocator);

    // The packaged failure exits after emitting only PowerShell's initial VT
    // frame, so verify liveness before accepting any echoed input as evidence.
    try sleepMs(750);
    if (!backend.isRunning()) return error.DefaultShellExitedBeforeInput;

    const is_command_prompt = std.ascii.endsWithIgnoreCase(std.fs.path.basename(command[0]), "cmd.exe");
    try writeMarkerCommand(&backend, is_command_prompt, false);
    try waitForTerminalMarker(&backend, "verde-conpty-1-ready");

    try sleepMs(500);
    if (!backend.isRunning()) return error.DefaultShellExitedAfterFirstCommand;
    try writeMarkerCommand(&backend, is_command_prompt, true);
    try waitForTerminalMarker(&backend, "verde-conpty-1-still-running");

    try backend.resize(81, 25);
    _ = backend.exitStatus();
    _ = backend.foregroundProcessGroup();
    _ = backend.processId();
    _ = windows_conpty.terminateProcessById(0);
}

fn writeMarkerCommand(backend: *windows_conpty.Backend, is_command_prompt: bool, second: bool) !void {
    const accepted = if (is_command_prompt)
        try backend.write(if (second)
            "echo verde-conpty-%VERDE%-still-running\r"
        else
            "echo verde-conpty-%VERDE%-ready\r")
    else
        try backend.write(if (second)
            "Write-Output ('verde-conpty-' + $env:VERDE + '-still-running')\r"
        else
            "Write-Output ('verde-conpty-' + $env:VERDE + '-ready')\r");
    if (!accepted) return error.DefaultShellRejectedInput;
}

fn sleepMs(milliseconds: i64) !void {
    var threaded = std.Io.Threaded.init_single_threaded;
    try std.Io.sleep(threaded.io(), .fromMilliseconds(milliseconds), .awake);
}

fn waitForTerminalMarker(backend: *windows_conpty.Backend, marker: []const u8) !void {
    var captured: std.ArrayList(u8) = .empty;
    defer captured.deinit(std.testing.allocator);
    var threaded = std.Io.Threaded.init_single_threaded;
    var buffer: [4096]u8 = undefined;

    for (0..200) |_| {
        const result = backend.read(&buffer);
        if (result.bytes > 0) {
            try captured.appendSlice(std.testing.allocator, buffer[0..result.bytes]);
            if (std.mem.find(u8, captured.items, marker) != null) return;
        }
        if (result.eof) return error.UnexpectedConptyEof;
        try std.Io.sleep(threaded.io(), .fromMilliseconds(10), .awake);
    }
    return error.ConptyOutputTimeout;
}
