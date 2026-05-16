const std = @import("std");
const palette = @import("palette");
const build_options = @import("build_options");

const profiler = @import("../profiler.zig");
const runtime_log = @import("../runtime_log.zig");
const runtime = @import("runtime.zig");
const theme = @import("theme.zig");

const DebugTab = enum {
    performance,
    logs,
    state,
};

const DebugHitKind = enum {
    tab,
    toggle_err,
    toggle_warn,
    toggle_info,
    toggle_debug,
    toggle_autoscroll,
    clear_logs,
};

const DebugHit = struct {
    rect: palette.Rect,
    kind: DebugHitKind,
    tab: DebugTab = .performance,
};

const MAX_DEBUG_HITS = 16;
const LINE_ADVANCE = 19.0;
const SMALL_LINE_ADVANCE = 17.0;

var active_tab: DebugTab = .performance;
var logs_autoscroll = true;
var show_err_logs = true;
var show_warn_logs = true;
var show_info_logs = true;
var show_debug_logs = true;
var debug_window_rect: palette.Rect = .{ .x = -1.0, .y = -1.0, .w = 0.0, .h = 0.0 };
var debug_hits: [MAX_DEBUG_HITS]DebugHit = undefined;
var debug_hit_count: usize = 0;

/// Renders the floating debug overlay window for inspecting UI state.
pub fn render(state: *runtime.AppState, width: f32, height: f32) void {
    if (!build_options.ui_debug) return;
    debug_hit_count = 0;

    const margin = theme.scaledUi(16.0);
    const window_width = @max(theme.scaledUi(320.0), @min(theme.scaledUi(820.0), width - margin * 2.0));
    const window_height = @max(theme.scaledUi(260.0), @min(theme.scaledUi(620.0), height - margin * 2.0));
    const rect: palette.Rect = .{
        .x = width - window_width - margin,
        .y = margin,
        .w = window_width,
        .h = window_height,
    };
    debug_window_rect = rect;

    queuePaletteRoundedRect(state, rect, paletteColor(.{ 0.06, 0.065, 0.075, 0.96 }), theme.scaledUi(10.0));
    queuePaletteBorder(state, rect, paletteColor(theme.COLOR_PANEL_MUTED), theme.scaledUi(10.0), theme.scaledUi(1.0));

    const pad = theme.scaledUi(18.0);
    var cursor_y = rect.y + pad;
    queuePaletteText(state, .{ .x = rect.x + pad, .y = cursor_y, .w = rect.w - pad * 2.0, .h = theme.scaledUi(24.0) }, "Diagnostics", paletteColor(theme.COLOR_WHITE), theme.scaledUi(18.0), rect);
    cursor_y += theme.scaledUi(24.0);
    queuePaletteText(state, .{ .x = rect.x + pad, .y = cursor_y, .w = rect.w - pad * 2.0, .h = theme.scaledUi(18.0) }, "Build flag: -Dui-debug=true", paletteColor(theme.COLOR_TEXT_MUTED), theme.scaledUi(13.0), rect);
    cursor_y += theme.scaledUi(26.0);
    queuePaletteRect(state, .{ .x = rect.x + pad, .y = cursor_y, .w = rect.w - pad * 2.0, .h = theme.scaledUi(1.0) }, paletteColor(theme.COLOR_PANEL_MUTED));
    cursor_y += theme.scaledUi(12.0);

    const tab_height = theme.scaledUi(30.0);
    const tab_gap = theme.scaledUi(8.0);
    var tab_x = rect.x + pad;
    tab_x = renderTab(state, tab_x, cursor_y, theme.scaledUi(118.0), tab_height, "Performance", .performance) + tab_gap;
    tab_x = renderTab(state, tab_x, cursor_y, theme.scaledUi(70.0), tab_height, "Logs", .logs) + tab_gap;
    _ = renderTab(state, tab_x, cursor_y, theme.scaledUi(72.0), tab_height, "State", .state);
    cursor_y += tab_height + theme.scaledUi(14.0);

    const content_rect: palette.Rect = .{
        .x = rect.x + pad,
        .y = cursor_y,
        .w = rect.w - pad * 2.0,
        .h = rect.y + rect.h - cursor_y - pad,
    };
    switch (active_tab) {
        .performance => renderPerformanceTab(state, content_rect),
        .logs => renderLogsTab(state, content_rect),
        .state => renderStateTab(state, content_rect),
    }
}

