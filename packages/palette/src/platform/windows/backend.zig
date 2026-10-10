//! Win32 platform backend: windows, the event loop, keyboard/IME/pointer input, clipboard,
//! cursors and system queries. Mirrors the Wayland backend's public API (`App`, `Window`)
//! so `platform/root.zig` can select it at comptime.
//!
//! * Per-monitor-v2 DPI awareness. `logicalSize` = round(pixels / scale), scale = dpi / 96.
//!   WM_GETDPISCALEDSIZE keeps the logical client size across monitors, WM_DPICHANGED
//!   applies the suggested rect.
//! * One window class per App (named after `AppOptions.app_id`) plus a message-only window
//!   for `wakeup` (PostMessage of a private message) and clipboard change notifications.
//! * `waitEvent` blocks in MsgWaitForMultipleObjectsEx on the message queue and on the DXGI
//!   frame-latency waitables of windows that requested a frame (`setFrameWaitable`); idle
//!   costs no CPU.
//! * Input translation (keys, text, IME, mouse, wheel) is in `translate.zig` (pure,
//!   unit-tested on Linux); this file adapts it to user32/imm32.
//! * Moving or resizing a window runs a modal loop inside DefWindowProc. While it runs,
//!   `pollEvent` does not pump (the messages already arrive through the window procedure)
//!   and a host-supplied `setModalLoopCallback` is called from a 10 ms timer and after each
//!   resize so it can keep rendering.
const std = @import("std");
const builtin = @import("builtin");
const w = @import("win32.zig");
const translate = @import("translate.zig");
const keymap = @import("keymap.zig");
const contract = @import("../present.zig");
const ev = @import("../../event.zig");
const Event = ev.Event;

const log = std.log.scoped(.win32);

pub const Rect = @import("../../draw.zig").Rect;

pub const max_windows = 16;
const queue_capacity = 256;
/// Stop pumping when the queue has fewer free slots than this (one message can produce a
/// few events).
const queue_reserve = 16;
const text_capacity = 16 * 1024;
const wakeup_capacity = 256;

const WM_PALETTE_WAKE = w.WM_APP + 1;
const WM_PALETTE_QUIT = w.WM_APP + 2;
const modal_timer_id: usize = 0x9a1e;

pub const Error = error{
    RegisterClassFailed,
    CreateWindowFailed,
    TooManyWindows,
    Unsupported,
    ClipboardUnavailable,
    OutOfMemory,
};

pub const AppOptions = struct {
    /// Window class name (tests must use a `palette-test` prefix).
    app_id: []const u8 = "palette",
    /// Unused on Windows (kept for source compatibility with the Wayland backend).
    environ: std.process.Environ = .empty,
    /// Turn Ctrl+C / Ctrl+Break / console close into `Event.quit` (SetConsoleCtrlHandler),
    /// like SDL. Only one App per process may enable it.
    handle_signals: bool = false,
};

pub const SystemTheme = enum { unknown, light, dark };

pub const Decorations = enum {
    /// Standard title bar and frame.
    server,
    /// No system title bar or frame (WS_POPUP); the app draws its own.
    client,
};

pub const WindowOptions = struct {
    title: []const u8 = "Palette",
    /// Logical size of the client area.
    width: u32 = 800,
    height: u32 = 600,
    min_width: u32 = 0,
    min_height: u32 = 0,
    resizable: bool = true,
    /// Unused on Windows (the class name comes from `AppOptions.app_id`).
    app_id: ?[]const u8 = null,
    decorations: Decorations = .server,
};

/// CSS cursor names (same set as the Wayland backend), plus `hidden`.
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

    /// IDC_* resource id (0 = no cursor).
    pub fn systemCursor(s: CursorShape) usize {
        return switch (s) {
            .default, .context_menu, .alias, .copy, .cell, .zoom_in, .zoom_out, .grab, .grabbing => w.IDC_ARROW,
            .text, .vertical_text => w.IDC_IBEAM,
            .wait => w.IDC_WAIT,
            .progress => w.IDC_APPSTARTING,
            .crosshair => w.IDC_CROSS,
            .pointer => w.IDC_HAND,
            .move, .all_scroll => w.IDC_SIZEALL,
            .not_allowed, .no_drop => w.IDC_NO,
            .ew_resize, .e_resize, .w_resize, .col_resize => w.IDC_SIZEWE,
            .ns_resize, .n_resize, .s_resize, .row_resize => w.IDC_SIZENS,
            .nwse_resize, .nw_resize, .se_resize => w.IDC_SIZENWSE,
            .nesw_resize, .ne_resize, .sw_resize => w.IDC_SIZENESW,
            .help => w.IDC_HELP,
            .hidden => 0,
        };
    }
};

pub const Size = struct { width: u32, height: u32 };

