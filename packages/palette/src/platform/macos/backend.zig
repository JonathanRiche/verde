//! AppKit backend: App (NSApplication, event queue) and Window (NSWindow + layer-backed
//! NSView whose backing layer is a CAMetalLayer).
//!
//! No SDK, nib or bundle: libobjc and the frameworks are dlopened (`objc.zig`) and the three
//! classes Palette needs are registered at runtime. See README.md in this directory.
//!
//! Threading: everything except `App.wakeup` must be called from the main thread (AppKit's
//! rule). One App per process.
//!
//! Event flow: `pump` drains `-[NSApplication nextEventMatchingMask:...]` (blocking for the
//! first event up to the timeout), translates key/flags events itself and forwards every
//! event to `-[NSApplication sendEvent:]`, which reaches the view's mouse methods, the
//! window delegate and the menus. Callbacks that can fire while the pump is blocked inside
//! AppKit (display link, appearance KVO, signal sources) post an application-defined event
//! so `nextEventMatchingMask` returns. Text payloads live in a 16 KiB arena that is reset when
//! the queue drains, as on Wayland.
//!
//! Known limitation (shared with SDL): during a live window resize or a modal menu AppKit
//! runs its own tracking loop inside `sendEvent:`, so `waitEvent` does not return until the
//! user lets go; `resized` events queue up meanwhile.

const std = @import("std");
const builtin = @import("builtin");

const objc = @import("objc.zig");
const keys = @import("keys.zig");
const text_input = @import("text_input.zig");
const clock = @import("../../clock.zig");
const ev = @import("../../event.zig");
const Event = ev.Event;
const Id = objc.Id;
const send = objc.send;

const log = std.log.scoped(.macos);

pub const Rect = @import("../../draw.zig").Rect;

pub const max_windows = 16;
const queue_capacity = 256;
const queue_reserve = 16;
const text_capacity = 16 * 1024;
const wakeup_capacity = 256;
/// `-[NSEvent subtype]` / `data1` of Palette's wake event.
const wake_subtype: i16 = 0x504e;
const wake_magic: objc.NSInteger = 0x50616c6574746557;
const clipboard_poll_ns = 500 * std.time.ns_per_ms;

pub const Error = objc.Error || error{
    TooManyWindows,
    Unsupported,
    WindowCreationFailed,
    OutOfMemory,
};

pub const ActivationPolicy = enum(objc.NSInteger) {
    /// Dock icon, menu bar, can be activated (a normal app).
    regular = 0,
    /// No dock icon or menu bar; windows can still be shown and focused by the user.
    accessory = 1,
    /// Never activated (background tool).
    prohibited = 2,
};

pub const AppOptions = struct {
    /// Application identifier. An id starting with `palette-test` forces the accessory
    /// activation policy and disables activation, so tests never steal focus.
    app_id: []const u8 = "palette",
    /// Unused on macOS (kept so hosts need no platform switch).
    environ: std.process.Environ = .empty,
    /// Turn SIGINT/SIGTERM into `Event.quit` (dispatch signal sources; the default handlers
    /// are set to SIG_IGN while the App lives).
    handle_signals: bool = false,
    activation_policy: ActivationPolicy = .regular,
    /// Activate the app (bring it to the front) when the first window is shown. Unbundled
    /// executables are not activated by the system on launch, so a GUI app wants this.
    activate: bool = true,
    /// Windows: ICON resource id in the executable used for the title bar,
    /// Alt+Tab and taskbar window icon (0 = none). Ignored elsewhere.
    icon_resource_id: u16 = 0,
};

pub const SystemTheme = enum { unknown, light, dark };

pub const Decorations = enum {
    /// Standard title bar.
    server,
    /// Content extends under a transparent title bar (traffic lights stay); the app draws the
    /// rest.
    client,
};

pub const WindowOptions = struct {
    title: []const u8 = "Palette",
    width: u32 = 800,
    height: u32 = 600,
    min_width: u32 = 0,
    min_height: u32 = 0,
    resizable: bool = true,
    /// Unused on macOS.
    app_id: ?[]const u8 = null,
    decorations: Decorations = .server,
    /// A click that activates an inactive window is also delivered as a button event
    /// (`acceptsFirstMouse:`). Off by default, like SDL.
    accepts_first_mouse: bool = false,
};

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
};

pub const Size = struct { width: u32, height: u32 };

