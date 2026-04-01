//! Thin Zig wrappers around the native CEF shim used by the browser pane backend.

const builtin = @import("builtin");
const build_options = @import("build_options");

/// Mirrors the native event kinds emitted by the Linux CEF shim.
pub const EventKind = enum(c_int) {
    none = 0,
    opened = 1,
    closed = 2,
    navigated = 3,
    title_changed = 4,
    failed = 5,
};

/// Describes the latest off-screen browser frame published by the native shim.
pub const FrameInfo = struct {
    pixels: ?[*]const u8 = null,
    len: usize = 0,
    width: u32 = 0,
    height: u32 = 0,
    dirty: bool = false,
};

const native_api = if (build_options.cef_sdk_configured and builtin.os.tag == .linux)
    struct {
        extern fn verde_cef_execute_subprocess(argc: c_int, argv: [*]const [*:0]const u8) c_int;
        extern fn verde_cef_initialize(
            argc: c_int,
            argv: [*]const [*:0]const u8,
            subprocess_path: [*:0]const u8,
            resources_dir: [*:0]const u8,
            locales_dir: [*:0]const u8,
        ) c_int;
        extern fn verde_cef_is_initialized() c_int;
        extern fn verde_cef_shutdown() void;
        extern fn verde_cef_do_message_loop_work() void;
        extern fn verde_cef_has_browser() c_int;
        extern fn verde_cef_create_browser(width: c_int, height: c_int, url: [*:0]const u8) c_int;
        extern fn verde_cef_resize_browser(width: c_int, height: c_int) void;
        extern fn verde_cef_navigate(url: [*:0]const u8) c_int;
        extern fn verde_cef_eval(js: [*:0]const u8) c_int;
        extern fn verde_cef_get_frame(
            pixels: *?[*]const u8,
            len: *usize,
            width: *c_int,
            height: *c_int,
            dirty: *c_int,
        ) void;
        extern fn verde_cef_clear_frame_dirty() void;
        extern fn verde_cef_pop_event(kind: *c_int, buffer: [*]u8, cap: usize, out_len: *usize) c_int;
    }
else
    struct {
        fn verde_cef_execute_subprocess(argc: c_int, argv: [*]const [*:0]const u8) c_int {
            _ = argc;
            _ = argv;
            return 0;
        }

        fn verde_cef_initialize(
            argc: c_int,
            argv: [*]const [*:0]const u8,
            subprocess_path: [*:0]const u8,
            resources_dir: [*:0]const u8,
            locales_dir: [*:0]const u8,
        ) c_int {
            _ = argc;
            _ = argv;
            _ = subprocess_path;
            _ = resources_dir;
            _ = locales_dir;
            return 0;
        }

        fn verde_cef_shutdown() void {}

        fn verde_cef_is_initialized() c_int {
            return 0;
        }

        fn verde_cef_do_message_loop_work() void {}

        fn verde_cef_has_browser() c_int {
            return 0;
        }

        fn verde_cef_create_browser(width: c_int, height: c_int, url: [*:0]const u8) c_int {
            _ = width;
            _ = height;
            _ = url;
            return 0;
        }

        fn verde_cef_resize_browser(width: c_int, height: c_int) void {
            _ = width;
            _ = height;
        }

        fn verde_cef_navigate(url: [*:0]const u8) c_int {
            _ = url;
            return 0;
        }

        fn verde_cef_eval(js: [*:0]const u8) c_int {
            _ = js;
            return 0;
        }

        fn verde_cef_get_frame(
            pixels: *?[*]const u8,
            len: *usize,
            width: *c_int,
            height: *c_int,
            dirty: *c_int,
        ) void {
            pixels.* = null;
            len.* = 0;
            width.* = 0;
            height.* = 0;
            dirty.* = 0;
        }

        fn verde_cef_clear_frame_dirty() void {}

        fn verde_cef_pop_event(kind: *c_int, buffer: [*]u8, cap: usize, out_len: *usize) c_int {
            _ = buffer;
            _ = cap;
            kind.* = @intFromEnum(EventKind.none);
            out_len.* = 0;
            return 0;
        }
    };

/// Reports whether the current build actually links the native CEF shim.
pub fn isAvailable() bool {
    return build_options.cef_sdk_configured and builtin.os.tag == .linux;
}

/// Executes the CEF subprocess entry point from the dedicated helper executable.
pub fn executeSubprocess(argc: c_int, argv: [*]const [*:0]const u8) c_int {
    return native_api.verde_cef_execute_subprocess(argc, argv);
}

/// Starts the browser-process side of the native CEF runtime.
pub fn initialize(
    argc: c_int,
    argv: [*]const [*:0]const u8,
    subprocess_path: [*:0]const u8,
    resources_dir: [*:0]const u8,
    locales_dir: [*:0]const u8,
) bool {
    return native_api.verde_cef_initialize(
        argc,
        argv,
        subprocess_path,
        resources_dir,
        locales_dir,
    ) != 0;
}

/// Reports whether the native CEF runtime has already been started in this process.
pub fn isInitialized() bool {
    return native_api.verde_cef_is_initialized() != 0;
}

/// Shuts down the native CEF runtime after the browser pane is done with it.
pub fn shutdown() void {
    native_api.verde_cef_shutdown();
}

/// Pumps one iteration of the native CEF message loop on the app main thread.
pub fn doMessageLoopWork() void {
    native_api.verde_cef_do_message_loop_work();
}

/// Reports whether the native shim currently owns a browser instance.
pub fn hasBrowser() bool {
    return native_api.verde_cef_has_browser() != 0;
}

/// Creates the off-screen browser that will paint into the app pane.
pub fn createBrowser(width: u32, height: u32, url: [*:0]const u8) bool {
    return native_api.verde_cef_create_browser(@intCast(width), @intCast(height), url) != 0;
}

/// Updates the off-screen browser viewport to match the current pane size.
pub fn resizeBrowser(width: u32, height: u32) void {
    native_api.verde_cef_resize_browser(@intCast(width), @intCast(height));
}

/// Requests a navigation in the active browser.
pub fn navigate(url: [*:0]const u8) bool {
    return native_api.verde_cef_navigate(url) != 0;
}

/// Dispatches JavaScript into the main frame of the active browser.
pub fn eval(js: [*:0]const u8) bool {
    return native_api.verde_cef_eval(js) != 0;
}

/// Returns the latest off-screen frame pointer and metadata from the native shim.
pub fn getFrame() FrameInfo {
    var pixels: ?[*]const u8 = null;
    var len: usize = 0;
    var width: c_int = 0;
    var height: c_int = 0;
    var dirty: c_int = 0;
    native_api.verde_cef_get_frame(&pixels, &len, &width, &height, &dirty);
    return .{
        .pixels = pixels,
        .len = len,
        .width = @intCast(@max(width, 0)),
        .height = @intCast(@max(height, 0)),
        .dirty = dirty != 0,
    };
}

/// Marks the latest published frame as consumed after the GPU upload succeeds.
pub fn clearFrameDirty() void {
    native_api.verde_cef_clear_frame_dirty();
}

/// Pops one pending browser event into the caller-provided UTF-8 buffer.
pub fn popEvent(buffer: []u8) ?struct { kind: EventKind, len: usize } {
    var kind: c_int = 0;
    var len: usize = 0;
    if (native_api.verde_cef_pop_event(&kind, buffer.ptr, buffer.len, &len) == 0) return null;
    return .{
        .kind = @enumFromInt(kind),
        .len = @min(len, buffer.len),
    };
}
