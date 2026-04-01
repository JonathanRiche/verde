const std = @import("std");
const zgui = @import("zgui");
const build_options = @import("build_options");

const runtime = @import("runtime.zig");
const theme = @import("theme.zig");

pub fn render(state: *runtime.AppState, width: f32, _: f32) void {
    if (!build_options.ui_debug) return;

    const window_width = theme.scaledUi(360.0);
    zgui.setNextWindowPos(.{
        .x = width - window_width - theme.scaledUi(16.0),
        .y = theme.scaledUi(16.0),
        .cond = .always,
    });
    zgui.setNextWindowSize(.{
        .w = window_width,
        .h = 0.0,
        .cond = .always,
    });
    zgui.setNextWindowBgAlpha(.{ .alpha = 0.96 });

    _ = zgui.begin("UI Debug", .{
        .flags = .{
            .no_saved_settings = true,
            .always_auto_resize = true,
        },
    });
    defer zgui.end();

    zgui.textColored(theme.COLOR_WHITE, "UI Debug", .{});
    zgui.textColored(theme.COLOR_TEXT_MUTED, "Build flag: -Dui-debug=true", .{});
    zgui.separator();

    zgui.text("fps: {d:.1}", .{zgui.io.getFramerate()});
    zgui.text("imgui.want_capture_keyboard: {}", .{zgui.io.getWantCaptureKeyboard()});
    zgui.text("imgui.want_text_input: {}", .{zgui.io.getWantTextInput()});
    zgui.text("imgui.want_capture_mouse: {}", .{zgui.io.getWantCaptureMouse()});
    zgui.text("imgui.any_item_focused: {}", .{zgui.isAnyItemFocused()});
    zgui.text("imgui.any_item_active: {}", .{zgui.isAnyItemActive()});
    zgui.separator();

    zgui.text("composer_focused: {}", .{state.composer_focused});
    zgui.text("terminal_focused: {}", .{state.terminal_focused});
    zgui.text("terminal_visible: {}", .{state.isTerminalVisible()});
    zgui.text("selected_project_index: {d}", .{state.selected_project_index});

    if (state.projects.items.len > 0) {
        const dock = state.currentProjectTerminal();
        zgui.text("terminal_running: {}", .{dock.hasRunningSession()});
        zgui.text("dock.focus_requested: {}", .{dock.focus_requested});
        zgui.text("dock.visible: {}", .{dock.visible});
        zgui.text("dock.font_scale: {d:.3}", .{dock.font_scale});
    }

    zgui.separator();
    zgui.text("terminal.window_focused: {}", .{state.debug_terminal_window_focused});
    zgui.text("terminal.hitbox_focused: {}", .{state.debug_terminal_hitbox_focused});
    zgui.text("terminal.hitbox_active: {}", .{state.debug_terminal_hitbox_active});
    zgui.text("terminal.hitbox_clicked: {}", .{state.debug_terminal_hitbox_clicked});
    zgui.text("terminal.focus_requested(frame): {}", .{state.debug_terminal_focus_requested});
    zgui.separator();

    if (state.debug_last_terminal_scancode) |scancode| {
        zgui.text("last_terminal_scancode: {s}", .{@tagName(scancode)});
    } else {
        zgui.textUnformatted("last_terminal_scancode: <none>");
    }
    zgui.text("last_terminal_key_handled: {}", .{state.debug_last_terminal_key_handled});
    zgui.text("last_terminal_text_handled: {}", .{state.debug_last_terminal_text_handled});
    const last_text = std.mem.sliceTo(&state.debug_last_terminal_text, 0);
    zgui.text("last_terminal_text: {s}", .{last_text});
}
