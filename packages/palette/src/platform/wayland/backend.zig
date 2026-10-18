//! Wayland backend: App (connection, globals, seat, event queue) and Window (xdg_toplevel).
//!
//! Threading: everything except `App.wakeup` must be called from the thread that created the
//! App. Memory: all per-event state lives in fixed buffers inside App; the heap is only touched
//! at init, window/buffer creation, keymap changes, dmabuf feedback updates and clipboard
//! operations.
//!
//! Event flow: `pump` polls the socket, the wakeup eventfd, the key-repeat timerfd and
//! clipboard write fds; complete messages are decoded and translated into `Event`s pushed onto
//! a 256-entry ring. Text payloads are copied into a 16 KiB arena that is reset when the queue
//! drains, so `Event` text slices stay valid until the next `pollEvent`/`waitEvent` call.

const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;

const wire = @import("wire.zig");
const proto = wire.proto;
const xkb = @import("xkb.zig");
const keysym = @import("keysym.zig");
const input = @import("input.zig");
const selection = @import("selection.zig");
const contract = @import("../present.zig");
const ev = @import("../../event.zig");
const Event = ev.Event;

const log = std.log.scoped(.wayland);

pub const Rect = @import("../../draw.zig").Rect;

pub const max_windows = 16;
pub const max_buffers = 64;
pub const max_outputs = 16;
const queue_capacity = 256;
/// Dispatch stops while fewer than this many queue slots are free (one wayland message can
/// produce several events, e.g. a pointer frame).
const queue_reserve = 16;
const text_capacity = 16 * 1024;
const wakeup_capacity = 256;
const max_repeats_per_tick = 4;
const configure_timeout_ns = 2 * std.time.ns_per_s;

pub const Error = wire.Error || error{
    MissingGlobal,
    TooManyWindows,
    TooManyBuffers,
    InvalidBuffer,
    Unsupported,
    ImportFailed,
    NoXdgRuntimeDir,
    NameTooLong,
    ConnectionRefused,
    InvalidWaylandSocket,
};

pub const AppOptions = struct {
    /// Default xdg_toplevel app_id for windows (tests must use a `palette-test` prefix).
    app_id: []const u8 = "palette",
    /// Process environment (`std.process.Init.environ`). Empty = libc `getenv` fallback.
    environ: std.process.Environ = .empty,
    /// Block SIGINT/SIGTERM for the calling thread and turn them into `Event.quit` through a
    /// signalfd watched by the event loop (SDL's default behaviour). Call `App.init` before
    /// spawning threads so they inherit the mask; threads created earlier still receive the
    /// default disposition.
    handle_signals: bool = false,
    /// Windows: ICON resource id in the executable used for the title bar,
    /// Alt+Tab and taskbar window icon (0 = none). Ignored elsewhere.
    icon_resource_id: u16 = 0,
};

pub const SystemTheme = enum { unknown, light, dark };

pub const Decorations = enum {
    /// Ask the compositor to draw decorations (xdg-decoration server_side).
    server,
    /// Ask for no compositor decorations; the app draws its own (or none).
    client,
};

pub const WindowOptions = struct {
    title: []const u8 = "Palette",
    /// Logical size. The compositor may override it (tiling); `resized` reports the result.
    width: u32 = 800,
    height: u32 = 600,
    min_width: u32 = 0,
    min_height: u32 = 0,
    resizable: bool = true,
    /// Overrides `AppOptions.app_id`.
    app_id: ?[]const u8 = null,
    decorations: Decorations = .server,
};

/// CSS cursor names (wp_cursor_shape_v1), plus `hidden`.
pub const CursorShape = enum {
    default,
    context_menu,
    help,
    pointer,
    progress,
    wait,
    cell,
    crosshair,
    text,
    vertical_text,
    alias,
    copy,
    move,
    no_drop,
    not_allowed,
    grab,
    grabbing,
    e_resize,
    n_resize,
    ne_resize,
    nw_resize,
    s_resize,
    se_resize,
    sw_resize,
    w_resize,
    ew_resize,
    ns_resize,
    nesw_resize,
    nwse_resize,
    col_resize,
    row_resize,
    all_scroll,
    zoom_in,
    zoom_out,
    hidden,

    fn protocolShape(s: CursorShape) proto.WpCursorShapeDeviceV1.Shape {
        return switch (s) {
            .hidden => .default,
            inline else => |t| @field(proto.WpCursorShapeDeviceV1.Shape, @tagName(t)),
        };
    }
};

pub const Size = struct { width: u32, height: u32 };

pub const NativeHandles = struct {
    /// The Wayland socket (owned by the App).
    socket_fd: i32,
    /// wl_surface object id on that connection.
    surface_id: u32,
};

pub const WindowStates = packed struct(u8) {
    maximized: bool = false,
    fullscreen: bool = false,
    activated: bool = false,
    resizing: bool = false,
    tiled: bool = false,
    suspended: bool = false,
    _pad: u2 = 0,
};

pub const WmCapabilities = packed struct(u8) {
    window_menu: bool = true,
    maximize: bool = true,
    fullscreen: bool = true,
    minimize: bool = true,
    _pad: u4 = 0,
};

pub const GlobalInfo = struct { name: u32, interface: []const u8, version: u32 };

const Output = struct {
    global: u32 = 0,
    obj: proto.WlOutput = undefined,
    scale: i32 = 1,
    pending_scale: i32 = 1,
    /// Current mode in physical px.
    mode: [2]i32 = .{ 0, 0 },
    live: bool = false,
};

const BufferSlot = struct {
    wl: proto.WlBuffer = undefined,
    window: u32 = 0,
    width: i32 = 0,
    height: i32 = 0,
    live: bool = false,
    busy: bool = false,
};

const Globals = struct {
    compositor: ?proto.WlCompositor = null,
    shm: ?proto.WlShm = null,
    wm_base: ?proto.XdgWmBase = null,
    ddm: ?proto.WlDataDeviceManager = null,
    primary_mgr: ?proto.ZwpPrimarySelectionDeviceManagerV1 = null,
    decoration_mgr: ?proto.ZxdgDecorationManagerV1 = null,
    viewporter: ?proto.WpViewporter = null,
    fractional_mgr: ?proto.WpFractionalScaleManagerV1 = null,
    cursor_shape_mgr: ?proto.WpCursorShapeManagerV1 = null,
    text_input_mgr: ?proto.ZwpTextInputManagerV3 = null,
    dmabuf: ?proto.ZwpLinuxDmabufV1 = null,
    activation: ?proto.XdgActivationV1 = null,
};

/// Globals bound by interface name, with the highest version we speak.
const bindings = .{
    .{ "compositor", proto.WlCompositor, 6 },
    .{ "shm", proto.WlShm, 1 },
    .{ "wm_base", proto.XdgWmBase, 6 },
    .{ "ddm", proto.WlDataDeviceManager, 3 },
    .{ "primary_mgr", proto.ZwpPrimarySelectionDeviceManagerV1, 1 },
    .{ "decoration_mgr", proto.ZxdgDecorationManagerV1, 1 },
    .{ "viewporter", proto.WpViewporter, 1 },
    .{ "fractional_mgr", proto.WpFractionalScaleManagerV1, 1 },
    .{ "cursor_shape_mgr", proto.WpCursorShapeManagerV1, 1 },
    .{ "text_input_mgr", proto.ZwpTextInputManagerV3, 1 },
    .{ "dmabuf", proto.ZwpLinuxDmabufV1, 4 },
    .{ "activation", proto.XdgActivationV1, 1 },
};
/// wl_seat v10 moves key repeat into the compositor (`repeated` key state); v9 keeps it ours.
const seat_max_version = 9;
const output_max_version = 4;

const ClipSelection = selection.Selection(proto.WlDataOffer, proto.WlDataSource);
const PrimarySelection = selection.Selection(proto.ZwpPrimarySelectionOfferV1, proto.ZwpPrimarySelectionSourceV1);

