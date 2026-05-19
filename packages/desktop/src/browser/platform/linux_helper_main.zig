//! Linux browser helper process that owns an offscreen WebKitGTK surface outside the SDL app.

const std = @import("std");
const ipc = @import("linux_ipc.zig");

const IDLE_SLEEP_MS = 2;

const RawBrowser = opaque {};

extern fn verde_browser_linux_create() ?*RawBrowser;
extern fn verde_browser_linux_destroy(browser: ?*RawBrowser) void;
extern fn verde_browser_linux_show(browser: ?*RawBrowser, width: c_int, height: c_int, url: ?[*:0]const u8) c_int;
extern fn verde_browser_linux_hide(browser: ?*RawBrowser) c_int;
extern fn verde_browser_linux_set_host_window(browser: ?*RawBrowser, host_window: usize) c_int;
extern fn verde_browser_linux_set_device_scale(browser: ?*RawBrowser, scale: f64) c_int;
extern fn verde_browser_linux_set_bounds(browser: ?*RawBrowser, x: c_int, y: c_int, width: c_int, height: c_int) c_int;
extern fn verde_browser_linux_resize(browser: ?*RawBrowser, width: c_int, height: c_int) c_int;
extern fn verde_browser_linux_navigate(browser: ?*RawBrowser, url: [*:0]const u8) c_int;
extern fn verde_browser_linux_eval(browser: ?*RawBrowser, js: [*:0]const u8) c_int;
extern fn verde_browser_linux_post_json(browser: ?*RawBrowser, json: [*:0]const u8) c_int;
extern fn verde_browser_linux_go_back(browser: ?*RawBrowser) c_int;
extern fn verde_browser_linux_go_forward(browser: ?*RawBrowser) c_int;
extern fn verde_browser_linux_reload(browser: ?*RawBrowser) c_int;
extern fn verde_browser_linux_focus(browser: ?*RawBrowser) c_int;
extern fn verde_browser_linux_blur(browser: ?*RawBrowser) c_int;
extern fn verde_browser_linux_mouse_move(browser: ?*RawBrowser, x: f64, y: f64, modifiers: c_uint) c_int;
extern fn verde_browser_linux_mouse_button(browser: ?*RawBrowser, x: f64, y: f64, button: c_uint, down: c_int, modifiers: c_uint) c_int;
extern fn verde_browser_linux_mouse_wheel(browser: ?*RawBrowser, x: f64, y: f64, delta_x: f64, delta_y: f64, modifiers: c_uint) c_int;
extern fn verde_browser_linux_key_input(browser: ?*RawBrowser, key_code: c_uint, down: c_int, modifiers: c_uint) c_int;
extern fn verde_browser_linux_text_input(browser: ?*RawBrowser, text: [*:0]const u8, modifiers: c_uint) c_int;
extern fn verde_browser_linux_poll_event(browser: ?*RawBrowser, kind: *c_int, payload: *?[*:0]u8) c_int;
extern fn verde_browser_linux_poll_frame(browser: ?*RawBrowser, path: *?[*:0]u8, sequence: *u64, slot: *c_int, width: *c_int, height: *c_int, byte_len: *usize) c_int;
extern fn verde_browser_linux_free_string(payload: ?[*:0]u8) void;

const Mutex = struct {
    inner: std.atomic.Mutex = .unlocked,

    fn lock(self: *Mutex) void {
        while (!self.inner.tryLock()) std.atomic.spinLoopHint();
    }

    fn unlock(self: *Mutex) void {
        self.inner.unlock();
    }
};

const CommandQueue = struct {
    mutex: Mutex = .{},
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

    /// Pushes a newly parsed command from the stdin reader thread.
    fn push(self: *CommandQueue, allocator: std.mem.Allocator, command: ipc.Command) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.items.append(allocator, command);
    }

    /// Marks the queue as closed so the helper can terminate once pending commands drain.
    fn markClosed(self: *CommandQueue) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.closed = true;
    }

    /// Removes and returns the oldest pending command, if one exists.
    fn pop(self: *CommandQueue) ?ipc.Command {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.items.items.len == 0) return null;
        return self.items.orderedRemove(0);
    }

    /// Reports whether stdin has closed and there are no commands left to process.
    fn isDrained(self: *CommandQueue) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.closed and self.items.items.len == 0;
    }
};

const ReaderContext = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    queue: *CommandQueue,
};

pub fn main(init: std.process.Init) !void {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    const allocator = gpa_state.allocator();

    const browser = verde_browser_linux_create() orelse return error.BrowserUnavailable;
    defer verde_browser_linux_destroy(browser);

    var queue = CommandQueue{};
    defer queue.deinit(allocator);

    var reader_context: ReaderContext = .{
        .allocator = allocator,
        .io = init.io,
        .queue = &queue,
    };
    const reader_thread = try std.Thread.spawn(.{}, stdinReaderMain, .{&reader_context});
    defer reader_thread.join();

    while (true) {
        var did_work = false;
        while (queue.pop()) |command| {
            did_work = true;
            defer if (command.payload) |payload| allocator.free(payload);
            if (!try applyCommand(allocator, browser, command)) {
                std.process.exit(0);
            }
        }

        did_work = (try flushBrowserEvents(allocator, init.io, browser)) > 0 or did_work;
        did_work = (try flushBrowserFrames(allocator, init.io, browser)) > 0 or did_work;
        if (queue.isDrained()) {
            std.process.exit(0);
        }
        if (did_work) {
            std.atomic.spinLoopHint();
        } else {
            sleepMillis(IDLE_SLEEP_MS);
        }
    }
}

