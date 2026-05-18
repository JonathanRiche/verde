//! Linux browser backend implemented as an offscreen WebKitGTK helper process.

const std = @import("std");
const browser_input = @import("../input.zig");
const browser_queue = @import("../queue.zig");
const browser_texture = @import("../texture.zig");
const browser_types = @import("../types.zig");
const ipc = @import("linux_ipc.zig");

const DEFAULT_WIDTH: u32 = 1280;
const DEFAULT_HEIGHT: u32 = 720;

extern fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern fn unsetenv(name: [*:0]const u8) c_int;

pub fn configuredPresentationKind() browser_types.PresentationKind {
    return if (visibleHelperEnabled()) .helper_window else .snapshot_texture;
}

const Mutex = struct {
    inner: std.atomic.Mutex = .unlocked,

    fn lock(self: *Mutex) void {
        while (!self.inner.tryLock()) std.atomic.spinLoopHint();
    }

    fn unlock(self: *Mutex) void {
        self.inner.unlock();
    }
};

const ReaderContext = struct {
    allocator: std.mem.Allocator,
    queue: *SharedQueue,
    frame: *SharedFrame,
    stdout_file: std.Io.File,
};

const SharedQueue = struct {
    mutex: Mutex = .{},
    events: browser_queue.EventQueue = .{},

    /// Releases any queued browser events.
    fn deinit(self: *SharedQueue, allocator: std.mem.Allocator) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.events.deinit(allocator);
    }

    /// Adds a new event received from the helper stdout reader thread.
    fn push(self: *SharedQueue, allocator: std.mem.Allocator, event: browser_types.Event) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.events.push(allocator, event);
    }

    /// Removes and returns the oldest queued event, if one exists.
    fn pop(self: *SharedQueue) ?browser_types.Event {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.events.pop();
    }
};

const SharedFrame = struct {
    mutex: Mutex = .{},
    path: ?[]u8 = null,
    width: u32 = 0,
    height: u32 = 0,
    byte_len: usize = 0,
    dirty: bool = false,

    /// Releases the latest published helper frame metadata.
    fn deinit(self: *SharedFrame, allocator: std.mem.Allocator) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.path) |path| allocator.free(path);
        self.path = null;
        self.width = 0;
        self.height = 0;
        self.byte_len = 0;
        self.dirty = false;
    }

    /// Replaces the latest published helper frame metadata.
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

    /// Uploads the latest dirty helper snapshot into the pane texture.
    fn uploadIntoTexture(
        self: *SharedFrame,
        allocator: std.mem.Allocator,
        frame_buffer: *std.ArrayList(u8),
        texture: *browser_texture.PaneTexture,
    ) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (!self.dirty) return;
        const frame_path = self.path orelse return;
        if (self.width == 0 or self.height == 0 or self.byte_len == 0) return;

        try frame_buffer.resize(allocator, self.byte_len);
        var threaded = std.Io.Threaded.init_single_threaded;
        const file = try std.Io.Dir.openFileAbsolute(threaded.io(), frame_path, .{ .mode = .read_only });
        defer file.close(threaded.io());

        var read_buffer: [8 * 1024]u8 = undefined;
        var reader = file.reader(threaded.io(), &read_buffer);
        try reader.interface.readSliceAll(frame_buffer.items[0..self.byte_len]);

        try texture.uploadBgra(self.width, self.height, frame_buffer.items[0..self.byte_len]);
        self.dirty = false;
    }
};

