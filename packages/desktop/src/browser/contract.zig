//! Compile-time browser backend contract checks.

const std = @import("std");
const browser_input = @import("input.zig");
const browser_texture = @import("texture.zig");
const browser_types = @import("types.zig");

/// Documents and validates the app-facing browser backend contract.
pub const BrowserBackend = struct {
    pub fn assertImplementation(comptime T: type) void {
        const init_fn: fn (std.mem.Allocator) anyerror!T = T.init;
        const deinit_fn: fn (*T) void = T.deinit;
        const host_window_fn: fn (*T, ?*anyopaque) anyerror!void = T.setHostWindow;
        const show_fn: fn (*T) anyerror!void = T.show;
        const hide_fn: fn (*T) anyerror!void = T.hide;
        const shutdown_fn: fn (*T) void = T.shutdown;
        const resize_fn: fn (*T, u32, u32) anyerror!void = T.resizePane;
        const bounds_fn: fn (*T, browser_types.PaneBounds) anyerror!void = T.setPaneBounds;
        const navigate_fn: fn (*T, []const u8) anyerror!void = T.navigate;
        const eval_fn: fn (*T, []const u8) anyerror!void = T.eval;
        const post_json_fn: fn (*T, []const u8) anyerror!void = T.postJson;
        const go_back_fn: fn (*T) anyerror!void = T.goBack;
        const go_forward_fn: fn (*T) anyerror!void = T.goForward;
        const reload_fn: fn (*T) anyerror!void = T.reload;
        const focus_fn: fn (*T) anyerror!void = T.focus;
        const blur_fn: fn (*T) anyerror!void = T.blur;
        const mouse_fn: fn (*T, browser_input.MouseEvent) anyerror!bool = T.handleMouse;
        const key_fn: fn (*T, browser_input.KeyEvent) anyerror!bool = T.handleKey;
        const runtime_kind_fn: fn (*const T) browser_types.RuntimeKind = T.runtimeKind;
        const runtime_initialized_fn: fn (*const T) bool = T.isRuntimeInitialized;
        const runtime_mode_fn: fn (*const T) browser_types.RuntimeMode = T.runtimeMode;
        const presentation_kind_fn: fn (*const T) browser_types.PresentationKind = T.presentationKind;
        const supports_inspector_fn: fn (*const T) bool = T.supportsInspector;
        const supports_popout_fn: fn (*const T) bool = T.supportsPopout;
        const sdk_configured_fn: fn (*const T) bool = T.sdkConfigured;
        const pane_session_fn: fn (*const T) ?browser_types.SessionId = T.paneSessionId;
        const pane_texture_fn: fn (*const T) ?browser_texture.PaneTexture = T.paneTexture;
        const poll_event_fn: fn (*T) ?browser_types.Event = T.pollEvent;

        _ = init_fn;
        _ = deinit_fn;
        _ = host_window_fn;
        _ = show_fn;
        _ = hide_fn;
        _ = shutdown_fn;
        _ = resize_fn;
        _ = bounds_fn;
        _ = navigate_fn;
        _ = eval_fn;
        _ = post_json_fn;
        _ = go_back_fn;
        _ = go_forward_fn;
        _ = reload_fn;
        _ = focus_fn;
        _ = blur_fn;
        _ = mouse_fn;
        _ = key_fn;
        _ = runtime_kind_fn;
        _ = runtime_initialized_fn;
        _ = runtime_mode_fn;
        _ = presentation_kind_fn;
        _ = supports_inspector_fn;
        _ = supports_popout_fn;
        _ = sdk_configured_fn;
        _ = pane_session_fn;
        _ = pane_texture_fn;
        _ = poll_event_fn;
    }
};

test "browser backends satisfy app-facing contract" {
    comptime {
        BrowserBackend.assertImplementation(@import("controller.zig").Controller);
        BrowserBackend.assertImplementation(@import("native_webview_backend.zig").Backend);
        BrowserBackend.assertImplementation(@import("platform/linux_webkitgtk.zig").Controller);
        BrowserBackend.assertImplementation(@import("platform/macos_wkwebview.zig").Controller);
        BrowserBackend.assertImplementation(@import("platform/windows_webview2.zig").Controller);
        BrowserBackend.assertImplementation(@import("cef/backend.zig").Backend);
        BrowserBackend.assertImplementation(@import("platform/stub_backend.zig").Controller);
    }
}
