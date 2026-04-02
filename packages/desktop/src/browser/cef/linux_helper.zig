//! Linux CEF browser helper client used by the desktop app.

const std = @import("std");
const browser_input = @import("../input.zig");
const browser_queue = @import("../queue.zig");
const browser_texture = @import("../texture.zig");
const browser_types = @import("../types.zig");
const ipc = @import("ipc.zig");

const COMMAND_FD: std.posix.fd_t = 3;
const EVENT_FD: std.posix.fd_t = 4;

const ReaderContext = struct {
    allocator: std.mem.Allocator,
    queue: *SharedQueue,
    frame: *SharedFrame,
    event_file: std.fs.File,
};

const SharedQueue = struct {
    mutex: std.Thread.Mutex = .{},
    events: browser_queue.EventQueue = .{},

    /// Releases any queued browser events received from the helper.
    fn deinit(self: *SharedQueue, allocator: std.mem.Allocator) void {
        self.events.deinit(allocator);
    }

    /// Adds a new browser event from the helper reader thread.
    fn push(self: *SharedQueue, allocator: std.mem.Allocator, event: browser_types.Event) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.events.push(allocator, event);
    }

    /// Removes and returns the oldest queued helper event.
    fn pop(self: *SharedQueue) ?browser_types.Event {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.events.pop();
    }
};

const SharedFrame = struct {
    mutex: std.Thread.Mutex = .{},
    path: ?[]u8 = null,
    width: u32 = 0,
    height: u32 = 0,
    byte_len: usize = 0,
    dirty: bool = false,

    /// Releases the stored frame metadata.
    fn deinit(self: *SharedFrame, allocator: std.mem.Allocator) void {
        if (self.path) |path| allocator.free(path);
        self.path = null;
        self.width = 0;
        self.height = 0;
        self.byte_len = 0;
        self.dirty = false;
    }

    /// Replaces the latest dirty frame metadata published by the helper.
    fn update(self: *SharedFrame, allocator: std.mem.Allocator, event: ipc.Event) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.path) |path| allocator.free(path);
        self.path = if (event.frame_path) |path|
            try allocator.dupe(u8, path)
        else
            null;
        self.width = event.width;
        self.height = event.height;
        self.byte_len = event.byte_len;
        self.dirty = true;
    }

    /// Uploads the newest dirty helper frame into the pane texture on the UI thread.
    fn uploadIntoTexture(
        self: *SharedFrame,
        allocator: std.mem.Allocator,
        buffer: *std.ArrayList(u8),
        texture: *browser_texture.PaneTexture,
    ) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (!self.dirty) return;
        const path = self.path orelse return;
        if (self.width == 0 or self.height == 0 or self.byte_len == 0) return;

        try buffer.resize(allocator, self.byte_len);
        const file = try std.fs.openFileAbsolute(path, .{ .mode = .read_only });
        defer file.close();

        const read_len = try file.preadAll(buffer.items[0..self.byte_len], 0);
        if (read_len < self.byte_len) return error.UnexpectedFrameEof;

        try texture.uploadBgra(self.width, self.height, buffer.items[0..self.byte_len]);
        self.dirty = false;
    }
};

