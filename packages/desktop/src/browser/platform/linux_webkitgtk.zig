//! Linux browser backend implemented as an offscreen WebKitGTK helper process.

const std = @import("std");
const browser_input = @import("../input.zig");
const browser_queue = @import("../queue.zig");
const browser_texture = @import("../texture.zig");
const browser_types = @import("../types.zig");
const ipc = @import("linux_ipc.zig");

const log = std.log.scoped(.linux_webkitgtk);

const DEFAULT_WIDTH: u32 = 1280;
const DEFAULT_HEIGHT: u32 = 720;
const FRAME_FD_BASE: std.posix.fd_t = 240;
const FRAME_SLOT_COUNT: usize = 3;
const FRAME_BYTES_MAX: usize = 4096 * 2160 * 4;

extern fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern fn unsetenv(name: [*:0]const u8) c_int;

const RawWaylandSubsurface = opaque {};
const WAYLAND_SUBSURFACE_PROBE_MESSAGE =
    "Wayland subsurface probe is attached, but WebKitGTK content is not embedded in it yet.";

extern fn verde_wayland_subsurface_create(display: ?*anyopaque, parent_surface: ?*anyopaque) ?*RawWaylandSubsurface;
extern fn verde_wayland_subsurface_destroy(handle: ?*RawWaylandSubsurface) void;
extern fn verde_wayland_subsurface_set_bounds(handle: ?*RawWaylandSubsurface, x: i32, y: i32, width: u32, height: u32) c_int;
extern fn verde_wayland_subsurface_show(handle: ?*RawWaylandSubsurface) c_int;
extern fn verde_wayland_subsurface_hide(handle: ?*RawWaylandSubsurface) void;

fn monotonicTimestampNs() i128 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.MONOTONIC, &ts) != 0) return 0;
    return @as(i128, @intCast(ts.sec)) * std.time.ns_per_s +
        @as(i128, @intCast(ts.nsec));
}

fn nanosToMillis(nanos: i128) f64 {
    return @as(f64, @floatFromInt(nanos)) / @as(f64, @floatFromInt(std.time.ns_per_ms));
}

fn deleteFramePath(path: []const u8) void {
    var threaded = std.Io.Threaded.init_single_threaded;
    std.Io.Dir.deleteFileAbsolute(threaded.io(), path) catch {};
}

fn frameLogEnabled() bool {
    const value = std.c.getenv("VERDE_BROWSER_FRAME_LOG") orelse return false;
    return std.mem.eql(u8, std.mem.span(value), "1");
}

pub fn configuredPresentationKind() browser_types.PresentationKind {
    if (wpeEnabled()) return .offscreen_texture;
    if (waylandSubsurfaceEnabled()) return .native_wayland_surface;
    return if (visibleHelperEnabled()) .helper_window else .snapshot_texture;
}

fn wpeEnabled() bool {
    const value = std.c.getenv("VERDE_BROWSER_LINUX_WPE") orelse return false;
    return std.mem.eql(u8, std.mem.span(value), "1");
}