pub fn handlePaletteMouseButton(state: *runtime.AppState, x: f32, y: f32, down: bool) bool {
    _ = state;
    if (!build_options.ui_debug) return false;
    if (!paletteRectContainsPoint(debug_window_rect, x, y)) return false;
    if (!down) return true;

    var index = debug_hit_count;
    while (index > 0) {
        index -= 1;
        const hit = debug_hits[index];
        if (!paletteRectContainsPoint(hit.rect, x, y)) continue;
        switch (hit.kind) {
            .tab => active_tab = hit.tab,
            .toggle_err => show_err_logs = !show_err_logs,
            .toggle_warn => show_warn_logs = !show_warn_logs,
            .toggle_info => show_info_logs = !show_info_logs,
            .toggle_debug => show_debug_logs = !show_debug_logs,
            .toggle_autoscroll => logs_autoscroll = !logs_autoscroll,
            .clear_logs => runtime_log.clearLogEntries(),
        }
        return true;
    }
    return true;
}

fn renderPerformanceTab(state: *runtime.AppState, rect: palette.Rect) void {
    const snapshot = profiler.snapshot();
    const latest = snapshot.latest;
    var y = rect.y;
    const font_size = theme.scaledUi(13.0);
    const line_h = theme.scaledUi(LINE_ADVANCE);

    const fps = if (latest.active_ns > 0) 1_000_000_000.0 / @as(f64, @floatFromInt(latest.active_ns)) else 0.0;
    y = renderFmtLine(state, rect, y, paletteColor(theme.COLOR_WHITE), font_size, "active-frame fps estimate: {d:.1}", .{fps});
    y = renderFmtLine(state, rect, y, paletteColor(theme.COLOR_WHITE), font_size, "frames sampled: {d}", .{snapshot.count});
    y = renderFmtLine(state, rect, y, paletteColor(theme.COLOR_WHITE), font_size, "latest active frame: {d:.2} ms", .{profiler.nsToMs(latest.active_ns)});
    y = renderFmtLine(state, rect, y, paletteColor(theme.COLOR_WHITE), font_size, "latest event wait: {d:.2} ms", .{profiler.nsToMs(latest.waited_ns)});
    y = renderFmtLine(state, rect, y, paletteColor(theme.COLOR_WHITE), font_size, "average active frame: {d:.2} ms", .{profiler.nsToMs(snapshot.avg_active_ns)});
    y = renderFmtLine(state, rect, y, paletteColor(theme.COLOR_WHITE), font_size, "max active frame: {d:.2} ms", .{profiler.nsToMs(snapshot.max_active_ns)});
    y = renderFmtLine(state, rect, y, paletteColor(theme.COLOR_WHITE), font_size, "slow frames >33ms: {d}", .{snapshot.slow_count});
    y = renderFmtLine(state, rect, y, paletteColor(theme.COLOR_WHITE), font_size, "hitches >100ms: {d}", .{snapshot.hitch_count});
    y += theme.scaledUi(8.0);
    queuePaletteRect(state, .{ .x = rect.x, .y = y, .w = rect.w, .h = theme.scaledUi(1.0) }, paletteColor(theme.COLOR_PANEL_MUTED));
    y += theme.scaledUi(12.0);

    y = renderLine(state, rect, y, "Latest frame sections", paletteColor(theme.COLOR_TEXT_MUTED), font_size);
    inline for (.{ .event_handling, .poll_picker, .poll_models, .poll_send, .poll_browser, .poll_terminals, .render_setup, .render_root, .flush_dirty, .draw_backend, .swap_window }) |section| {
        if (y + line_h > rect.y + rect.h) return;
        y = renderSectionLine(state, rect, y, &latest, section, font_size);
    }

    y += theme.scaledUi(8.0);
    if (y + line_h > rect.y + rect.h) return;
    y = renderLine(state, rect, y, "Recent slow frames", paletteColor(theme.COLOR_TEXT_MUTED), font_size);
    renderRecentSlowFrames(state, .{ .x = rect.x, .y = y, .w = rect.w, .h = rect.y + rect.h - y }, font_size);
}

