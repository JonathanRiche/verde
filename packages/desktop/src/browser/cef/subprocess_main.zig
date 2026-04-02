//! Entry point for the Linux CEF browser helper and Chromium subprocesses.

const std = @import("std");
const browser_native = @import("native.zig");
const ipc = @import("ipc.zig");

const DEFAULT_PANE_WIDTH: u32 = 1280;
const DEFAULT_PANE_HEIGHT: u32 = 720;
const MAX_NATIVE_EVENT_BYTES: usize = 4096;
const SYNTHETIC_EVAL_RESULT = "{\"status\":\"dispatched\"}";

const OwnedArgv = struct {
    allocator: std.mem.Allocator,
    values: std.ArrayList([*:0]const u8) = .empty,

    /// Captures the helper argv as owned C strings for CEF startup.
    fn init(allocator: std.mem.Allocator) !OwnedArgv {
        const args = try std.process.argsAlloc(allocator);
        defer std.process.argsFree(allocator, args);

        var owned: OwnedArgv = .{
            .allocator = allocator,
        };
        errdefer owned.deinit();

        for (args) |arg| {
            try owned.values.append(allocator, try allocator.dupeZ(u8, arg));
        }
        return owned;
    }

    /// Appends one Chromium switch when it is not already present on the command line.
    fn appendSwitchIfMissing(self: *OwnedArgv, switch_name: []const u8) !void {
        for (self.values.items) |arg| {
            if (std.mem.eql(u8, std.mem.span(arg), switch_name)) return;
        }
        try self.values.append(self.allocator, try self.allocator.dupeZ(u8, switch_name));
    }

    /// Releases the duplicated command line after CEF startup is done with it.
    fn deinit(self: *OwnedArgv) void {
        for (self.values.items) |value| {
            self.allocator.free(std.mem.span(value));
        }
        self.values.deinit(self.allocator);
    }
};

const RuntimePaths = struct {
    subprocess_path: [:0]u8,
    resources_dir: [:0]u8,
    locales_dir: [:0]u8,

    /// Resolves the helper executable and its sibling CEF resource directories.
    fn init(allocator: std.mem.Allocator) !RuntimePaths {
        const exe_path = try std.fs.selfExePathAlloc(allocator);
        defer allocator.free(exe_path);

        const exe_dir = std.fs.path.dirname(exe_path) orelse return error.InvalidExecutablePath;
        const locales_join = try std.fs.path.join(allocator, &.{ exe_dir, "locales" });
        defer allocator.free(locales_join);

        return .{
            .subprocess_path = try allocator.dupeZ(u8, exe_path),
            .resources_dir = try allocator.dupeZ(u8, exe_dir),
            .locales_dir = try allocator.dupeZ(u8, locales_join),
        };
    }

    /// Releases the owned helper/resource paths.
    fn deinit(self: *RuntimePaths, allocator: std.mem.Allocator) void {
        allocator.free(self.subprocess_path);
        allocator.free(self.resources_dir);
        allocator.free(self.locales_dir);
    }
};

const CommandQueue = struct {
    mutex: std.Thread.Mutex = .{},
    items: std.ArrayList(ipc.Command) = .empty,
    closed: bool = false,

    /// Releases queued commands and their payloads.
    fn deinit(self: *CommandQueue, allocator: std.mem.Allocator) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.items.items) |command| {
            if (command.payload) |payload| allocator.free(payload);
        }
        self.items.deinit(allocator);
    }

    /// Pushes a newly parsed helper command from the stdin reader thread.
    fn push(self: *CommandQueue, allocator: std.mem.Allocator, command: ipc.Command) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.items.append(allocator, command);
    }

    /// Marks stdin as closed so the helper can terminate once its queue drains.
    fn markClosed(self: *CommandQueue) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.closed = true;
    }

    /// Removes and returns the oldest queued helper command.
    fn pop(self: *CommandQueue) ?ipc.Command {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.items.items.len == 0) return null;
        return self.items.orderedRemove(0);
    }

    /// Reports whether the reader hit EOF and there is no remaining work.
    fn isDrained(self: *CommandQueue) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.closed and self.items.items.len == 0;
    }
};

const ReaderContext = struct {
    allocator: std.mem.Allocator,
    queue: *CommandQueue,
};