/// Owns the Linux CEF helper process and translates its output back into desktop browser state.
pub const Controller = struct {
    allocator: std.mem.Allocator,
    child_pid: ?std.posix.pid_t = null,
    command_file: ?std.fs.File = null,
    queue: *SharedQueue,
    frame: *SharedFrame,
    frame_buffer: std.ArrayList(u8) = .empty,
    reader_thread: ?std.Thread = null,

    /// Creates the helper-backed Linux CEF controller.
    pub fn init(allocator: std.mem.Allocator, helper_name: []const u8) !Controller {
        const queue = try allocator.create(SharedQueue);
        queue.* = .{};
        errdefer allocator.destroy(queue);

        const frame = try allocator.create(SharedFrame);
        frame.* = .{};
        errdefer allocator.destroy(frame);

        var controller: Controller = .{
            .allocator = allocator,
            .queue = queue,
            .frame = frame,
        };
        errdefer controller.frame_buffer.deinit(allocator);
        try controller.spawnHelper(helper_name);
        return controller;
    }

    /// Terminates the helper and releases queued events plus frame metadata.
    pub fn deinit(self: *Controller) void {
        if (self.child_pid != null) {
            self.sendCommand(.{ .kind = .quit }) catch {};
            self.closeCommandFile();
        }
        if (self.reader_thread) |thread| {
            thread.join();
            self.reader_thread = null;
        }
        self.terminateChild();
        self.frame_buffer.deinit(self.allocator);
        self.queue.deinit(self.allocator);
        self.frame.deinit(self.allocator);
        self.allocator.destroy(self.queue);
        self.allocator.destroy(self.frame);
    }

    /// Ensures the helper creates or reuses the pane browser at the requested size and URL.
    pub fn show(self: *Controller, width: u32, height: u32, url: []const u8) !void {
        try self.sendCommand(.{
            .kind = .show,
            .width = width,
            .height = height,
            .payload = url,
        });
    }

    /// Hides the helper-backed browser surface without destroying the warm runtime.
    pub fn hide(self: *Controller) !void {
        try self.sendCommand(.{ .kind = .hide });
    }

    /// Updates the off-screen browser viewport to match the latest pane size.
    pub fn resize(self: *Controller, width: u32, height: u32) !void {
        try self.sendCommand(.{
            .kind = .resize_pane,
            .width = width,
            .height = height,
        });
    }

    /// Navigates the helper-backed browser to a new URL.
    pub fn navigate(self: *Controller, width: u32, height: u32, url: []const u8) !void {
        try self.sendCommand(.{
            .kind = .navigate,
            .width = width,
            .height = height,
            .payload = url,
        });
    }

    /// Evaluates JavaScript inside the helper-backed browser.
    pub fn eval(self: *Controller, js: []const u8) !void {
        try self.sendCommand(.{
            .kind = .eval,
            .payload = js,
        });
    }

    /// Sends a host-originated JSON payload through the helper bridge placeholder path.
    pub fn postJson(self: *Controller, json: []const u8) !void {
        try self.sendCommand(.{
            .kind = .post_json,
            .payload = json,
        });
    }

    /// Sends pointer motion, button, and wheel input into the helper-backed browser.
    pub fn handleMouse(self: *Controller, event: browser_input.MouseEvent) !bool {
        if (event.button) |button| {
            try self.sendCommand(.{
                .kind = .mouse_button,
                .x = event.x,
                .y = event.y,
                .button = encodeMouseButton(button),
                .pressed = event.pressed,
                .ctrl = event.ctrl,
                .shift = event.shift,
                .alt = event.alt,
                .super = event.super,
            });
            return true;
        }
        if (event.wheel_x != 0.0 or event.wheel_y != 0.0) {
            try self.sendCommand(.{
                .kind = .mouse_wheel,
                .x = event.x,
                .y = event.y,
                .wheel_x = event.wheel_x,
                .wheel_y = event.wheel_y,
                .ctrl = event.ctrl,
                .shift = event.shift,
                .alt = event.alt,
                .super = event.super,
            });
            return true;
        }
        try self.sendCommand(.{
            .kind = .mouse_move,
            .x = event.x,
            .y = event.y,
            .ctrl = event.ctrl,
            .shift = event.shift,
            .alt = event.alt,
            .super = event.super,
        });
        return true;
    }

    /// Sends key and text input into the helper-backed browser.
    pub fn handleKey(self: *Controller, event: browser_input.KeyEvent) !bool {
        if (event.text) |text| {
            if (text.len == 0) return false;
            try self.sendCommand(.{
                .kind = .text_input,
                .payload = text,
                .ctrl = event.ctrl,
                .shift = event.shift,
                .alt = event.alt,
                .super = event.super,
            });
            return true;
        }
        if (event.key_code == 0) return false;
        try self.sendCommand(.{
            .kind = .key_input,
            .key_code = event.key_code,
            .pressed = event.pressed,
            .ctrl = event.ctrl,
            .shift = event.shift,
            .alt = event.alt,
            .super = event.super,
        });
        return true;
    }

    /// Returns the next helper event, if one has been read already.
    pub fn popEvent(self: *Controller) ?browser_types.Event {
        return self.queue.pop();
    }

    /// Uploads the latest dirty helper frame into the browser pane texture.
    pub fn uploadFrame(self: *Controller, texture: *browser_texture.PaneTexture) !void {
        try self.frame.uploadIntoTexture(self.allocator, &self.frame_buffer, texture);
    }

    // Launches the installed Linux CEF helper beside the desktop executable.
    fn spawnHelper(self: *Controller, helper_name: []const u8) !void {
        const helper_path = try browserHelperPath(self.allocator, helper_name);
        defer self.allocator.free(helper_path);

        const command_pipe = try std.posix.pipe();
        errdefer {
            std.posix.close(command_pipe[0]);
            std.posix.close(command_pipe[1]);
        }
        const event_pipe = try std.posix.pipe();
        errdefer {
            std.posix.close(event_pipe[0]);
            std.posix.close(event_pipe[1]);
        }

        var env_map = try std.process.getEnvMap(self.allocator);
        defer env_map.deinit();
        try env_map.put("VERDE_CEF_CMD_FD", "3");
        try env_map.put("VERDE_CEF_EVENT_FD", "4");

        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const helper_path_z = try std.fmt.allocPrintSentinel(arena, "{s}", .{helper_path}, 0);
        const helper_dir = std.fs.path.dirname(helper_path) orelse return error.BrowserUnavailable;
        const helper_dir_z = try std.fmt.allocPrintSentinel(arena, "{s}", .{helper_dir}, 0);
        const argv = try arena.allocSentinel(?[*:0]u8, 1, null);
        argv[0] = helper_path_z.ptr;
        const envp = try std.process.createEnvironFromMap(arena, &env_map, .{});

        const child_pid = try std.posix.fork();
        if (child_pid == 0) {
            execHelperChild(helper_dir_z.ptr, helper_path_z.ptr, argv.ptr, envp.ptr, command_pipe, event_pipe);
        }

        std.posix.close(command_pipe[0]);
        std.posix.close(event_pipe[1]);

        const command_file: std.fs.File = .{ .handle = command_pipe[1] };
        const event_file: std.fs.File = .{ .handle = event_pipe[0] };

        self.child_pid = child_pid;
        self.command_file = command_file;

        const context = try self.allocator.create(ReaderContext);
        context.* = .{
            .allocator = self.allocator,
            .queue = self.queue,
            .frame = self.frame,
            .event_file = event_file,
        };
        errdefer self.allocator.destroy(context);

        self.reader_thread = try std.Thread.spawn(.{}, helperReaderMain, .{context});
    }

    // Serializes and sends one JSON-line command to the helper process.
    fn sendCommand(self: *Controller, command: ipc.Command) !void {
        _ = self.child_pid orelse return error.BrowserUnavailable;
        const command_file = self.command_file orelse return error.BrowserUnavailable;
        const encoded = try std.json.Stringify.valueAlloc(self.allocator, command, .{});
        defer self.allocator.free(encoded);

        var write_buffer: [8 * 1024]u8 = undefined;
        var writer = command_file.writer(&write_buffer);
        try writer.interface.writeAll(encoded);
        try writer.interface.writeByte('\n');
        try writer.interface.flush();
    }

    // Closes the command FIFO writer so the helper can observe EOF during teardown.
    fn closeCommandFile(self: *Controller) void {
        const command_file = self.command_file orelse return;
        command_file.close();
        self.command_file = null;
    }

    // Forces the helper process down after the reader thread has drained its event pipe.
    fn terminateChild(self: *Controller) void {
        const child_pid = self.child_pid orelse return;
        std.posix.kill(child_pid, std.posix.SIG.TERM) catch {};
        _ = std.posix.waitpid(child_pid, 0);
        self.child_pid = null;
    }
};

