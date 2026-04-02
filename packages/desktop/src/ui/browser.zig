//! Browser dock rendering for the native shell.

const zgui = @import("zgui");

const app_state = @import("../state.zig");
const browser_runtime = @import("../browser/mod.zig");
const colors = @import("colors.zig");
const runtime = @import("runtime.zig");
const theme = @import("theme.zig");

/// Renders the browser dock that manages the in-app browser pane and bridge controls.
pub fn renderDock(state: *app_state.AppState, width: f32, height: f32) void {
    if (!state.isBrowserVisible()) return;

    zgui.pushStyleVar1f(.{ .idx = .child_rounding, .v = 0.0 });
    zgui.pushStyleVar2f(.{ .idx = .window_padding, .v = .{ 0.0, 0.0 } });
    zgui.pushStyleColor4f(.{ .idx = .child_bg, .c = colors.rgba(18, 20, 25, 255) });
    defer {
        zgui.popStyleColor(.{ .count = 1 });
        zgui.popStyleVar(.{ .count = 2 });
    }

    _ = zgui.beginChild("BrowserDock", .{
        .w = width,
        .h = height,
        .child_flags = .{
            .border = false,
            .always_use_window_padding = true,
        },
    });
    defer zgui.endChild();

    renderToolbar(state);
    renderPaneCanvas(state);
}

/// Renders the compact browser toolbar with URL entry and primary actions.
fn renderToolbar(state: *app_state.AppState) void {
    const toolbar_height = theme.scaledUi(52.0);
    zgui.pushStyleVar2f(.{ .idx = .window_padding, .v = .{ theme.scaledUi(10.0), theme.scaledUi(8.0) } });
    zgui.pushStyleColor4f(.{ .idx = .child_bg, .c = colors.rgba(18, 20, 25, 255) });
    defer {
        zgui.popStyleColor(.{ .count = 1 });
        zgui.popStyleVar(.{ .count = 1 });
    }
    _ = zgui.beginChild("BrowserToolbar", .{
        .w = 0.0,
        .h = toolbar_height,
        .child_flags = .{
            .border = false,
            .always_use_window_padding = true,
        },
        .window_flags = .{
            .no_scrollbar = true,
            .no_scroll_with_mouse = true,
        },
    });
    defer zgui.endChild();

    const browser_state = state.browserState();
    const avail = zgui.getContentRegionAvail()[0];
    const navigate_width = theme.scaledUi(40.0);
    const close_width = theme.scaledUi(36.0);
    const gap = theme.scaledUi(8.0);
    const field_width = @max(avail - navigate_width - close_width - gap * 2.0, theme.scaledUi(180.0));

    zgui.pushItemWidth(field_width);
    _ = zgui.inputTextWithHint("##browser-address", .{
        .hint = "https://example.com",
        .buf = browser_state.addressBuffer(),
    });
    zgui.popItemWidth();

    zgui.sameLine(.{ .spacing = gap });
    zgui.pushStyleColor4f(.{ .idx = .button, .c = theme.COLOR_SECONDARY_GREEN });
    zgui.pushStyleColor4f(.{ .idx = .button_hovered, .c = theme.lighten(theme.COLOR_SECONDARY_GREEN, 0.10) });
    zgui.pushStyleColor4f(.{ .idx = .button_active, .c = theme.darken(theme.COLOR_SECONDARY_GREEN, 0.10) });
    if (zgui.button("->", .{ .w = navigate_width, .h = theme.scaledUi(36.0) })) {
        state.navigateBrowserFromAddress();
    }
    zgui.popStyleColor(.{ .count = 3 });

    zgui.sameLine(.{ .spacing = gap });
    zgui.pushStyleColor4f(.{ .idx = .button, .c = theme.COLOR_PANEL_ALT });
    zgui.pushStyleColor4f(.{ .idx = .button_hovered, .c = theme.lighten(theme.COLOR_PANEL_ALT, 0.08) });
    zgui.pushStyleColor4f(.{ .idx = .button_active, .c = theme.lighten(theme.COLOR_PANEL_ALT, 0.14) });
    if (zgui.button("x", .{ .w = close_width, .h = theme.scaledUi(36.0) })) {
        state.hideBrowser();
    }
    zgui.popStyleColor(.{ .count = 3 });
}