fn sleepMillis(ms: u64) void {
    const request: std.c.timespec = .{
        .sec = @intCast(ms / 1000),
        .nsec = @intCast((ms % 1000) * std.time.ns_per_ms),
    };
    _ = std.c.nanosleep(&request, null);
}

/// Reads JSON-line commands from stdin and forwards them into the helper's command queue.
fn stdinReaderMain(context: *ReaderContext) !void {
    const stdin_file = std.Io.File.stdin();
    var read_buffer: [16 * 1024]u8 = undefined;
    var reader = stdin_file.readerStreaming(context.io, &read_buffer);

    while (true) {
        const maybe_line = try reader.interface.takeDelimiter('\n');
        if (maybe_line == null) break;
        const line = std.mem.trimEnd(u8, maybe_line.?, "\r");
        if (line.len == 0) continue;

        var parsed = try std.json.parseFromSlice(ipc.Command, context.allocator, line, .{ .allocate = .alloc_always });
        defer parsed.deinit();

        const command: ipc.Command = .{
            .kind = parsed.value.kind,
            .width = parsed.value.width,
            .height = parsed.value.height,
            .scale = parsed.value.scale,
            .x = parsed.value.x,
            .y = parsed.value.y,
            .wheel_x = parsed.value.wheel_x,
            .wheel_y = parsed.value.wheel_y,
            .screen_x = parsed.value.screen_x,
            .screen_y = parsed.value.screen_y,
            .button = parsed.value.button,
            .pressed = parsed.value.pressed,
            .key_code = parsed.value.key_code,
            .host_window = parsed.value.host_window,
            .ctrl = parsed.value.ctrl,
            .shift = parsed.value.shift,
            .alt = parsed.value.alt,
            .super = parsed.value.super,
            .payload = if (parsed.value.payload) |payload| try context.allocator.dupe(u8, payload) else null,
        };
        errdefer if (command.payload) |payload| context.allocator.free(payload);
        try context.queue.push(context.allocator, command);
    }

    context.queue.markClosed();
}

/// Applies one helper command on the GTK/WebKit side.
fn applyCommand(allocator: std.mem.Allocator, browser: *RawBrowser, command: ipc.Command) !bool {
    switch (command.kind) {
        .show => {
            const width = @max(command.width, 1);
            const height = @max(command.height, 1);
            _ = verde_browser_linux_set_device_scale(browser, command.scale);
            _ = verde_browser_linux_set_bounds(browser, command.screen_x, command.screen_y, @intCast(width), @intCast(height));
            if (command.payload) |payload| {
                const owned = try allocator.dupeZ(u8, payload);
                defer allocator.free(owned);
                _ = verde_browser_linux_show(browser, @intCast(width), @intCast(height), owned);
            } else {
                _ = verde_browser_linux_show(browser, @intCast(width), @intCast(height), null);
            }
        },
        .hide => _ = verde_browser_linux_hide(browser),
        .set_host_window => _ = verde_browser_linux_set_host_window(browser, @intCast(command.host_window)),
        .set_bounds => {
            _ = verde_browser_linux_set_device_scale(browser, command.scale);
            _ = verde_browser_linux_set_bounds(
                browser,
                command.screen_x,
                command.screen_y,
                @intCast(@max(command.width, 1)),
                @intCast(@max(command.height, 1)),
            );
        },
        .resize_pane => {
            _ = verde_browser_linux_set_device_scale(browser, command.scale);
            _ = verde_browser_linux_resize(
                browser,
                @intCast(@max(command.width, 1)),
                @intCast(@max(command.height, 1)),
            );
        },
        .navigate => {
            const payload = command.payload orelse return true;
            const owned = try allocator.dupeZ(u8, payload);
            defer allocator.free(owned);
            _ = verde_browser_linux_set_device_scale(browser, command.scale);
            _ = verde_browser_linux_set_bounds(
                browser,
                command.screen_x,
                command.screen_y,
                @intCast(@max(command.width, 1)),
                @intCast(@max(command.height, 1)),
            );
            _ = verde_browser_linux_navigate(browser, owned);
        },
        .eval => {
            const payload = command.payload orelse return true;
            const owned = try allocator.dupeZ(u8, payload);
            defer allocator.free(owned);
            _ = verde_browser_linux_eval(browser, owned);
        },
        .post_json => {
            const payload = command.payload orelse return true;
            const owned = try allocator.dupeZ(u8, payload);
            defer allocator.free(owned);
            _ = verde_browser_linux_post_json(browser, owned);
        },
        .go_back => _ = verde_browser_linux_go_back(browser),
        .go_forward => _ = verde_browser_linux_go_forward(browser),
        .reload => _ = verde_browser_linux_reload(browser),
        .focus => _ = verde_browser_linux_focus(browser),
        .blur => _ = verde_browser_linux_blur(browser),
        .mouse_move => _ = verde_browser_linux_mouse_move(
            browser,
            command.x,
            command.y,
            encodeModifierMask(command),
        ),
        .mouse_button => _ = verde_browser_linux_mouse_button(
            browser,
            command.x,
            command.y,
            command.button,
            if (command.pressed) 1 else 0,
            encodeModifierMask(command),
        ),
        .mouse_wheel => _ = verde_browser_linux_mouse_wheel(
            browser,
            command.x,
            command.y,
            command.wheel_x,
            command.wheel_y,
            encodeModifierMask(command),
        ),
        .key_input => _ = verde_browser_linux_key_input(
            browser,
            command.key_code,
            if (command.pressed) 1 else 0,
            encodeModifierMask(command),
        ),
        .text_input => {
            const payload = command.payload orelse return true;
            const owned = try allocator.dupeZ(u8, payload);
            defer allocator.free(owned);
            _ = verde_browser_linux_text_input(browser, owned, encodeModifierMask(command));
        },
        .quit => return false,
    }
    return true;
}

