//! Browser control surface rendering for the native shell.

const zgui = @import("zgui");

const colors = @import("colors.zig");
const runtime = @import("runtime.zig");
const theme = @import("theme.zig");

/// Renders the floating browser control window that will drive the native webview runtime.
pub fn render(state: *runtime.AppState, width: f32, height: f32) void {
    const browser_state = state.browserState();
    if (!browser_state.controls_visible) return;

    zgui.setNextWindowPos(.{
        .x = width * 0.5,
        .y = height * 0.5,
        .cond = .appearing,
        .pivot_x = 0.5,
        .pivot_y = 0.5,
    });
    zgui.setNextWindowSize(.{
        .w = theme.clampf(width * 0.42, theme.scaledUi(420.0), theme.scaledUi(760.0)),
        .h = 0.0,
        .cond = .appearing,
    });
    zgui.pushStyleVar1f(.{ .idx = .window_rounding, .v = theme.scaledUi(16.0) });
    zgui.pushStyleVar2f(.{ .idx = .window_padding, .v = .{ theme.scaledUi(18.0), theme.scaledUi(18.0) } });
    zgui.pushStyleVar2f(.{ .idx = .item_spacing, .v = .{ theme.scaledUi(10.0), theme.scaledUi(10.0) } });
    defer zgui.popStyleVar(.{ .count = 3 });

    var open = true;
    if (!zgui.begin("Browser Controls", .{
        .popen = &open,
        .flags = .{
            .no_saved_settings = true,
        },
    })) {
        zgui.end();
        if (!open) state.hideBrowser();
        return;
    }
    defer zgui.end();

    if (!open) {
        state.hideBrowser();
        return;
    }

    renderBrowserSummary(state);
    renderBrowserAddressBar(state);
    renderBrowserDetails(state);
}

/// Renders the browser status banner and implementation note.
fn renderBrowserSummary(state: *runtime.AppState) void {
    const browser_state = state.browserStateConst();
    zgui.textColored(theme.COLOR_WHITE, "Native browser scaffold", .{});
    zgui.textColored(theme.COLOR_TEXT_SUBTLE, "Status: {s}", .{browser_state.statusLabel()});
    zgui.textWrapped("The desktop UI and app-state seams are in place. Native WebView2, WKWebView, and WebKitGTK shims still need to replace the temporary stub backend.", .{});
}

/// Renders the browser address input row and primary actions.
fn renderBrowserAddressBar(state: *runtime.AppState) void {
    const browser_state = state.browserState();
    const avail = zgui.getContentRegionAvail();
    const button_width = theme.scaledUi(96.0);
    const close_width = theme.scaledUi(72.0);
    const field_spacing = theme.scaledUi(8.0);
    const field_width = @max(avail[0] - button_width - close_width - field_spacing * 2.0, theme.scaledUi(180.0));

    zgui.pushItemWidth(field_width);
    _ = zgui.inputTextWithHint("##browser-address", .{
        .hint = "https://example.com",
        .buf = browser_state.addressBuffer(),
    });
    zgui.popItemWidth();

    zgui.sameLine(.{ .spacing = field_spacing });
    zgui.pushStyleColor4f(.{ .idx = .button, .c = theme.COLOR_SECONDARY_GREEN });
    zgui.pushStyleColor4f(.{ .idx = .button_hovered, .c = theme.lighten(theme.COLOR_SECONDARY_GREEN, 0.10) });
    zgui.pushStyleColor4f(.{ .idx = .button_active, .c = theme.darken(theme.COLOR_SECONDARY_GREEN, 0.10) });
    if (zgui.button("Open URL", .{ .w = button_width, .h = theme.scaledUi(38.0) })) {
        state.navigateBrowserFromAddress();
    }
    zgui.popStyleColor(.{ .count = 3 });

    zgui.sameLine(.{ .spacing = field_spacing });
    zgui.pushStyleColor4f(.{ .idx = .button, .c = theme.COLOR_PANEL_ALT });
    zgui.pushStyleColor4f(.{ .idx = .button_hovered, .c = theme.lighten(theme.COLOR_PANEL_ALT, 0.08) });
    zgui.pushStyleColor4f(.{ .idx = .button_active, .c = theme.lighten(theme.COLOR_PANEL_ALT, 0.14) });
    if (zgui.button("Close", .{ .w = close_width, .h = theme.scaledUi(38.0) })) {
        state.hideBrowser();
    }
    zgui.popStyleColor(.{ .count = 3 });
}

/// Renders the current URL and last error surfaced by browser state.
fn renderBrowserDetails(state: *runtime.AppState) void {
    const browser_state = state.browserStateConst();
    zgui.separator();
    if (browser_state.current_url) |url| {
        zgui.textColored(theme.COLOR_WHITE, "Current URL", .{});
        zgui.textWrapped("{s}", .{url});
    } else {
        zgui.textColored(theme.COLOR_TEXT_SUBTLE, "No page loaded yet.", .{});
    }

    if (browser_state.last_error) |message| {
        zgui.dummy(.{ .w = 0.0, .h = theme.scaledUi(4.0) });
        zgui.textColored(colors.rgba(255, 182, 72, 255), "Last error", .{});
        zgui.textWrapped("{s}", .{message});
    }
}