/// Owns the Linux browser helper process and translates its stdout into browser events plus pane frames.
pub const Controller = struct {
    allocator: std.mem.Allocator,
    child_pid: ?std.posix.pid_t = null,
    child_process_group: ?std.posix.pid_t = null,
    stdin_file: ?std.Io.File = null,
    queue: *SharedQueue,
    frame: *SharedFrame,
    frame_buffer: std.ArrayList(u8) = .empty,
    reader_thread: ?std.Thread = null,
    pane_width: u32 = DEFAULT_WIDTH,
    pane_height: u32 = DEFAULT_HEIGHT,
    pane_screen_x: i32 = 0,
    pane_screen_y: i32 = 0,
    host_window: u64 = 0,
    current_url: ?[]u8 = null,

    /// Creates the helper-backed Linux browser controller.
    pub fn init(allocator: std.mem.Allocator) !Controller {
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
        try controller.spawnHelper();
        return controller;
    }

    /// Terminates the helper process and releases queued events.
    pub fn deinit(self: *Controller) void {
        if (self.child_pid != null) {
            self.sendCommand(.{ .kind = .quit }) catch {};
            self.closeChildStdin();
        }
        if (self.reader_thread) |thread| {
            thread.join();
            self.reader_thread = null;
        }
        self.terminateChild();
        if (self.current_url) |url| self.allocator.free(url);
        self.frame_buffer.deinit(self.allocator);
        self.queue.deinit(self.allocator);
        self.frame.deinit(self.allocator);
        self.allocator.destroy(self.queue);
        self.allocator.destroy(self.frame);
    }

    pub fn shutdown(self: *Controller) void {
        self.deinit();
    }

    pub fn runtimeKind(self: *const Controller) browser_types.RuntimeKind {
        _ = self;
        return .native_webview;
    }

    pub fn isRuntimeInitialized(self: *const Controller) bool {
        return self.child_pid != null;
    }

    pub fn runtimeMode(self: *const Controller) browser_types.RuntimeMode {
        _ = self;
        return .keep_warm;
    }

    pub fn supportsInspector(self: *const Controller) bool {
        _ = self;
        return true;
    }

    pub fn supportsPopout(self: *const Controller) bool {
        _ = self;
        return false;
    }

    pub fn sdkConfigured(self: *const Controller) bool {
        _ = self;
        return false;
    }

    pub fn paneSessionId(self: *const Controller) ?browser_types.SessionId {
        if (self.child_pid == null) return null;
        return 1;
    }

    pub fn paneTexture(self: *const Controller) ?browser_texture.PaneTexture {
        _ = self;
        return null;
    }

    /// Linux uses a helper process and does not need the SDL host window handle.
    pub fn setHostWindow(self: *Controller, handle: ?*anyopaque) !void {
        self.host_window = if (handle) |value| @intFromPtr(value) else 0;
        try self.sendCommand(.{
            .kind = .set_host_window,
            .host_window = self.host_window,
        });
    }

    /// Reports whether Linux is using the diagnostic helper window or the default snapshot texture path.
    pub fn presentationKind(self: *const Controller) browser_types.PresentationKind {
        _ = self;
        return configuredPresentationKind();
    }

    /// Requests that the Linux browser helper warm the offscreen browser surface.
    pub fn show(self: *Controller) !void {
        try self.sendCommand(.{
            .kind = .show,
            .width = self.pane_width,
            .height = self.pane_height,
            .screen_x = self.pane_screen_x,
            .screen_y = self.pane_screen_y,
            .payload = self.current_url orelse "about:blank",
        });
    }

    /// Requests that the Linux browser helper pause its surface updates.
    pub fn hide(self: *Controller) !void {
        try self.sendCommand(.{ .kind = .hide });
    }

    /// Toggles the Linux browser helper window by delegating to the shared controller visibility state.
    pub fn toggle(self: *Controller) !void {
        _ = self;
    }

    /// Updates the offscreen browser size to match the pane viewport.
    pub fn resizePane(self: *Controller, width: u32, height: u32) !void {
        try self.setPaneBounds(.{
            .screen_x = self.pane_screen_x,
            .screen_y = self.pane_screen_y,
            .width = width,
            .height = height,
        });
    }

    /// Moves and resizes the helper-owned native surface to the Palette browser content rectangle.
    pub fn setPaneBounds(self: *Controller, bounds: browser_types.PaneBounds) !void {
        self.pane_width = @max(bounds.width, 1);
        self.pane_height = @max(bounds.height, 1);
        self.pane_screen_x = bounds.screen_x;
        self.pane_screen_y = bounds.screen_y;
        try self.sendCommand(.{
            .kind = .set_bounds,
            .screen_x = self.pane_screen_x,
            .screen_y = self.pane_screen_y,
            .width = self.pane_width,
            .height = self.pane_height,
        });
    }

    /// Navigates the Linux browser helper to the requested URL.
    pub fn navigate(self: *Controller, url: []const u8) !void {
        try self.setCurrentUrl(url);
        try self.sendCommand(.{
            .kind = .navigate,
            .width = self.pane_width,
            .height = self.pane_height,
            .screen_x = self.pane_screen_x,
            .screen_y = self.pane_screen_y,
            .payload = url,
        });
    }

    /// Evaluates JavaScript inside the Linux browser helper.
    pub fn eval(self: *Controller, js: []const u8) !void {
        try self.sendCommand(.{ .kind = .eval, .payload = js });
    }

    /// Sends a host-originated JSON payload into the Linux browser helper.
    pub fn postJson(self: *Controller, json: []const u8) !void {
        try self.sendCommand(.{ .kind = .post_json, .payload = json });
    }

    /// Navigates backward through the helper using WebKitGTK history.
    pub fn goBack(self: *Controller) !void {
        try self.sendCommand(.{ .kind = .go_back });
    }

    /// Navigates forward through the helper using WebKitGTK history.
    pub fn goForward(self: *Controller) !void {
        try self.sendCommand(.{ .kind = .go_forward });
    }

    /// Reloads the helper page using WebKitGTK navigation.
    pub fn reload(self: *Controller) !void {
        try self.sendCommand(.{ .kind = .reload });
    }

    /// Gives the visible helper's WebKit view native focus when that presentation is active.
    pub fn focus(self: *Controller) !void {
        try self.sendCommand(.{ .kind = .focus });
    }

    /// Clears native focus from the visible helper when that presentation is active.
    pub fn blur(self: *Controller) !void {
        try self.sendCommand(.{ .kind = .blur });
    }

    /// Sends pointer motion, click, and wheel input into the offscreen browser.
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

    /// Sends key and text input into the offscreen browser.
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

    /// Returns the next browser event received from the Linux browser helper, if available.
    pub fn popEvent(self: *Controller) ?browser_types.Event {
        return self.queue.pop();
    }

    /// Alias used by the shared backend contract.
    pub fn pollEvent(self: *Controller) ?browser_types.Event {
        return self.popEvent();
    }

    /// Uploads the latest helper snapshot into the pane texture, if a new frame is ready.
    pub fn uploadFrame(self: *Controller, texture: *browser_texture.PaneTexture) !void {
        try self.frame.uploadIntoTexture(self.allocator, &self.frame_buffer, texture);
    }

    // Launches the installed browser helper binary beside the desktop executable.
    fn spawnHelper(self: *Controller) !void {
        const helper_path = try browserHelperPath(self.allocator);
        defer self.allocator.free(helper_path);

        var stdin_pipe: [2]std.posix.fd_t = undefined;
        if (std.c.pipe(&stdin_pipe) != 0) return error.Unexpected;
        errdefer {
            _ = std.c.close(stdin_pipe[0]);
            _ = std.c.close(stdin_pipe[1]);
        }
        var stdout_pipe: [2]std.posix.fd_t = undefined;
        if (std.c.pipe(&stdout_pipe) != 0) return error.Unexpected;
        errdefer {
            _ = std.c.close(stdout_pipe[0]);
            _ = std.c.close(stdout_pipe[1]);
        }

        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const helper_path_z = try std.fmt.allocPrintSentinel(arena, "{s}", .{helper_path}, 0);
        const helper_dir = std.fs.path.dirname(helper_path) orelse return error.BrowserUnavailable;
        const helper_dir_z = try std.fmt.allocPrintSentinel(arena, "{s}", .{helper_dir}, 0);
        const argv = try arena.allocSentinel(?[*:0]u8, 1, null);
        argv[0] = helper_path_z.ptr;
        const child_pid = std.c.fork();
        if (child_pid < 0) return error.Unexpected;
        if (child_pid == 0) {
            execHelperChild(helper_dir_z.ptr, helper_path_z.ptr, argv.ptr, stdin_pipe, stdout_pipe);
        }

        _ = std.c.close(stdin_pipe[0]);
        _ = std.c.close(stdout_pipe[1]);
        const stdin_file: std.Io.File = .{ .handle = stdin_pipe[1], .flags = .{ .nonblocking = false } };
        const stdout_file: std.Io.File = .{ .handle = stdout_pipe[0], .flags = .{ .nonblocking = false } };

        self.child_pid = child_pid;
        self.child_process_group = child_pid;
        self.stdin_file = stdin_file;
        _ = std.c.setpgid(child_pid, child_pid);

        const context = try self.allocator.create(ReaderContext);
        context.* = .{
            .allocator = self.allocator,
            .queue = self.queue,
            .frame = self.frame,
            .stdout_file = stdout_file,
        };
        errdefer self.allocator.destroy(context);

        self.reader_thread = try std.Thread.spawn(.{}, helperReaderMain, .{context});
    }

    // Serializes and sends one JSON-line command to the browser helper.
    fn sendCommand(self: *Controller, command: ipc.Command) !void {
        _ = self.child_pid orelse return error.BrowserUnavailable;
        const stdin_file = self.stdin_file orelse return error.BrowserUnavailable;
        const encoded = try std.json.Stringify.valueAlloc(self.allocator, command, .{});
        defer self.allocator.free(encoded);

        var write_buffer: [8 * 1024]u8 = undefined;
        var threaded: std.Io.Threaded = .init(self.allocator, .{});
        defer threaded.deinit();
        var writer = stdin_file.writer(threaded.io(), &write_buffer);
        try writer.interface.writeAll(encoded);
        try writer.interface.writeByte('\n');
        try writer.interface.flush();
    }

    // Closes the helper stdin pipe so the helper reader thread can observe EOF and exit cleanly.
    fn closeChildStdin(self: *Controller) void {
        const stdin_file = self.stdin_file orelse return;
        var threaded = std.Io.Threaded.init_single_threaded;
        stdin_file.close(threaded.io());
        self.stdin_file = null;
    }

    // Tracks the last requested URL so reopening the pane preserves browser location.
    fn setCurrentUrl(self: *Controller, url: []const u8) !void {
        if (self.current_url) |current| self.allocator.free(current);
        self.current_url = try self.allocator.dupe(u8, url);
    }

    fn terminateChild(self: *Controller) void {
        const child_pid = self.child_pid orelse return;
        const child_process_group = self.child_process_group orelse child_pid;
        if (!waitForChildExit(child_pid, 250)) {
            std.posix.kill(-child_process_group, std.posix.SIG.TERM) catch {};
            if (!waitForChildExit(child_pid, 250)) {
                std.posix.kill(-child_process_group, std.posix.SIG.KILL) catch {};
                _ = waitForChildExit(child_pid, 250);
            }
        }
        self.child_pid = null;
        self.child_process_group = null;
    }
};