pub const NativeHandles = struct {
    /// `NSWindow *` (PaletteNativeWindow).
    ns_window: *anyopaque,
    /// `NSView *` (PaletteNativeView, the content view; layer-backed).
    ns_view: *anyopaque,
    /// `CAMetalLayer *`, the view's backing layer.
    metal_layer: ?*anyopaque,
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

// ---- AppKit constants -------------------------------------------------------------------------

const NSEventType = struct {
    const left_mouse_down = 1;
    const left_mouse_up = 2;
    const right_mouse_down = 3;
    const right_mouse_up = 4;
    const mouse_moved = 5;
    const left_mouse_dragged = 6;
    const right_mouse_dragged = 7;
    const key_down = 10;
    const key_up = 11;
    const flags_changed = 12;
    const application_defined = 15;
    const scroll_wheel = 22;
    const other_mouse_down = 25;
    const other_mouse_up = 26;
    const other_mouse_dragged = 27;
};

const style_titled: objc.NSUInteger = 1 << 0;
const style_closable: objc.NSUInteger = 1 << 1;
const style_miniaturizable: objc.NSUInteger = 1 << 2;
const style_resizable: objc.NSUInteger = 1 << 3;
const style_fullscreen: objc.NSUInteger = 1 << 14;
const style_full_size_content: objc.NSUInteger = 1 << 15;
const backing_buffered: objc.NSUInteger = 2;
const collection_fullscreen_primary: objc.NSUInteger = 1 << 7;
const occlusion_visible: objc.NSUInteger = 1 << 1;
const terminate_cancel: objc.NSUInteger = 0;

const tracking_options: objc.NSUInteger = 0x01 | 0x02 | 0x04 | 0x80 | 0x200;

const enc_rect = "{CGRect={CGPoint=dd}{CGSize=dd}}";
const enc_range = "{_NSRange=QQ}";

// ---- dispatch (signal sources) ------------------------------------------------------------------

const Dispatch = struct {
    source_create: *const fn (*const anyopaque, usize, usize, *anyopaque) callconv(.c) ?*anyopaque,
    set_handler: *const fn (*anyopaque, *const fn (?*anyopaque) callconv(.c) void) callconv(.c) void,
    set_context: *const fn (*anyopaque, ?*anyopaque) callconv(.c) void,
    @"resume": *const fn (*anyopaque) callconv(.c) void,
    cancel: *const fn (*anyopaque) callconv(.c) void,
    release: *const fn (*anyopaque) callconv(.c) void,
    signal_type: *const anyopaque,
    main_q: *anyopaque,
    signal: *const fn (c_int, usize) callconv(.c) usize,

    fn load() ?Dispatch {
        return .{
            .source_create = objc.cSymbol(@FieldType(Dispatch, "source_create"), "dispatch_source_create") orelse return null,
            .set_handler = objc.cSymbol(@FieldType(Dispatch, "set_handler"), "dispatch_source_set_event_handler_f") orelse return null,
            .set_context = objc.cSymbol(@FieldType(Dispatch, "set_context"), "dispatch_set_context") orelse return null,
            .@"resume" = objc.cSymbol(@FieldType(Dispatch, "resume"), "dispatch_resume") orelse return null,
            .cancel = objc.cSymbol(@FieldType(Dispatch, "cancel"), "dispatch_source_cancel") orelse return null,
            .release = objc.cSymbol(@FieldType(Dispatch, "release"), "dispatch_release") orelse return null,
            .signal_type = objc.cSymbol(*const anyopaque, "_dispatch_source_type_signal") orelse return null,
            .main_q = objc.cSymbol(*anyopaque, "_dispatch_main_q") orelse return null,
            .signal = objc.cSymbol(@FieldType(Dispatch, "signal"), "signal") orelse return null,
        };
    }
};

const SIGINT: c_int = 2;
const SIGTERM: c_int = 15;
const SIG_DFL: usize = 0;
const SIG_IGN: usize = 1;

// ---- runtime classes ------------------------------------------------------------------------

const Classes = struct {
    view: objc.Class,
    window: objc.Class,
    delegate: objc.Class,
    helper: objc.Class,
};
var classes: ?Classes = null;
var launched = false;

/// The App of this process (AppKit has one NSApplication).
var g_app: ?*App = null;

const ivar_name = "pn_ptr";

fn windowOf(self: Id) ?*Window {
    const p = objc.ivarPtr(self, ivar_name).* orelse return null;
    return @ptrCast(@alignCast(p));
}

fn registerClasses() !Classes {
    if (classes) |c| return c;
    const view = blk: {
        const b = (try objc.ClassBuilder.begin("NSView", "PaletteNativeView")) orelse break :blk objc.class("PaletteNativeView");
        b.pointerIvar(ivar_name);
        b.method("makeBackingLayer", &View.makeBackingLayer, "@@:");
        b.method("wantsUpdateLayer", &View.yes, "c@:");
        b.method("isFlipped", &View.yes, "c@:");
        b.method("isOpaque", &View.yes, "c@:");
        b.method("acceptsFirstResponder", &View.yes, "c@:");
        b.method("acceptsFirstMouse:", &View.acceptsFirstMouse, "c@:@");
        b.method("keyDown:", &View.ignoreEvent, "v@:@");
        b.method("keyUp:", &View.ignoreEvent, "v@:@");
        b.method("flagsChanged:", &View.ignoreEvent, "v@:@");
        b.method("mouseDown:", &View.mouseDown, "v@:@");
        b.method("rightMouseDown:", &View.mouseDown, "v@:@");
        b.method("otherMouseDown:", &View.mouseDown, "v@:@");
        b.method("mouseUp:", &View.mouseUp, "v@:@");
        b.method("rightMouseUp:", &View.mouseUp, "v@:@");
        b.method("otherMouseUp:", &View.mouseUp, "v@:@");
        b.method("mouseMoved:", &View.mouseMoved, "v@:@");
        b.method("mouseDragged:", &View.mouseMoved, "v@:@");
        b.method("rightMouseDragged:", &View.mouseMoved, "v@:@");
        b.method("otherMouseDragged:", &View.mouseMoved, "v@:@");
        b.method("scrollWheel:", &View.scrollWheel, "v@:@");
        b.method("mouseEntered:", &View.mouseEntered, "v@:@");
        b.method("mouseExited:", &View.mouseExited, "v@:@");
        b.method("cursorUpdate:", &View.cursorUpdate, "v@:@");
        b.method("updateTrackingAreas", &View.updateTrackingAreas, "v@:");
        b.method("viewDidChangeBackingProperties", &View.backingChanged, "v@:");
        // NSTextInputClient
        b.method("hasMarkedText", &View.hasMarkedText, "c@:");
        b.method("markedRange", &View.markedRange, enc_range ++ "@:");
        b.method("selectedRange", &View.selectedRange, enc_range ++ "@:");
        b.method("setMarkedText:selectedRange:replacementRange:", &View.setMarkedText, "v@:@" ++ enc_range ++ enc_range);
        b.method("unmarkText", &View.unmarkText, "v@:");
        b.method("validAttributesForMarkedText", &View.validAttributes, "@@:");
        b.method("attributedSubstringForProposedRange:actualRange:", &View.attributedSubstring, "@@:" ++ enc_range ++ "^" ++ enc_range);
        b.method("insertText:replacementRange:", &View.insertTextRange, "v@:@" ++ enc_range);
        b.method("insertText:", &View.insertText, "v@:@");
        b.method("characterIndexForPoint:", &View.characterIndex, "Q@:{CGPoint=dd}");
        b.method("firstRectForCharacterRange:actualRange:", &View.firstRect, enc_rect ++ "@:" ++ enc_range ++ "^" ++ enc_range);
        b.method("doCommandBySelector:", &View.doCommand, "v@::");
        b.protocol("NSTextInputClient");
        break :blk b.register();
    };
    const window = blk: {
        const b = (try objc.ClassBuilder.begin("NSWindow", "PaletteNativeWindow")) orelse break :blk objc.class("PaletteNativeWindow");
        b.method("canBecomeKeyWindow", &View.yes, "c@:");
        b.method("canBecomeMainWindow", &View.yes, "c@:");
        break :blk b.register();
    };
    const delegate = blk: {
        const b = (try objc.ClassBuilder.begin("NSObject", "PaletteNativeWindowDelegate")) orelse break :blk objc.class("PaletteNativeWindowDelegate");
        b.pointerIvar(ivar_name);
        b.method("windowShouldClose:", &Delegate.shouldClose, "c@:@");
        b.method("windowDidResize:", &Delegate.didResize, "v@:@");
        b.method("windowDidChangeBackingProperties:", &Delegate.didResize, "v@:@");
        b.method("windowDidBecomeKey:", &Delegate.didBecomeKey, "v@:@");
        b.method("windowDidResignKey:", &Delegate.didResignKey, "v@:@");
        b.method("windowDidMiniaturize:", &Delegate.visibilityChanged, "v@:@");
        b.method("windowDidDeminiaturize:", &Delegate.visibilityChanged, "v@:@");
        b.method("windowDidChangeOcclusionState:", &Delegate.visibilityChanged, "v@:@");
        b.method("windowDidEnterFullScreen:", &Delegate.didResize, "v@:@");
        b.method("windowDidExitFullScreen:", &Delegate.didResize, "v@:@");
        b.method("paletteFrame:", &Delegate.frameFired, "v@:@");
        b.protocol("NSWindowDelegate");
        break :blk b.register();
    };
    const helper = blk: {
        const b = (try objc.ClassBuilder.begin("NSObject", "PaletteNativeAppHelper")) orelse break :blk objc.class("PaletteNativeAppHelper");
        b.method("observeValueForKeyPath:ofObject:change:context:", &Helper.observe, "v@:@@@^v");
        b.method("applicationShouldTerminate:", &Helper.shouldTerminate, "Q@:@");
        b.method("applicationShouldTerminateAfterLastWindowClosed:", &Helper.no, "c@:@");
        b.protocol("NSApplicationDelegate");
        break :blk b.register();
    };
    const c: Classes = .{ .view = view, .window = window, .delegate = delegate, .helper = helper };
    classes = c;
    return c;
}

// ---- event queue sink for the IME state machine ----------------------------------------------

const ImeSink = struct {
    app: *App,
    w: *Window,

    pub fn key(s: ImeSink, k: ev.KeyEvent) void {
        var kk = k;
        kk.window = s.w.id;
        s.app.push(if (kk.down) .{ .key_down = kk } else .{ .key_up = kk });
    }

    pub fn text(s: ImeSink, t: []const u8) void {
        const stored = s.app.storeText(t) orelse return;
        s.app.push(.{ .text_input = .{ .window = s.w.id, .text = stored } });
    }

    pub fn edit(s: ImeSink, t: []const u8, b: i32, e: i32) void {
        const stored = s.app.storeText(t) orelse return;
        s.app.push(.{ .text_editing = .{ .window = s.w.id, .text = stored, .cursor_begin = if (t.len == 0) -1 else b, .cursor_end = if (t.len == 0) -1 else e } });
    }
};
const Ime = text_input.Ime(ImeSink);

// ---- App ----------------------------------------------------------------------------------------

pub const App = struct {
    gpa: std.mem.Allocator,
    ns_app: Id,
    helper: Id,
    owns_delegate: bool = false,
    observing_theme: bool = false,
    app_id_buf: [128]u8 = undefined,
    app_id_len: usize = 0,
    policy: ActivationPolicy = .regular,
    allow_activation: bool = true,
    activated_once: bool = false,

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
    /// A wake NSEvent is in AppKit's queue (cleared when the pump sees it).
    wake_posted: std.atomic.Value(bool) = .init(false),

    mods: ev.Mods = .{},
    mod_keys: ev.ModKeys = .{},
    kb_focus: u32 = 0,
    ptr_focus: u32 = 0,
    iso_keyboard: bool = false,
    cursor_hidden: bool = false,

    clip_change_count: objc.NSInteger = 0,
    clip_checked_ns: u64 = 0,
    theme: SystemTheme = .unknown,

    dispatch: ?Dispatch = null,
    signal_sources: [2]?*anyopaque = .{ null, null },

    // Cached constants.
    run_loop_default: Id = undefined,
    run_loop_common: Id = undefined,
    pasteboard_string: ?Id = null,

    // -- lifecycle ------------------------------------------------------------------------------

    pub fn init(gpa: std.mem.Allocator, options: AppOptions) !*App {
        if (g_app != null) return error.Unsupported;
        try objc.load();
        if (objc.frameworks.appkit == null) return error.FrameworkUnavailable;
        const cls = try registerClasses();
        const pool = objc.Pool.push();
        defer pool.pop();

        const app = try gpa.create(App);
        errdefer gpa.destroy(app);
        const ns_app = send(Id, objc.class("NSApplication"), "sharedApplication", .{});
        app.* = .{ .gpa = gpa, .ns_app = ns_app, .helper = objc.new(cls.helper) };
        app.app_id_len = @min(options.app_id.len, app.app_id_buf.len);
        @memcpy(app.app_id_buf[0..app.app_id_len], options.app_id[0..app.app_id_len]);
        app.policy = options.activation_policy;
        app.allow_activation = options.activate;
        if (isTestId(options.app_id)) {
            app.policy = .accessory;
            app.allow_activation = false;
        }
        if (app.policy == .prohibited) app.allow_activation = false;

        app.run_loop_default = objc.stringConstant("NSDefaultRunLoopMode") orelse objc.retain(objc.nsString("kCFRunLoopDefaultMode"));
        app.run_loop_common = objc.stringConstant("NSRunLoopCommonModes") orelse objc.retain(objc.nsString("kCFRunLoopCommonModes"));
        app.pasteboard_string = objc.stringConstant("NSPasteboardTypeString");
        var pb_name_buf: [160]u8 = undefined;
        if (privatePasteboardName(&pb_name_buf, options.app_id)) |name| {
            private_pasteboard = objc.retain(send(Id, objc.class("NSPasteboard"), "pasteboardWithName:", .{objc.nsString(name)}));
        }

        _ = send(objc.BOOL, ns_app, "setActivationPolicy:", .{@intFromEnum(app.policy)});
        send(void, objc.class("NSWindow"), "setAllowsAutomaticWindowTabbing:", .{objc.NO});
        if (send(?Id, ns_app, "delegate", .{}) == null) {
            send(void, ns_app, "setDelegate:", .{app.helper});
            app.owns_delegate = true;
        }
        if (!launched) {
            if (app.policy == .regular and send(?Id, ns_app, "mainMenu", .{}) == null) buildMenu(ns_app, app.appId());
            send(void, ns_app, "finishLaunching", .{});
            launched = true;
        }

        if (objc.respondsTo(ns_app, "effectiveAppearance")) {
            send(void, ns_app, "addObserver:forKeyPath:options:context:", .{ app.helper, objc.nsString("effectiveAppearance"), @as(objc.NSUInteger, 1), @as(?*anyopaque, null) });
            app.observing_theme = true;
        }
        app.theme = readTheme(ns_app);
        app.iso_keyboard = detectIso();
        app.clip_change_count = send(objc.NSInteger, pasteboard(), "changeCount", .{});
        app.clip_checked_ns = clock.monotonicTimestampNs();
        g_app = app;
        if (options.handle_signals) app.installSignals();
        return app;
    }

    pub fn deinit(app: *App) void {
        const pool = objc.Pool.push();
        defer pool.pop();
        for (app.windows) |w| if (w) |win| win.destroy();
        if (app.cursor_hidden) {
            send(void, objc.class("NSCursor"), "unhide", .{});
            app.cursor_hidden = false;
        }
        if (app.dispatch) |d| {
            for (&app.signal_sources, [_]c_int{ SIGINT, SIGTERM }) |*s, sig| if (s.*) |src| {
                d.cancel(src);
                d.release(src);
                _ = d.signal(sig, SIG_DFL);
                s.* = null;
            };
        }
        if (app.observing_theme) send(void, app.ns_app, "removeObserver:forKeyPath:", .{ app.helper, objc.nsString("effectiveAppearance") });
        if (app.owns_delegate) send(void, app.ns_app, "setDelegate:", .{@as(?Id, null)});
        objc.release(app.helper);
        if (private_pasteboard) |pb| {
            send(void, pb, "releaseGlobally", .{});
            objc.release(pb);
            private_pasteboard = null;
        }
        g_app = null;
        app.gpa.destroy(app);
    }

    fn appId(app: *const App) []const u8 {
        return app.app_id_buf[0..app.app_id_len];
    }

    pub fn globals(app: *const App) []const GlobalInfo {
        _ = app;
        return &.{};
    }

    fn installSignals(app: *App) void {
        const d = Dispatch.load() orelse {
            log.warn("libdispatch symbols missing; handle_signals ignored", .{});
            return;
        };
        app.dispatch = d;
        for (&app.signal_sources, [_]c_int{ SIGINT, SIGTERM }) |*s, sig| {
            _ = d.signal(sig, SIG_IGN);
            const src = d.source_create(d.signal_type, @intCast(sig), 0, d.main_q) orelse continue;
            d.set_context(src, app);
            d.set_handler(src, &onSignal);
            d.@"resume"(src);
            s.* = src;
        }
    }

    fn onSignal(ctx: ?*anyopaque) callconv(.c) void {
        const app: *App = @ptrCast(@alignCast(ctx orelse return));
        app.push(.quit);
        app.postWake();
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

    pub fn pollEvent(app: *App, out: *Event) bool {
        if (app.pop(out)) return true;
        app.text_len = 0;
        app.pump(0);
        return app.pop(out);
    }

    /// Blocks until an event arrives or `timeout_ns` elapses (null = forever). Returns false
    /// on timeout.
    pub fn waitEvent(app: *App, out: *Event, timeout_ns: ?u64) bool {
        if (app.pop(out)) return true;
        app.text_len = 0;
        const deadline: ?u64 = if (timeout_ns) |t| clock.monotonicTimestampNs() +| t else null;
        while (true) {
            var remaining: ?u64 = null;
            if (deadline) |d| {
                const now = clock.monotonicTimestampNs();
                remaining = if (now >= d) 0 else d - now;
            }
            app.pump(remaining);
            if (app.pop(out)) return true;
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
        app.postWake();
    }

    /// Makes a blocked `nextEventMatchingMask` return (any thread). At most one wake event is
    /// in flight.
    fn postWake(app: *App) void {
        if (app.wake_posted.swap(true, .acq_rel)) return;
        const pool = objc.Pool.push();
        defer pool.pop();
        const e = send(?Id, objc.class("NSEvent"), "otherEventWithType:location:modifierFlags:timestamp:windowNumber:context:subtype:data1:data2:", .{
            @as(objc.NSUInteger, NSEventType.application_defined), objc.NSPoint{},       @as(objc.NSUInteger, 0),
            @as(f64, 0),                                            @as(objc.NSInteger, 0), @as(?Id, null),
            wake_subtype,                                           wake_magic,          @as(objc.NSInteger, 0),
        }) orelse {
            app.wake_posted.store(false, .release);
            return;
        };
        send(void, app.ns_app, "postEvent:atStart:", .{ e, objc.NO });
    }

    fn drainWakeups(app: *App) void {
        var local: [wakeup_capacity]u64 = undefined;
        while (app.wake_lock.cmpxchgWeak(0, 1, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
        const n = @min(app.wake_len, queue_capacity - app.q_len);
        @memcpy(local[0..n], app.wake_ring[0..n]);
        std.mem.copyForwards(u64, app.wake_ring[0 .. app.wake_len - n], app.wake_ring[n..app.wake_len]);
        app.wake_len -= n;
        const left = app.wake_len;
        app.wake_lock.store(0, .release);
        for (local[0..n]) |v| app.push(.{ .user = v });
        if (left > 0) app.postWake();
    }

    fn pump(app: *App, timeout_ns: ?u64) void {
        const pool = objc.Pool.push();
        defer pool.pop();
        const date_cls = objc.class("NSDate");
        var first = app.q_len == 0;
        while (app.q_len + queue_reserve <= queue_capacity) {
            const date: Id = if (!first)
                send(Id, date_cls, "distantPast", .{})
            else if (timeout_ns) |t|
                (if (t == 0) send(Id, date_cls, "distantPast", .{}) else send(Id, date_cls, "dateWithTimeIntervalSinceNow:", .{@as(f64, @floatFromInt(t)) / std.time.ns_per_s}))
            else
                send(Id, date_cls, "distantFuture", .{});
            first = false;
            const e = send(?Id, app.ns_app, "nextEventMatchingMask:untilDate:inMode:dequeue:", .{ @as(objc.NSUInteger, std.math.maxInt(objc.NSUInteger)), date, app.run_loop_default, objc.YES }) orelse break;
            app.dispatchEvent(e);
        }
        const now = clock.monotonicTimestampNs();
        if (now -% app.clip_checked_ns >= clipboard_poll_ns) app.checkClipboard();
    }

    fn dispatchEvent(app: *App, e: Id) void {
        const t = send(objc.NSUInteger, e, "type", .{});
        switch (t) {
            NSEventType.application_defined => if (send(i16, e, "subtype", .{}) == wake_subtype and send(objc.NSInteger, e, "data1", .{}) == wake_magic) {
                app.wake_posted.store(false, .release);
                app.drainWakeups();
                return;
            },
            NSEventType.key_down, NSEventType.key_up => app.handleKey(e, null),
            NSEventType.flags_changed => app.handleFlags(e, null),
            else => {},
        }
        send(void, app.ns_app, "sendEvent:", .{e});
    }

    fn windowForNs(app: *App, ns_window: ?Id) ?*Window {
        const nw = ns_window orelse return null;
        for (app.windows) |w| if (w) |win| if (win.ns_window == nw) return win;
        return null;
    }

    fn windowFromTag(app: *const App, tag: u32) ?*Window {
        if (tag == 0 or tag > max_windows) return null;
        return app.windows[tag - 1];
    }

    /// keyDown/keyUp. `forced`: test injection (bypasses the keyboard-focus gate).
    fn handleKey(app: *App, e: Id, forced: ?*Window) void {
        const w = forced orelse app.windowForNs(send(?Id, e, "window", .{})) orelse app.windowFromTag(app.kb_focus) orelse return;
        const down = send(objc.NSUInteger, e, "type", .{}) == NSEventType.key_down;
        const code = keys.normalizeIso(send(u16, e, "keyCode", .{}), app.iso_keyboard);
        const flags: u64 = send(objc.NSUInteger, e, "modifierFlags", .{});
        const chars = objc.utf8(send(?Id, e, "characters", .{}));
        const base = if (objc.respondsTo(e, "charactersByApplyingModifiers:"))
            objc.utf8(send(?Id, e, "charactersByApplyingModifiers:", .{@as(objc.NSUInteger, 0)}))
        else
            objc.utf8(send(?Id, e, "charactersIgnoringModifiers", .{}));
        const repeat = send(objc.BOOL, e, "isARepeat", .{}) != 0;
        var k = keys.keyEvent(code, chars, base, flags, down, repeat);
        k.window = w.id;
        app.mods = keys.modsFromFlags(flags);
        if (!down) return app.push(.{ .key_up = k });
        if (forced == null and !w.hasKeyboardFocus()) return;
        if (w.ti_enabled) {
            const sink: ImeSink = .{ .app = app, .w = w };
            w.ime.beginKeyDown(k);
            send(void, w.view, "interpretKeyEvents:", .{send(Id, objc.class("NSArray"), "arrayWithObject:", .{e})});
            w.ime.endKeyDown(sink);
        } else app.push(.{ .key_down = k });
    }

    fn handleFlags(app: *App, e: Id, forced: ?*Window) void {
        const w = forced orelse app.windowForNs(send(?Id, e, "window", .{})) orelse app.windowFromTag(app.kb_focus);
        const flags: u64 = send(objc.NSUInteger, e, "modifierFlags", .{});
        app.syncModifiers(flags, if (w) |win| win.id else .invalid, true);
    }

    fn syncModifiers(app: *App, flags: u64, window: ev.WindowId, emit: bool) void {
        const new = keys.modKeysFromFlags(flags);
        var buf: [8]keys.ModChange = undefined;
        const changes = keys.modifierChanges(app.mod_keys, new, &buf);
        app.mod_keys = new;
        app.mods = keys.modsFromFlags(flags);
        if (!emit) return;
        for (changes) |c| {
            var k = keys.keyEvent(c.mac_code, "", "", flags, c.down, false);
            k.window = window;
            app.push(if (c.down) .{ .key_down = k } else .{ .key_up = k });
        }
    }

    fn checkClipboard(app: *App) void {
        app.clip_checked_ns = clock.monotonicTimestampNs();
        const count = send(objc.NSInteger, pasteboard(), "changeCount", .{});
        if (count == app.clip_change_count) return;
        app.clip_change_count = count;
        const win = app.windowFromTag(app.kb_focus);
        app.push(.{ .clipboard_update = .{ .window = if (win) |w| w.id else .invalid } });
    }

    fn themeChanged(app: *App) void {
        const t = readTheme(app.ns_app);
        if (t == app.theme) return;
        app.theme = t;
        app.push(.system_theme_changed);
        app.postWake();
    }

    // -- accessors ------------------------------------------------------------------------------

    pub fn modState(app: *const App) ev.Mods {
        return app.mods;
    }

    pub fn modKeys(app: *const App) ev.ModKeys {
        return app.mod_keys;
    }

    /// Flushes pending Core Animation transactions (the closest thing to SDL_SyncWindow).
    pub fn sync(app: *App) !void {
        _ = app;
        if (objc.getClass("CATransaction")) |c| send(void, c, "flush", .{});
    }

    pub fn pointerFocus(app: *const App) ?*Window {
        return app.windowFromTag(app.ptr_focus);
    }

    pub fn keyboardFocus(app: *const App) ?*Window {
        return app.windowFromTag(app.kb_focus);
    }

    /// From `-[NSApplication effectiveAppearance]`; changes arrive as
    /// `Event.system_theme_changed`.
    pub fn systemTheme(app: *const App) SystemTheme {
        return app.theme;
    }

    /// `-[NSScreen visibleFrame]` of the main screen (menu bar and Dock excluded), in points.
    pub fn usableBounds(app: *const App) ?Size {
        _ = app;
        const pool = objc.Pool.push();
        defer pool.pop();
        const screen = send(?Id, objc.class("NSScreen"), "mainScreen", .{}) orelse return null;
        const r = send(objc.NSRect, screen, "visibleFrame", .{});
        if (r.size.width <= 0 or r.size.height <= 0) return null;
        return .{ .width = @intFromFloat(r.size.width), .height = @intFromFloat(r.size.height) };
    }

    /// The main screen's `visibleFrame` (minus menu bar and Dock) in global top-left-origin
    /// points, the same coordinates as `Window.position` / `setPosition`.
    pub fn usableRect(app: *const App) ?Rect {
        _ = app;
        const pool = objc.Pool.push();
        defer pool.pop();
        const screen = send(?Id, objc.class("NSScreen"), "mainScreen", .{}) orelse return null;
        const r = send(objc.NSRect, screen, "visibleFrame", .{});
        if (r.size.width <= 0 or r.size.height <= 0) return null;
        const top = Window.primaryScreenHeight() - (r.origin.y + r.size.height);
        return .{ .x = @floatCast(r.origin.x), .y = @floatCast(top), .w = @floatCast(r.size.width), .h = @floatCast(r.size.height) };
    }

    pub fn setClipboardText(app: *App, text: []const u8) !void {
        const pool = objc.Pool.push();
        defer pool.pop();
        const pb = pasteboard();
        const ty = app.pasteboard_string orelse return error.Unsupported;
        _ = send(objc.NSInteger, pb, "clearContents", .{});
        if (send(objc.BOOL, pb, "setString:forType:", .{ objc.nsString(text), ty }) == 0) return error.Unsupported;
        // Our own change does not produce clipboard_update (SDL behaves the same).
        app.clip_change_count = send(objc.NSInteger, pb, "changeCount", .{});
    }

    /// Caller owns the returned slice. null = no text on the clipboard.
    pub fn getClipboardText(app: *App, allocator: std.mem.Allocator) !?[]u8 {
        const pool = objc.Pool.push();
        defer pool.pop();
        const ty = app.pasteboard_string orelse return null;
        const s = send(?Id, pasteboard(), "stringForType:", .{ty}) orelse return null;
        return try allocator.dupe(u8, objc.utf8(s));
    }

    /// Raw pasteboard bytes for one type. `mime` is a MIME type (`image/png`, `image/jpeg`,
    /// `image/tiff`, `text/plain;charset=utf-8`, `text/html`) or, failing that, used as a UTI
    /// verbatim (`public.png`, `com.adobe.pdf`, ...). Caller frees.
    pub fn getClipboardData(app: *App, allocator: std.mem.Allocator, mime: []const u8) !?[]u8 {
        _ = app;
        const pool = objc.Pool.push();
        defer pool.pop();
        const data = send(?Id, pasteboard(), "dataForType:", .{objc.nsString(utiForMime(mime))}) orelse return null;
        return try dupeData(allocator, data);
    }

    pub const ClipboardImage = struct {
        bytes: []u8,
        /// "image/png" or "image/jpeg" (static string).
        mime: []const u8,
    };

    /// The pasteboard's image, if any: PNG as is, then JPEG as is, then TIFF or anything
    /// `NSImage` can read (PDF, HEIC, file promises of images, ...) re-encoded as PNG.
    /// Same order as Verde's `macos_clipboard.m`. Caller frees `bytes`.
    pub fn getClipboardImage(app: *App, allocator: std.mem.Allocator) !?ClipboardImage {
        _ = app;
        const pool = objc.Pool.push();
        defer pool.pop();
        const pb = pasteboard();
        if (send(?Id, pb, "dataForType:", .{objc.nsString("public.png")})) |d| {
            if (try dupeData(allocator, d)) |b| return .{ .bytes = b, .mime = "image/png" };
        }
        if (send(?Id, pb, "dataForType:", .{objc.nsString("public.jpeg")})) |d| {
            if (try dupeData(allocator, d)) |b| return .{ .bytes = b, .mime = "image/jpeg" };
        }
        var image: ?Id = null;
        if (send(?Id, pb, "dataForType:", .{objc.nsString("public.tiff")})) |tiff| {
            image = send(?Id, send(Id, objc.class("NSImage"), "alloc", .{}), "initWithData:", .{tiff});
            if (image) |img| _ = send(Id, img, "autorelease", .{});
        }
        if (image == null) {
            const classes_arr = send(Id, objc.class("NSArray"), "arrayWithObject:", .{objc.class("NSImage")});
            const options = send(Id, objc.class("NSDictionary"), "dictionary", .{});
            if (send(?Id, pb, "readObjectsForClasses:options:", .{ classes_arr, options })) |arr| {
                image = send(?Id, arr, "firstObject", .{});
            }
        }
        const img = image orelse return null;
        const tiff = send(?Id, img, "TIFFRepresentation", .{}) orelse return null;
        const rep = send(?Id, objc.class("NSBitmapImageRep"), "imageRepWithData:", .{tiff}) orelse return null;
        const props = send(Id, objc.class("NSDictionary"), "dictionary", .{});
        const png = send(?Id, rep, "representationUsingType:properties:", .{ @as(objc.NSUInteger, 4), props }) orelse return null; // NSBitmapImageFileTypePNG
        const bytes = try dupeData(allocator, png) orelse return null;
        return .{ .bytes = bytes, .mime = "image/png" };
    }

    fn dupeData(allocator: std.mem.Allocator, data: Id) !?[]u8 {
        const len = send(objc.NSUInteger, data, "length", .{});
        if (len == 0) return null;
        const ptr = send([*]const u8, data, "bytes", .{});
        return try allocator.dupe(u8, ptr[0..len]);
    }

    /// macOS has no primary selection.
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

    // -- windows ----------------------------------------------------------------------------------

    pub fn createWindow(app: *App, options: WindowOptions) !*Window {
        const cls = classes.?;
        const pool = objc.Pool.push();
        defer pool.pop();
        const slot: u32 = for (app.windows, 0..) |w, i| {
            if (w == null) break @intCast(i);
        } else return error.TooManyWindows;
        const w = try app.gpa.create(Window);
        errdefer app.gpa.destroy(w);

        const lw: f64 = @floatFromInt(@max(1, @min(options.width, 1 << 15)));
        const lh: f64 = @floatFromInt(@max(1, @min(options.height, 1 << 15)));
        const rect = objc.NSRect.make(0, 0, lw, lh);
        var style = style_titled | style_closable | style_miniaturizable;
        if (options.resizable) style |= style_resizable;
        if (options.decorations == .client) style |= style_full_size_content;

        const ns_window = send(?Id, send(Id, cls.window, "alloc", .{}), "initWithContentRect:styleMask:backing:defer:", .{ rect, style, backing_buffered, objc.NO }) orelse return error.WindowCreationFailed;
        const view = send(?Id, send(Id, cls.view, "alloc", .{}), "initWithFrame:", .{rect}) orelse {
            objc.release(ns_window);
            return error.WindowCreationFailed;
        };
        const delegate = objc.new(cls.delegate);

        w.* = .{
            .app = app,
            .slot = slot,
            .id = @enumFromInt(app.next_window_id),
            .ns_window = ns_window,
            .view = view,
            .delegate = delegate,
            .resizable = options.resizable,
            .accepts_first_mouse = options.accepts_first_mouse,
        };
        app.next_window_id +%= 1;
        if (app.next_window_id == 0) app.next_window_id = 1;
        objc.ivarPtr(view, ivar_name).* = w;
        objc.ivarPtr(delegate, ivar_name).* = w;

        send(void, ns_window, "setReleasedWhenClosed:", .{objc.NO});
        if (objc.respondsTo(ns_window, "setRestorable:")) send(void, ns_window, "setRestorable:", .{objc.NO});
        send(void, ns_window, "setTitle:", .{objc.nsString(options.title)});
        send(void, ns_window, "setCollectionBehavior:", .{collection_fullscreen_primary});
        send(void, ns_window, "setAcceptsMouseMovedEvents:", .{objc.YES});
        if (options.decorations == .client) {
            send(void, ns_window, "setTitlebarAppearsTransparent:", .{objc.YES});
            send(void, ns_window, "setTitleVisibility:", .{@as(objc.NSInteger, 1)});
        }
        send(void, view, "setWantsLayer:", .{objc.YES});
        send(void, ns_window, "setContentView:", .{view});
        send(void, ns_window, "setDelegate:", .{delegate});
        send(void, ns_window, "makeFirstResponder:", .{view});
        w.setMinSize(options.min_width, options.min_height);
        if (!options.resizable) {
            send(void, ns_window, "setContentMaxSize:", .{objc.NSSize{ .width = lw, .height = lh }});
            send(void, ns_window, "setContentMinSize:", .{objc.NSSize{ .width = lw, .height = lh }});
        }
        send(void, ns_window, "center", .{});
        w.layer = send(?Id, view, "layer", .{});
        w.syncLayerScale();
        w.updateTrackingArea();
        w.createDisplayLink();

        app.windows[slot] = w;
        w.orderIn();
        _ = w.updateSize();
        return w;
    }
};

fn isTestId(id: []const u8) bool {
    return std.mem.startsWith(u8, id, "palette-test");
}

/// Test apps (`palette-test*` ids) get a private named pasteboard instead of the general one,
/// so live checks and trial runs never overwrite, or Universal-Clipboard-sync, the user's clipboard.
var private_pasteboard: ?Id = null;

fn pasteboard() Id {
    if (private_pasteboard) |pb| return pb;
    return send(Id, objc.class("NSPasteboard"), "generalPasteboard", .{});
}

/// The private pasteboard name for a test app id, or null for a real app (general pasteboard).
fn privatePasteboardName(buf: []u8, app_id: []const u8) ?[]const u8 {
    if (!isTestId(app_id)) return null;
    return std.fmt.bufPrint(buf, "{s}.pasteboard", .{app_id}) catch "palette-test.pasteboard";
}

/// MIME type -> pasteboard type (UTI). Unknown strings pass through (callers may give a UTI).
fn utiForMime(mime: []const u8) []const u8 {
    const map = [_][2][]const u8{
        .{ "image/png", "public.png" },
        .{ "image/jpeg", "public.jpeg" },
        .{ "image/tiff", "public.tiff" },
        .{ "image/gif", "com.compuserve.gif" },
        .{ "application/pdf", "com.adobe.pdf" },
        .{ "text/plain", "public.utf8-plain-text" },
        .{ "text/plain;charset=utf-8", "public.utf8-plain-text" },
        .{ "text/html", "public.html" },
        .{ "text/uri-list", "public.file-url" },
    };
    for (map) |m| if (std.ascii.eqlIgnoreCase(m[0], mime)) return m[1];
    return mime;
}

fn readTheme(ns_app: Id) SystemTheme {
    if (!objc.respondsTo(ns_app, "effectiveAppearance")) return .unknown;
    const appearance = send(?Id, ns_app, "effectiveAppearance", .{}) orelse return .unknown;
    const name = objc.utf8(send(?Id, appearance, "name", .{}));
    if (name.len == 0) return .unknown;
    return if (std.mem.indexOf(u8, name, "Dark") != null) .dark else .light;
}

/// Carbon's `KBGetLayoutType(LMGetKbdType()) == kKeyboardISO`, looked up at runtime (SDL
/// does the same to undo the ISO section/grave swap).
fn detectIso() bool {
    _ = objc.dlopen("/System/Library/Frameworks/Carbon.framework/Carbon", 1 | 8);
    const lm = objc.cSymbol(*const fn () callconv(.c) u8, "LMGetKbdType") orelse return false;
    const kb = objc.cSymbol(*const fn (i16) callconv(.c) u32, "KBGetLayoutType") orelse return false;
    const iso: u32 = ('I' << 24) | ('S' << 16) | ('O' << 8) | ' ';
    return kb(lm()) == iso;
}

fn buildMenu(ns_app: Id, app_name: []const u8) void {
    const menu_cls = objc.class("NSMenu");
    const item_cls = objc.class("NSMenuItem");
    const bar = objc.new(menu_cls);
    const app_menu = objc.new(menu_cls);
    const addItem = struct {
        fn f(m: Id, cls: objc.Class, title: []const u8, comptime action: [:0]const u8, key: []const u8) Id {
            const it = send(Id, send(Id, cls, "alloc", .{}), "initWithTitle:action:keyEquivalent:", .{ objc.nsString(title), objc.sel(action), objc.nsString(key) });
            send(void, m, "addItem:", .{it});
            objc.release(it);
            return it;
        }
    }.f;
    var buf: [192]u8 = undefined;
    const hide_title = std.fmt.bufPrint(&buf, "Hide {s}", .{app_name}) catch "Hide";
    _ = addItem(app_menu, item_cls, hide_title, "hide:", "h");
    var qbuf: [192]u8 = undefined;
    const quit_title = std.fmt.bufPrint(&qbuf, "Quit {s}", .{app_name}) catch "Quit";
    _ = addItem(app_menu, item_cls, quit_title, "terminate:", "q");
    const app_item = objc.new(item_cls);
    send(void, app_item, "setSubmenu:", .{app_menu});
    send(void, bar, "addItem:", .{app_item});

    const win_menu = send(Id, send(Id, menu_cls, "alloc", .{}), "initWithTitle:", .{objc.nsString("Window")});
    _ = addItem(win_menu, item_cls, "Minimize", "performMiniaturize:", "m");
    _ = addItem(win_menu, item_cls, "Zoom", "performZoom:", "");
    const fs = addItem(win_menu, item_cls, "Enter Full Screen", "toggleFullScreen:", "f");
    send(void, fs, "setKeyEquivalentModifierMask:", .{@as(objc.NSUInteger, keys.flag_command | keys.flag_control)});
    const win_item = objc.new(item_cls);
    send(void, win_item, "setSubmenu:", .{win_menu});
    send(void, bar, "addItem:", .{win_item});
    send(void, ns_app, "setMainMenu:", .{bar});
    send(void, ns_app, "setWindowsMenu:", .{win_menu});
    objc.release(app_menu);
    objc.release(app_item);
    objc.release(win_menu);
    objc.release(win_item);
    objc.release(bar);
}

// ---- Window -------------------------------------------------------------------------------------

pub const Window = struct {
    app: *App,
    slot: u32,
    id: ev.WindowId,
    ns_window: Id,
    view: Id,
    delegate: Id,
    layer: ?Id = null,
    tracking_area: ?Id = null,
    display_link: ?Id = null,
    frame_timer: ?Id = null,
    frame_pending: bool = false,

    resizable: bool,
    accepts_first_mouse: bool,
    emitted: ev.ResizeEvent = .{ .width = 0, .height = 0, .pixel_width = 0, .pixel_height = 0, .scale = 0 },
    visible: bool = true,
    suspended: bool = false,
    cursor: CursorShape = .default,
    ti_enabled: bool = false,
    ti_rect: Rect = .{},
    ime: Ime = .{},
    last_x: f32 = 0,
    last_y: f32 = 0,
    /// The pointer left while a button was held; `mouse_leave` is sent on release.
    leave_pending: bool = false,

    fn tag(w: *const Window) u32 {
        return w.slot + 1;
    }

    fn orderIn(w: *Window) void {
        const app = w.app;
        if (app.allow_activation) {
            if (!app.activated_once) {
                send(void, app.ns_app, "activateIgnoringOtherApps:", .{objc.YES});
                app.activated_once = true;
            }
            send(void, w.ns_window, "makeKeyAndOrderFront:", .{@as(?Id, null)});
        } else {
            // Never activate: tests and background tools must not steal focus.
            send(void, w.ns_window, "orderFront:", .{@as(?Id, null)});
        }
    }

    fn syncLayerScale(w: *Window) void {
        const l = w.layer orelse return;
        send(void, l, "setContentsScale:", .{send(f64, w.ns_window, "backingScaleFactor", .{})});
    }

    fn updateTrackingArea(w: *Window) void {
        if (w.tracking_area) |t| {
            send(void, w.view, "removeTrackingArea:", .{t});
            objc.release(t);
        }
        const t = send(Id, send(Id, objc.class("NSTrackingArea"), "alloc", .{}), "initWithRect:options:owner:userInfo:", .{ send(objc.NSRect, w.view, "bounds", .{}), tracking_options, w.view, @as(?Id, null) });
        send(void, w.view, "addTrackingArea:", .{t});
        w.tracking_area = t;
    }

    fn createDisplayLink(w: *Window) void {
        if (!objc.respondsTo(w.view, "displayLinkWithTarget:selector:")) return; // < macOS 14: NSTimer fallback
        const link = send(?Id, w.view, "displayLinkWithTarget:selector:", .{ w.delegate, objc.sel("paletteFrame:") }) orelse return;
        send(void, link, "setPaused:", .{objc.YES});
        send(void, link, "addToRunLoop:forMode:", .{ send(Id, objc.class("NSRunLoop"), "mainRunLoop", .{}), w.app.run_loop_common });
        w.display_link = objc.retain(link);
    }

    fn frameFired(w: *Window) void {
        if (w.display_link) |l| send(void, l, "setPaused:", .{objc.YES});
        if (w.frame_timer) |t| {
            objc.release(t);
            w.frame_timer = null;
        }
        if (!w.frame_pending) return;
        w.frame_pending = false;
        w.app.push(.{ .frame = .{ .window = w.id } });
        w.app.postWake();
    }

    /// Emits `resized` if logical size, pixel size or scale changed. Returns true if emitted.
    fn updateSize(w: *Window) bool {
        const ls = w.logicalSize();
        const px = w.pixelSize();
        const e: ev.ResizeEvent = .{ .window = w.id, .width = @intCast(ls.width), .height = @intCast(ls.height), .pixel_width = @intCast(px.width), .pixel_height = @intCast(px.height), .scale = w.scale() };
        if (e.width == w.emitted.width and e.height == w.emitted.height and e.pixel_width == w.emitted.pixel_width and
            e.pixel_height == w.emitted.pixel_height and e.scale == w.emitted.scale) return false;
        w.emitted = e;
        w.app.push(.{ .resized = e });
        return true;
    }

    fn updateSuspended(w: *Window) void {
        if (!w.visible) return;
        const mini = send(objc.BOOL, w.ns_window, "isMiniaturized", .{}) != 0;
        const occluded = send(objc.NSUInteger, w.ns_window, "occlusionState", .{}) & occlusion_visible == 0;
        const s = mini or occluded;
        if (s == w.suspended) return;
        w.suspended = s;
        w.app.push(if (s) .{ .window_hidden = .{ .window = w.id, .reason = .suspended } } else .{ .window_shown = .{ .window = w.id, .reason = .suspended } });
    }

    fn releasePendingFrame(w: *Window) void {
        if (!w.frame_pending) return;
        w.frame_pending = false;
        if (w.display_link) |l| send(void, l, "setPaused:", .{objc.YES});
        w.app.push(.{ .frame = .{ .window = w.id } });
    }

    /// Orders the window out and emits `window_hidden`. `show()` brings it back.
    pub fn hide(w: *Window) void {
        if (!w.visible) return;
        const pool = objc.Pool.push();
        defer pool.pop();
        w.visible = false;
        w.ime.reset(.{ .app = w.app, .w = w });
        w.releasePendingFrame();
        send(void, w.ns_window, "orderOut:", .{@as(?Id, null)});
        w.app.push(.{ .window_hidden = .{ .window = w.id, .reason = .unmapped } });
    }

    pub fn show(w: *Window) void {
        if (w.visible) return;
        const pool = objc.Pool.push();
        defer pool.pop();
        w.visible = true;
        w.suspended = false;
        w.orderIn();
        w.app.push(.{ .window_shown = .{ .window = w.id, .reason = .unmapped } });
    }

    pub fn isVisible(w: *const Window) bool {
        return w.visible;
    }

    /// Minimized or fully occluded (`occlusionState`).
    pub fn isSuspended(w: *const Window) bool {
        return w.suspended;
    }

    pub fn isTextInputActive(w: *const Window) bool {
        return w.ti_enabled;
    }

    pub fn hasPointerFocus(w: *const Window) bool {
        return w.app.ptr_focus == w.tag();
    }

    pub fn hasKeyboardFocus(w: *const Window) bool {
        return w.app.kb_focus == w.tag();
    }

    /// Visible frame of the window's screen (points).
    pub fn configureBounds(w: *const Window) ?Size {
        const screen = send(?Id, w.ns_window, "screen", .{}) orelse return null;
        const r = send(objc.NSRect, screen, "visibleFrame", .{});
        return .{ .width = @intFromFloat(@max(r.size.width, 0)), .height = @intFromFloat(@max(r.size.height, 0)) };
    }

    fn primaryScreenHeight() f64 {
        const screens = send(?Id, objc.class("NSScreen"), "screens", .{}) orelse return 0;
        if (send(objc.NSUInteger, screens, "count", .{}) == 0) return 0;
        const s0 = send(Id, screens, "objectAtIndex:", .{@as(objc.NSUInteger, 0)});
        return send(objc.NSRect, s0, "frame", .{}).size.height;
    }

    /// Top-left of the content area in global top-left-origin points (SDL convention).
    pub fn position(w: *const Window) [2]i32 {
        const pool = objc.Pool.push();
        defer pool.pop();
        const frame = send(objc.NSRect, w.ns_window, "frame", .{});
        const content = send(objc.NSRect, w.ns_window, "contentRectForFrameRect:", .{frame});
        const top = primaryScreenHeight() - (content.origin.y + content.size.height);
        return .{ @intFromFloat(@round(content.origin.x)), @intFromFloat(@round(top)) };
    }

    /// Resizes the content area to `width` x `height` points (a `.resized` event follows).
    pub fn setSize(w: *Window, width: u32, height: u32) void {
        const pool = objc.Pool.push();
        defer pool.pop();
        send(void, w.ns_window, "setContentSize:", .{objc.NSSize{ .width = @floatFromInt(@max(width, 1)), .height = @floatFromInt(@max(height, 1)) }});
    }

    pub fn setPosition(w: *Window, x: i32, y: i32) void {
        const pool = objc.Pool.push();
        defer pool.pop();
        const frame = send(objc.NSRect, w.ns_window, "frame", .{});
        const content = send(objc.NSRect, w.ns_window, "contentRectForFrameRect:", .{frame});
        const titlebar = frame.size.height - content.size.height;
        const top = primaryScreenHeight() - @as(f64, @floatFromInt(y)) + titlebar;
        send(void, w.ns_window, "setFrameTopLeftPoint:", .{objc.NSPoint{ .x = @floatFromInt(x), .y = top }});
    }

    pub fn destroy(w: *Window) void {
        const app = w.app;
        const pool = objc.Pool.push();
        defer pool.pop();
        if (app.ptr_focus == w.tag()) {
            app.ptr_focus = 0;
            if (app.cursor_hidden) {
                send(void, objc.class("NSCursor"), "unhide", .{});
                app.cursor_hidden = false;
            }
        }
        if (app.kb_focus == w.tag()) app.kb_focus = 0;
        if (w.display_link) |l| {
            send(void, l, "invalidate", .{});
            objc.release(l);
        }
        if (w.frame_timer) |t| {
            send(void, t, "invalidate", .{});
            objc.release(t);
        }
        if (w.tracking_area) |t| {
            send(void, w.view, "removeTrackingArea:", .{t});
            objc.release(t);
        }
        objc.ivarPtr(w.view, ivar_name).* = null;
        objc.ivarPtr(w.delegate, ivar_name).* = null;
        send(void, w.ns_window, "setDelegate:", .{@as(?Id, null)});
        send(void, w.ns_window, "orderOut:", .{@as(?Id, null)});
        send(void, w.ns_window, "close", .{});
        objc.release(w.view);
        objc.release(w.ns_window);
        objc.release(w.delegate);
        app.windows[w.slot] = null;
        app.gpa.destroy(w);
    }

    pub fn logicalSize(w: *const Window) Size {
        const b = send(objc.NSRect, w.view, "bounds", .{});
        return .{ .width = @intFromFloat(@max(1, @round(b.size.width))), .height = @intFromFloat(@max(1, @round(b.size.height))) };
    }

    /// Drawable size: points x backingScaleFactor (what the CAMetalLayer's drawableSize must
    /// be).
    pub fn pixelSize(w: *const Window) Size {
        const b = send(objc.NSRect, w.view, "bounds", .{});
        const px = send(objc.NSRect, w.view, "convertRectToBacking:", .{b});
        return .{ .width = @intFromFloat(@max(1, @round(px.size.width))), .height = @intFromFloat(@max(1, @round(px.size.height))) };
    }

    pub fn scale(w: *const Window) f32 {
        return @floatCast(send(f64, w.ns_window, "backingScaleFactor", .{}));
    }

    pub fn setTitle(w: *Window, title: []const u8) void {
        const pool = objc.Pool.push();
        defer pool.pop();
        send(void, w.ns_window, "setTitle:", .{objc.nsString(title)});
    }

    pub fn setMinSize(w: *Window, width: u32, height: u32) void {
        send(void, w.ns_window, "setContentMinSize:", .{objc.NSSize{ .width = @floatFromInt(@max(width, 1)), .height = @floatFromInt(@max(height, 1)) }});
    }

    pub fn setCursor(w: *Window, shape: CursorShape) void {
        if (w.cursor == shape) return;
        w.cursor = shape;
        if (w.hasPointerFocus()) applyCursor(w);
    }

    /// Zoom (the green button). AppKit has no separate "maximized"; `isZoomed` is the state.
    pub fn setMaximized(w: *Window, on: bool) void {
        if (send(objc.BOOL, w.ns_window, "isMiniaturized", .{}) != 0) send(void, w.ns_window, "deminiaturize:", .{@as(?Id, null)});
        if ((send(objc.BOOL, w.ns_window, "isZoomed", .{}) != 0) != on) send(void, w.ns_window, "zoom:", .{@as(?Id, null)});
    }

    pub fn minimize(w: *Window) void {
        send(void, w.ns_window, "miniaturize:", .{@as(?Id, null)});
    }

    /// Native full screen (own Space, animated). `resized` follows when the transition ends.
    pub fn setFullscreen(w: *Window, on: bool) void {
        if (w.isFullscreen() != on) send(void, w.ns_window, "toggleFullScreen:", .{@as(?Id, null)});
    }

    pub fn isMaximized(w: *const Window) bool {
        return send(objc.BOOL, w.ns_window, "isZoomed", .{}) != 0;
    }

    pub fn isFullscreen(w: *const Window) bool {
        return send(objc.NSUInteger, w.ns_window, "styleMask", .{}) & style_fullscreen != 0;
    }

    pub fn isActivated(w: *const Window) bool {
        return send(objc.BOOL, w.ns_window, "isKeyWindow", .{}) != 0;
    }

    /// Asks for one `Event.frame` at the next display refresh (`NSView.displayLink`, macOS
    /// 14+; a 1/60 s one-shot NSTimer on older systems). The link is paused again after it
    /// fires, so an idle app uses no CPU.
    pub fn requestFrame(w: *Window) void {
        if (w.frame_pending) return;
        w.frame_pending = true;
        if (!w.visible) return w.releasePendingFrame();
        if (w.display_link) |l| {
            send(void, l, "setPaused:", .{objc.NO});
            return;
        }
        const pool = objc.Pool.push();
        defer pool.pop();
        const t = send(Id, objc.class("NSTimer"), "timerWithTimeInterval:target:selector:userInfo:repeats:", .{ @as(f64, 1.0 / 60.0), w.delegate, objc.sel("paletteFrame:"), @as(?Id, null), objc.NO });
        send(void, send(Id, objc.class("NSRunLoop"), "mainRunLoop", .{}), "addTimer:forMode:", .{ t, w.app.run_loop_common });
        w.frame_timer = objc.retain(t);
    }

    /// Brings the app and window to the front. `token` is ignored (Wayland activation
    /// tokens). A no-op for test apps and when activation is disabled.
    pub fn activate(w: *Window, token: []const u8) void {
        _ = token;
        if (!w.app.allow_activation) return;
        send(void, w.app.ns_app, "activateIgnoringOtherApps:", .{objc.YES});
        send(void, w.ns_window, "makeKeyAndOrderFront:", .{@as(?Id, null)});
    }

    /// Bounces the Dock icon once (NSInformationalRequest) when the app is inactive.
    pub fn requestAttention(w: *Window) void {
        if (w.app.policy != .regular) return;
        _ = send(objc.NSInteger, w.app.ns_app, "requestUserAttention:", .{@as(objc.NSUInteger, 10)});
    }

    /// Enables text/IME events; `rect` is the caret rectangle in logical window coordinates
    /// (where the candidate window is placed).
    pub fn startTextInput(w: *Window, rect: Rect) void {
        w.ti_rect = rect;
        if (w.ti_enabled) return w.setTextInputRect(rect);
        w.ti_enabled = true;
        send(void, w.ns_window, "makeFirstResponder:", .{w.view});
    }

    pub fn stopTextInput(w: *Window) void {
        if (!w.ti_enabled) return;
        w.ime.reset(.{ .app = w.app, .w = w });
        if (send(?Id, w.view, "inputContext", .{})) |ctx| send(void, ctx, "discardMarkedText", .{});
        w.ti_enabled = false;
    }

    pub fn setTextInputRect(w: *Window, rect: Rect) void {
        const same = w.ti_rect.x == rect.x and w.ti_rect.y == rect.y and w.ti_rect.w == rect.w and w.ti_rect.h == rect.h;
        w.ti_rect = rect;
        if (same or !w.ti_enabled) return;
        if (send(?Id, w.view, "inputContext", .{})) |ctx| send(void, ctx, "invalidateCharacterCoordinates", .{});
    }

    /// Screen rectangle (bottom-left origin) for `firstRectForCharacterRange:`.
    fn textInputScreenRect(w: *const Window) objc.NSRect {
        const r = objc.NSRect.make(w.ti_rect.x, w.ti_rect.y, @max(w.ti_rect.w, 1), @max(w.ti_rect.h, 1));
        const in_window = send(objc.NSRect, w.view, "convertRect:toView:", .{ r, @as(?Id, null) });
        return send(objc.NSRect, w.ns_window, "convertRectToScreen:", .{in_window});
    }

    pub fn nativeHandles(w: *const Window) NativeHandles {
        return .{ .ns_window = @ptrCast(w.ns_window), .ns_view = @ptrCast(w.view), .metal_layer = if (w.layer) |l| @ptrCast(l) else null };
    }

    /// Test hook: routes an in-process NSEvent as if AppKit delivered it to this window,
    /// without `sendEvent:` (no activation, no focus change). Keys bypass the focus gate.
    pub fn injectEvent(w: *Window, e: *anyopaque) void {
        const pool = objc.Pool.push();
        defer pool.pop();
        const ne: Id = @ptrCast(e);
        switch (send(objc.NSUInteger, ne, "type", .{})) {
            NSEventType.key_down, NSEventType.key_up => w.app.handleKey(ne, w),
            NSEventType.flags_changed => w.app.handleFlags(ne, w),
            NSEventType.left_mouse_down, NSEventType.right_mouse_down, NSEventType.other_mouse_down => View.mouseDown(w.view, undefined, ne),
            NSEventType.left_mouse_up, NSEventType.right_mouse_up, NSEventType.other_mouse_up => View.mouseUp(w.view, undefined, ne),
            NSEventType.mouse_moved, NSEventType.left_mouse_dragged, NSEventType.right_mouse_dragged, NSEventType.other_mouse_dragged => View.mouseMoved(w.view, undefined, ne),
            NSEventType.scroll_wheel => View.scrollWheel(w.view, undefined, ne),
            else => {},
        }
    }

    /// Test hook: simulates the pointer entering (`true`) or leaving the window.
    pub fn injectCrossing(w: *Window, entered: bool, x: f32, y: f32) void {
        if (entered) w.pointerEntered(x, y) else w.pointerLeft();
    }

    fn pointerEntered(w: *Window, x: f32, y: f32) void {
        const app = w.app;
        w.leave_pending = false;
        if (app.ptr_focus == w.tag()) return;
        app.ptr_focus = w.tag();
        w.last_x = x;
        w.last_y = y;
        app.push(.{ .mouse_enter = .{ .window = w.id, .x = x, .y = y, .state = buttonState() } });
        applyCursor(w);
    }

    fn pointerLeft(w: *Window) void {
        const app = w.app;
        if (app.ptr_focus != w.tag()) return;
        app.ptr_focus = 0;
        w.leave_pending = false;
        if (app.cursor_hidden) {
            send(void, objc.class("NSCursor"), "unhide", .{});
            app.cursor_hidden = false;
        }
        app.push(.{ .mouse_leave = .{ .window = w.id } });
    }
};

fn applyCursor(w: *Window) void {
    const app = w.app;
    const cursor_cls = objc.class("NSCursor");
    if (w.cursor == .hidden) {
        if (!app.cursor_hidden) {
            send(void, cursor_cls, "hide", .{});
            app.cursor_hidden = true;
        }
        return;
    }
    if (app.cursor_hidden) {
        send(void, cursor_cls, "unhide", .{});
        app.cursor_hidden = false;
    }
    const c = nsCursor(w.cursor);
    send(void, c, "set", .{});
}

fn cursorNamed(comptime name: [:0]const u8, comptime fallback: [:0]const u8) Id {
    const cls = objc.class("NSCursor");
    if (objc.respondsTo(cls, name)) if (send(?Id, cls, name, .{})) |c| return c;
    return send(Id, cls, fallback, .{});
}

/// Public NSCursor class methods, plus private ones (guarded by `respondsToSelector:`) for
/// shapes AppKit only exposes privately; anything else falls back to a close public cursor.
fn nsCursor(shape: CursorShape) Id {
    return switch (shape) {
        .default, .hidden, .progress, .wait => cursorNamed("arrowCursor", "arrowCursor"),
        .context_menu => cursorNamed("contextualMenuCursor", "arrowCursor"),
        .help => cursorNamed("_helpCursor", "arrowCursor"),
        .pointer => cursorNamed("pointingHandCursor", "arrowCursor"),
        .cell, .crosshair => cursorNamed("crosshairCursor", "arrowCursor"),
        .text => cursorNamed("IBeamCursor", "arrowCursor"),
        .vertical_text => cursorNamed("IBeamCursorForVerticalLayout", "IBeamCursor"),
        .alias => cursorNamed("dragLinkCursor", "arrowCursor"),
        .copy => cursorNamed("dragCopyCursor", "arrowCursor"),
        .move, .all_scroll => cursorNamed("_moveCursor", "openHandCursor"),
        .no_drop, .not_allowed => cursorNamed("operationNotAllowedCursor", "arrowCursor"),
        .grab => cursorNamed("openHandCursor", "arrowCursor"),
        .grabbing => cursorNamed("closedHandCursor", "arrowCursor"),
        .e_resize => cursorNamed("_windowResizeEastCursor", "resizeRightCursor"),
        .w_resize => cursorNamed("_windowResizeWestCursor", "resizeLeftCursor"),
        .n_resize => cursorNamed("_windowResizeNorthCursor", "resizeUpCursor"),
        .s_resize => cursorNamed("_windowResizeSouthCursor", "resizeDownCursor"),
        .ew_resize, .col_resize => cursorNamed("resizeLeftRightCursor", "arrowCursor"),
        .ns_resize, .row_resize => cursorNamed("resizeUpDownCursor", "arrowCursor"),
        .ne_resize => cursorNamed("_windowResizeNorthEastCursor", "crosshairCursor"),
        .nw_resize => cursorNamed("_windowResizeNorthWestCursor", "crosshairCursor"),
        .se_resize => cursorNamed("_windowResizeSouthEastCursor", "crosshairCursor"),
        .sw_resize => cursorNamed("_windowResizeSouthWestCursor", "crosshairCursor"),
        .nesw_resize => cursorNamed("_windowResizeNorthEastSouthWestCursor", "crosshairCursor"),
        .nwse_resize => cursorNamed("_windowResizeNorthWestSouthEastCursor", "crosshairCursor"),
        .zoom_in => cursorNamed("zoomInCursor", "arrowCursor"),
        .zoom_out => cursorNamed("zoomOutCursor", "arrowCursor"),
    };
}

fn buttonState() ev.ButtonState {
    const b = send(objc.NSUInteger, objc.class("NSEvent"), "pressedMouseButtons", .{});
    return .{
        .left = b & 1 != 0,
        .right = b & 2 != 0,
        .middle = b & 4 != 0,
        .back = b & 8 != 0,
        .forward = b & 16 != 0,
    };
}

/// AppKit button number -> Palette/SDL button (0 left, 1 right, 2 middle, n -> n + 1).
pub fn mapButton(n: objc.NSInteger) u8 {
    return switch (n) {
        0 => @intFromEnum(ev.MouseButton.left),
        1 => @intFromEnum(ev.MouseButton.right),
        2 => @intFromEnum(ev.MouseButton.middle),
        else => @intCast(std.math.clamp(n + 1, 0, 255)),
    };
}

/// SDL's wheel conversion: x is negated, discrete (non-precise) deltas round away from zero
/// to whole lines.
pub fn wheelDelta(dx: f64, dy: f64, precise: bool) [2]f32 {
    var x = -dx;
    var y = dy;
    if (!precise) {
        x = if (x > 0) @ceil(x) else if (x < 0) @floor(x) else 0;
        y = if (y > 0) @ceil(y) else if (y < 0) @floor(y) else 0;
    }
    return .{ @floatCast(x), @floatCast(y) };
}

// ---- view methods -------------------------------------------------------------------------------

const View = struct {
    fn yes(_: Id, _: objc.Sel) callconv(.c) objc.BOOL {
        return objc.YES;
    }

    fn makeBackingLayer(_: Id, _: objc.Sel) callconv(.c) ?Id {
        const cls = objc.getClass("CAMetalLayer") orelse return send(?Id, objc.class("CALayer"), "layer", .{});
        const layer = send(Id, cls, "layer", .{});
        // A blit target (the renderer copies its retained backbuffer into the drawable).
        send(void, layer, "setFramebufferOnly:", .{objc.NO});
        send(void, layer, "setOpaque:", .{objc.YES});
        return layer;
    }

    fn acceptsFirstMouse(self: Id, _: objc.Sel, _: ?Id) callconv(.c) objc.BOOL {
        const w = windowOf(self) orelse return objc.NO;
        return if (w.accepts_first_mouse) objc.YES else objc.NO;
    }

    fn ignoreEvent(_: Id, _: objc.Sel, _: ?Id) callconv(.c) void {}

    fn location(w: *Window, e: Id) [2]f32 {
        const p = send(objc.NSPoint, e, "locationInWindow", .{});
        const v = send(objc.NSPoint, w.view, "convertPoint:fromView:", .{ p, @as(?Id, null) });
        return .{ @floatCast(v.x), @floatCast(v.y) };
    }

    fn mouseDown(self: Id, _: objc.Sel, e: Id) callconv(.c) void {
        button(self, e, true);
    }

    fn mouseUp(self: Id, _: objc.Sel, e: Id) callconv(.c) void {
        button(self, e, false);
    }

    fn button(self: Id, e: Id, down: bool) void {
        const w = windowOf(self) orelse return;
        const p = location(w, e);
        const clicks = send(objc.NSInteger, e, "clickCount", .{});
        // Left/right come from the event type (synthesized events report buttonNumber 0);
        // other buttons from buttonNumber.
        const btn: u8 = switch (send(objc.NSUInteger, e, "type", .{})) {
            NSEventType.left_mouse_down, NSEventType.left_mouse_up => mapButton(0),
            NSEventType.right_mouse_down, NSEventType.right_mouse_up => mapButton(1),
            else => mapButton(send(objc.NSInteger, e, "buttonNumber", .{})),
        };
        w.app.push(if (down) .{ .mouse_button_down = .{
            .window = w.id,
            .x = p[0],
            .y = p[1],
            .button = btn,
            .clicks = @intCast(std.math.clamp(clicks, 1, 255)),
            .down = true,
        } } else .{ .mouse_button_up = .{
            .window = w.id,
            .x = p[0],
            .y = p[1],
            .button = btn,
            .clicks = @intCast(std.math.clamp(clicks, 1, 255)),
            .down = false,
        } });
        if (!down and w.leave_pending and buttonState() == ev.ButtonState{}) {
            const ls = w.logicalSize();
            if (p[0] < 0 or p[1] < 0 or p[0] >= @as(f32, @floatFromInt(ls.width)) or p[1] >= @as(f32, @floatFromInt(ls.height))) w.pointerLeft();
            w.leave_pending = false;
        }
    }

    fn mouseMoved(self: Id, _: objc.Sel, e: Id) callconv(.c) void {
        const w = windowOf(self) orelse return;
        const p = location(w, e);
        if (w.app.ptr_focus != w.tag()) {
            const ls = w.logicalSize();
            const inside = p[0] >= 0 and p[1] >= 0 and p[0] < @as(f32, @floatFromInt(ls.width)) and p[1] < @as(f32, @floatFromInt(ls.height));
            if (inside) w.pointerEntered(p[0], p[1]);
        }
        const xrel = p[0] - w.last_x;
        const yrel = p[1] - w.last_y;
        w.last_x = p[0];
        w.last_y = p[1];
        w.app.push(.{ .mouse_motion = .{ .window = w.id, .x = p[0], .y = p[1], .xrel = xrel, .yrel = yrel, .state = buttonState() } });
    }

    fn scrollWheel(self: Id, _: objc.Sel, e: Id) callconv(.c) void {
        const w = windowOf(self) orelse return;
        const p = location(w, e);
        const precise = send(objc.BOOL, e, "hasPreciseScrollingDeltas", .{}) != 0;
        const d = wheelDelta(send(f64, e, "deltaX", .{}), send(f64, e, "deltaY", .{}), precise);
        if (d[0] == 0 and d[1] == 0) return;
        w.app.push(.{ .mouse_wheel = .{ .window = w.id, .x = d[0], .y = d[1], .precise = precise, .mouse_x = p[0], .mouse_y = p[1] } });
    }

    fn mouseEntered(self: Id, _: objc.Sel, e: Id) callconv(.c) void {
        const w = windowOf(self) orelse return;
        const p = location(w, e);
        w.pointerEntered(p[0], p[1]);
    }

    fn mouseExited(self: Id, _: objc.Sel, _: Id) callconv(.c) void {
        const w = windowOf(self) orelse return;
        if (buttonState() != ev.ButtonState{}) {
            w.leave_pending = true; // implicit grab: keep focus until release
            return;
        }
        w.pointerLeft();
    }

    fn cursorUpdate(self: Id, _: objc.Sel, _: Id) callconv(.c) void {
        const w = windowOf(self) orelse return;
        applyCursor(w);
    }

    fn updateTrackingAreas(self: Id, _: objc.Sel) callconv(.c) void {
        objc.sendSuper(void, self, objc.class("NSView"), "updateTrackingAreas", .{});
        const w = windowOf(self) orelse return;
        w.updateTrackingArea();
    }

    fn backingChanged(self: Id, _: objc.Sel) callconv(.c) void {
        objc.sendSuper(void, self, objc.class("NSView"), "viewDidChangeBackingProperties", .{});
        const w = windowOf(self) orelse return;
        w.syncLayerScale();
        _ = w.updateSize();
    }

    // NSTextInputClient --------------------------------------------------------------------

    fn hasMarkedText(self: Id, _: objc.Sel) callconv(.c) objc.BOOL {
        const w = windowOf(self) orelse return objc.NO;
        return if (w.ime.marked) objc.YES else objc.NO;
    }

    fn markedRange(self: Id, _: objc.Sel) callconv(.c) objc.NSRange {
        const w = windowOf(self) orelse return objc.NSRange.empty;
        if (!w.ime.marked) return objc.NSRange.empty;
        return .{ .location = 0, .length = w.ime.marked_len16 };
    }

    fn selectedRange(self: Id, _: objc.Sel) callconv(.c) objc.NSRange {
        const w = windowOf(self) orelse return objc.NSRange.empty;
        if (!w.ime.marked) return objc.NSRange.empty;
        return .{ .location = w.ime.sel_location16, .length = w.ime.sel_length16 };
    }

    fn plainString(s: ?Id) ?Id {
        const str = s orelse return null;
        if (objc.isKindOf(str, objc.class("NSAttributedString"))) return send(?Id, str, "string", .{});
        return str;
    }

    fn setMarkedText(self: Id, _: objc.Sel, s: ?Id, sel_range: objc.NSRange, _: objc.NSRange) callconv(.c) void {
        const w = windowOf(self) orelse return;
        if (!w.ti_enabled) return;
        const text = objc.utf8(plainString(s));
        w.ime.setMarkedText(.{ .app = w.app, .w = w }, text, sel_range.location, sel_range.length);
    }

    fn unmarkText(self: Id, _: objc.Sel) callconv(.c) void {
        const w = windowOf(self) orelse return;
        if (w.ime.marked) w.ime.unmark(.{ .app = w.app, .w = w });
    }

    fn validAttributes(_: Id, _: objc.Sel) callconv(.c) Id {
        return send(Id, objc.class("NSArray"), "array", .{});
    }

    fn attributedSubstring(_: Id, _: objc.Sel, _: objc.NSRange, _: ?*objc.NSRange) callconv(.c) ?Id {
        return null;
    }

    fn insertTextRange(self: Id, _: objc.Sel, s: ?Id, replacement: objc.NSRange) callconv(.c) void {
        const w = windowOf(self) orelse return;
        if (!w.ti_enabled) return;
        var text = objc.utf8(plainString(s));
        // Control characters are not text (SDL drops them too); the key event still goes out.
        if (text.len > 0 and (text[0] < 0x20 or text[0] == 0x7f)) text = "";
        if (text.len >= 3 and keys.printable(keys.firstScalar(text)) == 0) text = "";
        w.ime.insertText(.{ .app = w.app, .w = w }, text, replacement.location != objc.NSRange.not_found);
    }

    fn insertText(self: Id, s: objc.Sel, str: ?Id) callconv(.c) void {
        insertTextRange(self, s, str, objc.NSRange.empty);
    }

    fn characterIndex(_: Id, _: objc.Sel, _: objc.NSPoint) callconv(.c) objc.NSUInteger {
        return 0;
    }

    fn firstRect(self: Id, _: objc.Sel, _: objc.NSRange, actual: ?*objc.NSRange) callconv(.c) objc.NSRect {
        if (actual) |a| a.* = objc.NSRange.empty;
        const w = windowOf(self) orelse return .{};
        return w.textInputScreenRect();
    }

    fn doCommand(_: Id, _: objc.Sel, _: ?objc.Sel) callconv(.c) void {}
};

// ---- window delegate --------------------------------------------------------------------------

const Delegate = struct {
    fn shouldClose(self: Id, _: objc.Sel, _: ?Id) callconv(.c) objc.BOOL {
        const w = windowOf(self) orelse return objc.YES;
        w.app.push(.{ .close_requested = .{ .window = w.id } });
        return objc.NO;
    }

    fn didResize(self: Id, _: objc.Sel, _: ?Id) callconv(.c) void {
        const w = windowOf(self) orelse return;
        w.syncLayerScale();
        _ = w.updateSize();
    }

    fn didBecomeKey(self: Id, _: objc.Sel, _: ?Id) callconv(.c) void {
        const w = windowOf(self) orelse return;
        const app = w.app;
        if (app.kb_focus == w.tag()) return;
        app.kb_focus = w.tag();
        app.push(.{ .focus_gained = .{ .window = w.id } });
        // Keys pressed while another app had focus: report the current modifier state.
        app.syncModifiers(send(objc.NSUInteger, objc.class("NSEvent"), "modifierFlags", .{}), w.id, true);
        app.checkClipboard();
        if (w.ti_enabled) send(void, w.ns_window, "makeFirstResponder:", .{w.view});
    }

    fn didResignKey(self: Id, _: objc.Sel, _: ?Id) callconv(.c) void {
        const w = windowOf(self) orelse return;
        const app = w.app;
        if (app.kb_focus != w.tag()) return;
        w.ime.reset(.{ .app = app, .w = w });
        app.syncModifiers(0, w.id, true);
        app.kb_focus = 0;
        app.push(.{ .focus_lost = .{ .window = w.id } });
    }

    fn visibilityChanged(self: Id, _: objc.Sel, _: ?Id) callconv(.c) void {
        const w = windowOf(self) orelse return;
        w.updateSuspended();
        w.app.postWake();
    }

    fn frameFired(self: Id, _: objc.Sel, _: ?Id) callconv(.c) void {
        const w = windowOf(self) orelse return;
        w.frameFired();
    }
};

const Helper = struct {
    fn observe(_: Id, _: objc.Sel, _: ?Id, _: ?Id, _: ?Id, _: ?*anyopaque) callconv(.c) void {
        const app = g_app orelse return;
        app.themeChanged();
    }

    fn shouldTerminate(_: Id, _: objc.Sel, _: ?Id) callconv(.c) objc.NSUInteger {
        // Cmd+Q / Dock "Quit" / logout: report `quit` and let the host decide.
        if (g_app) |app| {
            app.push(.quit);
            app.postWake();
        }
        return terminate_cancel;
    }

    fn no(_: Id, _: objc.Sel, _: ?Id) callconv(.c) objc.BOOL {
        return objc.NO;
    }
};

test "test app ids use a private pasteboard" {
    var buf: [160]u8 = undefined;
    try std.testing.expectEqualStrings("palette-test-verde.pasteboard", privatePasteboardName(&buf, "palette-test-verde").?);
    try std.testing.expect(privatePasteboardName(&buf, "dev.verde.Verde") == null);
    var small: [8]u8 = undefined;
    try std.testing.expectEqualStrings("palette-test.pasteboard", privatePasteboardName(&small, "palette-test-long-id").?);
}

test "clipboard MIME types map to UTIs" {
    try std.testing.expectEqualStrings("public.png", utiForMime("image/png"));
    try std.testing.expectEqualStrings("public.utf8-plain-text", utiForMime("text/plain;charset=UTF-8"));
    try std.testing.expectEqualStrings("com.example.custom", utiForMime("com.example.custom"));
}

test "button mapping and wheel conversion follow SDL" {
    try std.testing.expectEqual(@as(u8, 1), mapButton(0));
    try std.testing.expectEqual(@as(u8, 3), mapButton(1));
    try std.testing.expectEqual(@as(u8, 2), mapButton(2));
    try std.testing.expectEqual(@as(u8, 4), mapButton(3));
    try std.testing.expectEqual(@as(u8, 5), mapButton(4));
    // Mouse wheel: 0.1 line still scrolls one line; x is negated.
    try std.testing.expectEqual([2]f32{ -1, 1 }, wheelDelta(0.1, 0.1, false));
    try std.testing.expectEqual([2]f32{ 2, -3 }, wheelDelta(-1.2, -2.5, false));
    try std.testing.expectEqual([2]f32{ -0.5, 0.25 }, wheelDelta(0.5, 0.25, true));
    try std.testing.expect(isTestId("palette-test-macos"));
    try std.testing.expect(!isTestId("verde"));
}