const FrameStore = struct {
    allocator: std.mem.Allocator,
    path: []u8,
    file: std.fs.File,

    /// Creates the helper-owned raw frame file in `/tmp`.
    fn init(allocator: std.mem.Allocator) !FrameStore {
        const frame_path = try std.fmt.allocPrint(
            allocator,
            "/tmp/verde-cef-frame-{d}.rgba",
            .{@as(i32, @intCast(std.os.linux.getpid()))},
        );
        errdefer allocator.free(frame_path);

        const file = try std.fs.createFileAbsolute(frame_path, .{
            .read = true,
            .truncate = true,
        });
        return .{
            .allocator = allocator,
            .path = frame_path,
            .file = file,
        };
    }

    /// Closes and removes the helper frame file.
    fn deinit(self: *FrameStore) void {
        self.file.close();
        std.fs.deleteFileAbsolute(self.path) catch {};
        self.allocator.free(self.path);
    }

    /// Overwrites the shared frame file with the latest browser frame bytes.
    fn writeFrame(self: *FrameStore, pixels: []const u8) !void {
        try self.file.seekTo(0);
        try self.file.setEndPos(@intCast(pixels.len));
        try self.file.writeAll(pixels);
    }
};

const HelperState = struct {
    allocator: std.mem.Allocator,
    frame_store: FrameStore,
    pane_width: u32 = DEFAULT_PANE_WIDTH,
    pane_height: u32 = DEFAULT_PANE_HEIGHT,

    /// Releases helper-owned frame storage.
    fn deinit(self: *HelperState) void {
        self.frame_store.deinit();
    }

    /// Remembers the latest pane size so create/navigate paths stay consistent.
    fn updatePaneSize(self: *HelperState, width: u32, height: u32) void {
        self.pane_width = @max(width, 1);
        self.pane_height = @max(height, 1);
    }
};

/// Runs either as the Linux CEF browser helper or as a Chromium subprocess.
pub fn main() !void {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    const allocator = gpa_state.allocator();

    var argv = try OwnedArgv.init(allocator);
    defer argv.deinit();

    if (!isChromiumSubprocess(argv.values.items)) {
        try argv.appendSwitchIfMissing("--no-sandbox");
        try argv.appendSwitchIfMissing("--no-zygote");
        try argv.appendSwitchIfMissing("--single-process");
        try argv.appendSwitchIfMissing("--disable-gpu");
        try argv.appendSwitchIfMissing("--disable-gpu-compositing");
    }

    if (isChromiumSubprocess(argv.values.items)) {
        const subprocess_result = browser_native.executeSubprocess(
            @intCast(argv.values.items.len),
            argv.values.items.ptr,
        );
        if (subprocess_result >= 0) {
            std.process.exit(@intCast(subprocess_result));
        }
    }

    var runtime_paths = try RuntimePaths.init(allocator);
    defer runtime_paths.deinit(allocator);

    if (!browser_native.initialize(
        @intCast(argv.values.items.len),
        argv.values.items.ptr,
        runtime_paths.subprocess_path.ptr,
        runtime_paths.resources_dir.ptr,
        runtime_paths.locales_dir.ptr,
    )) {
        return error.CefInitializationFailed;
    }

    var helper_state: HelperState = .{
        .allocator = allocator,
        .frame_store = try FrameStore.init(allocator),
    };
    defer helper_state.deinit();

    var command_queue = CommandQueue{};
    defer command_queue.deinit(allocator);

    var reader_context: ReaderContext = .{
        .allocator = allocator,
        .queue = &command_queue,
    };
    const reader_thread = try std.Thread.spawn(.{}, stdinReaderMain, .{&reader_context});
    defer reader_thread.join();

    while (true) {
        while (command_queue.pop()) |command| {
            defer if (command.payload) |payload| allocator.free(payload);
            const keep_running = applyCommand(&helper_state, command) catch |err| {
                try emitEvent(allocator, .{
                    .kind = .failed,
                    .payload = @errorName(err),
                });
                continue;
            };
            if (!keep_running) std.process.exit(0);
        }

        browser_native.doMessageLoopWork();
        try flushNativeEvents(allocator);
        try publishLatestFrame(allocator, &helper_state);
        if (command_queue.isDrained()) std.process.exit(0);
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }
}

// Chromium subprocesses are launched with a `--type=` command-line flag.
fn isChromiumSubprocess(args: []const [*:0]const u8) bool {
    for (args) |arg| {
        if (std.mem.startsWith(u8, std.mem.span(arg), "--type=")) return true;
    }
    return false;
}

/// Reads JSON-line helper commands from stdin and queues them for the browser loop.
fn stdinReaderMain(context: *ReaderContext) !void {
    const stdin_file = std.fs.File.stdin();
    var read_buffer: [16 * 1024]u8 = undefined;
    var reader = stdin_file.reader(&read_buffer);

    while (true) {
        const maybe_line = try reader.interface.takeDelimiter('\n');
        if (maybe_line == null) break;

        const line = std.mem.trimRight(u8, maybe_line.?, "\r");
        if (line.len == 0) continue;

        var parsed = try std.json.parseFromSlice(ipc.Command, context.allocator, line, .{
            .allocate = .alloc_always,
        });
        defer parsed.deinit();

        const command: ipc.Command = .{
            .kind = parsed.value.kind,
            .session_id = parsed.value.session_id,
            .width = parsed.value.width,
            .height = parsed.value.height,
            .payload = if (parsed.value.payload) |payload|
                try context.allocator.dupe(u8, payload)
            else
                null,
        };
        errdefer if (command.payload) |payload| context.allocator.free(payload);
        try context.queue.push(context.allocator, command);
    }

    context.queue.markClosed();
}