fn visibleHelperEnabled() bool {
    const override_value = if (std.c.getenv("VERDE_BROWSER_LINUX_SHOW_HELPER")) |value_ptr| std.mem.span(value_ptr) else null;
    const unsafe_wayland = if (std.c.getenv("VERDE_BROWSER_LINUX_UNSAFE_WAYLAND_HELPER")) |value_ptr| std.mem.span(value_ptr) else null;
    const session_type = if (std.c.getenv("XDG_SESSION_TYPE")) |value_ptr| std.mem.span(value_ptr) else null;
    const gdk_backend = if (std.c.getenv("GDK_BACKEND")) |value_ptr| std.mem.span(value_ptr) else null;
    return visibleHelperEnabledFromValues(override_value, unsafe_wayland, session_type, gdk_backend);
}

fn visibleHelperEnabledFromValues(override_value: ?[]const u8, unsafe_wayland: ?[]const u8, session_type: ?[]const u8, gdk_backend: ?[]const u8) bool {
    const allow_wayland_helper = if (unsafe_wayland) |value| std.mem.eql(u8, value, "1") else false;
    const wayland_session = if (session_type) |value| std.mem.eql(u8, value, "wayland") else false;
    const wayland_backend = if (gdk_backend) |value| std.mem.indexOf(u8, value, "wayland") != null else false;

    if (override_value) |value| {
        if (std.mem.eql(u8, value, "1")) return (!wayland_session and !wayland_backend) or allow_wayland_helper;
        if (std.mem.eql(u8, value, "0")) return false;
    }
    if (session_type) |value| {
        if (std.mem.eql(u8, value, "x11")) return true;
        if (std.mem.eql(u8, value, "wayland")) return false;
    }
    if (gdk_backend) |value| {
        return std.mem.indexOf(u8, value, "x11") != null and std.mem.indexOf(u8, value, "wayland") == null;
    }
    return false;
}