/// Renders the in-app browser pane canvas or the current scaffold placeholder.
fn renderPaneCanvas(state: *app_state.AppState) void {
    const browser_state = state.browserState();
    const avail = zgui.getContentRegionAvail();
    const canvas_height = @max(avail[1], theme.scaledUi(180.0));
    const width_px: u32 = @intFromFloat(@max(avail[0], 1.0));
    const height_px: u32 = @intFromFloat(@max(canvas_height, 1.0));
    const input_size = .{ @as(f32, @floatFromInt(width_px)), @as(f32, @floatFromInt(height_px)) };
    browser_state.controller.resizePane(width_px, height_px) catch {};

    zgui.pushStyleVar2f(.{ .idx = .window_padding, .v = .{ 0.0, 0.0 } });
    zgui.pushStyleColor4f(.{ .idx = .child_bg, .c = colors.rgba(9, 11, 16, 255) });
    defer {
        zgui.popStyleColor(.{ .count = 1 });
        zgui.popStyleVar(.{ .count = 1 });
    }
    _ = zgui.beginChild("BrowserPaneCanvas", .{
        .w = 0.0,
        .h = canvas_height,
        .child_flags = .{
            .border = false,
        },
    });
    defer zgui.endChild();

    const pane_pos = zgui.getWindowPos();
    const pane_size = zgui.getWindowSize();
    const pane_hovered = zgui.isWindowHovered(.{});

    if (browser_state.controller.paneTexture()) |pane_texture| {
        if (pane_texture.isReady()) {
            // Preserve the browser snapshot aspect ratio so compositor-sized frames are not stretched into the pane.
            const image_size = runtime.scaledImageSize(
                @intCast(pane_texture.width),
                @intCast(pane_texture.height),
                zgui.getContentRegionAvail()[0],
                zgui.getContentRegionAvail()[1],
            );
            const x_offset = (pane_size[0] - image_size[0]) * 0.5;
            const y_offset = (pane_size[1] - image_size[1]) * 0.5;
            if (y_offset > 0.0) {
                zgui.dummy(.{ .w = 0.0, .h = y_offset });
            }
            if (x_offset > 0.0) {
                zgui.setCursorPosX(zgui.getCursorPosX() + x_offset);
            }
            const image_pos = zgui.getCursorScreenPos();
            state.noteBrowserPaneRegion(
                image_pos,
                .{ image_pos[0] + image_size[0], image_pos[1] + image_size[1] },
                input_size,
                pane_hovered,
            );
            zgui.image(runtime.textureRefFromGlId(pane_texture.texture_id), .{
                .w = image_size[0],
                .h = image_size[1],
            });
            return;
        }
    }

    // Fall back to the full pane bounds while the browser frame has not arrived yet.
    state.noteBrowserPaneRegion(
        pane_pos,
        .{ pane_pos[0] + pane_size[0], pane_pos[1] + pane_size[1] },
        input_size,
        pane_hovered,
    );

    renderPanePlaceholder(
        browser_state.controller.runtimeKind(),
        browser_state.controller.runtimeInitialized(),
        browser_state.controller.paneSessionId(),
        browser_state.controller.sdkConfigured(),
    );
}

/// Renders browser-pane scaffold details until the real CEF paint path is wired.
fn renderPanePlaceholder(
    runtime_kind: browser_runtime.RuntimeKind,
    runtime_initialized: bool,
    session_id: ?browser_runtime.SessionId,
    sdk_configured: bool,
) void {
    zgui.textColored(theme.COLOR_WHITE, "Browser Pane", .{});
    zgui.textColored(theme.COLOR_TEXT_SUBTLE, "Runtime: {s}", .{runtimeKindLabel(runtime_kind)});
    zgui.textColored(theme.COLOR_TEXT_SUBTLE, "Lazy init: {s}", .{if (runtime_initialized) "warm" else "cold"});
    zgui.textColored(theme.COLOR_TEXT_SUBTLE, "CEF SDK: {s}", .{if (sdk_configured) "configured" else "not configured"});
    if (session_id) |id| {
        zgui.textColored(theme.COLOR_TEXT_SUBTLE, "Session: {}", .{id});
    } else {
        zgui.textColored(theme.COLOR_TEXT_SUBTLE, "Session: not created yet", .{});
    }
    zgui.dummy(.{ .w = 0.0, .h = theme.scaledUi(4.0) });
    if (runtime_kind == .legacy_native) {
        zgui.textWrapped("The current native helper backend is active. On Linux it now feeds browser snapshots into this pane directly, so URL navigation and rendered page content stay inside the app layout.", .{});
        return;
    }
    if (!sdk_configured) {
        zgui.textWrapped("The in-app pane preview is active without a real CEF SDK. You can validate pane layout, lazy init, session creation, and texture presentation here before Chromium is wired in.", .{});
        return;
    }
    zgui.textWrapped("CEF is now the target runtime for the in-app browser pane. The dock is reserving a real viewport region here while the paint, input, and process bootstrap layers are integrated.", .{});
}

// Converts the runtime enum into a compact label for the browser dock.
fn runtimeKindLabel(kind: browser_runtime.RuntimeKind) []const u8 {
    return switch (kind) {
        .legacy_native => "Legacy native",
        .cef => "CEF",
    };
}