/// Applies one helper command on the local browser-process runtime.
fn applyCommand(state: *HelperState, command: ipc.Command) !bool {
    switch (command.kind) {
        .show => {
            state.updatePaneSize(command.width, command.height);
            const url = command.payload orelse "about:blank";
            try ensureBrowserCreated(state, url);
        },
        .hide => {},
        .resize_pane => {
            state.updatePaneSize(command.width, command.height);
            if (browser_native.hasBrowser()) {
                browser_native.resizeBrowser(state.pane_width, state.pane_height);
            }
        },
        .navigate => {
            state.updatePaneSize(command.width, command.height);
            const url = command.payload orelse return true;
            if (!browser_native.hasBrowser()) {
                try ensureBrowserCreated(state, url);
            } else {
                const owned_url = try state.allocator.dupeZ(u8, url);
                defer state.allocator.free(owned_url);
                if (!browser_native.navigate(owned_url)) return error.NavigateFailed;
            }
        },
        .eval => {
            const js = command.payload orelse return true;
            const owned_js = try state.allocator.dupeZ(u8, js);
            defer state.allocator.free(owned_js);
            if (!browser_native.eval(owned_js)) return error.EvalFailed;
            try emitEvent(state.allocator, .{
                .kind = .eval_result,
                .payload = SYNTHETIC_EVAL_RESULT,
            });
        },
        .post_json => {
            if (command.payload) |payload| {
                try emitEvent(state.allocator, .{
                    .kind = .js_message,
                    .payload = payload,
                });
            }
        },
        .quit => return false,
    }

    return true;
}

/// Creates the off-screen browser lazily the first time the pane is shown or navigated.
fn ensureBrowserCreated(state: *HelperState, url: []const u8) !void {
    if (browser_native.hasBrowser()) {
        browser_native.resizeBrowser(state.pane_width, state.pane_height);
        return;
    }

    const owned_url = try state.allocator.dupeZ(u8, url);
    defer state.allocator.free(owned_url);

    if (!browser_native.createBrowser(state.pane_width, state.pane_height, owned_url)) {
        return error.BrowserCreateFailed;
    }
}

/// Translates native browser events into helper JSON events for the desktop shell.
fn flushNativeEvents(allocator: std.mem.Allocator) !void {
    var buffer: [MAX_NATIVE_EVENT_BYTES]u8 = undefined;
    while (browser_native.popEvent(buffer[0..])) |native_event| {
        const payload = buffer[0..native_event.len];
        switch (native_event.kind) {
            .opened => try emitEvent(allocator, .{ .kind = .opened }),
            .closed => try emitEvent(allocator, .{ .kind = .closed }),
            .navigated => try emitEvent(allocator, .{
                .kind = .navigated,
                .payload = payload,
            }),
            .title_changed => try emitEvent(allocator, .{
                .kind = .title_changed,
                .payload = payload,
            }),
            .failed => try emitEvent(allocator, .{
                .kind = .failed,
                .payload = payload,
            }),
            else => {},
        }
    }
}

/// Publishes the latest dirty CEF frame into the helper frame file and notifies the desktop app.
fn publishLatestFrame(allocator: std.mem.Allocator, state: *HelperState) !void {
    const frame = browser_native.getFrame();
    if (!frame.dirty or frame.pixels == null or frame.width == 0 or frame.height == 0) return;

    const expected_len = @as(usize, frame.width) * @as(usize, frame.height) * 4;
    if (frame.len < expected_len) return error.InvalidFrame;

    try state.frame_store.writeFrame(frame.pixels.?[0..expected_len]);
    browser_native.clearFrameDirty();

    try emitEvent(allocator, .{
        .kind = .frame_ready,
        .width = frame.width,
        .height = frame.height,
        .byte_len = expected_len,
        .frame_path = state.frame_store.path,
    });
}

/// Serializes one helper event to stdout as a JSON line.
fn emitEvent(allocator: std.mem.Allocator, event: ipc.Event) !void {
    const stdout_file = std.fs.File.stdout();
    var write_buffer: [16 * 1024]u8 = undefined;
    var writer = stdout_file.writer(&write_buffer);
    defer writer.interface.flush() catch {};

    const encoded = try std.json.Stringify.valueAlloc(allocator, event, .{});
    defer allocator.free(encoded);
    try writer.interface.writeAll(encoded);
    try writer.interface.writeByte('\n');
}