test "visible helper selection honors overrides and session defaults" {
    try std.testing.expect(!visibleHelperEnabledFromValues("1", null, "wayland", null));
    try std.testing.expect(visibleHelperEnabledFromValues("1", "1", "wayland", null));
    try std.testing.expect(!visibleHelperEnabledFromValues("0", null, "x11", null));
    try std.testing.expect(visibleHelperEnabledFromValues(null, null, "x11", null));
    try std.testing.expect(!visibleHelperEnabledFromValues(null, null, "wayland", "x11"));
    try std.testing.expect(visibleHelperEnabledFromValues(null, null, null, "x11"));
    try std.testing.expect(!visibleHelperEnabledFromValues(null, null, null, "x11,wayland"));
}

/// Resolves the installed Linux browser helper path beside the running desktop executable.
fn browserHelperPath(allocator: std.mem.Allocator) ![]u8 {
    var threaded = std.Io.Threaded.init_single_threaded;
    const exe_dir = try std.process.executableDirPathAlloc(threaded.io(), allocator);
    defer allocator.free(exe_dir);
    return try std.fs.path.join(allocator, &.{ exe_dir, "verde-browser-linux" });
}

/// Reads JSON-line events from the helper stdout pipe and stores them in thread-safe queues.
fn helperReaderMain(context: *ReaderContext) !void {
    defer context.allocator.destroy(context);
    defer _ = std.c.close(context.stdout_file.handle);

    var read_buffer: [16 * 1024]u8 = undefined;
    var threaded = std.Io.Threaded.init_single_threaded;
    var reader = context.stdout_file.reader(threaded.io(), &read_buffer);

    while (true) {
        const maybe_line = try reader.interface.takeDelimiter('\n');
        if (maybe_line == null) return;

        const line = std.mem.trimEnd(u8, maybe_line.?, "\r");
        if (line.len == 0) continue;

        var parsed = try std.json.parseFromSlice(ipc.Event, context.allocator, line, .{ .allocate = .alloc_always });
        defer parsed.deinit();

        if (parsed.value.kind == .frame_ready) {
            try context.frame.update(context.allocator, parsed.value);
            continue;
        }

        const event = try convertHelperEvent(context.allocator, parsed.value);
        try context.queue.push(context.allocator, event);
    }
}