/// Serializes any pending GTK/WebKit events onto stdout as JSON lines.
fn flushBrowserEvents(allocator: std.mem.Allocator, io: std.Io, browser: *RawBrowser) !usize {
    const stdout_file = std.Io.File.stdout();
    var write_buffer: [16 * 1024]u8 = undefined;
    var writer = stdout_file.writerStreaming(io, &write_buffer);
    defer writer.interface.flush() catch {};

    var count: usize = 0;
    while (true) {
        var raw_kind: c_int = 0;
        var payload: ?[*:0]u8 = null;
        if (verde_browser_linux_poll_event(browser, &raw_kind, &payload) == 0) break;
        defer if (payload != null) verde_browser_linux_free_string(payload);

        const event: ipc.Event = .{
            .kind = mapEventKind(raw_kind),
            .payload = if (payload) |value| std.mem.span(value) else null,
        };
        const encoded = try std.json.Stringify.valueAlloc(allocator, event, .{});
        defer allocator.free(encoded);
        try writer.interface.writeAll(encoded);
        try writer.interface.writeByte('\n');
        count += 1;
    }
    return count;
}

/// Serializes any newly rendered browser snapshot onto stdout as a frame-ready event.
fn flushBrowserFrames(allocator: std.mem.Allocator, io: std.Io, browser: *RawBrowser) !usize {
    const stdout_file = std.Io.File.stdout();
    var write_buffer: [16 * 1024]u8 = undefined;
    var writer = stdout_file.writerStreaming(io, &write_buffer);
    defer writer.interface.flush() catch {};

    var count: usize = 0;
    while (true) {
        var frame_path: ?[*:0]u8 = null;
        var frame_sequence: u64 = 0;
        var frame_slot: c_int = -1;
        var width: c_int = 0;
        var height: c_int = 0;
        var byte_len: usize = 0;
        if (verde_browser_linux_poll_frame(browser, &frame_path, &frame_sequence, &frame_slot, &width, &height, &byte_len) == 0) break;
        defer if (frame_path != null) verde_browser_linux_free_string(frame_path);

        const event: ipc.Event = .{
            .kind = .frame_ready,
            .frame_sequence = frame_sequence,
            .width = @intCast(@max(width, 0)),
            .height = @intCast(@max(height, 0)),
            .byte_len = byte_len,
            .frame_slot = if (frame_slot >= 0) @intCast(frame_slot) else 0,
            .frame_path = if (frame_path) |value| std.mem.span(value) else null,
        };
        const encoded = try std.json.Stringify.valueAlloc(allocator, event, .{});
        defer allocator.free(encoded);
        try writer.interface.writeAll(encoded);
        try writer.interface.writeByte('\n');
        count += 1;
    }
    return count;
}

/// Maps the C helper event code into the shared JSON protocol enum.
fn mapEventKind(raw_kind: c_int) ipc.EventKind {
    return switch (raw_kind) {
        1 => .opened,
        2 => .closed,
        3 => .navigated,
        4 => .title_changed,
        5 => .document_loaded,
        6 => .js_message,
        7 => .eval_result,
        else => .failed,
    };
}

// Packs helper modifier booleans into the shared bitmask expected by the C shim.
fn encodeModifierMask(command: ipc.Command) c_uint {
    var mask: c_uint = 0;
    if (command.shift) mask |= 1 << 0;
    if (command.ctrl) mask |= 1 << 1;
    if (command.alt) mask |= 1 << 2;
    if (command.super) mask |= 1 << 3;
    return mask;
}