/// Resolves the installed Linux CEF helper path beside the app executable.
fn browserHelperPath(allocator: std.mem.Allocator, helper_name: []const u8) ![]u8 {
    const exe_dir = try std.fs.selfExeDirPathAlloc(allocator);
    defer allocator.free(exe_dir);
    return try std.fs.path.join(allocator, &.{ exe_dir, helper_name });
}

// Maps the shared browser mouse button enum to the helper protocol integer.
fn encodeMouseButton(button: browser_input.MouseButton) u8 {
    return switch (button) {
        .left => 1,
        .middle => 2,
        .right => 3,
    };
}

/// Reads helper JSON-line events from stdout and stores them in shared state.
fn helperReaderMain(context: *ReaderContext) !void {
    defer context.allocator.destroy(context);
    defer context.event_file.close();

    var read_buffer: [16 * 1024]u8 = undefined;
    var reader = context.event_file.reader(&read_buffer);

    while (true) {
        const maybe_line = try reader.interface.takeDelimiter('\n');
        if (maybe_line == null) return;

        const line = std.mem.trimRight(u8, maybe_line.?, "\r");
        if (line.len == 0) continue;

        var parsed = try std.json.parseFromSlice(ipc.Event, context.allocator, line, .{
            .allocate = .alloc_always,
        });
        defer parsed.deinit();

        if (parsed.value.kind == .frame_ready) {
            try context.frame.update(context.allocator, parsed.value);
            continue;
        }

        const event = try convertHelperEvent(context.allocator, parsed.value);
        try context.queue.push(context.allocator, event);
    }
}