/// Converts the helper JSON event into the desktop browser event union.
fn convertHelperEvent(allocator: std.mem.Allocator, event: ipc.Event) !browser_types.Event {
    return switch (event.kind) {
        .opened => .opened,
        .closed => .closed,
        .navigated => .{ .navigated = try allocator.dupe(u8, event.payload orelse "about:blank") },
        .title_changed => .{ .title_changed = try allocator.dupe(u8, event.payload orelse "") },
        .document_loaded => .document_loaded,
        .js_message => .{ .js_message = try allocator.dupe(u8, event.payload orelse "{}") },
        .eval_result => .{ .eval_result = try allocator.dupe(u8, event.payload orelse "null") },
        .failed => .{ .failed = try allocator.dupe(u8, event.payload orelse "Linux browser helper failed.") },
        .frame_ready => unreachable,
    };
}

fn execHelperChild(
    helper_dir_z: [*:0]const u8,
    helper_path_z: [*:0]const u8,
    argv: [*:null]const ?[*:0]const u8,
    stdin_pipe: [2]std.posix.fd_t,
    stdout_pipe: [2]std.posix.fd_t,
) noreturn {
    _ = std.c.setpgid(0, 0);
    if (std.c.dup2(stdin_pipe[0], std.c.STDIN_FILENO) < 0) std.c._exit(126);
    if (std.c.dup2(stdout_pipe[1], std.c.STDOUT_FILENO) < 0) std.c._exit(126);

    _ = std.c.close(stdin_pipe[0]);
    _ = std.c.close(stdin_pipe[1]);
    _ = std.c.close(stdout_pipe[0]);
    _ = std.c.close(stdout_pipe[1]);
    closeInheritedFileDescriptors();

    var empty_signal_mask = std.posix.sigemptyset();
    std.posix.sigprocmask(std.c.SIG.SETMASK, &empty_signal_mask, null);
    restoreDefaultSignal(std.posix.SIG.PIPE);
    if (std.c.chdir(helper_dir_z) != 0) std.c._exit(126);

    // The snapshot helper renders into a texture owned by Palette, whose pane
    // dimensions are already framebuffer pixels. Inheriting a global GDK_SCALE
    // would make WebKit produce an oversized DPR surface that Palette then
    // downsamples, causing visibly soft text on scale-1 outputs.
    _ = setenv("GDK_SCALE", "1", 1);
    _ = unsetenv("GDK_DPI_SCALE");

    _ = std.c.execve(helper_path_z, argv, std.c.environ);
    std.c._exit(127);
}

