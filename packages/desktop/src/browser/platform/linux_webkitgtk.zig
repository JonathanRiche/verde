//! Linux browser backend implemented as an offscreen WebKitGTK helper process.

const std = @import("std");
const browser_input = @import("../input.zig");
const browser_queue = @import("../queue.zig");
const browser_texture = @import("../texture.zig");
const browser_types = @import("../types.zig");
const ipc = @import("linux_ipc.zig");

const DEFAULT_WIDTH: u32 = 1280;
const DEFAULT_HEIGHT: u32 = 720;

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
    child: ?std.process.Child = null,
    queue: *SharedQueue,
    frame: *SharedFrame,
    frame_buffer: std.ArrayList(u8) = .empty,
    reader_thread: ?std.Thread = null,
    pane_width: u32 = DEFAULT_WIDTH,
    pane_height: u32 = DEFAULT_HEIGHT,
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
        if (self.child) |_| {
            self.sendCommand(.{ .kind = .quit }) catch {};
            self.closeChildStdin();
        }
        if (self.reader_thread) |thread| {
            thread.join();
            self.reader_thread = null;
        }
        if (self.child) |*child| {
            var threaded = std.Io.Threaded.init_single_threaded;
            child.kill(threaded.io());
            _ = child.wait(threaded.io()) catch {};
            self.child = null;
        }
        if (self.current_url) |url| self.allocator.free(url);
        self.frame_buffer.deinit(self.allocator);
        self.queue.deinit(self.allocator);
        self.frame.deinit(self.allocator);
        self.allocator.destroy(self.queue);
        self.allocator.destroy(self.frame);
    }

    /// Requests that the Linux browser helper warm the offscreen browser surface.
    pub fn show(self: *Controller) !void {
        try self.sendCommand(.{
            .kind = .show,
            .width = self.pane_width,
            .height = self.pane_height,
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
        self.pane_width = @max(width, 1);
        self.pane_height = @max(height, 1);
        try self.sendCommand(.{
            .kind = .resize_pane,
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

    /// Uploads the latest helper snapshot into the pane texture, if a new frame is ready.
    pub fn uploadFrame(self: *Controller, texture: *browser_texture.PaneTexture) !void {
        try self.frame.uploadIntoTexture(self.allocator, &self.frame_buffer, texture);
    }

    // Launches the installed browser helper binary beside the desktop executable.
    fn spawnHelper(self: *Controller) !void {
        const helper_path = try browserHelperPath(self.allocator);
        defer self.allocator.free(helper_path);

        var threaded = std.Io.Threaded.init_single_threaded;
        const child = try std.process.spawn(threaded.io(), .{
            .argv = &.{helper_path},
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .inherit,
        });

        const stdout_file = child.stdout.?;
        self.child = child;

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
        const child = self.child orelse return error.BrowserUnavailable;
        const stdin_file = child.stdin orelse return error.BrowserUnavailable;
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
        const child = if (self.child) |*child| child else return;
        const stdin_file = child.stdin orelse return;
        var threaded = std.Io.Threaded.init_single_threaded;
        stdin_file.close(threaded.io());
        child.stdin = null;
    }

    // Tracks the last requested URL so reopening the pane preserves browser location.
    fn setCurrentUrl(self: *Controller, url: []const u8) !void {
        if (self.current_url) |current| self.allocator.free(current);
        self.current_url = try self.allocator.dupe(u8, url);
    }
};

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
        .js_message => .{ .js_message = try allocator.dupe(u8, event.payload orelse "{}") },
        .eval_result => .{ .eval_result = try allocator.dupe(u8, event.payload orelse "null") },
        .failed => .{ .failed = try allocator.dupe(u8, event.payload orelse "Linux browser helper failed.") },
        .frame_ready => unreachable,
    };
}

// Maps the shared browser mouse button enum to the helper protocol integer.
fn encodeMouseButton(button: browser_input.MouseButton) u8 {
    return switch (button) {
        .left => 1,
        .middle => 2,
        .right => 3,
    };
}