fn renderLogsTab(state: *runtime.AppState, rect: palette.Rect) void {
    const control_h = theme.scaledUi(26.0);
    const gap = theme.scaledUi(8.0);
    var x = rect.x;
    x = renderToggle(state, x, rect.y, theme.scaledUi(58.0), control_h, "err", show_err_logs, .toggle_err) + gap;
    x = renderToggle(state, x, rect.y, theme.scaledUi(68.0), control_h, "warn", show_warn_logs, .toggle_warn) + gap;
    x = renderToggle(state, x, rect.y, theme.scaledUi(62.0), control_h, "info", show_info_logs, .toggle_info) + gap;
    x = renderToggle(state, x, rect.y, theme.scaledUi(76.0), control_h, "debug", show_debug_logs, .toggle_debug) + gap;
    x = renderToggle(state, x, rect.y, theme.scaledUi(112.0), control_h, "autoscroll", logs_autoscroll, .toggle_autoscroll) + gap;
    _ = renderButton(state, x, rect.y, theme.scaledUi(72.0), control_h, "Clear", .clear_logs);

    const filter_y = rect.y + control_h + theme.scaledUi(10.0);
    queuePaletteRoundedRect(state, .{ .x = rect.x, .y = filter_y, .w = rect.w, .h = theme.scaledUi(30.0) }, paletteColor(theme.COLOR_PANEL_ALT), theme.scaledUi(6.0));
    queuePaletteText(state, .{ .x = rect.x + theme.scaledUi(10.0), .y = filter_y + theme.scaledUi(7.0), .w = rect.w - theme.scaledUi(20.0), .h = theme.scaledUi(17.0) }, "Log text filtering is pending Palette text-input routing", paletteColor(theme.COLOR_TEXT_SUBTLE), theme.scaledUi(12.0), rect);

    const logs_rect: palette.Rect = .{
        .x = rect.x,
        .y = filter_y + theme.scaledUi(42.0),
        .w = rect.w,
        .h = rect.y + rect.h - filter_y - theme.scaledUi(42.0),
    };
    renderLogEntries(state, logs_rect, theme.scaledUi(12.0));
}

