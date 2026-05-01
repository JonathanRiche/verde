const std = @import("std");
const zgui = @import("zgui");
const build_options = @import("build_options");

const profiler = @import("../profiler.zig");
const runtime_log = @import("../runtime_log.zig");
const runtime = @import("runtime.zig");
const theme = @import("theme.zig");

var log_filter_storage: [128:0]u8 = std.mem.zeroes([128:0]u8);
var logs_autoscroll = true;
var show_err_logs = true;
var show_warn_logs = true;
var show_info_logs = true;
var show_debug_logs = true;

/// Renders the floating debug overlay window for inspecting UI state.
pub fn render(state: *runtime.AppState, width: f32, height: f32) void {
    if (!build_options.ui_debug) return;

    const window_width = @min(theme.scaledUi(820.0), width - theme.scaledUi(32.0));
    const window_height = @min(theme.scaledUi(620.0), height - theme.scaledUi(32.0));
    zgui.setNextWindowPos(.{
        .x = width - window_width - theme.scaledUi(16.0),
        .y = theme.scaledUi(16.0),
        .cond = .appearing,
    });
    zgui.setNextWindowSize(.{
        .w = window_width,
        .h = window_height,
        .cond = .appearing,
    });
    zgui.setNextWindowBgAlpha(.{ .alpha = 0.96 });

    _ = zgui.begin("Diagnostics", .{
        .flags = .{
            .no_saved_settings = true,
        },
    });
    defer zgui.end();

    zgui.textColored(theme.COLOR_WHITE, "Diagnostics", .{});
    zgui.textColored(theme.COLOR_TEXT_MUTED, "Build flag: -Dui-debug=true", .{});
    zgui.separator();

    if (zgui.beginTabBar("##diagnostics-tabs", .{})) {
        if (zgui.beginTabItem("Performance", .{})) {
            renderPerformanceTab();
            zgui.endTabItem();
        }
        if (zgui.beginTabItem("Logs", .{})) {
            renderLogsTab();
            zgui.endTabItem();
        }
        if (zgui.beginTabItem("State", .{})) {
            renderStateTab(state);
            zgui.endTabItem();
        }
        zgui.endTabBar();
    }
}

fn renderPerformanceTab() void {
    const snapshot = profiler.snapshot();
    const latest = snapshot.latest;

    zgui.text("fps: {d:.1}", .{zgui.io.getFramerate()});
    zgui.text("frames sampled: {d}", .{snapshot.count});
    zgui.text("latest active frame: {d:.2} ms", .{profiler.nsToMs(latest.active_ns)});
    zgui.text("latest event wait: {d:.2} ms", .{profiler.nsToMs(latest.waited_ns)});
    zgui.text("average active frame: {d:.2} ms", .{profiler.nsToMs(snapshot.avg_active_ns)});
    zgui.text("max active frame: {d:.2} ms", .{profiler.nsToMs(snapshot.max_active_ns)});
    zgui.text("slow frames >33ms: {d}", .{snapshot.slow_count});
    zgui.text("hitches >100ms: {d}", .{snapshot.hitch_count});
    zgui.separator();

    zgui.textColored(theme.COLOR_TEXT_MUTED, "Latest frame sections", .{});
    renderSectionLine(&latest, .event_handling);
    renderSectionLine(&latest, .poll_picker);
    renderSectionLine(&latest, .poll_models);
    renderSectionLine(&latest, .poll_send);
    renderSectionLine(&latest, .poll_browser);
    renderSectionLine(&latest, .poll_terminals);
    renderSectionLine(&latest, .render_setup);
    renderSectionLine(&latest, .render_root);
    renderSectionLine(&latest, .flush_dirty);
    renderSectionLine(&latest, .draw_backend);
    renderSectionLine(&latest, .swap_window);
    zgui.separator();

    zgui.textColored(theme.COLOR_TEXT_MUTED, "Recent slow frames", .{});
    _ = zgui.beginChild("##slow-frames", .{
        .h = theme.scaledUi(180.0),
        .window_flags = .{ .horizontal_scrollbar = true },
    });
    defer zgui.endChild();

    const count = profiler.frameCount();
    const start = if (count > 120) count - 120 else 0;
    var shown: usize = 0;
    var index = count;
    while (index > start) {
        index -= 1;
        const sample = profiler.frameAt(index) orelse continue;
        if (sample.active_ns < profiler.SLOW_FRAME_NS) continue;
        renderFrameSummary(sample);
        shown += 1;
        if (shown >= 40) break;
    }
    if (shown == 0) {
        zgui.textUnformatted("No slow frames in the current sample window.");
    }
}