fn waylandSubsurfaceEnabled() bool {
    const value = std.c.getenv("VERDE_BROWSER_LINUX_SUBSURFACE") orelse return false;
    return std.mem.eql(u8, std.mem.span(value), "1");
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
    slots: [FRAME_SLOT_COUNT][]align(std.heap.page_size_min) u8 = undefined,
    slot_ready: [FRAME_SLOT_COUNT]bool = [_]bool{false} ** FRAME_SLOT_COUNT,
    staging: std.ArrayList(u8) = .empty,
    path: ?[]u8 = null,
    sequence: u64 = 0,
    width: u32 = 0,
    height: u32 = 0,
    byte_len: usize = 0,
    dirty: bool = false,

    /// Releases the latest published helper frame metadata.
    fn deinit(self: *SharedFrame, allocator: std.mem.Allocator) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.path) |path| {
            deleteFramePath(path);
            allocator.free(path);
        }
        for (0..FRAME_SLOT_COUNT) |index| {
            if (!self.slot_ready[index]) continue;
            std.posix.munmap(self.slots[index]);
            self.slot_ready[index] = false;
        }
        self.staging.deinit(allocator);
        self.path = null;
        self.sequence = 0;
        self.width = 0;
        self.height = 0;
        self.byte_len = 0;
        self.dirty = false;
    }

    /// Replaces the latest published helper frame metadata.
    fn update(self: *SharedFrame, allocator: std.mem.Allocator, event: ipc.Event) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (event.frame_sequence <= self.sequence) {
            if (event.frame_path) |path| deleteFramePath(path);
            return;
        }

        if (event.frame_path) |path| {
            if (self.path) |old_path| {
                deleteFramePath(old_path);
                allocator.free(old_path);
            }
            self.path = try allocator.dupe(u8, path);
        } else {
            if (event.frame_slot >= FRAME_SLOT_COUNT) return error.InvalidFrameSlot;
            if (!self.slot_ready[event.frame_slot]) return error.InvalidFrameSlot;
            if (event.byte_len > self.slots[event.frame_slot].len) return error.FrameTooLarge;
            try self.staging.resize(allocator, event.byte_len);
            @memcpy(self.staging.items[0..event.byte_len], self.slots[event.frame_slot][0..event.byte_len]);
            if (self.path) |old_path| {
                deleteFramePath(old_path);
                allocator.free(old_path);
                self.path = null;
            }
        }
        self.sequence = event.frame_sequence;
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
    ) !bool {
        var upload_path: ?[]u8 = null;
        var upload_sequence: u64 = 0;
        var upload_width: u32 = 0;
        var upload_height: u32 = 0;
        var upload_byte_len: usize = 0;
        var upload_pixels: []u8 = &.{};

        {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (!self.dirty or self.width == 0 or self.height == 0 or self.byte_len == 0) {
                return false;
            }
            upload_sequence = self.sequence;
            upload_width = self.width;
            upload_height = self.height;
            upload_byte_len = self.byte_len;
            if (self.path) |path| {
                upload_path = path;
                self.path = null;
            } else {
                try frame_buffer.resize(allocator, upload_byte_len);
                @memcpy(frame_buffer.items[0..upload_byte_len], self.staging.items[0..upload_byte_len]);
                upload_pixels = frame_buffer.items[0..upload_byte_len];
            }
            self.dirty = false;
        }
        defer {
            if (upload_path) |path| {
                deleteFramePath(path);
                allocator.free(path);
            }
        }

        const read_start = monotonicTimestampNs();
        if (upload_path) |path| {
            try frame_buffer.resize(allocator, upload_byte_len);
            var threaded = std.Io.Threaded.init_single_threaded;
            const file = try std.Io.Dir.openFileAbsolute(threaded.io(), path, .{ .mode = .read_only });
            defer file.close(threaded.io());

            var read_buffer: [8 * 1024]u8 = undefined;
            var reader = file.reader(threaded.io(), &read_buffer);
            try reader.interface.readSliceAll(frame_buffer.items[0..upload_byte_len]);
            upload_pixels = frame_buffer.items[0..upload_byte_len];
        }
        const read_end = monotonicTimestampNs();

        const upload_start = monotonicTimestampNs();
        try texture.uploadBgra(upload_width, upload_height, upload_pixels);
        const upload_end = monotonicTimestampNs();
        if (frameLogEnabled()) {
            log.info(
                "snapshot frame seq={} read_ms={d:.3} upload_ms={d:.3} bytes={} size={}x{}",
                .{
                    upload_sequence,
                    nanosToMillis(read_end - read_start),
                    nanosToMillis(upload_end - upload_start),
                    upload_byte_len,
                    upload_width,
                    upload_height,
                },
            );
        }
        return true;
    }
};

