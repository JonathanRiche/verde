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
    zgui.pushStyleVar2f(.{ .idx = .window_padding, .v = .{ theme.scaledUi(18.0), theme.scaledUi(14.0) } });
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

    renderHeader(state);
    zgui.separator();
    renderAddressBar(state);
    renderPaneCanvas(state);
    renderScriptTools(state);
    renderDetails(state);
}

/// Renders the browser dock header row and window-management actions.
fn renderHeader(state: *app_state.AppState) void {
    const browser_state = state.browserStateConst();
    const avail = zgui.getContentRegionAvail()[0];
    const close_width = theme.scaledUi(68.0);
    const popout_label = if (browser_state.status == .hidden) "Open window" else "Pop out";
    const popout_width = theme.clampf(
        zgui.calcTextSize(popout_label, .{})[0] + theme.scaledUi(28.0),
        theme.scaledUi(96.0),
        theme.scaledUi(132.0),
    );
    const gap = theme.scaledUi(8.0);
    const label_width = @max(avail - close_width - popout_width - gap * 2.0, theme.scaledUi(160.0));

    zgui.pushTextWrapPos(zgui.getCursorScreenPos()[0] + label_width);
    zgui.textColored(theme.COLOR_WHITE, "Browser", .{});
    zgui.textColored(theme.COLOR_TEXT_SUBTLE, "Status: {s}", .{browser_state.statusLabel()});
    zgui.popTextWrapPos();

    const cursor_y = zgui.getCursorPosY() - theme.scaledUi(34.0);
    zgui.setCursorPos(.{ @max(zgui.getCursorPosX(), avail - close_width - popout_width - gap), cursor_y });
    zgui.beginDisabled(.{ .disabled = !browser_state.controller.supportsPopout() });
    zgui.pushStyleColor4f(.{ .idx = .button, .c = theme.COLOR_PANEL_ALT });
    zgui.pushStyleColor4f(.{ .idx = .button_hovered, .c = theme.lighten(theme.COLOR_PANEL_ALT, 0.08) });
    zgui.pushStyleColor4f(.{ .idx = .button_active, .c = theme.lighten(theme.COLOR_PANEL_ALT, 0.14) });
    if (zgui.button(popout_label, .{ .w = popout_width, .h = theme.scaledUi(32.0) })) {
        state.reopenBrowserWindow();
    }
    zgui.popStyleColor(.{ .count = 3 });
    zgui.endDisabled();

    zgui.sameLine(.{ .spacing = gap });
    zgui.pushStyleColor4f(.{ .idx = .button, .c = theme.COLOR_PANEL_ALT });
    zgui.pushStyleColor4f(.{ .idx = .button_hovered, .c = theme.lighten(theme.COLOR_PANEL_ALT, 0.08) });
    zgui.pushStyleColor4f(.{ .idx = .button_active, .c = theme.lighten(theme.COLOR_PANEL_ALT, 0.14) });
    if (zgui.button("Close", .{ .w = close_width, .h = theme.scaledUi(32.0) })) {
        state.hideBrowser();
    }
    zgui.popStyleColor(.{ .count = 3 });
}

/// Renders the browser URL input row and primary navigation action.
fn renderAddressBar(state: *app_state.AppState) void {
    const browser_state = state.browserState();
    const avail = zgui.getContentRegionAvail()[0];
    const button_width = theme.scaledUi(96.0);
    const gap = theme.scaledUi(8.0);
    const field_width = @max(avail - button_width - gap, theme.scaledUi(180.0));

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
    if (zgui.button("Open URL", .{ .w = button_width, .h = theme.scaledUi(36.0) })) {
        state.navigateBrowserFromAddress();
    }
    zgui.popStyleColor(.{ .count = 3 });
}