fn renderLogsTab() void {
    _ = zgui.checkbox("err", .{ .v = &show_err_logs });
    zgui.sameLine(.{ .spacing = theme.scaledUi(10.0) });
    _ = zgui.checkbox("warn", .{ .v = &show_warn_logs });
    zgui.sameLine(.{ .spacing = theme.scaledUi(10.0) });
    _ = zgui.checkbox("info", .{ .v = &show_info_logs });
    zgui.sameLine(.{ .spacing = theme.scaledUi(10.0) });
    _ = zgui.checkbox("debug", .{ .v = &show_debug_logs });
    zgui.sameLine(.{ .spacing = theme.scaledUi(16.0) });
    _ = zgui.checkbox("autoscroll", .{ .v = &logs_autoscroll });
    zgui.sameLine(.{ .spacing = theme.scaledUi(16.0) });
    if (zgui.button("Clear", .{ .w = theme.scaledUi(72.0), .h = theme.scaledUi(28.0) })) {
        runtime_log.clearLogEntries();
    }

    zgui.pushItemWidth(-1.0);
    _ = zgui.inputTextWithHint("##diagnostics-log-filter", .{
        .hint = "filter logs by message or scope",
        .buf = log_filter_storage[0..],
    });
    zgui.popItemWidth();

    _ = zgui.beginChild("##diagnostics-logs", .{
        .h = 0.0,
        .window_flags = .{ .horizontal_scrollbar = true },
    });
    defer zgui.endChild();

    const filter = std.mem.sliceTo(&log_filter_storage, 0);
    const count = runtime_log.logEntryCount();
    const start = if (count > 350) count - 350 else 0;
    var visible: usize = 0;
    for (start..count) |index| {
        const entry = runtime_log.logEntryAt(index) orelse continue;
        if (!shouldShowLogEntry(&entry, filter)) continue;
        renderLogEntry(&entry);
        visible += 1;
    }
    if (visible == 0) {
        zgui.textUnformatted("No matching log entries.");
    } else if (logs_autoscroll) {
        zgui.setScrollHereY(.{ .center_y_ratio = 1.0 });
    }
}

fn renderStateTab(state: *runtime.AppState) void {
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

fn renderSectionLine(sample: *const profiler.FrameSample, section: profiler.Section) void {
    zgui.text("{s}: {d:.2} ms", .{ profiler.sectionName(section), profiler.nsToMs(sample.sectionNs(section)) });
}

fn renderFrameSummary(sample: profiler.FrameSample) void {
    var line: [512]u8 = undefined;
    const rendered = if (sample.rendered) "rendered" else "poll-only";
    const formatted = std.fmt.bufPrint(
        &line,
        "#{d} {s} active={d:.2}ms wait={d:.2}ms events={d:.2}ms render={d:.2}ms browser={d:.2}ms terminals={d:.2}ms swap={d:.2}ms",
        .{
            sample.sequence,
            rendered,
            profiler.nsToMs(sample.active_ns),
            profiler.nsToMs(sample.waited_ns),
            profiler.nsToMs(sample.sectionNs(.event_handling)),
            profiler.nsToMs(sample.sectionNs(.render_root)),
            profiler.nsToMs(sample.sectionNs(.poll_browser)),
            profiler.nsToMs(sample.sectionNs(.poll_terminals)),
            profiler.nsToMs(sample.sectionNs(.swap_window)),
        },
    ) catch "slow frame summary unavailable";
    zgui.textUnformattedColored(frameColor(sample.active_ns), formatted);
}

fn renderLogEntry(entry: *const runtime_log.LogEntry) void {
    var line: [896]u8 = undefined;
    const suffix = if (entry.truncated) " ..." else "";
    const formatted = std.fmt.bufPrint(
        &line,
        "#{d} {d} [{s}] ({s}) {s}{s}",
        .{
            entry.sequence,
            entry.timestamp_ms,
            logLevelText(entry.level),
            entry.scopeSlice(),
            entry.messageSlice(),
            suffix,
        },
    ) catch "log entry unavailable";
    zgui.textUnformattedColored(logColor(entry.level), formatted);
}

fn shouldShowLogEntry(entry: *const runtime_log.LogEntry, filter: []const u8) bool {
    switch (entry.level) {
        .err => if (!show_err_logs) return false,
        .warn => if (!show_warn_logs) return false,
        .info => if (!show_info_logs) return false,
        .debug => if (!show_debug_logs) return false,
    }
    if (filter.len == 0) return true;
    return std.mem.indexOf(u8, entry.messageSlice(), filter) != null or
        std.mem.indexOf(u8, entry.scopeSlice(), filter) != null;
}

fn logColor(level: std.log.Level) [4]f32 {
    return switch (level) {
        .err => theme.COLOR_DIFF_REMOVE,
        .warn => theme.COLOR_YELLOW,
        .info => theme.COLOR_WHITE,
        .debug => theme.COLOR_TEXT_MUTED,
    };
}

fn logLevelText(level: std.log.Level) []const u8 {
    return switch (level) {
        .err => "error",
        .warn => "warning",
        .info => "info",
        .debug => "debug",
    };
}

fn frameColor(active_ns: u64) [4]f32 {
    if (active_ns >= profiler.HITCH_FRAME_NS) return theme.COLOR_DIFF_REMOVE;
    if (active_ns >= profiler.SLOW_FRAME_NS) return theme.COLOR_YELLOW;
    return theme.COLOR_WHITE;
}