const WaylandSubsurface = struct {
    handle: ?*RawWaylandSubsurface = null,
    display: ?*anyopaque = null,
    parent_surface: ?*anyopaque = null,
    x: i32 = 0,
    y: i32 = 0,
    width: u32 = 0,
    height: u32 = 0,
    visible: bool = false,

    fn attach(self: *WaylandSubsurface, host: *const browser_types.LinuxWaylandHost) !void {
        const display = host.display orelse return error.WaylandHostUnavailable;
        const parent_surface = host.surface orelse return error.WaylandHostUnavailable;
        if (self.handle != null and self.display == display and self.parent_surface == parent_surface) {
            return;
        }
        self.deinit();
        self.handle = verde_wayland_subsurface_create(display, parent_surface) orelse return error.WaylandSurfaceUnavailable;
        self.display = display;
        self.parent_surface = parent_surface;
    }

    fn setBounds(self: *WaylandSubsurface, x: i32, y: i32, width: u32, height: u32) !void {
        self.x = x;
        self.y = y;
        self.width = @max(width, 1);
        self.height = @max(height, 1);
        if (self.handle == null) return;
        if (verde_wayland_subsurface_set_bounds(self.handle, x, y, self.width, self.height) != 0) return error.WaylandBufferUnavailable;
    }

    fn show(self: *WaylandSubsurface) !void {
        self.visible = true;
        if (self.handle == null) return;
        if (verde_wayland_subsurface_show(self.handle) != 0) return error.WaylandBufferUnavailable;
    }

    fn hide(self: *WaylandSubsurface) void {
        self.visible = false;
        verde_wayland_subsurface_hide(self.handle);
    }

    fn deinit(self: *WaylandSubsurface) void {
        self.hide();
        verde_wayland_subsurface_destroy(self.handle);
        self.* = .{};
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
    pane_scale: f32 = 1.0,
    host_window: u64 = 0,
    current_url: ?[]u8 = null,
    wayland_subsurface: WaylandSubsurface = .{},

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
        if (!waylandSubsurfaceEnabled()) {
            try controller.spawnHelper();
        }
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
        self.wayland_subsurface.deinit();
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
        return self.child_pid != null or (waylandSubsurfaceEnabled() and self.wayland_subsurface.handle != null);
    }

    pub fn runtimeMode(self: *const Controller) browser_types.RuntimeMode {
        _ = self;
        return .keep_warm;
    }

    pub fn supportsInspector(self: *const Controller) bool {
        _ = self;
        return !waylandSubsurfaceEnabled();
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
        if (self.child_pid == null and !(waylandSubsurfaceEnabled() and self.wayland_subsurface.handle != null)) return null;
        return 1;
    }

    pub fn paneTexture(self: *const Controller) ?browser_texture.PaneTexture {
        _ = self;
        return null;
    }

    /// Stores the SDL host window handle and initializes the app-owned Wayland subsurface when requested.
    pub fn setHostWindow(self: *Controller, handle: ?*anyopaque) !void {
        self.host_window = if (handle) |value| @intFromPtr(value) else 0;
        if (waylandSubsurfaceEnabled()) {
            const host_ptr = handle orelse return error.WaylandHostUnavailable;
            const host: *const browser_types.LinuxWaylandHost = @ptrCast(@alignCast(host_ptr));
            try self.wayland_subsurface.attach(host);
            try self.wayland_subsurface.setBounds(
                self.pane_screen_x,
                self.pane_screen_y,
                self.pane_width,
                self.pane_height,
            );
        }
        try self.sendCommand(.{
            .kind = .set_host_window,
            .host_window = self.host_window,
        });
    }

    /// Reports whether Linux is using Wayland native presentation, the diagnostic helper window, or snapshot fallback.
    pub fn presentationKind(self: *const Controller) browser_types.PresentationKind {
        _ = self;
        return configuredPresentationKind();
    }

    /// Requests that the Linux browser helper warm the offscreen browser surface.
    pub fn show(self: *Controller) !void {
        if (waylandSubsurfaceEnabled()) {
            try self.wayland_subsurface.show();
            try self.queue.push(self.allocator, .opened);
            try self.queue.push(self.allocator, .{ .failed = try self.allocator.dupe(u8, WAYLAND_SUBSURFACE_PROBE_MESSAGE) });
            return;
        }
        try self.sendCommand(.{
            .kind = .show,
            .width = self.pane_width,
            .height = self.pane_height,
            .scale = self.pane_scale,
            .screen_x = self.pane_screen_x,
            .screen_y = self.pane_screen_y,
            .payload = self.current_url orelse "about:blank",
        });
    }

    /// Requests that the Linux browser helper pause its surface updates.
    pub fn hide(self: *Controller) !void {
        if (waylandSubsurfaceEnabled()) {
            self.wayland_subsurface.hide();
            try self.queue.push(self.allocator, .closed);
            return;
        }
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
            .scale = self.pane_scale,
        });
    }

    /// Moves and resizes the helper-owned native surface to the Palette browser content rectangle.
    pub fn setPaneBounds(self: *Controller, bounds: browser_types.PaneBounds) !void {
        self.pane_width = @max(bounds.width, 1);
        self.pane_height = @max(bounds.height, 1);
        self.pane_screen_x = bounds.screen_x;
        self.pane_screen_y = bounds.screen_y;
        self.pane_scale = @max(bounds.scale, 0.05);
        if (waylandSubsurfaceEnabled()) {
            try self.wayland_subsurface.setBounds(
                self.pane_screen_x,
                self.pane_screen_y,
                self.pane_width,
                self.pane_height,
            );
            return;
        }
        try self.sendCommand(.{
            .kind = .set_bounds,
            .screen_x = self.pane_screen_x,
            .screen_y = self.pane_screen_y,
            .width = self.pane_width,
            .height = self.pane_height,
            .scale = self.pane_scale,
        });
    }

    /// Navigates the Linux browser helper to the requested URL.
    pub fn navigate(self: *Controller, url: []const u8) !void {
        try self.setCurrentUrl(url);
        if (waylandSubsurfaceEnabled()) {
            try self.queue.push(self.allocator, .{ .failed = try self.allocator.dupe(u8, WAYLAND_SUBSURFACE_PROBE_MESSAGE) });
            return;
        }
        try self.sendCommand(.{
            .kind = .navigate,
            .width = self.pane_width,
            .height = self.pane_height,
            .scale = self.pane_scale,
            .screen_x = self.pane_screen_x,
            .screen_y = self.pane_screen_y,
            .payload = url,
        });
    }

    /// Evaluates JavaScript inside the Linux browser helper.
    pub fn eval(self: *Controller, js: []const u8) !void {
        if (waylandSubsurfaceEnabled()) {
            return;
        }
        try self.sendCommand(.{ .kind = .eval, .payload = js });
    }

    /// Sends a host-originated JSON payload into the Linux browser helper.
    pub fn postJson(self: *Controller, json: []const u8) !void {
        if (waylandSubsurfaceEnabled()) {
            return;
        }
        try self.sendCommand(.{ .kind = .post_json, .payload = json });
    }

    /// Navigates backward through the helper using WebKitGTK history.
    pub fn goBack(self: *Controller) !void {
        if (waylandSubsurfaceEnabled()) return;
        try self.sendCommand(.{ .kind = .go_back });
    }

    /// Navigates forward through the helper using WebKitGTK history.
    pub fn goForward(self: *Controller) !void {
        if (waylandSubsurfaceEnabled()) return;
        try self.sendCommand(.{ .kind = .go_forward });
    }

    /// Reloads the helper page using WebKitGTK navigation.
    pub fn reload(self: *Controller) !void {
        if (waylandSubsurfaceEnabled()) return;
        try self.sendCommand(.{ .kind = .reload });
    }

    /// Gives the visible helper's WebKit view native focus when that presentation is active.
    pub fn focus(self: *Controller) !void {
        if (waylandSubsurfaceEnabled()) return;
        try self.sendCommand(.{ .kind = .focus });
    }

    /// Clears native focus from the visible helper when that presentation is active.
    pub fn blur(self: *Controller) !void {
        if (waylandSubsurfaceEnabled()) return;
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
    pub fn uploadFrame(self: *Controller, texture: *browser_texture.PaneTexture) !bool {
        if (waylandSubsurfaceEnabled()) {
            return false;
        }
        return try self.frame.uploadIntoTexture(self.allocator, &self.frame_buffer, texture);
    }

    // Launches the installed browser helper binary beside the desktop executable.
    fn spawnHelper(self: *Controller) !void {
        const helper_path = try browserHelperPath(self.allocator, wpeEnabled());
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
        const frame_fds: ?[FRAME_SLOT_COUNT]std.posix.fd_t = createFrameSlots(self.frame, self.allocator) catch |err| frame_fds: {
            log.warn("Linux WebKit shared frame slots unavailable: {}; falling back to temp-frame files", .{err});
            break :frame_fds null;
        };
        var frame_fds_to_close = frame_fds;
        errdefer if (frame_fds_to_close) |fds| {
            for (fds) |fd| _ = std.c.close(fd);
            self.frame.deinit(self.allocator);
        };

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
            execHelperChild(helper_dir_z.ptr, helper_path_z.ptr, argv.ptr, stdin_pipe, stdout_pipe, frame_fds);
        }

        if (frame_fds) |fds| {
            for (fds) |fd| _ = std.c.close(fd);
            frame_fds_to_close = null;
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
    if (waylandDiagnosticHelperEnabled()) return true;
    const override_value = if (std.c.getenv("VERDE_BROWSER_LINUX_SHOW_HELPER")) |value_ptr| std.mem.span(value_ptr) else null;
    const unsafe_wayland = if (std.c.getenv("VERDE_BROWSER_LINUX_UNSAFE_WAYLAND_HELPER")) |value_ptr| std.mem.span(value_ptr) else null;
    const session_type = if (std.c.getenv("XDG_SESSION_TYPE")) |value_ptr| std.mem.span(value_ptr) else null;
    const gdk_backend = if (std.c.getenv("GDK_BACKEND")) |value_ptr| std.mem.span(value_ptr) else null;
    return visibleHelperEnabledFromValues(override_value, unsafe_wayland, session_type, gdk_backend);
}

fn waylandDiagnosticHelperEnabled() bool {
    const override_value = if (std.c.getenv("VERDE_BROWSER_LINUX_WAYLAND_HELPER")) |value_ptr|
        std.mem.span(value_ptr)
    else if (std.c.getenv("VERDE_BROWSER_LINUX_NATIVE_WAYLAND_SURFACE")) |value_ptr|
        std.mem.span(value_ptr)
    else
        null;
    const session_type = if (std.c.getenv("XDG_SESSION_TYPE")) |value_ptr| std.mem.span(value_ptr) else null;
    const wayland_display = if (std.c.getenv("WAYLAND_DISPLAY")) |value_ptr| std.mem.span(value_ptr) else null;
    const gdk_backend = if (std.c.getenv("GDK_BACKEND")) |value_ptr| std.mem.span(value_ptr) else null;
    return waylandDiagnosticHelperEnabledFromValues(override_value, session_type, wayland_display, gdk_backend);
}

fn waylandDiagnosticHelperEnabledFromValues(override_value: ?[]const u8, session_type: ?[]const u8, wayland_display: ?[]const u8, gdk_backend: ?[]const u8) bool {
    if (override_value) |value| {
        if (std.mem.eql(u8, value, "0")) return false;
        if (!std.mem.eql(u8, value, "1")) return false;
    } else {
        return false;
    }
    if (session_type) |value| {
        if (std.mem.eql(u8, value, "wayland")) return true;
        if (std.mem.eql(u8, value, "x11")) return false;
    }
    if (wayland_display) |value| {
        if (value.len > 0) return true;
    }
    if (gdk_backend) |value| {
        return std.mem.indexOf(u8, value, "wayland") != null;
    }
    return false;
}

fn visibleHelperEnabledFromValues(override_value: ?[]const u8, unsafe_wayland: ?[]const u8, session_type: ?[]const u8, gdk_backend: ?[]const u8) bool {
    _ = unsafe_wayland;

    if (override_value) |value| {
        if (std.mem.eql(u8, value, "1")) return true;
        if (std.mem.eql(u8, value, "0")) return false;
    }
    if (session_type) |value| {
        if (std.mem.eql(u8, value, "x11")) return true;
        if (std.mem.eql(u8, value, "wayland")) return true;
    }
    if (gdk_backend) |value| {
        return std.mem.indexOf(u8, value, "wayland") != null or std.mem.indexOf(u8, value, "x11") != null;
    }
    return false;
}

test "visible helper selection honors overrides and session defaults" {
    try std.testing.expect(visibleHelperEnabledFromValues("1", null, "wayland", null));
    try std.testing.expect(visibleHelperEnabledFromValues("1", "1", "wayland", null));
    try std.testing.expect(!visibleHelperEnabledFromValues("0", null, "x11", null));
    try std.testing.expect(visibleHelperEnabledFromValues(null, null, "x11", null));
    try std.testing.expect(visibleHelperEnabledFromValues(null, null, "wayland", "x11"));
    try std.testing.expect(visibleHelperEnabledFromValues(null, null, null, "x11"));
    try std.testing.expect(visibleHelperEnabledFromValues(null, null, null, "x11,wayland"));
}

test "Wayland diagnostic helper selection requires explicit Wayland opt-in" {
    try std.testing.expect(waylandDiagnosticHelperEnabledFromValues("1", "wayland", null, null));
    try std.testing.expect(waylandDiagnosticHelperEnabledFromValues("1", null, "wayland-1", null));
    try std.testing.expect(waylandDiagnosticHelperEnabledFromValues("1", null, null, "wayland"));
    try std.testing.expect(!waylandDiagnosticHelperEnabledFromValues(null, "wayland", "wayland-1", null));
    try std.testing.expect(!waylandDiagnosticHelperEnabledFromValues("0", "wayland", "wayland-1", null));
    try std.testing.expect(!waylandDiagnosticHelperEnabledFromValues("1", "x11", "wayland-1", "wayland"));
}

/// Resolves the installed Linux browser helper path beside the running desktop executable.
fn browserHelperPath(allocator: std.mem.Allocator, use_wpe: bool) ![]u8 {
    var threaded = std.Io.Threaded.init_single_threaded;
    const exe_dir = try std.process.executableDirPathAlloc(threaded.io(), allocator);
    defer allocator.free(exe_dir);
    return try std.fs.path.join(allocator, &.{ exe_dir, if (use_wpe) "verde-browser-linux-wpe" else "verde-browser-linux" });
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
    frame_fds: ?[FRAME_SLOT_COUNT]std.posix.fd_t,
) noreturn {
    _ = std.c.setpgid(0, 0);
    if (std.c.dup2(stdin_pipe[0], std.c.STDIN_FILENO) < 0) std.c._exit(126);
    if (std.c.dup2(stdout_pipe[1], std.c.STDOUT_FILENO) < 0) std.c._exit(126);
    if (frame_fds) |fds| {
        inline for (fds, 0..) |frame_fd, index| {
            if (std.c.dup2(frame_fd, FRAME_FD_BASE + @as(std.posix.fd_t, @intCast(index))) < 0) std.c._exit(126);
        }
    }

    _ = std.c.close(stdin_pipe[0]);
    _ = std.c.close(stdin_pipe[1]);
    _ = std.c.close(stdout_pipe[0]);
    _ = std.c.close(stdout_pipe[1]);
    if (frame_fds) |fds| {
        for (fds) |frame_fd| _ = std.c.close(frame_fd);
    }
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
    if (waylandSubsurfaceEnabled()) {
        _ = setenv("VERDE_BROWSER_LINUX_SHOW_HELPER", "0", 1);
    }
    if (frame_fds != null) {
        _ = setenv("VERDE_BROWSER_LINUX_FRAME0_FD", "240", 1);
        _ = setenv("VERDE_BROWSER_LINUX_FRAME1_FD", "241", 1);
        _ = setenv("VERDE_BROWSER_LINUX_FRAME2_FD", "242", 1);
    }

    _ = std.c.execve(helper_path_z, argv, std.c.environ);
    std.c._exit(127);
}

fn closeInheritedFileDescriptors() void {
    const limits = std.posix.getrlimit(.NOFILE) catch return;
    const max_fd: usize = @intCast(@min(limits.cur, 4096));
    var fd: usize = 3;
    while (fd < max_fd) : (fd += 1) {
        if (fd >= FRAME_FD_BASE and fd < FRAME_FD_BASE + FRAME_SLOT_COUNT) continue;
        _ = std.c.close(@intCast(fd));
    }
}

// Creates shared frame slots so the WebKit helper can publish pixels without rewriting files.
fn createFrameSlots(frame: *SharedFrame, allocator: std.mem.Allocator) ![FRAME_SLOT_COUNT]std.posix.fd_t {
    var frame_fds: [FRAME_SLOT_COUNT]std.posix.fd_t = undefined;
    errdefer frame.deinit(allocator);

    inline for (0..FRAME_SLOT_COUNT) |index| {
        const frame_name = try std.fmt.allocPrint(allocator, "verde-browser-linux-frame-{d}", .{index});
        defer allocator.free(frame_name);

        frame_fds[index] = try std.posix.memfd_create(frame_name, std.posix.MFD.CLOEXEC);
        errdefer _ = std.c.close(frame_fds[index]);

        if (std.c.ftruncate(frame_fds[index], FRAME_BYTES_MAX) != 0) return error.Unexpected;
        frame.slots[index] = try std.posix.mmap(
            null,
            FRAME_BYTES_MAX,
            .{ .READ = true, .WRITE = true },
            .{ .TYPE = .SHARED },
            frame_fds[index],
            0,
        );
        frame.slot_ready[index] = true;
        @memset(frame.slots[index], 0);
    }
    return frame_fds;
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