pub const App = struct {
    gpa: std.mem.Allocator,
    conn: *wire.Connection,
    app_id_buf: [128]u8 = undefined,
    app_id_len: usize = 0,

    registry: proto.WlRegistry = undefined,
    g: Globals = .{},
    global_list: std.ArrayList(GlobalInfo) = .empty,
    global_names: std.heap.ArenaAllocator,
    outputs: [max_outputs]Output = @splat(.{}),

    seat: ?proto.WlSeat = null,
    seat_global: u32 = 0,
    pointer: ?proto.WlPointer = null,
    keyboard: ?proto.WlKeyboard = null,
    cursor_device: ?proto.WpCursorShapeDeviceV1 = null,
    data_device: ?proto.WlDataDevice = null,
    primary_device: ?proto.ZwpPrimarySelectionDeviceV1 = null,
    text_input: ?proto.ZwpTextInputV3 = null,

    windows: [max_windows]?*Window = @splat(null),
    next_window_id: u32 = 1,
    buffers: [max_buffers]BufferSlot = @splat(.{}),

    // Event queue.
    queue: [queue_capacity]Event = undefined,
    q_head: usize = 0,
    q_len: usize = 0,
    text: [text_capacity]u8 = undefined,
    text_len: usize = 0,
    dropped_events: u64 = 0,
    dead: bool = false,

    // Cross-thread wakeups.
    event_fd: i32 = -1,
    /// signalfd for SIGINT/SIGTERM (`AppOptions.handle_signals`), or -1.
    signal_fd: i32 = -1,
    /// Signal mask before `handle_signals` blocked SIGINT/SIGTERM (restored on deinit).
    old_sigmask: ?linux.sigset_t = null,
    wake_lock: std.atomic.Value(u32) = .init(0),
    wake_ring: [wakeup_capacity]u64 = undefined,
    wake_len: usize = 0,

    // Keyboard.
    keymap: ?xkb.Keymap = null,
    xkb_state: xkb.State = .{},
    mods: ev.Mods = .{},
    /// Physical modifier keys currently held (left/right), from wl_keyboard key events.
    mod_keys: ev.ModKeys = .{},
    kb_focus: u32 = 0,
    repeat_fd: i32 = -1,
    repeat_rate: i32 = 25,
    repeat_delay: i32 = 600,
    repeat_key: u32 = 0,

    // Pointer.
    ptr_focus: u32 = 0,
    ptr_x: f32 = 0,
    ptr_y: f32 = 0,
    last_motion_x: f32 = 0,
    last_motion_y: f32 = 0,
    ptr_buttons: ev.ButtonState = .{},
    ptr_enter_serial: u32 = 0,
    ptr_frame: input.PointerFrame = .{},
    clicks: input.ClickCounter = .{},
    /// Latest input serial (key/button press, keyboard enter) for selections and activation.
    last_serial: u32 = 0,

    // Text input (IME).
    ti_focus: u32 = 0,
    ti_commits: u32 = 0,
    preedit_active: bool = false,
    ti_preedit: [1024]u8 = undefined,
    ti_preedit_len: usize = 0,
    ti_preedit_cursor: [2]i32 = .{ -1, -1 },
    ti_has_preedit: bool = false,
    ti_commit: [4096]u8 = undefined,
    ti_commit_len: usize = 0,
    ti_has_commit: bool = false,

    // Selections.
    clipboard: ClipSelection = .{},
    primary: PrimarySelection = .{},
    dnd_offer: u32 = 0,

    // dmabuf.
    dmabuf_formats: std.ArrayList(contract.FormatModifier) = .empty,
    dmabuf_pending: std.ArrayList(contract.FormatModifier) = .empty,
    dmabuf_main_device: ?u64 = null,
    dmabuf_feedback: ?proto.ZwpLinuxDmabufFeedbackV1 = null,
    format_table: ?[]align(std.heap.page_size_min) const u8 = null,
    params_failed: bool = false,
    /// (format, modifier, planes) that create_immed already accepted; later imports with the
    /// same layout skip the verification roundtrip (resizes re-import every buffer).
    dmabuf_verified: ?struct { format: u32, modifier: u64, planes: u8 } = null,

    // -- lifecycle --------------------------------------------------------------------------

    pub fn init(gpa: std.mem.Allocator, options: AppOptions) !*App {
        const env: wire.Env = .{ .environ = options.environ };
        const conn = try wire.Connection.connect(gpa, env);
        errdefer conn.deinit();
        const app = try gpa.create(App);
        errdefer gpa.destroy(app);
        app.* = .{ .gpa = gpa, .conn = conn, .global_names = .init(gpa) };
        app.app_id_len = @min(options.app_id.len, app.app_id_buf.len);
        @memcpy(app.app_id_buf[0..app.app_id_len], options.app_id[0..app.app_id_len]);

        const efd = linux.eventfd(0, linux.EFD.CLOEXEC | linux.EFD.NONBLOCK);
        if (linux.errno(efd) != .SUCCESS) return error.SystemResources;
        app.event_fd = @intCast(efd);
        const tfd = linux.timerfd_create(.MONOTONIC, .{ .CLOEXEC = true, .NONBLOCK = true });
        if (linux.errno(tfd) != .SUCCESS) {
            _ = linux.close(app.event_fd);
            return error.SystemResources;
        }
        app.repeat_fd = @intCast(tfd);
        errdefer app.closeFds();
        if (options.handle_signals) try app.installSignalFd();

        app.registry = try conn.display().getRegistry(conn);
        try conn.roundtrip(app);
        inline for (.{ "compositor", "wm_base", "shm" }) |req| {
            if (@field(app.g, req) == null) {
                log.err("compositor lacks a required global ({s})", .{req});
                return error.MissingGlobal;
            }
        }
        try app.setupSeatDevices();
        if (app.g.dmabuf) |d| if (conn.objectVersion(d) >= 4) {
            app.dmabuf_feedback = try d.getDefaultFeedback(conn);
        };
        // Seat capabilities, outputs, dmabuf formats/feedback, keymap.
        try conn.roundtrip(app);
        try conn.roundtrip(app);
        return app;
    }

    fn closeFds(app: *App) void {
        if (app.event_fd >= 0) _ = linux.close(app.event_fd);
        if (app.repeat_fd >= 0) _ = linux.close(app.repeat_fd);
        if (app.signal_fd >= 0) _ = linux.close(app.signal_fd);
        if (app.old_sigmask) |*old| _ = linux.sigprocmask(linux.SIG.SETMASK, old, null);
        app.event_fd = -1;
        app.repeat_fd = -1;
        app.signal_fd = -1;
        app.old_sigmask = null;
    }

    fn installSignalFd(app: *App) !void {
        var set = linux.sigemptyset();
        linux.sigaddset(&set, .INT);
        linux.sigaddset(&set, .TERM);
        var old: linux.sigset_t = undefined;
        if (linux.errno(linux.sigprocmask(linux.SIG.BLOCK, &set, &old)) != .SUCCESS) return error.SystemResources;
        app.old_sigmask = old;
        const sfd = linux.signalfd(-1, &set, linux.SFD.CLOEXEC | linux.SFD.NONBLOCK);
        if (linux.errno(sfd) != .SUCCESS) return error.SystemResources;
        app.signal_fd = @intCast(sfd);
    }

    /// Drains the signalfd; any SIGINT/SIGTERM becomes one `quit` per batch.
    fn drainSignals(app: *App) void {
        var got = false;
        while (true) {
            var info: linux.signalfd_siginfo = undefined;
            const rc = linux.read(app.signal_fd, std.mem.asBytes(&info), @sizeOf(linux.signalfd_siginfo));
            if (linux.errno(rc) != .SUCCESS or rc != @sizeOf(linux.signalfd_siginfo)) break;
            got = true;
        }
        if (got) app.push(.quit);
    }

    pub fn deinit(app: *App) void {
        const c = app.conn;
        for (app.windows) |w| if (w) |win| win.destroy();
        app.clipboard.deinit(c, app.gpa);
        app.primary.deinit(c, app.gpa);
        if (app.text_input) |t| t.destroy(c) catch {};
        if (app.data_device) |d| if (c.objectVersion(d) >= 2) d.release(c) catch {};
        if (app.primary_device) |d| d.destroy(c) catch {};
        app.releasePointer();
        app.releaseKeyboard();
        if (app.dmabuf_feedback) |f| f.destroy(c) catch {};
        if (app.seat) |s| if (c.objectVersion(s) >= 5) s.release(c) catch {};
        for (&app.outputs) |*o| if (o.live and c.objectVersion(o.obj) >= 3) o.obj.release(c) catch {};
        c.flush() catch {};
        c.deinit();
        app.closeFds();
        if (app.keymap) |*k| k.deinit();
        if (app.format_table) |t| _ = linux.munmap(t.ptr, t.len);
        app.dmabuf_formats.deinit(app.gpa);
        app.dmabuf_pending.deinit(app.gpa);
        app.global_list.deinit(app.gpa);
        app.global_names.deinit();
        app.gpa.destroy(app);
    }

    fn setupSeatDevices(app: *App) !void {
        const seat = app.seat orelse return;
        const c = app.conn;
        if (app.g.ddm) |m| app.data_device = try m.getDataDevice(c, seat);
        if (app.g.primary_mgr) |m| app.primary_device = try m.getDevice(c, seat);
        if (app.g.text_input_mgr) |m| app.text_input = try m.getTextInput(c, seat);
    }

    fn appId(app: *const App) []const u8 {
        return app.app_id_buf[0..app.app_id_len];
    }

    /// Globals advertised at startup (for diagnostics).
    pub fn globals(app: *const App) []const GlobalInfo {
        return app.global_list.items;
    }

    // -- event queue --------------------------------------------------------------------------

    fn push(app: *App, e: Event) void {
        if (app.q_len == queue_capacity) {
            app.dropped_events += 1;
            if (app.dropped_events == 1) log.warn("event queue overflow; dropping events", .{});
            return;
        }
        app.queue[(app.q_head + app.q_len) % queue_capacity] = e;
        app.q_len += 1;
    }

    fn pop(app: *App, out: *Event) bool {
        if (app.q_len == 0) return false;
        out.* = app.queue[app.q_head];
        app.q_head = (app.q_head + 1) % queue_capacity;
        app.q_len -= 1;
        return true;
    }

    /// Copies text into the per-batch arena. Returns null (and drops the event) when full.
    fn storeText(app: *App, s: []const u8) ?[]const u8 {
        if (app.text_len + s.len > app.text.len) {
            log.warn("text arena full; dropping {d} bytes", .{s.len});
            return null;
        }
        const out = app.text[app.text_len..][0..s.len];
        @memcpy(out, s);
        app.text_len += s.len;
        return out;
    }

    /// Non-blocking: returns the next event if one is available.
    pub fn pollEvent(app: *App, out: *Event) bool {
        if (app.pop(out)) return true;
        app.text_len = 0;
        app.pump(0);
        return app.pop(out);
    }

    /// Blocks until an event arrives or `timeout_ns` elapses (null = forever). Returns false
    /// on timeout (or once the connection is dead and the final `quit` was delivered).
    pub fn waitEvent(app: *App, out: *Event, timeout_ns: ?u64) bool {
        if (app.pop(out)) return true;
        app.text_len = 0;
        const deadline: ?u64 = if (timeout_ns) |t| wire.monotonicNs() +| t else null;
        while (true) {
            var remaining: ?u64 = null;
            if (deadline) |d| {
                const now = wire.monotonicNs();
                remaining = if (now >= d) 0 else d - now;
            }
            app.pump(remaining);
            if (app.pop(out)) return true;
            if (app.dead) return false;
            if (remaining) |r| if (r == 0) return false;
        }
    }

    /// Thread-safe: posts `Event.user` and wakes `waitEvent`. Identical pending values are
    /// coalesced; at most 256 distinct values are buffered.
    pub fn wakeup(app: *App, user: u64) void {
        while (app.wake_lock.cmpxchgWeak(0, 1, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
        const dup = std.mem.indexOfScalar(u64, app.wake_ring[0..app.wake_len], user) != null;
        if (!dup and app.wake_len < wakeup_capacity) {
            app.wake_ring[app.wake_len] = user;
            app.wake_len += 1;
        }
        app.wake_lock.store(0, .release);
        const one: u64 = 1;
        _ = linux.write(app.event_fd, std.mem.asBytes(&one), 8);
    }

    fn drainWakeups(app: *App) void {
        var buf: [8]u8 = undefined;
        _ = linux.read(app.event_fd, &buf, 8);
        var local: [wakeup_capacity]u64 = undefined;
        while (app.wake_lock.cmpxchgWeak(0, 1, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
        const n = @min(app.wake_len, queue_capacity - app.q_len);
        @memcpy(local[0..n], app.wake_ring[0..n]);
        std.mem.copyForwards(u64, app.wake_ring[0 .. app.wake_len - n], app.wake_ring[n..app.wake_len]);
        app.wake_len -= n;
        const left = app.wake_len;
        app.wake_lock.store(0, .release);
        for (local[0..n]) |v| app.push(.{ .user = v });
        if (left > 0) {
            const one: u64 = 1;
            _ = linux.write(app.event_fd, std.mem.asBytes(&one), 8);
        }
    }

    fn fatal(app: *App, err: anyerror) void {
        if (app.dead) return;
        app.dead = true;
        if (app.conn.display_error) |de| {
            log.err("wayland connection lost: protocol error on {s}#{d} code {d}: {s}", .{ de.interface, de.object_id, de.code, de.message() });
        } else log.err("wayland connection lost: {s}", .{@errorName(err)});
        app.push(.quit);
    }

    /// Decodes buffered messages while the queue has room.
    fn processBuffered(app: *App) void {
        while (!app.dead and app.q_len + queue_reserve <= queue_capacity) {
            const msg = app.conn.nextMessage() catch |e| return app.fatal(e);
            var m = msg orelse return;
            defer m.deinit();
            app.handle(&m) catch |e| {
                if (app.conn.closed) return app.fatal(e);
                log.warn("error handling {s} event: {s}", .{ @tagName(m.iface), @errorName(e) });
            };
        }
    }

    /// One iteration of the event loop: poll all fds once (up to `timeout_ns`) and dispatch.
    fn pump(app: *App, timeout_ns: ?u64) void {
        if (app.dead) return;
        const c = app.conn;
        app.processBuffered();
        var timeout = timeout_ns;
        if (app.q_len > 0) timeout = 0;

        app.commitPendingFrames();
        while (c.hasPendingOutput()) {
            const sent = c.trySend() catch |e| return app.fatal(e);
            if (!sent) break;
        }

        var pfds: [4 + 2 * selection.max_jobs]linux.pollfd = undefined;
        pfds[0] = .{ .fd = c.fd, .events = linux.POLL.IN | (if (c.hasPendingOutput()) @as(i16, linux.POLL.OUT) else 0), .revents = 0 };
        pfds[1] = .{ .fd = app.event_fd, .events = linux.POLL.IN, .revents = 0 };
        pfds[2] = .{ .fd = app.repeat_fd, .events = linux.POLL.IN, .revents = 0 };
        // A negative fd is ignored by poll, so the slot is always present.
        pfds[3] = .{ .fd = app.signal_fd, .events = linux.POLL.IN, .revents = 0 };
        var n: usize = 4;
        n += app.clipboard.pollFds(pfds[n..]);
        n += app.primary.pollFds(pfds[n..]);

        var ts: linux.timespec = undefined;
        var tsp: ?*linux.timespec = null;
        if (timeout) |t| {
            ts = .{ .sec = @intCast(t / std.time.ns_per_s), .nsec = @intCast(t % std.time.ns_per_s) };
            tsp = &ts;
        }
        const rc = linux.ppoll(&pfds, n, tsp, null);
        switch (linux.errno(rc)) {
            .SUCCESS => {},
            .INTR => return,
            else => return app.fatal(error.Unexpected),
        }
        if (rc == 0) return;

        const wl = pfds[0].revents;
        if (wl & linux.POLL.OUT != 0) _ = c.trySend() catch |e| return app.fatal(e);
        if (wl & linux.POLL.IN != 0) {
            while (true) {
                const got = c.read() catch |e| return app.fatal(e);
                if (got == 0) break;
            }
            app.processBuffered();
        } else if (wl & (linux.POLL.ERR | linux.POLL.HUP) != 0) {
            return app.fatal(error.ConnectionClosed);
        }
        if (pfds[1].revents & linux.POLL.IN != 0) app.drainWakeups();
        if (pfds[2].revents & linux.POLL.IN != 0) app.repeatTick();
        if (pfds[3].revents & linux.POLL.IN != 0) app.drainSignals();
        for (pfds[4..n]) |p| if (p.revents != 0) {
            app.clipboard.serviceFd(app.gpa, p.fd);
            app.primary.serviceFd(app.gpa, p.fd);
        };
    }

    /// Pumps until `cond(ctx)` or timeout; used for synchronous waits (initial configure).
    fn pumpUntil(app: *App, ctx: anytype, comptime cond: fn (@TypeOf(ctx)) bool, timeout_ns: u64) bool {
        const deadline = wire.monotonicNs() + timeout_ns;
        while (!cond(ctx)) {
            if (app.dead) return false;
            const now = wire.monotonicNs();
            if (now >= deadline) return false;
            // Leave room in the queue so dispatch keeps making progress.
            if (app.q_len + queue_reserve > queue_capacity) return false;
            app.pump(deadline - now);
        }
        return true;
    }

    fn commitPendingFrames(app: *App) void {
        for (app.windows) |win| if (win) |w| if (w.frame_cb != null and !w.frame_committed) {
            w.surface.commit(app.conn) catch {};
            w.frame_committed = true;
        };
    }

    // -- accessors ----------------------------------------------------------------------------

    pub fn modState(app: *const App) ev.Mods {
        return app.mods;
    }

    /// Like `modState`, plus which physical modifier keys are held (left/right).
    pub fn modKeys(app: *const App) ev.ModKeys {
        return app.mod_keys;
    }

    /// Blocks until the compositor processed every request sent so far and its replies were
    /// dispatched (SDL_SyncWindow). Events produced meanwhile are queued normally.
    pub fn sync(app: *App) !void {
        if (app.dead) return error.ConnectionClosed;
        try app.conn.roundtrip(app);
    }

    /// The window under the pointer, if any.
    pub fn pointerFocus(app: *const App) ?*Window {
        return app.windowFromData(app.ptr_focus);
    }

    /// The window with keyboard focus, if any.
    pub fn keyboardFocus(app: *const App) ?*Window {
        return app.windowFromData(app.kb_focus);
    }

    /// Wayland has no portable system appearance query (it is an xdg-desktop-portal D-Bus
    /// setting); report `unknown` so hosts apply their default.
    pub fn systemTheme(app: *const App) SystemTheme {
        _ = app;
        return .unknown;
    }

    /// Size of the display area a window can use, in logical px (origin is always 0,0:
    /// Wayland exposes no global coordinates). This is the largest xdg_toplevel.configure_bounds a window got, or
    /// the largest output mode divided by its scale, or null when nothing is known yet.
    pub fn usableBounds(app: *const App) ?Size {
        var best: [2]i32 = .{ 0, 0 };
        for (app.windows) |win| if (win) |w| {
            if (w.bounds[0] * w.bounds[1] > best[0] * best[1]) best = w.bounds;
        };
        if (best[0] > 0 and best[1] > 0) return .{ .width = @intCast(best[0]), .height = @intCast(best[1]) };
        for (app.outputs) |o| if (o.live and o.mode[0] > 0) {
            const s = @max(o.scale, 1);
            const lw = @divTrunc(o.mode[0], s);
            const lh = @divTrunc(o.mode[1], s);
            if (lw * lh > best[0] * best[1]) best = .{ lw, lh };
        };
        if (best[0] > 0 and best[1] > 0) return .{ .width = @intCast(best[0]), .height = @intCast(best[1]) };
        return null;
    }

    /// `usableBounds` as a rectangle at the origin (Wayland exposes no global coordinates).
    pub fn usableRect(app: *const App) ?Rect {
        const s = app.usableBounds() orelse return null;
        return .{ .x = 0, .y = 0, .w = @floatFromInt(s.width), .h = @floatFromInt(s.height) };
    }

    /// Formats the compositor accepts for dma-buf import. Valid until the next dispatch that
    /// receives updated feedback.
    pub fn dmabufFeedback(app: *const App) contract.DmabufFeedback {
        return .{ .main_device = app.dmabuf_main_device, .formats = app.dmabuf_formats.items };
    }

    pub fn setClipboardText(app: *App, text: []const u8) !void {
        const m = app.g.ddm orelse return error.Unsupported;
        const dev = app.data_device orelse return error.Unsupported;
        const src = try m.createDataSource(app.conn);
        try app.clipboard.set(app.conn, app.gpa, src, dev, app.last_serial, text);
        try app.conn.flush();
    }

    /// Caller owns the returned slice. null = empty clipboard or no text available.
    pub fn getClipboardText(app: *App, allocator: std.mem.Allocator) !?[]u8 {
        if (app.data_device == null) return null;
        return app.clipboard.get(app.conn, allocator);
    }

    pub fn setPrimarySelectionText(app: *App, text: []const u8) !void {
        const m = app.g.primary_mgr orelse return error.Unsupported;
        const dev = app.primary_device orelse return error.Unsupported;
        const src = try m.createSource(app.conn);
        try app.primary.set(app.conn, app.gpa, src, dev, app.last_serial, text);
        try app.conn.flush();
    }

    pub fn getPrimarySelectionText(app: *App, allocator: std.mem.Allocator) !?[]u8 {
        if (app.primary_device == null) return null;
        return app.primary.get(app.conn, allocator);
    }

    fn windowFromData(app: *const App, data: u32) ?*Window {
        if (data == 0 or data > max_windows) return null;
        return app.windows[data - 1];
    }

    fn windowFromSurface(app: *App, surface: proto.WlSurface) ?*Window {
        const o = app.conn.lookup(@intFromEnum(surface)) orelse return null;
        if (o.iface != .wl_surface) return null;
        return app.windowFromData(o.data);
    }

    fn windowId(app: *App, data: u32) ev.WindowId {
        return if (app.windowFromData(data)) |w| w.id else .invalid;
    }

    // -- windows ----------------------------------------------------------------------------

    pub fn createWindow(app: *App, options: WindowOptions) !*Window {
        const c = app.conn;
        const slot: u32 = for (app.windows, 0..) |w, i| {
            if (w == null) break @intCast(i);
        } else return error.TooManyWindows;
        const tag = slot + 1;
        const w = try app.gpa.create(Window);
        errdefer app.gpa.destroy(w);

        const lw: i32 = @intCast(@max(1, @min(options.width, 1 << 15)));
        const lh: i32 = @intCast(@max(1, @min(options.height, 1 << 15)));
        w.* = .{
            .app = app,
            .slot = slot,
            .id = @enumFromInt(app.next_window_id),
            .surface = try app.g.compositor.?.createSurface(c),
            .xdg_surface = undefined,
            .toplevel = undefined,
            .width = lw,
            .height = lh,
            .req_width = lw,
            .req_height = lh,
            .min_width = @intCast(@min(options.min_width, 1 << 15)),
            .min_height = @intCast(@min(options.min_height, 1 << 15)),
            .resizable = options.resizable,
        };
        app.next_window_id +%= 1;
        if (app.next_window_id == 0) app.next_window_id = 1;
        c.setData(w.surface, tag);
        if (app.g.viewporter) |vp| {
            w.viewport = try vp.getViewport(c, w.surface);
            if (app.g.fractional_mgr) |fm| {
                w.fractional = try fm.getFractionalScale(c, w.surface);
                c.setData(w.fractional.?, tag);
            }
        }
        const title_src = truncateUtf8(options.title, w.title_buf.len);
        @memcpy(w.title_buf[0..title_src.len], title_src);
        w.title_len = title_src.len;
        const id_src = truncateUtf8(options.app_id orelse app.appId(), w.app_id_buf.len);
        @memcpy(w.app_id_buf[0..id_src.len], id_src);
        w.app_id_len = id_src.len;
        w.decorations = options.decorations;
        try w.createRole();
        try w.surface.commit(c);
        try c.flush();
        app.windows[slot] = w;

        if (!app.pumpUntil(w, Window.isConfigured, configure_timeout_ns))
            log.warn("no initial configure within 2s; continuing with the requested size", .{});
        return w;
    }

    // -- dispatch ------------------------------------------------------------------------------

    /// Handles one message (also used as the roundtrip handler).
    pub fn handle(app: *App, m: *wire.Message) !void {
        const c = app.conn;
        switch (m.iface) {
            .wl_registry => switch (try m.decode(proto.WlRegistry)) {
                .global => |g| try app.onGlobal(g.name, g.interface, g.version),
                .global_remove => |g| app.onGlobalRemove(g.name),
            },
            .wl_callback => switch (try m.decode(proto.WlCallback)) {
                .done => if (app.windowFromData(m.data)) |w| {
                    if (w.frame_cb != null and @intFromEnum(w.frame_cb.?) == m.object) {
                        w.frame_cb = null;
                        app.push(.{ .frame = .{ .window = w.id } });
                    }
                },
            },
            .xdg_wm_base => switch (try m.decode(proto.XdgWmBase)) {
                .ping => |p| try app.g.wm_base.?.pong(c, p.serial),
            },
            .xdg_surface => switch (try m.decode(proto.XdgSurface)) {
                .configure => |cfg| if (app.windowFromData(m.data)) |w| try w.onConfigure(cfg.serial),
            },
            .xdg_toplevel => {
                const w = app.windowFromData(m.data) orelse return;
                switch (try m.decode(proto.XdgToplevel)) {
                    .configure => |cfg| {
                        w.pending_width = cfg.width;
                        w.pending_height = cfg.height;
                        var st: WindowStates = .{};
                        for (cfg.states.u32s()) |s| switch (@as(proto.XdgToplevel.State, @enumFromInt(s))) {
                            .maximized => st.maximized = true,
                            .fullscreen => st.fullscreen = true,
                            .activated => st.activated = true,
                            .resizing => st.resizing = true,
                            .tiled_left, .tiled_right, .tiled_top, .tiled_bottom => st.tiled = true,
                            .suspended => st.suspended = true,
                            else => {},
                        };
                        w.pending_states = st;
                    },
                    .close => app.push(.{ .close_requested = .{ .window = w.id } }),
                    .configure_bounds => |b| {
                        w.bounds = .{ b.width, b.height };
                    },
                    .wm_capabilities => |caps| {
                        var wc: WmCapabilities = .{ .window_menu = false, .maximize = false, .fullscreen = false, .minimize = false };
                        for (caps.capabilities.u32s()) |s| switch (@as(proto.XdgToplevel.WmCapabilities, @enumFromInt(s))) {
                            .window_menu => wc.window_menu = true,
                            .maximize => wc.maximize = true,
                            .fullscreen => wc.fullscreen = true,
                            .minimize => wc.minimize = true,
                            else => {},
                        };
                        w.wm_capabilities = wc;
                    },
                }
            },
            .zxdg_toplevel_decoration_v1 => switch (try m.decode(proto.ZxdgToplevelDecorationV1)) {
                .configure => |d| if (app.windowFromData(m.data)) |w| {
                    w.server_decorations = d.mode == .server_side;
                },
            },
            .wl_surface => {
                const w = app.windowFromData(m.data) orelse return;
                switch (try m.decode(proto.WlSurface)) {
                    .enter => |e| if (app.outputSlot(e.output)) |i| {
                        w.outputs |= @as(u32, 1) << @intCast(i);
                        _ = w.updateSize();
                    },
                    .leave => |e| if (app.outputSlot(e.output)) |i| {
                        w.outputs &= ~(@as(u32, 1) << @intCast(i));
                        _ = w.updateSize();
                    },
                    .preferred_buffer_scale => |s| {
                        // fractional-scale-v1 supersedes the integer hint when present.
                        if (w.fractional != null) return;
                        w.buffer_scale = s.factor;
                        _ = w.updateSize();
                    },
                    .preferred_buffer_transform => {},
                }
            },
            .wp_fractional_scale_v1 => switch (try m.decode(proto.WpFractionalScaleV1)) {
                .preferred_scale => |s| if (app.windowFromData(m.data)) |w| {
                    w.scale120 = s.scale;
                    _ = w.updateSize();
                },
            },
            .wl_output => {
                if (m.data == 0 or m.data > max_outputs) return;
                const o = &app.outputs[m.data - 1];
                switch (try m.decode(proto.WlOutput)) {
                    .scale => |s| o.pending_scale = s.factor,
                    .mode => |md| if (md.flags & proto.WlOutput.Mode.current != 0) {
                        o.mode = .{ md.width, md.height };
                    },
                    .done => if (o.scale != o.pending_scale) {
                        o.scale = o.pending_scale;
                        for (app.windows) |win| if (win) |w| {
                            _ = w.updateSize();
                        };
                    },
                    else => {},
                }
            },
            .wl_buffer => switch (try m.decode(proto.WlBuffer)) {
                .release => if (m.data > 0 and m.data <= max_buffers) {
                    app.buffers[m.data - 1].busy = false;
                },
            },
            .wl_seat => switch (try m.decode(proto.WlSeat)) {
                .capabilities => |caps| try app.onSeatCapabilities(caps.capabilities),
                .name => {},
            },
            .wl_pointer => try app.onPointer(try m.decode(proto.WlPointer)),
            .wl_keyboard => try app.onKeyboard(try m.decode(proto.WlKeyboard)),
            .zwp_text_input_v3 => try app.onTextInput(try m.decode(proto.ZwpTextInputV3)),
            .wl_data_device => switch (try m.decode(proto.WlDataDevice)) {
                .data_offer => |o| app.clipboard.onDataOffer(c, @intFromEnum(o.id)),
                .selection => |s| {
                    app.clipboard.onSelection(c, if (s.id) |id| @intFromEnum(id) else null);
                    app.push(.{ .clipboard_update = .{ .window = app.windowId(app.kb_focus) } });
                },
                // Drag and drop is not supported: drop the offers we are given.
                .enter => |e| if (e.id) |id| {
                    app.dnd_offer = @intFromEnum(id);
                },
                .leave, .drop => if (app.dnd_offer != 0) {
                    app.clipboard.dropOffer(c, app.dnd_offer);
                    app.dnd_offer = 0;
                },
                .motion => {},
            },
            .wl_data_offer => switch (try m.decode(proto.WlDataOffer)) {
                .offer => |o| app.clipboard.onOfferMime(m.object, o.mime_type),
                else => {},
            },
            .wl_data_source => switch (try m.decode(proto.WlDataSource)) {
                .send => |s| app.clipboard.onSend(app.gpa, m.object, s.mime_type, @intFromEnum(s.fd)),
                .cancelled => app.clipboard.onCancelled(c, app.gpa, m.object),
                else => {},
            },
            .zwp_primary_selection_device_v1 => switch (try m.decode(proto.ZwpPrimarySelectionDeviceV1)) {
                .data_offer => |o| app.primary.onDataOffer(c, @intFromEnum(o.offer)),
                .selection => |s| app.primary.onSelection(c, if (s.id) |id| @intFromEnum(id) else null),
            },
            .zwp_primary_selection_offer_v1 => switch (try m.decode(proto.ZwpPrimarySelectionOfferV1)) {
                .offer => |o| app.primary.onOfferMime(m.object, o.mime_type),
            },
            .zwp_primary_selection_source_v1 => switch (try m.decode(proto.ZwpPrimarySelectionSourceV1)) {
                .send => |s| app.primary.onSend(app.gpa, m.object, s.mime_type, @intFromEnum(s.fd)),
                .cancelled => app.primary.onCancelled(c, app.gpa, m.object),
            },
            .zwp_linux_dmabuf_v1 => switch (try m.decode(proto.ZwpLinuxDmabufV1)) {
                .format => |f| if (c.objectVersion(app.g.dmabuf.?) < 3) {
                    try app.addFormat(&app.dmabuf_formats, f.format, contract.modifier_invalid);
                },
                .modifier => |f| try app.addFormat(&app.dmabuf_formats, f.format, (@as(u64, f.modifier_hi) << 32) | f.modifier_lo),
            },
            .zwp_linux_dmabuf_feedback_v1 => try app.onFeedback(try m.decode(proto.ZwpLinuxDmabufFeedbackV1)),
            .zwp_linux_buffer_params_v1 => switch (try m.decode(proto.ZwpLinuxBufferParamsV1)) {
                .failed => app.params_failed = true,
                .created => {},
            },
            .xdg_activation_token_v1 => switch (try m.decode(proto.XdgActivationTokenV1)) {
                .done => |d| {
                    if (app.windowFromData(m.data)) |w| if (app.g.activation) |act| {
                        try act.activate(c, d.token, w.surface);
                    };
                    try (@as(proto.XdgActivationTokenV1, @enumFromInt(m.object))).destroy(c);
                },
            },
            else => {},
        }
    }

    fn onGlobal(app: *App, name: u32, iface: []const u8, version: u32) !void {
        const c = app.conn;
        const dup = try app.global_names.allocator().dupe(u8, iface);
        try app.global_list.append(app.gpa, .{ .name = name, .interface = dup, .version = version });
        inline for (bindings) |b| {
            if (std.mem.eql(u8, iface, b[1].interface_name)) {
                if (@field(app.g, b[0]) == null)
                    @field(app.g, b[0]) = try app.registry.bind(c, name, b[1], @min(version, b[2]));
                return;
            }
        }
        if (std.mem.eql(u8, iface, proto.WlSeat.interface_name)) {
            if (app.seat != null) return; // single-seat
            app.seat = try app.registry.bind(c, name, proto.WlSeat, @min(version, seat_max_version));
            app.seat_global = name;
            // Late seat (after init): create the per-seat devices now.
            if (app.g.compositor != null and app.g.wm_base != null) try app.setupSeatDevices();
        } else if (std.mem.eql(u8, iface, proto.WlOutput.interface_name)) {
            for (&app.outputs, 0..) |*o, i| if (!o.live) {
                o.* = .{ .global = name, .live = true, .obj = try app.registry.bind(c, name, proto.WlOutput, @min(version, output_max_version)) };
                c.setData(o.obj, @intCast(i + 1));
                return;
            };
        }
    }

    fn onGlobalRemove(app: *App, name: u32) void {
        for (&app.outputs, 0..) |*o, i| if (o.live and o.global == name) {
            if (app.conn.objectVersion(o.obj) >= 3) o.obj.release(app.conn) catch {};
            o.live = false;
            for (app.windows) |win| if (win) |w| {
                w.outputs &= ~(@as(u32, 1) << @intCast(i));
                _ = w.updateSize();
            };
        };
    }

    fn outputSlot(app: *App, output: proto.WlOutput) ?usize {
        const o = app.conn.lookup(@intFromEnum(output)) orelse return null;
        if (o.iface != .wl_output or o.data == 0) return null;
        return o.data - 1;
    }

    // -- seat ---------------------------------------------------------------------------------

    fn onSeatCapabilities(app: *App, caps: u32) !void {
        const c = app.conn;
        const seat = app.seat orelse return;
        if (caps & proto.WlSeat.Capability.pointer != 0) {
            if (app.pointer == null) {
                app.pointer = try seat.getPointer(c);
                if (app.g.cursor_shape_mgr) |m| app.cursor_device = try m.getPointer(c, app.pointer.?);
            }
        } else app.releasePointer();
        if (caps & proto.WlSeat.Capability.keyboard != 0) {
            if (app.keyboard == null) app.keyboard = try seat.getKeyboard(c);
        } else app.releaseKeyboard();
    }

    fn releasePointer(app: *App) void {
        const c = app.conn;
        if (app.cursor_device) |d| d.destroy(c) catch {};
        app.cursor_device = null;
        if (app.pointer) |p| if (c.objectVersion(p) >= 3) p.release(c) catch {};
        app.pointer = null;
        app.ptr_focus = 0;
    }

    fn releaseKeyboard(app: *App) void {
        const c = app.conn;
        if (app.keyboard) |k| if (c.objectVersion(k) >= 3) k.release(c) catch {};
        app.keyboard = null;
        app.kb_focus = 0;
        app.disarmRepeat();
    }

    // -- pointer ------------------------------------------------------------------------------

    fn onPointer(app: *App, e: proto.WlPointer.Event) !void {
        const f = &app.ptr_frame;
        switch (e) {
            .enter => |p| {
                const w = app.windowFromSurface(p.surface) orelse return;
                app.ptr_focus = w.slot + 1;
                app.ptr_enter_serial = p.serial;
                app.ptr_x = @floatCast(p.surface_x.toFloat());
                app.ptr_y = @floatCast(p.surface_y.toFloat());
                app.last_motion_x = app.ptr_x;
                app.last_motion_y = app.ptr_y;
                f.enter = true;
                app.applyCursor(w);
            },
            .leave => {
                // Flush what belongs to the window being left, then report the leave
                // immediately so a following enter (same frame) is ordered after it.
                app.flushPointerFrame();
                if (app.windowFromData(app.ptr_focus)) |w| app.push(.{ .mouse_leave = .{ .window = w.id } });
                app.ptr_focus = 0;
            },
            .motion => |p| {
                app.ptr_x = @floatCast(p.surface_x.toFloat());
                app.ptr_y = @floatCast(p.surface_y.toFloat());
                f.motion = true;
            },
            .button => |b| {
                const down = b.state == .pressed;
                if (down) app.last_serial = b.serial;
                f.addButton(.{ .button = input.mapButton(b.button), .down = down, .time = b.time });
            },
            .axis => |a| f.scroll.addValue(@intFromEnum(a.axis), a.value.toFloat()),
            .axis_source => |s| f.scroll.source = @enumFromInt(@intFromEnum(s.axis_source)),
            .axis_discrete => |a| f.scroll.addDiscrete(@intFromEnum(a.axis), a.discrete),
            .axis_value120 => |a| f.scroll.addValue120(@intFromEnum(a.axis), a.value120),
            .frame => app.flushPointerFrame(),
            .axis_stop, .axis_relative_direction, .warp => {},
        }
        // Pre-v5 pointers have no frame event: every event is its own frame.
        if (app.pointer) |p| if (app.conn.objectVersion(p) < 5) app.flushPointerFrame();
    }

    fn flushPointerFrame(app: *App) void {
        const f = &app.ptr_frame;
        defer f.* = .{};
        const w = app.windowFromData(app.ptr_focus) orelse return;
        const x = app.ptr_x;
        const y = app.ptr_y;
        if (f.enter) app.push(.{ .mouse_enter = .{ .window = w.id, .x = x, .y = y, .state = app.ptr_buttons } });
        if (f.motion) {
            app.push(.{ .mouse_motion = .{
                .window = w.id,
                .x = x,
                .y = y,
                .xrel = x - app.last_motion_x,
                .yrel = y - app.last_motion_y,
                .state = app.ptr_buttons,
            } });
            app.last_motion_x = x;
            app.last_motion_y = y;
        }
        for (f.buttons[0..f.button_count]) |b| {
            input.setButton(&app.ptr_buttons, b.button, b.down);
            const clicks = if (b.down) app.clicks.press(b.button, b.time, x, y) else app.clicks.current();
            const be: ev.ButtonEvent = .{ .window = w.id, .x = x, .y = y, .button = b.button, .clicks = clicks, .down = b.down };
            app.push(if (b.down) .{ .mouse_button_down = be } else .{ .mouse_button_up = be });
        }
        if (f.scroll.any) {
            const l = f.scroll.lines();
            if (l.x != 0 or l.y != 0)
                app.push(.{ .mouse_wheel = .{ .window = w.id, .x = l.x, .y = l.y, .precise = l.precise, .mouse_x = x, .mouse_y = y } });
        }
    }

    fn applyCursor(app: *App, w: *Window) void {
        const c = app.conn;
        const p = app.pointer orelse return;
        if (w.cursor == .hidden) {
            p.setCursor(c, app.ptr_enter_serial, null, 0, 0) catch {};
        } else if (app.cursor_device) |d| {
            d.setShape(c, app.ptr_enter_serial, w.cursor.protocolShape()) catch {};
        }
        // Without wp_cursor_shape we would need to load an Xcursor theme; not implemented,
        // so the compositor's current cursor stays.
    }

    // -- keyboard -----------------------------------------------------------------------------

    fn onKeyboard(app: *App, e: proto.WlKeyboard.Event) !void {
        switch (e) {
            .keymap => |k| {
                const fd: i32 = @intFromEnum(k.fd);
                defer _ = linux.close(fd);
                if (k.format != .xkb_v1 or k.size == 0) return;
                const rc = linux.mmap(null, k.size, .{ .READ = true }, .{ .TYPE = .PRIVATE }, fd, 0);
                if (linux.errno(rc) != .SUCCESS) {
                    log.warn("keymap mmap failed", .{});
                    return;
                }
                const ptr: [*]const u8 = @ptrFromInt(rc);
                defer _ = linux.munmap(ptr, k.size);
                const text = std.mem.sliceTo(ptr[0..k.size], 0);
                const km = xkb.parse(app.gpa, text) catch |err| {
                    log.warn("keymap parse failed: {s}", .{@errorName(err)});
                    return;
                };
                if (app.keymap) |*old| old.deinit();
                app.keymap = km;
                app.updateMods();
            },
            .enter => |k| {
                const w = app.windowFromSurface(k.surface) orelse return;
                app.kb_focus = w.slot + 1;
                app.last_serial = k.serial;
                app.mod_keys = .{};
                for (k.keys.u32s()) |code| app.mod_keys.set(code, true);
                app.push(.{ .focus_gained = .{ .window = w.id } });
            },
            .leave => {
                app.disarmRepeat();
                app.mod_keys = .{};
                if (app.windowFromData(app.kb_focus)) |w| app.push(.{ .focus_lost = .{ .window = w.id } });
                app.kb_focus = 0;
            },
            .key => |k| {
                const w = app.windowFromData(app.kb_focus) orelse return;
                const down = k.state != .released;
                if (down) app.last_serial = k.serial;
                app.mod_keys.set(k.key, down);
                app.emitKey(w, k.key, down, k.state == .repeated);
                const code = k.key + 8;
                if (down and k.state != .repeated) {
                    const repeats = if (app.keymap) |*km| km.keyRepeats(code) else true;
                    if (repeats and app.repeat_rate > 0) app.armRepeat(code) else if (app.repeat_key != 0) app.disarmRepeat();
                } else if (!down and app.repeat_key == code) app.disarmRepeat();
            },
            .modifiers => |mo| {
                app.xkb_state = .{ .depressed = mo.mods_depressed, .latched = mo.mods_latched, .locked = mo.mods_locked, .group = mo.group };
                app.updateMods();
            },
            .repeat_info => |r| {
                app.repeat_rate = r.rate;
                app.repeat_delay = r.delay;
                if (r.rate <= 0) app.disarmRepeat();
            },
        }
    }

    fn updateMods(app: *App) void {
        const km = if (app.keymap) |*k| k else return;
        const s = app.xkb_state;
        const eff = km.canonical(s.depressed | s.latched | s.locked);
        const locked = km.canonical(s.locked);
        app.mods = .{
            .shift = eff & xkb.mod_shift != 0,
            .ctrl = eff & xkb.mod_control != 0,
            .alt = eff & km.alt_mask != 0,
            .super = eff & km.super_mask != 0,
            .caps_lock = locked & xkb.mod_lock != 0,
            .num_lock = locked & km.num_lock_mask != 0,
        };
    }

    fn emitKey(app: *App, w: *Window, evdev: u32, down: bool, repeat: bool) void {
        var k: ev.KeyEvent = .{ .window = w.id, .key = .unknown, .scancode = evdev, .mod = app.mods, .mod_keys = app.mod_keys, .down = down, .repeat = repeat };
        if (app.keymap) |*km| {
            const l = km.lookup(evdev + 8, app.xkb_state);
            k.keysym = l.sym;
            k.codepoint = keysym.toUnicode(l.sym);
            k.base_codepoint = keysym.toUnicode(l.base_sym);
            k.key = if (keysym.isKeypad(l.sym)) keysym.toKeycode(l.sym) else resolveKeycode(km, evdev, l.base_sym);
        } else k.key = keysym.keycodeFromScancode(evdev);
        app.push(if (down) .{ .key_down = k } else .{ .key_up = k });

        const cp = k.codepoint;
        if (!down or cp < 0x20 or cp == 0x7f or (cp >= 0x80 and cp < 0xa0)) return;
        if (app.mods.ctrl or app.mods.alt or app.mods.super or app.preedit_active) return;
        // SDL semantics: no text events unless the window started text input.
        if (!w.ti_enabled) return;
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &buf) catch return;
        if (app.storeText(buf[0..n])) |t| app.push(.{ .text_input = .{ .window = w.id, .text = t } });
    }

    fn armRepeat(app: *App, code: u32) void {
        app.repeat_key = code;
        const delay_ns: u64 = @as(u64, @intCast(@max(app.repeat_delay, 1))) * std.time.ns_per_ms;
        const interval_ns: u64 = std.time.ns_per_s / @as(u64, @intCast(@max(app.repeat_rate, 1)));
        const spec: linux.itimerspec = .{
            .it_value = .{ .sec = @intCast(delay_ns / std.time.ns_per_s), .nsec = @intCast(delay_ns % std.time.ns_per_s) },
            .it_interval = .{ .sec = @intCast(interval_ns / std.time.ns_per_s), .nsec = @intCast(interval_ns % std.time.ns_per_s) },
        };
        _ = linux.timerfd_settime(app.repeat_fd, .{}, &spec, null);
    }

    fn disarmRepeat(app: *App) void {
        if (app.repeat_key == 0) return;
        app.repeat_key = 0;
        const zero: linux.itimerspec = .{ .it_value = .{ .sec = 0, .nsec = 0 }, .it_interval = .{ .sec = 0, .nsec = 0 } };
        _ = linux.timerfd_settime(app.repeat_fd, .{}, &zero, null);
    }

    fn repeatTick(app: *App) void {
        var count: u64 = 0;
        const rc = linux.read(app.repeat_fd, std.mem.asBytes(&count), 8);
        if (linux.errno(rc) != .SUCCESS) return;
        if (app.repeat_key == 0) return;
        const w = app.windowFromData(app.kb_focus) orelse return app.disarmRepeat();
        var i: u64 = 0;
        while (i < @min(count, max_repeats_per_tick)) : (i += 1) app.emitKey(w, app.repeat_key - 8, true, true);
    }

    // -- text input ---------------------------------------------------------------------------

    fn onTextInput(app: *App, e: proto.ZwpTextInputV3.Event) !void {
        switch (e) {
            .enter => |t| {
                const w = app.windowFromSurface(t.surface) orelse return;
                app.ti_focus = w.slot + 1;
                if (w.ti_enabled) try app.tiEnable(w);
            },
            .leave => {
                if (app.text_input) |ti| if (app.windowFromData(app.ti_focus)) |w| if (w.ti_enabled) {
                    try ti.disable(app.conn);
                    try app.tiCommit();
                };
                app.endPreedit();
                app.ti_focus = 0;
            },
            .preedit_string => |p| {
                const s = p.text orelse "";
                app.ti_preedit_len = truncateUtf8(s, app.ti_preedit.len).len;
                @memcpy(app.ti_preedit[0..app.ti_preedit_len], s[0..app.ti_preedit_len]);
                app.ti_preedit_cursor = .{ p.cursor_begin, p.cursor_end };
                app.ti_has_preedit = true;
            },
            .commit_string => |p| {
                const s = p.text orelse "";
                app.ti_commit_len = truncateUtf8(s, app.ti_commit.len).len;
                @memcpy(app.ti_commit[0..app.ti_commit_len], s[0..app.ti_commit_len]);
                app.ti_has_commit = true;
            },
            .done => {
                // Apply in protocol order: drop old preedit, insert commit, show new preedit.
                const w = app.windowFromData(app.ti_focus);
                const id: ev.WindowId = if (w) |x| x.id else .invalid;
                const new_preedit = app.ti_has_preedit and app.ti_preedit_len > 0;
                if (app.preedit_active) {
                    app.push(.{ .text_editing = .{ .window = id, .text = "" } });
                    app.preedit_active = false;
                }
                if (app.ti_has_commit and app.ti_commit_len > 0) {
                    if (app.storeText(app.ti_commit[0..app.ti_commit_len])) |t| app.push(.{ .text_input = .{ .window = id, .text = t } });
                }
                if (new_preedit) {
                    if (app.storeText(app.ti_preedit[0..app.ti_preedit_len])) |t| {
                        app.push(.{ .text_editing = .{ .window = id, .text = t, .cursor_begin = app.ti_preedit_cursor[0], .cursor_end = app.ti_preedit_cursor[1] } });
                        app.preedit_active = true;
                    }
                }
                app.ti_has_preedit = false;
                app.ti_has_commit = false;
                app.ti_preedit_len = 0;
                app.ti_commit_len = 0;
            },
            .delete_surrounding_text, .action, .language, .preedit_hint => {},
        }
    }

    fn endPreedit(app: *App) void {
        if (!app.preedit_active) return;
        app.preedit_active = false;
        app.push(.{ .text_editing = .{ .window = app.windowId(app.ti_focus), .text = "" } });
    }

    fn tiEnable(app: *App, w: *Window) !void {
        const ti = app.text_input orelse return;
        const c = app.conn;
        try ti.enable(c);
        try ti.setContentType(c, proto.ZwpTextInputV3.ContentHint.none, .normal);
        try app.tiSendRect(w);
        try app.tiCommit();
    }

    fn tiSendRect(app: *App, w: *Window) !void {
        const ti = app.text_input orelse return;
        const r = w.ti_rect;
        try ti.setCursorRectangle(app.conn, @intFromFloat(@round(r.x)), @intFromFloat(@round(r.y)), @intFromFloat(@max(1, @round(r.w))), @intFromFloat(@max(1, @round(r.h))));
    }

    fn tiCommit(app: *App) !void {
        const ti = app.text_input orelse return;
        try ti.commit(app.conn);
        app.ti_commits +%= 1;
        _ = app.conn.trySend() catch {};
    }

    // -- dmabuf -------------------------------------------------------------------------------

    fn addFormat(app: *App, list: *std.ArrayList(contract.FormatModifier), format: u32, modifier: u64) !void {
        const fm: contract.FormatModifier = .{ .format = @enumFromInt(format), .modifier = modifier };
        for (list.items) |x| if (x.format == fm.format and x.modifier == fm.modifier) return;
        try list.append(app.gpa, fm);
    }

    fn onFeedback(app: *App, e: proto.ZwpLinuxDmabufFeedbackV1.Event) !void {
        switch (e) {
            .format_table => |t| {
                const fd: i32 = @intFromEnum(t.fd);
                defer _ = linux.close(fd);
                if (app.format_table) |old| _ = linux.munmap(old.ptr, old.len);
                app.format_table = null;
                if (t.size == 0) return;
                const rc = linux.mmap(null, t.size, .{ .READ = true }, .{ .TYPE = .PRIVATE }, fd, 0);
                if (linux.errno(rc) != .SUCCESS) return;
                const ptr: [*]align(std.heap.page_size_min) const u8 = @ptrFromInt(rc);
                app.format_table = ptr[0..t.size];
            },
            .main_device => |d| {
                if (d.device.data.len >= 8) app.dmabuf_main_device = std.mem.readInt(u64, d.device.data[0..8], builtin.cpu.arch.endian());
            },
            .tranche_formats => |t| {
                const table = app.format_table orelse return;
                const idx = std.mem.bytesAsSlice(u16, t.indices.data[0 .. t.indices.data.len / 2 * 2]);
                for (idx) |i_| {
                    const i: usize = i_;
                    if ((i + 1) * 16 > table.len) continue;
                    const entry = table[i * 16 ..][0..16];
                    const format = std.mem.readInt(u32, entry[0..4], builtin.cpu.arch.endian());
                    const modifier = std.mem.readInt(u64, entry[8..16], builtin.cpu.arch.endian());
                    try app.addFormat(&app.dmabuf_pending, format, modifier);
                }
            },
            .done => {
                app.dmabuf_formats.clearRetainingCapacity();
                try app.dmabuf_formats.appendSlice(app.gpa, app.dmabuf_pending.items);
                app.dmabuf_pending.clearRetainingCapacity();
            },
            .tranche_target_device, .tranche_flags, .tranche_done => {},
        }
    }

    fn allocBuffer(app: *App, wl: proto.WlBuffer, window: u32, width: i32, height: i32) !contract.BufferId {
        for (&app.buffers, 0..) |*b, i| if (!b.live) {
            b.* = .{ .wl = wl, .window = window, .width = width, .height = height, .live = true };
            app.conn.setData(wl, @intCast(i + 1));
            return @enumFromInt(@as(u32, @intCast(i + 1)));
        };
        wl.destroy(app.conn) catch {};
        return error.TooManyBuffers;
    }

    fn bufferSlot(app: *App, id: contract.BufferId) ?*BufferSlot {
        const i = @intFromEnum(id);
        if (i == 0 or i > max_buffers) return null;
        const b = &app.buffers[i - 1];
        return if (b.live) b else null;
    }
};

pub const Window = struct {
    app: *App,
    slot: u32,
    id: ev.WindowId,
    surface: proto.WlSurface,
    xdg_surface: proto.XdgSurface,
    toplevel: proto.XdgToplevel,
    viewport: ?proto.WpViewport = null,
    fractional: ?proto.WpFractionalScaleV1 = null,
    decoration: ?proto.ZxdgToplevelDecorationV1 = null,

    /// Current logical size.
    width: i32,
    height: i32,
    /// Size used when the compositor lets us choose (configure 0x0).
    req_width: i32,
    req_height: i32,
    min_width: i32,
    min_height: i32,
    resizable: bool,
    pending_width: i32 = 0,
    pending_height: i32 = 0,
    pending_states: WindowStates = .{},
    states: WindowStates = .{},
    bounds: [2]i32 = .{ 0, 0 },
    wm_capabilities: WmCapabilities = .{},
    server_decorations: bool = false,
    configured: bool = false,
    has_buffer: bool = false,

    scale120: u32 = 0,
    buffer_scale: i32 = 0,
    outputs: u32 = 0,
    emitted: ev.ResizeEvent = .{ .width = 0, .height = 0, .pixel_width = 0, .pixel_height = 0, .scale = 0 },
    applied_dest: [2]i32 = .{ 0, 0 },
    applied_buffer_scale: i32 = 1,

    frame_cb: ?proto.WlCallback = null,
    frame_committed: bool = true,
    cursor: CursorShape = .default,
    ti_enabled: bool = false,
    ti_rect: Rect = .{},
    /// False between `hide()` and `show()` (the surface is unmapped).
    visible: bool = true,
    /// Set by `show()` until the compositor's next configure (no buffer may be attached).
    remap_pending: bool = false,
    /// xdg_surface/xdg_toplevel exist (false between `hide()` and `show()`).
    role_live: bool = true,
    decorations: Decorations = .server,
    title_buf: [1024]u8 = undefined,
    title_len: usize = 0,
    app_id_buf: [512]u8 = undefined,
    app_id_len: usize = 0,

    fn isConfigured(w: *Window) bool {
        return w.configured;
    }

    fn isRemapped(w: *Window) bool {
        return !w.remap_pending;
    }

    /// Creates the xdg_surface/xdg_toplevel (and decoration) role objects from the stored
    /// title, app_id, size limits and decoration mode. Does not commit.
    fn createRole(w: *Window) !void {
        const app = w.app;
        const c = app.conn;
        const tag = w.slot + 1;
        w.xdg_surface = try app.g.wm_base.?.getXdgSurface(c, w.surface);
        c.setData(w.xdg_surface, tag);
        w.toplevel = try w.xdg_surface.getToplevel(c);
        c.setData(w.toplevel, tag);
        try w.toplevel.setTitle(c, w.title_buf[0..w.title_len]);
        try w.toplevel.setAppId(c, w.app_id_buf[0..w.app_id_len]);
        if (w.resizable) {
            if (w.min_width > 0 or w.min_height > 0) try w.toplevel.setMinSize(c, w.min_width, w.min_height);
        } else {
            try w.toplevel.setMinSize(c, w.req_width, w.req_height);
            try w.toplevel.setMaxSize(c, w.req_width, w.req_height);
        }
        if (app.g.decoration_mgr) |dm| {
            const d = try dm.getToplevelDecoration(c, w.toplevel);
            c.setData(d, tag);
            try d.setMode(c, switch (w.decorations) {
                .server => .server_side,
                .client => .client_side,
            });
            w.decoration = d;
        }
    }

    /// Destroys the role objects; late events addressed to them are ignored (data 0).
    fn destroyRole(w: *Window) void {
        const c = w.app.conn;
        if (w.decoration) |d| {
            c.setData(d, 0);
            d.destroy(c) catch {};
            w.decoration = null;
        }
        c.setData(w.toplevel, 0);
        c.setData(w.xdg_surface, 0);
        w.toplevel.destroy(c) catch {};
        w.xdg_surface.destroy(c) catch {};
    }

    /// Unmaps the window (null buffer commit, xdg_toplevel destroyed like SDL does) and emits
    /// `window_hidden`. The wl_surface, buffers and window id stay, so `show()` maps it again
    /// with a new toplevel. `present` is a no-op while hidden.
    pub fn hide(w: *Window) void {
        if (!w.visible) return;
        const app = w.app;
        const c = app.conn;
        w.visible = false;
        if (w.ti_enabled and app.ti_focus == w.slot + 1) {
            if (app.text_input) |ti| ti.disable(c) catch {};
            app.tiCommit() catch {};
            app.endPreedit();
        }
        if (w.frame_cb) |cb| {
            // An unmapped surface gets no frame callbacks; release the pacing wait now.
            c.setData(cb, 0);
            w.frame_cb = null;
            w.frame_committed = true;
            app.push(.{ .frame = .{ .window = w.id } });
        }
        w.surface.attach(c, null, 0, 0) catch {};
        w.surface.commit(c) catch {};
        w.has_buffer = false;
        // Like SDL, drop the role objects: some compositors (Hyprland 0.56) never send a new
        // configure to a re-committed unmapped xdg_surface, so `show()` builds fresh ones.
        w.destroyRole();
        w.role_live = false;
        c.flush() catch {};
        app.push(.{ .window_hidden = .{ .window = w.id, .reason = .unmapped } });
    }

    /// Re-maps a hidden window: creates a new xdg_toplevel (same title/app_id), commits
    /// without a buffer, waits (up to 1 s) for the compositor's configure, then emits
    /// `window_shown`. The host must redraw (a
    /// `WindowRenderer` forces a full repaint on `window_shown`).
    pub fn show(w: *Window) void {
        if (w.visible) return;
        const app = w.app;
        w.visible = true;
        // A buffer may only be attached after the new role's first configure.
        w.remap_pending = true;
        w.createRole() catch |err| log.warn("show(): recreating xdg_toplevel failed: {s}", .{@errorName(err)});
        w.role_live = true;
        w.surface.commit(app.conn) catch {};
        app.conn.flush() catch {};
        if (!app.pumpUntil(w, Window.isRemapped, std.time.ns_per_s))
            log.warn("no configure within 1s after show()", .{});
        if (w.ti_enabled and app.ti_focus == w.slot + 1) app.tiEnable(w) catch {};
        app.push(.{ .window_shown = .{ .window = w.id, .reason = .unmapped } });
    }

    /// Mapped (between `show`/`hide`) — says nothing about occlusion; see `isSuspended`.
    pub fn isVisible(w: *const Window) bool {
        return w.visible;
    }

    /// The compositor reported xdg_toplevel.suspended (not visible to the user).
    pub fn isSuspended(w: *const Window) bool {
        return w.states.suspended;
    }

    pub fn isTextInputActive(w: *const Window) bool {
        return w.ti_enabled;
    }

    pub fn hasPointerFocus(w: *const Window) bool {
        return w.app.ptr_focus == w.slot + 1;
    }

    pub fn hasKeyboardFocus(w: *const Window) bool {
        return w.app.kb_focus == w.slot + 1;
    }

    /// Largest size the compositor suggests for this window (xdg_toplevel.configure_bounds,
    /// logical px), or null when not sent.
    pub fn configureBounds(w: *const Window) ?Size {
        if (w.bounds[0] <= 0 or w.bounds[1] <= 0) return null;
        return .{ .width = @intCast(w.bounds[0]), .height = @intCast(w.bounds[1]) };
    }

    /// Wayland clients cannot read or set their global position; always 0,0.
    pub fn position(w: *const Window) [2]i32 {
        _ = w;
        return .{ 0, 0 };
    }

    /// No-op on Wayland: xdg-shell has no client-initiated resize of a configured toplevel
    /// (the compositor sizes windows). Kept so hosts need no platform switch.
    pub fn setSize(w: *Window, width: u32, height: u32) void {
        _ = w;
        _ = width;
        _ = height;
    }

    /// No-op on Wayland (the compositor places windows). Kept so hosts need no platform
    /// switch.
    pub fn setPosition(w: *Window, x: i32, y: i32) void {
        _ = w;
        _ = x;
        _ = y;
    }

    pub fn destroy(w: *Window) void {
        const app = w.app;
        const c = app.conn;
        const tag = w.slot + 1;
        if (app.ptr_focus == tag) app.ptr_focus = 0;
        if (app.kb_focus == tag) {
            app.kb_focus = 0;
            app.disarmRepeat();
        }
        if (app.ti_focus == tag) app.ti_focus = 0;
        for (&app.buffers) |*b| if (b.live and b.window == tag) {
            b.wl.destroy(c) catch {};
            b.live = false;
        };
        if (w.frame_cb) |cb| c.setData(cb, 0);
        if (w.fractional) |f| f.destroy(c) catch {};
        if (w.viewport) |v| v.destroy(c) catch {};
        if (w.role_live) w.destroyRole();
        w.surface.destroy(c) catch {};
        c.flush() catch {};
        app.windows[w.slot] = null;
        app.gpa.destroy(w);
    }

    fn onConfigure(w: *Window, serial: u32) !void {
        const app = w.app;
        var nw = w.pending_width;
        var nh = w.pending_height;
        if (nw <= 0) nw = w.req_width;
        if (nh <= 0) nh = w.req_height;
        if (!w.resizable and !w.pending_states.maximized and !w.pending_states.fullscreen and !w.pending_states.tiled) {
            nw = w.req_width;
            nh = w.req_height;
        }
        nw = @max(nw, @max(w.min_width, 1));
        nh = @max(nh, @max(w.min_height, 1));
        const old_states = w.states;
        w.states = w.pending_states;
        w.width = nw;
        w.height = nh;
        try w.xdg_surface.ackConfigure(app.conn, serial);
        w.configured = true;
        w.remap_pending = false;
        // Without a keyboard, xdg "activated" is the only focus signal.
        if (app.keyboard == null and old_states.activated != w.states.activated)
            app.push(if (w.states.activated) .{ .focus_gained = .{ .window = w.id } } else .{ .focus_lost = .{ .window = w.id } });
        // xdg_toplevel.suspended: the compositor will not show the surface (minimized, other
        // workspace, locked). Report it like SDL's hidden/shown so hosts can pause work.
        if (w.visible and old_states.suspended != w.states.suspended)
            app.push(if (w.states.suspended) .{ .window_hidden = .{ .window = w.id, .reason = .suspended } } else .{ .window_shown = .{ .window = w.id, .reason = .suspended } });
        if (!w.updateSize() and w.has_buffer) {
            // Nothing for the app to redraw; commit so the ack takes effect.
            try w.surface.commit(app.conn);
        }
    }

    /// Emits `resized` if logical size, pixel size or scale changed. Returns true if emitted.
    fn updateSize(w: *Window) bool {
        const px = w.pixelSize();
        const s = w.scale();
        const e: ev.ResizeEvent = .{ .window = w.id, .width = w.width, .height = w.height, .pixel_width = @intCast(px.width), .pixel_height = @intCast(px.height), .scale = s };
        if (!w.configured) return false;
        if (e.width == w.emitted.width and e.height == w.emitted.height and e.pixel_width == w.emitted.pixel_width and
            e.pixel_height == w.emitted.pixel_height and e.scale == w.emitted.scale) return false;
        w.emitted = e;
        w.app.push(.{ .resized = e });
        return true;
    }

    pub fn logicalSize(w: *const Window) Size {
        return .{ .width = @intCast(w.width), .height = @intCast(w.height) };
    }

    /// Size of the buffer to render: round(logical * scale) with viewporter, else
    /// logical * integer scale.
    pub fn pixelSize(w: *const Window) Size {
        if (w.viewport != null) {
            const s = w.scale();
            return .{
                .width = @intFromFloat(@max(1, @round(@as(f32, @floatFromInt(w.width)) * s))),
                .height = @intFromFloat(@max(1, @round(@as(f32, @floatFromInt(w.height)) * s))),
            };
        }
        const is: u32 = @intCast(w.intScale());
        return .{ .width = @as(u32, @intCast(w.width)) * is, .height = @as(u32, @intCast(w.height)) * is };
    }

    /// Fractional preferred scale if available, else preferred buffer scale, else the
    /// largest scale of the outputs the surface is on.
    pub fn scale(w: *const Window) f32 {
        if (w.scale120 != 0) return @as(f32, @floatFromInt(w.scale120)) / 120.0;
        // With fractional-scale-v1 the compositor sends preferred_scale on output changes;
        // integer hints would only cause a transient resize to the wrong scale.
        if (w.fractional != null) return 1;
        if (w.buffer_scale > 0) return @floatFromInt(w.buffer_scale);
        var best: i32 = 0;
        for (w.app.outputs, 0..) |o, i| {
            if (o.live and w.outputs & (@as(u32, 1) << @intCast(i)) != 0) best = @max(best, o.scale);
        }
        return @floatFromInt(@max(best, 1));
    }

    fn intScale(w: *const Window) i32 {
        return @max(1, @as(i32, @intFromFloat(@ceil(w.scale()))));
    }

    pub fn setTitle(w: *Window, title: []const u8) void {
        const t = truncateUtf8(title, w.title_buf.len);
        @memcpy(w.title_buf[0..t.len], t);
        w.title_len = t.len;
        if (w.role_live) w.toplevel.setTitle(w.app.conn, t) catch {};
    }

    pub fn setMinSize(w: *Window, width: u32, height: u32) void {
        w.min_width = @intCast(@min(width, 1 << 15));
        w.min_height = @intCast(@min(height, 1 << 15));
        if (w.role_live) w.toplevel.setMinSize(w.app.conn, w.min_width, w.min_height) catch {};
        if (w.has_buffer) w.surface.commit(w.app.conn) catch {};
    }

    pub fn setCursor(w: *Window, shape: CursorShape) void {
        if (w.cursor == shape) return;
        w.cursor = shape;
        if (w.app.ptr_focus == w.slot + 1) w.app.applyCursor(w);
    }

    pub fn setMaximized(w: *Window, on: bool) void {
        if (!w.role_live) return;
        const c = w.app.conn;
        (if (on) w.toplevel.setMaximized(c) else w.toplevel.unsetMaximized(c)) catch {};
    }

    pub fn minimize(w: *Window) void {
        if (!w.role_live) return;
        w.toplevel.setMinimized(w.app.conn) catch {};
    }

    pub fn setFullscreen(w: *Window, on: bool) void {
        if (!w.role_live) return;
        const c = w.app.conn;
        (if (on) w.toplevel.setFullscreen(c, null) else w.toplevel.unsetFullscreen(c)) catch {};
    }

    pub fn isMaximized(w: *const Window) bool {
        return w.states.maximized;
    }

    pub fn isFullscreen(w: *const Window) bool {
        return w.states.fullscreen;
    }

    pub fn isActivated(w: *const Window) bool {
        return w.states.activated;
    }

    /// Asks for one `Event.frame` when the compositor is ready for the next frame. Commit it
    /// with `present` (or it is committed automatically before the next poll).
    pub fn requestFrame(w: *Window) void {
        if (w.frame_cb != null) return;
        const c = w.app.conn;
        const cb = w.surface.frame(c) catch return;
        c.setData(cb, w.slot + 1);
        w.frame_cb = cb;
        w.frame_committed = false;
    }

    /// Activates the window with an xdg-activation token obtained elsewhere (e.g. from
    /// XDG_ACTIVATION_TOKEN at startup or another client).
    pub fn activate(w: *Window, token: []const u8) void {
        const act = w.app.g.activation orelse return;
        act.activate(w.app.conn, token, w.surface) catch {};
    }

    /// Requests attention (compositors usually mark the window urgent; no focus change).
    pub fn requestAttention(w: *Window) void {
        const app = w.app;
        const act = app.g.activation orelse return;
        const c = app.conn;
        const tok = act.getActivationToken(c) catch return;
        c.setData(tok, w.slot + 1);
        tok.setSurface(c, w.surface) catch {};
        tok.setAppId(c, app.appId()) catch {};
        tok.commit(c) catch {};
    }

    /// Enables IME text input; `rect` is the caret rectangle in logical window coordinates.
    pub fn startTextInput(w: *Window, rect: Rect) void {
        w.ti_rect = rect;
        if (w.ti_enabled) return w.setTextInputRect(rect);
        w.ti_enabled = true;
        if (w.app.ti_focus == w.slot + 1) w.app.tiEnable(w) catch {};
    }

    pub fn stopTextInput(w: *Window) void {
        if (!w.ti_enabled) return;
        w.ti_enabled = false;
        const app = w.app;
        if (app.ti_focus == w.slot + 1) {
            if (app.text_input) |ti| {
                ti.disable(app.conn) catch {};
                app.tiCommit() catch {};
            }
            app.endPreedit();
        }
    }

    pub fn setTextInputRect(w: *Window, rect: Rect) void {
        const same = w.ti_rect.x == rect.x and w.ti_rect.y == rect.y and w.ti_rect.w == rect.w and w.ti_rect.h == rect.h;
        w.ti_rect = rect;
        if (same or !w.ti_enabled or w.app.ti_focus != w.slot + 1) return;
        w.app.tiSendRect(w) catch {};
        w.app.tiCommit() catch {};
    }

    /// Wraps an exported dma-buf in a wl_buffer (zwp_linux_dmabuf_v1.create_immed). The fds
    /// are duplicated; the caller keeps ownership. The first import of a (format, modifier,
    /// planes) layout performs one roundtrip to detect failure; later ones do not.
    pub fn importDmabuf(w: *Window, image: contract.DmabufImage) !contract.BufferId {
        const app = w.app;
        const c = app.conn;
        const dmabuf = app.g.dmabuf orelse return error.Unsupported;
        if (image.plane_count == 0 or image.plane_count > contract.max_planes) return error.InvalidBuffer;
        const params = try dmabuf.createParams(c);
        for (image.planes[0..image.plane_count], 0..) |p, i| {
            try params.add(c, @enumFromInt(p.fd), @intCast(i), p.offset, p.stride, @truncate(image.modifier >> 32), @truncate(image.modifier));
        }
        const wl = try params.createImmed(c, @intCast(image.width), @intCast(image.height), @intFromEnum(image.format), 0);
        const known = if (app.dmabuf_verified) |v|
            v.format == @intFromEnum(image.format) and v.modifier == image.modifier and v.planes == image.plane_count
        else
            false;
        if (known) {
            try params.destroy(c);
        } else {
            app.params_failed = false;
            try c.roundtrip(app);
            try params.destroy(c);
            if (app.params_failed) {
                wl.destroy(c) catch {};
                return error.ImportFailed;
            }
            app.dmabuf_verified = .{ .format = @intFromEnum(image.format), .modifier = image.modifier, .planes = image.plane_count };
        }
        return app.allocBuffer(wl, w.slot + 1, @intCast(image.width), @intCast(image.height));
    }

    /// Wraps shared memory (e.g. a memfd) in a wl_buffer. The fd is duplicated.
    pub fn importShm(w: *Window, fd: std.posix.fd_t, width: u32, height: u32, stride: u32, format: contract.Fourcc) !contract.BufferId {
        const app = w.app;
        const c = app.conn;
        const shm_format: proto.WlShm.Format = switch (format) {
            .argb8888 => .argb8888,
            .xrgb8888 => .xrgb8888,
            else => @enumFromInt(@intFromEnum(format)),
        };
        const size = std.math.mul(u32, stride, height) catch return error.InvalidBuffer;
        if (size > std.math.maxInt(i32)) return error.InvalidBuffer;
        const pool = try app.g.shm.?.createPool(c, @enumFromInt(fd), @intCast(size));
        const wl = try pool.createBuffer(c, 0, @intCast(width), @intCast(height), @intCast(stride), shm_format);
        try pool.destroy(c);
        return app.allocBuffer(wl, w.slot + 1, @intCast(width), @intCast(height));
    }

    pub fn destroyBuffer(w: *Window, id: contract.BufferId) void {
        const b = w.app.bufferSlot(id) orelse return;
        b.wl.destroy(w.app.conn) catch {};
        b.live = false;
    }

    /// True once the compositor no longer reads the buffer (safe to render into again).
    pub fn bufferReleased(w: *Window, id: contract.BufferId) bool {
        const b = w.app.bufferSlot(id) orelse return true;
        return !b.busy;
    }

    /// Attaches `id`, damages `damage` (buffer pixels; empty = everything), sets the viewport
    /// destination / buffer scale, and commits (including a pending `requestFrame`).
    pub fn present(w: *Window, id: contract.BufferId, damage: []const contract.DamageRect) !void {
        const app = w.app;
        const c = app.conn;
        const b = app.bufferSlot(id) orelse return error.InvalidBuffer;
        // Attaching before the (re-)configure after show() is a protocol error.
        if (!w.visible or w.remap_pending) return;
        try w.surface.attach(c, b.wl, 0, 0);
        if (damage.len == 0) {
            try w.surface.damageBuffer(c, 0, 0, std.math.maxInt(i32), std.math.maxInt(i32));
        } else for (damage) |d| try w.surface.damageBuffer(c, d.x, d.y, d.w, d.h);
        if (w.viewport) |vp| {
            if (w.applied_dest[0] != w.width or w.applied_dest[1] != w.height) {
                try vp.setDestination(c, w.width, w.height);
                w.applied_dest = .{ w.width, w.height };
            }
        } else {
            var s = w.intScale();
            // A buffer that is not a multiple of the scale is a protocol error; degrade.
            if (@rem(b.width, s) != 0 or @rem(b.height, s) != 0) s = 1;
            if (s != w.applied_buffer_scale) {
                try w.surface.setBufferScale(c, s);
                w.applied_buffer_scale = s;
            }
        }
        try w.surface.commit(c);
        w.frame_committed = true;
        b.busy = true;
        w.has_buffer = true;
        _ = try c.trySend();
    }

    pub fn nativeHandles(w: *const Window) NativeHandles {
        return .{ .socket_fd = w.app.conn.fd, .surface_id = @intFromEnum(w.surface) };
    }
};

fn resolveKeycode(km: *const xkb.Keymap, evdev: u32, base: u32) ev.Keycode {
    const k = keysym.toKeycode(base);
    if (k != .character and k != .unknown) return k;
    // Non-Latin layouts: use a Latin group's identity, then the US position, so shortcuts
    // like Ctrl+C keep working on e.g. Cyrillic layouts.
    if (keysym.toUnicode(base) < 0x370 and k == .character) return k;
    var g: u32 = 0;
    while (g < km.num_groups) : (g += 1) {
        const s = km.baseSymInGroup(evdev + 8, g) orelse continue;
        const kg = keysym.toKeycode(s);
        if (kg != .character and kg != .unknown) return kg;
    }
    const ks = keysym.keycodeFromScancode(evdev);
    return if (ks != .unknown) ks else k;
}

fn truncateUtf8(s: []const u8, max: usize) []const u8 {
    if (s.len <= max) return s;
    var n = max;
    while (n > 0 and (s[n] & 0xc0) == 0x80) n -= 1;
    return s[0..n];
}

test "keycode resolution falls back for non-Latin layouts" {
    const text = @embedFile("testdata/two_groups.xkb");
    var km = try xkb.parse(std.testing.allocator, text);
    defer km.deinit();
    // <AC03> is "d" in group 1; in group 2 its base keysym is Cyrillic.
    const evdev_d: u32 = 32;
    const ru = km.lookup(evdev_d + 8, .{ .group = 1 });
    try std.testing.expectEqual(ev.Keycode.d, resolveKeycode(&km, evdev_d, ru.base_sym));
    const us = km.lookup(evdev_d + 8, .{});
    try std.testing.expectEqual(ev.Keycode.d, resolveKeycode(&km, evdev_d, us.base_sym));
}

fn testApp(gpa: std.mem.Allocator) !*App {
    const app = try gpa.create(App);
    app.* = .{ .gpa = gpa, .conn = undefined, .global_names = .init(gpa) };
    app.keymap = try xkb.parse(gpa, @embedFile("testdata/hyprland.xkb"));
    return app;
}

fn testAppFree(app: *App) void {
    if (app.keymap) |*k| k.deinit();
    app.global_names.deinit();
    app.gpa.destroy(app);
}

fn testWindow(app: *App) Window {
    return .{
        .app = app,
        .slot = 0,
        .id = @enumFromInt(1),
        .surface = undefined,
        .xdg_surface = undefined,
        .toplevel = undefined,
        .width = 100,
        .height = 100,
        .req_width = 100,
        .req_height = 100,
        .min_width = 0,
        .min_height = 0,
        .resizable = true,
    };
}

test "keypad keys resolve by NumLock state; mod keys track sides" {
    const app = try testApp(std.testing.allocator);
    defer testAppFree(app);
    var w = testWindow(app);
    var e: Event = undefined;
    const km = &app.keymap.?;

    app.emitKey(&w, 71, true, false); // KEY_KP7, NumLock off
    try std.testing.expect(app.pop(&e) and e.key_down.key == .home);
    app.xkb_state = .{ .locked = km.num_lock_mask };
    app.updateMods();
    app.emitKey(&w, 71, true, false);
    try std.testing.expect(app.pop(&e) and e.key_down.key == .kp_7);
    try std.testing.expect(e.key_down.mod.num_lock);
    app.emitKey(&w, 98, true, false); // KEY_KPSLASH
    try std.testing.expect(app.pop(&e) and e.key_down.key == .kp_divide);
    app.emitKey(&w, 183, true, false); // KEY_F13
    try std.testing.expect(app.pop(&e) and e.key_down.key == .f13);

    app.mod_keys.set(97, true); // KEY_RIGHTCTRL
    app.emitKey(&w, 46, true, false);
    try std.testing.expect(app.pop(&e) and e.key_down.mod_keys.rctrl and !e.key_down.mod_keys.lctrl);
}