fn closeInheritedFileDescriptors() void {
    const limits = std.posix.getrlimit(.NOFILE) catch return;
    const max_fd: usize = @intCast(@min(limits.cur, 4096));
    var fd: usize = 3;
    while (fd < max_fd) : (fd += 1) {
        _ = std.c.close(@intCast(fd));
    }
}

fn waitForChildExit(child_pid: std.posix.pid_t, timeout_ms: u16) bool {
    var waited_ms: u16 = 0;
    while (waited_ms <= timeout_ms) : (waited_ms += 25) {
        var status: c_int = 0;
        const result = std.c.waitpid(child_pid, &status, std.c.W.NOHANG);
        if (result == child_pid) return true;
        sleepMillis(25);
    }
    return false;
}

fn sleepMillis(ms: u64) void {
    const request: std.c.timespec = .{
        .sec = @intCast(ms / 1000),
        .nsec = @intCast((ms % 1000) * std.time.ns_per_ms),
    };
    _ = std.c.nanosleep(&request, null);
}

fn restoreDefaultSignal(signal_number: std.posix.SIG) void {
    const action: std.posix.Sigaction = if (@hasField(std.posix.Sigaction, "restorer"))
        .{
            .flags = 0,
            .handler = .{ .handler = null },
            .mask = std.posix.sigemptyset(),
            .restorer = null,
        }
    else
        .{
            .flags = 0,
            .handler = .{ .handler = null },
            .mask = std.posix.sigemptyset(),
        };
    std.posix.sigaction(signal_number, &action, null);
}

// Maps the shared browser mouse button enum to the helper protocol integer.
fn encodeMouseButton(button: browser_input.MouseButton) u8 {
    return switch (button) {
        .left => 1,
        .middle => 2,
        .right => 3,
        .back => 4,
        .forward => 5,
    };
}
