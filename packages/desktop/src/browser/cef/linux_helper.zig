//! Linux CEF browser helper client used by the desktop app.

const std = @import("std");
const browser_queue = @import("../queue.zig");
const browser_texture = @import("../texture.zig");
const browser_types = @import("../types.zig");
const ipc = @import("ipc.zig");

const ReaderContext = struct {
    allocator: std.mem.Allocator,
    queue: *SharedQueue,
    frame: *SharedFrame,
    stdout_file: std.fs.File,
};

const SharedQueue = struct {
    mutex: std.Thread.Mutex = .{},
    events: browser_queue.EventQueue = .{},

    /// Releases any queued browser events received from the helper.
    fn deinit(self: *SharedQueue, allocator: std.mem.Allocator) void {
        self.mutex.lock();
        defer self.mutex.unlock();
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
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.path) |path| allocator.free(path);
        self.* = .{};
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
    child: ?std.process.Child = null,
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
        if (self.child) |_| {
            self.sendCommand(.{ .kind = .quit }) catch {};
            self.closeChildStdin();
        }
        if (self.reader_thread) |thread| {
            thread.join();
            self.reader_thread = null;
        }
        if (self.child) |*child| {
            _ = child.kill() catch {};
            _ = child.wait() catch {};
            self.child = null;
        }
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

        var child = std.process.Child.init(&.{helper_path}, self.allocator);
        child.stdin_behavior = .Pipe;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Inherit;
        try child.spawn();

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

    // Serializes and sends one JSON-line command to the helper process.
    fn sendCommand(self: *Controller, command: ipc.Command) !void {
        const child = self.child orelse return error.BrowserUnavailable;
        const stdin_file = child.stdin orelse return error.BrowserUnavailable;
        const encoded = try std.json.Stringify.valueAlloc(self.allocator, command, .{});
        defer self.allocator.free(encoded);

        var write_buffer: [8 * 1024]u8 = undefined;
        var writer = stdin_file.writer(&write_buffer);
        try writer.interface.writeAll(encoded);
        try writer.interface.writeByte('\n');
        try writer.interface.flush();
    }

    // Closes the helper stdin pipe so the reader can observe EOF during teardown.
    fn closeChildStdin(self: *Controller) void {
        const child = if (self.child) |*child| child else return;
        const stdin_file = child.stdin orelse return;
        stdin_file.close();
        child.stdin = null;
    }
};

/// Resolves the installed Linux CEF helper path beside the app executable.
fn browserHelperPath(allocator: std.mem.Allocator, helper_name: []const u8) ![]u8 {
    const exe_dir = try std.fs.selfExeDirPathAlloc(allocator);
    defer allocator.free(exe_dir);
    return try std.fs.path.join(allocator, &.{ exe_dir, helper_name });
}

/// Reads helper JSON-line events from stdout and stores them in shared state.
fn helperReaderMain(context: *ReaderContext) !void {
    defer context.allocator.destroy(context);

    var read_buffer: [16 * 1024]u8 = undefined;
    var reader = context.stdout_file.reader(&read_buffer);

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