fn renderStateTab(state: *runtime.AppState, rect: palette.Rect) void {
    var y = rect.y;
    const font_size = theme.scaledUi(13.0);
    y = renderLine(state, rect, y, "legacy capture/focus state: unavailable after debug Palette migration", paletteColor(theme.COLOR_TEXT_MUTED), font_size);
    y += theme.scaledUi(8.0);
    y = renderFmtLine(state, rect, y, paletteColor(theme.COLOR_WHITE), font_size, "composer_focused: {}", .{state.composer_focused});
    y = renderFmtLine(state, rect, y, paletteColor(theme.COLOR_WHITE), font_size, "terminal_focused: {}", .{state.terminal_focused});
    y = renderFmtLine(state, rect, y, paletteColor(theme.COLOR_WHITE), font_size, "terminal_visible: {}", .{state.isTerminalVisible()});
    y = renderFmtLine(state, rect, y, paletteColor(theme.COLOR_WHITE), font_size, "selected_project_index: {d}", .{state.selected_project_index});
    y = renderFmtLine(state, rect, y, paletteColor(theme.COLOR_WHITE), font_size, "workspace_visible_panes: {d}", .{state.debug_workspace_visible_pane_count});
    y = renderFmtLine(state, rect, y, paletteColor(theme.COLOR_WHITE), font_size, "workspace_minimized_panes: {d}", .{state.currentProjectWorkspaceMinimizedPaneCount()});
    if (state.currentProjectWorkspaceMaximizedPaneId()) |pane_id| {
        y = renderFmtLine(state, rect, y, paletteColor(theme.COLOR_WHITE), font_size, "workspace_maximized_pane: {d}", .{pane_id});
    } else {
        y = renderLine(state, rect, y, "workspace_maximized_pane: <none>", paletteColor(theme.COLOR_WHITE), font_size);
    }
    if (state.focusedWorkspacePaneKind()) |kind| {
        y = renderFmtLine(state, rect, y, paletteColor(theme.COLOR_WHITE), font_size, "workspace_focused_kind: {s}", .{@tagName(kind)});
    } else {
        y = renderLine(state, rect, y, "workspace_focused_kind: <none>", paletteColor(theme.COLOR_WHITE), font_size);
    }
    if (state.focusedWorkspaceTerminalDockId()) |dock_id| {
        y = renderFmtLine(state, rect, y, paletteColor(theme.COLOR_WHITE), font_size, "workspace_terminal_dock_id: {d}", .{dock_id});
    } else {
        y = renderLine(state, rect, y, "workspace_terminal_dock_id: <none>", paletteColor(theme.COLOR_WHITE), font_size);
    }

    if (state.projects.items.len > 0) {
        y += theme.scaledUi(8.0);
        const dock = state.currentProjectTerminal();
        y = renderFmtLine(state, rect, y, paletteColor(theme.COLOR_WHITE), font_size, "terminal_running: {}", .{dock.hasRunningSession()});
        y = renderFmtLine(state, rect, y, paletteColor(theme.COLOR_WHITE), font_size, "dock.focus_requested: {}", .{dock.focus_requested});
        y = renderFmtLine(state, rect, y, paletteColor(theme.COLOR_WHITE), font_size, "dock.visible: {}", .{dock.visible});
        y = renderFmtLine(state, rect, y, paletteColor(theme.COLOR_WHITE), font_size, "dock.font_scale: {d:.3}", .{dock.font_scale});
    }

    y += theme.scaledUi(8.0);
    y = renderFmtLine(state, rect, y, paletteColor(theme.COLOR_WHITE), font_size, "terminal.window_focused: {}", .{state.debug_terminal_window_focused});
    y = renderFmtLine(state, rect, y, paletteColor(theme.COLOR_WHITE), font_size, "terminal.hitbox_focused: {}", .{state.debug_terminal_hitbox_focused});
    y = renderFmtLine(state, rect, y, paletteColor(theme.COLOR_WHITE), font_size, "terminal.hitbox_active: {}", .{state.debug_terminal_hitbox_active});
    y = renderFmtLine(state, rect, y, paletteColor(theme.COLOR_WHITE), font_size, "terminal.hitbox_clicked: {}", .{state.debug_terminal_hitbox_clicked});
    y = renderFmtLine(state, rect, y, paletteColor(theme.COLOR_WHITE), font_size, "terminal.focus_requested(frame): {}", .{state.debug_terminal_focus_requested});
    y += theme.scaledUi(8.0);

    if (state.debug_last_terminal_scancode) |scancode| {
        y = renderFmtLine(state, rect, y, paletteColor(theme.COLOR_WHITE), font_size, "last_terminal_scancode: {s}", .{@tagName(scancode)});
    } else {
        y = renderLine(state, rect, y, "last_terminal_scancode: <none>", paletteColor(theme.COLOR_WHITE), font_size);
    }
    y = renderFmtLine(state, rect, y, paletteColor(theme.COLOR_WHITE), font_size, "last_terminal_key_handled: {}", .{state.debug_last_terminal_key_handled});
    y = renderFmtLine(state, rect, y, paletteColor(theme.COLOR_WHITE), font_size, "last_terminal_text_handled: {}", .{state.debug_last_terminal_text_handled});
    const last_text = std.mem.sliceTo(&state.debug_last_terminal_text, 0);
    _ = renderFmtLine(state, rect, y, paletteColor(theme.COLOR_WHITE), font_size, "last_terminal_text: {s}", .{last_text});
}

fn renderRecentSlowFrames(state: *runtime.AppState, rect: palette.Rect, font_size: f32) void {
    const count = profiler.frameCount();
    const start = if (count > 120) count - 120 else 0;
    var shown: usize = 0;
    var y = rect.y;
    var index = count;
    while (index > start and y + theme.scaledUi(SMALL_LINE_ADVANCE) <= rect.y + rect.h) {
        index -= 1;
        const sample = profiler.frameAt(index) orelse continue;
        if (sample.active_ns < profiler.SLOW_FRAME_NS) continue;
        y = renderFrameSummary(state, rect, y, sample, font_size);
        shown += 1;
        if (shown >= 40) break;
    }
    if (shown == 0) {
        _ = renderLine(state, rect, y, "No slow frames in the current sample window.", paletteColor(theme.COLOR_TEXT_MUTED), font_size);
    }
}