// Replaces std.process.Child with a direct fork/exec path because Linux CEF hangs under the std child launcher.
fn execHelperChild(
    helper_dir_z: [*:0]const u8,
    helper_path_z: [*:0]const u8,
    argv: [*:null]const ?[*:0]const u8,
    envp: [*:null]const ?[*:0]const u8,
    command_pipe: [2]std.posix.fd_t,
    event_pipe: [2]std.posix.fd_t,
) noreturn {
    std.posix.dup2(command_pipe[0], COMMAND_FD) catch std.posix.exit(126);
    std.posix.dup2(event_pipe[1], EVENT_FD) catch std.posix.exit(126);

    std.posix.close(command_pipe[0]);
    std.posix.close(command_pipe[1]);
    std.posix.close(event_pipe[0]);
    std.posix.close(event_pipe[1]);
    closeInheritedFileDescriptors();

    var empty_signal_mask = std.posix.sigemptyset();
    std.posix.sigprocmask(std.c.SIG.SETMASK, &empty_signal_mask, null);
    restoreDefaultSignal(std.posix.SIG.PIPE);
    std.posix.chdirZ(helper_dir_z) catch std.posix.exit(126);

    std.posix.execveZ(helper_path_z, argv, envp) catch std.posix.exit(127);
}

// Closes unrelated desktop-app descriptors so the Linux CEF host starts in a shell-like fd state.
fn closeInheritedFileDescriptors() void {
    const limits = std.posix.getrlimit(.NOFILE) catch return;
    const max_fd: usize = @intCast(@min(limits.cur, 4096));
    var fd: usize = 5;
    while (fd < max_fd) : (fd += 1) {
        _ = std.c.close(@intCast(fd));
    }
}

// Restores the default action for signals that the desktop app may have globally ignored.
fn restoreDefaultSignal(signal_number: u8) void {
    const action: std.posix.Sigaction = .{
        .flags = 0,
        .handler = .{ .handler = null },
        .mask = std.posix.sigemptyset(),
        .restorer = null,
    };
    std.posix.sigaction(signal_number, &action, null);
}

/// Converts one helper JSON event into the desktop browser event union.
fn convertHelperEvent(allocator: std.mem.Allocator, event: ipc.Event) !browser_types.Event {
    return switch (event.kind) {
        .opened => .opened,
        .closed => .closed,
        .navigated => .{ .navigated = try allocator.dupe(u8, event.payload orelse "about:blank") },
        .title_changed => .{ .title_changed = try allocator.dupe(u8, event.payload orelse "") },
        .js_message => .{ .js_message = try allocator.dupe(u8, event.payload orelse "{}") },
        .eval_result => .{ .eval_result = try allocator.dupe(u8, event.payload orelse "null") },
        .failed => .{ .failed = try allocator.dupe(u8, event.payload orelse "Linux CEF helper failed.") },
        .frame_ready => unreachable,
    };
}