/// Renders the in-app browser pane canvas or the current scaffold placeholder.
fn renderPaneCanvas(state: *app_state.AppState) void {
    const browser_state = state.browserState();
    const avail = zgui.getContentRegionAvail();
    const reserved_detail_height = theme.scaledUi(180.0);
    const canvas_height = theme.clampf(
        avail[1] * 0.68,
        theme.scaledUi(180.0),
        @max(avail[1] - reserved_detail_height, theme.scaledUi(180.0)),
    );
    const width_px: u32 = @intFromFloat(@max(avail[0], 1.0));
    const height_px: u32 = @intFromFloat(@max(canvas_height, 1.0));
    browser_state.controller.resizePane(width_px, height_px) catch {};

    zgui.pushStyleColor4f(.{ .idx = .child_bg, .c = colors.rgba(9, 11, 16, 255) });
    defer zgui.popStyleColor(.{ .count = 1 });
    _ = zgui.beginChild("BrowserPaneCanvas", .{
        .w = 0.0,
        .h = canvas_height,
        .child_flags = .{
            .border = true,
            .always_use_window_padding = true,
        },
    });
    defer zgui.endChild();

    // Track the pane bounds in framebuffer-space so SDL input can be remapped into browser-local coordinates.
    const pane_pos = zgui.getWindowPos();
    const pane_size = zgui.getWindowSize();
    state.noteBrowserPaneRegion(
        pane_pos,
        .{ pane_pos[0] + pane_size[0], pane_pos[1] + pane_size[1] },
        zgui.isWindowHovered(.{}),
    );

    if (browser_state.controller.paneTexture()) |pane_texture| {
        if (pane_texture.isReady()) {
            zgui.image(runtime.textureRefFromGlId(pane_texture.texture_id), .{
                .w = @floatFromInt(pane_texture.width),
                .h = @floatFromInt(pane_texture.height),
            });
            return;
        }
    }

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

/// Renders the JavaScript eval and JSON bridge controls for the active browser session.
fn renderScriptTools(state: *app_state.AppState) void {
    const browser_state = state.browserState();
    const avail = zgui.getContentRegionAvail()[0];
    const action_width = theme.scaledUi(108.0);
    const gap = theme.scaledUi(8.0);

    zgui.dummy(.{ .w = 0.0, .h = theme.scaledUi(2.0) });
    zgui.textColored(theme.COLOR_WHITE, "JavaScript", .{});
    _ = zgui.inputTextMultiline("##browser-script", .{
        .buf = browser_state.scriptBuffer(),
        .w = 0.0,
        .h = theme.scaledUi(84.0),
    });
    zgui.pushStyleColor4f(.{ .idx = .button, .c = theme.COLOR_PANEL_ALT });
    zgui.pushStyleColor4f(.{ .idx = .button_hovered, .c = theme.lighten(theme.COLOR_PANEL_ALT, 0.08) });
    zgui.pushStyleColor4f(.{ .idx = .button_active, .c = theme.lighten(theme.COLOR_PANEL_ALT, 0.14) });
    if (zgui.button("Eval JS", .{ .w = action_width, .h = theme.scaledUi(32.0) })) {
        state.evalBrowserScript();
    }
    zgui.popStyleColor(.{ .count = 3 });

    zgui.dummy(.{ .w = 0.0, .h = theme.scaledUi(2.0) });
    zgui.textColored(theme.COLOR_WHITE, "JSON Bridge", .{});
    zgui.pushItemWidth(@max(avail - action_width - gap, theme.scaledUi(180.0)));
    _ = zgui.inputTextWithHint("##browser-json", .{
        .hint = "{\"type\":\"ping\"}",
        .buf = browser_state.jsonBuffer(),
    });
    zgui.popItemWidth();
    zgui.sameLine(.{ .spacing = gap });
    zgui.pushStyleColor4f(.{ .idx = .button, .c = theme.COLOR_PANEL_ALT });
    zgui.pushStyleColor4f(.{ .idx = .button_hovered, .c = theme.lighten(theme.COLOR_PANEL_ALT, 0.08) });
    zgui.pushStyleColor4f(.{ .idx = .button_active, .c = theme.lighten(theme.COLOR_PANEL_ALT, 0.14) });
    if (zgui.button("Send JSON", .{ .w = action_width, .h = theme.scaledUi(32.0) })) {
        state.postBrowserJsonFromInput();
    }
    zgui.popStyleColor(.{ .count = 3 });
}

/// Renders the current browser URL, errors, and the latest bridge outputs.
fn renderDetails(state: *app_state.AppState) void {
    const browser_state = state.browserStateConst();
    zgui.separator();
    if (browser_state.status == .hidden and state.isBrowserVisible()) {
        zgui.textColored(theme.COLOR_TEXT_SUBTLE, "The browser pane is hidden. Reopen Browser from the header to show it again.", .{});
    }

    if (browser_state.current_url) |url| {
        zgui.textColored(theme.COLOR_WHITE, "Current URL", .{});
        zgui.textWrapped("{s}", .{url});
    } else {
        zgui.textColored(theme.COLOR_TEXT_SUBTLE, "No page loaded yet.", .{});
    }

    if (browser_state.last_error) |message| {
        zgui.textColored(colors.rgba(255, 182, 72, 255), "Last error", .{});
        zgui.textWrapped("{s}", .{message});
    }

    if (browser_state.last_eval_result) |result| {
        zgui.textColored(theme.COLOR_WHITE, "Last eval result", .{});
        zgui.textWrapped("{s}", .{result});
    }

    if (browser_state.last_js_message) |message| {
        zgui.textColored(theme.COLOR_WHITE, "Last bridge message", .{});
        zgui.textWrapped("{s}", .{message});
    }

    zgui.textColored(theme.COLOR_TEXT_SUBTLE, "Runtime mode: {s}", .{runtimeModeLabel(browser_state.controller.runtimeMode())});
}

// Converts the runtime enum into a compact label for the browser dock.
fn runtimeKindLabel(kind: browser_runtime.RuntimeKind) []const u8 {
    return switch (kind) {
        .legacy_native => "Legacy native",
        .cef => "CEF",
    };
}

// Converts the runtime lifetime mode into a compact label for the browser dock.
fn runtimeModeLabel(mode: browser_runtime.RuntimeMode) []const u8 {
    return switch (mode) {
        .keep_warm => "Keep warm",
        .shutdown_on_close => "Shutdown on close",
    };
}