fn renderLogEntries(state: *runtime.AppState, rect: palette.Rect, font_size: f32) void {
    const count = runtime_log.logEntryCount();
    const max_visible = @max(@as(usize, 1), @as(usize, @intFromFloat(@max(rect.h, 1.0) / theme.scaledUi(SMALL_LINE_ADVANCE))));
    const start = if (count > @min(count, max_visible + 120)) count - @min(count, max_visible + 120) else 0;
    var visible: usize = 0;
    var y = rect.y;
    for (start..count) |index| {
        const entry = runtime_log.logEntryAt(index) orelse continue;
        if (!shouldShowLogEntry(&entry)) continue;
        if (visible + 1 > max_visible) break;
        y = renderLogEntry(state, rect, y, &entry, font_size);
        visible += 1;
    }
    if (visible == 0) {
        _ = renderLine(state, rect, y, "No matching log entries.", paletteColor(theme.COLOR_TEXT_MUTED), font_size);
    }
}

fn renderTab(state: *runtime.AppState, x: f32, y: f32, w: f32, h: f32, label: []const u8, tab: DebugTab) f32 {
    const rect: palette.Rect = .{ .x = x, .y = y, .w = w, .h = h };
    const selected = active_tab == tab;
    queuePaletteRoundedRect(state, rect, paletteColor(if (selected) theme.COLOR_SECONDARY_GREEN else theme.COLOR_PANEL_ALT), theme.scaledUi(7.0));
    queuePaletteText(state, .{ .x = x + theme.scaledUi(10.0), .y = y + theme.scaledUi(7.0), .w = w - theme.scaledUi(20.0), .h = h - theme.scaledUi(10.0) }, label, paletteColor(theme.COLOR_WHITE), theme.scaledUi(13.0), debug_window_rect);
    addDebugHit(rect, .{ .kind = .tab, .tab = tab });
    return x + w;
}

fn renderToggle(state: *runtime.AppState, x: f32, y: f32, w: f32, h: f32, label: []const u8, enabled: bool, kind: DebugHitKind) f32 {
    const rect: palette.Rect = .{ .x = x, .y = y, .w = w, .h = h };
    queuePaletteRoundedRect(state, rect, paletteColor(if (enabled) theme.COLOR_SECONDARY_GREEN else theme.COLOR_PANEL_ALT), theme.scaledUi(6.0));
    queuePaletteText(state, .{ .x = x + theme.scaledUi(9.0), .y = y + theme.scaledUi(6.0), .w = w - theme.scaledUi(18.0), .h = h - theme.scaledUi(8.0) }, label, paletteColor(theme.COLOR_WHITE), theme.scaledUi(12.0), debug_window_rect);
    addDebugHit(rect, .{ .kind = kind });
    return x + w;
}

fn renderButton(state: *runtime.AppState, x: f32, y: f32, w: f32, h: f32, label: []const u8, kind: DebugHitKind) f32 {
    const rect: palette.Rect = .{ .x = x, .y = y, .w = w, .h = h };
    queuePaletteRoundedRect(state, rect, paletteColor(theme.COLOR_PANEL_ALT), theme.scaledUi(6.0));
    queuePaletteBorder(state, rect, paletteColor(theme.COLOR_PANEL_MUTED), theme.scaledUi(6.0), theme.scaledUi(1.0));
    queuePaletteText(state, .{ .x = x + theme.scaledUi(12.0), .y = y + theme.scaledUi(6.0), .w = w - theme.scaledUi(24.0), .h = h - theme.scaledUi(8.0) }, label, paletteColor(theme.COLOR_WHITE), theme.scaledUi(12.0), debug_window_rect);
    addDebugHit(rect, .{ .kind = kind });
    return x + w;
}

fn renderSectionLine(state: *runtime.AppState, rect: palette.Rect, y: f32, sample: *const profiler.FrameSample, section: profiler.Section, font_size: f32) f32 {
    return renderFmtLine(state, rect, y, paletteColor(theme.COLOR_WHITE), font_size, "{s}: {d:.2} ms", .{ profiler.sectionName(section), profiler.nsToMs(sample.sectionNs(section)) });
}

fn renderFrameSummary(state: *runtime.AppState, rect: palette.Rect, y: f32, sample: profiler.FrameSample, font_size: f32) f32 {
    const rendered = if (sample.rendered) "rendered" else "poll-only";
    return renderFmtLine(
        state,
        rect,
        y,
        paletteColor(frameColor(sample.active_ns)),
        font_size,
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
    );
}