pub const NativeHandles = struct {
    /// Top-level HWND (what SDL exposes as "SDL.window.win32.hwnd").
    hwnd: *anyopaque,
    /// Module handle the window class was registered with (GetModuleHandleW(null)).
    hinstance: *anyopaque,
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

pub const GlobalInfo = struct { name: u32, interface: []const u8, version: u32 };

const Translator = translate.Translator(Host);

/// `translate.Translator` host backed by user32/imm32 for one window.
const Host = struct {
    app: *App,
    win: *Window,

    pub fn push(h: *Host, e: Event) void {
        h.app.push(e);
    }
    pub fn storeText(h: *Host, s: []const u8) ?[]const u8 {
        return h.app.storeText(s);
    }
    pub fn keyState(h: *Host, vk: i32) i16 {
        _ = h;
        return w.GetKeyState(vk);
    }
    pub fn keyboardState(h: *Host, out: *[256]u8) void {
        _ = h;
        if (w.GetKeyboardState(out) == 0) out.* = @splat(0);
    }
    pub fn toUnicode(h: *Host, vk: u32, sc: u32, state: *const [256]u8, out: []u16) i32 {
        _ = h;
        // Flag 0x4 (Windows 10 1607+): do not change the keyboard's dead-key state.
        return w.ToUnicode(vk, sc & 0xFF, state, out.ptr, @intCast(out.len), 0x4);
    }
    pub fn vkToScancodeEx(h: *Host, vk: u32) u16 {
        _ = h;
        return @truncate(w.MapVirtualKeyW(vk, w.MAPVK_VK_TO_VSC_EX));
    }
    pub fn messageTime(h: *Host) u32 {
        _ = h;
        return @bitCast(w.GetMessageTime());
    }
    pub fn peekKey(h: *Host) ?w.MSG {
        var m: w.MSG = .{};
        if (w.PeekMessageW(&m, h.win.hwnd, w.WM_KEYFIRST, w.WM_KEYLAST, w.PM_NOREMOVE) == 0) return null;
        return m;
    }
    pub fn screenToClient(h: *Host, p: w.POINT) w.POINT {
        var q = p;
        _ = w.ScreenToClient(h.win.hwnd, &q);
        return q;
    }
    pub fn setCapture(h: *Host) void {
        _ = w.SetCapture(h.win.hwnd);
    }
    pub fn releaseCapture(h: *Host) void {
        _ = h;
        _ = w.ReleaseCapture();
    }
    pub fn trackLeave(h: *Host) void {
        var t: w.TRACKMOUSEEVENT = .{ .dwFlags = w.TME_LEAVE, .hwndTrack = h.win.hwnd };
        _ = w.TrackMouseEvent(&t);
    }
    pub fn doubleClickMs(h: *Host) u32 {
        _ = h;
        return w.GetDoubleClickTime();
    }
    pub fn doubleClickPx(h: *Host) [2]i32 {
        return .{ w.GetSystemMetricsForDpi(w.SM_CXDOUBLECLK, h.win.dpi), w.GetSystemMetricsForDpi(w.SM_CYDOUBLECLK, h.win.dpi) };
    }
    pub fn imeString(h: *Host, kind: u32, out: []u16) ?[]const u16 {
        const himc = w.ImmGetContext(h.win.hwnd) orelse return null;
        defer _ = w.ImmReleaseContext(h.win.hwnd, himc);
        const n = w.ImmGetCompositionStringW(himc, kind, out.ptr, @intCast(out.len * 2));
        if (n < 0) return null;
        return out[0..@min(@as(usize, @intCast(n)) / 2, out.len)];
    }
    pub fn imeCursor(h: *Host) i32 {
        const himc = w.ImmGetContext(h.win.hwnd) orelse return -1;
        defer _ = w.ImmReleaseContext(h.win.hwnd, himc);
        return w.ImmGetCompositionStringW(himc, w.GCS_CURSORPOS, null, 0) & 0xFFFF;
    }
};

/// The App that handles console control events (SetConsoleCtrlHandler has no context).
var console_app: std.atomic.Value(?*App) = .init(null);

fn consoleHandler(kind: w.DWORD) callconv(w.WINAPI) w.BOOL {
    switch (kind) {
        w.CTRL_C_EVENT, w.CTRL_BREAK_EVENT, w.CTRL_CLOSE_EVENT => {
            const app = console_app.load(.acquire) orelse return w.FALSE;
            app.quit_pending.store(true, .release);
            _ = w.PostMessageW(app.msg_hwnd, WM_PALETTE_QUIT, 0, 0);
            return w.TRUE;
        },
        else => return w.FALSE,
    }
}

pub const App = struct {
    gpa: std.mem.Allocator,
    hinstance: w.HINSTANCE,
    class_name: [128:0]u16 = undefined,
    msg_class_name: [140:0]u16 = undefined,
    msg_hwnd: w.HWND = undefined,
    handle_signals: bool = false,

    windows: [max_windows]?*Window = @splat(null),
    next_window_id: u32 = 1,

    queue: [queue_capacity]Event = undefined,
    q_head: usize = 0,
    q_len: usize = 0,
    text: [text_capacity]u8 = undefined,
    text_len: usize = 0,
    dropped_events: u64 = 0,

    wake_lock: std.atomic.Value(u32) = .init(0),
    wake_ring: [wakeup_capacity]u64 = undefined,
    wake_len: usize = 0,
    wake_posted: std.atomic.Value(bool) = .init(false),
    quit_pending: std.atomic.Value(bool) = .init(false),

    input: Translator = .{},
    kb_focus: ?*Window = null,
    ptr_window: ?*Window = null,

    theme: SystemTheme = .unknown,
    clipboard_seq: w.DWORD = 0,

    /// >0 while DefWindowProc runs a modal move/size loop (or a menu loop).
    modal_depth: u32 = 0,
    modal_callback: ?*const fn (ctx: ?*anyopaque) void = null,
    modal_ctx: ?*anyopaque = null,
    in_modal_callback: bool = false,

    pub fn init(gpa: std.mem.Allocator, options: AppOptions) !*App {
        // Fails with ERROR_ACCESS_DENIED when a manifest already set the awareness: fine.
        _ = w.SetProcessDpiAwarenessContext(w.DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
        const app = try gpa.create(App);
        errdefer gpa.destroy(app);
        app.* = .{ .gpa = gpa, .hinstance = w.GetModuleHandleW(null).? };

        const id = if (options.app_id.len > 0) options.app_id else "palette";
        _ = w.utf8ToUtf16Z(&app.class_name, id);
        var tmp: [140]u8 = undefined;
        const msg_id = std.fmt.bufPrint(&tmp, "{s}.msg", .{id[0..@min(id.len, 120)]}) catch unreachable;
        _ = w.utf8ToUtf16Z(&app.msg_class_name, msg_id);

        const wc: w.WNDCLASSEXW = .{
            // No CS_DBLCLKS: click counting is ours (SDL-compatible counts beyond 2).
            .style = w.CS_OWNDC,
            .lpfnWndProc = wndProc,
            .hInstance = app.hinstance,
            .hCursor = w.LoadCursorW(null, w.makeIntResource(w.IDC_ARROW)),
            .lpszClassName = &app.class_name,
        };
        if (w.RegisterClassExW(&wc) == 0) return error.RegisterClassFailed;
        errdefer _ = w.UnregisterClassW(&app.class_name, app.hinstance);
        const mc: w.WNDCLASSEXW = .{
            .lpfnWndProc = msgWndProc,
            .hInstance = app.hinstance,
            .lpszClassName = &app.msg_class_name,
        };
        if (w.RegisterClassExW(&mc) == 0) return error.RegisterClassFailed;
        errdefer _ = w.UnregisterClassW(&app.msg_class_name, app.hinstance);
        app.msg_hwnd = w.CreateWindowExW(0, &app.msg_class_name, w.L("palette"), 0, 0, 0, 0, 0, w.HWND_MESSAGE, null, app.hinstance, app) orelse
            return error.CreateWindowFailed;
        _ = w.AddClipboardFormatListener(app.msg_hwnd);
        app.clipboard_seq = w.GetClipboardSequenceNumber();
        app.theme = readSystemTheme();
        if (options.handle_signals) {
            if (console_app.cmpxchgStrong(null, app, .acq_rel, .acquire) == null) {
                _ = w.SetConsoleCtrlHandler(consoleHandler, w.TRUE);
                app.handle_signals = true;
            } else log.warn("handle_signals: another App already handles console events", .{});
        }
        return app;
    }

    pub fn deinit(app: *App) void {
        for (app.windows) |win| if (win) |x| x.destroy();
        if (app.handle_signals) {
            _ = w.SetConsoleCtrlHandler(consoleHandler, w.FALSE);
            console_app.store(null, .release);
        }
        _ = w.RemoveClipboardFormatListener(app.msg_hwnd);
        _ = w.DestroyWindow(app.msg_hwnd);
        _ = w.UnregisterClassW(&app.class_name, app.hinstance);
        _ = w.UnregisterClassW(&app.msg_class_name, app.hinstance);
        app.gpa.destroy(app);
    }

    /// No registry on Windows.
    pub fn globals(app: *const App) []const GlobalInfo {
        _ = app;
        return &.{};
    }

    // -- event queue ----------------------------------------------------------------------------

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

    /// Non-blocking: returns the next event if one is available. Inside a modal move/size
    /// loop (see `setModalLoopCallback`) it only returns already queued events.
    pub fn pollEvent(app: *App, out: *Event) bool {
        if (app.pop(out)) return true;
        if (app.modal_depth == 0) app.text_len = 0;
        app.pump(0);
        return app.pop(out);
    }

    /// Blocks until an event arrives or `timeout_ns` elapses (null = forever). Returns false
    /// on timeout.
    pub fn waitEvent(app: *App, out: *Event, timeout_ns: ?u64) bool {
        if (app.pop(out)) return true;
        if (app.modal_depth == 0) app.text_len = 0;
        const deadline: ?u64 = if (timeout_ns) |t| monotonicNs() +| t else null;
        while (true) {
            var remaining: ?u64 = null;
            if (deadline) |d| {
                const now = monotonicNs();
                remaining = if (now >= d) 0 else d - now;
            }
            app.pump(remaining);
            if (app.pop(out)) return true;
            if (remaining) |r| if (r == 0) return false;
            if (app.modal_depth > 0) return false; // cannot block inside the modal loop
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
        // One posted message at a time (the thread's posted-message queue is bounded).
        if (!app.wake_posted.swap(true, .acq_rel)) _ = w.PostMessageW(app.msg_hwnd, WM_PALETTE_WAKE, 0, 0);
    }

    fn drainWakeups(app: *App) void {
        app.wake_posted.store(false, .release);
        var local: [wakeup_capacity]u64 = undefined;
        while (app.wake_lock.cmpxchgWeak(0, 1, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
        const n = @min(app.wake_len, queue_capacity - app.q_len);
        @memcpy(local[0..n], app.wake_ring[0..n]);
        std.mem.copyForwards(u64, app.wake_ring[0 .. app.wake_len - n], app.wake_ring[n..app.wake_len]);
        app.wake_len -= n;
        const left = app.wake_len;
        app.wake_lock.store(0, .release);
        for (local[0..n]) |u| app.push(.{ .user = u });
        // Queue full: try again on the next pump.
        if (left > 0 and !app.wake_posted.swap(true, .acq_rel)) _ = w.PostMessageW(app.msg_hwnd, WM_PALETTE_WAKE, 0, 0);
    }

    /// Dispatches pending messages; with `timeout_ns` > 0 and nothing queued, first blocks
    /// until a message, a frame waitable or the timeout.
    fn pump(app: *App, timeout_ns: ?u64) void {
        if (app.modal_depth > 0) {
            // The modal loop dispatches for us; only frame pacing needs polling.
            app.pollFrameWaitables();
            return;
        }
        var handles: [max_windows]w.HANDLE = undefined;
        var owners: [max_windows]*Window = undefined;
        var n: usize = 0;
        var immediate = false;
        for (app.windows) |win| if (win) |x| if (x.frame_requested) {
            if (x.frame_waitable != null and x.visible and !x.minimized) {
                handles[n] = x.frame_waitable.?;
                owners[n] = x;
                n += 1;
            } else immediate = true;
        };
        const want_wait = if (timeout_ns) |t| t > 0 else true;
        if (want_wait and !immediate and app.q_len == 0 and !app.quit_pending.load(.acquire)) {
            const ms: w.DWORD = if (timeout_ns) |t| @intCast(@min((t + std.time.ns_per_ms - 1) / std.time.ns_per_ms, w.INFINITE - 1)) else w.INFINITE;
            const r = w.MsgWaitForMultipleObjectsEx(@intCast(n), if (n > 0) &handles else null, ms, w.QS_ALLINPUT, w.MWMO_INPUTAVAILABLE);
            if (r < n) app.frameReady(owners[r]);
        }
        app.pollFrameWaitables();
        var m: w.MSG = .{};
        while (app.q_len + queue_reserve <= queue_capacity and w.PeekMessageW(&m, null, 0, 0, w.PM_REMOVE) != 0) {
            if (m.message == w.WM_QUIT) {
                app.push(.quit);
                continue;
            }
            _ = w.TranslateMessage(&m);
            _ = w.DispatchMessageW(&m);
            if (app.modal_depth > 0) break;
        }
        if (app.quit_pending.swap(false, .acq_rel)) app.push(.quit);
        // Frames requested without a waitable (or while hidden) are due right away.
        for (app.windows) |win| if (win) |x| if (x.frame_requested and (x.frame_waitable == null or !x.visible or x.minimized)) app.frameReady(x);
    }

    fn pollFrameWaitables(app: *App) void {
        for (app.windows) |win| if (win) |x| if (x.frame_requested) if (x.frame_waitable) |h| {
            if (w.WaitForSingleObject(h, 0) == w.WAIT_OBJECT_0) app.frameReady(x);
        };
    }

    fn frameReady(app: *App, x: *Window) void {
        if (!x.frame_requested) return;
        x.frame_requested = false;
        app.push(.{ .frame = .{ .window = x.id } });
    }

    /// Called from a timer while the user moves/resizes a window (DefWindowProc runs a modal
    /// loop then and the host's own loop is blocked), and right after each modal resize.
    /// The callback may call `pollEvent` (which returns queued events without pumping) and
    /// render. Null disables it.
    pub fn setModalLoopCallback(app: *App, ctx: ?*anyopaque, callback: ?*const fn (ctx: ?*anyopaque) void) void {
        app.modal_ctx = ctx;
        app.modal_callback = callback;
    }

    /// True while a modal move/size loop runs (see `setModalLoopCallback`).
    pub fn inModalLoop(app: *const App) bool {
        return app.modal_depth > 0;
    }

    fn runModalCallback(app: *App) void {
        const cb = app.modal_callback orelse return;
        if (app.in_modal_callback) return;
        app.in_modal_callback = true;
        defer app.in_modal_callback = false;
        cb(app.modal_ctx);
    }

    // -- accessors ------------------------------------------------------------------------------

    pub fn modState(app: *App) ev.Mods {
        var h: Host = .{ .app = app, .win = undefined };
        return app.input.mods(&h);
    }

    pub fn modKeys(app: *const App) ev.ModKeys {
        return app.input.mod_keys;
    }

    /// Nothing to synchronise with on Win32 (calls are synchronous).
    pub fn sync(app: *App) !void {
        _ = app;
    }

    pub fn pointerFocus(app: *const App) ?*Window {
        return if (app.input.ptr_inside) app.ptr_window else null;
    }

    pub fn keyboardFocus(app: *const App) ?*Window {
        return app.kb_focus;
    }

    /// `AppsUseLightTheme` (re-read on WM_SETTINGCHANGE "ImmersiveColorSet"). There is no
    /// change event; hosts that follow the theme re-query after `focus_gained` or poll.
    pub fn systemTheme(app: *const App) SystemTheme {
        return app.theme;
    }

    /// Work area (screen minus taskbar) of the monitor showing the first window, or of the
    /// primary monitor, in logical px of that monitor.
    pub fn usableBounds(app: *const App) ?Size {
        const r = app.usableRect() orelse return null;
        return .{ .width = @intFromFloat(r.w), .height = @intFromFloat(r.h) };
    }

    /// Work area of the monitor of the first window (else the primary), in logical units of
    /// that monitor's DPI: origin = physical origin / scale. Exact on a single monitor; with
    /// mixed-DPI monitors the origin is only meaningful together with `Window.setPosition`
    /// scaled by the same factor.
    pub fn usableRect(app: *const App) ?Rect {
        var mon: ?w.HMONITOR = null;
        for (app.windows) |win| if (win) |x| {
            mon = w.MonitorFromWindow(x.hwnd, w.MONITOR_DEFAULTTONEAREST);
            break;
        };
        if (mon == null) mon = w.MonitorFromPoint(.{}, w.MONITOR_DEFAULTTOPRIMARY);
        const m = mon orelse return null;
        var info: w.MONITORINFO = .{};
        if (w.GetMonitorInfoW(m, &info) == 0) return null;
        var dx: w.UINT = 96;
        var dy: w.UINT = 96;
        if (w.GetDpiForMonitor(m, w.MDT_EFFECTIVE_DPI, &dx, &dy) < 0) dx = 96;
        const lw = translate.dpi.toLogical(info.rcWork.width(), dx);
        const lh = translate.dpi.toLogical(info.rcWork.height(), dx);
        if (lw <= 0 or lh <= 0) return null;
        const scale = translate.dpi.scale(dx);
        return .{
            .x = @as(f32, @floatFromInt(info.rcWork.left)) / scale,
            .y = @as(f32, @floatFromInt(info.rcWork.top)) / scale,
            .w = @floatFromInt(lw),
            .h = @floatFromInt(lh),
        };
    }

    /// No dma-buf on Windows (kept so shared code compiles).
    pub fn dmabufFeedback(app: *const App) contract.DmabufFeedback {
        _ = app;
        return .{};
    }

    // -- clipboard ------------------------------------------------------------------------------

    fn openClipboard(app: *App) bool {
        // Another process may hold it for a moment.
        var i: u32 = 0;
        while (i < 5) : (i += 1) {
            if (w.OpenClipboard(app.msg_hwnd) != 0) return true;
            w.Sleep(1);
        }
        return false;
    }

    /// Sets CF_UNICODETEXT (LF becomes CRLF, the Windows convention).
    pub fn setClipboardText(app: *App, text: []const u8) !void {
        const units = try clipboardUtf16(app.gpa, text);
        defer app.gpa.free(units);
        const bytes = (units.len + 1) * 2;
        const mem = w.GlobalAlloc(w.GMEM_MOVEABLE, bytes) orelse return error.OutOfMemory;
        {
            const p: [*]u16 = @ptrCast(@alignCast(w.GlobalLock(mem) orelse {
                _ = w.GlobalFree(mem);
                return error.OutOfMemory;
            }));
            @memcpy(p[0..units.len], units);
            p[units.len] = 0;
            _ = w.GlobalUnlock(mem);
        }
        if (!app.openClipboard()) {
            _ = w.GlobalFree(mem);
            return error.ClipboardUnavailable;
        }
        defer _ = w.CloseClipboard();
        _ = w.EmptyClipboard();
        if (w.SetClipboardData(w.CF_UNICODETEXT, mem) == null) {
            _ = w.GlobalFree(mem);
            return error.ClipboardUnavailable;
        }
    }

    /// Caller owns the returned slice (CRLF normalised to LF). null = no text on the
    /// clipboard.
    pub fn getClipboardText(app: *App, allocator: std.mem.Allocator) !?[]u8 {
        if (!app.openClipboard()) return error.ClipboardUnavailable;
        defer _ = w.CloseClipboard();
        const h = w.GetClipboardData(w.CF_UNICODETEXT) orelse return null;
        const p: [*]const u16 = @ptrCast(@alignCast(w.GlobalLock(h) orelse return null));
        defer _ = w.GlobalUnlock(h);
        const max_units = w.GlobalSize(h) / 2;
        const units = p[0 .. std.mem.indexOfScalar(u16, p[0..max_units], 0) orelse max_units];
        const out = try allocator.alloc(u8, units.len * 3);
        const conv = translate.utf16ToUtf8(out, units, -1);
        const n = translate.crlfToLf(out[0..conv.text.len]).len;
        return allocator.realloc(out, n) catch out[0..n];
    }

    /// No primary selection on Windows.
    pub fn setPrimarySelectionText(app: *App, text: []const u8) !void {
        _ = app;
        _ = text;
        return error.Unsupported;
    }

    pub fn getPrimarySelectionText(app: *App, allocator: std.mem.Allocator) !?[]u8 {
        _ = app;
        _ = allocator;
        return null;
    }

    // -- windows --------------------------------------------------------------------------------

    pub fn createWindow(app: *App, options: WindowOptions) !*Window {
        const slot: u32 = for (app.windows, 0..) |x, i| {
            if (x == null) break @intCast(i);
        } else return error.TooManyWindows;
        const win = try app.gpa.create(Window);
        errdefer app.gpa.destroy(win);
        const lw: i32 = @intCast(@max(1, @min(options.width, 1 << 15)));
        const lh: i32 = @intCast(@max(1, @min(options.height, 1 << 15)));
        win.* = .{
            .app = app,
            .hwnd = undefined,
            .slot = slot,
            .id = @enumFromInt(app.next_window_id),
            .logical_w = lw,
            .logical_h = lh,
            .min_width = @intCast(@min(options.min_width, 1 << 15)),
            .min_height = @intCast(@min(options.min_height, 1 << 15)),
            .resizable = options.resizable,
            .decorations = options.decorations,
        };
        app.next_window_id +%= 1;
        if (app.next_window_id == 0) app.next_window_id = 1;
        win.style = win.windowStyle();
        var title: [1024]u16 = undefined;
        const t = w.utf8ToUtf16Z(&title, options.title);
        const hwnd = w.CreateWindowExW(win.ex_style, &app.class_name, t.ptr, win.style, w.CW_USEDEFAULT, w.CW_USEDEFAULT, w.CW_USEDEFAULT, w.CW_USEDEFAULT, null, null, app.hinstance, win) orelse
            return error.CreateWindowFailed;
        win.hwnd = hwnd;
        app.windows[slot] = win;
        win.dpi = @max(w.GetDpiForWindow(hwnd), 1);
        // Client area = logical size at this monitor's DPI.
        const outer = win.outerSize(translate.dpi.toPixels(lw, win.dpi), translate.dpi.toPixels(lh, win.dpi), win.dpi);
        _ = w.SetWindowPos(hwnd, null, 0, 0, outer[0], outer[1], w.SWP_NOMOVE | w.SWP_NOZORDER | w.SWP_NOACTIVATE);
        // IME off until startTextInput.
        _ = w.ImmAssociateContextEx(hwnd, null, 0);
        win.applyDarkMode(app.theme == .dark);
        win.visible = true;
        _ = w.ShowWindow(hwnd, w.SW_SHOWNORMAL);
        win.updateSize(true);
        return win;
    }

    fn windowFromHwnd(app: *App, hwnd: ?w.HWND) ?*Window {
        const h = hwnd orelse return null;
        for (app.windows) |x| if (x) |y| if (y.hwnd == h) return y;
        return null;
    }

    fn onThemeSetting(app: *App) void {
        const t = readSystemTheme();
        if (t == app.theme) return;
        app.theme = t;
        for (app.windows) |x| if (x) |y| y.applyDarkMode(t == .dark);
    }

    fn onClipboardUpdate(app: *App) void {
        const seq = w.GetClipboardSequenceNumber();
        if (seq == app.clipboard_seq) return;
        app.clipboard_seq = seq;
        app.push(.{ .clipboard_update = .{ .window = if (app.kb_focus) |f| f.id else .invalid } });
    }
};

pub const Window = struct {
    app: *App,
    hwnd: w.HWND,
    slot: u32,
    id: ev.WindowId,
    dpi: u32 = 96,
    style: w.DWORD = 0,
    ex_style: w.DWORD = 0,
    decorations: Decorations = .server,
    /// Requested logical client size (kept across DPI changes).
    logical_w: i32,
    logical_h: i32,
    px_w: i32 = 0,
    px_h: i32 = 0,
    min_width: i32 = 0,
    min_height: i32 = 0,
    resizable: bool = true,
    visible: bool = false,
    minimized: bool = false,
    activated: bool = false,
    fullscreen: bool = false,
    saved_style: w.DWORD = 0,
    saved_placement: w.WINDOWPLACEMENT = .{},
    emitted: ev.ResizeEvent = .{ .width = 0, .height = 0, .pixel_width = 0, .pixel_height = 0, .scale = 0 },
    cursor: CursorShape = .default,
    cursor_handle: ?w.HCURSOR = null,
    ti_enabled: bool = false,
    ti_rect: Rect = .{},
    frame_requested: bool = false,
    frame_waitable: ?w.HANDLE = null,

    fn windowStyle(win: *const Window) w.DWORD {
        const base: w.DWORD = w.WS_CLIPSIBLINGS | w.WS_CLIPCHILDREN;
        return switch (win.decorations) {
            .server => base | w.WS_OVERLAPPED | w.WS_CAPTION | w.WS_SYSMENU | w.WS_MINIMIZEBOX |
                (if (win.resizable) @as(w.DWORD, w.WS_THICKFRAME | w.WS_MAXIMIZEBOX) else 0),
            .client => base | w.WS_POPUP | w.WS_MINIMIZEBOX,
        };
    }

    /// Outer window size for a client size in px at `dpi`.
    fn outerSize(win: *const Window, cw: i32, ch: i32, dpi: u32) [2]i32 {
        var r: w.RECT = .{ .left = 0, .top = 0, .right = cw, .bottom = ch };
        _ = w.AdjustWindowRectExForDpi(&r, win.style, w.FALSE, win.ex_style, dpi);
        return .{ r.width(), r.height() };
    }

    fn info(win: *const Window) translate.WindowInfo {
        return .{ .id = win.id, .scale = win.scale(), .text_input = win.ti_enabled };
    }

    /// Re-reads the client size; pushes `resized` when it (or the scale) changed.
    fn updateSize(win: *Window, force: bool) void {
        if (win.minimized) return;
        var r: w.RECT = .{};
        if (w.GetClientRect(win.hwnd, &r) == 0) return;
        win.px_w = @max(r.width(), 1);
        win.px_h = @max(r.height(), 1);
        if (!win.fullscreen and w.IsZoomed(win.hwnd) == 0) {
            win.logical_w = translate.dpi.toLogical(win.px_w, win.dpi);
            win.logical_h = translate.dpi.toLogical(win.px_h, win.dpi);
        }
        const e: ev.ResizeEvent = .{
            .window = win.id,
            .width = translate.dpi.toLogical(win.px_w, win.dpi),
            .height = translate.dpi.toLogical(win.px_h, win.dpi),
            .pixel_width = win.px_w,
            .pixel_height = win.px_h,
            .scale = win.scale(),
        };
        if (!force and std.meta.eql(e, win.emitted)) return;
        win.emitted = e;
        win.app.push(.{ .resized = e });
    }

    fn applyDarkMode(win: *Window, dark: bool) void {
        const v: w.BOOL = @intFromBool(dark);
        _ = w.DwmSetWindowAttribute(win.hwnd, w.DWMWA_USE_IMMERSIVE_DARK_MODE, &v, @sizeOf(w.BOOL));
    }

    /// Hides the window (SW_HIDE) and emits `window_hidden` (.unmapped).
    pub fn hide(win: *Window) void {
        if (!win.visible) return;
        win.visible = false;
        _ = w.ShowWindow(win.hwnd, w.SW_HIDE);
        if (win.frame_requested) win.app.frameReady(win);
        win.app.push(.{ .window_hidden = .{ .window = win.id, .reason = .unmapped } });
    }

    /// Shows a hidden window again (activating it) and emits `window_shown` (.unmapped).
    pub fn show(win: *Window) void {
        if (win.visible) return;
        win.visible = true;
        _ = w.ShowWindow(win.hwnd, w.SW_SHOW);
        win.app.push(.{ .window_shown = .{ .window = win.id, .reason = .unmapped } });
    }

    pub fn isVisible(win: *const Window) bool {
        return win.visible;
    }

    /// Minimized (Windows has no other notion of a suspended window).
    pub fn isSuspended(win: *const Window) bool {
        return win.minimized;
    }

    pub fn isTextInputActive(win: *const Window) bool {
        return win.ti_enabled;
    }

    pub fn hasPointerFocus(win: *const Window) bool {
        return win.app.pointerFocus() == win;
    }

    pub fn hasKeyboardFocus(win: *const Window) bool {
        return win.app.kb_focus == win;
    }

    pub fn configureBounds(win: *const Window) ?Size {
        _ = win;
        return null;
    }

    /// Screen position of the client area's top-left corner in physical pixels (what SDL3
    /// reports as the window position on Windows).
    pub fn position(win: *const Window) [2]i32 {
        var p: w.POINT = .{};
        _ = w.ClientToScreen(win.hwnd, &p);
        return .{ p.x, p.y };
    }

    /// Moves the window so its client area starts at (x, y) in physical screen pixels.
    pub fn setPosition(win: *Window, x: i32, y: i32) void {
        var r: w.RECT = .{};
        _ = w.AdjustWindowRectExForDpi(&r, win.style, w.FALSE, win.ex_style, win.dpi);
        _ = w.SetWindowPos(win.hwnd, null, x + r.left, y + r.top, 0, 0, w.SWP_NOSIZE | w.SWP_NOZORDER | w.SWP_NOACTIVATE);
    }

    pub fn destroy(win: *Window) void {
        const app = win.app;
        if (app.kb_focus == win) app.kb_focus = null;
        if (app.ptr_window == win) {
            app.ptr_window = null;
            app.input.ptr_inside = false;
        }
        _ = w.SetWindowLongPtrW(win.hwnd, w.GWLP_USERDATA, 0);
        _ = w.DestroyWindow(win.hwnd);
        app.windows[win.slot] = null;
        app.gpa.destroy(win);
    }

    pub fn logicalSize(win: *const Window) Size {
        return .{ .width = @intCast(@max(translate.dpi.toLogical(win.px_w, win.dpi), 1)), .height = @intCast(@max(translate.dpi.toLogical(win.px_h, win.dpi), 1)) };
    }

    pub fn pixelSize(win: *const Window) Size {
        return .{ .width = @intCast(@max(win.px_w, 1)), .height = @intCast(@max(win.px_h, 1)) };
    }

    /// dpi / 96.
    pub fn scale(win: *const Window) f32 {
        return translate.dpi.scale(win.dpi);
    }

    pub fn setTitle(win: *Window, title: []const u8) void {
        var buf: [1024]u16 = undefined;
        _ = w.SetWindowTextW(win.hwnd, w.utf8ToUtf16Z(&buf, title).ptr);
    }

    /// Resizes the client area to a logical size (Win32 only: xdg-shell has no client-side
    /// resize). Ignored while maximized/fullscreen/minimized; emits `resized` as usual.
    pub fn setSize(win: *Window, width: u32, height: u32) void {
        win.logical_w = @intCast(@max(1, @min(width, 1 << 15)));
        win.logical_h = @intCast(@max(1, @min(height, 1 << 15)));
        if (win.minimized or win.fullscreen or w.IsZoomed(win.hwnd) != 0) return;
        const outer = win.outerSize(translate.dpi.toPixels(win.logical_w, win.dpi), translate.dpi.toPixels(win.logical_h, win.dpi), win.dpi);
        _ = w.SetWindowPos(win.hwnd, null, 0, 0, outer[0], outer[1], w.SWP_NOMOVE | w.SWP_NOZORDER | w.SWP_NOACTIVATE);
    }

    /// Minimum logical client size (WM_GETMINMAXINFO).
    pub fn setMinSize(win: *Window, width: u32, height: u32) void {
        win.min_width = @intCast(@min(width, 1 << 15));
        win.min_height = @intCast(@min(height, 1 << 15));
        // Grow now if below the new minimum.
        if (win.minimized or win.fullscreen or w.IsZoomed(win.hwnd) != 0) return;
        const mw = translate.dpi.toPixels(win.min_width, win.dpi);
        const mh = translate.dpi.toPixels(win.min_height, win.dpi);
        if (win.px_w < mw or win.px_h < mh) {
            const outer = win.outerSize(@max(win.px_w, mw), @max(win.px_h, mh), win.dpi);
            _ = w.SetWindowPos(win.hwnd, null, 0, 0, outer[0], outer[1], w.SWP_NOMOVE | w.SWP_NOZORDER | w.SWP_NOACTIVATE);
        }
    }

    pub fn setCursor(win: *Window, shape: CursorShape) void {
        if (win.cursor == shape and (shape == .hidden or win.cursor_handle != null)) return;
        win.cursor = shape;
        const id = shape.systemCursor();
        win.cursor_handle = if (id == 0) null else w.LoadCursorW(null, w.makeIntResource(id));
        if (win.hasPointerFocus()) _ = w.SetCursor(win.cursor_handle);
    }

    pub fn setMaximized(win: *Window, on: bool) void {
        if (win.fullscreen) return;
        _ = w.ShowWindow(win.hwnd, if (on) w.SW_MAXIMIZE else w.SW_RESTORE);
    }

    pub fn minimize(win: *Window) void {
        _ = w.ShowWindow(win.hwnd, w.SW_MINIMIZE);
    }

    /// Borderless window covering the whole monitor (no display mode change).
    pub fn setFullscreen(win: *Window, on: bool) void {
        if (on == win.fullscreen) return;
        if (on) {
            const mon = w.MonitorFromWindow(win.hwnd, w.MONITOR_DEFAULTTONEAREST) orelse return;
            var mi: w.MONITORINFO = .{};
            if (w.GetMonitorInfoW(mon, &mi) == 0) return;
            win.saved_placement = .{};
            _ = w.GetWindowPlacement(win.hwnd, &win.saved_placement);
            win.saved_style = win.style;
            win.fullscreen = true;
            win.style = (win.style & ~@as(w.DWORD, w.WS_CAPTION | w.WS_THICKFRAME | w.WS_SYSMENU | w.WS_MAXIMIZEBOX)) | w.WS_POPUP;
            _ = w.SetWindowLongPtrW(win.hwnd, w.GWL_STYLE, @intCast(win.style | (if (win.visible) @as(w.DWORD, w.WS_VISIBLE) else 0)));
            const r = mi.rcMonitor;
            _ = w.SetWindowPos(win.hwnd, w.HWND_TOP, r.left, r.top, r.width(), r.height(), w.SWP_FRAMECHANGED | w.SWP_NOOWNERZORDER);
        } else {
            win.fullscreen = false;
            win.style = win.saved_style;
            _ = w.SetWindowLongPtrW(win.hwnd, w.GWL_STYLE, @intCast(win.style | (if (win.visible) @as(w.DWORD, w.WS_VISIBLE) else 0)));
            _ = w.SetWindowPlacement(win.hwnd, &win.saved_placement);
            _ = w.SetWindowPos(win.hwnd, null, 0, 0, 0, 0, w.SWP_FRAMECHANGED | w.SWP_NOMOVE | w.SWP_NOSIZE | w.SWP_NOZORDER | w.SWP_NOOWNERZORDER);
        }
        win.updateSize(false);
    }

    pub fn isMaximized(win: *const Window) bool {
        return w.IsZoomed(win.hwnd) != 0;
    }

    pub fn isFullscreen(win: *const Window) bool {
        return win.fullscreen;
    }

    pub fn isActivated(win: *const Window) bool {
        return win.activated;
    }

    /// Asks for one `Event.frame` when the swapchain can take the next frame (its DXGI
    /// frame-latency waitable is signalled; see `setFrameWaitable`). Without a waitable, or
    /// while hidden/minimized, the event comes on the next poll.
    pub fn requestFrame(win: *Window) void {
        win.frame_requested = true;
    }

    /// Registers the swapchain's frame-latency waitable object (IDXGISwapChain2::
    /// GetFrameLatencyWaitableObject) for frame pacing; null unregisters. Not owned.
    pub fn setFrameWaitable(win: *Window, handle: ?*anyopaque) void {
        win.frame_waitable = handle;
    }

    /// Brings the window to the foreground. Windows only allows this when the process may
    /// set the foreground window (it received the last input, or was given the right); else
    /// the taskbar button flashes instead. `token` is ignored (Wayland activation token).
    pub fn activate(win: *Window, token: []const u8) void {
        _ = token;
        if (w.IsIconic(win.hwnd) != 0) _ = w.ShowWindow(win.hwnd, w.SW_RESTORE);
        if (w.SetForegroundWindow(win.hwnd) == 0) win.requestAttention();
    }

    /// Flashes the taskbar button until the window is activated (no focus change).
    pub fn requestAttention(win: *Window) void {
        const fi: w.FLASHWINFO = .{ .hwnd = win.hwnd, .dwFlags = w.FLASHW_ALL | w.FLASHW_TIMERNOFG, .uCount = 0 };
        _ = w.FlashWindowEx(&fi);
    }

    /// Enables text input (WM_CHAR → `text_input`) and the IME; `rect` is the caret
    /// rectangle in logical window coordinates (candidate window placement).
    pub fn startTextInput(win: *Window, rect: Rect) void {
        win.ti_rect = rect;
        if (!win.ti_enabled) {
            win.ti_enabled = true;
            _ = w.ImmAssociateContextEx(win.hwnd, null, w.IACE_DEFAULT);
        }
        win.placeIme();
    }

    pub fn stopTextInput(win: *Window) void {
        if (!win.ti_enabled) return;
        if (w.ImmGetContext(win.hwnd)) |himc| {
            _ = w.ImmNotifyIME(himc, w.NI_COMPOSITIONSTR, w.CPS_CANCEL, 0);
            _ = w.ImmReleaseContext(win.hwnd, himc);
        }
        var h: Host = .{ .app = win.app, .win = win };
        if (win.app.input.preedit_active) {
            win.app.input.preedit_active = false;
            h.push(.{ .text_editing = .{ .window = win.id, .text = "" } });
        }
        win.ti_enabled = false;
        _ = w.ImmAssociateContextEx(win.hwnd, null, 0);
    }

    pub fn setTextInputRect(win: *Window, rect: Rect) void {
        const same = win.ti_rect.x == rect.x and win.ti_rect.y == rect.y and win.ti_rect.w == rect.w and win.ti_rect.h == rect.h;
        win.ti_rect = rect;
        if (same or !win.ti_enabled) return;
        win.placeIme();
    }

    fn placeIme(win: *Window) void {
        const himc = w.ImmGetContext(win.hwnd) orelse return;
        defer _ = w.ImmReleaseContext(win.hwnd, himc);
        const s = win.scale();
        const r = win.ti_rect;
        const area: w.RECT = .{
            .left = @intFromFloat(@floor(r.x * s)),
            .top = @intFromFloat(@floor(r.y * s)),
            .right = @intFromFloat(@ceil((r.x + r.w) * s)),
            .bottom = @intFromFloat(@ceil((r.y + r.h) * s)),
        };
        const cof: w.COMPOSITIONFORM = .{ .dwStyle = w.CFS_RECT, .ptCurrentPos = .{ .x = area.left, .y = area.top }, .rcArea = area };
        _ = w.ImmSetCompositionWindow(himc, &cof);
        const caf: w.CANDIDATEFORM = .{ .dwIndex = 0, .dwStyle = w.CFS_EXCLUDE, .ptCurrentPos = .{ .x = area.left, .y = area.top }, .rcArea = area };
        _ = w.ImmSetCandidateWindow(himc, &caf);
    }

    pub fn nativeHandles(win: *const Window) NativeHandles {
        return .{ .hwnd = win.hwnd, .hinstance = win.app.hinstance };
    }

    // -- window procedure -----------------------------------------------------------------------

    fn handleMessage(win: *Window, msg: u32, wp: w.WPARAM, lp: w.LPARAM) ?w.LRESULT {
        const app = win.app;
        switch (msg) {
            w.WM_CLOSE => {
                app.push(.{ .close_requested = .{ .window = win.id } });
                return 0;
            },
            w.WM_ERASEBKGND => return 1,
            w.WM_PAINT => {
                var ps: w.PAINTSTRUCT = .{};
                _ = w.BeginPaint(win.hwnd, &ps);
                _ = w.EndPaint(win.hwnd, &ps);
                return 0;
            },
            w.WM_SIZE => {
                if (wp == w.SIZE_MINIMIZED) {
                    if (!win.minimized) {
                        win.minimized = true;
                        if (win.frame_requested) app.frameReady(win);
                        app.push(.{ .window_hidden = .{ .window = win.id, .reason = .suspended } });
                    }
                    return 0;
                }
                if (win.minimized) {
                    win.minimized = false;
                    app.push(.{ .window_shown = .{ .window = win.id, .reason = .suspended } });
                }
                win.updateSize(false);
                if (app.modal_depth > 0) app.runModalCallback();
                return 0;
            },
            w.WM_ACTIVATE => {
                win.activated = w.loword(wp) != w.WA_INACTIVE;
                return null;
            },
            w.WM_GETMINMAXINFO => {
                const mmi: *w.MINMAXINFO = @ptrFromInt(@as(usize, @bitCast(lp)));
                if (win.min_width > 0 or win.min_height > 0) {
                    const outer = win.outerSize(translate.dpi.toPixels(@max(win.min_width, 1), win.dpi), translate.dpi.toPixels(@max(win.min_height, 1), win.dpi), win.dpi);
                    mmi.ptMinTrackSize = .{ .x = outer[0], .y = outer[1] };
                }
                return 0;
            },
            w.WM_GETDPISCALEDSIZE => {
                // Keep the logical client size on the new monitor.
                const new_dpi: u32 = @truncate(wp);
                const sz: *w.SIZE = @ptrFromInt(@as(usize, @bitCast(lp)));
                const outer = win.outerSize(translate.dpi.toPixels(win.logical_w, new_dpi), translate.dpi.toPixels(win.logical_h, new_dpi), new_dpi);
                sz.* = .{ .cx = outer[0], .cy = outer[1] };
                return w.TRUE;
            },
            w.WM_DPICHANGED => {
                win.dpi = @max(w.hiword(wp), 1);
                const r: *const w.RECT = @ptrFromInt(@as(usize, @bitCast(lp)));
                _ = w.SetWindowPos(win.hwnd, null, r.left, r.top, r.width(), r.height(), w.SWP_NOZORDER | w.SWP_NOACTIVATE);
                win.updateSize(false);
                if (win.ti_enabled) win.placeIme();
                return 0;
            },
            w.WM_SETCURSOR => {
                // Only our client area: child windows (WebView2) keep their own cursor.
                if (w.loword(lp) == w.HTCLIENT and wp == @intFromPtr(win.hwnd)) {
                    if (win.cursor_handle == null and win.cursor != .hidden) {
                        win.cursor_handle = w.LoadCursorW(null, w.makeIntResource(win.cursor.systemCursor()));
                    }
                    _ = w.SetCursor(win.cursor_handle);
                    return w.TRUE;
                }
                return null;
            },
            w.WM_ENTERSIZEMOVE, w.WM_ENTERMENULOOP => {
                app.modal_depth += 1;
                _ = w.SetTimer(win.hwnd, modal_timer_id, w.USER_TIMER_MINIMUM, null);
                return null;
            },
            w.WM_EXITSIZEMOVE, w.WM_EXITMENULOOP => {
                _ = w.KillTimer(win.hwnd, modal_timer_id);
                if (app.modal_depth > 0) app.modal_depth -= 1;
                return null;
            },
            w.WM_TIMER => {
                if (wp == modal_timer_id) {
                    app.runModalCallback();
                    return 0;
                }
                return null;
            },
            w.WM_SETTINGCHANGE => {
                if (lp != 0) {
                    const s: [*:0]const u16 = @ptrFromInt(@as(usize, @bitCast(lp)));
                    if (std.mem.eql(u16, std.mem.span(s), w.L("ImmersiveColorSet"))) app.onThemeSetting();
                }
                return null;
            },
            w.WM_SETFOCUS => {
                app.kb_focus = win;
                return win.translateInput(msg, wp, lp);
            },
            w.WM_KILLFOCUS => {
                if (app.kb_focus == win) app.kb_focus = null;
                return win.translateInput(msg, wp, lp);
            },
            w.WM_MOUSEMOVE => {
                if (app.ptr_window != win) {
                    if (app.ptr_window) |old| if (app.input.ptr_inside) {
                        app.push(.{ .mouse_leave = .{ .window = old.id } });
                    };
                    app.input.ptr_inside = false;
                    app.ptr_window = win;
                }
                const r = win.translateInput(msg, wp, lp);
                return r;
            },
            w.WM_MOUSELEAVE => {
                if (app.ptr_window != win) return 0;
                return win.translateInput(msg, wp, lp);
            },
            else => return win.translateInput(msg, wp, lp),
        }
    }

    fn translateInput(win: *Window, msg: u32, wp: w.WPARAM, lp: w.LPARAM) ?w.LRESULT {
        var h: Host = .{ .app = win.app, .win = win };
        return switch (win.app.input.handle(&h, win.info(), msg, wp, lp)) {
            .default => null,
            .default_lparam => |l| w.DefWindowProcW(win.hwnd, msg, wp, l),
            .handled => |v| v,
        };
    }
};

fn wndProc(hwnd: w.HWND, msg: w.UINT, wp: w.WPARAM, lp: w.LPARAM) callconv(w.WINAPI) w.LRESULT {
    if (msg == w.WM_NCCREATE) {
        const cs: *const w.CREATESTRUCTW = @ptrFromInt(@as(usize, @bitCast(lp)));
        if (cs.lpCreateParams) |p| {
            const win: *Window = @ptrCast(@alignCast(p));
            win.hwnd = hwnd;
            _ = w.SetWindowLongPtrW(hwnd, w.GWLP_USERDATA, @bitCast(@intFromPtr(win)));
        }
        return w.DefWindowProcW(hwnd, msg, wp, lp);
    }
    const ud = w.GetWindowLongPtrW(hwnd, w.GWLP_USERDATA);
    if (ud == 0) return w.DefWindowProcW(hwnd, msg, wp, lp);
    const win: *Window = @ptrFromInt(@as(usize, @bitCast(ud)));
    if (win.handleMessage(msg, wp, lp)) |r| return r;
    return w.DefWindowProcW(hwnd, msg, wp, lp);
}

fn msgWndProc(hwnd: w.HWND, msg: w.UINT, wp: w.WPARAM, lp: w.LPARAM) callconv(w.WINAPI) w.LRESULT {
    if (msg == w.WM_NCCREATE) {
        const cs: *const w.CREATESTRUCTW = @ptrFromInt(@as(usize, @bitCast(lp)));
        _ = w.SetWindowLongPtrW(hwnd, w.GWLP_USERDATA, @bitCast(@intFromPtr(cs.lpCreateParams)));
        return w.DefWindowProcW(hwnd, msg, wp, lp);
    }
    const ud = w.GetWindowLongPtrW(hwnd, w.GWLP_USERDATA);
    if (ud == 0) return w.DefWindowProcW(hwnd, msg, wp, lp);
    const app: *App = @ptrFromInt(@as(usize, @bitCast(ud)));
    switch (msg) {
        WM_PALETTE_WAKE => {
            app.drainWakeups();
            return 0;
        },
        WM_PALETTE_QUIT => {
            if (app.quit_pending.swap(false, .acq_rel)) app.push(.quit);
            return 0;
        },
        w.WM_CLIPBOARDUPDATE => {
            app.onClipboardUpdate();
            return 0;
        },
        else => return w.DefWindowProcW(hwnd, msg, wp, lp),
    }
}

fn readSystemTheme() SystemTheme {
    var v: w.DWORD = 0;
    var size: w.DWORD = @sizeOf(w.DWORD);
    const rc = w.RegGetValueW(w.HKEY_CURRENT_USER, w.L("Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize"), w.L("AppsUseLightTheme"), w.RRF_RT_REG_DWORD, null, &v, &size);
    if (rc != w.ERROR_SUCCESS) return .unknown;
    return if (v == 0) .dark else .light;
}

/// UTF-8 → UTF-16 with LF → CRLF (an existing CRLF stays).
pub fn clipboardUtf16(gpa: std.mem.Allocator, text: []const u8) ![]u16 {
    var out: std.ArrayList(u16) = .empty;
    errdefer out.deinit(gpa);
    try out.ensureTotalCapacity(gpa, text.len + 8);
    var prev: u21 = 0;
    var i: usize = 0;
    while (i < text.len) {
        var cp: u21 = 0xFFFD;
        var adv: usize = 1;
        if (std.unicode.utf8ByteSequenceLength(text[i])) |len| {
            if (i + len <= text.len) {
                if (std.unicode.utf8Decode(text[i..][0..len])) |c| {
                    cp = c;
                    adv = len;
                } else |_| {}
            }
        } else |_| {}
        if (cp == '\n' and prev != '\r') try out.append(gpa, '\r');
        if (cp >= 0x10000) {
            const v = cp - 0x10000;
            try out.append(gpa, @intCast(0xD800 + (v >> 10)));
            try out.append(gpa, @intCast(0xDC00 + (v & 0x3FF)));
        } else try out.append(gpa, @intCast(cp));
        prev = cp;
        i += adv;
    }
    return out.toOwnedSlice(gpa);
}

fn monotonicNs() u64 {
    var c: i64 = 0;
    var f: i64 = 1;
    _ = w.QueryPerformanceCounter(&c);
    _ = w.QueryPerformanceFrequency(&f);
    const cu: u128 = @intCast(c);
    return @intCast(cu * std.time.ns_per_s / @as(u128, @intCast(@max(f, 1))));
}

test "cursor mapping" {
    try std.testing.expectEqual(w.IDC_IBEAM, CursorShape.text.systemCursor());
    try std.testing.expectEqual(w.IDC_HAND, CursorShape.pointer.systemCursor());
    try std.testing.expectEqual(w.IDC_SIZEWE, CursorShape.col_resize.systemCursor());
    try std.testing.expectEqual(w.IDC_SIZENESW, CursorShape.sw_resize.systemCursor());
    try std.testing.expectEqual(@as(usize, 0), CursorShape.hidden.systemCursor());
    try std.testing.expectEqual(w.IDC_ARROW, CursorShape.default.systemCursor());
}

test "clipboard LF to CRLF" {
    const a = std.testing.allocator;
    const u = try clipboardUtf16(a, "a\nb\r\nc\u{1F600}");
    defer a.free(u);
    try std.testing.expectEqualSlices(u16, &.{ 'a', '\r', '\n', 'b', '\r', '\n', 'c', 0xD83D, 0xDE00 }, u);
    const bad = try clipboardUtf16(a, "x\xffy");
    defer a.free(bad);
    try std.testing.expectEqualSlices(u16, &.{ 'x', 0xFFFD, 'y' }, bad);
}