fn renderLogEntry(state: *runtime.AppState, rect: palette.Rect, y: f32, entry: *const runtime_log.LogEntry, font_size: f32) f32 {
    const suffix = if (entry.truncated) " ..." else "";
    return renderFmtLine(
        state,
        rect,
        y,
        paletteColor(logColor(entry.level)),
        font_size,
        "#{d} {d} [{s}] ({s}) {s}{s}",
        .{
            entry.sequence,
            entry.timestamp_ms,
            logLevelText(entry.level),
            entry.scopeSlice(),
            entry.messageSlice(),
            suffix,
        },
    );
}

fn renderFmtLine(state: *runtime.AppState, rect: palette.Rect, y: f32, color: palette.Color, font_size: f32, comptime fmt: []const u8, args: anytype) f32 {
    var line: [1024]u8 = undefined;
    const formatted = std.fmt.bufPrint(&line, fmt, args) catch "diagnostic line unavailable";
    return renderLine(state, rect, y, formatted, color, font_size);
}

fn renderLine(state: *runtime.AppState, rect: palette.Rect, y: f32, value: []const u8, color: palette.Color, font_size: f32) f32 {
    const line_h = theme.scaledUi(SMALL_LINE_ADVANCE);
    queuePaletteText(state, .{ .x = rect.x, .y = y, .w = rect.w, .h = line_h }, value, color, font_size, rect);
    return y + line_h;
}

fn shouldShowLogEntry(entry: *const runtime_log.LogEntry) bool {
    return switch (entry.level) {
        .err => show_err_logs,
        .warn => show_warn_logs,
        .info => show_info_logs,
        .debug => show_debug_logs,
    };
}

fn addDebugHit(rect: palette.Rect, hit: DebugHit) void {
    if (debug_hit_count >= debug_hits.len) return;
    debug_hits[debug_hit_count] = .{
        .rect = rect,
        .kind = hit.kind,
        .tab = hit.tab,
    };
    debug_hit_count += 1;
}

fn paletteRectContainsPoint(rect: palette.Rect, x: f32, y: f32) bool {
    return x >= rect.x and y >= rect.y and x <= rect.x + rect.w and y <= rect.y + rect.h;
}

fn queuePaletteRect(state: *runtime.AppState, rect: palette.Rect, color: palette.Color) void {
    state.palette_overlay_batch.rect(state.allocator, rect, color) catch |err| {
        runtime.log.warn("failed to queue debug palette rect: {s}", .{@errorName(err)});
    };
}

fn queuePaletteRoundedRect(state: *runtime.AppState, rect: palette.Rect, color: palette.Color, radius: f32) void {
    state.palette_overlay_batch.roundedRect(state.allocator, rect, color, radius) catch |err| {
        runtime.log.warn("failed to queue debug palette rounded rect: {s}", .{@errorName(err)});
    };
}

fn queuePaletteBorder(state: *runtime.AppState, rect: palette.Rect, color: palette.Color, radius: f32, width: f32) void {
    state.palette_overlay_batch.rectBorder(state.allocator, rect, color, radius, width) catch |err| {
        runtime.log.warn("failed to queue debug palette border: {s}", .{@errorName(err)});
    };
}

fn queuePaletteText(state: *runtime.AppState, rect: palette.Rect, value: []const u8, color: palette.Color, font_size: f32, clip: ?palette.Rect) void {
    const stable_value = stablePaletteText(state, value) catch |err| {
        runtime.log.warn("failed to retain debug palette text: {s}", .{@errorName(err)});
        return;
    };
    state.palette_overlay_batch.fixedText(
        state.allocator,
        rect,
        stable_value,
        color,
        font_size,
        clip,
        .{},
        font_size * 0.55,
        font_size * 1.25,
        false,
    ) catch |err| {
        runtime.log.warn("failed to queue debug palette text: {s}", .{@errorName(err)});
    };
}

fn stablePaletteText(state: *runtime.AppState, value: []const u8) ![]const u8 {
    return try state.palette_frame_text_arena.allocator().dupe(u8, value);
}

fn paletteColor(value: [4]f32) palette.Color {
    return .{ .r = value[0], .g = value[1], .b = value[2], .a = value[3] };
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
