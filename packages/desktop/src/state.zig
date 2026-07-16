const std = @import("std");
const builtin = @import("builtin");
const palette = @import("palette");
const sdl = @import("zsdl3");
const profiler = @import("profiler.zig");
const chat_markdown = @import("ui/chat_markdown.zig");
const app_config = @import("config.zig");
const ai_harness = @import("harness.zig");
const browser_inspector = @import("browser/inspector.zig");
const browser_runtime = @import("browser/mod.zig");
const chat_threads = @import("chat/threads.zig");
const db_client = @import("db/client.zig");
const db_types = @import("db/types.zig");
const fff = @import("fff.zig");
const herdr = @import("herdr.zig");
const keybinds = @import("keybinds.zig");
const loop_wakeup = @import("loop_wakeup.zig");
const notifier = @import("notifier.zig");
const platform_paths = @import("platform_paths");
const platform_runtime = @import("platform_runtime");
const platform_process = @import("platform/process.zig");
const process_env = @import("process_env.zig");
const provider_hooks = @import("provider_hooks.zig");
const runtime_log = @import("runtime_log.zig");
const slash_commands = @import("slash_commands.zig");
const stack_config = @import("stack.zig");
const stb_image = @import("stb_image.zig");
const sessionizer = @import("terminal/sessionizer.zig");
const terminal = @import("terminal/terminal.zig");
const theme = @import("ui/theme.zig");
const text_measure = @import("ui/text_measure.zig");
const updater = @import("updater.zig");
const update_installer = @import("update_installer.zig");
const utils = @import("utils.zig");

/// Arrow-key line step for transcript scroll (scaled px per key repeat).
const TRANSCRIPT_KEYBOARD_LINE_PX: f32 = 29.0;
const STACK_CONFIG_REFRESH_MS: i64 = 2000;
const BACKGROUND_TASK_POLL_MS: i64 = 1000;
const MANAGED_PROCESS_BASE_RESTART_BACKOFF_MS: i64 = 1000;
const MANAGED_PROCESS_MAX_RESTART_BACKOFF_MS: i64 = 30000;
const MANAGED_PROCESS_WATCH_SCAN_MS: i64 = 1000;
const MANAGED_PROCESS_WATCH_DEBOUNCE_MS: i64 = 500;
const EXTERNAL_OPEN_CLOSE_SUPPRESS_MS: i64 = 2000;

pub fn paletteUiTextPrefixWidth(text: []const u8, font_size: f32, end: usize) f32 {
    return text_measure.textPrefixWidth(.ui, text, font_size, end);
}

pub const ReasoningEffort = db_types.ReasoningEffort;
pub const FastMode = db_types.FastMode;
pub const AccessMode = db_types.AccessMode;
pub const ChatRole = db_types.ChatRole;
pub const Provider = db_types.Provider;
pub const AgentTuiProvider = stack_config.AgentProvider;
pub const Harness = db_types.Harness;

fn harnessProviderForDbProvider(provider: Provider) ai_harness.Provider {
    return switch (provider) {
        .opencode => .opencode,
        .codex => .codex,
        .claude => .claude,
        .cursor => .cursor,
    };
}

fn slashCommandPrefix(raw_text: []const u8) ?[]const u8 {
    const text = std.mem.trim(u8, raw_text, " \t\r\n");
    if (!std.mem.startsWith(u8, text, "/")) return null;
    if (std.mem.startsWith(u8, text, "//")) return null;
    if (std.mem.indexOfAny(u8, text, " \t\r\n") != null) return null;
    return text;
}

fn slashCommandMatchesPrefix(name: []const u8, prefix: []const u8) bool {
    if (prefix.len == 0 or std.mem.eql(u8, prefix, "/")) return true;
    return std.mem.startsWith(u8, name, prefix);
}

pub const SurfaceStatus = enum {
    idle,
    working,
    waiting,
    done,
    @"error",
};

pub const SurfaceUpdate = struct {
    session_id: []const u8,
    workspace_id: ?[]const u8 = null,
    workspace_path: ?[]const u8 = null,
    dock_id: ?u32 = null,
    pane_id: ?u32 = null,
    provider: ?Provider = null,
    provider_thread_id: ?[]const u8 = null,
    title: ?[]const u8 = null,
    status: ?SurfaceStatus = null,
    progress: ?f32 = null,
    attention: ?bool = null,
    unread_increment: u32 = 0,
    last_event_title: ?[]const u8 = null,
    last_event_body: ?[]const u8 = null,
    clear: bool = false,
};

pub const SurfaceState = struct {
    session_id: []u8,
    workspace_id: []u8 = "",
    workspace_path: []u8 = "",
    dock_id: u32 = 0,
    pane_id: ?u32 = null,
    provider: ?Provider = null,
    provider_thread_id: ?[]u8 = null,
    title: []u8 = "",
    status: SurfaceStatus = .idle,
    progress: ?f32 = null,
    attention: bool = false,
    unread_count: u32 = 0,
    last_event_title: ?[]u8 = null,
    last_event_body: ?[]u8 = null,
    last_event_at_ms: i64 = 0,

    pub fn deinit(self: *SurfaceState, allocator: std.mem.Allocator) void {
        allocator.free(self.session_id);
        allocator.free(self.workspace_id);
        allocator.free(self.workspace_path);
        allocator.free(self.title);
        if (self.provider_thread_id) |value| allocator.free(value);
        if (self.last_event_title) |value| allocator.free(value);
        if (self.last_event_body) |value| allocator.free(value);
        self.* = undefined;
    }
};

pub const PaletteModalAction = enum {
    provider_onboarding_close,
    provider_onboarding_recheck,
    provider_onboarding_open_guide,
    image_close,
    project_rename_cancel,
    project_rename_submit,
    transcript_close,
    thread_import_refresh,
    thread_import_cancel,
    thread_import_submit,
    thread_import_select,
    herdr_profile_refresh,
    herdr_profile_cancel,
    herdr_profile_submit,
    herdr_profile_select,
    project_import_browse,
    project_import_submit,
    project_import_create_dir,
    project_import_cancel,
    modal_dismiss,
    modal_block,
    project_rename_input,
    thread_import_input,
    project_import_input,
    settings_cancel,
    settings_close,
    settings_save,
    settings_control,
    command_palette_input,
    command_palette_row,
    command_palette_action_row,
};

pub const SettingsOpenAction = enum {
    folder,
    editor,
    cursor,
    vscode,
    zed,
    custom,
};

pub const SettingsDraft = struct {
    font_size: f32 = theme.DEFAULT_FONT_SIZE,
    terminal_font_size: f32 = app_config.DEFAULT_TERMINAL_FONT_SIZE,
    theme_source: theme.ThemeSource = .omarchy,
    open_action: SettingsOpenAction = .folder,
    link_open_target: app_config.LinkOpenTarget = .verde_browser,
    check_for_updates_automatically: bool = true,
    notifications_enabled: bool = true,
};

pub const PaletteModalHit = struct {
    rect: palette.Rect,
    action: PaletteModalAction,
    index: usize = 0,
};

/// Per-frame hit-test entry for a fenced code block's "Copy" button. The
/// payload bytes live in `palette_frame_text` (cleared each frame), so the
/// offset/length pair is only valid until the next frame's text-buffer reset.
pub const CodeCopyButtonHit = chat_markdown.CodeCopyButtonSink;

pub const BrowserContextMenuItem = struct {
    index: u32,
    label: []u8,
    enabled: bool,
    separator: bool,
    submenu: bool,
};

const BrowserContextMenuPayload = struct {
    x: f32 = 0.0,
    y: f32 = 0.0,
    items: []const BrowserContextMenuPayloadItem = &.{},
};

const BrowserContextMenuPayloadItem = struct {
    index: u32 = 0,
    label: []const u8 = "",
    enabled: bool = false,
    separator: bool = false,
    submenu: bool = false,
};

/// Kinds of expand/collapse cards that share the same per-frame hit list.
pub const CardToggleKind = enum(u8) {
    command_card,
    diff_file,
};

/// Per-frame hit-test entry for a collapsible card header (command bubble,
/// diff file row). The `key` identifies the card across frames and is also the
/// lookup into `expanded_cards`.
pub const CardToggleHit = struct {
    rect: palette.Rect,
    key: u64,
    kind: CardToggleKind,
};

pub const PaletteModalTextFocus = enum {
    none,
    project_rename,
    thread_import,
    project_import,
    command_palette,
};

const PALETTE_COMPOSER_FONT_SIZE: f32 = 22.0;
const PALETTE_COMPOSER_TOOLBAR_FONT_SIZE: f32 = 15.0;
const PALETTE_COMPOSER_ICON_FONT_SIZE: f32 = 18.0;
const PALETTE_COMPOSER_TEXT_ADVANCE_SCALE: f32 = 1.0;

fn paletteColor(color: [4]f32) palette.Color {
    return .{ .r = color[0], .g = color[1], .b = color[2], .a = color[3] };
}

fn paletteComposerStyle() PaletteComposerPrompt.Style {
    return .{
        .background_color = paletteColor(theme.withAlpha(theme.COLOR_PANEL_ALT, 248)),
        .border_color = paletteColor(theme.COLOR_PANEL_MUTED),
        .focus_border_color = paletteColor(theme.COLOR_GREEN),
        .focus_border_width = 1.5,
        .control_background_color = paletteColor(theme.withAlpha(theme.COLOR_PANEL_MUTED, 86)),
        .control_hover_color = paletteColor(theme.withAlpha(theme.lighten(theme.COLOR_PANEL_ALT, 0.08), 210)),
        .separator_color = paletteColor(theme.withAlpha(theme.COLOR_TEXT_SUBTLE, 90)),
        .send_color = paletteColor(theme.COLOR_GREEN),
        .send_hover_color = paletteColor(theme.lighten(theme.COLOR_GREEN, 0.08)),
        .stop_button_color = paletteColor(theme.COLOR_YELLOW),
        .stop_button_hover_color = paletteColor(theme.lighten(theme.COLOR_YELLOW, 0.08)),
        .text_color = paletteColor(theme.COLOR_WHITE),
        .placeholder_color = paletteColor(theme.withAlpha(theme.COLOR_TEXT_SUBTLE, 220)),
        .icon_color = paletteColor(theme.COLOR_TEXT_MUTED),
        .cursor_color = paletteColor(theme.COLOR_WHITE),
        .selection_color = paletteColor(theme.withAlpha(theme.selection(), 140)),
        .scrollbar_track_color = paletteColor(theme.withAlpha(theme.COLOR_PANEL_MUTED, 110)),
        .scrollbar_thumb_color = paletteColor(theme.withAlpha(theme.COLOR_TEXT_MUTED, 200)),
        .menu_background_color = paletteColor(theme.COLOR_PANEL_ALT),
        .menu_border_color = paletteColor(theme.COLOR_PANEL_MUTED),
        .menu_selected_color = paletteColor(theme.withAlpha(theme.selection(), 218)),
        .menu_hover_color = paletteColor(theme.lighten(theme.COLOR_PANEL_ALT, 0.08)),
    };
}

pub const PaletteComposerPrompt = palette.composerPrompt(.{
    // Geometry retuned for the 15pt toolbar / 16pt body fonts. Earlier numbers
    // assumed ~24pt pills and looked over-padded after the type-scale change.
    .padding_x = 16.0,
    .padding_y = 14.0,
    .toolbar_height = 32.0,
    .toolbar_gap = 10.0,
    .control_gap = 6.0,
    .pill_padding_x = 13.0,
    // `pill_overlay_icon_reserve + pill_icon_gap` must clear the host-drawn
    // toolbar icon AND leave breathing room at 1× display scale. Provider
    // PNG is 26 CSS px, fast/access codicons 22 CSS px. Sum kept ≥ 38 so the
    // label doesn't kiss the glyph on a laptop screen at 1×.
    .pill_icon_gap = 12.0,
    .pill_chevron_gap = 14.0,
    .model_min_width = 112.0,
    // Long OpenCode labels include the provider, e.g. "GPT-5.4 (OpenAI)"; cap high enough for measured pill width.
    .model_max_width = 270.0,
    .reasoning_min_width = 74.0,
    // The run pill now shows a "Reasoning · Speed · Access" summary, so it
    // needs far more room than the old single reasoning label.
    // Wide enough for the summary text plus the leading state-glyph reserve.
    .reasoning_max_width = 340.0,
    .fast_min_width = 80.0,
    .fast_max_width = 180.0,
    .access_min_width = 138.0,
    // Toolbar label + lock icon + padding; keep above natural measured width for "Full access".
    .access_max_width = 212.0,
    // Space after `pill_padding_x` until label: ~scaled toolbar icon width
    // minus `pill_icon_gap`. Provider PNG slot is 26 CSS px; reserve + gap
    // gives label-start at icon-end + ~12 CSS px on the smallest screens.
    .pill_overlay_icon_reserve = 26.0,
    .pill_label_width_fudge = 8.0,
    .corner_radius = 18.0,
    .border_width = 1.0,
    .background_color = .{ .r = 0.11, .g = 0.15, .b = 0.16, .a = 0.98 },
    .border_color = .{ .r = 0.25, .g = 0.31, .b = 0.34, .a = 1.0 },
    // Verde brand green (#50c878) glows on focus so the composer flags itself
    // when keystrokes are live. Slightly thicker than the resting border to
    // make the state change unambiguous.
    .focus_border_color = .{ .r = 0.314, .g = 0.784, .b = 0.471, .a = 1.0 },
    .focus_border_width = 1.5,
    // Force the bold pill labels (GPT-5.5, Medium, Fast, Full access) onto the
    // .ui role too so they share CalSans-Regular with the placeholder and the
    // workspace header buttons. The default `.ui_bold` falls through to the
    // renderer's heavy NotoSans-Bold, which reads as a different typeface.
    .bold_font_role = .ui,
    .control_background_color = .{ .r = 0.12, .g = 0.13, .b = 0.16, .a = 0.34 },
    .control_hover_color = .{ .r = 0.16, .g = 0.18, .b = 0.22, .a = 0.78 },
    .separator_color = .{ .r = 0.47, .g = 0.50, .b = 0.56, .a = 0.35 },
    .menu_background_color = .{ .r = 0.075, .g = 0.09, .b = 0.105, .a = 1.0 },
    .menu_border_color = .{ .r = 0.28, .g = 0.34, .b = 0.38, .a = 1.0 },
    .menu_selected_color = .{ .r = 0.19, .g = 0.31, .b = 0.39, .a = 1.0 },
    .menu_hover_color = .{ .r = 0.17, .g = 0.20, .b = 0.24, .a = 1.0 },
    .send_color = .{ .r = 0.25, .g = 0.45, .b = 0.31, .a = 1.0 },
    .send_hover_color = .{ .r = 0.31, .g = 0.52, .b = 0.37, .a = 1.0 },
    .stop_button_color = .{ .r = 0.80, .g = 0.58, .b = 0.10, .a = 1.0 },
    .stop_button_hover_color = .{ .r = 0.92, .g = 0.68, .b = 0.14, .a = 1.0 },
    .text_color = .{ .r = 0.94, .g = 0.96, .b = 0.98, .a = 1.0 },
    .icon_color = .{ .r = 0.70, .g = 0.73, .b = 0.80, .a = 1.0 },
    .selection_color = .{ .r = 0.18, .g = 0.42, .b = 0.72, .a = 0.55 },
    .placeholder_color = .{ .r = 0.38, .g = 0.40, .b = 0.46, .a = 1.0 },
    .font_size = PALETTE_COMPOSER_FONT_SIZE,
    .toolbar_font_size = PALETTE_COMPOSER_TOOLBAR_FONT_SIZE,
    .icon_font_size = PALETTE_COMPOSER_ICON_FONT_SIZE,
    .placeholder = "Ask anything, or use / to show available commands",
    .model_icon = "",
    .fast_icon = "",
    .access_icon = "",
    // codicon-chevron-right (Nerd Font Symbols) — crisp at any size.
    .chevron_icon = "\u{EAB6}",
    .send_icon = "",
    // codicon-debug-stop
    .stop_icon = "\u{EAD7}",
    .z_index = 120,
});

// CSS-unit width of the composer model picker popover; the component scales it
// (and every other geometry token) by `setUiScale` for HiDPI displays.
/// Width reserved per host-drawn state glyph leading the run pill's summary
/// (fast bolt / access lock, ~22px drawn plus spacing); mirrors the sizing
/// convention of `pill_overlay_icon_reserve`.
pub const COMPOSER_RUN_PILL_ICON_CELL: f32 = 26.0;
const COMPOSER_MODEL_PICKER_WIDTH: f32 = 430.0;
/// Width of the provider-icon rail on the picker's left edge; the popover's
/// total width is body + rail.
const COMPOSER_MODEL_PICKER_RAIL_WIDTH: f32 = 52.0;
const COMPOSER_MODEL_PICKER_Z: i32 = 1400;
pub const COMPOSER_RUN_CONFIG_Z: i32 = 1400;
const COMPOSER_PROVIDER_OPTIONS = [_]Provider{ .codex, .opencode, .claude, .cursor };

fn paletteEstimatedFontAdvance(_: ?*anyopaque, text: []const u8, byte_offset: usize, font_size: f32) palette.FontAdvance {
    if (byte_offset >= text.len) return .{ .byte_len = 0, .width = 0.0 };
    if (text[byte_offset] == '\n') return .{ .byte_len = 1, .width = 0.0 };
    const seq_len = std.unicode.utf8ByteSequenceLength(text[byte_offset]) catch 1;
    const end = @min(byte_offset + seq_len, text.len);
    _ = std.unicode.utf8Decode(text[byte_offset..end]) catch {
        return .{ .byte_len = 1, .width = @max(font_size * 0.55, 1.0) };
    };
    return .{ .byte_len = end - byte_offset, .width = paletteCachedGlyphAdvance(text, byte_offset, font_size) };
}

// Palette's text layout asks for one glyph advance at a time and walks whole
// buffers several times per frame (runs, content height, caret, selection).
// Measuring each glyph as a line-prefix difference re-shapes the prefix via
// SDL_ttf on every call — O(line²) per walk, which visibly stalled the
// composer beyond a few lines and froze the app on large pastes. Instead,
// shape each distinct text once (one pass per line) into a per-glyph advance
// table and serve lookups O(1). A few slots cover the concurrent shapes the
// layout uses per frame: the full buffer plus caret/selection line prefixes.
const PALETTE_ADVANCE_CACHE_SLOTS = 6;

const PaletteAdvanceCacheEntry = struct {
    // Identity of the live slice this entry was built from; mid-walk lookups
    // trust it without re-comparing content (single-threaded, edits happen
    // between walks). Content equality is re-checked whenever a walk restarts.
    ptr: usize = 0,
    text: std.ArrayListUnmanaged(u8) = .empty,
    advances: std.ArrayListUnmanaged(f32) = .empty,
    font_size: f32 = 0.0,
    last_offset: usize = std.math.maxInt(usize),
    stamp: u64 = 0,
};

var palette_advance_cache: [PALETTE_ADVANCE_CACHE_SLOTS]PaletteAdvanceCacheEntry =
    .{PaletteAdvanceCacheEntry{}} ** PALETTE_ADVANCE_CACHE_SLOTS;
var palette_advance_cache_stamp: u64 = 0;

fn paletteCachedGlyphAdvance(text: []const u8, byte_offset: usize, font_size: f32) f32 {
    palette_advance_cache_stamp += 1;
    var oldest: *PaletteAdvanceCacheEntry = &palette_advance_cache[0];
    for (&palette_advance_cache) |*entry| {
        if (entry.stamp < oldest.stamp) oldest = entry;
        if (entry.font_size != font_size) continue;
        if (entry.ptr != @intFromPtr(text.ptr) or entry.text.items.len != text.len) continue;
        // A walk restarted (offset went backward): the buffer may have been
        // edited in place since this entry was built, so re-verify content.
        const restarted = byte_offset <= entry.last_offset;
        if (restarted and !std.mem.eql(u8, entry.text.items, text)) continue;
        entry.last_offset = byte_offset;
        entry.stamp = palette_advance_cache_stamp;
        return entry.advances.items[byte_offset];
    }

    rebuildPaletteAdvanceEntry(oldest, text, font_size) catch {
        // Allocation failure: fall back to a single uncached prefix pair.
        var line_start: usize = byte_offset;
        while (line_start > 0 and text[line_start - 1] != '\n') : (line_start -= 1) {}
        const seq_len = std.unicode.utf8ByteSequenceLength(text[byte_offset]) catch 1;
        const end = @min(byte_offset + seq_len, text.len);
        const line = text[line_start..];
        const before = text_measure.textPrefixWidth(.ui, line, font_size, byte_offset - line_start);
        const through = text_measure.textPrefixWidth(.ui, line, font_size, end - line_start);
        return @max(through - before, 0.0);
    };
    oldest.last_offset = byte_offset;
    oldest.stamp = palette_advance_cache_stamp;
    return oldest.advances.items[byte_offset];
}

fn rebuildPaletteAdvanceEntry(entry: *PaletteAdvanceCacheEntry, text: []const u8, font_size: f32) !void {
    const cache_alloc = std.heap.page_allocator;
    try entry.text.resize(cache_alloc, text.len);
    @memcpy(entry.text.items, text);
    try entry.advances.resize(cache_alloc, text.len);
    @memset(entry.advances.items, 0.0);
    entry.ptr = @intFromPtr(text.ptr);
    entry.font_size = font_size;

    var line_start: usize = 0;
    var i: usize = 0;
    while (i <= text.len) : (i += 1) {
        if (i == text.len or text[i] == '\n') {
            const line = text[line_start..i];
            if (line.len > 0) {
                text_measure.textGlyphAdvances(.ui, line, font_size, entry.advances.items[line_start..i]);
            }
            // Newline bytes keep a 0 advance, matching the layout contract.
            line_start = i + 1;
        }
    }
}

fn paletteEstimatedFontMetrics(font_size: f32) palette.FontMetrics {
    const line_height = @max(font_size * 1.25, font_size);
    return .{
        .font_size = font_size,
        .line_height = line_height,
        .context = null,
        .advance = paletteEstimatedFontAdvance,
    };
}

fn paletteComposerTextFontAdvance(context: ?*anyopaque, text: []const u8, byte_offset: usize, font_size: f32) palette.FontAdvance {
    var measured = paletteEstimatedFontAdvance(context, text, byte_offset, font_size);
    measured.width *= PALETTE_COMPOSER_TEXT_ADVANCE_SCALE;
    return measured;
}

fn paletteComposerTextFontMetrics(font_size: f32) palette.FontMetrics {
    var metrics = paletteEstimatedFontMetrics(font_size);
    metrics.advance = paletteComposerTextFontAdvance;
    return metrics;
}

const Mutex = struct {
    inner: std.atomic.Mutex = .unlocked,

    pub fn tryLock(self: *Mutex) bool {
        return self.inner.tryLock();
    }

    pub fn lock(self: *Mutex) void {
        while (!self.inner.tryLock()) std.atomic.spinLoopHint();
    }

    pub fn unlock(self: *Mutex) void {
        self.inner.unlock();
    }
};

const Condition = struct {
    pub fn wait(_: *Condition, mutex: *Mutex) void {
        mutex.unlock();
        std.atomic.spinLoopHint();
        mutex.lock();
    }

    fn broadcast(_: *Condition) void {}
};

fn paletteMousePoint(x: f32, y: f32, ui_scale: f32) palette.draw.Vec2 {
    _ = ui_scale;
    return .{ .x = x, .y = y };
}

fn paletteComposerKeyFromSdl(event: *const sdl.KeyboardEvent) ?palette.Key {
    const mod_bits = keymodBits(event.mod);
    const keyboard_state = sdl.getKeyboardState();
    const ctrl_down = keyboard_state[@intFromEnum(sdl.Scancode.lctrl)] or keyboard_state[@intFromEnum(sdl.Scancode.rctrl)];
    const primary = (mod_bits & (sdl.Keymod.ctrl | sdl.Keymod.gui)) != 0 or ctrl_down;
    const shift = (mod_bits & sdl.Keymod.shift) != 0;
    const alt = (mod_bits & sdl.Keymod.alt) != 0;
    const code: palette.Key.Code = switch (event.key) {
        .left => .left,
        .right => .right,
        .up => .up,
        .down => .down,
        .home => .home,
        .end => .end,
        .pageup => .page_up,
        .pagedown => .page_down,
        .backspace => .backspace,
        .delete => .delete,
        .@"return", .kp_enter => .enter,
        .a => .a,
        .c => .c,
        .v => .v,
        .x => .x,
        .y => .y,
        .z => .z,
        else => return null,
    };
    return .{ .code = code, .shift = shift, .primary = primary or (code == .enter and !shift), .alt = alt };
}

fn keymodBits(modifier_state: sdl.Keymod) u16 {
    return @as(*const u16, @ptrCast(&modifier_state)).*;
}

fn appStateFromContext(context: ?*anyopaque) ?*AppState {
    const ptr = context orelse return null;
    return @ptrCast(@alignCast(ptr));
}

fn paletteModelLabel(context: ?*anyopaque, index: usize) []const u8 {
    const state = appStateFromContext(context) orelse return "";
    const thread = state.currentThread();
    const options = composerModelOptions(state, thread.provider);
    if (index >= options.len) return "";
    return options[index].label;
}

fn composerModelOptions(state: *const AppState, provider: Provider) []const ModelOption {
    return chat_threads.modelOptions(
        ModelOption,
        provider,
        state.opencodeModelOptionsSnapshot(),
        CODEX_MODEL_OPTIONS[0..],
        state.claudeModelOptionsSnapshot(),
        state.cursorModelOptionsSnapshot(),
    );
}

fn composerDefaultModelRef(state: *const AppState, provider: Provider) [:0]const u8 {
    return switch (provider) {
        .codex => DEFAULT_CODEX_MODEL,
        .opencode => state.cachedDefaultModelRefForProvider(.opencode),
        .claude => DEFAULT_CLAUDE_MODEL,
        .cursor => DEFAULT_CURSOR_MODEL,
    };
}

fn paletteComposerPromptEvent(context: ?*anyopaque, event: palette.ComposerPromptEvent) void {
    const state = appStateFromContext(context) orelse return;
    switch (event) {
        .text_changed => |text| {
            state.setDraft(text);
            state.updateFileSearch();
            state.clampSlashCommandPickerSelection();
        },
        .submitted => {
            if (state.currentThread().isSendPendingForUi()) {
                state.setSidebarNotice("This thread is still running. Press Tab to queue or steer a follow-up.");
                return;
            }
            if (state.acceptPrimaryFileSearchResult()) return;
            if (state.handleWorkspaceCommand(state.currentProject().currentDraft())) return;
            if (state.handleProviderSlashCommand(state.currentProject().currentDraft())) return;
            state.sendDraft() catch |err| {
                log.err("failed to send draft: {s}", .{@errorName(err)});
                state.setSidebarNotice(initialSendStartFailureMessage(err));
            };
        },
        .model_changed => |index| {
            const options = composerModelOptions(state, state.currentThread().provider);
            if (index >= options.len) return;
            state.setCurrentThreadModelRef(options[index].value);
        },
        .reasoning_changed => |index| {
            const thread = state.currentThreadMutable();
            if (thread.provider == .codex) {
                if (index >= CODEX_REASONING_OPTIONS.len) return;
                const next = CODEX_REASONING_OPTIONS[index].value;
                const changed = if (next) |value|
                    thread.reasoning_effort == null or thread.reasoning_effort.? != value
                else
                    thread.reasoning_effort != null;
                if (!changed) return;
                thread.reasoning_effort = next;
                state.markDirty();
                return;
            }
            if (thread.provider == .claude) {
                const rows = state.opencode_reasoning_menu.items;
                if (index >= rows.len) return;
                const row = rows[index];
                const next = if (row.variant) |variant| parseReasoningEffort(variant) orelse return else null;
                const changed = if (next) |value|
                    thread.reasoning_effort == null or thread.reasoning_effort.? != value
                else
                    thread.reasoning_effort != null;
                if (!changed) return;
                thread.reasoning_effort = next;
                state.markDirty();
                return;
            }
            const rows = state.opencode_reasoning_menu.items;
            if (index >= rows.len) return;
            const row = rows[index];
            const matches = blk: {
                if (thread.opencode_reasoning_variant == null and row.variant == null) break :blk true;
                if (thread.opencode_reasoning_variant) |existing| {
                    if (row.variant) |rv| break :blk std.mem.eql(u8, existing, rv);
                }
                break :blk false;
            };
            if (matches) return;
            if (thread.opencode_reasoning_variant) |old| state.allocator.free(old);
            thread.opencode_reasoning_variant = if (row.variant) |rv| state.allocator.dupeZ(u8, rv) catch null else null;
            state.markDirty();
        },
        .fast_changed => |enabled| {
            if (state.currentThread().provider != .codex and state.currentThread().provider != .cursor) return;
            const next: FastMode = if (enabled) .on else .off;
            const thread = state.currentThreadMutable();
            if (thread.fast_mode == next) return;
            thread.fast_mode = next;
            state.markDirty();
        },
        .access_changed => |enabled| {
            const next: AccessMode = if (enabled) .full_access else .supervised;
            const thread = state.currentThreadMutable();
            if (thread.access_mode == next) return;
            thread.access_mode = next;
            state.markDirty();
        },
        .send_clicked => {
            if (state.currentThread().isSendPendingForUi()) state.abortCurrentThreadSend();
        },
        .focus_changed => |focused| {
            state.composer_focused = focused;
            if (focused) {
                state.terminal_focused = false;
                state.unfocusBrowserPane();
            }
        },
        // Pill clicks that reach the composer directly (outside the overlay
        // hit-rect path) still open the host popovers.
        .model_clicked => state.openPaletteModelPicker(),
        .reasoning_clicked => state.toggleRunConfigPopover(),
    }
}

fn paletteComposerGetClipboard(context: ?*anyopaque, allocator: std.mem.Allocator) ?[]u8 {
    _ = allocator;
    const state = appStateFromContext(context) orelse return null;
    return state.readClipboardTextForPaste();
}

/// One row of the composer model picker: a concrete model under a provider
/// group. Rebuilt by `rebuildModelPickerEntries` whenever the picker syncs.
pub const ModelPickerEntry = struct {
    provider: Provider,
    option_index: usize,
};

fn modelPickerEntryAt(state: *const AppState, index: usize) ?ModelPickerEntry {
    if (index >= state.model_picker_entries.items.len) return null;
    return state.model_picker_entries.items[index];
}

fn modelPickerOptionAt(state: *const AppState, index: usize) ?ModelOption {
    const entry = modelPickerEntryAt(state, index) orelse return null;
    const options = composerModelOptions(state, entry.provider);
    if (entry.option_index >= options.len) return null;
    return options[entry.option_index];
}

fn paletteModelPickerLabel(context: ?*anyopaque, index: usize) []const u8 {
    const state = appStateFromContext(context) orelse return "";
    const option = modelPickerOptionAt(state, index) orelse return "";
    return option.label;
}

fn paletteModelPickerDescription(context: ?*anyopaque, index: usize) []const u8 {
    const state = appStateFromContext(context) orelse return "";
    const entry = modelPickerEntryAt(state, index) orelse return "";
    // Rows show the provider under the model name (with its logo rendered by
    // `leading_on_description`), mirroring the reference picker design.
    return chat_threads.providerLabel(entry.provider);
}

fn paletteModelPickerBadge(context: ?*anyopaque, index: usize) []const u8 {
    const state = appStateFromContext(context) orelse return "";
    const entry = modelPickerEntryAt(state, index) orelse return "";
    const option = modelPickerOptionAt(state, index) orelse return "";
    const value = option.value orelse return "";
    if (std.mem.eql(u8, value, composerDefaultModelRef(state, entry.provider))) return "Default";
    return "";
}

fn paletteModelPickerGroup(context: ?*anyopaque, index: usize) []const u8 {
    const state = appStateFromContext(context) orelse return "";
    const entry = modelPickerEntryAt(state, index) orelse return "";
    return chat_threads.providerLabel(entry.provider);
}

/// Contain-fits the provider logo into `slot`. Serves both picker icon
/// contexts: the small description-line icon and the rail entries.
fn drawModelPickerProviderLogo(
    state: *AppState,
    allocator: std.mem.Allocator,
    batch: *palette.draw.RenderBatch,
    provider: Provider,
    clip: palette.draw.Rect,
    slot: palette.draw.Rect,
) void {
    const tex = state.providerLogoTexture(provider) orelse return;
    if (!tex.valid or tex.texture_id == 0) return;
    const inner = @min(slot.w, slot.h);
    const square: palette.Rect = .{
        .x = slot.x + (slot.w - inner) * 0.5,
        .y = slot.y + (slot.h - inner) * 0.5,
        .w = inner,
        .h = inner,
    };
    const c = utils.snapImageRectToPixels(utils.imageRectContain(tex.width, tex.height, square.x, square.y, square.w, square.h));
    batch.image(allocator, .{ .x = c.x, .y = c.y, .w = c.w, .h = c.h }, palette.TextureId.init(tex.texture_id), .{
        .x = 0.0,
        .y = 0.0,
        .w = 1.0,
        .h = 1.0,
    }, .{ .r = 1.0, .g = 1.0, .b = 1.0, .a = 1.0 }, clip) catch {};
}

fn paletteModelPickerRenderRowLeading(
    context: ?*anyopaque,
    allocator: std.mem.Allocator,
    batch: *palette.draw.RenderBatch,
    index: usize,
    clip: palette.draw.Rect,
    leading_rect: palette.draw.Rect,
) void {
    const state = appStateFromContext(context) orelse return;
    const entry = modelPickerEntryAt(state, index) orelse return;
    drawModelPickerProviderLogo(state, allocator, batch, entry.provider, clip, leading_rect);
}

fn paletteModelPickerRailIcon(
    context: ?*anyopaque,
    allocator: std.mem.Allocator,
    batch: *palette.draw.RenderBatch,
    first_item: usize,
    clip: palette.draw.Rect,
    icon_rect: palette.draw.Rect,
) void {
    const state = appStateFromContext(context) orelse return;
    const entry = modelPickerEntryAt(state, first_item) orelse return;
    drawModelPickerProviderLogo(state, allocator, batch, entry.provider, clip, icon_rect);
}

fn paletteModelPickerStyle() palette.RichPickerStyle {
    return .{
        .background_color = paletteColor(theme.COLOR_PANEL_ALT),
        .border_color = paletteColor(theme.COLOR_PANEL_MUTED),
        .highlighted_color = paletteColor(theme.lighten(theme.COLOR_PANEL_ALT, 0.08)),
        // The inline accent check marks the active model, so the row fill
        // stays subtle instead of a solid selection block.
        .selected_color = paletteColor(theme.withAlpha(theme.selection(), 70)),
        .text_color = paletteColor(theme.COLOR_WHITE),
        .description_color = paletteColor(theme.COLOR_TEXT_MUTED),
        .header_color = paletteColor(theme.COLOR_TEXT_SUBTLE),
        .badge_background_color = paletteColor(theme.withAlpha(theme.COLOR_PANEL_MUTED, 220)),
        .badge_text_color = paletteColor(theme.COLOR_TEXT_MUTED),
        .icon_color = paletteColor(theme.COLOR_GREEN),
        .accent_color = paletteColor(theme.COLOR_GREEN),
        .rail_background_color = paletteColor(theme.darken(theme.COLOR_PANEL_ALT, 0.35)),
        .search_background_color = paletteColor(theme.darken(theme.COLOR_PANEL_ALT, 0.25)),
        .search_border_color = paletteColor(theme.COLOR_PANEL_MUTED),
        .search_selection_color = paletteColor(theme.withAlpha(theme.selection(), 140)),
        .scrollbar_track_color = paletteColor(theme.withAlpha(theme.COLOR_PANEL_MUTED, 110)),
        .scrollbar_thumb_color = paletteColor(theme.withAlpha(theme.COLOR_TEXT_MUTED, 220)),
    };
}

pub const PaletteModelPicker = palette.richPicker(.{
    .width = COMPOSER_MODEL_PICKER_WIDTH,
    .row_height = 34.0,
    .row_height_with_description = 50.0,
    .header_row_height = 26.0,
    .max_body_height = 380.0,
    .padding_x = 10.0,
    .padding_y = 10.0,
    .row_padding_x = 10.0,
    .corner_radius = 14.0,
    .border_width = 1.0,
    .font_size = 15.5,
    .description_font_size = 12.0,
    .header_font_size = 12.0,
    .badge_font_size = 11.0,
    .search_enabled = true,
    .search_min_items = 8,
    .search_height = 36.0,
    .search_placeholder = "Search models…",
    .search_style = .underline,
    // codicon-search magnifier leads the query field.
    .search_icon = "\u{EA6D}",
    .search_gap = 10.0,
    // The provider logo renders small on each row's description line rather
    // than spanning the row.
    .render_row_leading = paletteModelPickerRenderRowLeading,
    .leading_on_description = true,
    .item_label = paletteModelPickerLabel,
    .item_description = paletteModelPickerDescription,
    .item_badge = paletteModelPickerBadge,
    .item_group = paletteModelPickerGroup,
    // Provider rail on the left; codicon star-full tops it as "all models".
    .rail_enabled = true,
    .rail_width = COMPOSER_MODEL_PICKER_RAIL_WIDTH,
    .rail_item_height = 46.0,
    .rail_icon_size = 24.0,
    .rail_all_icon = "\u{EB59}",
    .render_rail_icon = paletteModelPickerRailIcon,
    // codicon-check marks the active model inline after its name.
    .check_icon = "\u{EAB2}",
    .check_inline = true,
    // Ctrl+1..9 select the first nine visible rows; the raw SDL digits are
    // routed in `routePaletteComposerKeyDown`.
    .shortcut_badge_limit = 9,
    .placement = .above,
    .scrollbar_width = 5.0,
    .z_index = COMPOSER_MODEL_PICKER_Z,
});

fn paletteModelPickerEvent(context: ?*anyopaque, event: palette.RichPickerEvent) void {
    const state = appStateFromContext(context) orelse return;
    switch (event) {
        .selected => |index| {
            const entry = modelPickerEntryAt(state, index) orelse return;
            const option = modelPickerOptionAt(state, index) orelse return;
            if (entry.provider != state.currentThread().provider) {
                state.setCurrentThreadProvider(entry.provider);
            }
            state.setCurrentThreadModelRef(option.value);
            state.syncPaletteComposerControls();
        },
        .highlighted, .open_changed => {},
    }
}

/// Ordered rows of the composer run-configuration popover. Reasoning and
/// speed only appear when the current provider/model supports them; access
/// applies to every provider.
pub const RunConfigRowKind = enum(u8) {
    reasoning = 0,
    speed = 1,
    access = 2,
};

/// Stable per-stepper context so one comptime Stepper type serves all three
/// run-config rows; `state` is refreshed every sync in case AppState moved.
pub const RunStepperContext = struct {
    state: ?*AppState = null,
    kind: RunConfigRowKind = .access,
};

const RUN_SPEED_STEP_LABELS = [_][:0]const u8{ "Default", "Fast" };
const RUN_SPEED_STEP_DESCRIPTIONS = [_][:0]const u8{
    "Balanced speed and quality",
    "Prioritizes faster responses",
};
const RUN_ACCESS_STEP_LABELS = [_][:0]const u8{ "Supervised", "Full access" };
const RUN_ACCESS_STEP_DESCRIPTIONS = [_][:0]const u8{
    "Asks before running risky commands",
    "Runs commands without asking first",
};

fn runStepperStateFromContext(context: ?*anyopaque) ?struct { state: *AppState, kind: RunConfigRowKind } {
    const ptr = context orelse return null;
    const stepper_context: *RunStepperContext = @ptrCast(@alignCast(ptr));
    const state = stepper_context.state orelse return null;
    return .{ .state = state, .kind = stepper_context.kind };
}

fn runReasoningStepLabel(state: *const AppState, index: usize) []const u8 {
    if (state.currentThread().provider == .codex) {
        if (index >= CODEX_REASONING_OPTIONS.len) return "";
        return CODEX_REASONING_OPTIONS[index].label;
    }
    const rows = state.opencode_reasoning_menu.items;
    if (index >= rows.len) return "";
    return rows[index].label;
}

fn reasoningEffortStepDescription(effort: ?ReasoningEffort) []const u8 {
    const value = effort orelse return "Provider default reasoning";
    return switch (value) {
        .low => "Fastest, lightest reasoning",
        .medium => "Balanced depth and speed",
        .high => "Deeper reasoning for harder tasks",
        .xhigh => "Very deep reasoning, slower",
        .max => "Maximum depth for the hardest problems",
    };
}

fn runReasoningStepDescription(state: *const AppState, index: usize) []const u8 {
    if (state.currentThread().provider == .codex) {
        if (index >= CODEX_REASONING_OPTIONS.len) return "";
        return reasoningEffortStepDescription(CODEX_REASONING_OPTIONS[index].value);
    }
    const rows = state.opencode_reasoning_menu.items;
    if (index >= rows.len) return "";
    const variant = rows[index].variant orelse return reasoningEffortStepDescription(null);
    if (parseReasoningEffort(variant)) |effort| return reasoningEffortStepDescription(effort);
    return "Model-specific reasoning variant";
}

fn runStepLabel(context: ?*anyopaque, index: usize) []const u8 {
    const resolved = runStepperStateFromContext(context) orelse return "";
    return switch (resolved.kind) {
        .reasoning => runReasoningStepLabel(resolved.state, index),
        .speed => if (index < RUN_SPEED_STEP_LABELS.len) RUN_SPEED_STEP_LABELS[index] else "",
        .access => if (index < RUN_ACCESS_STEP_LABELS.len) RUN_ACCESS_STEP_LABELS[index] else "",
    };
}

fn runStepDescription(context: ?*anyopaque, index: usize) []const u8 {
    const resolved = runStepperStateFromContext(context) orelse return "";
    return switch (resolved.kind) {
        .reasoning => runReasoningStepDescription(resolved.state, index),
        .speed => if (index < RUN_SPEED_STEP_DESCRIPTIONS.len) RUN_SPEED_STEP_DESCRIPTIONS[index] else "",
        .access => if (index < RUN_ACCESS_STEP_DESCRIPTIONS.len) RUN_ACCESS_STEP_DESCRIPTIONS[index] else "",
    };
}

fn paletteRunStepperStyle() palette.StepperStyle {
    return .{
        .track_color = paletteColor(theme.withAlpha(theme.background(), 160)),
        .segment_color = paletteColor(theme.withAlpha(theme.COLOR_PANEL_MUTED, 140)),
        .segment_hover_color = paletteColor(theme.lighten(theme.COLOR_PANEL_MUTED, 0.10)),
        // The selected thumb uses the theme accent (like the send button) so
        // it stands out from the muted base segments in every theme.
        .segment_selected_color = paletteColor(theme.withAlpha(theme.COLOR_GREEN, 230)),
        .text_color = paletteColor(theme.COLOR_TEXT_MUTED),
        .text_selected_color = paletteColor(theme.COLOR_WHITE),
        .description_color = paletteColor(theme.COLOR_TEXT_SUBTLE),
    };
}

pub const PaletteRunStepper = palette.stepper(.{
    .segment_height = 30.0,
    .segment_gap = 4.0,
    .corner_radius = 9.0,
    .font_size = 13.0,
    .description_font_size = 12.0,
    .description_gap = 6.0,
    .show_description = true,
    .step_label = runStepLabel,
    .step_description = runStepDescription,
    .z_index = COMPOSER_RUN_CONFIG_Z + 2,
});

fn paletteRunStepperEvent(context: ?*anyopaque, event: palette.StepperEvent) void {
    const resolved = runStepperStateFromContext(context) orelse return;
    switch (event) {
        .changed => |index| {
            const composer_event: palette.ComposerPromptEvent = switch (resolved.kind) {
                .reasoning => .{ .reasoning_changed = index },
                .speed => .{ .fast_changed = index == 1 },
                .access => .{ .access_changed = index == 1 },
            };
            paletteComposerPromptEvent(resolved.state, composer_event);
        },
        .hover_changed => {},
    }
}

pub const ProjectEditorTarget = enum {
    configured,
    cursor,
    vscode,
    zed,
};

pub const log = std.log.scoped(.native_shell);

pub const ORG_NAME: [:0]const u8 = "verde";
pub const APP_NAME: [:0]const u8 = "Native";
pub const LEGACY_STATE_FILE_NAME = "state.json";
const CURSOR_MODEL_CACHE_FILE_NAME = "cursor-models.json";
pub const DEFAULT_CODEX_MODEL: [:0]const u8 = "gpt-5.6-sol";
pub const DEFAULT_CODEX_REASONING_EFFORT: ReasoningEffort = .low;
pub const DEFAULT_OPENCODE_MODEL: [:0]const u8 = "opencode/gpt-5.4";
pub const DEFAULT_CLAUDE_MODEL: [:0]const u8 = "default";
pub const DEFAULT_CURSOR_MODEL: [:0]const u8 = "composer-2";
pub const IMAGE_MODAL_ID: [:0]const u8 = "AttachmentPreviewModal";
pub const THREAD_IMPORT_MODAL_ID: [:0]const u8 = "ThreadImportModal";
pub const TRANSCRIPT_SELECTION_MODAL_ID: [:0]const u8 = "TranscriptSelectionModal";
pub const VERDE_LOGO_BYTES = @embedFile("assets/verde_logo_mask.png");
pub const OPENCODE_LOGO_BYTES = @embedFile("assets/opencode-logo-dark.png");
pub const CODEX_LOGO_BYTES = @embedFile("assets/OpenAI-white-monoblossom.png");
pub const CLAUDE_LOGO_BYTES = @embedFile("assets/claude-logo.png");
pub const AMP_LOGO_BYTES = @embedFile("assets/amp-logo.png");
pub const THREAD_EDIT_BYTES = @embedFile("assets/thread_edit.png");
pub const CURSOR_LOGO_BYTES = @embedFile("assets/editor_logos/cursor.png");
pub const EMACS_LOGO_BYTES = @embedFile("assets/editor_logos/emacs.png");
pub const NEOVIM_LOGO_BYTES = @embedFile("assets/editor_logos/neovim.png");
pub const VSCODE_LOGO_BYTES = @embedFile("assets/editor_logos/vscode.png");
pub const ZED_LOGO_BYTES = @embedFile("assets/editor_logos/zed.png");

const LoadedPersistedState = db_types.LoadedState;
const PersistedImageAttachment = db_types.PersistedImageAttachment;
const PersistedHerdrWorkspaceLink = db_types.PersistedHerdrWorkspaceLink;
const PersistedMessage = db_types.PersistedMessage;
const PersistedProject = db_types.PersistedProject;
const PersistedState = db_types.PersistedState;
const PersistedThread = db_types.PersistedThread;

// `utils.zig` owns the cross-cutting runtime helpers that are shared with the UI shell.
const SendWorkerRequest = utils.SendWorkerRequest;
const appendPendingDiffSummaryEvent = utils.appendPendingDiffSummaryEvent;
const approvalPolicyForMode = utils.approvalPolicyForMode;
const captureClipboardImage = utils.captureClipboardImage;
const extensionForImageMime = utils.extensionForImageMime;
const flushPendingAssistantTextLocked = utils.flushPendingAssistantTextLocked;
const freePendingApproval = utils.freePendingApproval;
const freePendingApprovalLocked = utils.freePendingApprovalLocked;
const freePendingDiffFiles = utils.freePendingDiffFiles;
const freePendingDiffFilesLocked = utils.freePendingDiffFilesLocked;
const freePendingTimelineEvents = utils.freePendingTimelineEvents;
const freePendingTimelineEventsLocked = utils.freePendingTimelineEventsLocked;
const pendingTimelineEventsContainAssistant = utils.pendingTimelineEventsContainAssistant;
const pickerWorker = utils.pickerWorker;
const sandboxModeForMode = utils.sandboxModeForMode;
const serviceTierForMode = utils.serviceTierForMode;
const sendWorker = utils.sendWorker;
const uploadTexture = utils.uploadTexture;

pub const ModelOption = struct {
    label: [:0]const u8,
    value: ?[:0]const u8 = null,
    /// From OpenCode model metadata (`capabilities.reasoning`); presets default to true.
    reasoning_supported: bool = true,
    /// Sorted OpenCode `variants` keys; owned with the option row (freed in `clearDynamicOpencodeModelOptions`).
    reasoning_variant_keys: ?[][:0]const u8 = null,
    cursor_fast_supported: bool = false,
    cursor_reasoning_param_id: ?[:0]const u8 = null,
    cursor_reasoning_values: ?[][:0]const u8 = null,
    cursor_reasoning_requires_thinking: bool = false,
    claude_effort_values: ?[]const [:0]const u8 = null,
};

const OpencodeReasoningMenuRow = struct {
    label: [:0]const u8,
    /// Null selects the default (no `variant` field on the wire).
    variant: ?[:0]const u8,
};

const PersistedCursorModelOption = struct {
    label: []const u8,
    value: []const u8,
    fast_supported: bool = false,
    reasoning_param_id: ?[]const u8 = null,
    reasoning_values: ?[]const []const u8 = null,
    reasoning_requires_thinking: bool = false,
};

fn persistedCursorModelCacheNeedsRefresh(options: []const PersistedCursorModelOption) bool {
    for (options) |option| {
        if (std.mem.eql(u8, option.value, "composer-2.5-fast") or
            std.mem.eql(u8, option.value, "composer-2-fast"))
        {
            return true;
        }
    }
    return false;
}

fn cursorReasoningValueLabel(value: []const u8) []const u8 {
    if (std.mem.eql(u8, value, "low")) return "Low";
    if (std.mem.eql(u8, value, "medium")) return "Medium";
    if (std.mem.eql(u8, value, "high")) return "High";
    if (std.mem.eql(u8, value, "extra-high") or std.mem.eql(u8, value, "xhigh")) return "Extra High";
    if (std.mem.eql(u8, value, "max")) return "Max";
    if (std.mem.eql(u8, value, "none")) return "None";
    return value;
}

fn parseReasoningEffort(value: []const u8) ?ReasoningEffort {
    if (std.mem.eql(u8, value, "low")) return .low;
    if (std.mem.eql(u8, value, "medium")) return .medium;
    if (std.mem.eql(u8, value, "high")) return .high;
    if (std.mem.eql(u8, value, "xhigh")) return .xhigh;
    if (std.mem.eql(u8, value, "max")) return .max;
    return null;
}

fn claudeEffortValueLabel(value: []const u8) []const u8 {
    if (std.mem.eql(u8, value, "xhigh")) return "Xhigh";
    if (std.mem.eql(u8, value, "max")) return "Max";
    return cursorReasoningValueLabel(value);
}

fn reasoningEffortDisplayLabel(value: ReasoningEffort) []const u8 {
    return switch (value) {
        .low => "Low",
        .medium => "Medium",
        .high => "High",
        .xhigh => "Xhigh",
        .max => "Max",
    };
}

pub const ReasoningOption = struct {
    label: [:0]const u8,
    value: ?ReasoningEffort = null,
};

const FastModeOption = struct {
    label: [:0]const u8,
    value: FastMode,
};

const AccessModeOption = struct {
    label: [:0]const u8,
    value: AccessMode,
};

const TranscriptMarkdownBody = struct {
    owned_body: []u8,
    view: chat_markdown.BodyView,

    fn deinit(self: *TranscriptMarkdownBody, allocator: std.mem.Allocator) void {
        self.view.deinit(allocator);
        allocator.free(self.owned_body);
        allocator.destroy(self);
    }
};

const TranscriptHeightEntry = struct {
    valid: bool = false,
    role: ChatRole = .assistant,
    assistant_plain_layout: bool = false,
    width: f32 = 0.0,
    body_hash: u64 = 0,
    author_hash: u64 = 0,
    image_present: bool = false,
    height: f32 = 0.0,
};

pub const TranscriptMarkdownSelectionPoint = struct {
    message_index: usize,
    point: chat_markdown.SelectionPoint,
};

pub const TranscriptMarkdownSelection = struct {
    anchor: TranscriptMarkdownSelectionPoint,
    focus: TranscriptMarkdownSelectionPoint,
};

const InspectorPromptSubmittedEvent = struct {
    payload: struct {
        prompt: []const u8,
        selection: InspectorSelectionPayload,
    },
};

const BrowserClipboardEvent = struct {
    source: []const u8,
    text: []const u8 = "",
    cut: bool = false,
};

const InspectorSelectionPayload = struct {
    mode: []const u8,
    element: ?InspectorElementPayload = null,
    elements: ?[]InspectorElementPayload = null,
    rect: ?InspectorRectPayload = null,
};

const InspectorElementPayload = struct {
    selector: ?[]const u8 = null,
    tagName: ?[]const u8 = null,
    textSnippet: ?[]const u8 = null,
    ariaLabel: ?[]const u8 = null,
    href: ?[]const u8 = null,
};

const InspectorRectPayload = struct {
    x: f32 = 0.0,
    y: f32 = 0.0,
    width: f32 = 0.0,
    height: f32 = 0.0,
};

pub const OPENCODE_MODEL_OPTIONS = [_]ModelOption{
    .{ .label = "GPT-5.5", .value = "opencode/gpt-5.5" },
    .{ .label = "GPT-5.4", .value = "opencode/gpt-5.4" },
    .{ .label = "Claude Opus 4.7", .value = "opencode/claude-opus-4-7" },
    .{ .label = "Claude Opus 4.6", .value = "opencode/claude-opus-4-6" },
    .{ .label = "Claude Sonnet 4.5", .value = "opencode/claude-sonnet-4-5" },
    .{ .label = "Gemini 3.1 Pro", .value = "opencode/gemini-3.1-pro" },
};

pub const CODEX_MODEL_OPTIONS = [_]ModelOption{
    .{ .label = "GPT-5.6 Sol", .value = "gpt-5.6-sol" },
    .{ .label = "GPT-5.5", .value = "gpt-5.5" },
    .{ .label = "GPT-5.6 Terra", .value = "gpt-5.6-terra" },
    .{ .label = "GPT-5.6 Luna", .value = "gpt-5.6-luna" },
    .{ .label = "GPT-5.4", .value = "gpt-5.4" },
    .{ .label = "GPT-5.4 Mini", .value = "gpt-5.4-mini" },
    .{ .label = "GPT-5.3 Codex", .value = "gpt-5.3-codex" },
    .{ .label = "GPT-5.3 Codex Spark", .value = "gpt-5.3-codex-spark" },
    .{ .label = "GPT-5.2 Codex", .value = "gpt-5.2-codex" },
    .{ .label = "GPT-5.2", .value = "gpt-5.2" },
};

pub const CURSOR_MODEL_OPTIONS = [_]ModelOption{
    .{ .label = "Auto", .value = "auto" },
    .{ .label = "Composer 2.5", .value = "composer-2.5", .cursor_fast_supported = true },
    .{ .label = "Composer 2", .value = DEFAULT_CURSOR_MODEL, .cursor_fast_supported = true },
    .{ .label = "GPT-5.5", .value = "gpt-5.5-medium", .cursor_fast_supported = true },
    .{ .label = "GPT-5.4", .value = "gpt-5.4-medium", .cursor_fast_supported = true },
    .{ .label = "Claude Opus 4.7", .value = "claude-opus-4-7" },
    .{ .label = "Claude Sonnet 4.5", .value = "claude-sonnet-4-5" },
};

const CLAUDE_STANDARD_EFFORT_VALUES = [_][:0]const u8{ "low", "medium", "high" };
const CLAUDE_OPUS_EFFORT_VALUES = [_][:0]const u8{ "low", "medium", "high", "xhigh", "max" };

pub const CLAUDE_MODEL_OPTIONS = [_]ModelOption{
    .{ .label = "Default (Sonnet)", .value = DEFAULT_CLAUDE_MODEL, .reasoning_supported = true, .claude_effort_values = CLAUDE_STANDARD_EFFORT_VALUES[0..] },
    .{ .label = "Claude Opus 4.7", .value = "claude-opus-4-7", .reasoning_supported = true, .claude_effort_values = CLAUDE_OPUS_EFFORT_VALUES[0..] },
    .{ .label = "Claude Sonnet 4.5", .value = "claude-sonnet-4-5", .reasoning_supported = true, .claude_effort_values = CLAUDE_STANDARD_EFFORT_VALUES[0..] },
    .{ .label = "Sonnet (1M context)", .value = "sonnet[1m]", .reasoning_supported = true, .claude_effort_values = CLAUDE_STANDARD_EFFORT_VALUES[0..] },
    .{ .label = "Opus", .value = "opus", .reasoning_supported = true, .claude_effort_values = CLAUDE_OPUS_EFFORT_VALUES[0..] },
    .{ .label = "Haiku", .value = "haiku", .reasoning_supported = false },
};

pub const CODEX_REASONING_OPTIONS = [_]ReasoningOption{
    .{ .label = "Default", .value = null },
    .{ .label = "Low", .value = .low },
    .{ .label = "Medium", .value = .medium },
    .{ .label = "High", .value = .high },
    .{ .label = "Xhigh", .value = .xhigh },
};

pub const CODEX_FAST_MODE_OPTIONS = [_]FastModeOption{
    .{ .label = "Off", .value = .off },
    .{ .label = "On", .value = .on },
};

pub const CODEX_ACCESS_MODE_OPTIONS = [_]AccessModeOption{
    .{ .label = "Full access", .value = .full_access },
    .{ .label = "Supervised", .value = .supervised },
};

pub const ChatMessage = struct {
    role: ChatRole,
    author: [:0]const u8,
    body: [:0]const u8,
    image: ?ChatImageAttachment = null,
    extra_images: []ChatImageAttachment = &.{},
};

pub const ChatImageAttachment = struct {
    path: [:0]const u8,
    file_name: [:0]const u8,
    mime: [:0]const u8,
    byte_size: usize,

    fn init(allocator: std.mem.Allocator, path: []const u8, mime: []const u8, byte_size: usize) !ChatImageAttachment {
        return .{
            .path = try allocator.dupeZ(u8, path),
            .file_name = try allocator.dupeZ(u8, std.fs.path.basename(path)),
            .mime = try allocator.dupeZ(u8, mime),
            .byte_size = byte_size,
        };
    }

    fn deinit(self: ChatImageAttachment, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.file_name);
        allocator.free(self.mime);
    }
};

pub const SlashPickerRow = struct {
    name: []const u8,
    summary: []const u8,
    usage: []const u8,
    provider_label: []const u8,
    disabled: bool,
    requires_thread: bool,
};

pub const BackgroundTaskStatus = enum {
    running,
    completed,
    failed,
    stopped,
};

pub const BackgroundTask = struct {
    command: [:0]const u8,
    task_id: ?[:0]const u8 = null,
    pid_path: ?[:0]const u8 = null,
    log_path: ?[:0]const u8 = null,
    status: BackgroundTaskStatus,
    updated_at_ms: i64 = 0,
    last_poll_ms: i64 = 0,

    fn deinit(self: BackgroundTask, allocator: std.mem.Allocator) void {
        allocator.free(self.command);
        if (self.task_id) |value| allocator.free(value);
        if (self.pid_path) |value| allocator.free(value);
        if (self.log_path) |value| allocator.free(value);
    }
};

pub const ChatThread = struct {
    title: [:0]const u8,
    archived: bool = false,
    committed: bool = false,
    local_thread_id: [:0]const u8,
    last_activity_at: i64 = 0,
    provider_thread_id: ?[:0]const u8 = null,
    model_ref: ?[:0]const u8 = null,
    reasoning_effort: ?ReasoningEffort = null,
    /// OpenCode JSON `variant` when the configured model exposes variant keys.
    opencode_reasoning_variant: ?[:0]const u8 = null,
    fast_mode: FastMode = .off,
    access_mode: AccessMode = .full_access,
    provider: Provider = .opencode,
    harness: Harness = .local_cli,
    tui_dock_id: ?u32 = null,
    messages: std.ArrayList(ChatMessage),
    background_tasks: std.ArrayList(BackgroundTask),
    send_state: *SendState,
    transcript_markdown_entries: std.ArrayList(?*TranscriptMarkdownBody),
    transcript_height_entries: std.ArrayList(TranscriptHeightEntry),
    transcript_scroll_valid: bool = false,
    transcript_scroll_y: f32 = 0.0,
    draft_image: ?ChatImageAttachment = null,
    draft_extra_images: std.ArrayList(ChatImageAttachment),
    draft_storage: [AppState.DRAFT_CAPACITY:0]u8,

    fn init(allocator: std.mem.Allocator, title: []const u8) !ChatThread {
        const send_state = try allocator.create(SendState);
        errdefer allocator.destroy(send_state);
        send_state.* = .{};
        const local_thread_id = try allocPrintZCompat(allocator, "chat-{d}-{x}", .{ unixTimestampMs(), @intFromPtr(send_state) });
        errdefer allocator.free(local_thread_id);

        return .{
            .title = try allocator.dupeZ(u8, title),
            .local_thread_id = local_thread_id,
            .committed = false,
            .last_activity_at = 0,
            .model_ref = try allocator.dupeZ(u8, DEFAULT_CODEX_MODEL),
            .reasoning_effort = DEFAULT_CODEX_REASONING_EFFORT,
            .fast_mode = .off,
            .access_mode = .full_access,
            .provider = .codex,
            .harness = .local_cli,
            .tui_dock_id = null,
            .messages = .empty,
            .background_tasks = .empty,
            .send_state = send_state,
            .transcript_markdown_entries = .empty,
            .transcript_height_entries = .empty,
            .transcript_scroll_valid = false,
            .transcript_scroll_y = 0.0,
            .draft_image = null,
            .draft_extra_images = .empty,
            .draft_storage = std.mem.zeroes([AppState.DRAFT_CAPACITY:0]u8),
        };
    }

    fn currentDraft(self: *const ChatThread) []const u8 {
        const slice = self.draft_storage[0..];
        return std.mem.sliceTo(slice, 0);
    }

    fn draftBuffer(self: *ChatThread) [:0]u8 {
        return self.draft_storage[0 .. self.draft_storage.len - 1 :0];
    }

    fn setDraft(self: *ChatThread, value: []const u8) void {
        const len = @min(value.len, AppState.DRAFT_CAPACITY - 1);
        @memcpy(self.draft_storage[0..len], value[0..len]);
        self.draft_storage[len] = 0;
    }

    fn clearDraft(self: *ChatThread) void {
        self.draft_storage[0] = 0;
    }

    fn setDraftImage(self: *ChatThread, allocator: std.mem.Allocator, path: []const u8, mime: []const u8, byte_size: usize) !void {
        self.clearDraftImage(allocator);
        self.draft_image = try ChatImageAttachment.init(allocator, path, mime, byte_size);
    }

    fn addDraftImage(self: *ChatThread, allocator: std.mem.Allocator, path: []const u8, mime: []const u8, byte_size: usize) !void {
        if (self.draft_image == null) {
            self.draft_image = try ChatImageAttachment.init(allocator, path, mime, byte_size);
            return;
        }
        try self.draft_extra_images.append(allocator, try ChatImageAttachment.init(allocator, path, mime, byte_size));
    }

    fn clearDraftImage(self: *ChatThread, allocator: std.mem.Allocator) void {
        if (self.draft_image) |*image| {
            image.deinit(allocator);
            self.draft_image = null;
        }
        for (self.draft_extra_images.items) |*image| {
            image.deinit(allocator);
        }
        self.draft_extra_images.clearRetainingCapacity();
    }

    fn clearDraftImageAt(self: *ChatThread, allocator: std.mem.Allocator, index: usize) void {
        if (index == 0) {
            if (self.draft_image) |*image| image.deinit(allocator);
            if (self.draft_extra_images.items.len > 0) {
                self.draft_image = self.draft_extra_images.orderedRemove(0);
            } else {
                self.draft_image = null;
            }
            return;
        }
        const extra_index = index - 1;
        if (extra_index >= self.draft_extra_images.items.len) return;
        var image = self.draft_extra_images.orderedRemove(extra_index);
        image.deinit(allocator);
    }

    pub fn draftImageCount(self: *const ChatThread) usize {
        return (if (self.draft_image != null) @as(usize, 1) else 0) + self.draft_extra_images.items.len;
    }

    pub fn draftImageAt(self: *const ChatThread, index: usize) ?*const ChatImageAttachment {
        if (index == 0) return if (self.draft_image) |*image| image else null;
        const extra_index = index - 1;
        if (extra_index >= self.draft_extra_images.items.len) return null;
        return &self.draft_extra_images.items[extra_index];
    }

    fn commitFromPrompt(self: *ChatThread, allocator: std.mem.Allocator, prompt: []const u8) !void {
        self.committed = true;
        self.touch();
        const next_title = try chat_threads.makeThreadTitle(allocator, prompt);
        allocator.free(self.title);
        self.title = next_title;
    }

    fn touch(self: *ChatThread) void {
        self.last_activity_at = unixTimestampSeconds();
    }

    fn isSendPending(self: *const ChatThread) bool {
        self.send_state.mutex.lock();
        defer self.send_state.mutex.unlock();
        return self.send_state.status == .pending;
    }

    pub fn isSendPendingForUi(self: *const ChatThread) bool {
        if (!self.send_state.mutex.tryLock()) return true;
        defer self.send_state.mutex.unlock();
        return self.send_state.status == .pending;
    }

    fn finishSendThread(self: *ChatThread) void {
        self.send_state.mutex.lock();
        const maybe_worker = self.send_state.worker;
        self.send_state.worker = null;
        const status = self.send_state.status;
        const provider = self.provider;
        self.send_state.mutex.unlock();

        if (maybe_worker) |worker| {
            runtime_log.diagnostic("shutdown joining send thread provider={s} status={s}", .{ @tagName(provider), @tagName(status) });
            worker.join();
            runtime_log.diagnostic("shutdown joined send thread provider={s}", .{@tagName(provider)});
        }
    }

    fn ensureTranscriptMarkdownEntries(self: *ChatThread, allocator: std.mem.Allocator) void {
        const message_count = self.messages.items.len;
        if (self.transcript_markdown_entries.items.len > message_count) {
            for (self.transcript_markdown_entries.items[message_count..]) |entry| {
                if (entry) |owned| owned.deinit(allocator);
            }
            self.transcript_markdown_entries.shrinkRetainingCapacity(message_count);
        } else if (self.transcript_markdown_entries.items.len < message_count) {
            self.transcript_markdown_entries.appendNTimes(allocator, null, message_count - self.transcript_markdown_entries.items.len) catch return;
        }
    }

    fn clearTranscriptMarkdownEntries(self: *ChatThread, allocator: std.mem.Allocator) void {
        for (self.transcript_markdown_entries.items) |entry| {
            if (entry) |owned| owned.deinit(allocator);
        }
        self.transcript_markdown_entries.clearRetainingCapacity();
    }

    fn ensureTranscriptHeightEntries(self: *ChatThread, allocator: std.mem.Allocator) void {
        const message_count = self.messages.items.len;
        if (self.transcript_height_entries.items.len > message_count) {
            self.transcript_height_entries.shrinkRetainingCapacity(message_count);
        } else if (self.transcript_height_entries.items.len < message_count) {
            self.transcript_height_entries.appendNTimes(allocator, .{}, message_count - self.transcript_height_entries.items.len) catch return;
        }
    }

    fn clearTranscriptHeightEntries(self: *ChatThread) void {
        self.transcript_height_entries.clearRetainingCapacity();
    }

    fn backgroundCommandFromEventBody(body_raw: []const u8) []const u8 {
        const body = std.mem.trim(u8, body_raw, "\n\r\t ");
        if (std.mem.find(u8, body, "\n\n")) |index| {
            return std.mem.trim(u8, body[0..index], "\n\r\t ");
        }
        return body;
    }

    fn backgroundTaskStatusForEvent(author: []const u8) ?BackgroundTaskStatus {
        if (std.mem.eql(u8, author, "Backgrounded command")) return .running;
        if (std.mem.eql(u8, author, "Background task completed")) return .completed;
        if (std.mem.eql(u8, author, "Background task failed")) return .failed;
        if (std.mem.eql(u8, author, "Background task stopped")) return .stopped;
        return null;
    }

    fn backgroundTaskMetadataValue(body_raw: []const u8, label: []const u8) ?[]const u8 {
        var lines = std.mem.splitScalar(u8, body_raw, '\n');
        while (lines.next()) |line_raw| {
            const line = std.mem.trim(u8, line_raw, "\r\t ");
            if (!std.mem.startsWith(u8, line, label)) continue;
            return std.mem.trim(u8, line[label.len..], "\r\t ");
        }
        return null;
    }

    fn allocPrintZCompat(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) ![:0]u8 {
        const raw = try std.fmt.allocPrint(allocator, fmt, args);
        defer allocator.free(raw);
        return try allocator.dupeZ(u8, raw);
    }

    fn backgroundTaskPidPathForId(allocator: std.mem.Allocator, task_id: []const u8) ![:0]const u8 {
        const temp_dir = try platform_paths.tempDir(allocator);
        defer allocator.free(temp_dir);
        const filename = try std.fmt.allocPrint(allocator, "verde-claude-bg-{s}.pid", .{task_id});
        defer allocator.free(filename);
        const joined = try std.fs.path.join(allocator, &.{ temp_dir, filename });
        defer allocator.free(joined);
        return try allocator.dupeZ(u8, joined);
    }

    fn replaceOptionalZ(
        allocator: std.mem.Allocator,
        slot: *?[:0]const u8,
        value: ?[]const u8,
    ) !void {
        const raw = value orelse return;
        if (raw.len == 0) return;
        if (slot.*) |existing| {
            if (std.mem.eql(u8, existing, raw)) return;
            allocator.free(existing);
        }
        slot.* = try allocator.dupeZ(u8, raw);
    }

    fn refreshBackgroundTaskMetadata(task: *BackgroundTask, allocator: std.mem.Allocator, body_raw: []const u8) !void {
        const explicit_pid_path = backgroundTaskMetadataValue(body_raw, "PID file:");
        if (backgroundTaskMetadataValue(body_raw, "Verde task ID:")) |task_id| {
            const previous_matches = task.task_id != null and std.mem.eql(u8, task.task_id.?, task_id);
            try replaceOptionalZ(allocator, &task.task_id, task_id);
            if (explicit_pid_path == null and (task.pid_path == null or !previous_matches)) {
                if (task.pid_path) |existing| allocator.free(existing);
                task.pid_path = try backgroundTaskPidPathForId(allocator, task_id);
            }
        }
        try replaceOptionalZ(allocator, &task.pid_path, explicit_pid_path);
        try replaceOptionalZ(allocator, &task.log_path, backgroundTaskMetadataValue(body_raw, "Output log:"));
    }

    fn noteBackgroundTaskEvent(self: *ChatThread, allocator: std.mem.Allocator, author: []const u8, body_raw: []const u8) !void {
        const status = backgroundTaskStatusForEvent(author) orelse return;
        const command = backgroundCommandFromEventBody(body_raw);
        if (command.len == 0) return;

        for (self.background_tasks.items) |*task| {
            if (!std.mem.eql(u8, task.command, command)) continue;
            task.status = status;
            task.updated_at_ms = unixTimestampMs();
            try refreshBackgroundTaskMetadata(task, allocator, body_raw);
            return;
        }

        var task: BackgroundTask = .{
            .command = try allocator.dupeZ(u8, command),
            .status = status,
            .updated_at_ms = unixTimestampMs(),
        };
        errdefer task.deinit(allocator);
        try refreshBackgroundTaskMetadata(&task, allocator, body_raw);
        try self.background_tasks.append(allocator, task);
    }

    fn rebuildBackgroundTasksFromMessages(self: *ChatThread, allocator: std.mem.Allocator) void {
        for (self.messages.items) |message| {
            if (message.role != .system) continue;
            self.noteBackgroundTaskEvent(allocator, message.author, message.body) catch |err| {
                log.warn("failed to restore background task metadata: {s}", .{@errorName(err)});
            };
        }
    }

    pub fn backgroundCommandIsRunning(self: *const ChatThread, body_raw: []const u8) bool {
        const command = backgroundCommandFromEventBody(body_raw);
        if (command.len == 0) return false;
        for (self.background_tasks.items) |task| {
            if (task.status == .running and std.mem.eql(u8, task.command, command)) return true;
        }
        return false;
    }

    fn stopRunningBackgroundTasks(self: *ChatThread) void {
        const now_ms = unixTimestampMs();
        for (self.background_tasks.items) |*task| {
            if (task.status == .running) {
                task.status = .stopped;
                task.updated_at_ms = now_ms;
            }
        }
    }

    fn deinitSendState(self: *ChatThread, allocator: std.mem.Allocator) void {
        self.finishSendThread();
        if (self.send_state.result) |result| {
            std.heap.page_allocator.free(result.provider_thread_id);
            std.heap.page_allocator.free(result.reply_text);
            self.send_state.result = null;
        }
        if (self.send_state.error_message) |message| {
            std.heap.page_allocator.free(message);
            self.send_state.error_message = null;
        }
        if (self.send_state.provisional_provider_thread_id) |thread_id| {
            std.heap.page_allocator.free(thread_id);
            self.send_state.provisional_provider_thread_id = null;
        }
        if (self.send_state.active_turn_id) |turn_id| {
            std.heap.page_allocator.free(turn_id);
            self.send_state.active_turn_id = null;
        }
        if (self.send_state.daemon_turn_id) |turn_id| {
            std.heap.page_allocator.free(turn_id);
            self.send_state.daemon_turn_id = null;
        }
        freePendingFollowup(std.heap.page_allocator, &self.send_state.pending_followup);
        self.send_state.partial_text.deinit(std.heap.page_allocator);
        freePendingTimelineEvents(std.heap.page_allocator, &self.send_state.pending_events);
        freePendingDiffFiles(std.heap.page_allocator, &self.send_state.pending_diff_files);
        freePendingApproval(std.heap.page_allocator, &self.send_state.pending_approval);
        allocator.destroy(self.send_state);
    }

    fn deinit(self: *ChatThread, allocator: std.mem.Allocator) void {
        self.deinitSendState(allocator);
        self.clearTranscriptMarkdownEntries(allocator);
        self.transcript_markdown_entries.deinit(allocator);
        self.transcript_height_entries.deinit(allocator);
        allocator.free(self.title);
        allocator.free(self.local_thread_id);
        if (self.provider_thread_id) |thread_id| allocator.free(thread_id);
        if (self.model_ref) |model_ref| allocator.free(model_ref);
        if (self.opencode_reasoning_variant) |variant| allocator.free(variant);
        for (self.messages.items) |message| {
            allocator.free(message.author);
            allocator.free(message.body);
            if (message.image) |*image| image.deinit(allocator);
            for (message.extra_images) |*image| image.deinit(allocator);
            allocator.free(message.extra_images);
        }
        self.messages.deinit(allocator);
        for (self.background_tasks.items) |task| task.deinit(allocator);
        self.background_tasks.deinit(allocator);
        self.clearDraftImage(allocator);
        self.draft_extra_images.deinit(allocator);
    }
};
pub const PickerStatus = enum {
    idle,
    pending,
    selected,
    cancelled,
    unavailable,
    failed,
};
pub const PickerState = struct {
    mutex: Mutex = .{},
    status: PickerStatus = .idle,
    selected_path: ?[]u8 = null,
    worker: ?std.Thread = null,
};

const OpencodeModelCacheStatus = enum {
    idle,
    pending,
    completed,
    failed,
};

const OpencodeModelCacheState = struct {
    mutex: Mutex = .{},
    status: OpencodeModelCacheStatus = .idle,
    models: ?[]ai_harness.ModelInfo = null,
    worker: ?std.Thread = null,
};

const CursorModelCacheStatus = OpencodeModelCacheStatus;

const CursorModelCacheState = struct {
    mutex: Mutex = .{},
    status: CursorModelCacheStatus = .idle,
    models: ?[]ai_harness.ModelInfo = null,
    worker: ?std.Thread = null,
};

const ClaudeModelCacheStatus = OpencodeModelCacheStatus;

const ClaudeModelCacheState = struct {
    mutex: Mutex = .{},
    status: ClaudeModelCacheStatus = .idle,
    models: ?[]ai_harness.ModelInfo = null,
    worker: ?std.Thread = null,
};

pub const ProviderReadiness = enum {
    checking,
    missing,
    signed_out,
    ready,
    unavailable,
};

pub const ProviderReadinessSnapshot = struct {
    codex: ProviderReadiness = .checking,
    opencode: ProviderReadiness = .checking,
    claude: ProviderReadiness = .checking,
    cursor: ProviderReadiness = .checking,

    pub fn forProvider(self: ProviderReadinessSnapshot, provider: Provider) ProviderReadiness {
        return switch (provider) {
            .codex => self.codex,
            .opencode => self.opencode,
            .claude => self.claude,
            .cursor => self.cursor,
        };
    }

    fn hasReadyProvider(self: ProviderReadinessSnapshot) bool {
        return self.codex == .ready or self.opencode == .ready or self.claude == .ready or self.cursor == .ready;
    }
};

const ProviderReadinessStatus = enum {
    idle,
    pending,
    completed,
};

const ProviderReadinessState = struct {
    mutex: Mutex = .{},
    status: ProviderReadinessStatus = .idle,
    snapshot: ProviderReadinessSnapshot = .{},
    worker: ?std.Thread = null,
};

const SlashCommandStatus = enum {
    idle,
    pending,
    completed,
    failed,
};

const SlashCommandState = struct {
    mutex: Mutex = .{},
    status: SlashCommandStatus = .idle,
    worker: ?std.Thread = null,
    project_index: usize = 0,
    thread_index: usize = 0,
    provider: Provider = .codex,
    command: ai_harness.ProviderSlashCommandId = .usage,
    display_name: ?[]u8 = null,
    started_at_ms: i64 = 0,
    result: ?ai_harness.RunSlashCommandResult = null,
    error_message: ?[]u8 = null,
};

pub const PendingSlashCommandDetails = struct {
    provider: Provider,
    command: ai_harness.ProviderSlashCommandId,
    display_name: []const u8,
    started_at_ms: i64,
};

const SlashCommandWorkerRequest = struct {
    provider: Provider,
    harness: Harness,
    project_path: []u8,
    remote_ssh_host: ?[]u8 = null,
    remote_cwd: ?[]u8 = null,
    thread_id: ?[]u8,
    command: ai_harness.ProviderSlashCommandId,
    raw_text: []u8,
    args: []u8,
};

const FileSearchToken = struct {
    at_start: usize,
    query_start: usize,
    end: usize,
};

pub const FileSearchResult = struct {
    path: []u8,
    relative_path: []u8,
    file_name: []u8,

    fn deinit(self: FileSearchResult, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.relative_path);
        allocator.free(self.file_name);
    }
};

pub const ImportThreadSummary = struct {
    id: [:0]const u8,
    title: [:0]const u8,

    fn deinit(self: ImportThreadSummary, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.title);
    }
};

pub const HerdrProfileSummary = struct {
    name: [:0]const u8,
    ssh_target: [:0]const u8,
    session: [:0]const u8,
    remote_cwd: ?[:0]const u8 = null,
    local_dir: ?[:0]const u8 = null,

    fn deinit(self: HerdrProfileSummary, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.ssh_target);
        allocator.free(self.session);
        if (self.remote_cwd) |value| allocator.free(value);
        if (self.local_dir) |value| allocator.free(value);
    }
};

const FileSearchState = struct {
    finder: ?fff.Finder = null,
    project_path: ?[]u8 = null,
    last_query: ?[]u8 = null,
    token: ?FileSearchToken = null,
    results: std.ArrayList(FileSearchResult) = .empty,
    total_matched: usize = 0,
    total_files: usize = 0,
    visible: bool = false,
    selected_index: usize = 0,
    ensure_selection_visible: bool = false,

    fn clearResults(self: *FileSearchState, allocator: std.mem.Allocator) void {
        for (self.results.items) |item| item.deinit(allocator);
        self.results.clearRetainingCapacity();
        self.total_matched = 0;
        self.total_files = 0;
        self.selected_index = 0;
        self.ensure_selection_visible = false;
    }

    fn setResults(self: *FileSearchState, allocator: std.mem.Allocator, search_results: *fff.SearchResults) !void {
        self.clearResults(allocator);
        try self.results.ensureTotalCapacity(allocator, search_results.items.len);
        var appended: usize = 0;
        errdefer {
            for (self.results.items[0..appended]) |item| item.deinit(allocator);
            self.results.clearRetainingCapacity();
        }
        for (search_results.items) |item| {
            self.results.appendAssumeCapacity(.{
                .path = try allocator.dupe(u8, item.path),
                .relative_path = try allocator.dupe(u8, item.relative_path),
                .file_name = try allocator.dupe(u8, item.file_name),
            });
            appended += 1;
        }
        self.total_matched = search_results.total_matched;
        self.total_files = search_results.total_files;
        self.selected_index = 0;
        self.ensure_selection_visible = true;
    }

    fn clearQuery(self: *FileSearchState, allocator: std.mem.Allocator) void {
        if (self.last_query) |query| allocator.free(query);
        self.last_query = null;
    }

    fn deinit(self: *FileSearchState, allocator: std.mem.Allocator) void {
        self.clearResults(allocator);
        self.results.deinit(allocator);
        self.clearQuery(allocator);
        if (self.project_path) |project_path| allocator.free(project_path);
        if (self.finder) |*finder| finder.deinit();
        self.* = .{};
    }
};

pub const TextureBackend = enum {
    external,
};

pub const CachedImageTexture = struct {
    texture_id: c_uint = 0,
    width: i32 = 0,
    height: i32 = 0,
    valid: bool = false,
    backend: TextureBackend = .external,

    fn deinit(self: CachedImageTexture) void {
        _ = self;
    }
};

pub const WorkspacePaneId = u32;

pub const WorkspacePaneKind = enum {
    chat,
    terminal,
    browser,
};

pub const WorkspacePaneRef = union(WorkspacePaneKind) {
    chat: ChatPaneRef,
    terminal: TerminalPaneRef,
    browser: BrowserPaneRef,
};

pub const ChatPaneRef = struct {
    thread_index: usize = 0,
    transcript_scroll_valid: bool = false,
    transcript_scroll_y: f32 = 0.0,
};

pub const TerminalPaneRef = struct {
    dock_id: u32 = 0,
    purpose: TerminalPanePurpose = .normal,
};

pub const TerminalPanePurpose = enum {
    normal,
    editor,
};

pub const BrowserPaneRef = struct {
    url: ?[]u8 = null,
    title: ?[]u8 = null,
    history: std.ArrayList([]u8) = .empty,
    history_index: ?usize = null,

    fn deinit(self: *BrowserPaneRef, allocator: std.mem.Allocator) void {
        if (self.url) |url| allocator.free(url);
        if (self.title) |title| allocator.free(title);
        for (self.history.items) |entry| allocator.free(entry);
        self.history.deinit(allocator);
        self.* = .{};
    }

    fn setUrl(self: *BrowserPaneRef, allocator: std.mem.Allocator, value: ?[]const u8) !void {
        if (self.url) |url| allocator.free(url);
        self.url = if (value) |slice| try allocator.dupe(u8, slice) else null;
    }

    fn setTitle(self: *BrowserPaneRef, allocator: std.mem.Allocator, value: ?[]const u8) !void {
        if (self.title) |title| allocator.free(title);
        self.title = if (value) |slice| try allocator.dupe(u8, slice) else null;
    }

    fn recordNavigation(self: *BrowserPaneRef, allocator: std.mem.Allocator, url: []const u8) !void {
        if (self.url) |current| {
            if (std.mem.eql(u8, current, url)) return;
        }

        if (self.history_index) |index| {
            if (index < self.history.items.len and std.mem.eql(u8, self.history.items[index], url)) {
                try self.setUrl(allocator, url);
                return;
            }
            const remove_index = index + 1;
            while (self.history.items.len > remove_index) {
                allocator.free(self.history.items[self.history.items.len - 1]);
                self.history.items.len -= 1;
            }
        } else if (self.history.items.len > 0) {
            for (self.history.items) |entry| allocator.free(entry);
            self.history.clearRetainingCapacity();
        }

        try self.appendHistoryEntry(allocator, url);
        self.history_index = self.history.items.len - 1;
        try self.setUrl(allocator, url);
    }

    fn appendHistoryEntry(self: *BrowserPaneRef, allocator: std.mem.Allocator, url: []const u8) !void {
        const owned = try allocator.dupe(u8, url);
        errdefer allocator.free(owned);
        try self.history.append(allocator, owned);
    }

    fn historyTarget(self: *const BrowserPaneRef, delta: i32) ?struct { index: usize, url: []const u8 } {
        const index = self.history_index orelse return null;
        const target: isize = @as(isize, @intCast(index)) + @as(isize, @intCast(delta));
        if (target < 0) return null;
        const target_index: usize = @intCast(target);
        if (target_index >= self.history.items.len) return null;
        return .{ .index = target_index, .url = self.history.items[target_index] };
    }
};

fn deinitWorkspacePaneRef(ref: *WorkspacePaneRef, allocator: std.mem.Allocator) void {
    switch (ref.*) {
        .browser => |*browser| browser.deinit(allocator),
        .chat, .terminal => {},
    }
}

pub const BrowserOpenResult = struct {
    pane_id: WorkspacePaneId,
    workspace_index: usize,
    moved_from_workspace: ?usize,
};

pub const BrowserWorkspaceLocation = struct {
    index: usize,
    pane_id: WorkspacePaneId,
};

const ViewFocusSnapshot = struct {
    selected_project_index: usize,
    terminal_focused: bool,
    composer_focused: bool,
    palette_composer_focused: bool,
    browser_address_focused: bool,
};

pub const WorkspacePane = struct {
    id: WorkspacePaneId,
    ref: WorkspacePaneRef,
    minimized: bool = false,
};

pub const WorkspacePanePlacement = struct {
    pane_id: WorkspacePaneId,
    axis: WorkspaceSplitAxis,
    new_after: bool,
};

const WorkspaceLayoutRect = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
};

const WorkspacePaneLayoutRect = struct {
    pane_id: WorkspacePaneId,
    x: f32,
    y: f32,
    w: f32,
    h: f32,
};

pub const WorkspaceMinimizedPane = struct {
    id: WorkspacePaneId,
    kind: WorkspacePaneKind,
};

pub const TerminalDockEntry = struct {
    id: u32,
    dock: terminal.Dock,

    fn deinit(self: *TerminalDockEntry, allocator: std.mem.Allocator) void {
        self.dock.deinit(allocator);
    }
};

pub const ManagedProcessStatus = enum {
    stopped,
    starting,
    running,
    crashed,
    restarting,
};

pub const ManagedProcess = struct {
    name: []u8,
    kind: stack_config.ProcessKind,
    command: []u8,
    argv: std.ArrayList([]u8) = .empty,
    cwd: []u8,
    restart: stack_config.RestartPolicy,
    provider: ?stack_config.AgentProvider = null,
    revive: stack_config.RevivePolicy = .attach_or_create,
    notify: bool = false,
    mcp: bool = false,
    hooks: bool = false,
    watch: std.ArrayList([]u8) = .empty,
    status: ManagedProcessStatus = .stopped,
    exit_code: ?u32 = null,
    signal: ?u32 = null,
    last_start_ms: i64 = 0,
    last_exit_ms: i64 = 0,
    next_restart_ms: i64 = 0,
    restart_count: u32 = 0,
    watch_trigger_count: u32 = 0,
    last_watch_scan_ms: i64 = 0,
    last_watch_change_ms: i64 = 0,
    pending_watch_restart_ms: i64 = 0,
    watch_signature: u64 = 0,
    watch_ready: bool = false,
    watch_error_count: u32 = 0,
    dock_id: ?u32 = null,
    pane_id: ?WorkspacePaneId = null,
    explicit_stop: bool = false,

    fn initFromDefinition(allocator: std.mem.Allocator, definition: stack_config.ProcessDefinition) !ManagedProcess {
        const launch = definition.launchForOs(builtin.os.tag) orelse return error.ManagedProcessUnavailableOnPlatform;
        var process: ManagedProcess = .{
            .name = try allocator.dupe(u8, definition.name),
            .kind = definition.kind,
            .command = try allocator.dupe(u8, if (launch == .command) launch.command else ""),
            .argv = .empty,
            .cwd = try allocator.dupe(u8, definition.cwd),
            .restart = definition.restart,
            .provider = definition.provider,
            .revive = definition.revive,
            .notify = definition.notify,
            .mcp = definition.mcp,
            .hooks = definition.hooks,
            .watch = .empty,
        };
        errdefer process.deinit(allocator);
        if (launch == .argv) {
            for (launch.argv) |arg| try appendOwnedString(allocator, &process.argv, arg);
        }
        for (definition.watch.items) |pattern| {
            try appendOwnedString(allocator, &process.watch, pattern);
        }
        return process;
    }

    fn updateFromDefinition(self: *ManagedProcess, allocator: std.mem.Allocator, definition: stack_config.ProcessDefinition) !void {
        const launch = definition.launchForOs(builtin.os.tag) orelse return error.ManagedProcessUnavailableOnPlatform;
        self.kind = definition.kind;
        self.restart = definition.restart;
        self.provider = definition.provider;
        self.revive = definition.revive;
        self.notify = definition.notify;
        self.mcp = definition.mcp;
        self.hooks = definition.hooks;
        var reset_watch_state = false;
        const next_command = if (launch == .command) launch.command else "";
        const next_argv = if (launch == .argv) launch.argv else &.{};
        if (!std.mem.eql(u8, self.command, next_command) or !argvEqual(self.argv.items, next_argv)) {
            const replacement_command = try allocator.dupe(u8, next_command);
            errdefer allocator.free(replacement_command);
            var replacement_argv: std.ArrayList([]u8) = .empty;
            errdefer deinitOwnedArgv(allocator, &replacement_argv);
            for (next_argv) |arg| try appendOwnedString(allocator, &replacement_argv, arg);

            allocator.free(self.command);
            deinitOwnedArgv(allocator, &self.argv);
            self.command = replacement_command;
            self.argv = replacement_argv;
        }
        if (!std.mem.eql(u8, self.cwd, definition.cwd)) {
            allocator.free(self.cwd);
            self.cwd = try allocator.dupe(u8, definition.cwd);
            reset_watch_state = true;
        }
        if (!watchPatternsEqual(self.watch.items, definition.watch.items)) reset_watch_state = true;
        for (self.watch.items) |pattern| allocator.free(pattern);
        self.watch.clearRetainingCapacity();
        for (definition.watch.items) |pattern| {
            try appendOwnedString(allocator, &self.watch, pattern);
        }
        if (reset_watch_state) self.resetWatchState();
    }

    fn deinit(self: *ManagedProcess, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.command);
        deinitOwnedArgv(allocator, &self.argv);
        allocator.free(self.cwd);
        for (self.watch.items) |pattern| allocator.free(pattern);
        self.watch.deinit(allocator);
    }

    fn resetWatchState(self: *ManagedProcess) void {
        self.watch_signature = 0;
        self.watch_ready = false;
        self.last_watch_scan_ms = 0;
        self.last_watch_change_ms = 0;
        self.pending_watch_restart_ms = 0;
        self.watch_error_count = 0;
    }

    fn watchPatternsEqual(left: []const []u8, right: []const []u8) bool {
        if (left.len != right.len) return false;
        for (left, right) |l, r| {
            if (!std.mem.eql(u8, l, r)) return false;
        }
        return true;
    }

    fn argvEqual(left: []const []u8, right: []const []u8) bool {
        if (left.len != right.len) return false;
        for (left, right) |l, r| {
            if (!std.mem.eql(u8, l, r)) return false;
        }
        return true;
    }

    fn deinitOwnedArgv(allocator: std.mem.Allocator, argv: *std.ArrayList([]u8)) void {
        for (argv.items) |arg| allocator.free(arg);
        argv.deinit(allocator);
    }
};

fn appendOwnedString(allocator: std.mem.Allocator, list: *std.ArrayList([]u8), value: []const u8) !void {
    const owned = try allocator.dupe(u8, value);
    errdefer allocator.free(owned);
    try list.append(allocator, owned);
}

const DefaultAgentTui = struct {
    name: []const u8,
    command: []const u8,
    provider: stack_config.AgentProvider,
    notify: bool = false,
    mcp: bool = false,
    hooks: bool = false,
};

const OPENCODE_TUI_COMMAND =
    \\candidate=$(find "$HOME/.npm/_npx" -path '*/node_modules/opencode-linux-x64*/bin/opencode' -type f -perm -111 2>/dev/null | sort | tail -n 1)
    \\if [ -n "$candidate" ]; then exec "$candidate"; fi
    \\exec opencode
;

fn opencodeTuiCommandForOs(comptime os_tag: std.Target.Os.Tag) []const u8 {
    // The npx cache fallback is Unix-specific. Windows executable discovery
    // already honors PATHEXT, including the common opencode.cmd shim.
    return if (os_tag == .windows) "opencode" else OPENCODE_TUI_COMMAND;
}

fn defaultAgentTui(provider: stack_config.AgentProvider) ?DefaultAgentTui {
    return switch (provider) {
        .codex => .{ .name = "codex", .command = "codex", .provider = .codex, .notify = true, .mcp = true, .hooks = true },
        .claude => .{ .name = "claude", .command = "claude", .provider = .claude },
        .opencode => .{ .name = "opencode", .command = opencodeTuiCommandForOs(builtin.os.tag), .provider = .opencode },
        .cursor => .{ .name = "cursor", .command = "agent", .provider = .cursor },
        .amp => .{ .name = "amp", .command = "amp", .provider = .amp },
        .other => null,
    };
}

fn isKnownDefaultAgentTuiCommand(provider: stack_config.AgentProvider, command: []const u8) bool {
    return switch (provider) {
        .codex => std.mem.eql(u8, command, "codex"),
        .claude => std.mem.eql(u8, command, "claude"),
        .opencode => std.mem.eql(u8, command, "opencode") or std.mem.eql(u8, command, OPENCODE_TUI_COMMAND),
        .cursor => std.mem.eql(u8, command, "agent"),
        .amp => std.mem.eql(u8, command, "amp"),
        .other => false,
    };
}

fn agentTuiProviderLabel(provider: ?stack_config.AgentProvider) []const u8 {
    return switch (provider orelse return "Agent") {
        .codex => "Codex",
        .claude => "Claude",
        .opencode => "OpenCode",
        .cursor => "Cursor",
        .amp => "Amp",
        .other => "Agent",
    };
}

pub const WorkspaceSplitAxis = enum {
    horizontal,
    vertical,
};

pub const WorkspacePaneDirection = enum {
    left,
    right,
    up,
    down,
};

pub const WorkspaceNode = union(enum) {
    leaf: WorkspacePaneId,
    split: struct {
        axis: WorkspaceSplitAxis,
        ratio: f32,
        first: *WorkspaceNode,
        second: *WorkspaceNode,
    },
};

pub const WorkspaceLayout = struct {
    next_pane_id: WorkspacePaneId = 1,
    root: ?*WorkspaceNode = null,
    panes: std.ArrayList(WorkspacePane) = .empty,
    focused_pane_id: ?WorkspacePaneId = null,
    maximized_pane_id: ?WorkspacePaneId = null,

    fn initDefaultChat(allocator: std.mem.Allocator) !WorkspaceLayout {
        var layout: WorkspaceLayout = .{};
        errdefer layout.deinit(allocator);
        const pane_id = layout.next_pane_id;
        layout.next_pane_id += 1;
        try layout.panes.append(allocator, .{
            .id = pane_id,
            .ref = .{ .chat = .{ .thread_index = 0 } },
        });
        layout.root = try createLeafNode(allocator, pane_id);
        layout.focused_pane_id = pane_id;
        return layout;
    }

    fn deinit(self: *WorkspaceLayout, allocator: std.mem.Allocator) void {
        if (self.root) |root| destroyNode(allocator, root);
        for (self.panes.items) |*pane| deinitWorkspacePaneRef(&pane.ref, allocator);
        self.panes.deinit(allocator);
        self.* = .{};
    }

    fn ensureDefaultChat(self: *WorkspaceLayout, allocator: std.mem.Allocator) !bool {
        if (self.root != null and self.panes.items.len > 0 and self.firstVisiblePaneId() != null) {
            return try self.repairVisibleRoot(allocator);
        }

        self.deinit(allocator);
        self.* = try WorkspaceLayout.initDefaultChat(allocator);
        return true;
    }

    fn repairVisibleRoot(self: *WorkspaceLayout, allocator: std.mem.Allocator) !bool {
        var changed = false;
        if (self.root) |root_node| {
            const repaired = pruneRootToVisiblePanes(allocator, self, root_node);
            self.root = repaired.node;
            changed = changed or repaired.changed;
        }
        if (self.root == null) {
            if (self.firstVisiblePaneId()) |pane_id| {
                self.root = try createLeafNode(allocator, pane_id);
                changed = true;
            }
        }
        if (self.focused_pane_id) |pane_id| {
            if (!self.paneIdVisible(pane_id)) {
                self.focused_pane_id = self.firstVisiblePaneId();
                changed = true;
            }
        } else {
            self.focused_pane_id = self.firstVisiblePaneId();
            changed = changed or self.focused_pane_id != null;
        }
        if (self.maximized_pane_id) |pane_id| {
            if (!self.paneIdVisible(pane_id)) {
                self.maximized_pane_id = null;
                changed = true;
            }
        }
        return changed;
    }

    fn paneIdVisible(self: *const WorkspaceLayout, pane_id: WorkspacePaneId) bool {
        const pane = self.paneById(pane_id) orelse return false;
        return !pane.minimized;
    }

    fn firstVisiblePaneId(self: *const WorkspaceLayout) ?WorkspacePaneId {
        for (self.panes.items) |pane| {
            if (!pane.minimized) return pane.id;
        }
        return null;
    }

    pub fn paneById(self: *const WorkspaceLayout, pane_id: WorkspacePaneId) ?*const WorkspacePane {
        for (self.panes.items) |*pane| {
            if (pane.id == pane_id) return pane;
        }
        return null;
    }

    fn paneByIdMutable(self: *WorkspaceLayout, pane_id: WorkspacePaneId) ?*WorkspacePane {
        for (self.panes.items) |*pane| {
            if (pane.id == pane_id) return pane;
        }
        return null;
    }

    fn visibleChatPaneIdForThread(self: *const WorkspaceLayout, thread_index: usize) ?WorkspacePaneId {
        for (self.panes.items) |pane| {
            if (pane.minimized) continue;
            switch (pane.ref) {
                .chat => |ref| if (ref.thread_index == thread_index) return pane.id,
                else => {},
            }
        }
        return null;
    }

    fn visibleTerminalPaneIdForDock(self: *const WorkspaceLayout, dock_id: u32) ?WorkspacePaneId {
        for (self.panes.items) |pane| {
            if (pane.minimized) continue;
            switch (pane.ref) {
                .terminal => |ref| if (ref.dock_id == dock_id) return pane.id,
                else => {},
            }
        }
        return null;
    }

    fn rootContainsPane(self: *const WorkspaceLayout, pane_id: WorkspacePaneId) bool {
        const root_node = self.root orelse return false;
        return nodeContainsPane(root_node, pane_id);
    }

    fn replaceRootWithLeaf(self: *WorkspaceLayout, allocator: std.mem.Allocator, pane_id: WorkspacePaneId) !void {
        if (self.root) |root_node| destroyNode(allocator, root_node);
        self.root = try createLeafNode(allocator, pane_id);
        self.focused_pane_id = pane_id;
    }

    fn focusedPane(self: *const WorkspaceLayout) ?*const WorkspacePane {
        const pane_id = self.focused_pane_id orelse return null;
        return self.paneById(pane_id);
    }

    fn visiblePaneCount(self: *const WorkspaceLayout) usize {
        var count: usize = 0;
        for (self.panes.items) |pane| {
            if (!pane.minimized) count += 1;
        }
        return count;
    }

    fn gridNewPanePlacement(self: *const WorkspaceLayout) ?WorkspacePanePlacement {
        if (self.maximized_pane_id != null) return null;
        const visible = self.visiblePaneCount();
        if (visible == 0 or visible >= 4) return null;

        const root_node = self.root orelse return null;
        var rects: [48]WorkspacePaneLayoutRect = undefined;
        var count: usize = 0;
        self.collectVisiblePaneRects(root_node, .{ .x = 0, .y = 0, .w = 1, .h = 1 }, &rects, &count);
        if (count == 0) return null;

        if (visible == 1) {
            return .{ .pane_id = rects[0].pane_id, .axis = .vertical, .new_after = true };
        }

        var best: usize = 0;
        var i: usize = 1;
        while (i < count) : (i += 1) {
            const a = rects[i];
            const b = rects[best];
            if (a.h > b.h + 0.001) {
                best = i;
            } else if (a.h > b.h - 0.001 and a.x < b.x - 0.001) {
                best = i;
            }
        }
        return .{ .pane_id = rects[best].pane_id, .axis = .horizontal, .new_after = true };
    }

    fn collectVisiblePaneRects(
        self: *const WorkspaceLayout,
        node: *const WorkspaceNode,
        rect: WorkspaceLayoutRect,
        rects: *[48]WorkspacePaneLayoutRect,
        count: *usize,
    ) void {
        switch (node.*) {
            .leaf => |pane_id| {
                if (!self.paneIdVisible(pane_id) or count.* >= rects.len) return;
                rects[count.*] = .{
                    .pane_id = pane_id,
                    .x = rect.x,
                    .y = rect.y,
                    .w = rect.w,
                    .h = rect.h,
                };
                count.* += 1;
            },
            .split => |split| {
                const ratio = std.math.clamp(split.ratio, 0.05, 0.95);
                switch (split.axis) {
                    .vertical => {
                        const first_w = rect.w * ratio;
                        const second_x = rect.x + first_w;
                        self.collectVisiblePaneRects(split.first, .{ .x = rect.x, .y = rect.y, .w = first_w, .h = rect.h }, rects, count);
                        self.collectVisiblePaneRects(split.second, .{ .x = second_x, .y = rect.y, .w = rect.w - first_w, .h = rect.h }, rects, count);
                    },
                    .horizontal => {
                        const first_h = rect.h * ratio;
                        const second_y = rect.y + first_h;
                        self.collectVisiblePaneRects(split.first, .{ .x = rect.x, .y = rect.y, .w = rect.w, .h = first_h }, rects, count);
                        self.collectVisiblePaneRects(split.second, .{ .x = rect.x, .y = second_y, .w = rect.w, .h = rect.h - first_h }, rects, count);
                    },
                }
            },
        }
    }

    fn paneIndexById(self: *const WorkspaceLayout, pane_id: WorkspacePaneId) ?usize {
        for (self.panes.items, 0..) |pane, index| {
            if (pane.id == pane_id) return index;
        }
        return null;
    }

    fn swapPaneRefs(self: *WorkspaceLayout, first_pane_id: WorkspacePaneId, second_pane_id: WorkspacePaneId) bool {
        const first_index = self.paneIndexById(first_pane_id) orelse return false;
        const second_index = self.paneIndexById(second_pane_id) orelse return false;
        if (self.panes.items[first_index].minimized or self.panes.items[second_index].minimized) return false;
        const first_ref = self.panes.items[first_index].ref;
        self.panes.items[first_index].ref = self.panes.items[second_index].ref;
        self.panes.items[second_index].ref = first_ref;
        return true;
    }

    fn hasVisiblePaneKind(self: *const WorkspaceLayout, kind: WorkspacePaneKind) bool {
        for (self.panes.items) |pane| {
            if (pane.minimized) continue;
            switch (pane.ref) {
                .chat => if (kind == .chat) return true,
                .terminal => if (kind == .terminal) return true,
                .browser => if (kind == .browser) return true,
            }
        }
        return false;
    }

    fn visibleBrowserPaneId(self: *const WorkspaceLayout) ?WorkspacePaneId {
        for (self.panes.items) |pane| {
            if (pane.minimized) continue;
            switch (pane.ref) {
                .browser => return pane.id,
                else => {},
            }
        }
        return null;
    }

    fn hasTerminalDockPane(self: *const WorkspaceLayout, dock_id: u32) bool {
        for (self.panes.items) |pane| {
            switch (pane.ref) {
                .terminal => |ref| if (ref.dock_id == dock_id) return true,
                else => {},
            }
        }
        return false;
    }

    fn hasEditorTerminalDockPane(self: *const WorkspaceLayout, dock_id: u32) bool {
        for (self.panes.items) |pane| {
            switch (pane.ref) {
                .terminal => |ref| if (ref.dock_id == dock_id and ref.purpose == .editor) return true,
                else => {},
            }
        }
        return false;
    }

    fn maxTerminalDockId(self: *const WorkspaceLayout) u32 {
        var max_id: u32 = 0;
        for (self.panes.items) |pane| {
            switch (pane.ref) {
                .terminal => |ref| max_id = @max(max_id, ref.dock_id),
                else => {},
            }
        }
        return max_id;
    }

    fn ensureTerminalPane(self: *WorkspaceLayout, allocator: std.mem.Allocator, dock_id: u32) !WorkspacePaneId {
        for (self.panes.items) |*pane| {
            switch (pane.ref) {
                .terminal => |ref| if (ref.dock_id == dock_id) {
                    pane.minimized = false;
                    self.focused_pane_id = pane.id;
                    try self.ensurePaneInRootSplit(allocator, pane.id, .horizontal, 0.64);
                    return pane.id;
                },
                else => {},
            }
        }

        const pane_id = self.next_pane_id;
        self.next_pane_id += 1;
        try self.panes.append(allocator, .{
            .id = pane_id,
            .ref = .{ .terminal = .{ .dock_id = dock_id } },
        });
        self.focused_pane_id = pane_id;
        try self.ensurePaneInRootSplit(allocator, pane_id, .horizontal, 0.64);
        return pane_id;
    }

    fn ensureBrowserPane(self: *WorkspaceLayout, allocator: std.mem.Allocator) !WorkspacePaneId {
        for (self.panes.items) |*pane| {
            switch (pane.ref) {
                .browser => {
                    pane.minimized = false;
                    self.focused_pane_id = pane.id;
                    try self.ensurePaneInRootSplit(allocator, pane.id, .vertical, 0.58);
                    return pane.id;
                },
                else => {},
            }
        }

        const pane_id = self.next_pane_id;
        self.next_pane_id += 1;
        try self.panes.append(allocator, .{
            .id = pane_id,
            .ref = .{ .browser = .{} },
        });
        self.focused_pane_id = pane_id;
        try self.ensurePaneInRootSplit(allocator, pane_id, .vertical, 0.58);
        return pane_id;
    }

    fn createTerminalPane(self: *WorkspaceLayout, allocator: std.mem.Allocator, dock_id: u32) !WorkspacePaneId {
        return self.createTerminalPaneWithPurpose(allocator, dock_id, .normal);
    }

    fn createTerminalPaneWithPurpose(self: *WorkspaceLayout, allocator: std.mem.Allocator, dock_id: u32, purpose: TerminalPanePurpose) !WorkspacePaneId {
        const pane_id = self.next_pane_id;
        self.next_pane_id += 1;
        try self.panes.append(allocator, .{
            .id = pane_id,
            .ref = .{ .terminal = .{ .dock_id = dock_id, .purpose = purpose } },
        });
        return pane_id;
    }

    fn createChatPane(self: *WorkspaceLayout, allocator: std.mem.Allocator, thread_index: usize) !WorkspacePaneId {
        const pane_id = self.next_pane_id;
        self.next_pane_id += 1;
        try self.panes.append(allocator, .{
            .id = pane_id,
            .ref = .{ .chat = .{ .thread_index = thread_index } },
        });
        return pane_id;
    }

    fn splitPaneWithLeaf(
        self: *WorkspaceLayout,
        allocator: std.mem.Allocator,
        target_pane_id: WorkspacePaneId,
        new_pane_id: WorkspacePaneId,
        axis: WorkspaceSplitAxis,
        new_after: bool,
    ) !void {
        if (self.root) |root_node| {
            if (try splitNodeWithLeaf(allocator, root_node, target_pane_id, new_pane_id, axis, new_after)) {
                self.focused_pane_id = new_pane_id;
                return;
            }
        }
        try self.ensurePaneInRootSplit(allocator, new_pane_id, axis, 0.5);
        self.focused_pane_id = new_pane_id;
    }

    fn minimizePaneKind(self: *WorkspaceLayout, allocator: std.mem.Allocator, kind: WorkspacePaneKind) bool {
        var changed = false;
        for (self.panes.items) |*pane| {
            switch (pane.ref) {
                .chat => if (kind == .chat and !pane.minimized) {
                    pane.minimized = true;
                    changed = true;
                },
                .terminal => if (kind == .terminal and !pane.minimized) {
                    pane.minimized = true;
                    changed = true;
                },
                .browser => if (kind == .browser and !pane.minimized) {
                    pane.minimized = true;
                    changed = true;
                },
            }
        }
        if (changed) {
            if (self.firstVisiblePaneId()) |pane_id| {
                self.replaceRootWithLeaf(allocator, pane_id) catch {
                    self.focused_pane_id = pane_id;
                };
            } else {
                self.focused_pane_id = null;
            }
        }
        return changed;
    }

    fn closePaneKind(self: *WorkspaceLayout, allocator: std.mem.Allocator, kind: WorkspacePaneKind) bool {
        var changed = false;
        var index: usize = 0;
        while (index < self.panes.items.len) {
            const pane = self.panes.items[index];
            if (std.meta.activeTag(pane.ref) != kind) {
                index += 1;
                continue;
            }
            if (self.root) |root_node| {
                self.root = removePaneFromTree(allocator, root_node, pane.id);
            }
            var removed_ref = self.panes.items[index].ref;
            deinitWorkspacePaneRef(&removed_ref, allocator);
            _ = self.panes.orderedRemove(index);
            changed = true;
        }
        if (!changed) return false;

        if (self.focused_pane_id) |pane_id| {
            const focused = self.paneById(pane_id);
            if (focused == null or focused.?.minimized) self.focused_pane_id = self.firstVisiblePaneId();
        }
        if (self.maximized_pane_id) |pane_id| {
            const maximized = self.paneById(pane_id);
            if (maximized == null or maximized.?.minimized) self.maximized_pane_id = null;
        }
        if (self.root == null) {
            if (self.firstVisiblePaneId()) |pane_id| {
                self.replaceRootWithLeaf(allocator, pane_id) catch {
                    self.focused_pane_id = pane_id;
                };
            }
        }
        return true;
    }

    fn closePane(self: *WorkspaceLayout, allocator: std.mem.Allocator, pane_id: WorkspacePaneId) ?WorkspacePaneRef {
        const pane_index = self.paneIndexById(pane_id) orelse return null;
        const removed_ref = self.panes.items[pane_index].ref;
        if (self.root) |root_node| {
            self.root = removePaneFromTree(allocator, root_node, pane_id);
        }
        _ = self.panes.orderedRemove(pane_index);
        if (self.focused_pane_id == pane_id) self.focused_pane_id = self.firstVisiblePaneId();
        if (self.maximized_pane_id == pane_id) self.maximized_pane_id = null;
        return removed_ref;
    }

    fn resizeSplit(self: *WorkspaceLayout, first_pane_id: WorkspacePaneId, second_pane_id: WorkspacePaneId, axis: WorkspaceSplitAxis, ratio: f32) bool {
        const root_node = self.root orelse return false;
        return resizeNodeSplit(root_node, first_pane_id, second_pane_id, axis, @max(0.18, @min(0.82, ratio)));
    }

    fn nudgeSplitRatio(self: *WorkspaceLayout, first_pane_id: WorkspacePaneId, second_pane_id: WorkspacePaneId, axis: WorkspaceSplitAxis, delta: f32) bool {
        const root_node = self.root orelse return false;
        return nudgeNodeSplitRatio(root_node, first_pane_id, second_pane_id, axis, delta);
    }

    fn neighborPaneId(self: *const WorkspaceLayout, pane_id: WorkspacePaneId, direction: WorkspacePaneDirection) ?WorkspacePaneId {
        const root_node = self.root orelse return null;
        if (!nodeContainsPane(root_node, pane_id)) return null;
        return self.neighborPaneIdInNode(root_node, pane_id, direction);
    }

    fn neighborPaneIdInNode(
        self: *const WorkspaceLayout,
        node: *const WorkspaceNode,
        pane_id: WorkspacePaneId,
        direction: WorkspacePaneDirection,
    ) ?WorkspacePaneId {
        switch (node.*) {
            .leaf => return null,
            .split => |split| {
                if (nodeContainsPane(split.first, pane_id)) {
                    if (self.neighborPaneIdInNode(split.first, pane_id, direction)) |neighbor| return neighbor;
                    if ((direction == .right and split.axis == .vertical) or
                        (direction == .down and split.axis == .horizontal))
                    {
                        return self.edgeVisiblePaneId(split.second, false);
                    }
                    return null;
                }
                if (nodeContainsPane(split.second, pane_id)) {
                    if (self.neighborPaneIdInNode(split.second, pane_id, direction)) |neighbor| return neighbor;
                    if ((direction == .left and split.axis == .vertical) or
                        (direction == .up and split.axis == .horizontal))
                    {
                        return self.edgeVisiblePaneId(split.first, true);
                    }
                    return null;
                }
                return null;
            },
        }
    }

    fn edgeVisiblePaneId(self: *const WorkspaceLayout, node: *const WorkspaceNode, prefer_second: bool) ?WorkspacePaneId {
        switch (node.*) {
            .leaf => |pane_id| {
                const pane = self.paneById(pane_id) orelse return null;
                return if (pane.minimized) null else pane_id;
            },
            .split => |split| {
                if (prefer_second) {
                    return self.edgeVisiblePaneId(split.second, true) orelse self.edgeVisiblePaneId(split.first, true);
                }
                return self.edgeVisiblePaneId(split.first, false) orelse self.edgeVisiblePaneId(split.second, false);
            },
        }
    }

    fn persistedWorkspaceJson(self: *const WorkspaceLayout, allocator: std.mem.Allocator) ![]u8 {
        var writer: std.Io.Writer.Allocating = .init(allocator);
        errdefer writer.deinit();
        var stringify: std.json.Stringify = .{ .writer = &writer.writer, .options = .{} };

        try stringify.beginObject();
        try stringify.objectField("v");
        try stringify.write(2);
        try stringify.objectField("next");
        try stringify.write(self.next_pane_id);
        try stringify.objectField("focused");
        if (self.focused_pane_id) |pane_id| {
            try stringify.write(pane_id);
        } else {
            try stringify.write(null);
        }
        try stringify.objectField("maximized");
        if (self.maximized_pane_id) |pane_id| {
            try stringify.write(pane_id);
        } else {
            try stringify.write(null);
        }

        try stringify.objectField("panes");
        try stringify.beginArray();
        for (self.panes.items) |pane| {
            try stringify.beginObject();
            try stringify.objectField("id");
            try stringify.write(pane.id);
            try stringify.objectField("minimized");
            try stringify.write(pane.minimized);
            switch (pane.ref) {
                .chat => |ref| {
                    try stringify.objectField("kind");
                    try stringify.write("chat");
                    try stringify.objectField("thread");
                    try stringify.write(ref.thread_index);
                },
                .terminal => |ref| {
                    try stringify.objectField("kind");
                    try stringify.write("terminal");
                    try stringify.objectField("dock");
                    try stringify.write(ref.dock_id);
                    if (ref.purpose != .normal) {
                        try stringify.objectField("purpose");
                        try stringify.write(@tagName(ref.purpose));
                    }
                },
                .browser => |ref| {
                    try stringify.objectField("kind");
                    try stringify.write("browser");
                    if (ref.url) |url| {
                        try stringify.objectField("url");
                        try stringify.write(url);
                    }
                    if (ref.title) |title| {
                        try stringify.objectField("title");
                        try stringify.write(title);
                    }
                    try stringify.objectField("history_index");
                    if (ref.history_index) |history_index| {
                        try stringify.write(history_index);
                    } else {
                        try stringify.write(null);
                    }
                    try stringify.objectField("history");
                    try stringify.beginArray();
                    for (ref.history.items) |entry| {
                        try stringify.write(entry);
                    }
                    try stringify.endArray();
                },
            }
            try stringify.endObject();
        }
        try stringify.endArray();

        try stringify.objectField("root");
        if (self.root) |root_node| {
            try writeWorkspaceNodeJson(&stringify, root_node);
        } else {
            try stringify.write(null);
        }
        try stringify.endObject();
        return try writer.toOwnedSlice();
    }

    fn applyPersistedWorkspaceJson(self: *WorkspaceLayout, allocator: std.mem.Allocator, json: []const u8) !void {
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
        defer parsed.deinit();
        const root_value = parsed.value;
        if (root_value != .object) return;
        const version = jsonInt(root_value.object.get("v") orelse .null) orelse 1;
        if (version < 2) {
            try self.applyLegacyPersistedWorkspaceJson(allocator, json);
            return;
        }

        const panes_value = root_value.object.get("panes") orelse return;
        if (panes_value != .array) return;

        var next_layout: WorkspaceLayout = .{};
        errdefer next_layout.deinit(allocator);
        next_layout.next_pane_id = @intCast(jsonInt(root_value.object.get("next") orelse .null) orelse 1);
        next_layout.focused_pane_id = if (jsonInt(root_value.object.get("focused") orelse .null)) |id| @intCast(id) else null;
        next_layout.maximized_pane_id = if (jsonInt(root_value.object.get("maximized") orelse .null)) |id| @intCast(id) else null;

        for (panes_value.array.items) |pane_value| {
            if (pane_value != .object) continue;
            const pane_id: WorkspacePaneId = @intCast(jsonInt(pane_value.object.get("id") orelse .null) orelse continue);
            const kind = jsonString(pane_value.object.get("kind") orelse .null) orelse continue;
            const minimized = jsonBool(pane_value.object.get("minimized") orelse .null) orelse false;
            if (std.mem.eql(u8, kind, "chat")) {
                const thread_index: usize = @intCast(jsonInt(pane_value.object.get("thread") orelse .null) orelse 0);
                try next_layout.panes.append(allocator, .{
                    .id = pane_id,
                    .ref = .{ .chat = .{ .thread_index = thread_index } },
                    .minimized = minimized,
                });
            } else if (std.mem.eql(u8, kind, "terminal")) {
                const dock_id: u32 = @intCast(jsonInt(pane_value.object.get("dock") orelse .null) orelse 0);
                const purpose_label = jsonString(pane_value.object.get("purpose") orelse .null) orelse "normal";
                const purpose: TerminalPanePurpose = if (std.mem.eql(u8, purpose_label, "editor")) .editor else .normal;
                try next_layout.panes.append(allocator, .{
                    .id = pane_id,
                    .ref = .{ .terminal = .{ .dock_id = dock_id, .purpose = purpose } },
                    .minimized = minimized,
                });
            } else if (std.mem.eql(u8, kind, "browser")) {
                var browser_ref: BrowserPaneRef = .{};
                var browser_ref_owned = true;
                errdefer if (browser_ref_owned) browser_ref.deinit(allocator);
                if (jsonString(pane_value.object.get("url") orelse .null)) |url| {
                    try browser_ref.setUrl(allocator, url);
                }
                if (jsonString(pane_value.object.get("title") orelse .null)) |title| {
                    try browser_ref.setTitle(allocator, title);
                }
                if (pane_value.object.get("history")) |history_value| {
                    if (history_value == .array) {
                        for (history_value.array.items) |entry_value| {
                            const entry = jsonString(entry_value) orelse continue;
                            try browser_ref.appendHistoryEntry(allocator, entry);
                        }
                    }
                }
                if (jsonInt(pane_value.object.get("history_index") orelse .null)) |history_index| {
                    if (history_index >= 0 and @as(usize, @intCast(history_index)) < browser_ref.history.items.len) {
                        browser_ref.history_index = @intCast(history_index);
                    }
                } else if (browser_ref.url != null and browser_ref.history.items.len == 0) {
                    try browser_ref.appendHistoryEntry(allocator, browser_ref.url.?);
                    browser_ref.history_index = 0;
                }
                if (browser_ref.url == null and browser_ref.history.items.len > 0) {
                    const restore_index = browser_ref.history_index orelse browser_ref.history.items.len - 1;
                    try browser_ref.setUrl(allocator, browser_ref.history.items[restore_index]);
                    browser_ref.history_index = restore_index;
                }
                try next_layout.panes.append(allocator, .{
                    .id = pane_id,
                    .ref = .{ .browser = browser_ref },
                    .minimized = minimized,
                });
                browser_ref_owned = false;
            }
            if (pane_id >= next_layout.next_pane_id) next_layout.next_pane_id = pane_id + 1;
        }

        if (root_value.object.get("root")) |node_value| {
            next_layout.root = try parseWorkspaceNodeJson(allocator, node_value);
        }
        if (next_layout.root == null) {
            if (next_layout.firstVisiblePaneId()) |pane_id| {
                next_layout.root = try createLeafNode(allocator, pane_id);
            }
        }
        if (next_layout.panes.items.len == 0 or next_layout.root == null) return;
        if (next_layout.focused_pane_id) |pane_id| {
            const pane = next_layout.paneById(pane_id);
            if (pane == null or pane.?.minimized) next_layout.focused_pane_id = next_layout.firstVisiblePaneId();
        } else {
            next_layout.focused_pane_id = next_layout.firstVisiblePaneId();
        }
        if (next_layout.maximized_pane_id) |pane_id| {
            const pane = next_layout.paneById(pane_id);
            if (pane == null or pane.?.minimized) next_layout.maximized_pane_id = null;
        }

        self.deinit(allocator);
        self.* = next_layout;
    }

    fn applyLegacyPersistedWorkspaceJson(self: *WorkspaceLayout, allocator: std.mem.Allocator, json: []const u8) !void {
        _ = try self.ensureDefaultChat(allocator);
        if (std.mem.indexOf(u8, json, "\"terminal_visible\":true") != null) {
            _ = try self.ensureTerminalPane(allocator, 0);
        }
        if (std.mem.indexOf(u8, json, "\"focused\":\"chat\"") != null) {
            self.focusFirstVisiblePaneKind(.chat);
        } else if (std.mem.indexOf(u8, json, "\"focused\":\"terminal\"") != null) {
            self.focusFirstVisiblePaneKind(.terminal);
        }
    }

    fn focusFirstVisiblePaneKind(self: *WorkspaceLayout, kind: WorkspacePaneKind) void {
        for (self.panes.items) |pane| {
            if (pane.minimized) continue;
            switch (pane.ref) {
                .chat => if (kind == .chat) {
                    self.focused_pane_id = pane.id;
                    return;
                },
                .terminal => if (kind == .terminal) {
                    self.focused_pane_id = pane.id;
                    return;
                },
                .browser => if (kind == .browser) {
                    self.focused_pane_id = pane.id;
                    return;
                },
            }
        }
    }

    fn ensurePaneInRootSplit(self: *WorkspaceLayout, allocator: std.mem.Allocator, pane_id: WorkspacePaneId, axis: WorkspaceSplitAxis, ratio: f32) !void {
        if (self.root) |root_node| {
            if (nodeContainsPane(root_node, pane_id)) return;
            const new_leaf = try createLeafNode(allocator, pane_id);
            errdefer destroyNode(allocator, new_leaf);
            const split = try allocator.create(WorkspaceNode);
            split.* = .{ .split = .{
                .axis = axis,
                .ratio = ratio,
                .first = root_node,
                .second = new_leaf,
            } };
            self.root = split;
            return;
        }

        self.root = try createLeafNode(allocator, pane_id);
    }

    fn createLeafNode(allocator: std.mem.Allocator, pane_id: WorkspacePaneId) !*WorkspaceNode {
        const node = try allocator.create(WorkspaceNode);
        node.* = .{ .leaf = pane_id };
        return node;
    }

    fn destroyNode(allocator: std.mem.Allocator, node: *WorkspaceNode) void {
        switch (node.*) {
            .leaf => {},
            .split => |split| {
                destroyNode(allocator, split.first);
                destroyNode(allocator, split.second);
            },
        }
        allocator.destroy(node);
    }

    fn nodeContainsPane(node: *const WorkspaceNode, pane_id: WorkspacePaneId) bool {
        return switch (node.*) {
            .leaf => |leaf_id| leaf_id == pane_id,
            .split => |split| nodeContainsPane(split.first, pane_id) or nodeContainsPane(split.second, pane_id),
        };
    }

    const PruneRootResult = struct {
        node: ?*WorkspaceNode,
        changed: bool,
    };

    fn pruneRootToVisiblePanes(allocator: std.mem.Allocator, layout: *const WorkspaceLayout, node: *WorkspaceNode) PruneRootResult {
        switch (node.*) {
            .leaf => |pane_id| {
                if (layout.paneIdVisible(pane_id)) return .{ .node = node, .changed = false };
                allocator.destroy(node);
                return .{ .node = null, .changed = true };
            },
            .split => |split| {
                const axis = split.axis;
                const ratio = split.ratio;
                const first = pruneRootToVisiblePanes(allocator, layout, split.first);
                const second = pruneRootToVisiblePanes(allocator, layout, split.second);
                const child_changed = first.changed or second.changed;
                if (first.node) |first_node| {
                    if (second.node) |second_node| {
                        node.* = .{ .split = .{
                            .axis = axis,
                            .ratio = ratio,
                            .first = first_node,
                            .second = second_node,
                        } };
                        return .{ .node = node, .changed = child_changed };
                    }
                    allocator.destroy(node);
                    return .{ .node = first_node, .changed = true };
                }
                if (second.node) |second_node| {
                    allocator.destroy(node);
                    return .{ .node = second_node, .changed = true };
                }
                allocator.destroy(node);
                return .{ .node = null, .changed = true };
            },
        }
    }

    fn resizeNodeSplit(node: *WorkspaceNode, first_pane_id: WorkspacePaneId, second_pane_id: WorkspacePaneId, axis: WorkspaceSplitAxis, ratio: f32) bool {
        switch (node.*) {
            .leaf => return false,
            .split => |*split| {
                if (split.axis == axis and
                    nodeContainsPane(split.first, first_pane_id) and
                    nodeContainsPane(split.second, second_pane_id))
                {
                    split.ratio = ratio;
                    return true;
                }
                if (resizeNodeSplit(split.first, first_pane_id, second_pane_id, axis, ratio)) return true;
                return resizeNodeSplit(split.second, first_pane_id, second_pane_id, axis, ratio);
            },
        }
    }

    fn nudgeNodeSplitRatio(node: *WorkspaceNode, first_pane_id: WorkspacePaneId, second_pane_id: WorkspacePaneId, axis: WorkspaceSplitAxis, delta: f32) bool {
        switch (node.*) {
            .leaf => return false,
            .split => |*split| {
                if (split.axis == axis and
                    nodeContainsPane(split.first, first_pane_id) and
                    nodeContainsPane(split.second, second_pane_id))
                {
                    split.ratio = @max(0.18, @min(0.82, split.ratio + delta));
                    return true;
                }
                if (nudgeNodeSplitRatio(split.first, first_pane_id, second_pane_id, axis, delta)) return true;
                return nudgeNodeSplitRatio(split.second, first_pane_id, second_pane_id, axis, delta);
            },
        }
    }

    fn removePaneFromTree(allocator: std.mem.Allocator, node: *WorkspaceNode, pane_id: WorkspacePaneId) ?*WorkspaceNode {
        switch (node.*) {
            .leaf => |leaf_id| {
                if (leaf_id != pane_id) return node;
                allocator.destroy(node);
                return null;
            },
            .split => |split| {
                const first = removePaneFromTree(allocator, split.first, pane_id);
                const second = removePaneFromTree(allocator, split.second, pane_id);
                if (first) |first_node| {
                    if (second) |second_node| {
                        node.* = .{ .split = .{
                            .axis = split.axis,
                            .ratio = split.ratio,
                            .first = first_node,
                            .second = second_node,
                        } };
                        return node;
                    }
                    allocator.destroy(node);
                    return first_node;
                }
                if (second) |second_node| {
                    allocator.destroy(node);
                    return second_node;
                }
                allocator.destroy(node);
                return null;
            },
        }
    }

    fn splitNodeWithLeaf(
        allocator: std.mem.Allocator,
        node: *WorkspaceNode,
        target_pane_id: WorkspacePaneId,
        new_pane_id: WorkspacePaneId,
        axis: WorkspaceSplitAxis,
        new_after: bool,
    ) !bool {
        switch (node.*) {
            .leaf => |leaf_id| {
                if (leaf_id != target_pane_id) return false;
                const old_leaf = try createLeafNode(allocator, leaf_id);
                errdefer destroyNode(allocator, old_leaf);
                const new_leaf = try createLeafNode(allocator, new_pane_id);
                errdefer destroyNode(allocator, new_leaf);
                node.* = .{ .split = .{
                    .axis = axis,
                    .ratio = 0.5,
                    .first = if (new_after) old_leaf else new_leaf,
                    .second = if (new_after) new_leaf else old_leaf,
                } };
                return true;
            },
            .split => |split| {
                if (try splitNodeWithLeaf(allocator, split.first, target_pane_id, new_pane_id, axis, new_after)) return true;
                return try splitNodeWithLeaf(allocator, split.second, target_pane_id, new_pane_id, axis, new_after);
            },
        }
    }

    fn writeWorkspaceNodeJson(stringify: *std.json.Stringify, node: *const WorkspaceNode) !void {
        try stringify.beginObject();
        switch (node.*) {
            .leaf => |pane_id| {
                try stringify.objectField("leaf");
                try stringify.write(pane_id);
            },
            .split => |split| {
                try stringify.objectField("split");
                try stringify.beginObject();
                try stringify.objectField("axis");
                try stringify.write(switch (split.axis) {
                    .horizontal => "horizontal",
                    .vertical => "vertical",
                });
                try stringify.objectField("ratio");
                try stringify.write(split.ratio);
                try stringify.objectField("first");
                try writeWorkspaceNodeJson(stringify, split.first);
                try stringify.objectField("second");
                try writeWorkspaceNodeJson(stringify, split.second);
                try stringify.endObject();
            },
        }
        try stringify.endObject();
    }

    fn parseWorkspaceNodeJson(allocator: std.mem.Allocator, value: std.json.Value) !?*WorkspaceNode {
        if (value != .object) return null;
        if (value.object.get("leaf")) |leaf_value| {
            const pane_id: WorkspacePaneId = @intCast(jsonInt(leaf_value) orelse return null);
            return try createLeafNode(allocator, pane_id);
        }
        const split_value = value.object.get("split") orelse return null;
        if (split_value != .object) return null;
        const first_value = split_value.object.get("first") orelse return null;
        const second_value = split_value.object.get("second") orelse return null;
        const first_node = (try parseWorkspaceNodeJson(allocator, first_value)) orelse return null;
        errdefer destroyNode(allocator, first_node);
        const second_node = (try parseWorkspaceNodeJson(allocator, second_value)) orelse return null;
        errdefer destroyNode(allocator, second_node);
        const axis_label = jsonString(split_value.object.get("axis") orelse .null) orelse "horizontal";
        const node = try allocator.create(WorkspaceNode);
        node.* = .{ .split = .{
            .axis = if (std.mem.eql(u8, axis_label, "vertical")) .vertical else .horizontal,
            .ratio = jsonFloat(split_value.object.get("ratio") orelse .null) orelse 0.5,
            .first = first_node,
            .second = second_node,
        } };
        return node;
    }

    fn jsonString(value: std.json.Value) ?[]const u8 {
        return switch (value) {
            .string => |s| s,
            else => null,
        };
    }

    fn jsonBool(value: std.json.Value) ?bool {
        return switch (value) {
            .bool => |b| b,
            else => null,
        };
    }

    fn jsonInt(value: std.json.Value) ?i64 {
        return switch (value) {
            .integer => |i| i,
            .float => |f| @intFromFloat(f),
            else => null,
        };
    }

    fn jsonFloat(value: std.json.Value) ?f32 {
        return switch (value) {
            .integer => |i| @floatFromInt(i),
            .float => |f| @floatCast(f),
            else => null,
        };
    }
};

pub const HerdrPanePresentation = enum(u8) {
    gui_chat,
    tui_agent,
    terminal,
    browser_link,
    unknown,
};

pub const HerdrPaneProvider = enum(u8) {
    codex,
    claude,
    opencode,
    cursor,
    terminal,
    browser,
    unknown,
};

const ProviderExecutionTarget = union(enum) {
    local: []const u8,
    remote_ssh: struct {
        host: []const u8,
        cwd: []const u8,
    },

    fn cwd(self: ProviderExecutionTarget) []const u8 {
        return switch (self) {
            .local => |path| path,
            .remote_ssh => |remote| remote.cwd,
        };
    }

    fn remoteHost(self: ProviderExecutionTarget) ?[]const u8 {
        return switch (self) {
            .local => null,
            .remote_ssh => |remote| remote.host,
        };
    }
};

pub const HerdrPaneLink = struct {
    verde_pane_id: WorkspacePaneId = 0,
    herdr_tab_id: ?[]u8 = null,
    herdr_pane_id: ?[]u8 = null,
    provider: HerdrPaneProvider = .unknown,
    presentation: HerdrPanePresentation = .unknown,
    provider_thread_id: ?[]u8 = null,
    provider_session_ref: ?[]u8 = null,
    cwd: ?[]u8 = null,
    title: ?[]u8 = null,
    updated_at_ms: i64 = 0,

    fn init(
        allocator: std.mem.Allocator,
        verde_pane_id: WorkspacePaneId,
        herdr_tab_id: ?[]const u8,
        herdr_pane_id: ?[]const u8,
        provider: HerdrPaneProvider,
        presentation: HerdrPanePresentation,
        provider_thread_id: ?[]const u8,
        provider_session_ref: ?[]const u8,
        cwd: ?[]const u8,
        title: ?[]const u8,
    ) !HerdrPaneLink {
        return .{
            .verde_pane_id = verde_pane_id,
            .herdr_tab_id = if (herdr_tab_id) |value| try allocator.dupe(u8, value) else null,
            .herdr_pane_id = if (herdr_pane_id) |value| try allocator.dupe(u8, value) else null,
            .provider = provider,
            .presentation = presentation,
            .provider_thread_id = if (provider_thread_id) |value| try allocator.dupe(u8, value) else null,
            .provider_session_ref = if (provider_session_ref) |value| try allocator.dupe(u8, value) else null,
            .cwd = if (cwd) |value| try allocator.dupe(u8, value) else null,
            .title = if (title) |value| try allocator.dupe(u8, value) else null,
            .updated_at_ms = unixTimestampMs(),
        };
    }

    fn deinit(self: *HerdrPaneLink, allocator: std.mem.Allocator) void {
        if (self.herdr_tab_id) |value| allocator.free(value);
        if (self.herdr_pane_id) |value| allocator.free(value);
        if (self.provider_thread_id) |value| allocator.free(value);
        if (self.provider_session_ref) |value| allocator.free(value);
        if (self.cwd) |value| allocator.free(value);
        if (self.title) |value| allocator.free(value);
        self.* = undefined;
    }
};

pub const HerdrWorkspaceLink = struct {
    remote_alias: []u8,
    session_name: []u8,
    workspace_id: []u8,
    local_dir: []u8,
    remote_cwd: ?[]u8 = null,
    last_pane_id: ?[]u8 = null,
    attach_dock_id: ?u32 = null,
    attach_pane_id: ?WorkspacePaneId = null,
    pane_links: std.ArrayList(HerdrPaneLink) = .empty,
    updated_at_ms: i64 = 0,

    fn init(
        allocator: std.mem.Allocator,
        remote_alias: []const u8,
        session_name: []const u8,
        workspace_id: []const u8,
        local_dir: []const u8,
        remote_cwd: ?[]const u8,
        last_pane_id: ?[]const u8,
        attach_dock_id: ?u32,
        attach_pane_id: ?WorkspacePaneId,
    ) !HerdrWorkspaceLink {
        const remote_copy = try allocator.dupe(u8, remote_alias);
        errdefer allocator.free(remote_copy);
        const session_copy = try allocator.dupe(u8, session_name);
        errdefer allocator.free(session_copy);
        const workspace_copy = try allocator.dupe(u8, workspace_id);
        errdefer allocator.free(workspace_copy);
        const local_dir_copy = try allocator.dupe(u8, local_dir);
        errdefer allocator.free(local_dir_copy);
        var remote_cwd_copy: ?[]u8 = null;
        errdefer if (remote_cwd_copy) |value| allocator.free(value);
        remote_cwd_copy = if (remote_cwd) |value| try allocator.dupe(u8, value) else null;
        var last_pane_copy: ?[]u8 = null;
        errdefer if (last_pane_copy) |value| allocator.free(value);
        last_pane_copy = if (last_pane_id) |value| try allocator.dupe(u8, value) else null;
        return .{
            .remote_alias = remote_copy,
            .session_name = session_copy,
            .workspace_id = workspace_copy,
            .local_dir = local_dir_copy,
            .remote_cwd = remote_cwd_copy,
            .last_pane_id = last_pane_copy,
            .attach_dock_id = attach_dock_id,
            .attach_pane_id = attach_pane_id,
            .pane_links = .empty,
            .updated_at_ms = unixTimestampMs(),
        };
    }

    fn initFromPersisted(allocator: std.mem.Allocator, persisted: PersistedHerdrWorkspaceLink) !HerdrWorkspaceLink {
        var link = try init(
            allocator,
            persisted.remote_alias,
            persisted.session_name,
            persisted.workspace_id,
            persisted.local_dir,
            persisted.remote_cwd,
            persisted.last_pane_id,
            persisted.attach_dock_id,
            persisted.attach_pane_id,
        );
        errdefer link.deinit(allocator);
        link.updated_at_ms = persisted.updated_at_ms;
        if (persisted.pane_links_json) |json| try link.applyPaneLinksJson(allocator, json);
        return link;
    }

    fn deinit(self: *HerdrWorkspaceLink, allocator: std.mem.Allocator) void {
        allocator.free(self.remote_alias);
        allocator.free(self.session_name);
        allocator.free(self.workspace_id);
        allocator.free(self.local_dir);
        if (self.remote_cwd) |value| allocator.free(value);
        if (self.last_pane_id) |value| allocator.free(value);
        for (self.pane_links.items) |*pane_link| pane_link.deinit(allocator);
        self.pane_links.deinit(allocator);
        self.* = undefined;
    }

    fn toPersisted(self: *const HerdrWorkspaceLink, allocator: std.mem.Allocator) !PersistedHerdrWorkspaceLink {
        return .{
            .remote_alias = try allocator.dupe(u8, self.remote_alias),
            .session_name = try allocator.dupe(u8, self.session_name),
            .workspace_id = try allocator.dupe(u8, self.workspace_id),
            .local_dir = try allocator.dupe(u8, self.local_dir),
            .remote_cwd = if (self.remote_cwd) |value| try allocator.dupe(u8, value) else null,
            .last_pane_id = if (self.last_pane_id) |value| try allocator.dupe(u8, value) else null,
            .attach_dock_id = self.attach_dock_id,
            .attach_pane_id = self.attach_pane_id,
            .pane_links_json = try self.paneLinksJsonAlloc(allocator),
            .updated_at_ms = self.updated_at_ms,
        };
    }

    fn replacePaneLinks(self: *HerdrWorkspaceLink, allocator: std.mem.Allocator, next_links: *std.ArrayList(HerdrPaneLink)) void {
        for (self.pane_links.items) |*pane_link| pane_link.deinit(allocator);
        self.pane_links.deinit(allocator);
        self.pane_links = next_links.*;
        next_links.* = .empty;
        self.updated_at_ms = unixTimestampMs();
    }

    fn paneLinkForVerdePane(self: *const HerdrWorkspaceLink, pane_id: WorkspacePaneId) ?HerdrPaneLink {
        for (self.pane_links.items) |pane_link| {
            if (pane_link.verde_pane_id == pane_id) return pane_link;
        }
        return null;
    }

    fn removePaneLinkForVerdePane(self: *HerdrWorkspaceLink, allocator: std.mem.Allocator, pane_id: WorkspacePaneId) bool {
        for (self.pane_links.items, 0..) |*pane_link, index| {
            if (pane_link.verde_pane_id != pane_id) continue;
            var removed = self.pane_links.orderedRemove(index);
            removed.deinit(allocator);
            self.updated_at_ms = unixTimestampMs();
            return true;
        }
        return false;
    }

    fn paneLinksJsonAlloc(self: *const HerdrWorkspaceLink, allocator: std.mem.Allocator) !?[]u8 {
        if (self.pane_links.items.len == 0) return null;
        var writer: std.Io.Writer.Allocating = .init(allocator);
        errdefer writer.deinit();
        var stringify: std.json.Stringify = .{ .writer = &writer.writer, .options = .{} };
        try stringify.beginArray();
        for (self.pane_links.items) |pane_link| {
            try stringify.beginObject();
            try stringify.objectField("verde_pane_id");
            try stringify.write(pane_link.verde_pane_id);
            try stringify.objectField("herdr_tab_id");
            if (pane_link.herdr_tab_id) |value| try stringify.write(value) else try stringify.write(null);
            try stringify.objectField("herdr_pane_id");
            if (pane_link.herdr_pane_id) |value| try stringify.write(value) else try stringify.write(null);
            try stringify.objectField("provider");
            try stringify.write(@tagName(pane_link.provider));
            try stringify.objectField("presentation");
            try stringify.write(@tagName(pane_link.presentation));
            try stringify.objectField("provider_thread_id");
            if (pane_link.provider_thread_id) |value| try stringify.write(value) else try stringify.write(null);
            try stringify.objectField("provider_session_ref");
            if (pane_link.provider_session_ref) |value| try stringify.write(value) else try stringify.write(null);
            try stringify.objectField("cwd");
            if (pane_link.cwd) |value| try stringify.write(value) else try stringify.write(null);
            try stringify.objectField("title");
            if (pane_link.title) |value| try stringify.write(value) else try stringify.write(null);
            try stringify.objectField("updated_at_ms");
            try stringify.write(pane_link.updated_at_ms);
            try stringify.endObject();
        }
        try stringify.endArray();
        return try writer.toOwnedSlice();
    }

    fn applyPaneLinksJson(self: *HerdrWorkspaceLink, allocator: std.mem.Allocator, json: []const u8) !void {
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
        defer parsed.deinit();
        if (parsed.value != .array) return;
        for (parsed.value.array.items) |entry| {
            if (entry != .object) continue;
            const pane_id: WorkspacePaneId = @intCast(herdrJsonInt(entry.object.get("verde_pane_id") orelse .null) orelse continue);
            var link = try HerdrPaneLink.init(
                allocator,
                pane_id,
                herdrJsonString(entry.object.get("herdr_tab_id") orelse .null),
                herdrJsonString(entry.object.get("herdr_pane_id") orelse .null),
                herdrPaneProviderFromLabel(herdrJsonString(entry.object.get("provider") orelse .null) orelse "unknown"),
                herdrPanePresentationFromLabel(herdrJsonString(entry.object.get("presentation") orelse .null) orelse "unknown"),
                herdrJsonString(entry.object.get("provider_thread_id") orelse .null),
                herdrJsonString(entry.object.get("provider_session_ref") orelse .null),
                herdrJsonString(entry.object.get("cwd") orelse .null),
                herdrJsonString(entry.object.get("title") orelse .null),
            );
            link.updated_at_ms = herdrJsonInt(entry.object.get("updated_at_ms") orelse .null) orelse link.updated_at_ms;
            errdefer link.deinit(allocator);
            try self.pane_links.append(allocator, link);
        }
    }
};

fn herdrJsonString(value: std.json.Value) ?[]const u8 {
    return switch (value) {
        .string => |s| s,
        else => null,
    };
}

fn herdrJsonInt(value: std.json.Value) ?i64 {
    return switch (value) {
        .integer => |i| i,
        .float => |f| @intFromFloat(f),
        else => null,
    };
}

fn herdrPaneProviderFromLabel(label: []const u8) HerdrPaneProvider {
    if (std.mem.eql(u8, label, "codex")) return .codex;
    if (std.mem.eql(u8, label, "claude")) return .claude;
    if (std.mem.eql(u8, label, "opencode")) return .opencode;
    if (std.mem.eql(u8, label, "cursor")) return .cursor;
    if (std.mem.eql(u8, label, "terminal")) return .terminal;
    if (std.mem.eql(u8, label, "browser")) return .browser;
    return .unknown;
}

fn herdrPanePresentationFromLabel(label: []const u8) HerdrPanePresentation {
    if (std.mem.eql(u8, label, "gui_chat")) return .gui_chat;
    if (std.mem.eql(u8, label, "tui_agent")) return .tui_agent;
    if (std.mem.eql(u8, label, "terminal")) return .terminal;
    if (std.mem.eql(u8, label, "browser_link")) return .browser_link;
    return .unknown;
}

fn herdrPaneProviderForThreadProvider(provider: Provider) HerdrPaneProvider {
    return switch (provider) {
        .codex => .codex,
        .claude => .claude,
        .opencode => .opencode,
        .cursor => .cursor,
    };
}

fn herdrAgentCommandForProvider(allocator: std.mem.Allocator, provider: HerdrPaneProvider, thread_id: ?[]const u8) !?[]u8 {
    if (thread_id) |id| {
        return switch (provider) {
            .codex => try std.fmt.allocPrint(allocator, "codex resume {s}", .{id}),
            .claude => try std.fmt.allocPrint(allocator, "claude --resume {s}", .{id}),
            .opencode => if (std.mem.startsWith(u8, id, "ses"))
                try std.fmt.allocPrint(allocator, "{s} --session {s}", .{ OPENCODE_TUI_COMMAND, id })
            else
                try allocator.dupe(u8, OPENCODE_TUI_COMMAND),
            .cursor => try std.fmt.allocPrint(allocator, "agent --resume {s}", .{id}),
            .terminal, .browser, .unknown => null,
        };
    }

    const command: ?[]const u8 = switch (provider) {
        .codex => "codex",
        .claude => "claude",
        .opencode => OPENCODE_TUI_COMMAND,
        .cursor => "agent",
        .terminal, .browser, .unknown => null,
    };
    return if (command) |value| try allocator.dupe(u8, value) else null;
}

fn parseHerdrJsonStringAlloc(allocator: std.mem.Allocator, json: []const u8, key: []const u8) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();
    const value = herdr.findJsonString(parsed.value, key) orelse return error.InvalidHerdrResponse;
    return try allocator.dupe(u8, value);
}

pub const HerdrOpenResult = struct {
    workspace_index: usize,
    workspace_id: []const u8,
    workspace_path: []const u8,
    created: bool,
    restored: bool,
    remote: []const u8,
    session: []const u8,
    herdr_workspace: []const u8,
    herdr_pane: ?[]const u8,
    terminal_dock_id: ?u32,
    terminal_pane_id: ?WorkspacePaneId,
};

pub const HerdrHandoffWorkspaceResult = struct {
    workspace_index: usize,
    workspace_id: []const u8,
    label: []const u8,
    path: []const u8,
    remote: []const u8,
    session: []const u8,
    herdr_workspace: []const u8,
    herdr_tab: ?[]const u8,
    created: bool,
    pane_count: usize,
};

pub const HerdrHandoffResult = struct {
    dry_run: bool,
    workspace_count: usize,
    workspaces: []HerdrHandoffWorkspaceResult,

    pub fn deinit(self: HerdrHandoffResult, allocator: std.mem.Allocator) void {
        if (self.workspaces.len > 0) allocator.free(self.workspaces);
    }
};

pub const HerdrUnlinkPreviousLink = struct {
    remote: []const u8,
    session: []const u8,
    herdr_workspace: []const u8,
    remote_cwd: ?[]const u8 = null,
    herdr_pane: ?[]const u8 = null,
    terminal_dock_id: ?u32 = null,
    terminal_pane_id: ?WorkspacePaneId = null,
    pane_links_len: usize = 0,
    updated_at_ms: i64 = 0,

    fn init(allocator: std.mem.Allocator, link: HerdrWorkspaceLink) !HerdrUnlinkPreviousLink {
        const remote = try allocator.dupe(u8, link.remote_alias);
        errdefer allocator.free(remote);
        const session = try allocator.dupe(u8, link.session_name);
        errdefer allocator.free(session);
        const workspace = try allocator.dupe(u8, link.workspace_id);
        errdefer allocator.free(workspace);
        const remote_cwd = if (link.remote_cwd) |value| try allocator.dupe(u8, value) else null;
        errdefer if (remote_cwd) |value| allocator.free(value);
        const herdr_pane = if (link.last_pane_id) |value| try allocator.dupe(u8, value) else null;
        errdefer if (herdr_pane) |value| allocator.free(value);
        return .{
            .remote = remote,
            .session = session,
            .herdr_workspace = workspace,
            .remote_cwd = remote_cwd,
            .herdr_pane = herdr_pane,
            .terminal_dock_id = link.attach_dock_id,
            .terminal_pane_id = link.attach_pane_id,
            .pane_links_len = link.pane_links.items.len,
            .updated_at_ms = link.updated_at_ms,
        };
    }

    fn deinit(self: HerdrUnlinkPreviousLink, allocator: std.mem.Allocator) void {
        allocator.free(self.remote);
        allocator.free(self.session);
        allocator.free(self.herdr_workspace);
        if (self.remote_cwd) |value| allocator.free(value);
        if (self.herdr_pane) |value| allocator.free(value);
    }
};

pub const HerdrUnlinkWorkspaceResult = struct {
    workspace_index: usize,
    workspace_id: []const u8,
    label: []const u8,
    path: []const u8,
    unlinked: bool,
    previous: ?HerdrUnlinkPreviousLink = null,

    fn deinit(self: HerdrUnlinkWorkspaceResult, allocator: std.mem.Allocator) void {
        if (self.previous) |previous| previous.deinit(allocator);
    }
};

pub const HerdrUnlinkResult = struct {
    workspace_count: usize,
    workspaces: []HerdrUnlinkWorkspaceResult,

    pub fn deinit(self: HerdrUnlinkResult, allocator: std.mem.Allocator) void {
        for (self.workspaces) |workspace| workspace.deinit(allocator);
        if (self.workspaces.len > 0) allocator.free(self.workspaces);
    }
};

pub const Project = struct {
    id: [:0]const u8,
    label: [:0]const u8,
    path: [:0]const u8,
    herdr_link: ?HerdrWorkspaceLink = null,
    archived: bool = false,
    unread_count: u8 = 0,
    collapsed: bool = false,
    thread_list_expanded: bool = false,
    terminal_dock: terminal.Dock,
    terminal_docks: std.ArrayList(TerminalDockEntry) = .empty,
    managed_processes: std.ArrayList(ManagedProcess) = .empty,
    last_stack_config_refresh_ms: i64 = 0,
    stack_config_error: ?[]u8 = null,
    next_terminal_dock_id: u32 = 1,
    workspace_layout: WorkspaceLayout,
    threads: std.ArrayList(ChatThread),
    archived_threads: std.ArrayList(ChatThread),
    selected_thread_index: usize = 0,
    sidebar_thread_indices: std.ArrayList(usize) = .empty,
    sidebar_committed_thread_count: usize = 0,
    sidebar_thread_cache_dirty: bool = true,

    fn init(allocator: std.mem.Allocator, id: []const u8, label: []const u8, path: []const u8, unread_count: u8) !Project {
        var terminal_dock = try terminal.Dock.init(allocator);
        terminal_dock.setDefaultFontSize(app_config.DEFAULT_TERMINAL_FONT_SIZE);
        errdefer terminal_dock.deinit(allocator);
        var project: Project = .{
            .id = try allocator.dupeZ(u8, id),
            .label = try allocator.dupeZ(u8, label),
            .path = try allocator.dupeZ(u8, path),
            .herdr_link = null,
            .archived = false,
            .unread_count = unread_count,
            .collapsed = false,
            .thread_list_expanded = false,
            .terminal_dock = terminal_dock,
            .terminal_docks = .empty,
            .managed_processes = .empty,
            .last_stack_config_refresh_ms = 0,
            .stack_config_error = null,
            .next_terminal_dock_id = 1,
            .workspace_layout = try WorkspaceLayout.initDefaultChat(allocator),
            .threads = .empty,
            .archived_threads = .empty,
            .selected_thread_index = 0,
            .sidebar_thread_indices = .empty,
            .sidebar_committed_thread_count = 0,
            .sidebar_thread_cache_dirty = true,
        };
        _ = try project.addThread(allocator);
        return project;
    }

    fn currentThreadIndex(self: *const Project) usize {
        std.debug.assert(self.threads.items.len > 0);
        return @min(self.selected_thread_index, self.threads.items.len - 1);
    }

    pub fn currentThread(self: *const Project) *const ChatThread {
        return &self.threads.items[self.currentThreadIndex()];
    }

    pub fn currentThreadMutable(self: *Project) *ChatThread {
        std.debug.assert(self.threads.items.len > 0);
        if (self.selected_thread_index >= self.threads.items.len) {
            self.selected_thread_index = self.threads.items.len - 1;
        }
        return &self.threads.items[self.selected_thread_index];
    }

    pub fn invalidateSidebarThreadCache(self: *Project) void {
        self.sidebar_thread_cache_dirty = true;
    }

    pub fn committedThreadCountCached(self: *Project, allocator: std.mem.Allocator) usize {
        self.ensureSidebarThreadCache(allocator);
        return self.sidebar_committed_thread_count;
    }

    pub fn sortedCommittedThreadIndices(self: *Project, allocator: std.mem.Allocator) []const usize {
        self.ensureSidebarThreadCache(allocator);
        return self.sidebar_thread_indices.items;
    }

    fn currentDraft(self: *const Project) []const u8 {
        return self.currentThread().currentDraft();
    }

    fn draftBuffer(self: *Project) [:0]u8 {
        return self.currentThreadMutable().draftBuffer();
    }

    fn setDraft(self: *Project, value: []const u8) void {
        self.currentThreadMutable().setDraft(value);
    }

    fn clearDraft(self: *Project) void {
        self.currentThreadMutable().clearDraft();
    }

    fn addThread(self: *Project, allocator: std.mem.Allocator) !usize {
        var thread = try ChatThread.init(allocator, "New thread");
        errdefer thread.deinit(allocator);
        try self.threads.append(allocator, thread);
        self.selected_thread_index = self.threads.items.len - 1;
        return self.selected_thread_index;
    }

    fn normalize(self: *Project, allocator: std.mem.Allocator, default_terminal_font_size: f32) !void {
        if (!self.archived and self.threads.items.len == 0) {
            _ = try self.addThread(allocator);
        }
        if (self.threads.items.len == 0) {
            self.selected_thread_index = 0;
        } else if (self.selected_thread_index >= self.threads.items.len) {
            self.selected_thread_index = self.threads.items.len - 1;
        }
        for (self.threads.items) |*thread| {
            chat_threads.sanitizeEnum(Provider, &thread.provider, .opencode);
            chat_threads.sanitizeEnum(Harness, &thread.harness, .local_cli);
            for (thread.messages.items) |*message| {
                chat_threads.sanitizeEnum(ChatRole, &message.role, .user);
            }
        }
        for (self.archived_threads.items) |*thread| {
            chat_threads.sanitizeEnum(Provider, &thread.provider, .opencode);
            chat_threads.sanitizeEnum(Harness, &thread.harness, .local_cli);
            for (thread.messages.items) |*message| {
                chat_threads.sanitizeEnum(ChatRole, &message.role, .user);
            }
        }
        if (self.threads.items.len > 0) {
            const fallback_thread_index = @min(self.selected_thread_index, self.threads.items.len - 1);
            for (self.workspace_layout.panes.items) |*pane| {
                switch (pane.ref) {
                    .chat => |*ref| {
                        if (ref.thread_index >= self.threads.items.len) ref.thread_index = fallback_thread_index;
                    },
                    else => {},
                }
            }
        }
        try self.ensureTerminalDocksForWorkspace(allocator, default_terminal_font_size);
    }

    fn ensureTerminalDocksForWorkspace(self: *Project, allocator: std.mem.Allocator, default_terminal_font_size: f32) !void {
        const max_dock_id = self.workspace_layout.maxTerminalDockId();
        var dock_id: u32 = 1;
        while (dock_id <= max_dock_id) : (dock_id += 1) {
            if (self.terminalDockEntryById(dock_id) != null) continue;
            var dock = try terminal.Dock.init(allocator);
            dock.setDefaultFontSize(default_terminal_font_size);
            errdefer dock.deinit(allocator);
            try self.terminal_docks.append(allocator, .{ .id = dock_id, .dock = dock });
        }
        if (self.next_terminal_dock_id <= max_dock_id) self.next_terminal_dock_id = max_dock_id + 1;
    }

    fn applyDefaultTerminalFontSize(self: *Project, font_size: f32) void {
        self.terminal_dock.setDefaultFontSize(font_size);
        for (self.terminal_docks.items) |*entry| {
            entry.dock.setDefaultFontSize(font_size);
        }
    }

    fn terminalDockEntryById(self: *Project, dock_id: u32) ?*TerminalDockEntry {
        for (self.terminal_docks.items) |*entry| {
            if (entry.id == dock_id) return entry;
        }
        return null;
    }

    pub fn managedProcessByName(self: *Project, name: []const u8) ?*ManagedProcess {
        for (self.managed_processes.items) |*process| {
            if (std.mem.eql(u8, process.name, name)) return process;
        }
        return null;
    }

    fn clearManagedProcesses(self: *Project, allocator: std.mem.Allocator) void {
        for (self.managed_processes.items) |*process| {
            self.terminateManagedProcessSession(process);
            process.deinit(allocator);
        }
        self.managed_processes.clearRetainingCapacity();
    }

    fn terminateManagedProcessSession(self: *Project, process: *ManagedProcess) void {
        const dock_id = process.dock_id orelse return;
        const entry = self.terminalDockEntryById(dock_id) orelse return;
        _ = entry.dock.terminateActiveSession();
        process.status = .stopped;
        process.explicit_stop = true;
        process.next_restart_ms = 0;
        process.pending_watch_restart_ms = 0;
    }

    fn managedProcessByDockId(self: *Project, dock_id: u32) ?*ManagedProcess {
        for (self.managed_processes.items) |*process| {
            if (process.dock_id != null and process.dock_id.? == dock_id) return process;
        }
        return null;
    }

    fn removeTerminalDockById(self: *Project, allocator: std.mem.Allocator, dock_id: u32) bool {
        for (self.terminal_docks.items, 0..) |*entry, index| {
            if (entry.id != dock_id) continue;
            entry.deinit(allocator);
            _ = self.terminal_docks.orderedRemove(index);
            return true;
        }
        return false;
    }

    pub fn committedThreadCount(self: *const Project) usize {
        var count: usize = 0;
        for (self.threads.items) |thread| {
            if (thread.committed) count += 1;
        }
        return count;
    }

    fn deinit(self: *Project, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.label);
        allocator.free(self.path);
        if (self.herdr_link) |*link| link.deinit(allocator);
        self.terminal_dock.deinit(allocator);
        for (self.terminal_docks.items) |*entry| entry.deinit(allocator);
        self.terminal_docks.deinit(allocator);
        for (self.managed_processes.items) |*process| process.deinit(allocator);
        self.managed_processes.deinit(allocator);
        if (self.stack_config_error) |message| allocator.free(message);
        self.workspace_layout.deinit(allocator);
        for (self.threads.items) |*thread| {
            thread.deinit(allocator);
        }
        self.threads.deinit(allocator);
        for (self.archived_threads.items) |*thread| {
            thread.deinit(allocator);
        }
        self.archived_threads.deinit(allocator);
        self.sidebar_thread_indices.deinit(allocator);
    }

    fn terminateWorkspaceSessions(self: *Project) void {
        self.terminal_dock.terminateAllSessions();
        for (self.terminal_docks.items) |*entry| entry.dock.terminateAllSessions();
        for (self.managed_processes.items) |*process| {
            process.status = .stopped;
            process.explicit_stop = true;
            process.next_restart_ms = 0;
            process.pending_watch_restart_ms = 0;
        }
    }

    fn ensureSidebarThreadCache(self: *Project, allocator: std.mem.Allocator) void {
        if (!self.sidebar_thread_cache_dirty) return;

        self.sidebar_thread_indices.clearRetainingCapacity();
        self.sidebar_committed_thread_count = 0;

        for (self.threads.items, 0..) |thread, index| {
            if (!thread.committed) continue;
            self.sidebar_committed_thread_count += 1;
            self.sidebar_thread_indices.append(allocator, index) catch {
                self.sidebar_thread_cache_dirty = true;
                return;
            };
        }

        var i: usize = 1;
        while (i < self.sidebar_thread_indices.items.len) : (i += 1) {
            const current = self.sidebar_thread_indices.items[i];
            var j = i;
            while (j > 0) : (j -= 1) {
                const left_index = self.sidebar_thread_indices.items[j - 1];
                const left = self.threads.items[left_index];
                const right = self.threads.items[current];
                const should_move = if (left.last_activity_at != right.last_activity_at)
                    left.last_activity_at < right.last_activity_at
                else
                    left_index < current;
                if (!should_move) break;
                self.sidebar_thread_indices.items[j] = self.sidebar_thread_indices.items[j - 1];
            }
            self.sidebar_thread_indices.items[j] = current;
        }

        self.sidebar_thread_cache_dirty = false;
    }

    fn setStackConfigError(self: *Project, allocator: std.mem.Allocator, message: []const u8) void {
        if (self.stack_config_error) |existing| allocator.free(existing);
        self.stack_config_error = allocator.dupe(u8, message) catch null;
    }

    fn clearStackConfigError(self: *Project, allocator: std.mem.Allocator) void {
        if (self.stack_config_error) |existing| allocator.free(existing);
        self.stack_config_error = null;
    }
};

pub const Storage = struct {
    allocator: std.mem.Allocator,
    pref_path: []const u8,
    client: db_client.Client,

    pub fn init(allocator: std.mem.Allocator) !Storage {
        const pref_path = sdl.getPrefPath(ORG_NAME, APP_NAME) orelse return error.SdlError;
        const owned_pref_path = try allocator.dupe(u8, pref_path);
        errdefer allocator.free(owned_pref_path);
        const client = try db_client.Client.init(allocator, owned_pref_path);
        errdefer {
            var owned_client = client;
            owned_client.deinit();
        }
        return .{
            .allocator = allocator,
            .pref_path = owned_pref_path,
            .client = client,
        };
    }

    pub fn deinit(self: *Storage) void {
        self.client.deinit();
        self.allocator.free(self.pref_path);
    }

    fn load(self: *const Storage, allocator: std.mem.Allocator) !?LoadedPersistedState {
        if (try self.client.load(allocator)) |loaded| {
            return loaded;
        }
        if (try self.loadLegacyJson(allocator)) |loaded| {
            errdefer {
                var owned_loaded = loaded;
                owned_loaded.deinit();
            }
            try self.client.save(loaded.value);
            return loaded;
        }
        return null;
    }

    fn loadLegacyJson(self: *const Storage, allocator: std.mem.Allocator) !?LoadedPersistedState {
        var threaded: std.Io.Threaded = .init(allocator, .{});
        defer threaded.deinit();
        var dir = try std.Io.Dir.openDirAbsolute(threaded.io(), self.pref_path, .{});
        defer dir.close(threaded.io());

        const bytes = dir.readFileAlloc(threaded.io(), LEGACY_STATE_FILE_NAME, allocator, .limited(1024 * 1024)) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        defer allocator.free(bytes);

        var loaded = LoadedPersistedState.init(allocator);
        errdefer loaded.deinit();
        loaded.value = try std.json.parseFromSliceLeaky(PersistedState, loaded.allocator(), bytes, .{
            .allocate = .alloc_always,
        });
        return loaded;
    }

    fn save(self: *const Storage, state: *const AppState) !void {
        var persisted = try state.buildPersistedState(self.allocator);
        defer persisted.deinit();
        try self.client.save(persisted.value);
    }
};

fn savePersistedStateWorker(pref_path: []u8, loaded_state: LoadedPersistedState) void {
    var loaded = loaded_state;
    defer loaded.deinit();
    defer std.heap.page_allocator.free(pref_path);

    var client = db_client.Client.init(std.heap.page_allocator, pref_path) catch |err| {
        log.err("failed to initialize async native state save: {s}", .{@errorName(err)});
        return;
    };
    defer client.deinit();

    client.save(loaded.value) catch |err| {
        log.err("failed to save native state: {s}", .{@errorName(err)});
    };
}

pub const SendStatus = enum {
    idle,
    pending,
    completed,
    aborted,
    failed,
};
pub const FollowupKind = enum {
    queue,
    steer,
};
pub const FollowupState = enum {
    pending,
    sent_inline,
    fallback_next_turn,
};
pub const PendingFollowup = struct {
    kind: FollowupKind,
    state: FollowupState = .pending,
    prompt: []u8,
};
pub const SendState = struct {
    mutex: Mutex = .{},
    condition: Condition = .{},
    status: SendStatus = .idle,
    started_at_ms: i64 = 0,
    result: ?SendResultPayload = null,
    error_message: ?[]u8 = null,
    provider: ?Provider = null,
    provisional_provider_thread_id: ?[]u8 = null,
    active_turn_id: ?[]u8 = null,
    daemon_turn_id: ?[]u8 = null,
    daemon_last_seq: u64 = 0,
    daemon_owned: bool = false,
    partial_text: std.ArrayListUnmanaged(u8) = .empty,
    pending_events: std.ArrayListUnmanaged(PendingTimelineEvent) = .empty,
    pending_diff_files: std.ArrayListUnmanaged(PendingDiffFile) = .empty,
    pending_approval: ?PendingApproval = null,
    ui_revision: u64 = 0,
    polled_ui_revision: u64 = 0,
    /// Whole-second elapsed value last reported to the UI poll loop for the
    /// pending "Working - mm:ss" label. Tracked so `pollSend` can request a
    /// repaint exactly when the visible seconds counter would change, even
    /// while the provider has not streamed any tokens. -1 means "no value
    /// reported yet" (so the very first pending poll always renders).
    polled_working_seconds: i64 = -1,
    pending_followup: ?PendingFollowup = null,
    pending_followup_signal_sent: bool = false,
    approval_decision: ?ai_harness.ApprovalDecision = null,
    stop_requested: bool = false,
    stop_signal_sent: bool = false,
    worker: ?std.Thread = null,
};
pub const PendingApproval = struct {
    call_id: []u8,
    title: []u8,
    body: []u8,
};
pub const PendingDiffFile = struct {
    path: []u8,
    additions: i64,
    deletions: i64,
    patch: ?[]u8 = null,
    expanded: bool = false,
};
pub const PendingTimelineEvent = struct {
    role: ChatRole,
    author: []u8,
    body: []u8,
};
pub const SendResultPayload = struct {
    provider_thread_id: []const u8,
    reply_text: []const u8,
};

const InitialSendSnapshot = struct {
    message_count: usize,
    committed: bool,
    last_activity_at: i64,
    title: ?[:0]u8,

    fn init(allocator: std.mem.Allocator, thread: *const ChatThread) !InitialSendSnapshot {
        return .{
            .message_count = thread.messages.items.len,
            .committed = thread.committed,
            .last_activity_at = thread.last_activity_at,
            .title = if (thread.committed) null else try allocator.dupeZ(u8, thread.title),
        };
    }

    fn deinit(self: *InitialSendSnapshot, allocator: std.mem.Allocator) void {
        if (self.title) |title| allocator.free(title);
        self.title = null;
    }

    fn restore(self: *InitialSendSnapshot, state: *AppState, thread: *ChatThread) void {
        while (thread.messages.items.len > self.message_count) {
            state.releaseMessage(thread.messages.pop().?);
        }
        if (self.title) |title| {
            state.allocator.free(thread.title);
            thread.title = title;
            self.title = null;
        }
        thread.committed = self.committed;
        thread.last_activity_at = self.last_activity_at;
    }
};

fn freePendingFollowup(allocator: std.mem.Allocator, followup: *?PendingFollowup) void {
    if (followup.*) |pending| {
        allocator.free(pending.prompt);
        followup.* = null;
    }
}

pub const SidebarThreadHover = struct {
    project_index: usize,
    thread_index: usize,
};

pub const SidebarContextMenuKind = enum {
    none,
    project,
    project_new_thread,
    thread,
};

pub const AppState = struct {
    const DRAFT_CAPACITY = 64 * 1024;
    const SAVE_DEBOUNCE_MS: i64 = 750;

    allocator: std.mem.Allocator,
    storage: *const Storage,
    projects: std.ArrayList(Project),
    archived_projects: std.ArrayList(Project),
    surfaces: std.ArrayList(SurfaceState),
    selected_project_index: usize,
    next_project_number: usize,
    import_path_storage: [DRAFT_CAPACITY:0]u8,
    rename_storage: [256:0]u8,
    sidebar_notice_storage: [256:0]u8,
    import_thread_id_storage: [256:0]u8,
    import_notice_storage: [256:0]u8,
    herdr_profile_notice_storage: [256:0]u8,
    sidebar_collapsed: bool,
    sidebar_hidden: bool,
    sidebar_hover_revealed: bool,
    composer_focused: bool,
    composer_focus_requested: bool,
    composer_input_nonce: u32,
    composer_input_bounds_valid: bool,
    composer_input_min: [2]f32,
    composer_input_max: [2]f32,
    composer_send_bounds_valid: bool,
    composer_send_min: [2]f32,
    composer_send_max: [2]f32,
    composer_send_pressed: bool,
    composer_send_hovered: bool,
    composer_draft_image_clear_valid: bool,
    composer_draft_image_clear_rect: palette.Rect,
    composer_draft_image_clear_index: usize,
    composer_draft_image_clear_count: usize,
    composer_draft_image_clear_rects: [16]palette.Rect,
    composer_draft_image_clear_indices: [16]usize,
    /// Hit rect of the pinned queued/steered follow-up card (above the composer).
    /// Double-clicking it pulls the queued prompt back into the composer to edit.
    followup_pin_valid: bool,
    followup_pin_rect: palette.Rect,
    composer_overlay_scroll_y: f32,
    composer_overlay_follow_cursor: bool,
    composer_overlay_last_cursor_pos: usize,
    composer_overlay_last_draft_len: usize,
    composer_toolbar_overlay_valid: bool,
    composer_toolbar_model_rect: palette.Rect,
    composer_toolbar_reasoning_rect: palette.Rect,
    composer_toolbar_fast_rect: palette.Rect,
    composer_toolbar_access_rect: palette.Rect,
    palette_composer: PaletteComposerPrompt,
    palette_model_picker: PaletteModelPicker,
    model_picker_entries: std.ArrayList(ModelPickerEntry),
    run_config_open: bool,
    /// Index into the currently visible run-config rows for keyboard focus.
    run_config_focused_row: usize,
    /// Monotonic-ms timestamp of the last stepper animation tick; drives the
    /// run-config thumb slide (see `tickRunConfigSteppers`).
    run_config_last_tick_ms: i64,
    run_steppers: [3]PaletteRunStepper,
    run_stepper_contexts: [3]RunStepperContext,
    palette_overlay_batch: palette.RenderBatch,
    palette_frame_text: std.ArrayList(u8),
    palette_frame_text_arena: std.heap.ArenaAllocator,
    palette_modal_hits: std.ArrayList(PaletteModalHit),
    code_copy_buttons: std.ArrayList(CodeCopyButtonHit),
    code_copy_recent_identity: u64,
    code_copy_recent_until_ms: i64,
    card_toggle_hits: std.ArrayList(CardToggleHit),
    expanded_cards: std.AutoHashMap(u64, void),
    palette_modal_text_focus: PaletteModalTextFocus,
    gl_texture_uploads_enabled: bool,
    browser_textures_enabled: bool,
    texture_upload_context: ?*anyopaque,
    texture_upload_fn: ?TextureUploadFn,
    texture_release_fn: ?TextureReleaseFn,
    project_rename_cursor: usize,
    project_import_cursor: usize,
    thread_import_cursor: usize,
    /// Selection anchor for whichever modal text field currently owns focus.
    /// `null` means no active selection. Cleared on focus change.
    modal_text_selection_anchor: ?usize,
    /// True while the user is dragging to extend the modal text selection.
    modal_text_drag_active: bool,
    /// Last-painted rect of the focused modal input. Set by `drawTextField`
    /// so the modal mouse handlers can hit-test + convert cursor x→offset
    /// without re-running the modal layout.
    modal_text_input_rect: palette.Rect,
    /// Font size used to paint the focused modal input, matched for caret
    /// hit-testing on the same `.ui` font role.
    modal_text_input_font_size: f32,
    terminal_focused: bool,
    terminal_resize_drag_active: bool,
    terminal_resize_drag_origin_height: f32,
    // Whether the OS window currently holds input focus. Updated from SDL
    // window focus events; used to gate chat-completion notifications so we
    // don't notify about a turn the user is actively watching.
    window_input_focus: bool,
    debug_terminal_window_focused: bool,
    debug_terminal_hitbox_focused: bool,
    debug_terminal_hitbox_active: bool,
    debug_terminal_hitbox_clicked: bool,
    debug_terminal_focus_requested: bool,
    debug_last_terminal_key_handled: bool,
    debug_last_terminal_text_handled: bool,
    debug_last_terminal_scancode: ?sdl.Scancode,
    debug_last_terminal_text: [32:0]u8,
    debug_workspace_visible_pane_count: usize,
    composer_picker_provider: ?Provider,
    composer_slash_selected: usize,
    composer_locked_model_picker_open: bool,
    opencode_model_options: std.ArrayList(ModelOption),
    claude_model_options: std.ArrayList(ModelOption),
    cursor_model_options: std.ArrayList(ModelOption),
    opencode_reasoning_menu: std.ArrayList(OpencodeReasoningMenuRow),
    image_texture_cache: std.StringHashMap(CachedImageTexture),
    logo_texture: ?CachedImageTexture,
    opencode_logo_texture: ?CachedImageTexture,
    codex_logo_texture: ?CachedImageTexture,
    claude_logo_texture: ?CachedImageTexture,
    amp_logo_texture: ?CachedImageTexture,
    thread_edit_texture: ?CachedImageTexture,
    cursor_logo_texture: ?CachedImageTexture,
    emacs_logo_texture: ?CachedImageTexture,
    neovim_logo_texture: ?CachedImageTexture,
    vscode_logo_texture: ?CachedImageTexture,
    zed_logo_texture: ?CachedImageTexture,
    modal_image_path: ?[:0]const u8,
    app_config: app_config.AppConfig,
    rename_project_index: ?usize,
    thread_import_provider: ?Provider,
    thread_import_project_index: ?usize,
    thread_import_selected_index: ?usize,
    /// Row index in `thread_import_threads` under the cursor (import modal list).
    thread_import_hover_index: ?usize,
    thread_import_threads: std.ArrayList(ImportThreadSummary),
    herdr_profile_picker_project_index: ?usize,
    herdr_profile_selected_index: ?usize,
    /// Row index in `herdr_profile_summaries` under the cursor (profile picker modal).
    herdr_profile_hover_index: ?usize,
    herdr_profile_summaries: std.ArrayList(HerdrProfileSummary),
    /// Command palette (Ctrl+Shift+P overlay). `ui/command_palette.zig` owns result
    /// building and rendering; these are the cross-cutting bits the input
    /// router and keybind dispatch need.
    command_palette_open: bool,
    /// Restrict results to one workspace's threads (sidebar "History" entry
    /// point). `null` = global scope: commands + threads across workspaces.
    command_palette_scope_project: ?usize,
    command_palette_query_storage: [256:0]u8,
    command_palette_cursor: usize,
    /// Selected row in the palette's flattened selectable result list.
    command_palette_selected: usize,
    /// Tab-opened secondary action submenu for the selected result row.
    command_palette_action_menu_open: bool,
    command_palette_action_selected: usize,
    /// Read-only view of the loaded keybind config so the palette can show
    /// live accelerator hints; set by main after keybinds load/reload.
    keyboard_config: ?*const keybinds.NativeKeyboardConfig,
    show_project_creator: bool,
    provider_onboarding_visible: bool,
    provider_onboarding_dismissed: bool,
    show_settings_modal: bool,
    settings_draft: SettingsDraft,
    settings_hook_claude_installed: bool,
    settings_hook_codex_installed: bool,
    settings_hook_amp_installed: bool,
    settings_scroll_y: f32,
    settings_hover_control: ?u8,
    settings_close_hovered: bool,
    app_config_file_mtime: i128,
    app_config_runtime_sync_pending: bool,
    project_directory_browse_requested: bool,
    project_directory_picker_create_parent: bool,
    picker_state: PickerState,
    slash_command_state: SlashCommandState,
    opencode_model_cache_state: OpencodeModelCacheState,
    update_state: updater.State,
    update_installer_started: bool,
    update_exit_requested: bool,
    claude_model_cache_state: ClaudeModelCacheState,
    cursor_model_cache_state: CursorModelCacheState,
    provider_readiness_state: ProviderReadinessState,
    file_search_state: FileSearchState,
    browser_state: browser_runtime.State,
    browser_launch_open_delay_frames: u8,
    browser_start_eval_pending: bool,
    browser_pane_min: [2]f32,
    browser_pane_max: [2]f32,
    browser_pane_input_size: [2]f32,
    browser_pane_hovered: bool,
    app_window_screen_origin: [2]i32,
    app_window_display_scale: f32,
    browser_surface_suspended_for_palette_overlay: bool,
    browser_surface_suspended_for_layout: bool,
    browser_suppressed_closed_events: u8,
    browser_clipboard_copy_pending: bool,
    /// Palette sidebar thread row under the cursor (hover highlight).
    sidebar_thread_hover: ?SidebarThreadHover,
    sidebar_project_hover: ?usize,
    sidebar_new_thread_hover: ?usize,
    browser_pane_focused: bool,
    browser_address_focused: bool,
    browser_address_cursor: usize,
    /// Selection anchor for the URL bar. When equal to `browser_address_cursor`
    /// (or null) there is no active selection.
    browser_address_selection_anchor: ?usize,
    /// True while the user is dragging to extend the URL-bar selection.
    browser_address_drag_active: bool,
    browser_inspector_menu_open: bool,
    browser_context_menu_open: bool,
    browser_context_menu_anchor_x: f32,
    browser_context_menu_anchor_y: f32,
    browser_context_menu_items: std.ArrayList(BrowserContextMenuItem),
    /// Split "Open" header menu (folder / editors); palette workspace chrome only.
    workspace_header_open_menu_open: bool,
    workspace_header_open_menu_pane_id: ?WorkspacePaneId,
    sidebar_context_menu_open: bool,
    sidebar_context_menu_kind: SidebarContextMenuKind,
    sidebar_context_menu_project_index: usize,
    sidebar_context_menu_thread_index: usize,
    sidebar_context_menu_anchor_x: f32,
    sidebar_context_menu_anchor_y: f32,
    transcript_focused: bool,
    transcript_selection_modal_requested: bool,
    transcript_project_index: ?usize,
    transcript_thread_index: ?usize,
    transcript_selection_text: ?[:0]u8,
    transcript_markdown_selection_project_index: ?usize,
    transcript_markdown_selection_thread_index: ?usize,
    transcript_markdown_selection_anchor: ?TranscriptMarkdownSelectionPoint,
    transcript_markdown_selection_focus: ?TranscriptMarkdownSelectionPoint,
    transcript_markdown_selection_dragging: bool,
    /// Last pointer position in palette framebuffer space (updated from workspace mouse motion).
    palette_mouse_x: f32,
    palette_mouse_y: f32,
    palette_mouse_in_workspace: bool,
    /// Cached transcript layout from the last `chat_panel` paint (used for hit-testing between frames).
    transcript_palette_column: palette.Rect,
    transcript_palette_scroll_y: f32,
    transcript_palette_clip: palette.Rect,
    transcript_markdown_project_index: ?usize,
    transcript_markdown_thread_index: ?usize,
    transcript_markdown_entries: std.ArrayList(?*TranscriptMarkdownBody),
    transcript_auto_follow_pending: bool,
    scroll_transcript_to_bottom_frames: u8,
    /// Keyboard fine scroll: applied once on next transcript layout (px); cleared after paint.
    pending_transcript_scroll_px: f32,
    pending_transcript_page_steps: i16,
    transcript_scroll_pending_track_p: usize,
    transcript_scroll_pending_track_t: usize,
    dirty: bool,
    last_dirty_at_ms: i64,
    last_interaction_at_ms: i64,
    pending_send_count: usize,
    /// Set by the sidebar render pass whenever it draws a pulsing status pip
    /// this frame; cleared at the top of renderRoot. The main loop reads the
    /// previous frame's value to keep a ~30fps animation tick going (the loop
    /// otherwise sleeps and the pulse would step at the 1Hz label cadence).
    sidebar_pulse_animating: bool,
    /// Monotonic ms timestamp of the last visible terminal input or output.
    /// Input starts the fast-poll window before ConPTY has produced its echo,
    /// avoiding a cold keystroke falling back to the idle wake cadence.
    last_terminal_activity_ms: i64,
    /// Caps synchronous daemon-tail RPCs when SDL delivers a burst of input or
    /// mouse events. A terminal input can explicitly bypass the cap once so
    /// the first output check still happens in the same event-loop iteration.
    last_terminal_poll_ms: i64,
    terminal_poll_requested: bool,
    /// Wall-clock ms deadline for ignoring Linux close requests immediately
    /// after a successful xdg-open/gio launch. Some file managers briefly send
    /// a focused SDL close event back to Verde even though the user only opened
    /// the workspace folder.
    external_open_close_suppress_until_ms: i64,

    pub const InitOptions = struct {
        gl_texture_uploads_enabled: bool = true,
        browser_textures_enabled: bool = true,
        texture_upload_context: ?*anyopaque = null,
        texture_upload_fn: ?TextureUploadFn = null,
        texture_release_fn: ?TextureReleaseFn = null,
    };

    pub const TextureUploadFn = *const fn (context: ?*anyopaque, loaded: stb_image.LoadedImage) ?CachedImageTexture;
    pub const TextureReleaseFn = *const fn (context: ?*anyopaque, texture_id: c_uint) void;

    pub fn init(allocator: std.mem.Allocator, storage: *const Storage, initial_config: app_config.AppConfig, options: InitOptions) !AppState {
        terminal.configureGhosttySystem();
        var browser_state = try browser_runtime.State.init(allocator);
        errdefer browser_state.deinit();

        var state: AppState = .{
            .allocator = allocator,
            .storage = storage,
            .projects = .empty,
            .archived_projects = .empty,
            .surfaces = .empty,
            .selected_project_index = 0,
            .next_project_number = 4,
            .import_path_storage = std.mem.zeroes([DRAFT_CAPACITY:0]u8),
            .rename_storage = std.mem.zeroes([256:0]u8),
            .sidebar_notice_storage = std.mem.zeroes([256:0]u8),
            .import_thread_id_storage = std.mem.zeroes([256:0]u8),
            .import_notice_storage = std.mem.zeroes([256:0]u8),
            .herdr_profile_notice_storage = std.mem.zeroes([256:0]u8),
            .sidebar_collapsed = false,
            .sidebar_hidden = false,
            .sidebar_hover_revealed = false,
            .composer_focused = false,
            .composer_focus_requested = false,
            .composer_input_nonce = 0,
            .composer_input_bounds_valid = false,
            .composer_input_min = .{ 0.0, 0.0 },
            .composer_input_max = .{ 0.0, 0.0 },
            .composer_send_bounds_valid = false,
            .composer_send_min = .{ 0.0, 0.0 },
            .composer_send_max = .{ 0.0, 0.0 },
            .composer_send_pressed = false,
            .composer_send_hovered = false,
            .composer_draft_image_clear_valid = false,
            .composer_draft_image_clear_rect = .{ .x = 0.0, .y = 0.0, .w = 0.0, .h = 0.0 },
            .composer_draft_image_clear_index = 0,
            .composer_draft_image_clear_count = 0,
            .composer_draft_image_clear_rects = [_]palette.Rect{.{ .x = 0.0, .y = 0.0, .w = 0.0, .h = 0.0 }} ** 16,
            .composer_draft_image_clear_indices = [_]usize{0} ** 16,
            .followup_pin_valid = false,
            .followup_pin_rect = .{ .x = 0.0, .y = 0.0, .w = 0.0, .h = 0.0 },
            .composer_overlay_scroll_y = 0.0,
            .composer_overlay_follow_cursor = true,
            .composer_overlay_last_cursor_pos = 0,
            .composer_overlay_last_draft_len = 0,
            .composer_toolbar_overlay_valid = false,
            .composer_toolbar_model_rect = .{ .x = 0.0, .y = 0.0, .w = 0.0, .h = 0.0 },
            .composer_toolbar_reasoning_rect = .{ .x = 0.0, .y = 0.0, .w = 0.0, .h = 0.0 },
            .composer_toolbar_fast_rect = .{ .x = 0.0, .y = 0.0, .w = 0.0, .h = 0.0 },
            .composer_toolbar_access_rect = .{ .x = 0.0, .y = 0.0, .w = 0.0, .h = 0.0 },
            .palette_composer = PaletteComposerPrompt.init(),
            .palette_model_picker = PaletteModelPicker.init(0),
            .model_picker_entries = .empty,
            .run_config_open = false,
            .run_config_focused_row = 0,
            .run_config_last_tick_ms = 0,
            .run_steppers = .{ PaletteRunStepper.init(0), PaletteRunStepper.init(2), PaletteRunStepper.init(2) },
            .run_stepper_contexts = .{ .{}, .{}, .{} },
            .palette_overlay_batch = .{},
            .palette_frame_text = .empty,
            .palette_frame_text_arena = std.heap.ArenaAllocator.init(allocator),
            .palette_modal_hits = .empty,
            .code_copy_buttons = .empty,
            .code_copy_recent_identity = 0,
            .code_copy_recent_until_ms = 0,
            .card_toggle_hits = .empty,
            .expanded_cards = std.AutoHashMap(u64, void).init(allocator),
            .palette_modal_text_focus = .none,
            .gl_texture_uploads_enabled = options.gl_texture_uploads_enabled,
            .browser_textures_enabled = options.browser_textures_enabled,
            .texture_upload_context = options.texture_upload_context,
            .texture_upload_fn = options.texture_upload_fn,
            .texture_release_fn = options.texture_release_fn,
            .project_rename_cursor = 0,
            .project_import_cursor = 0,
            .thread_import_cursor = 0,
            .modal_text_selection_anchor = null,
            .modal_text_drag_active = false,
            .modal_text_input_rect = .{},
            .modal_text_input_font_size = 0.0,
            .terminal_focused = false,
            .terminal_resize_drag_active = false,
            .terminal_resize_drag_origin_height = 0.0,
            .window_input_focus = true,
            .debug_terminal_window_focused = false,
            .debug_terminal_hitbox_focused = false,
            .debug_terminal_hitbox_active = false,
            .debug_terminal_hitbox_clicked = false,
            .debug_terminal_focus_requested = false,
            .debug_last_terminal_key_handled = false,
            .debug_last_terminal_text_handled = false,
            .debug_last_terminal_scancode = null,
            .debug_last_terminal_text = std.mem.zeroes([32:0]u8),
            .debug_workspace_visible_pane_count = 0,
            .composer_picker_provider = null,
            .composer_slash_selected = 0,
            .composer_locked_model_picker_open = false,
            .opencode_model_options = .empty,
            .claude_model_options = .empty,
            .cursor_model_options = .empty,
            .opencode_reasoning_menu = .empty,
            .image_texture_cache = std.StringHashMap(CachedImageTexture).init(allocator),
            .logo_texture = null,
            .opencode_logo_texture = null,
            .codex_logo_texture = null,
            .claude_logo_texture = null,
            .amp_logo_texture = null,
            .thread_edit_texture = null,
            .cursor_logo_texture = null,
            .emacs_logo_texture = null,
            .neovim_logo_texture = null,
            .vscode_logo_texture = null,
            .zed_logo_texture = null,
            .modal_image_path = null,
            .app_config = initial_config,
            .rename_project_index = null,
            .thread_import_provider = null,
            .thread_import_project_index = null,
            .thread_import_selected_index = null,
            .thread_import_hover_index = null,
            .thread_import_threads = .empty,
            .herdr_profile_picker_project_index = null,
            .herdr_profile_selected_index = null,
            .herdr_profile_hover_index = null,
            .herdr_profile_summaries = .empty,
            .command_palette_open = false,
            .command_palette_scope_project = null,
            .command_palette_query_storage = std.mem.zeroes([256:0]u8),
            .command_palette_cursor = 0,
            .command_palette_selected = 0,
            .command_palette_action_menu_open = false,
            .command_palette_action_selected = 0,
            .keyboard_config = null,
            .show_project_creator = false,
            .provider_onboarding_visible = false,
            .provider_onboarding_dismissed = false,
            .show_settings_modal = false,
            .settings_draft = .{},
            .settings_hook_claude_installed = false,
            .settings_hook_codex_installed = false,
            .settings_hook_amp_installed = false,
            .settings_scroll_y = 0.0,
            .settings_hover_control = null,
            .settings_close_hovered = false,
            .app_config_file_mtime = -1,
            .app_config_runtime_sync_pending = false,
            .project_directory_browse_requested = false,
            .project_directory_picker_create_parent = false,
            .picker_state = .{},
            .slash_command_state = .{},
            .opencode_model_cache_state = .{},
            .update_state = .{},
            .update_installer_started = false,
            .update_exit_requested = false,
            .claude_model_cache_state = .{},
            .cursor_model_cache_state = .{},
            .provider_readiness_state = .{},
            .file_search_state = .{},
            .browser_state = browser_state,
            .browser_launch_open_delay_frames = 0,
            .browser_start_eval_pending = false,
            .browser_pane_min = .{ 0.0, 0.0 },
            .browser_pane_max = .{ 0.0, 0.0 },
            .browser_pane_input_size = .{ 0.0, 0.0 },
            .browser_pane_hovered = false,
            .app_window_screen_origin = .{ 0, 0 },
            .app_window_display_scale = 1.0,
            .browser_surface_suspended_for_palette_overlay = false,
            .browser_surface_suspended_for_layout = false,
            .browser_suppressed_closed_events = 0,
            .browser_clipboard_copy_pending = false,
            .sidebar_thread_hover = null,
            .sidebar_project_hover = null,
            .sidebar_new_thread_hover = null,
            .browser_pane_focused = false,
            .browser_address_focused = false,
            .browser_address_cursor = 0,
            .browser_address_selection_anchor = null,
            .browser_address_drag_active = false,
            .browser_inspector_menu_open = false,
            .browser_context_menu_open = false,
            .browser_context_menu_anchor_x = 0.0,
            .browser_context_menu_anchor_y = 0.0,
            .browser_context_menu_items = .empty,
            .workspace_header_open_menu_open = false,
            .workspace_header_open_menu_pane_id = null,
            .sidebar_context_menu_open = false,
            .sidebar_context_menu_kind = .none,
            .sidebar_context_menu_project_index = 0,
            .sidebar_context_menu_thread_index = 0,
            .sidebar_context_menu_anchor_x = 0.0,
            .sidebar_context_menu_anchor_y = 0.0,
            .transcript_focused = false,
            .transcript_selection_modal_requested = false,
            .transcript_project_index = null,
            .transcript_thread_index = null,
            .transcript_selection_text = null,
            .transcript_markdown_selection_project_index = null,
            .transcript_markdown_selection_thread_index = null,
            .transcript_markdown_selection_anchor = null,
            .transcript_markdown_selection_focus = null,
            .transcript_markdown_selection_dragging = false,
            .palette_mouse_x = 0.0,
            .palette_mouse_y = 0.0,
            .palette_mouse_in_workspace = false,
            .transcript_palette_column = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
            .transcript_palette_scroll_y = 0.0,
            .transcript_palette_clip = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
            .transcript_markdown_project_index = null,
            .transcript_markdown_thread_index = null,
            .transcript_markdown_entries = .empty,
            .transcript_auto_follow_pending = true,
            .scroll_transcript_to_bottom_frames = 8,
            .pending_transcript_scroll_px = 0,
            .pending_transcript_page_steps = 0,
            .transcript_scroll_pending_track_p = std.math.maxInt(usize),
            .transcript_scroll_pending_track_t = std.math.maxInt(usize),
            .dirty = false,
            .last_dirty_at_ms = 0,
            .last_interaction_at_ms = 0,
            .pending_send_count = 0,
            .sidebar_pulse_animating = false,
            .last_terminal_activity_ms = 0,
            .last_terminal_poll_ms = 0,
            .terminal_poll_requested = false,
            .external_open_close_suppress_until_ms = 0,
        };
        state.palette_composer.setCallbacks(.{});

        if (try storage.load(allocator)) |persisted_value| {
            var persisted = persisted_value;
            defer persisted.deinit();
            try state.applyPersisted(persisted.value);
        } else {
            try state.seedDefaultState();
        }
        state.restoreDaemonChatTurnsOnLaunch();
        state.loadCursorModelOptionsDiskCache() catch |err| {
            log.warn("failed to load Cursor model cache: {s}", .{@errorName(err)});
            state.clearCursorModelOptions();
        };
        if (options.gl_texture_uploads_enabled or options.texture_upload_fn != null) {
            state.logo_texture = state.loadEmbeddedTexture(VERDE_LOGO_BYTES);
            state.opencode_logo_texture = state.loadEmbeddedTexture(OPENCODE_LOGO_BYTES);
            state.codex_logo_texture = state.loadEmbeddedTexture(CODEX_LOGO_BYTES);
            state.claude_logo_texture = state.loadEmbeddedTexture(CLAUDE_LOGO_BYTES);
            state.amp_logo_texture = state.loadEmbeddedTexture(AMP_LOGO_BYTES);
            state.thread_edit_texture = state.loadEmbeddedTexture(THREAD_EDIT_BYTES);
            state.cursor_logo_texture = state.loadEmbeddedTexture(CURSOR_LOGO_BYTES);
            state.emacs_logo_texture = state.loadEmbeddedTexture(EMACS_LOGO_BYTES);
            state.neovim_logo_texture = state.loadEmbeddedTexture(NEOVIM_LOGO_BYTES);
            state.vscode_logo_texture = state.loadEmbeddedTexture(VSCODE_LOGO_BYTES);
            state.zed_logo_texture = state.loadEmbeddedTexture(ZED_LOGO_BYTES);
        }
        return state;
    }

    fn loadEmbeddedTexture(self: *AppState, bytes: []const u8) ?CachedImageTexture {
        const loaded = stb_image.loadFromMemory(bytes) catch |err| {
            log.err("failed to decode embedded texture: {s}", .{@errorName(err)});
            return null;
        };
        defer loaded.deinit();
        return self.uploadLoadedTexture(loaded);
    }

    fn uploadLoadedTexture(self: *AppState, loaded: stb_image.LoadedImage) ?CachedImageTexture {
        if (self.texture_upload_fn) |upload_fn| {
            return upload_fn(self.texture_upload_context, loaded);
        }
        if (!self.gl_texture_uploads_enabled) return null;
        return uploadTexture(loaded);
    }

    pub fn uploadRgbaTexture(self: *AppState, width: u32, height: u32, pixels: []const u8) ?CachedImageTexture {
        const expected_len = std.math.mul(usize, width, height) catch return null;
        const rgba_len = std.math.mul(usize, expected_len, 4) catch return null;
        if (width == 0 or height == 0 or pixels.len != rgba_len) return null;
        const loaded: stb_image.LoadedImage = .{
            .pixels = @ptrCast(@constCast(pixels.ptr)),
            .width = @intCast(width),
            .height = @intCast(height),
            .channels = 4,
        };
        return self.uploadLoadedTexture(loaded);
    }

    pub fn releaseTexture(self: *AppState, texture_id: c_uint) void {
        if (texture_id == 0) return;
        if (self.texture_release_fn) |release_fn| {
            release_fn(self.texture_upload_context, texture_id);
        }
    }

    pub fn opencodeModelOptionsSnapshot(self: *const AppState) []const ModelOption {
        return if (self.opencode_model_options.items.len > 0)
            self.opencode_model_options.items
        else
            OPENCODE_MODEL_OPTIONS[0..];
    }

    pub fn claudeModelOptionsSnapshot(self: *const AppState) []const ModelOption {
        return if (self.claude_model_options.items.len > 0)
            self.claude_model_options.items
        else
            CLAUDE_MODEL_OPTIONS[0..];
    }

    pub fn cursorModelOptionsSnapshot(self: *const AppState) []const ModelOption {
        return if (self.cursor_model_options.items.len > 0)
            self.cursor_model_options.items
        else
            CURSOR_MODEL_OPTIONS[0..];
    }

    pub fn cachedDefaultModelRefForProvider(self: *const AppState, provider: Provider) [:0]const u8 {
        return switch (provider) {
            .codex => DEFAULT_CODEX_MODEL,
            .claude => DEFAULT_CLAUDE_MODEL,
            .cursor => DEFAULT_CURSOR_MODEL,
            .opencode => blk: {
                for (self.opencodeModelOptionsSnapshot()) |option| {
                    if (option.value) |value| break :blk value;
                }
                break :blk DEFAULT_OPENCODE_MODEL;
            },
        };
    }

    pub fn startOpencodeModelOptionsRefresh(self: *AppState) void {
        self.refreshOpencodeModelOptionsCacheAsync();
    }

    pub fn startCursorModelOptionsRefresh(self: *AppState) void {
        self.refreshCursorModelOptionsCacheAsync();
    }

    pub fn startClaudeModelOptionsRefresh(self: *AppState) void {
        self.refreshClaudeModelOptionsCacheAsync();
    }

    pub fn startProviderReadinessCheck(self: *AppState) void {
        self.pollProviderReadiness();

        self.provider_readiness_state.mutex.lock();
        defer self.provider_readiness_state.mutex.unlock();
        if (self.provider_readiness_state.status == .pending) return;

        self.provider_readiness_state.status = .pending;
        self.provider_readiness_state.snapshot = .{};
        self.provider_readiness_state.worker = std.Thread.spawn(.{}, providerReadinessWorker, .{
            &self.provider_readiness_state,
        }) catch {
            self.provider_readiness_state.status = .completed;
            self.provider_readiness_state.snapshot = .{
                .codex = .unavailable,
                .opencode = .unavailable,
                .claude = .unavailable,
                .cursor = .unavailable,
            };
            return;
        };
        self.markDirty();
    }

    pub fn pollProviderReadiness(self: *AppState) void {
        var completed = false;
        var snapshot: ProviderReadinessSnapshot = .{};

        self.provider_readiness_state.mutex.lock();
        if (self.provider_readiness_state.status == .completed) {
            snapshot = self.provider_readiness_state.snapshot;
            self.provider_readiness_state.status = .idle;
            completed = true;
        }
        self.provider_readiness_state.mutex.unlock();
        if (!completed) return;

        self.finishProviderReadinessThread();
        if (snapshot.hasReadyProvider()) {
            self.provider_onboarding_visible = false;
            self.provider_onboarding_dismissed = false;
        } else if (!self.provider_onboarding_dismissed) {
            self.provider_onboarding_visible = true;
        }
        self.markDirty();
    }

    pub fn providerReadinessSnapshot(self: *AppState) ProviderReadinessSnapshot {
        self.provider_readiness_state.mutex.lock();
        defer self.provider_readiness_state.mutex.unlock();
        return self.provider_readiness_state.snapshot;
    }

    pub fn dismissProviderOnboarding(self: *AppState) void {
        self.provider_onboarding_visible = false;
        self.provider_onboarding_dismissed = true;
        self.markDirty();
    }

    pub fn recheckProviderReadiness(self: *AppState) void {
        self.provider_onboarding_visible = true;
        self.provider_onboarding_dismissed = false;
        self.startProviderReadinessCheck();
    }

    pub fn openProviderSetupGuide(self: *AppState) void {
        utils.openUrlInDefaultBrowser(self.allocator, "https://verdeai.dev/docs/providers") catch |err| {
            log.warn("failed to open provider setup guide: {s}", .{@errorName(err)});
            self.setSidebarNotice("Could not open the provider setup guide.");
            return;
        };
        self.setSidebarNotice("Opened provider setup guide.");
    }

    fn refreshOpencodeModelOptionsCacheAsync(self: *AppState) void {
        self.pollOpencodeModelOptionsCache();

        self.opencode_model_cache_state.mutex.lock();
        defer self.opencode_model_cache_state.mutex.unlock();
        if (self.opencode_model_cache_state.status == .pending) return;

        self.opencode_model_cache_state.status = .pending;
        self.opencode_model_cache_state.worker = std.Thread.spawn(.{}, opencodeModelCacheWorker, .{
            &self.opencode_model_cache_state,
        }) catch {
            self.opencode_model_cache_state.status = .idle;
            return;
        };
    }

    fn refreshCursorModelOptionsCacheAsync(self: *AppState) void {
        self.pollCursorModelOptionsCache();

        self.cursor_model_cache_state.mutex.lock();
        defer self.cursor_model_cache_state.mutex.unlock();
        if (self.cursor_model_cache_state.status == .pending) return;

        self.cursor_model_cache_state.status = .pending;
        self.cursor_model_cache_state.worker = std.Thread.spawn(.{}, cursorModelCacheWorker, .{
            &self.cursor_model_cache_state,
        }) catch {
            self.cursor_model_cache_state.status = .idle;
            return;
        };
    }

    fn refreshClaudeModelOptionsCacheAsync(self: *AppState) void {
        self.pollClaudeModelOptionsCache();

        self.claude_model_cache_state.mutex.lock();
        defer self.claude_model_cache_state.mutex.unlock();
        if (self.claude_model_cache_state.status == .pending) return;

        self.claude_model_cache_state.status = .pending;
        self.claude_model_cache_state.worker = std.Thread.spawn(.{}, claudeModelCacheWorker, .{
            &self.claude_model_cache_state,
        }) catch {
            self.claude_model_cache_state.status = .idle;
            log.warn("failed to spawn Claude model cache worker", .{});
            return;
        };
    }

    fn duplicateReasoningVariantKeys(allocator: std.mem.Allocator, src: ?[]const [:0]const u8) !?[][:0]const u8 {
        const keys = src orelse return null;
        if (keys.len == 0) return null;
        const out = try allocator.alloc([:0]const u8, keys.len);
        errdefer {
            for (out) |k| allocator.free(k);
            allocator.free(out);
        }
        for (keys, 0..) |k, i| {
            out[i] = try allocator.dupeZ(u8, k);
        }
        return out;
    }

    fn populateOpencodeModelOptions(self: *AppState, models: []const ai_harness.ModelInfo) !void {
        var order = try self.allocator.alloc(usize, models.len);
        defer self.allocator.free(order);
        for (0..models.len) |i| order[i] = i;

        var sort_i: usize = 1;
        while (sort_i < order.len) : (sort_i += 1) {
            const cur_idx = order[sort_i];
            var j = sort_i;
            while (j > 0 and opencodeModelSortLessThan(models[cur_idx], models[order[j - 1]])) : (j -= 1) {
                order[j] = order[j - 1];
            }
            order[j] = cur_idx;
        }

        // Preset `opencode/…` routes first when the API list omits them (common when only one vendor
        // is configured). Skip a preset when any API row already exposes the same model id so we do
        // not list two entries for the same model (e.g. `openai/gpt-5.4` vs `opencode/gpt-5.4`).
        for (OPENCODE_MODEL_OPTIONS) |preset| {
            const preset_value = preset.value orelse continue;
            const preset_model_id = opencodeModelIdSuffixFromRef(preset_value) orelse continue;
            if (opencodeSortedModelsContainModelIdFromOrder(order, models, preset_model_id)) continue;

            const preset_label = try self.allocator.dupeZ(u8, preset.label);
            errdefer self.allocator.free(preset_label);
            const preset_value_copy = try self.allocator.dupeZ(u8, preset_value);
            errdefer self.allocator.free(preset_value_copy);
            const preset_keys = try duplicateReasoningVariantKeys(self.allocator, preset.reasoning_variant_keys);
            errdefer if (preset_keys) |pk| {
                for (pk) |k| self.allocator.free(k);
                self.allocator.free(pk);
            };
            try self.opencode_model_options.append(self.allocator, .{
                .label = preset_label,
                .value = preset_value_copy,
                .reasoning_supported = preset.reasoning_supported,
                .reasoning_variant_keys = preset_keys,
            });
        }

        for (order) |mi| {
            const model = models[mi];
            const model_name = if (model.model_name.len > 0) model.model_name else model.model_id;
            const provider_name = if (model.provider_name.len > 0) model.provider_name else model.provider_id;
            const label_text = try std.fmt.allocPrint(self.allocator, "{s} ({s})", .{ model_name, provider_name });
            defer self.allocator.free(label_text);
            const label = try self.allocator.dupeZ(u8, label_text);
            errdefer self.allocator.free(label);

            const value_text = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ model.provider_id, model.model_id });
            defer self.allocator.free(value_text);
            const value = try self.allocator.dupeZ(u8, value_text);
            errdefer self.allocator.free(value);

            const keys = try duplicateReasoningVariantKeys(self.allocator, model.reasoning_variant_keys);
            errdefer if (keys) |k| {
                for (k) |x| self.allocator.free(x);
                self.allocator.free(k);
            };

            try self.opencode_model_options.append(self.allocator, .{
                .label = label,
                .value = value,
                .reasoning_supported = model.reasoning_supported,
                .reasoning_variant_keys = keys,
            });
        }
    }

    fn opencodeModelIdSuffixFromRef(model_ref: []const u8) ?[]const u8 {
        const slash = std.mem.lastIndexOfScalar(u8, model_ref, '/') orelse return null;
        if (slash + 1 >= model_ref.len) return null;
        return model_ref[slash + 1 ..];
    }

    fn opencodeSortedModelsContainModelIdFromOrder(order: []const usize, model_list: []const ai_harness.ModelInfo, model_id: []const u8) bool {
        for (order) |mi| {
            if (std.mem.eql(u8, model_list[mi].model_id, model_id)) return true;
        }
        return false;
    }

    fn opencodeModelSortLessThan(a: ai_harness.ModelInfo, b: ai_harness.ModelInfo) bool {
        const provider_name_a = if (a.provider_name.len > 0) a.provider_name else a.provider_id;
        const provider_name_b = if (b.provider_name.len > 0) b.provider_name else b.provider_id;
        const provider_cmp = asciiCaseInsensitiveCompare(provider_name_a, provider_name_b);
        if (provider_cmp != .eq) return provider_cmp == .lt;

        const model_name_a = if (a.model_name.len > 0) a.model_name else a.model_id;
        const model_name_b = if (b.model_name.len > 0) b.model_name else b.model_id;
        const model_cmp = asciiCaseInsensitiveCompare(model_name_a, model_name_b);
        if (model_cmp != .eq) return model_cmp == .lt;

        const provider_id_cmp = asciiCaseInsensitiveCompare(a.provider_id, b.provider_id);
        if (provider_id_cmp != .eq) return provider_id_cmp == .lt;

        return asciiCaseInsensitiveCompare(a.model_id, b.model_id) == .lt;
    }

    fn populateCursorModelOptions(self: *AppState, models: []const ai_harness.ModelInfo) !void {
        for (models) |model| {
            if (model.model_id.len == 0) continue;
            const label_text = if (model.model_name.len > 0) model.model_name else model.model_id;
            const label = try self.allocator.dupeZ(u8, label_text);
            errdefer self.allocator.free(label);
            const value = try self.allocator.dupeZ(u8, model.model_id);
            errdefer self.allocator.free(value);
            const reasoning_param_id = if (model.cursor_reasoning_param_id) |param_id| try self.allocator.dupeZ(u8, param_id) else null;
            errdefer if (reasoning_param_id) |param_id| self.allocator.free(param_id);
            const cursor_reasoning_values = try duplicateReasoningVariantKeys(self.allocator, model.cursor_reasoning_values);
            errdefer if (cursor_reasoning_values) |values| {
                for (values) |reasoning_value| self.allocator.free(reasoning_value);
                self.allocator.free(values);
            };

            try self.cursor_model_options.append(self.allocator, .{
                .label = label,
                .value = value,
                .reasoning_supported = model.reasoning_supported,
                .cursor_fast_supported = model.cursor_fast_supported,
                .cursor_reasoning_param_id = reasoning_param_id,
                .cursor_reasoning_values = cursor_reasoning_values,
                .cursor_reasoning_requires_thinking = model.cursor_reasoning_requires_thinking,
            });
        }
    }

    fn populateClaudeModelOptions(self: *AppState, models: []const ai_harness.ModelInfo) !void {
        for (models) |model| {
            if (model.model_id.len == 0) continue;
            const label_text = if (model.model_name.len > 0) model.model_name else model.model_id;
            const label = try self.allocator.dupeZ(u8, label_text);
            errdefer self.allocator.free(label);
            const value = try self.allocator.dupeZ(u8, model.model_id);
            errdefer self.allocator.free(value);
            const effort_values = try duplicateReasoningVariantKeys(self.allocator, model.claude_effort_values);
            errdefer if (effort_values) |values| {
                for (values) |effort_value| self.allocator.free(effort_value);
                self.allocator.free(values);
            };

            try self.claude_model_options.append(self.allocator, .{
                .label = label,
                .value = value,
                .reasoning_supported = model.reasoning_supported,
                .claude_effort_values = effort_values,
            });
        }
    }

    fn asciiCaseInsensitiveCompare(a: []const u8, b: []const u8) std.math.Order {
        var index: usize = 0;
        const min_len = @min(a.len, b.len);
        while (index < min_len) : (index += 1) {
            const lhs = std.ascii.toLower(a[index]);
            const rhs = std.ascii.toLower(b[index]);
            if (lhs < rhs) return .lt;
            if (lhs > rhs) return .gt;
        }
        if (a.len < b.len) return .lt;
        if (a.len > b.len) return .gt;
        return .eq;
    }

    fn normalizeCurrentOpencodeThreadModel(self: *AppState) void {
        if (self.projects.items.len == 0) return;
        if (self.opencode_model_options.items.len == 0) return;

        const thread = self.currentThreadMutable();
        if (thread.provider != .opencode) return;

        const fallback_model_ref = blk: {
            for (self.opencode_model_options.items) |option| {
                if (option.value) |value| break :blk value;
            }
            return;
        };

        if (thread.model_ref) |model_ref| {
            for (self.opencode_model_options.items) |option| {
                if (option.value) |value| {
                    if (std.mem.eql(u8, model_ref, value)) {
                        self.normalizeOpencodeReasoningVariant(thread);
                        return;
                    }
                }
            }
            self.allocator.free(model_ref);
        }

        thread.model_ref = self.allocator.dupeZ(u8, fallback_model_ref) catch null;
        self.normalizeOpencodeReasoningVariant(thread);
        self.markDirty();
    }

    fn opencodeModelOptionForRef(self: *const AppState, model_ref: ?[:0]const u8) ?ModelOption {
        const ref = model_ref orelse return null;
        for (self.opencode_model_options.items) |opt| {
            if (opt.value) |v| {
                if (std.mem.eql(u8, ref, v)) return opt;
            }
        }
        return null;
    }

    fn refreshOpencodeReasoningMenu(self: *AppState, thread: *const ChatThread) !void {
        self.clearOpencodeReasoningMenu();
        errdefer self.clearOpencodeReasoningMenu();

        if (thread.provider == .cursor) return self.refreshCursorReasoningMenu(thread);
        if (thread.provider == .claude) return self.refreshClaudeReasoningMenu(thread);
        if (thread.provider != .opencode) return;
        const opt = self.opencodeModelOptionForRef(thread.model_ref) orelse return;
        if (!opt.reasoning_supported) return;
        const keys = opt.reasoning_variant_keys orelse return;
        if (keys.len == 0) return;

        const default_label = try self.allocator.dupeZ(u8, "Default");
        try self.opencode_reasoning_menu.append(self.allocator, .{ .label = default_label, .variant = null });

        for (keys) |key| {
            const label = try self.allocator.dupeZ(u8, key);
            const variant_copy = try self.allocator.dupeZ(u8, key);
            try self.opencode_reasoning_menu.append(self.allocator, .{ .label = label, .variant = variant_copy });
        }
    }

    fn refreshCursorReasoningMenu(self: *AppState, thread: *const ChatThread) !void {
        const opt = self.cursorModelOptionForRef(thread.model_ref) orelse return;
        const values = opt.cursor_reasoning_values orelse return;
        if (values.len == 0) return;

        const default_label = try self.allocator.dupeZ(u8, "Default");
        try self.opencode_reasoning_menu.append(self.allocator, .{ .label = default_label, .variant = null });

        for (values) |value| {
            const label_text = cursorReasoningValueLabel(value);
            const label = try self.allocator.dupeZ(u8, label_text);
            const variant_copy = try self.allocator.dupeZ(u8, value);
            try self.opencode_reasoning_menu.append(self.allocator, .{ .label = label, .variant = variant_copy });
        }
    }

    fn refreshClaudeReasoningMenu(self: *AppState, thread: *const ChatThread) !void {
        const opt = self.claudeModelOptionForRef(thread.model_ref) orelse return;
        if (!opt.reasoning_supported) return;
        const values = opt.claude_effort_values orelse CLAUDE_STANDARD_EFFORT_VALUES[0..];
        if (values.len == 0) return;

        const default_label = try self.allocator.dupeZ(u8, "Default");
        try self.opencode_reasoning_menu.append(self.allocator, .{ .label = default_label, .variant = null });

        for (values) |value| {
            if (parseReasoningEffort(value) == null) continue;
            const label_text = claudeEffortValueLabel(value);
            const label = try self.allocator.dupeZ(u8, label_text);
            const variant_copy = try self.allocator.dupeZ(u8, value);
            try self.opencode_reasoning_menu.append(self.allocator, .{ .label = label, .variant = variant_copy });
        }
    }

    fn cursorModelOptionForRef(self: *const AppState, model_ref: ?[:0]const u8) ?ModelOption {
        const ref = model_ref orelse DEFAULT_CURSOR_MODEL;
        for (self.cursorModelOptionsSnapshot()) |opt| {
            if (opt.value) |v| {
                if (std.mem.eql(u8, ref, v)) return opt;
            }
        }
        return null;
    }

    fn claudeModelOptionForRef(self: *const AppState, model_ref: ?[:0]const u8) ?ModelOption {
        const ref = model_ref orelse DEFAULT_CLAUDE_MODEL;
        for (self.claudeModelOptionsSnapshot()) |opt| {
            if (opt.value) |v| {
                if (std.mem.eql(u8, ref, v)) return opt;
            }
        }
        return null;
    }

    fn cursorModelParamsJsonAlloc(self: *const AppState, allocator: std.mem.Allocator, thread: *const ChatThread) !?[]u8 {
        if (thread.provider != .cursor) return null;
        const opt = self.cursorModelOptionForRef(thread.model_ref) orelse return null;

        var writer: std.Io.Writer.Allocating = .init(allocator);
        errdefer writer.deinit();
        var stringify: std.json.Stringify = .{ .writer = &writer.writer, .options = .{} };
        try stringify.beginArray();
        var wrote_any = false;

        if (opt.cursor_reasoning_requires_thinking and thread.opencode_reasoning_variant != null) {
            try stringify.beginObject();
            try stringify.objectField("id");
            try stringify.write("thinking");
            try stringify.objectField("value");
            try stringify.write("true");
            try stringify.endObject();
            wrote_any = true;
        }
        if (opt.cursor_reasoning_param_id) |param_id| {
            if (thread.opencode_reasoning_variant) |value| {
                try stringify.beginObject();
                try stringify.objectField("id");
                try stringify.write(std.mem.sliceTo(param_id, 0));
                try stringify.objectField("value");
                try stringify.write(std.mem.sliceTo(value, 0));
                try stringify.endObject();
                wrote_any = true;
            }
        }
        if (opt.cursor_fast_supported) {
            try stringify.beginObject();
            try stringify.objectField("id");
            try stringify.write("fast");
            try stringify.objectField("value");
            try stringify.write(if (thread.fast_mode == .on) "true" else "false");
            try stringify.endObject();
            wrote_any = true;
        }

        try stringify.endArray();
        if (!wrote_any) {
            writer.deinit();
            return null;
        }
        return try writer.toOwnedSlice();
    }

    fn normalizeOpencodeReasoningVariant(self: *AppState, thread: *ChatThread) void {
        if (thread.provider != .opencode) return;
        if (thread.opencode_reasoning_variant) |cur| {
            const opt = self.opencodeModelOptionForRef(thread.model_ref) orelse {
                self.allocator.free(cur);
                thread.opencode_reasoning_variant = null;
                return;
            };
            if (!opt.reasoning_supported) {
                self.allocator.free(cur);
                thread.opencode_reasoning_variant = null;
                return;
            }
            const keys = opt.reasoning_variant_keys orelse {
                self.allocator.free(cur);
                thread.opencode_reasoning_variant = null;
                return;
            };
            if (keys.len == 0) {
                self.allocator.free(cur);
                thread.opencode_reasoning_variant = null;
                return;
            }
            for (keys) |k| {
                if (std.mem.eql(u8, cur, k)) return;
            }
            self.allocator.free(cur);
            thread.opencode_reasoning_variant = null;
        }
    }

    fn clearDynamicOpencodeModelOptions(self: *AppState) void {
        for (self.opencode_model_options.items) |option| {
            self.allocator.free(option.label);
            if (option.value) |value| self.allocator.free(value);
            if (option.reasoning_variant_keys) |keys| {
                for (keys) |k| self.allocator.free(k);
                self.allocator.free(keys);
            }
        }
        self.opencode_model_options.clearRetainingCapacity();
        self.clearOpencodeReasoningMenu();
    }

    fn clearOpencodeReasoningMenu(self: *AppState) void {
        for (self.opencode_reasoning_menu.items) |row| {
            self.allocator.free(row.label);
            if (row.variant) |v| self.allocator.free(v);
        }
        self.opencode_reasoning_menu.clearRetainingCapacity();
    }

    fn clearOpencodeModelOptions(self: *AppState) void {
        self.clearDynamicOpencodeModelOptions();
    }

    fn clearDynamicCursorModelOptions(self: *AppState) void {
        for (self.cursor_model_options.items) |option| {
            self.allocator.free(option.label);
            if (option.value) |value| self.allocator.free(value);
            if (option.reasoning_variant_keys) |keys| {
                for (keys) |k| self.allocator.free(k);
                self.allocator.free(keys);
            }
            if (option.cursor_reasoning_param_id) |param_id| self.allocator.free(param_id);
            if (option.cursor_reasoning_values) |values| {
                for (values) |value| self.allocator.free(value);
                self.allocator.free(values);
            }
        }
        self.cursor_model_options.clearRetainingCapacity();
    }

    fn clearDynamicClaudeModelOptions(self: *AppState) void {
        for (self.claude_model_options.items) |option| {
            self.allocator.free(option.label);
            if (option.value) |value| self.allocator.free(value);
            if (option.reasoning_variant_keys) |keys| {
                for (keys) |k| self.allocator.free(k);
                self.allocator.free(keys);
            }
            if (option.claude_effort_values) |values| {
                for (values) |value| self.allocator.free(value);
                self.allocator.free(values);
            }
        }
        self.claude_model_options.clearRetainingCapacity();
    }

    fn clearClaudeModelOptions(self: *AppState) void {
        self.clearDynamicClaudeModelOptions();
    }

    fn clearCursorModelOptions(self: *AppState) void {
        self.clearDynamicCursorModelOptions();
    }

    fn loadCursorModelOptionsDiskCache(self: *AppState) !void {
        var threaded: std.Io.Threaded = .init(self.allocator, .{});
        defer threaded.deinit();
        var dir = try std.Io.Dir.openDirAbsolute(threaded.io(), self.storage.pref_path, .{});
        defer dir.close(threaded.io());

        const bytes = dir.readFileAlloc(threaded.io(), CURSOR_MODEL_CACHE_FILE_NAME, self.allocator, .limited(512 * 1024)) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer self.allocator.free(bytes);

        var parsed = try std.json.parseFromSlice([]PersistedCursorModelOption, self.allocator, bytes, .{
            .allocate = .alloc_always,
        });
        defer parsed.deinit();

        if (persistedCursorModelCacheNeedsRefresh(parsed.value)) return;

        self.clearCursorModelOptions();
        errdefer self.clearCursorModelOptions();
        for (parsed.value) |option| {
            if (option.label.len == 0 or option.value.len == 0) continue;
            const label = try self.allocator.dupeZ(u8, option.label);
            errdefer self.allocator.free(label);
            const value = try self.allocator.dupeZ(u8, option.value);
            errdefer self.allocator.free(value);
            const reasoning_param_id = if (option.reasoning_param_id) |param_id| try self.allocator.dupeZ(u8, param_id) else null;
            errdefer if (reasoning_param_id) |param_id| self.allocator.free(param_id);
            const reasoning_values = if (option.reasoning_values) |values| blk: {
                const out = try self.allocator.alloc([:0]const u8, values.len);
                errdefer {
                    for (out) |v| self.allocator.free(v);
                    self.allocator.free(out);
                }
                for (values, 0..) |v, i| out[i] = try self.allocator.dupeZ(u8, v);
                break :blk out;
            } else null;
            errdefer if (reasoning_values) |values| {
                for (values) |v| self.allocator.free(v);
                self.allocator.free(values);
            };
            try self.cursor_model_options.append(self.allocator, .{
                .label = label,
                .value = value,
                .cursor_fast_supported = option.fast_supported,
                .cursor_reasoning_param_id = reasoning_param_id,
                .cursor_reasoning_values = reasoning_values,
                .cursor_reasoning_requires_thinking = option.reasoning_requires_thinking,
            });
        }
    }

    fn saveCursorModelOptionsDiskCache(self: *AppState) !void {
        if (self.cursor_model_options.items.len == 0) return;

        var persisted: std.ArrayList(PersistedCursorModelOption) = .empty;
        defer persisted.deinit(self.allocator);
        for (self.cursor_model_options.items) |option| {
            const value = option.value orelse continue;
            try persisted.append(self.allocator, .{
                .label = std.mem.sliceTo(option.label, 0),
                .value = std.mem.sliceTo(value, 0),
                .fast_supported = option.cursor_fast_supported,
                .reasoning_param_id = if (option.cursor_reasoning_param_id) |param_id| std.mem.sliceTo(param_id, 0) else null,
                .reasoning_values = if (option.cursor_reasoning_values) |values| blk: {
                    const out = try self.allocator.alloc([]const u8, values.len);
                    for (values, 0..) |v, i| out[i] = std.mem.sliceTo(v, 0);
                    break :blk out;
                } else null,
                .reasoning_requires_thinking = option.cursor_reasoning_requires_thinking,
            });
        }
        defer {
            for (persisted.items) |option| {
                if (option.reasoning_values) |values| self.allocator.free(values);
            }
        }
        if (persisted.items.len == 0) return;

        const json = try std.json.Stringify.valueAlloc(self.allocator, persisted.items, .{ .whitespace = .minified });
        defer self.allocator.free(json);

        const path = try std.fs.path.join(self.allocator, &.{ self.storage.pref_path, CURSOR_MODEL_CACHE_FILE_NAME });
        defer self.allocator.free(path);

        var threaded: std.Io.Threaded = .init(self.allocator, .{});
        defer threaded.deinit();
        var file = try std.Io.Dir.createFileAbsolute(threaded.io(), path, .{ .truncate = true });
        defer file.close(threaded.io());
        try file.writeStreamingAll(threaded.io(), json);
    }

    const AddProjectResult = enum {
        created,
        restored,
    };

    pub const CreateProjectResult = struct {
        index: usize,
        restored: bool,
    };

    fn addProject(self: *AppState, label: []const u8, path: []const u8, unread_count: u8) !AddProjectResult {
        const id = try self.deriveProjectId(path);
        defer self.allocator.free(id);
        if (self.findArchivedProjectIndexByPath(path)) |archived_index| {
            try self.restoreClosedProject(archived_index, unread_count);
            return .restored;
        }
        var project = try Project.init(self.allocator, id, label, path, unread_count);
        project.applyDefaultTerminalFontSize(self.app_config.terminal_font_size);
        try self.projects.append(self.allocator, project);
        self.markDirty();
        return .created;
    }

    pub fn createProjectFromPath(self: *AppState, raw_path: []const u8) !CreateProjectResult {
        const trimmed = std.mem.trim(u8, raw_path, &std.ascii.whitespace);
        if (trimmed.len == 0) return error.EmptyProjectPath;

        const resolved = try self.resolveProjectPath(trimmed);
        defer self.allocator.free(resolved);

        if (self.findProjectIndexByPath(resolved) != null) return error.ProjectAlreadyExists;

        const label = utils.projectLabelFromPath(resolved);
        const add_result = try self.addProject(label, resolved, 0);
        const index = self.projects.items.len - 1;
        self.selected_project_index = index;
        self.syncRenameBuffer();
        self.show_project_creator = false;
        self.palette_modal_text_focus = .none;
        self.setSidebarNotice(if (add_result == .restored) "Workspace reopened." else "Workspace imported.");
        self.markDirty();
        return .{
            .index = index,
            .restored = add_result == .restored,
        };
    }

    pub fn createProjectDirectoryFromInput(self: *AppState) !void {
        const trimmed = std.mem.trim(u8, self.importDirectoryDraft(), &std.ascii.whitespace);
        if (trimmed.len == 0) {
            self.browseForProjectDirectoryCreateParent();
            return;
        }

        if (self.resolveProjectPath(trimmed)) |existing| {
            defer self.allocator.free(existing);
            try self.setImportPathWithTrailingSeparator(existing);
            self.project_import_cursor = self.importDirectoryDraft().len;
            self.palette_modal_text_focus = .project_import;
            self.setSidebarNotice("Type the new folder name, then Create directory.");
            self.markDirty();
            return;
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        }

        const created = self.ensureDirectoryPath(trimmed) catch |err| switch (err) {
            error.EmptyProjectPath => {
                self.setSidebarNotice("Enter a workspace directory path first.");
                return;
            },
            else => return err,
        };
        defer self.allocator.free(created);
        self.setSidebarNotice("Directory created. Adding workspace...");
        try self.importProjectFromInput();
    }

    pub fn consumePendingHerdrOpenRequest(self: *AppState) !bool {
        var threaded: std.Io.Threaded = .init(self.allocator, .{});
        defer threaded.deinit();
        var loaded = try herdr.readPendingOpen(self.allocator, threaded.io(), self.storage.pref_path) orelse return false;
        defer loaded.deinit();
        herdr.deletePendingOpen(self.allocator, threaded.io(), self.storage.pref_path);
        _ = try self.openOrCreateHerdrWorkspace(loaded.value);
        return true;
    }

    pub fn openOrCreateHerdrWorkspace(self: *AppState, request: herdr.OpenRequest) !HerdrOpenResult {
        try herdr.validateOpenRequest(request);
        const remote_alias = herdr.remoteAlias(request);
        var created = false;
        var restored = false;

        const project_index = if (self.findHerdrProjectIndex(request)) |index| index else blk: {
            const local_dir = try self.resolveHerdrLocalProjectDir(request);
            defer self.allocator.free(local_dir);
            if (self.findProjectIndexByPath(local_dir)) |index| {
                break :blk index;
            }
            const result = try self.createProjectFromPath(local_dir);
            created = !result.restored;
            restored = result.restored;
            break :blk result.index;
        };

        self.selected_project_index = project_index;
        self.ensureCurrentProjectWorkspace();
        const local_dir_for_link = self.projects.items[project_index].path;
        try self.replaceProjectHerdrLink(project_index, request, local_dir_for_link, null, null);
        self.syncRenameBuffer();
        self.setSidebarNotice(if (remote_alias.len > 0) "Remote Herdr workspace opened." else "Herdr workspace opened.");
        self.markDirty();

        const project = &self.projects.items[project_index];
        const link = project.herdr_link;
        return .{
            .workspace_index = project_index,
            .workspace_id = project.id,
            .workspace_path = project.path,
            .created = created,
            .restored = restored,
            .remote = remote_alias,
            .session = request.session,
            .herdr_workspace = request.herdr_workspace,
            .herdr_pane = request.pane,
            .terminal_dock_id = if (link) |value| value.attach_dock_id else null,
            .terminal_pane_id = if (link) |value| value.attach_pane_id else null,
        };
    }

    pub fn handoffHerdrWorkspaces(self: *AppState, result_allocator: std.mem.Allocator, request: herdr.HandoffRequest) !HerdrHandoffResult {
        try herdr.validateHandoffRequest(request);
        if (self.projects.items.len == 0) return .{ .dry_run = request.dry_run, .workspace_count = 0, .workspaces = &.{} };

        var results: std.ArrayList(HerdrHandoffWorkspaceResult) = .empty;
        errdefer results.deinit(result_allocator);

        if (request.all or request.workspace == null) {
            for (self.projects.items, 0..) |_, project_index| {
                try results.append(result_allocator, try self.handoffProjectToHerdr(project_index, request));
            }
        } else {
            const project_index = self.herdrHandoffProjectIndex(request.workspace.?) orelse return error.NoProjectSelected;
            try results.append(result_allocator, try self.handoffProjectToHerdr(project_index, request));
        }

        if (!request.dry_run) {
            self.setSidebarNotice("Handed Verde workspace layout to Herdr.");
            self.markDirty();
        }

        const owned = try results.toOwnedSlice(result_allocator);
        return .{
            .dry_run = request.dry_run,
            .workspace_count = owned.len,
            .workspaces = owned,
        };
    }

    pub fn unlinkHerdrWorkspaces(self: *AppState, result_allocator: std.mem.Allocator, request: herdr.UnlinkRequest) !HerdrUnlinkResult {
        try herdr.validateUnlinkRequest(request);
        if (self.projects.items.len == 0) return .{ .workspace_count = 0, .workspaces = &.{} };

        var results: std.ArrayList(HerdrUnlinkWorkspaceResult) = .empty;
        errdefer {
            for (results.items) |workspace| workspace.deinit(result_allocator);
            results.deinit(result_allocator);
        }

        if (request.all) {
            for (self.projects.items, 0..) |project, project_index| {
                if (project.herdr_link == null) continue;
                try self.appendHerdrUnlinkResult(result_allocator, &results, project_index);
            }
        } else {
            const selector = request.workspace orelse "current";
            const project_index = self.herdrHandoffProjectIndex(selector) orelse return error.NoProjectSelected;
            try self.appendHerdrUnlinkResult(result_allocator, &results, project_index);
        }

        var unlinked_count: usize = 0;
        for (results.items) |result| {
            if (result.unlinked) unlinked_count += 1;
        }
        if (unlinked_count > 0) {
            self.setSidebarNotice(if (unlinked_count == 1) "Herdr link removed; workspace now runs locally." else "Herdr links removed; workspaces now run locally.");
            self.markDirty();
        }

        const owned = try results.toOwnedSlice(result_allocator);
        return .{
            .workspace_count = owned.len,
            .workspaces = owned,
        };
    }

    pub fn handoffProjectToLocalHerdrFromUi(self: *AppState, project_index: usize) void {
        if (project_index >= self.projects.items.len) {
            self.setSidebarNotice("Workspace not found.");
            return;
        }
        const request: herdr.HandoffRequest = .{
            .session = if (self.projects.items[project_index].herdr_link) |link| link.session_name else "default",
            .workspace = self.projects.items[project_index].id,
            .all = false,
        };
        var result = self.handoffHerdrWorkspaces(self.allocator, request) catch |err| {
            self.setSidebarNotice(herdrUiFailureMessage(err));
            return;
        };
        defer result.deinit(self.allocator);
        self.setSidebarNotice("Workspace handed off to Herdr.");
    }

    pub fn unlinkProjectHerdrFromUi(self: *AppState, project_index: usize) void {
        if (project_index >= self.projects.items.len) {
            self.setSidebarNotice("Workspace not found.");
            return;
        }
        const request: herdr.UnlinkRequest = .{
            .workspace = self.projects.items[project_index].id,
            .all = false,
        };
        var result = self.unlinkHerdrWorkspaces(self.allocator, request) catch |err| {
            self.setSidebarNotice(herdrUiFailureMessage(err));
            return;
        };
        defer result.deinit(self.allocator);
        if (result.workspace_count == 0 or (result.workspaces.len > 0 and !result.workspaces[0].unlinked)) {
            self.setSidebarNotice("Workspace is already running locally.");
        }
    }

    pub fn focusProjectHerdrAttachTerminal(self: *AppState, project_index: usize) bool {
        if (project_index >= self.projects.items.len) return false;
        var project = &self.projects.items[project_index];
        const link = project.herdr_link orelse {
            self.setSidebarNotice("Workspace is not linked to Herdr.");
            return false;
        };
        const dock_id = link.attach_dock_id orelse {
            return self.openLinkedHerdrWorkspaceTerminalFromUi(project_index);
        };
        const pane_id = link.attach_pane_id orelse project.workspace_layout.visibleTerminalPaneIdForDock(dock_id) orelse {
            return self.openLinkedHerdrWorkspaceTerminalFromUi(project_index);
        };
        if (project.workspace_layout.paneById(pane_id) == null) {
            return self.openLinkedHerdrWorkspaceTerminalFromUi(project_index);
        }
        self.selected_project_index = project_index;
        self.ensureCurrentProjectWorkspace();
        project = &self.projects.items[project_index];
        project.workspace_layout.focused_pane_id = pane_id;
        project.workspace_layout.maximized_pane_id = null;
        self.requestTerminalDockFocus(dock_id);
        self.syncRenameBuffer();
        self.markDirty();
        return true;
    }

    fn appendHerdrUnlinkResult(
        self: *AppState,
        result_allocator: std.mem.Allocator,
        results: *std.ArrayList(HerdrUnlinkWorkspaceResult),
        project_index: usize,
    ) !void {
        var result = try self.snapshotHerdrUnlinkResult(result_allocator, project_index);
        var result_owned = true;
        errdefer if (result_owned) result.deinit(result_allocator);
        try results.append(result_allocator, result);
        result_owned = false;
        if (result.unlinked) self.clearProjectHerdrLink(project_index);
    }

    fn snapshotHerdrUnlinkResult(self: *AppState, result_allocator: std.mem.Allocator, project_index: usize) !HerdrUnlinkWorkspaceResult {
        if (project_index >= self.projects.items.len) return error.NoProjectSelected;
        const project = &self.projects.items[project_index];
        const previous = if (project.herdr_link) |link| try HerdrUnlinkPreviousLink.init(result_allocator, link) else null;
        errdefer if (previous) |value| value.deinit(result_allocator);
        return .{
            .workspace_index = project_index,
            .workspace_id = project.id,
            .label = project.label,
            .path = project.path,
            .unlinked = previous != null,
            .previous = previous,
        };
    }

    fn clearProjectHerdrLink(self: *AppState, project_index: usize) void {
        var project = &self.projects.items[project_index];
        if (project.herdr_link) |*link| {
            link.deinit(self.allocator);
            project.herdr_link = null;
        }
    }

    fn openLinkedHerdrWorkspaceTerminalFromUi(self: *AppState, project_index: usize) bool {
        if (project_index >= self.projects.items.len) return false;
        const project = &self.projects.items[project_index];
        const link = project.herdr_link orelse {
            self.setSidebarNotice("Workspace is not linked to Herdr.");
            return false;
        };
        const request: herdr.OpenRequest = .{
            .session = link.session_name,
            .herdr_workspace = link.workspace_id,
            .remote = if (link.remote_alias.len > 0) link.remote_alias else null,
            .cwd = if (link.remote_alias.len == 0) project.path else null,
            .remote_cwd = link.remote_cwd,
            .local_dir = project.path,
            .pane = link.last_pane_id,
        };
        const attach = self.ensureHerdrAttachTerminal(project_index, request) catch |err| {
            self.setSidebarNotice(herdrUiFailureMessage(err));
            return false;
        };
        self.replaceProjectHerdrLink(project_index, request, project.path, attach.dock_id, attach.pane_id) catch |err| {
            self.setSidebarNotice(herdrUiFailureMessage(err));
            return false;
        };
        self.syncRenameBuffer();
        self.setSidebarNotice("Herdr terminal opened.");
        self.markDirty();
        return true;
    }

    fn herdrUiFailureMessage(err: anyerror) []const u8 {
        return switch (err) {
            error.HerdrCommandFailed => "Herdr command failed. Check Herdr is installed/running.",
            error.InvalidHerdrResponse => "Herdr returned an unexpected response.",
            error.NoProjectSelected => "Workspace not found.",
            error.MissingHerdrSession => "Herdr session name is required.",
            else => "Herdr action failed.",
        };
    }

    fn handoffProjectToHerdr(self: *AppState, project_index: usize, request: herdr.HandoffRequest) !HerdrHandoffWorkspaceResult {
        if (project_index >= self.projects.items.len) return error.NoProjectSelected;
        var project = &self.projects.items[project_index];
        const existing_link = project.herdr_link;
        const remote_alias = request.remote orelse if (existing_link) |link| link.remote_alias else "";
        const session_name = if (existing_link) |link| link.session_name else request.session;
        var default_remote_cwd: ?[]u8 = null;
        defer if (default_remote_cwd) |cwd| self.allocator.free(cwd);
        const remote_cwd = if (remote_alias.len > 0) blk: {
            if (request.remote_cwd) |cwd| break :blk cwd;
            if (existing_link) |link| {
                if (link.remote_cwd) |cwd| {
                    // Earlier builds used the local project path as the
                    // implicit remote cwd. Treat that as unset so existing
                    // links migrate to Verde's remote workspace area.
                    if (!std.mem.eql(u8, cwd, project.path)) break :blk cwd;
                }
            }
            default_remote_cwd = try herdr.defaultRemoteCwd(self.allocator, project.label, project.id);
            break :blk default_remote_cwd.?;
        } else null;
        const herdr_cwd = remote_cwd orelse project.path;

        if (request.dry_run) {
            const workspace_id = if (existing_link) |link| link.workspace_id else "(new)";
            return .{
                .workspace_index = project_index,
                .workspace_id = project.id,
                .label = project.label,
                .path = project.path,
                .remote = remote_alias,
                .session = session_name,
                .herdr_workspace = workspace_id,
                .herdr_tab = null,
                .created = existing_link == null,
                .pane_count = project.workspace_layout.visiblePaneCount(),
            };
        }

        const target: herdr.CliTarget = .{
            .session = session_name,
            .remote = if (remote_alias.len > 0) remote_alias else null,
        };
        if (remote_alias.len > 0) try self.ensureHerdrRemoteCwd(target, herdr_cwd);
        var workspace = if (existing_link) |link|
            try self.createHerdrMirrorTab(target, link.workspace_id, project.label, herdr_cwd)
        else
            try self.createHerdrWorkspace(target, project.label, herdr_cwd);
        defer workspace.deinit(self.allocator);

        var next_links: std.ArrayList(HerdrPaneLink) = .empty;
        var next_links_owned = true;
        errdefer if (next_links_owned) {
            for (next_links.items) |*pane_link| pane_link.deinit(self.allocator);
            next_links.deinit(self.allocator);
        };

        if (project.workspace_layout.root) |root_node| {
            try self.mirrorHerdrNode(project_index, target, root_node, workspace.root_pane_id, workspace.tab_id, herdr_cwd, &next_links);
        }

        const open_request: herdr.OpenRequest = .{
            .session = session_name,
            .herdr_workspace = workspace.workspace_id,
            .remote = if (remote_alias.len > 0) remote_alias else null,
            .cwd = if (remote_alias.len == 0) project.path else null,
            .remote_cwd = remote_cwd,
            .local_dir = project.path,
            .pane = workspace.root_pane_id,
        };
        try self.replaceProjectHerdrLink(project_index, open_request, project.path, null, null);
        project = &self.projects.items[project_index];
        if (project.herdr_link) |*link| {
            link.replacePaneLinks(self.allocator, &next_links);
            next_links_owned = false;
        }
        const final_link = project.herdr_link.?;

        return .{
            .workspace_index = project_index,
            .workspace_id = project.id,
            .label = project.label,
            .path = project.path,
            .remote = final_link.remote_alias,
            .session = final_link.session_name,
            .herdr_workspace = final_link.workspace_id,
            .herdr_tab = null,
            .created = workspace.created,
            .pane_count = final_link.pane_links.items.len,
        };
    }

    const HerdrWorkspaceBootstrap = struct {
        workspace_id: []u8,
        tab_id: ?[]u8 = null,
        root_pane_id: []u8,
        created: bool,

        fn deinit(self: *HerdrWorkspaceBootstrap, allocator: std.mem.Allocator) void {
            allocator.free(self.workspace_id);
            if (self.tab_id) |tab_id| allocator.free(tab_id);
            allocator.free(self.root_pane_id);
        }
    };

    fn createHerdrWorkspace(self: *AppState, target: herdr.CliTarget, label: []const u8, cwd: []const u8) !HerdrWorkspaceBootstrap {
        const cli_args = [_][]const u8{ "workspace", "create", "--cwd", cwd, "--label", label, "--no-focus" };
        const result = try self.runHerdrCli(target, &cli_args);
        defer self.freeHerdrRunResult(result);
        try self.ensureHerdrCliSuccess(result, "workspace create");
        return .{
            .workspace_id = try parseHerdrJsonStringAlloc(self.allocator, result.stdout, "workspace_id"),
            .tab_id = try parseHerdrJsonStringAlloc(self.allocator, result.stdout, "tab_id"),
            .root_pane_id = try parseHerdrJsonStringAlloc(self.allocator, result.stdout, "pane_id"),
            .created = true,
        };
    }

    fn createHerdrMirrorTab(self: *AppState, target: herdr.CliTarget, workspace_id: []const u8, label: []const u8, cwd: []const u8) !HerdrWorkspaceBootstrap {
        const tab_label = try std.fmt.allocPrint(self.allocator, "Verde: {s}", .{label});
        defer self.allocator.free(tab_label);
        const cli_args = [_][]const u8{ "tab", "create", "--workspace", workspace_id, "--cwd", cwd, "--label", tab_label, "--no-focus" };
        const result = try self.runHerdrCli(target, &cli_args);
        defer self.freeHerdrRunResult(result);
        try self.ensureHerdrCliSuccess(result, "tab create");
        return .{
            .workspace_id = try self.allocator.dupe(u8, workspace_id),
            .tab_id = try parseHerdrJsonStringAlloc(self.allocator, result.stdout, "tab_id"),
            .root_pane_id = try parseHerdrJsonStringAlloc(self.allocator, result.stdout, "pane_id"),
            .created = false,
        };
    }

    fn mirrorHerdrNode(
        self: *AppState,
        project_index: usize,
        target: herdr.CliTarget,
        node: *const WorkspaceNode,
        herdr_pane_id: []const u8,
        herdr_tab_id: ?[]const u8,
        cwd: []const u8,
        links: *std.ArrayList(HerdrPaneLink),
    ) !void {
        switch (node.*) {
            .leaf => |verde_pane_id| try self.configureHerdrPaneForVerdePane(project_index, target, verde_pane_id, herdr_tab_id, herdr_pane_id, cwd, links),
            .split => |split| {
                const ratio_text = try std.fmt.allocPrint(self.allocator, "{d}", .{std.math.clamp(split.ratio, 0.05, 0.95)});
                defer self.allocator.free(ratio_text);
                const direction = switch (split.axis) {
                    .vertical => "right",
                    .horizontal => "down",
                };
                const cli_args = [_][]const u8{ "pane", "split", herdr_pane_id, "--direction", direction, "--ratio", ratio_text, "--cwd", cwd, "--no-focus" };
                const result = try self.runHerdrCli(target, &cli_args);
                defer self.freeHerdrRunResult(result);
                try self.ensureHerdrCliSuccess(result, "pane split");
                const second_pane_id = try parseHerdrJsonStringAlloc(self.allocator, result.stdout, "pane_id");
                defer self.allocator.free(second_pane_id);
                try self.mirrorHerdrNode(project_index, target, split.first, herdr_pane_id, herdr_tab_id, cwd, links);
                try self.mirrorHerdrNode(project_index, target, split.second, second_pane_id, herdr_tab_id, cwd, links);
            },
        }
    }

    fn configureHerdrPaneForVerdePane(
        self: *AppState,
        project_index: usize,
        target: herdr.CliTarget,
        verde_pane_id: WorkspacePaneId,
        herdr_tab_id: ?[]const u8,
        herdr_pane_id: []const u8,
        default_cwd: []const u8,
        links: *std.ArrayList(HerdrPaneLink),
    ) !void {
        const project = &self.projects.items[project_index];
        const pane = project.workspace_layout.paneById(verde_pane_id) orelse return;
        if (pane.minimized) return;

        const descriptor = try self.herdrPaneDescriptor(project_index, pane, default_cwd);
        defer descriptor.deinit(self.allocator);
        var link = try HerdrPaneLink.init(
            self.allocator,
            verde_pane_id,
            herdr_tab_id,
            herdr_pane_id,
            descriptor.provider,
            descriptor.presentation,
            descriptor.provider_thread_id,
            null,
            descriptor.cwd,
            descriptor.title,
        );
        errdefer link.deinit(self.allocator);
        try links.append(self.allocator, link);

        try self.renameHerdrPane(target, herdr_pane_id, descriptor.title);
        if (descriptor.command) |command| try self.runHerdrPaneCommand(target, herdr_pane_id, command);
    }

    const HerdrPaneDescriptor = struct {
        provider: HerdrPaneProvider,
        presentation: HerdrPanePresentation,
        provider_thread_id: ?[]const u8 = null,
        cwd: []const u8,
        title: []u8,
        command: ?[]u8 = null,

        fn deinit(self: HerdrPaneDescriptor, allocator: std.mem.Allocator) void {
            allocator.free(self.title);
            if (self.command) |command| allocator.free(command);
        }
    };

    fn herdrPaneDescriptor(self: *AppState, project_index: usize, pane: *const WorkspacePane, default_cwd: []const u8) !HerdrPaneDescriptor {
        const project = &self.projects.items[project_index];
        return switch (pane.ref) {
            .chat => |chat_ref| blk: {
                const maybe_thread = if (chat_ref.thread_index < project.threads.items.len) &project.threads.items[chat_ref.thread_index] else null;
                const provider = if (maybe_thread) |thread| herdrPaneProviderForThreadProvider(thread.provider) else .unknown;
                const thread_title = if (maybe_thread) |thread| thread.title else "Chat";
                const title = try std.fmt.allocPrint(self.allocator, "{s} GUI", .{thread_title});
                errdefer self.allocator.free(title);
                const provider_thread_id = if (maybe_thread) |thread| thread.provider_thread_id else null;
                const command = try herdrAgentCommandForProvider(self.allocator, provider, provider_thread_id);
                break :blk .{
                    .provider = provider,
                    .presentation = .gui_chat,
                    .provider_thread_id = provider_thread_id,
                    .cwd = default_cwd,
                    .title = title,
                    .command = command,
                };
            },
            .terminal => |terminal_ref| blk: {
                const dock = self.projectTerminalDock(project_index, terminal_ref.dock_id);
                const cwd = if (dock) |value| value.cwd orelse default_cwd else default_cwd;
                const title = try std.fmt.allocPrint(self.allocator, "Terminal {d}", .{terminal_ref.dock_id});
                break :blk .{ .provider = .terminal, .presentation = .terminal, .cwd = cwd, .title = title };
            },
            .browser => |browser_ref| blk: {
                const label = browser_ref.title orelse browser_ref.url orelse "Browser";
                const title = try std.fmt.allocPrint(self.allocator, "Browser: {s}", .{label});
                break :blk .{ .provider = .browser, .presentation = .browser_link, .cwd = default_cwd, .title = title };
            },
        };
    }

    fn herdrHandoffProjectIndex(self: *const AppState, selector: []const u8) ?usize {
        if (std.mem.eql(u8, selector, "current")) return self.selected_project_index;
        if (std.fmt.parseInt(usize, selector, 10)) |index| {
            if (index < self.projects.items.len) return index;
        } else |_| {}
        for (self.projects.items, 0..) |project, index| {
            if (std.mem.eql(u8, project.id, selector) or
                self.projectPathMatches(project.path, selector) or
                std.mem.eql(u8, project.label, selector)) return index;
        }
        return null;
    }

    fn runHerdrCli(self: *AppState, target: herdr.CliTarget, cli_args: []const []const u8) !std.process.RunResult {
        var threaded: std.Io.Threaded = .init(self.allocator, .{});
        defer threaded.deinit();
        return try herdr.runCli(self.allocator, threaded.io(), target, cli_args, 512 * 1024);
    }

    fn ensureHerdrRemoteCwd(self: *AppState, target: herdr.CliTarget, cwd: []const u8) !void {
        const remote = target.remote orelse return;
        const command = try herdr.remoteMkdirCommandLineAlloc(self.allocator, cwd);
        defer self.allocator.free(command);
        var threaded: std.Io.Threaded = .init(self.allocator, .{});
        defer threaded.deinit();
        const result = try herdr.runRemoteShell(self.allocator, threaded.io(), remote, .{ .bytes = command }, 64 * 1024);
        defer self.freeHerdrRunResult(result);
        try self.ensureHerdrCliSuccess(result, "remote mkdir");
    }

    fn remoteCwdForWorkspaceCwd(self: *AppState, project: *const Project, cwd: []const u8) ![]u8 {
        const link = project.herdr_link orelse return error.WorkspaceNotRemote;
        const base = link.remote_cwd orelse return error.MissingRemoteCwd;
        const trimmed = std.mem.trim(u8, cwd, &std.ascii.whitespace);
        if (trimmed.len == 0 or std.mem.eql(u8, trimmed, ".") or std.mem.eql(u8, trimmed, project.path)) {
            return try self.allocator.dupe(u8, base);
        }
        if (std.mem.startsWith(u8, trimmed, project.path) and trimmed.len > project.path.len and trimmed[project.path.len] == std.fs.path.sep) {
            return try std.fs.path.join(self.allocator, &.{ base, trimmed[project.path.len + 1 ..] });
        }
        if (std.fs.path.isAbsolute(trimmed)) return try self.allocator.dupe(u8, trimmed);
        return try std.fs.path.join(self.allocator, &.{ base, trimmed });
    }

    fn commandArgsForTerminalProfile(profile: terminal.TerminalLaunchProfile) ?[]const []const u8 {
        if (profile.command.len > 0) return profile.command;
        return switch (profile.kind) {
            .shell => null,
            .claude => &.{"claude"},
            .opencode => &.{"opencode"},
            .codex => &.{"codex"},
            .cursor => &.{"cursor"},
            .custom => &.{},
        };
    }

    fn remoteTerminalLabel(link: HerdrWorkspaceLink, profile: terminal.TerminalLaunchProfile, buffer: []u8) []const u8 {
        const label = std.mem.trim(u8, profile.label, &std.ascii.whitespace);
        if (label.len > 0) return label;
        return std.fmt.bufPrint(buffer, "Remote {s}", .{link.remote_alias}) catch "Remote terminal";
    }

    fn remoteCommandForTerminalProfile(
        self: *AppState,
        project: *const Project,
        profile: terminal.TerminalLaunchProfile,
        cwd: []const u8,
    ) ![]u8 {
        const link = project.herdr_link orelse return error.WorkspaceNotRemote;
        if (link.remote_alias.len == 0) return error.WorkspaceNotRemote;
        const remote_cwd = try self.remoteCwdForWorkspaceCwd(project, cwd);
        defer self.allocator.free(remote_cwd);
        if (commandArgsForTerminalProfile(profile)) |args| {
            return try herdr.remoteExecCommandLineAlloc(self.allocator, remote_cwd, args);
        }
        return try herdr.remoteLoginShellCommandLineAlloc(self.allocator, remote_cwd);
    }

    fn restartTerminalDockForWorkspaceProfile(
        self: *AppState,
        project_index: usize,
        dock_id: u32,
        cwd: []const u8,
        profile: terminal.TerminalLaunchProfile,
    ) !void {
        if (project_index >= self.projects.items.len) return error.NoProjectSelected;
        const project = &self.projects.items[project_index];
        var dock = self.projectTerminalDockMutable(project_index, dock_id) orelse return error.NoProjectSelected;
        if (project.herdr_link) |link| {
            if (link.remote_alias.len > 0) {
                const remote_command = try self.remoteCommandForTerminalProfile(project, profile, cwd);
                defer self.allocator.free(remote_command);
                var label_buf: [160]u8 = undefined;
                const label = remoteTerminalLabel(link, profile, &label_buf);
                const command_args = [_][]const u8{ "ssh", "-tt", link.remote_alias, remote_command };
                try dock.restartWithProfilePersistent(self.allocator, project.path, .{
                    .kind = .custom,
                    .label = label,
                    .command = &command_args,
                }, self.storage.pref_path, dock_id);
                return;
            }
        }
        try dock.restartWithProfilePersistent(self.allocator, cwd, profile, self.storage.pref_path, dock_id);
    }

    fn restartTerminalDockForWorkspace(self: *AppState, project_index: usize, dock_id: u32) !void {
        if (project_index >= self.projects.items.len) return error.NoProjectSelected;
        const project = &self.projects.items[project_index];
        try self.restartTerminalDockForWorkspaceProfile(project_index, dock_id, project.path, .{});
    }

    fn createTerminalTabForWorkspaceProfile(
        self: *AppState,
        project_index: usize,
        dock_id: u32,
        profile: terminal.TerminalLaunchProfile,
    ) !void {
        if (project_index >= self.projects.items.len) return error.NoProjectSelected;
        const project = &self.projects.items[project_index];
        var dock = self.projectTerminalDockMutable(project_index, dock_id) orelse return error.NoProjectSelected;
        if (project.herdr_link) |link| {
            if (link.remote_alias.len > 0) {
                const cwd = dock.cwd orelse project.path;
                const remote_command = try self.remoteCommandForTerminalProfile(project, profile, cwd);
                defer self.allocator.free(remote_command);
                var label_buf: [160]u8 = undefined;
                const label = remoteTerminalLabel(link, profile, &label_buf);
                const command_args = [_][]const u8{ "ssh", "-tt", link.remote_alias, remote_command };
                try dock.createTabWithProfile(self.allocator, .{
                    .kind = .custom,
                    .label = label,
                    .command = &command_args,
                });
                return;
            }
        }
        if (profile.kind == .shell and profile.label.len == 0 and profile.command.len == 0) {
            try dock.createTab(self.allocator);
        } else {
            try dock.createTabWithProfile(self.allocator, profile);
        }
    }

    fn freeHerdrRunResult(self: *AppState, result: std.process.RunResult) void {
        self.allocator.free(result.stdout);
        self.allocator.free(result.stderr);
    }

    fn ensureHerdrCliSuccess(self: *AppState, result: std.process.RunResult, action: []const u8) !void {
        _ = self;
        switch (result.term) {
            .exited => |code| if (code == 0) return,
            else => {},
        }
        log.warn("Herdr CLI {s} failed stderr_len={d}", .{ action, result.stderr.len });
        return error.HerdrCommandFailed;
    }

    fn renameHerdrPane(self: *AppState, target: herdr.CliTarget, pane_id: []const u8, title: []const u8) !void {
        const cli_args = [_][]const u8{ "pane", "rename", pane_id, title };
        const result = try self.runHerdrCli(target, &cli_args);
        defer self.freeHerdrRunResult(result);
        try self.ensureHerdrCliSuccess(result, "pane rename");
    }

    fn runHerdrPaneCommand(self: *AppState, target: herdr.CliTarget, pane_id: []const u8, command: []const u8) !void {
        const cli_args = [_][]const u8{ "pane", "run", pane_id, command };
        const result = try self.runHerdrCli(target, &cli_args);
        defer self.freeHerdrRunResult(result);
        try self.ensureHerdrCliSuccess(result, "pane run");
    }

    const HerdrAttachPane = struct {
        dock_id: u32,
        pane_id: WorkspacePaneId,
    };

    fn ensureHerdrAttachTerminal(self: *AppState, project_index: usize, request: herdr.OpenRequest) !HerdrAttachPane {
        if (project_index >= self.projects.items.len) return error.NoProjectSelected;
        var project = &self.projects.items[project_index];
        if (project.herdr_link) |link| {
            if (link.attach_dock_id) |dock_id| {
                if (self.projectTerminalDockMutable(project_index, dock_id)) |dock| {
                    const pane_id = link.attach_pane_id orelse project.workspace_layout.visibleTerminalPaneIdForDock(dock_id);
                    if (pane_id) |id| {
                        if (project.workspace_layout.paneById(id) != null) {
                            if (!dock.hasRunningSession()) try self.restartHerdrAttachDock(project_index, dock_id, request);
                            project = &self.projects.items[project_index];
                            project.workspace_layout.focused_pane_id = id;
                            project.workspace_layout.maximized_pane_id = null;
                            self.requestTerminalDockFocus(dock_id);
                            return .{ .dock_id = dock_id, .pane_id = id };
                        }
                    }
                }
            }
        }

        const dock_id = try self.createProjectTerminalDock(project_index);
        try self.restartHerdrAttachDock(project_index, dock_id, request);
        if (self.replaceOnlyDraftChatPaneWithTerminal(project_index, dock_id)) |pane_id| {
            self.requestTerminalDockFocus(dock_id);
            return .{ .dock_id = dock_id, .pane_id = pane_id };
        }

        project = &self.projects.items[project_index];
        const pane_id = try project.workspace_layout.ensureTerminalPane(self.allocator, dock_id);
        project.workspace_layout.maximized_pane_id = null;
        self.requestTerminalDockFocus(dock_id);
        return .{ .dock_id = dock_id, .pane_id = pane_id };
    }

    fn restartHerdrAttachDock(self: *AppState, project_index: usize, dock_id: u32, request: herdr.OpenRequest) !void {
        const project = &self.projects.items[project_index];
        var dock = self.projectTerminalDockMutable(project_index, dock_id) orelse return error.NoProjectSelected;
        const remote_alias = herdr.remoteAlias(request);
        const label = if (remote_alias.len > 0)
            try std.fmt.allocPrint(self.allocator, "Herdr {s}@{s}", .{ request.session, remote_alias })
        else
            try std.fmt.allocPrint(self.allocator, "Herdr {s}", .{request.session});
        defer self.allocator.free(label);

        if (remote_alias.len > 0) {
            const remote_command = try herdr.remoteHerdrCommandLineAlloc(self.allocator, request.session, &.{});
            defer self.allocator.free(remote_command);
            // Herdr's ratatui frontend opens the remote TTY directly; without
            // forced allocation it can panic with ENXIO even though Verde's
            // local side is already a PTY.
            const command_args = [_][]const u8{ "ssh", "-tt", remote_alias, remote_command };
            try dock.restartWithProfilePersistent(self.allocator, project.path, .{
                .kind = .custom,
                .label = label,
                .command = &command_args,
            }, self.storage.pref_path, dock_id);
        } else {
            const command_args = [_][]const u8{ "herdr", "--session", request.session };
            try dock.restartWithProfilePersistent(self.allocator, project.path, .{
                .kind = .custom,
                .label = label,
                .command = &command_args,
            }, self.storage.pref_path, dock_id);
        }
        dock.visible = false;
    }

    fn replaceOnlyDraftChatPaneWithTerminal(self: *AppState, project_index: usize, dock_id: u32) ?WorkspacePaneId {
        var project = &self.projects.items[project_index];
        var layout = &project.workspace_layout;
        if (layout.panes.items.len != 1) return null;
        var pane = &layout.panes.items[0];
        if (pane.minimized) return null;
        switch (pane.ref) {
            .chat => |chat_ref| {
                if (chat_ref.thread_index >= project.threads.items.len) return null;
                const thread = &project.threads.items[chat_ref.thread_index];
                if (thread.committed or thread.messages.items.len > 0 or thread.currentDraft().len > 0) return null;
                deinitWorkspacePaneRef(&pane.ref, self.allocator);
                pane.ref = .{ .terminal = .{ .dock_id = dock_id } };
                layout.focused_pane_id = pane.id;
                layout.maximized_pane_id = null;
                return pane.id;
            },
            else => return null,
        }
    }

    fn replaceProjectHerdrLink(
        self: *AppState,
        project_index: usize,
        request: herdr.OpenRequest,
        local_dir: []const u8,
        attach_dock_id: ?u32,
        attach_pane_id: ?WorkspacePaneId,
    ) !void {
        var project = &self.projects.items[project_index];
        const existing_dock_id = attach_dock_id orelse if (project.herdr_link) |link| link.attach_dock_id else null;
        const existing_pane_id = attach_pane_id orelse if (project.herdr_link) |link| link.attach_pane_id else null;
        var next = try HerdrWorkspaceLink.init(
            self.allocator,
            herdr.remoteAlias(request),
            request.session,
            request.herdr_workspace,
            local_dir,
            request.remote_cwd,
            request.pane,
            existing_dock_id,
            existing_pane_id,
        );
        errdefer next.deinit(self.allocator);
        if (project.herdr_link) |*old| {
            // `verde herdr open` is often a focus/pickup operation; preserve
            // pane presentation metadata so returning from Herdr still knows
            // which panes should come back as GUI chat versus terminal/TUI.
            if (herdrLinkMatchesRequest(old.*, request)) {
                next.pane_links = old.pane_links;
                old.pane_links = .empty;
            }
            old.deinit(self.allocator);
        }
        project.herdr_link = next;
    }

    fn findHerdrProjectIndex(self: *const AppState, request: herdr.OpenRequest) ?usize {
        for (self.projects.items, 0..) |project, index| {
            const link = project.herdr_link orelse continue;
            if (herdrLinkMatchesRequest(link, request)) return index;
        }
        return null;
    }

    fn herdrLinkMatchesRequest(link: HerdrWorkspaceLink, request: herdr.OpenRequest) bool {
        return std.mem.eql(u8, link.remote_alias, herdr.remoteAlias(request)) and
            std.mem.eql(u8, link.session_name, request.session) and
            std.mem.eql(u8, link.workspace_id, request.herdr_workspace);
    }

    fn resolveHerdrLocalProjectDir(self: *AppState, request: herdr.OpenRequest) ![]u8 {
        if (request.local_dir) |local_dir| return try self.ensureDirectoryPath(local_dir);
        if (herdr.remoteAlias(request).len > 0) {
            const default_dir = try herdr.defaultLocalDir(self.allocator, self.storage.pref_path, request);
            defer self.allocator.free(default_dir);
            return try self.ensureDirectoryPath(default_dir);
        }
        if (request.cwd) |cwd| return try self.resolveProjectPath(cwd);
        const default_dir = try herdr.defaultLocalDir(self.allocator, self.storage.pref_path, request);
        defer self.allocator.free(default_dir);
        return try self.ensureDirectoryPath(default_dir);
    }

    fn ensureDirectoryPath(self: *AppState, raw_path: []const u8) ![]u8 {
        const absolute = try self.absolutePathForCreate(raw_path);
        defer self.allocator.free(absolute);
        var threaded: std.Io.Threaded = .init(self.allocator, .{});
        defer threaded.deinit();
        try std.Io.Dir.cwd().createDirPath(threaded.io(), absolute);
        var dir = try std.Io.Dir.openDirAbsolute(threaded.io(), absolute, .{});
        dir.close(threaded.io());
        return try std.Io.Dir.realPathFileAbsoluteAlloc(threaded.io(), absolute, self.allocator);
    }

    fn absolutePathForCreate(self: *AppState, raw_path: []const u8) ![]u8 {
        const trimmed = std.mem.trim(u8, raw_path, &std.ascii.whitespace);
        if (trimmed.len == 0) return error.EmptyProjectPath;
        const expanded = try platform_paths.expandUserPath(self.allocator, trimmed);
        defer self.allocator.free(expanded);
        if (std.fs.path.isAbsolute(expanded)) return try self.allocator.dupe(u8, expanded);

        var threaded: std.Io.Threaded = .init(self.allocator, .{});
        defer threaded.deinit();
        const cwd = try std.Io.Dir.cwd().realPathFileAlloc(threaded.io(), ".", self.allocator);
        defer self.allocator.free(cwd);
        return try std.fs.path.join(self.allocator, &.{ cwd, expanded });
    }

    fn appendMessageToThread(
        self: *AppState,
        thread: *ChatThread,
        role: ChatRole,
        author: []const u8,
        body: []const u8,
        image: ?*const ChatImageAttachment,
        extra_images: []const ChatImageAttachment,
    ) !void {
        self.trimThreadMessages(thread, 1);

        const copied_extra = try self.allocator.alloc(ChatImageAttachment, extra_images.len);
        errdefer self.allocator.free(copied_extra);
        for (extra_images, 0..) |attachment, index| {
            copied_extra[index] = try ChatImageAttachment.init(self.allocator, attachment.path, attachment.mime, attachment.byte_size);
        }

        try thread.messages.append(self.allocator, .{
            .role = role,
            .author = try self.dupeZ(author),
            .body = try self.dupeZ(body),
            .image = if (image) |attachment|
                try ChatImageAttachment.init(self.allocator, attachment.path, attachment.mime, attachment.byte_size)
            else
                null,
            .extra_images = copied_extra,
        });
        thread.touch();
        self.markDirty();
    }

    fn appendMessage(self: *AppState, role: ChatRole, author: []const u8, body: []const u8, image: ?*const ChatImageAttachment) !void {
        return self.appendMessageToThread(self.currentThreadMutable(), role, author, body, image, &.{});
    }

    fn appendInitialSendFailure(self: *AppState, thread: *ChatThread, message: []const u8) void {
        self.appendMessageToThread(thread, .system, "Send failed", message, null, &.{}) catch |err| {
            log.err("failed to append initial-send failure: {s}", .{@errorName(err)});
        };
        self.setSidebarNotice(message);
    }

    pub fn importProjectFromInput(self: *AppState) !void {
        _ = self.createProjectFromPath(self.importDirectoryDraft()) catch |err| switch (err) {
            error.EmptyProjectPath => {
                self.setSidebarNotice("Enter a workspace directory path first.");
                return;
            },
            error.FileNotFound => {
                self.setSidebarNotice("Directory not found. Use New folder..., then type a folder name.");
                self.markDirty();
                return;
            },
            error.ProjectAlreadyExists => {
                self.setSidebarNotice("That directory is already in the workspace rail.");
                return;
            },
            else => return err,
        };
        self.clearImportPath();
        self.project_import_cursor = 0;
    }

    pub fn cancelProjectImport(self: *AppState) void {
        self.show_project_creator = false;
        self.clearImportPath();
        self.project_import_cursor = 0;
        if (self.palette_modal_text_focus == .project_import) {
            self.palette_modal_text_focus = .none;
        }
        self.setSidebarNotice("");
        self.markDirty();
    }

    pub fn browseForProjectDirectoryCreateParent(self: *AppState) void {
        self.project_directory_picker_create_parent = true;
        self.browseForProjectDirectory();
    }

    pub fn browseForProjectDirectory(self: *AppState) void {
        runtime_log.diagnostic("browseForWorkspaceDirectory entry show_project_creator={} draft_len={d}", .{ self.show_project_creator, self.importDirectoryDraft().len });
        log.info("browseForWorkspaceDirectory entry show_project_creator={} draft_len={d}", .{ self.show_project_creator, self.importDirectoryDraft().len });
        const target_path = self.defaultExplorerPath() catch |err| {
            runtime_log.diagnostic("browseForWorkspaceDirectory defaultExplorerPath failed: {s}", .{@errorName(err)});
            log.warn("browseForWorkspaceDirectory defaultExplorerPath failed: {s}", .{@errorName(err)});
            self.project_directory_picker_create_parent = false;
            self.setSidebarNotice(@errorName(err));
            return;
        };
        runtime_log.diagnostic("browseForWorkspaceDirectory target_path={s}", .{target_path});
        log.info("browseForWorkspaceDirectory target_path={s}", .{target_path});
        const page_alloc = std.heap.page_allocator;
        const owned_target = page_alloc.dupe(u8, target_path) catch {
            self.allocator.free(target_path);
            self.setSidebarNotice("Failed to start folder picker.");
            return;
        };
        self.allocator.free(target_path);

        self.picker_state.mutex.lock();
        defer self.picker_state.mutex.unlock();

        if (self.picker_state.status == .pending) {
            runtime_log.diagnostic("browseForWorkspaceDirectory ignored: picker already pending", .{});
            log.info("browseForWorkspaceDirectory ignored: picker already pending", .{});
            page_alloc.free(owned_target);
            self.project_directory_picker_create_parent = false;
            self.setSidebarNotice("Folder picker already open.");
            return;
        }

        self.picker_state.status = .pending;
        self.picker_state.selected_path = null;
        self.picker_state.worker = std.Thread.spawn(.{}, pickerWorker, .{ &self.picker_state, owned_target }) catch {
            page_alloc.free(owned_target);
            self.picker_state.status = .failed;
            self.project_directory_picker_create_parent = false;
            runtime_log.diagnostic("browseForWorkspaceDirectory failed to spawn picker worker", .{});
            log.warn("browseForWorkspaceDirectory failed to spawn picker worker", .{});
            self.setSidebarNotice("Failed to start folder picker.");
            return;
        };
        runtime_log.diagnostic("browseForWorkspaceDirectory spawned picker worker", .{});
        log.info("browseForWorkspaceDirectory spawned picker worker", .{});
        self.setSidebarNotice("Waiting for folder selection...");
    }

    pub fn requestBrowseForProjectDirectory(self: *AppState) void {
        runtime_log.diagnostic("requestBrowseForWorkspaceDirectory queued", .{});
        log.info("requestBrowseForWorkspaceDirectory queued", .{});
        self.project_directory_picker_create_parent = false;
        self.project_directory_browse_requested = true;
        self.markDirty();
    }

    pub fn processDeferredProjectDirectoryBrowse(self: *AppState) void {
        if (!self.project_directory_browse_requested) return;
        runtime_log.diagnostic("processDeferredWorkspaceDirectoryBrowse running", .{});
        log.info("processDeferredWorkspaceDirectoryBrowse running", .{});
        self.project_directory_browse_requested = false;
        self.browseForProjectDirectory();
    }

    fn renameSelectedProject(self: *AppState) void {
        if (self.projects.items.len == 0) return;
        self.renameProjectAtIndex(self.selected_project_index, self.renameInput()) catch |err| switch (err) {
            error.EmptyProjectName => self.setSidebarNotice("Workspace name cannot be empty."),
            else => self.setSidebarNotice("Rename failed."),
        };
    }

    pub fn renameProjectAtIndex(self: *AppState, index: usize, label: []const u8) !void {
        if (index >= self.projects.items.len) return error.ProjectNotFound;
        const trimmed = std.mem.trim(u8, label, &std.ascii.whitespace);
        if (trimmed.len == 0) return error.EmptyProjectName;

        const project = &self.projects.items[index];
        const copied = try self.allocator.dupeZ(u8, trimmed);
        self.allocator.free(project.label);
        project.label = copied;
        if (self.selected_project_index == index) self.syncRenameBuffer();
        self.setSidebarNotice("Workspace renamed.");
        self.markDirty();
    }

    pub fn beginProjectRename(self: *AppState, index: usize) void {
        if (index >= self.projects.items.len) return;
        if (self.show_project_creator) self.cancelProjectImport();
        self.selected_project_index = index;
        self.rename_project_index = index;
        self.syncRenameBuffer();
        self.palette_modal_text_focus = .project_rename;
        self.project_rename_cursor = self.renameInput().len;
        self.setSidebarNotice("");
    }

    pub fn selectProjectAtIndex(self: *AppState, index: usize) bool {
        if (index >= self.projects.items.len) return false;
        self.selected_project_index = index;
        self.ensureCurrentProjectWorkspace();
        self.workspace_header_open_menu_open = false;
        self.workspace_header_open_menu_pane_id = null;
        self.sidebar_context_menu_open = false;
        self.syncRenameBuffer();
        self.markDirty();
        return true;
    }

    pub fn selectAdjacentProject(self: *AppState, direction: isize) bool {
        if (self.projects.items.len == 0 or direction == 0) return false;
        const len: isize = @intCast(self.projects.items.len);
        const current: isize = @intCast(self.selected_project_index);
        const next: usize = @intCast(@mod(current + direction, len));
        return self.selectProjectAtIndex(next);
    }

    pub fn beginThreadImport(self: *AppState, index: usize, provider: Provider) void {
        if (index >= self.projects.items.len) return;
        if (self.show_project_creator) self.cancelProjectImport();
        if (self.herdr_profile_picker_project_index != null) self.cancelHerdrProfilePicker();
        self.selected_project_index = index;
        self.rename_project_index = null;
        self.thread_import_provider = provider;
        self.thread_import_project_index = index;
        self.thread_import_selected_index = null;
        self.import_thread_id_storage[0] = 0;
        self.palette_modal_text_focus = .thread_import;
        self.thread_import_cursor = 0;
        self.setThreadImportNotice("");
        self.clearThreadImportThreads();
        self.refreshThreadImportList();
    }

    pub fn beginHerdrProfilePicker(self: *AppState, index: usize) void {
        if (index >= self.projects.items.len) return;
        if (self.show_project_creator) self.cancelProjectImport();
        if (self.thread_import_provider != null) self.cancelThreadImport();
        self.selected_project_index = index;
        self.rename_project_index = null;
        self.herdr_profile_picker_project_index = index;
        self.herdr_profile_selected_index = null;
        self.herdr_profile_hover_index = null;
        self.palette_modal_text_focus = .none;
        self.setHerdrProfileNotice("");
        self.clearHerdrProfileSummaries();
        self.refreshHerdrProfileList();
    }

    pub fn cancelHerdrProfilePicker(self: *AppState) void {
        self.herdr_profile_picker_project_index = null;
        self.herdr_profile_selected_index = null;
        self.herdr_profile_hover_index = null;
        self.palette_modal_text_focus = .none;
        self.setHerdrProfileNotice("");
        self.clearHerdrProfileSummaries();
        self.markDirty();
    }

    pub fn refreshHerdrProfileList(self: *AppState) void {
        if (self.herdr_profile_picker_project_index == null) return;
        self.clearHerdrProfileSummaries();

        var threaded: std.Io.Threaded = .init(self.allocator, .{});
        defer threaded.deinit();
        var loaded = herdr.loadProfiles(self.allocator, threaded.io(), self.storage.pref_path) catch |err| {
            log.warn("failed to load Herdr profiles: {s}", .{@errorName(err)});
            self.setHerdrProfileNotice("Could not load Herdr profiles.");
            return;
        };
        defer loaded.deinit();

        for (loaded.profiles) |profile| {
            var summary = self.copyHerdrProfileSummary(profile) catch {
                self.setHerdrProfileNotice("Could not store Herdr profile list.");
                return;
            };
            errdefer summary.deinit(self.allocator);
            self.herdr_profile_summaries.append(self.allocator, summary) catch {
                self.setHerdrProfileNotice("Could not store Herdr profile list.");
                return;
            };
        }

        if (self.herdr_profile_summaries.items.len == 0) {
            self.setHerdrProfileNotice("No Herdr profiles configured. Use `verde herdr profiles add` first.");
        } else {
            self.herdr_profile_selected_index = 0;
            self.setHerdrProfileNotice("Choose a remote profile for this workspace.");
        }
        self.markDirty();
    }

    fn copyHerdrProfileSummary(self: *AppState, profile: herdr.Profile) !HerdrProfileSummary {
        const name = try self.allocator.dupeZ(u8, profile.name);
        errdefer self.allocator.free(name);
        const ssh_target = try self.allocator.dupeZ(u8, profile.ssh_target);
        errdefer self.allocator.free(ssh_target);
        const session = try self.allocator.dupeZ(u8, profile.session);
        errdefer self.allocator.free(session);
        const remote_cwd = if (profile.remote_cwd) |value| try self.allocator.dupeZ(u8, value) else null;
        errdefer if (remote_cwd) |value| self.allocator.free(value);
        const local_dir = if (profile.local_dir) |value| try self.allocator.dupeZ(u8, value) else null;
        errdefer if (local_dir) |value| self.allocator.free(value);
        return .{
            .name = name,
            .ssh_target = ssh_target,
            .session = session,
            .remote_cwd = remote_cwd,
            .local_dir = local_dir,
        };
    }

    pub fn selectHerdrProfile(self: *AppState, index: usize) void {
        if (index >= self.herdr_profile_summaries.items.len) return;
        self.herdr_profile_selected_index = index;
        self.markDirty();
    }

    pub fn handoffProjectToSelectedHerdrProfile(self: *AppState) void {
        const project_index = self.herdr_profile_picker_project_index orelse return;
        const profile_index = self.herdr_profile_selected_index orelse {
            self.setHerdrProfileNotice("Select a Herdr profile first.");
            return;
        };
        if (project_index >= self.projects.items.len or profile_index >= self.herdr_profile_summaries.items.len) return;
        const profile = self.herdr_profile_summaries.items[profile_index];
        self.handoffProjectToRemoteHerdrProfile(project_index, profile);
    }

    fn handoffProjectToRemoteHerdrProfile(self: *AppState, project_index: usize, profile: HerdrProfileSummary) void {
        if (project_index >= self.projects.items.len) return;
        const project = &self.projects.items[project_index];
        var default_remote_cwd: ?[]u8 = null;
        defer if (default_remote_cwd) |cwd| self.allocator.free(cwd);
        const remote_cwd = profile.remote_cwd orelse blk: {
            default_remote_cwd = herdr.defaultRemoteCwd(self.allocator, project.label, project.id) catch {
                self.setHerdrProfileNotice("Could not build a remote workspace path.");
                return;
            };
            break :blk default_remote_cwd.?;
        };
        const request: herdr.HandoffRequest = .{
            .session = profile.session,
            .remote = profile.ssh_target,
            .remote_cwd = remote_cwd,
            .workspace = project.id,
            .all = false,
        };
        var result = self.handoffHerdrWorkspaces(self.allocator, request) catch |err| {
            self.setHerdrProfileNotice(herdrUiFailureMessage(err));
            return;
        };
        defer result.deinit(self.allocator);
        if (result.workspaces.len == 0) {
            self.setHerdrProfileNotice("Herdr did not return a workspace.");
            return;
        }
        const workspace_id = result.workspaces[0].herdr_workspace;
        const open_request: herdr.OpenRequest = .{
            .session = profile.session,
            .herdr_workspace = workspace_id,
            .remote = profile.ssh_target,
            .remote_cwd = remote_cwd,
            .local_dir = profile.local_dir orelse project.path,
        };
        _ = self.openOrCreateHerdrWorkspace(open_request) catch |err| {
            self.setHerdrProfileNotice(herdrUiFailureMessage(err));
            return;
        };
        self.cancelHerdrProfilePicker();
        self.setSidebarNotice("Remote Herdr workspace opened.");
    }

    pub fn cancelThreadImport(self: *AppState) void {
        self.thread_import_provider = null;
        self.thread_import_project_index = null;
        self.thread_import_selected_index = null;
        self.import_thread_id_storage[0] = 0;
        if (self.palette_modal_text_focus == .thread_import) self.palette_modal_text_focus = .none;
        self.thread_import_cursor = 0;
        self.setThreadImportNotice("");
        self.clearThreadImportThreads();
    }

    pub fn refreshThreadImportList(self: *AppState) void {
        const provider = self.thread_import_provider orelse return;
        const project_index = self.thread_import_project_index orelse return;
        if (project_index >= self.projects.items.len) {
            self.cancelThreadImport();
            return;
        }

        self.clearThreadImportThreads();

        const project = &self.projects.items[project_index];
        const provider_config = switch (provider) {
            .codex => ai_harness.ProviderConfig{
                .codex = .{
                    .cwd = project.path,
                    .launch_on_connect = true,
                },
            },
            .opencode => ai_harness.ProviderConfig{
                .opencode = .{
                    .allocator = self.allocator,
                    .working_directory = project.path,
                    .launch_if_missing = true,
                },
            },
            .claude => ai_harness.ProviderConfig{
                .claude = .{
                    .cwd = project.path,
                },
            },
            .cursor => return self.setThreadImportNotice(importThreadFailureMessage(provider, error.UnsupportedOperation)),
        };

        var client = ai_harness.connect(self.allocator, provider_config) catch |err| {
            self.setThreadImportNotice(importThreadFailureMessage(provider, err));
            return;
        };
        defer client.deinit();

        const provider_threads = client.listThreads(self.allocator) catch |err| {
            self.setThreadImportNotice(importThreadFailureMessage(provider, err));
            return;
        };
        defer {
            for (provider_threads) |thread| {
                self.allocator.free(thread.id);
                self.allocator.free(thread.title);
            }
            self.allocator.free(provider_threads);
        }

        for (provider_threads) |thread| {
            const owned_id = self.allocator.dupeZ(u8, thread.id) catch {
                self.setThreadImportNotice(failedToStoreThreadListNotice(provider));
                return;
            };
            errdefer self.allocator.free(owned_id);
            const owned_title = self.allocator.dupeZ(u8, thread.title) catch {
                self.setThreadImportNotice(failedToStoreThreadListNotice(provider));
                return;
            };
            errdefer self.allocator.free(owned_title);

            self.thread_import_threads.append(self.allocator, .{
                .id = owned_id,
                .title = owned_title,
            }) catch {
                self.setThreadImportNotice(failedToStoreThreadListNotice(provider));
                return;
            };
        }

        if (self.thread_import_threads.items.len == 0) {
            self.setThreadImportNotice(noRecentThreadsNotice(provider));
            return;
        }

        self.setThreadImportNotice(selectThreadNotice(provider));
    }

    pub fn threadImportThreadIdBuffer(self: *AppState) [:0]u8 {
        return self.import_thread_id_storage[0 .. self.import_thread_id_storage.len - 1 :0];
    }

    pub fn threadImportThreadId(self: *const AppState) []const u8 {
        return std.mem.sliceTo(self.import_thread_id_storage[0..], 0);
    }

    fn threadImportListTitleForId(self: *const AppState, thread_id: []const u8) ?[]const u8 {
        if (self.thread_import_selected_index) |index| {
            if (index < self.thread_import_threads.items.len) {
                const selected = self.thread_import_threads.items[index];
                if (std.mem.eql(u8, selected.id, thread_id)) return selected.title;
            }
        }
        for (self.thread_import_threads.items) |thread| {
            if (std.mem.eql(u8, thread.id, thread_id)) return thread.title;
        }
        return null;
    }

    /// Opens the command palette overlay. `scope_project` restricts results to
    /// one workspace's thread history (the sidebar "History" entry point);
    /// `null` is the global Ctrl+Shift+P scope (commands + threads everywhere).
    pub fn openCommandPalette(self: *AppState, scope_project: ?usize) void {
        self.command_palette_open = true;
        self.command_palette_scope_project = scope_project;
        self.command_palette_query_storage[0] = 0;
        self.command_palette_cursor = 0;
        self.command_palette_selected = 0;
        self.command_palette_action_menu_open = false;
        self.command_palette_action_selected = 0;
        self.modal_text_selection_anchor = null;
        self.palette_modal_text_focus = .command_palette;
        self.closeSidebarContextMenu();
        self.workspace_header_open_menu_open = false;
        self.workspace_header_open_menu_pane_id = null;
        self.blurPaletteComposer();
        self.noteInteraction();
        self.markDirty();
    }

    pub fn closeCommandPalette(self: *AppState) void {
        if (!self.command_palette_open) return;
        self.command_palette_open = false;
        self.command_palette_action_menu_open = false;
        if (self.palette_modal_text_focus == .command_palette) self.palette_modal_text_focus = .none;
        self.modal_text_selection_anchor = null;
        self.markDirty();
    }

    pub fn commandPaletteQuery(self: *const AppState) []const u8 {
        return std.mem.sliceTo(self.command_palette_query_storage[0..], 0);
    }

    pub fn commandPaletteQueryBuffer(self: *AppState) [:0]u8 {
        return self.command_palette_query_storage[0 .. self.command_palette_query_storage.len - 1 :0];
    }

    /// Opens a thread in a brand-new chat pane split off the focused pane,
    /// preserving the existing layout. This is the command palette's
    /// Ctrl+Enter / "Open in New Pane" path; plain Enter goes through
    /// `selectThreadForProject` (reuse a visible chat pane) instead.
    pub fn openThreadInWorkspaceSplit(self: *AppState, project_index: usize, thread_index: usize) void {
        if (project_index >= self.projects.items.len) return;
        var project = &self.projects.items[project_index];
        if (thread_index >= project.threads.items.len) return;
        self.selected_project_index = project_index;
        var layout = &project.workspace_layout;
        const new_pane_id = layout.createChatPane(self.allocator, thread_index) catch |err| {
            log.err("failed to create chat pane for palette split: {s}", .{@errorName(err)});
            return;
        };
        const target_pane_id = layout.focused_pane_id orelse layout.firstVisiblePaneId();
        if (target_pane_id) |target_id| {
            layout.splitPaneWithLeaf(self.allocator, target_id, new_pane_id, .vertical, true) catch |err| {
                log.err("failed to split workspace pane for palette: {s}", .{@errorName(err)});
                return;
            };
        } else {
            layout.replaceRootWithLeaf(self.allocator, new_pane_id) catch |err| {
                log.err("failed to seed workspace pane for palette: {s}", .{@errorName(err)});
                return;
            };
        }
        layout.focused_pane_id = new_pane_id;
        layout.maximized_pane_id = null;
        project.selected_thread_index = thread_index;
        self.terminal_focused = false;
        self.requestComposerFocus();
        self.syncRenameBuffer();
        self.requestTranscriptScrollToBottom();
        self.markDirty();
    }

    pub fn threadImportNotice(self: *const AppState) []const u8 {
        return std.mem.sliceTo(self.import_notice_storage[0..], 0);
    }

    pub fn setThreadImportNotice(self: *AppState, value: []const u8) void {
        @memset(&self.import_notice_storage, 0);
        const len = @min(value.len, self.import_notice_storage.len - 1);
        @memcpy(self.import_notice_storage[0..len], value[0..len]);
    }

    pub fn herdrProfileNotice(self: *const AppState) []const u8 {
        return std.mem.sliceTo(self.herdr_profile_notice_storage[0..], 0);
    }

    pub fn setHerdrProfileNotice(self: *AppState, value: []const u8) void {
        @memset(&self.herdr_profile_notice_storage, 0);
        const len = @min(value.len, self.herdr_profile_notice_storage.len - 1);
        @memcpy(self.herdr_profile_notice_storage[0..len], value[0..len]);
    }

    pub fn selectThreadImport(self: *AppState, index: usize) void {
        if (index >= self.thread_import_threads.items.len) return;
        self.thread_import_selected_index = index;
        @memset(&self.import_thread_id_storage, 0);
        const thread_id = self.thread_import_threads.items[index].id;
        const len = @min(thread_id.len, self.import_thread_id_storage.len - 1);
        @memcpy(self.import_thread_id_storage[0..len], thread_id[0..len]);
    }

    pub fn importSelectedThread(self: *AppState) void {
        const provider = self.thread_import_provider orelse return;
        const project_index = self.thread_import_project_index orelse return;
        if (project_index >= self.projects.items.len) {
            self.cancelThreadImport();
            return;
        }

        const trimmed_id = std.mem.trim(u8, self.threadImportThreadId(), &std.ascii.whitespace);
        if (trimmed_id.len == 0) {
            self.setThreadImportNotice(emptyThreadImportIdNotice(provider));
            return;
        }

        if (self.findThreadIndexByProviderThreadId(project_index, provider, trimmed_id)) |thread_index| {
            self.selected_project_index = project_index;
            self.projects.items[project_index].selected_thread_index = thread_index;
            self.requestComposerFocus();
            self.requestTranscriptScrollToBottom();
            self.setSidebarNotice(duplicateThreadNotice(provider));
            self.cancelThreadImport();
            return;
        }

        const project = &self.projects.items[project_index];
        const provider_config = switch (provider) {
            .codex => ai_harness.ProviderConfig{
                .codex = .{
                    .cwd = project.path,
                    .launch_on_connect = true,
                },
            },
            .opencode => ai_harness.ProviderConfig{
                .opencode = .{
                    .allocator = self.allocator,
                    .working_directory = project.path,
                    .launch_if_missing = true,
                },
            },
            .claude => ai_harness.ProviderConfig{
                .claude = .{
                    .cwd = project.path,
                },
            },
            .cursor => return self.setThreadImportNotice(importThreadFailureMessage(provider, error.UnsupportedOperation)),
        };

        var client = ai_harness.connect(self.allocator, provider_config) catch |err| {
            self.setThreadImportNotice(importThreadFailureMessage(provider, err));
            return;
        };
        defer client.deinit();

        const imported_thread = client.readThread(self.allocator, trimmed_id) catch |err| {
            log.warn("failed to read {s} thread for import id_len={d}: {s}", .{ @tagName(provider), trimmed_id.len, @errorName(err) });
            self.setThreadImportNotice(readThreadFailureMessage(provider, err));
            return;
        };
        defer imported_thread.deinit(self.allocator);

        var imported = self.buildImportedThread(imported_thread, null) catch |err| {
            log.warn("failed to build imported {s} thread id_len={d}: {s}", .{ @tagName(provider), trimmed_id.len, @errorName(err) });
            self.setThreadImportNotice(failedCreateImportedThreadNotice(provider));
            return;
        };
        errdefer imported.deinit(self.allocator);

        if (std.mem.eql(u8, imported.title, trimmed_id)) {
            if (self.threadImportListTitleForId(trimmed_id)) |list_title| {
                const title_copy = self.allocator.dupeZ(u8, list_title) catch {
                    self.setThreadImportNotice(failedCreateImportedThreadNotice(provider));
                    return;
                };
                self.allocator.free(imported.title);
                imported.title = title_copy;
            }
        }

        imported.provider = provider;
        if (imported.model_ref) |model_ref| {
            self.allocator.free(model_ref);
            imported.model_ref = null;
        }
        const model_ref = imported_thread.model_id orelse self.cachedDefaultModelRefForProvider(provider);
        imported.model_ref = self.allocator.dupeZ(u8, model_ref) catch {
            self.setThreadImportNotice(failedCreateImportedThreadNotice(provider));
            return;
        };

        self.projects.items[project_index].threads.append(self.allocator, imported) catch {
            self.setThreadImportNotice(failedAddImportedThreadNotice(provider));
            return;
        };
        self.projects.items[project_index].invalidateSidebarThreadCache();
        self.selected_project_index = project_index;
        self.projects.items[project_index].selected_thread_index = self.projects.items[project_index].threads.items.len - 1;
        self.requestComposerFocus();
        self.requestTranscriptScrollToBottom();
        self.markDirty();
        self.setSidebarNotice(threadImportedNotice(provider));
        self.cancelThreadImport();
    }

    pub fn syncThreadFromProvider(self: *AppState, project_index: usize, thread_index: usize) void {
        if (project_index >= self.projects.items.len) {
            self.setSidebarNotice("Workspace not found.");
            return;
        }

        const project = &self.projects.items[project_index];
        if (thread_index >= project.threads.items.len) {
            self.setSidebarNotice("Thread not found.");
            return;
        }

        if (project.threads.items[thread_index].isSendPending()) {
            self.setSidebarNotice("Finish this thread's provider request before syncing.");
            return;
        }

        const provider = project.threads.items[thread_index].provider;
        const provider_config = switch (provider) {
            .codex => ai_harness.ProviderConfig{
                .codex = .{
                    .cwd = project.path,
                    .launch_on_connect = true,
                },
            },
            .opencode => ai_harness.ProviderConfig{
                .opencode = .{
                    .allocator = self.allocator,
                    .working_directory = project.path,
                    .launch_if_missing = true,
                },
            },
            .claude => ai_harness.ProviderConfig{
                .claude = .{
                    .cwd = project.path,
                },
            },
            .cursor => {
                self.setSidebarNotice(syncThreadFailureMessage(provider, error.UnsupportedOperation));
                return;
            },
        };

        const provider_thread_id = project.threads.items[thread_index].provider_thread_id orelse {
            self.setSidebarNotice("This thread is not linked to a remote provider session.");
            return;
        };

        var client = ai_harness.connect(self.allocator, provider_config) catch |err| {
            self.setSidebarNotice(syncThreadFailureMessage(provider, err));
            return;
        };
        defer client.deinit();

        const imported_thread = client.readThread(self.allocator, provider_thread_id) catch |err| {
            self.setSidebarNotice(syncThreadFailureMessage(provider, err));
            return;
        };
        defer imported_thread.deinit(self.allocator);

        self.replaceThreadWithImportedSnapshot(project_index, thread_index, imported_thread) catch {
            self.setSidebarNotice("Failed to sync the local thread.");
            return;
        };

        self.selected_project_index = project_index;
        self.projects.items[project_index].selected_thread_index = thread_index;
        self.requestComposerFocus();
        self.syncRenameBuffer();
        self.requestTranscriptScrollToBottom();
        self.markDirty();
        self.setSidebarNotice(threadSyncedNotice(provider));
    }

    pub fn finishProjectRename(self: *AppState) void {
        if (self.rename_project_index) |index| {
            if (index < self.projects.items.len) {
                self.selected_project_index = index;
                self.renameSelectedProject();
            }
        }
        self.rename_project_index = null;
        if (self.palette_modal_text_focus == .project_rename) self.palette_modal_text_focus = .none;
    }

    pub fn cancelProjectRename(self: *AppState) void {
        self.rename_project_index = null;
        if (self.palette_modal_text_focus == .project_rename) self.palette_modal_text_focus = .none;
        self.syncRenameBuffer();
    }

    /// Reorders the workspace list, moving the project at `from` so it lands
    /// immediately before slot `before` (in current array coordinates; pass
    /// `projects.items.len` to drop at the end). Keeps `selected_project_index`
    /// pointing at the same logical workspace and persists the new order.
    pub fn moveProject(self: *AppState, from: usize, before: usize) void {
        const len = self.projects.items.len;
        if (from >= len) return;

        var insert_at = before;
        if (insert_at > from) insert_at -= 1;
        if (insert_at >= len) insert_at = len - 1;
        if (insert_at == from) return;

        const sel_is_from = self.selected_project_index == from;
        const moved = self.projects.orderedRemove(from);
        self.projects.insert(self.allocator, insert_at, moved) catch {
            // Best effort: restore near the original slot so we never drop it.
            self.projects.insert(self.allocator, from, moved) catch {
                self.projects.append(self.allocator, moved) catch {};
            };
            return;
        };

        if (sel_is_from) {
            self.selected_project_index = insert_at;
        } else {
            var s = self.selected_project_index;
            if (s > from) s -= 1;
            if (s >= insert_at) s += 1;
            self.selected_project_index = s;
        }

        self.syncRenameBuffer();
        self.markDirty();
    }

    fn restoreClosedProject(self: *AppState, archived_index: usize, unread_count: u8) !void {
        if (archived_index >= self.archived_projects.items.len) return error.ProjectNotFound;
        var restored = self.archived_projects.orderedRemove(archived_index);
        var restored_appended = false;
        errdefer if (!restored_appended) restored.deinit(self.allocator);
        restored.archived = false;
        restored.unread_count = unread_count;
        if (restored.threads.items.len == 0) {
            _ = try restored.addThread(self.allocator);
        }
        try restored.normalize(self.allocator, self.app_config.terminal_font_size);
        try self.projects.append(self.allocator, restored);
        restored_appended = true;
        self.selected_project_index = self.projects.items.len - 1;
        self.ensureCurrentProjectWorkspace();
        self.syncRenameBuffer();
        self.markDirty();
    }

    pub fn reopenClosedProjectAtIndex(self: *AppState, archived_index: usize) bool {
        self.restoreClosedProject(archived_index, 0) catch |err| {
            self.setSidebarNotice(@errorName(err));
            return false;
        };
        self.setSidebarNotice("Workspace reopened.");
        return true;
    }

    pub fn reopenLastClosedProject(self: *AppState) bool {
        if (self.archived_projects.items.len == 0) {
            self.setSidebarNotice("No closed workspaces to reopen.");
            return false;
        }
        return self.reopenClosedProjectAtIndex(self.archived_projects.items.len - 1);
    }

    pub fn closeProjectAtIndex(self: *AppState, index: usize) void {
        _ = self.closeProjectAtIndexResult(index);
    }

    pub fn closeProjectAtIndexResult(self: *AppState, index: usize) bool {
        if (index >= self.projects.items.len) return false;
        if (self.projectHasPendingSend(index)) {
            self.setSidebarNotice("Finish this workspace's running provider requests before closing it.");
            return false;
        }

        self.cancelThreadImport();
        var removed = self.projects.orderedRemove(index);
        removed.archived = true;
        removed.terminal_dock.visible = false;
        removed.terminateWorkspaceSessions();
        self.archived_projects.append(self.allocator, removed) catch |err| {
            var failed = removed;
            failed.deinit(self.allocator);
            self.setSidebarNotice(@errorName(err));
            return false;
        };

        if (self.projects.items.len == 0) {
            self.selected_project_index = 0;
        } else if (self.selected_project_index == index) {
            self.selected_project_index = @min(index, self.projects.items.len - 1);
        } else if (self.selected_project_index > index) {
            self.selected_project_index -= 1;
        }

        self.rename_project_index = null;
        self.syncRenameBuffer();
        self.setSidebarNotice("Workspace closed.");
        self.markDirty();
        return true;
    }

    pub fn archiveProjectAtIndex(self: *AppState, index: usize) void {
        self.closeProjectAtIndex(index);
    }

    pub fn archiveProjectAtIndexResult(self: *AppState, index: usize) bool {
        return self.closeProjectAtIndexResult(index);
    }

    fn archiveSelectedProject(self: *AppState) void {
        if (self.projects.items.len == 0) return;
        _ = self.closeProjectAtIndexResult(self.selected_project_index);
    }

    fn projectHasPendingSend(self: *const AppState, index: usize) bool {
        if (index >= self.projects.items.len) return false;
        for (self.projects.items[index].threads.items) |*thread| {
            if (thread.isSendPending()) {
                return true;
            }
        }
        return false;
    }

    pub fn archiveThreadAtIndex(self: *AppState, project_index: usize, thread_index: usize) void {
        if (project_index >= self.projects.items.len) {
            self.setSidebarNotice("Workspace not found.");
            return;
        }

        const project = &self.projects.items[project_index];
        if (thread_index >= project.threads.items.len) {
            self.setSidebarNotice("Thread not found.");
            return;
        }

        if (project.threads.items[thread_index].isSendPending()) {
            self.setSidebarNotice("Finish this thread's provider request before archiving.");
            return;
        }

        var archived_thread = project.threads.orderedRemove(thread_index);
        archived_thread.archived = true;
        project.archived_threads.append(self.allocator, archived_thread) catch |err| {
            var failed = archived_thread;
            failed.archived = false;
            if (thread_index <= project.threads.items.len) {
                project.threads.insert(self.allocator, thread_index, failed) catch {
                    failed.deinit(self.allocator);
                };
            } else {
                project.threads.append(self.allocator, failed) catch {
                    failed.deinit(self.allocator);
                };
            }
            self.setSidebarNotice(@errorName(err));
            return;
        };
        project.invalidateSidebarThreadCache();

        if (project.threads.items.len == 0) {
            _ = project.addThread(self.allocator) catch {
                self.setSidebarNotice("Archived the thread, but failed to create a new draft.");
                self.markDirty();
                return;
            };
        } else if (thread_index < project.selected_thread_index) {
            project.selected_thread_index -= 1;
        } else if (project.selected_thread_index >= project.threads.items.len) {
            project.selected_thread_index = project.threads.items.len - 1;
        }

        self.selected_project_index = project_index;
        self.syncRenameBuffer();
        self.requestTranscriptScrollToBottom();
        self.markDirty();
        self.setSidebarNotice("Thread archived.");
    }

    pub fn createThreadForProject(self: *AppState, index: usize) void {
        if (index >= self.projects.items.len) return;
        var project = &self.projects.items[index];
        const thread_index = project.addThread(self.allocator) catch {
            self.setSidebarNotice("Failed to create a new thread.");
            return;
        };
        self.selected_project_index = index;
        self.focusProjectThreadInWorkspace(index, thread_index) catch |err| {
            log.err("failed to focus new thread workspace pane: {s}", .{@errorName(err)});
        };
        self.requestComposerFocus();
        self.syncRenameBuffer();
        self.setSidebarNotice("New thread ready.");
        self.markDirty();
    }

    pub fn selectThreadForProject(self: *AppState, project_index: usize, thread_index: usize) void {
        if (project_index >= self.projects.items.len) return;
        const project = &self.projects.items[project_index];
        if (thread_index >= project.threads.items.len) return;
        self.selected_project_index = project_index;
        project.selected_thread_index = thread_index;
        self.focusProjectThreadInWorkspace(project_index, thread_index) catch |err| {
            log.err("failed to focus selected thread workspace pane: {s}", .{@errorName(err)});
        };
        self.requestComposerFocus();
        self.syncRenameBuffer();
        self.requestTranscriptScrollToBottom();
        self.markDirty();
    }

    fn focusProjectThreadInWorkspace(self: *AppState, project_index: usize, thread_index: usize) !void {
        if (project_index >= self.projects.items.len) return;
        var project = &self.projects.items[project_index];
        if (thread_index >= project.threads.items.len) return;
        var layout = &project.workspace_layout;
        _ = try layout.ensureDefaultChat(self.allocator);

        var chat_pane_id: ?WorkspacePaneId = null;
        for (layout.panes.items) |*pane| {
            if (pane.minimized) continue;
            switch (pane.ref) {
                .chat => |*ref| {
                    ref.thread_index = thread_index;
                    chat_pane_id = pane.id;
                    break;
                },
                else => {},
            }
        }

        if (chat_pane_id == null) {
            const new_pane_id = try layout.createChatPane(self.allocator, thread_index);
            const target_pane_id = layout.focused_pane_id orelse layout.firstVisiblePaneId();
            if (target_pane_id) |target_id| {
                try layout.splitPaneWithLeaf(self.allocator, target_id, new_pane_id, .vertical, true);
            } else {
                try layout.replaceRootWithLeaf(self.allocator, new_pane_id);
            }
            chat_pane_id = new_pane_id;
        }

        layout.focused_pane_id = chat_pane_id;
        layout.maximized_pane_id = null;
        project.selected_thread_index = thread_index;
        self.terminal_focused = false;
    }

    fn providerExecutionTargetForProjectThread(
        self: *AppState,
        project_index: usize,
        thread: *const ChatThread,
        image_count: usize,
    ) ?ProviderExecutionTarget {
        if (project_index >= self.projects.items.len) return null;
        const project = &self.projects.items[project_index];
        const link = project.herdr_link orelse return .{ .local = project.path };

        if (link.remote_alias.len == 0) {
            self.setSidebarNotice("Local Herdr GUI sends use the Herdr terminal/TUI pane for now.");
            return null;
        }
        if (thread.provider != .codex) {
            var buffer: [160]u8 = undefined;
            self.setSidebarNotice(std.fmt.bufPrint(
                &buffer,
                "Remote Herdr GUI sends support Codex only for now. Use the Herdr TUI pane for {s}.",
                .{utils.providerLabel(thread.provider)},
            ) catch "Remote Herdr GUI sends support Codex only for now.");
            return null;
        }
        if (image_count > 0) {
            self.setSidebarNotice("Remote Herdr Codex GUI sends do not support local image attachments yet.");
            return null;
        }
        const remote_cwd = link.remote_cwd orelse {
            self.setSidebarNotice("Remote Herdr workspace is missing a remote cwd.");
            return null;
        };
        return .{ .remote_ssh = .{ .host = link.remote_alias, .cwd = remote_cwd } };
    }

    pub fn sendDraft(self: *AppState) !void {
        const draft = self.currentDraft();
        const draft_image = self.currentThread().draft_image;
        const draft_image_count = self.currentThread().draftImageCount();
        if (draft.len == 0 and draft_image_count == 0) return;

        if (self.currentThread().isSendPending()) {
            self.setSidebarNotice("This chat already has a provider request running.");
            return;
        }
        const execution_target = self.providerExecutionTargetForProjectThread(
            self.selected_project_index,
            self.currentThread(),
            draft_image_count,
        ) orelse return;

        // Prove the daemon is reachable before staging a persisted user turn.
        // A failure here cannot be an ambiguously accepted send, so the draft,
        // attachments, title, and existing transcript all remain retryable.
        self.ensureSessionDaemon() catch |err| {
            const thread = self.currentThreadMutable();
            self.appendInitialSendFailure(thread, initialSendStartFailureMessage(err));
            self.currentProjectMutable().invalidateSidebarThreadCache();
            self.requestTranscriptScrollToBottom();
            self.flushDirtyBlocking();
            return err;
        };

        const trimmed_title = std.mem.trim(u8, draft, &std.ascii.whitespace);
        const thread = self.currentThreadMutable();
        var snapshot = try InitialSendSnapshot.init(self.allocator, thread);
        defer snapshot.deinit(self.allocator);
        if (!thread.committed) {
            thread.commitFromPrompt(self.allocator, if (trimmed_title.len > 0) trimmed_title else "Image") catch |err| {
                snapshot.restore(self, thread);
                self.appendInitialSendFailure(thread, initialSendStartFailureMessage(err));
                self.currentProjectMutable().invalidateSidebarThreadCache();
                self.requestTranscriptScrollToBottom();
                self.flushDirtyBlocking();
                return err;
            };
        }
        var draft_image_copy = draft_image;
        self.appendMessageToThread(thread, .user, "You", draft, if (draft_image_copy) |*image| image else null, thread.draft_extra_images.items) catch |err| {
            snapshot.restore(self, thread);
            self.appendInitialSendFailure(thread, initialSendStartFailureMessage(err));
            self.currentProjectMutable().invalidateSidebarThreadCache();
            self.requestTranscriptScrollToBottom();
            self.flushDirtyBlocking();
            return err;
        };
        self.currentProjectMutable().invalidateSidebarThreadCache();
        // Persist the user turn before handing provider execution to the daemon,
        // so a fast app quit can still reattach the daemon-owned reply to a
        // known local chat thread.
        self.flushDirtyBlocking();
        self.beginSendForThreadWithReadyDaemon(self.selected_project_index, thread, draft, execution_target) catch |err| {
            if (err == error.DaemonRequestFailed) {
                // A daemon JSON-RPC error is a confirmed rejection, so removing
                // the staged user row is safe and leaves the draft retryable.
                snapshot.restore(self, thread);
                self.appendInitialSendFailure(thread, initialSendStartFailureMessage(err));
            } else {
                // Transport and response failures may happen after acceptance.
                // Keep the one persisted user row, but clear the composer so a
                // blind retry cannot duplicate it (or the provider turn).
                self.clearDraft();
                thread.clearDraftImage(self.allocator);
                self.resetComposerInputWidget();
                self.appendInitialSendFailure(thread, ambiguousInitialSendFailureMessage());
            }
            self.currentProjectMutable().invalidateSidebarThreadCache();
            self.requestTranscriptScrollToBottom();
            self.flushDirtyBlocking();
            return err;
        };
        self.clearDraft();
        thread.clearDraftImage(self.allocator);
        self.resetComposerInputWidget();
        self.requestTranscriptScrollToBottom();
        self.setSidebarNotice("Waiting for provider reply...");
    }

    pub fn abortCurrentThreadSend(self: *AppState) void {
        if (self.projects.items.len == 0) return;
        const send_state = self.currentThread().send_state;
        send_state.mutex.lock();
        defer send_state.mutex.unlock();

        if (send_state.status != .pending) {
            self.setSidebarNotice("This chat is not running.");
            return;
        }

        if (send_state.stop_requested) {
            self.setSidebarNotice("Stopping provider reply...");
            return;
        }

        send_state.stop_requested = true;
        if (send_state.pending_approval != null) {
            send_state.approval_decision = .deny;
            send_state.condition.broadcast();
        }
        self.setSidebarNotice("Stopping provider reply...");
    }

    pub fn queueOrSteerDraftDuringSend(self: *AppState) void {
        if (self.projects.items.len == 0) return;
        const thread = self.currentThreadMutable();
        if (!thread.isSendPending()) {
            self.setSidebarNotice("This chat is not running.");
            return;
        }

        const draft = thread.currentDraft();
        if (std.mem.trim(u8, draft, &std.ascii.whitespace).len == 0) {
            self.setSidebarNotice("Type a message first.");
            return;
        }

        const kind: FollowupKind = switch (thread.provider) {
            .codex => .steer,
            .opencode => .queue,
            .claude => .queue,
            .cursor => .queue,
        };

        const send_state = thread.send_state;
        send_state.mutex.lock();
        defer send_state.mutex.unlock();

        freePendingFollowup(self.allocator, &send_state.pending_followup);
        send_state.pending_followup_signal_sent = false;
        send_state.pending_followup = .{
            .kind = kind,
            .state = .pending,
            .prompt = self.allocator.dupe(u8, draft) catch {
                self.setSidebarNotice("Failed to store the pending follow-up.");
                return;
            },
        };

        self.clearDraft();
        thread.clearDraftImage(self.allocator);
        self.resetComposerInputWidget();
        self.setSidebarNotice(switch (kind) {
            .queue => "Queued. Sends after the current reply.",
            .steer => "Steer queued. Waiting for Codex to accept it.",
        });
    }

    pub fn pendingFollowupSnapshot(self: *AppState) !?PendingFollowup {
        if (self.projects.items.len == 0) return null;
        const send_state = self.currentThread().send_state;
        send_state.mutex.lock();
        defer send_state.mutex.unlock();

        const pending = send_state.pending_followup orelse return null;
        return .{
            .kind = pending.kind,
            .state = pending.state,
            .prompt = try self.allocator.dupe(u8, pending.prompt),
        };
    }

    pub fn pendingFollowupHint(self: *const AppState) ?[:0]const u8 {
        if (self.projects.items.len == 0) return null;
        const thread = self.currentThread();
        if (!thread.isSendPending()) return null;
        return switch (thread.provider) {
            .codex => "Tab to steer",
            .opencode => "Tab to queue",
            .claude => "Tab to queue",
            .cursor => "Tab to queue",
        };
    }

    fn sendPromptViaHarness(self: *AppState, prompt: []const u8) !ai_harness.SendPromptResult {
        const project = self.currentProject();
        const thread = self.currentThread();

        if (thread.harness != .local_cli) {
            return error.UnsupportedHarnessMode;
        }

        const provider_config = switch (thread.provider) {
            .opencode => ai_harness.ProviderConfig{
                .opencode = .{
                    .allocator = self.allocator,
                    .working_directory = project.path,
                    .launch_if_missing = true,
                },
            },
            .codex => ai_harness.ProviderConfig{
                .codex = .{
                    .cwd = project.path,
                    .launch_on_connect = false,
                },
            },
            .claude => ai_harness.ProviderConfig{
                .claude = .{
                    .cwd = project.path,
                },
            },
            .cursor => ai_harness.ProviderConfig{
                .cursor = .{
                    .cwd = project.path,
                    .model = if (thread.model_ref) |model_ref| model_ref else null,
                },
            },
        };

        var client = try ai_harness.connect(self.allocator, provider_config);
        defer client.deinit();

        const cursor_model_params_json = if (thread.provider == .cursor) try self.cursorModelParamsJsonAlloc(self.allocator, thread) else null;
        defer if (cursor_model_params_json) |params| self.allocator.free(params);

        return client.sendPrompt(self.allocator, .{
            .thread_id = if (thread.provider_thread_id) |thread_id| thread_id else null,
            .thread_title = thread.title,
            .prompt = prompt,
            .cwd = project.path,
            .model = if (thread.model_ref) |model_ref| model_ref else null,
            .opencode_variant = if (thread.provider == .opencode) thread.opencode_reasoning_variant else null,
            .cursor_model_params_json = cursor_model_params_json,
            .reasoning_effort = if (thread.provider == .opencode and thread.opencode_reasoning_variant != null) null else thread.reasoning_effort,
            .service_tier = serviceTierForMode(thread.provider, thread.fast_mode),
            .approval_policy = approvalPolicyForMode(thread.provider, thread.access_mode),
            .sandbox_mode = sandboxModeForMode(thread.provider, thread.access_mode),
        });
    }

    fn interruptThreadViaHarness(
        self: *AppState,
        execution_target: ProviderExecutionTarget,
        provider: Provider,
        thread_id: []const u8,
        turn_id: ?[]const u8,
    ) !void {
        if (execution_target.remoteHost() != null and provider != .codex) return error.UnsupportedRemoteProvider;
        const provider_cwd = execution_target.cwd();
        const provider_config = switch (provider) {
            .opencode => ai_harness.ProviderConfig{
                .opencode = .{
                    .allocator = self.allocator,
                    .working_directory = provider_cwd,
                    .launch_if_missing = true,
                },
            },
            .codex => ai_harness.ProviderConfig{
                .codex = .{
                    .cwd = provider_cwd,
                    .launch_on_connect = false,
                    .remote_ssh = if (execution_target.remoteHost()) |host| .{
                        .host = host,
                        .cwd = provider_cwd,
                    } else null,
                },
            },
            .claude => ai_harness.ProviderConfig{
                .claude = .{
                    .cwd = provider_cwd,
                },
            },
            .cursor => ai_harness.ProviderConfig{
                .cursor = .{
                    .cwd = provider_cwd,
                },
            },
        };

        var client = try ai_harness.connect(self.allocator, provider_config);
        defer client.deinit();

        return client.interruptThread(.{
            .thread_id = thread_id,
            .turn_id = turn_id,
        });
    }

    fn steerThreadViaHarness(
        self: *AppState,
        execution_target: ProviderExecutionTarget,
        thread_id: []const u8,
        turn_id: []const u8,
        prompt: []const u8,
    ) !void {
        const provider_cwd = execution_target.cwd();
        const provider_config = ai_harness.ProviderConfig{
            .codex = .{
                .cwd = provider_cwd,
                .launch_on_connect = false,
                .remote_ssh = if (execution_target.remoteHost()) |host| .{
                    .host = host,
                    .cwd = provider_cwd,
                } else null,
            },
        };

        var client = try ai_harness.connect(self.allocator, provider_config);
        defer client.deinit();

        return client.steerThread(.{
            .thread_id = thread_id,
            .turn_id = turn_id,
            .prompt = prompt,
        });
    }

    fn beginSendForThread(
        self: *AppState,
        project_index: usize,
        thread: *ChatThread,
        prompt: []const u8,
        execution_target: ProviderExecutionTarget,
    ) !void {
        try self.ensureSessionDaemon();
        return self.beginSendForThreadWithReadyDaemon(project_index, thread, prompt, execution_target);
    }

    fn beginSendForThreadWithReadyDaemon(
        self: *AppState,
        project_index: usize,
        thread: *ChatThread,
        prompt: []const u8,
        execution_target: ProviderExecutionTarget,
    ) !void {
        const page_alloc = std.heap.page_allocator;
        const execution_cwd = execution_target.cwd();
        const turn_id = try std.fmt.allocPrint(page_alloc, "gui:{s}:{s}:{d}", .{ self.projects.items[project_index].id, thread.local_thread_id, unixTimestampMs() });
        errdefer page_alloc.free(turn_id);
        const cursor_model_params_json = if (thread.provider == .cursor) try self.cursorModelParamsJsonAlloc(page_alloc, thread) else null;
        defer if (cursor_model_params_json) |params| page_alloc.free(params);

        // The daemon response is owned by self.allocator (startDaemonChatTurn ->
        // sessionizer.requestAlloc); freeing it with page_alloc trips
        // PageAllocator's alignment safety check and crashes the send.
        const response: ?[]u8 = self.startDaemonChatTurn(
            project_index,
            thread,
            prompt,
            execution_target,
            execution_cwd,
            cursor_model_params_json,
            turn_id,
        ) catch |err| recovered: {
            // A lost reply can follow successful acceptance. Probe this exact
            // idempotency key before exposing a retry that could run twice.
            if (!self.daemonChatTurnExists(turn_id)) return err;
            break :recovered null;
        };
        defer if (response) |owned| self.allocator.free(owned);
        if (response) |json| {
            ensureJsonRpcOk(self.allocator, json) catch |err| {
                if (!self.daemonChatTurnExists(turn_id)) return err;
            };
        }

        const send_state = thread.send_state;
        send_state.mutex.lock();
        defer send_state.mutex.unlock();
        send_state.status = .pending;
        send_state.started_at_ms = unixTimestampMs();
        send_state.result = null;
        send_state.error_message = null;
        send_state.provider = thread.provider;
        if (send_state.provisional_provider_thread_id) |thread_id| {
            page_alloc.free(thread_id);
            send_state.provisional_provider_thread_id = null;
        }
        if (send_state.active_turn_id) |active_turn_id| {
            page_alloc.free(active_turn_id);
            send_state.active_turn_id = null;
        }
        if (send_state.daemon_turn_id) |old_turn_id| {
            page_alloc.free(old_turn_id);
            send_state.daemon_turn_id = null;
        }
        send_state.daemon_turn_id = turn_id;
        send_state.daemon_last_seq = 0;
        send_state.daemon_owned = true;
        send_state.partial_text.clearRetainingCapacity();
        freePendingTimelineEventsLocked(page_alloc, &send_state.pending_events);
        freePendingDiffFilesLocked(page_alloc, &send_state.pending_diff_files);
        freePendingApprovalLocked(page_alloc, &send_state.pending_approval);
        send_state.ui_revision = 1;
        send_state.polled_ui_revision = 0;
        // Reset the working-seconds tracker so the first pending poll forces
        // a render and seeds the visible "Working - 0:00" label.
        send_state.polled_working_seconds = -1;
        send_state.approval_decision = null;
        send_state.pending_followup_signal_sent = false;
        send_state.stop_requested = false;
        send_state.stop_signal_sent = false;
        send_state.worker = null;
        self.pending_send_count += 1;
    }

    fn beginSendDraft(self: *AppState, prompt: []const u8) !void {
        const execution_target = self.providerExecutionTargetForProjectThread(
            self.selected_project_index,
            self.currentThread(),
            self.currentThread().draftImageCount(),
        ) orelse return;
        return self.beginSendForThread(self.selected_project_index, self.currentThreadMutable(), prompt, execution_target);
    }

    fn ensureSessionDaemon(self: *AppState) !void {
        var threaded: std.Io.Threaded = .init(self.allocator, .{});
        defer threaded.deinit();
        const exe_path = try std.process.executablePathAlloc(threaded.io(), self.allocator);
        defer self.allocator.free(exe_path);
        try sessionizer.ensureDaemon(self.allocator, self.storage.pref_path, exe_path);
    }

    fn startDaemonChatTurn(
        self: *AppState,
        project_index: usize,
        thread: *const ChatThread,
        prompt: []const u8,
        execution_target: ProviderExecutionTarget,
        execution_cwd: []const u8,
        cursor_model_params_json: ?[]const u8,
        turn_id: []const u8,
    ) ![]u8 {
        var image_paths: std.ArrayList([]const u8) = .empty;
        defer image_paths.deinit(self.allocator);
        if (thread.draft_image) |image| try image_paths.append(self.allocator, image.path);
        for (thread.draft_extra_images.items) |image| try image_paths.append(self.allocator, image.path);

        return sessionizer.requestAlloc(self.allocator, self.storage.pref_path, "chat.turn.start", .{
            .turn_id = turn_id,
            .workspace_id = self.projects.items[project_index].id,
            .local_thread_id = thread.local_thread_id,
            .provider = @tagName(harnessProviderForDbProvider(thread.provider)),
            .harness = @tagName(thread.harness),
            .project_path = self.projects.items[project_index].path,
            .prompt = prompt,
            .image_paths = image_paths.items,
            .provider_thread_id = if (thread.provider_thread_id) |thread_id| thread_id else null,
            .thread_title = thread.title,
            .model_ref = if (thread.model_ref) |model_ref| model_ref else null,
            .reasoning_effort = if (thread.reasoning_effort) |effort| @tagName(effort) else null,
            .opencode_reasoning_variant = if (thread.provider == .opencode) thread.opencode_reasoning_variant else null,
            .cursor_model_params_json = cursor_model_params_json,
            .fast_mode = thread.fast_mode == .on,
            .access_mode = @tagName(thread.access_mode),
            .remote_ssh_host = if (execution_target.remoteHost()) |host| host else null,
            .remote_cwd = if (execution_target.remoteHost() != null) execution_cwd else null,
        }, 1);
    }

    fn daemonChatTurnExists(self: *AppState, turn_id: []const u8) bool {
        const response = sessionizer.requestAlloc(self.allocator, self.storage.pref_path, "chat.turn.tail", .{
            .turn_id = turn_id,
            .after_seq = 0,
        }, 2) catch return false;
        defer self.allocator.free(response);
        ensureJsonRpcOk(self.allocator, response) catch return false;
        return true;
    }

    fn cancelDaemonChatTurn(self: *AppState, turn_id: []const u8) void {
        const response = sessionizer.requestAlloc(self.allocator, self.storage.pref_path, "chat.turn.cancel", .{ .turn_id = turn_id }, 3) catch |err| {
            log.warn("failed to cancel daemon chat turn: {s}", .{@errorName(err)});
            return;
        };
        defer self.allocator.free(response);
    }

    fn approveDaemonChatTurn(self: *AppState, turn_id: []const u8, call_id: []const u8, decision: ai_harness.ApprovalDecision) void {
        const response = sessionizer.requestAlloc(self.allocator, self.storage.pref_path, "chat.turn.approve", .{
            .turn_id = turn_id,
            .call_id = call_id,
            .decision = @tagName(decision),
        }, 4) catch |err| {
            log.warn("failed to approve daemon chat turn: {s}", .{@errorName(err)});
            return;
        };
        defer self.allocator.free(response);
    }

    fn consumeDaemonChatTurn(self: *AppState, turn_id: ?[]u8) void {
        const owned_turn_id = turn_id orelse return;
        defer std.heap.page_allocator.free(owned_turn_id);
        const response = sessionizer.requestAlloc(self.allocator, self.storage.pref_path, "chat.turn.consume", .{ .turn_id = owned_turn_id }, 5) catch |err| {
            log.warn("failed to consume daemon chat turn: {s}", .{@errorName(err)});
            return;
        };
        defer self.allocator.free(response);
    }

    fn restoreDaemonChatTurnsOnLaunch(self: *AppState) void {
        const response = sessionizer.requestAlloc(self.allocator, self.storage.pref_path, "chat.turn.list", .{}, 6) catch return;
        defer self.allocator.free(response);
        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, response, .{}) catch return;
        defer parsed.deinit();
        const result = jsonRpcResult(parsed.value) catch return;
        if (result != .object) return;
        const turns = result.object.get("turns") orelse return;
        if (turns != .array) return;
        for (turns.array.items) |turn_value| {
            if (turn_value != .object) continue;
            const workspace_id = jsonValueString(turn_value.object.get("workspace_id") orelse .null) orelse continue;
            const local_thread_id = jsonValueString(turn_value.object.get("local_thread_id") orelse .null) orelse continue;
            const turn_id = jsonValueString(turn_value.object.get("turn_id") orelse .null) orelse continue;
            const status = jsonValueString(turn_value.object.get("status") orelse .null) orelse "running";
            const thread = self.threadByLocalId(workspace_id, local_thread_id) orelse continue;
            const send_state = thread.send_state;
            send_state.mutex.lock();
            if (send_state.status == .idle and !send_state.daemon_owned) {
                send_state.status = .pending;
                send_state.started_at_ms = unixTimestampMs();
                send_state.provider = thread.provider;
                send_state.daemon_turn_id = std.heap.page_allocator.dupe(u8, turn_id) catch null;
                send_state.daemon_last_seq = 0;
                send_state.daemon_owned = send_state.daemon_turn_id != null;
                send_state.ui_revision +%= 1;
                if (std.mem.eql(u8, status, "completed") or std.mem.eql(u8, status, "failed") or std.mem.eql(u8, status, "aborted")) {
                    send_state.polled_working_seconds = 0;
                }
                if (send_state.daemon_owned) self.pending_send_count += 1;
            }
            send_state.mutex.unlock();
        }
    }

    fn threadByLocalId(self: *AppState, workspace_id: []const u8, local_thread_id: []const u8) ?*ChatThread {
        for (self.projects.items) |*project| {
            if (!std.mem.eql(u8, project.id, workspace_id)) continue;
            for (project.threads.items) |*thread| {
                if (std.mem.eql(u8, thread.local_thread_id, local_thread_id)) return thread;
            }
        }
        return null;
    }

    fn applyPersisted(self: *AppState, persisted: PersistedState) !void {
        self.sidebar_collapsed = persisted.sidebar_collapsed;
        if (persisted.projects.len == 0) {
            self.selected_project_index = 0;
            self.next_project_number = 1;
            self.syncRenameBuffer();
            self.dirty = false;
            return;
        }

        for (persisted.projects, 0..) |project, index| {
            const project_id = if (project.id) |persisted_id|
                try self.allocator.dupe(u8, persisted_id)
            else
                try self.deriveProjectId(project.path);
            defer self.allocator.free(project_id);

            var loaded = try Project.init(self.allocator, project_id, project.label, project.path, project.unread_count);
            loaded.archived = project.archived;
            loaded.collapsed = project.collapsed orelse false;
            loaded.thread_list_expanded = project.thread_list_expanded orelse false;
            if (project.herdr_link) |link| {
                loaded.herdr_link = try HerdrWorkspaceLink.initFromPersisted(self.allocator, link);
            }
            if (project.terminal_height) |height| {
                loaded.terminal_dock.preferred_height = terminal.clampPreferredHeight(height);
            }
            loaded.applyDefaultTerminalFontSize(self.app_config.terminal_font_size);
            if (project.terminal_layout_json) |layout_json| {
                loaded.terminal_dock.applyPersistedLayoutJson(self.allocator, layout_json) catch |err| {
                    log.warn("failed to restore terminal layout: {s}", .{@errorName(err)});
                };
            }
            if (project.workspace_layout_json) |layout_json| {
                loaded.workspace_layout.applyPersistedWorkspaceJson(self.allocator, layout_json) catch |err| {
                    log.warn("failed to restore workspace layout: {s}", .{@errorName(err)});
                };
            }
            if (project.terminal_docks_json) |docks_json| {
                self.applyPersistedTerminalDocksJson(&loaded, docks_json) catch |err| {
                    log.warn("failed to restore terminal docks: {s}", .{@errorName(err)});
                };
            }
            for (loaded.threads.items) |*thread| {
                thread.deinit(self.allocator);
            }
            loaded.threads.clearRetainingCapacity();

            if (project.threads) |threads| {
                for (threads) |persisted_thread| {
                    var thread = try ChatThread.init(self.allocator, persisted_thread.title);
                    thread.archived = persisted_thread.archived;
                    thread.committed = persisted_thread.committed;
                    if (persisted_thread.local_thread_id) |local_thread_id| {
                        self.allocator.free(thread.local_thread_id);
                        thread.local_thread_id = try self.allocator.dupeZ(u8, local_thread_id);
                    }
                    thread.last_activity_at = persisted_thread.last_activity_at orelse 0;
                    thread.provider_thread_id = if (persisted_thread.provider_thread_id) |thread_id|
                        try self.allocator.dupeZ(u8, thread_id)
                    else
                        null;
                    if (thread.model_ref) |model_ref| {
                        self.allocator.free(model_ref);
                    }
                    thread.model_ref = if (persisted_thread.model_ref) |model_ref|
                        try self.allocator.dupeZ(u8, model_ref)
                    else
                        null;
                    thread.reasoning_effort = persisted_thread.reasoning_effort;
                    if (thread.opencode_reasoning_variant) |v| self.allocator.free(v);
                    thread.opencode_reasoning_variant = if (persisted_thread.reasoning_variant) |rv|
                        try self.allocator.dupeZ(u8, rv)
                    else
                        null;
                    thread.fast_mode = persisted_thread.fast_mode orelse .off;
                    thread.access_mode = persisted_thread.access_mode orelse .full_access;
                    thread.provider = persisted_thread.provider;
                    thread.harness = persisted_thread.harness;
                    thread.tui_dock_id = persisted_thread.tui_dock_id;
                    thread.setDraft(persisted_thread.draft);
                    if (persisted_thread.draft_image) |image| {
                        try thread.setDraftImage(self.allocator, image.path, image.mime, image.byte_size);
                    }
                    for (persisted_thread.messages) |message| {
                        try thread.messages.append(self.allocator, .{
                            .role = message.role,
                            .author = try self.dupeZ(message.author),
                            .body = try self.dupeZ(message.body),
                            .image = if (message.image) |image|
                                try ChatImageAttachment.init(self.allocator, image.path, image.mime, image.byte_size)
                            else
                                null,
                        });
                    }
                    thread.rebuildBackgroundTasksFromMessages(self.allocator);
                    if (thread.last_activity_at == 0 and thread.messages.items.len > 0) {
                        thread.touch();
                    }
                    if (thread.archived) {
                        try loaded.archived_threads.append(self.allocator, thread);
                    } else {
                        try loaded.threads.append(self.allocator, thread);
                    }
                }
                if (!loaded.archived and loaded.threads.items.len == 0) {
                    _ = try loaded.addThread(self.allocator);
                }
                if (loaded.threads.items.len == 0) {
                    loaded.selected_thread_index = 0;
                } else {
                    loaded.selected_thread_index = @min(project.selected_thread_index, loaded.threads.items.len - 1);
                }
            } else {
                var thread = try ChatThread.init(self.allocator, "New thread");
                thread.archived = project.archived;
                thread.committed = project.messages.len > 0;
                thread.last_activity_at = 0;
                thread.provider = project.provider;
                thread.harness = project.harness;
                thread.setDraft(project.draft);
                for (project.messages) |message| {
                    try thread.messages.append(self.allocator, .{
                        .role = message.role,
                        .author = try self.dupeZ(message.author),
                        .body = try self.dupeZ(message.body),
                        .image = if (message.image) |image|
                            try ChatImageAttachment.init(self.allocator, image.path, image.mime, image.byte_size)
                        else
                            null,
                    });
                }
                thread.rebuildBackgroundTasksFromMessages(self.allocator);
                if (thread.archived) {
                    try loaded.archived_threads.append(self.allocator, thread);
                } else {
                    try loaded.threads.append(self.allocator, thread);
                    loaded.selected_thread_index = 0;
                }
            }

            if (!loaded.archived and index == 0 and project.messages.len == 0 and project.threads == null and persisted.messages != null) {
                var fallback_thread = loaded.currentThreadMutable();
                fallback_thread.provider = persisted.provider orelse fallback_thread.provider;
                fallback_thread.harness = persisted.harness orelse fallback_thread.harness;
                if (persisted.draft) |draft| fallback_thread.setDraft(draft);
                for (persisted.messages.?) |message| {
                    try fallback_thread.messages.append(self.allocator, .{
                        .role = message.role,
                        .author = try self.dupeZ(message.author),
                        .body = try self.dupeZ(message.body),
                        .image = if (message.image) |image|
                            try ChatImageAttachment.init(self.allocator, image.path, image.mime, image.byte_size)
                        else
                            null,
                    });
                }
                fallback_thread.rebuildBackgroundTasksFromMessages(self.allocator);
            }

            try loaded.normalize(self.allocator, self.app_config.terminal_font_size);

            if (loaded.archived) {
                try self.archived_projects.append(self.allocator, loaded);
            } else {
                try self.projects.append(self.allocator, loaded);
            }
        }

        if (self.projects.items.len == 0) {
            self.selected_project_index = 0;
        } else {
            self.selected_project_index = @min(persisted.selected_project_index, self.projects.items.len - 1);
        }
        self.next_project_number = self.projects.items.len + self.archived_projects.items.len + 1;
        self.syncRenameBuffer();
        self.requestTranscriptScrollToBottom();
        self.dirty = false;
    }

    fn buildPersistedState(self: *const AppState, backing_allocator: std.mem.Allocator) !LoadedPersistedState {
        var loaded = LoadedPersistedState.init(backing_allocator);
        errdefer loaded.deinit();

        const arena = loaded.allocator();
        var projects: std.ArrayList(PersistedProject) = .empty;
        defer projects.deinit(arena);

        for (self.projects.items) |project| {
            try projects.append(arena, try self.persistedProjectSnapshot(arena, &project));
        }
        for (self.archived_projects.items) |project| {
            try projects.append(arena, try self.persistedProjectSnapshot(arena, &project));
        }

        loaded.value = .{
            .selected_project_index = self.selected_project_index,
            .sidebar_collapsed = self.sidebar_collapsed,
            .projects = try projects.toOwnedSlice(arena),
        };
        return loaded;
    }

    fn persistedProjectSnapshot(self: *const AppState, allocator: std.mem.Allocator, project: *const Project) !PersistedProject {
        var threads: std.ArrayList(PersistedThread) = .empty;
        defer threads.deinit(allocator);
        const terminal_layout_json = try project.terminal_dock.persistedLayoutJsonWithContext(allocator, .{
            .project_id = project.id,
            .project_path = project.path,
            .dock_id = 0,
        });
        errdefer if (terminal_layout_json) |value| allocator.free(value);
        const terminal_docks_json = try self.persistedTerminalDocksJson(allocator, project);
        errdefer if (terminal_docks_json) |value| allocator.free(value);
        const workspace_layout_json = try project.workspace_layout.persistedWorkspaceJson(allocator);
        errdefer allocator.free(workspace_layout_json);

        for (project.threads.items) |thread| {
            if (!project.archived and !thread.committed) continue;
            try threads.append(allocator, try self.persistedThreadSnapshot(allocator, &thread));
        }
        for (project.archived_threads.items) |thread| {
            try threads.append(allocator, try self.persistedThreadSnapshot(allocator, &thread));
        }

        return .{
            .id = try allocator.dupe(u8, project.id),
            .label = try allocator.dupe(u8, project.label),
            .path = try allocator.dupe(u8, project.path),
            .archived = project.archived,
            .unread_count = project.unread_count,
            .collapsed = project.collapsed,
            .thread_list_expanded = project.thread_list_expanded,
            .terminal_height = project.terminal_dock.preferred_height,
            .terminal_layout_json = terminal_layout_json,
            .terminal_docks_json = terminal_docks_json,
            .workspace_layout_json = workspace_layout_json,
            .selected_thread_index = if (project.threads.items.len == 0) 0 else @min(project.selected_thread_index, project.threads.items.len - 1),
            .herdr_link = if (project.herdr_link) |*link| try link.toPersisted(allocator) else null,
            .threads = try threads.toOwnedSlice(allocator),
        };
    }

    fn persistedTerminalDocksJson(self: *const AppState, allocator: std.mem.Allocator, project: *const Project) !?[]u8 {
        _ = self;
        if (project.terminal_docks.items.len == 0) return null;
        var writer: std.Io.Writer.Allocating = .init(allocator);
        errdefer writer.deinit();
        var stringify: std.json.Stringify = .{ .writer = &writer.writer, .options = .{} };
        try stringify.beginArray();
        for (project.terminal_docks.items) |*entry| {
            const layout_json = try entry.dock.persistedLayoutJsonWithContext(allocator, .{
                .project_id = project.id,
                .project_path = project.path,
                .dock_id = entry.id,
            });
            defer if (layout_json) |value| allocator.free(value);
            if (layout_json == null and !entry.dock.hasRunningSession()) continue;
            try stringify.beginObject();
            try stringify.objectField("id");
            try stringify.write(entry.id);
            try stringify.objectField("layout");
            if (layout_json) |value| {
                try stringify.write(value);
            } else {
                try stringify.write(null);
            }
            try stringify.endObject();
        }
        try stringify.endArray();
        return try writer.toOwnedSlice();
    }

    fn applyPersistedTerminalDocksJson(self: *AppState, project: *Project, json: []const u8) !void {
        var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, json, .{});
        defer parsed.deinit();
        if (parsed.value != .array) return;
        for (parsed.value.array.items) |entry_value| {
            if (entry_value != .object) continue;
            const dock_id: u32 = @intCast(appJsonInt(entry_value.object.get("id") orelse .null) orelse continue);
            if (dock_id == 0) continue;
            var entry = project.terminalDockEntryById(dock_id);
            if (entry == null) {
                var dock = try terminal.Dock.init(self.allocator);
                dock.setDefaultFontSize(self.app_config.terminal_font_size);
                errdefer dock.deinit(self.allocator);
                try project.terminal_docks.append(self.allocator, .{ .id = dock_id, .dock = dock });
                entry = &project.terminal_docks.items[project.terminal_docks.items.len - 1];
            }
            if (entry_value.object.get("layout")) |layout_value| {
                if (appJsonString(layout_value)) |layout_json| {
                    entry.?.dock.applyPersistedLayoutJson(self.allocator, layout_json) catch |err| {
                        log.warn("failed to restore terminal dock {d} layout: {s}", .{ dock_id, @errorName(err) });
                    };
                }
            }
            if (project.next_terminal_dock_id <= dock_id) project.next_terminal_dock_id = dock_id + 1;
        }
    }

    fn appJsonString(value: std.json.Value) ?[]const u8 {
        return switch (value) {
            .string => |s| s,
            else => null,
        };
    }

    fn appJsonInt(value: std.json.Value) ?i64 {
        return switch (value) {
            .integer => |i| i,
            .float => |f| @intFromFloat(f),
            else => null,
        };
    }

    fn persistedThreadSnapshot(self: *const AppState, allocator: std.mem.Allocator, thread: *const ChatThread) !PersistedThread {
        var messages: std.ArrayList(PersistedMessage) = .empty;
        defer messages.deinit(allocator);

        for (thread.messages.items) |message| {
            try messages.append(allocator, try self.persistedMessageSnapshot(allocator, &message));
        }

        return .{
            .title = try allocator.dupe(u8, thread.title),
            .archived = thread.archived,
            .committed = thread.committed,
            .local_thread_id = try allocator.dupe(u8, thread.local_thread_id),
            .last_activity_at = if (thread.last_activity_at == 0) null else thread.last_activity_at,
            .provider_thread_id = try dupeOptionalSlice(allocator, thread.provider_thread_id),
            .model_ref = try dupeOptionalSlice(allocator, thread.model_ref),
            .reasoning_effort = thread.reasoning_effort,
            .reasoning_variant = try dupeOptionalSlice(allocator, if (thread.opencode_reasoning_variant) |v| v else null),
            .fast_mode = thread.fast_mode,
            .access_mode = thread.access_mode,
            .provider = thread.provider,
            .harness = thread.harness,
            .tui_dock_id = thread.tui_dock_id,
            .draft = try allocator.dupe(u8, thread.currentDraft()),
            .draft_image = try persistedImageSnapshot(allocator, thread.draft_image),
            .messages = try messages.toOwnedSlice(allocator),
        };
    }

    fn persistedMessageSnapshot(self: *const AppState, allocator: std.mem.Allocator, message: *const ChatMessage) !PersistedMessage {
        _ = self;
        return .{
            .role = message.role,
            .author = try allocator.dupe(u8, message.author),
            .body = try allocator.dupe(u8, message.body),
            .image = try persistedImageSnapshot(allocator, message.image),
        };
    }

    fn seedDefaultState(self: *AppState) !void {
        self.selected_project_index = 0;
        self.next_project_number = 1;
        self.syncRenameBuffer();
        self.requestTranscriptScrollToBottom();
        self.dirty = false;
    }

    pub fn currentProject(self: *const AppState) *const Project {
        return &self.projects.items[self.selected_project_index];
    }

    pub fn currentProjectMutable(self: *AppState) *Project {
        return &self.projects.items[self.selected_project_index];
    }

    pub fn canOpenCurrentProjectDirectory(self: *const AppState) bool {
        return self.projects.items.len > 0 and utils.canOpenProjectDirectory();
    }

    pub fn canOpenCurrentProjectEditor(self: *const AppState, target: ProjectEditorTarget) bool {
        if (self.projects.items.len == 0) return false;
        if (target == .configured and utils.configuredEditorIsNeovim()) return true;
        return utils.canOpenProjectEditor(target);
    }

    pub fn configuredEditorDisplayName(self: *const AppState) ?[]const u8 {
        _ = self;
        return utils.configuredEditorDisplayName();
    }

    pub fn defaultOpenButtonLabel(self: *const AppState) []const u8 {
        return switch (self.app_config.default_open_action) {
            .custom => |custom| custom.label,
            else => "Open",
        };
    }

    pub fn canRunDefaultOpenAction(self: *const AppState) bool {
        if (self.projects.items.len == 0) return false;
        return switch (self.app_config.default_open_action) {
            .folder => self.canOpenCurrentProjectDirectory(),
            .editor => self.canOpenCurrentProjectEditor(.configured),
            .cursor => self.canOpenCurrentProjectEditor(.cursor),
            .vscode => self.canOpenCurrentProjectEditor(.vscode),
            .zed => self.canOpenCurrentProjectEditor(.zed),
            .custom => |custom| custom.action.len > 0,
        };
    }

    pub fn defaultOpenTooltip(self: *const AppState) []const u8 {
        return switch (self.app_config.default_open_action) {
            .folder => if (self.canOpenCurrentProjectDirectory()) "Open this workspace's folder" else "No system folder opener was found",
            .editor => if (self.canOpenCurrentProjectEditor(.configured)) "Open this workspace in the configured editor" else "Configured editor is unavailable",
            .cursor => if (self.canOpenCurrentProjectEditor(.cursor)) "Open this workspace in Cursor" else "Cursor is unavailable",
            .vscode => if (self.canOpenCurrentProjectEditor(.vscode)) "Open this workspace in VS Code" else "VS Code is unavailable",
            .zed => if (self.canOpenCurrentProjectEditor(.zed)) "Open this workspace in Zed" else "Zed is unavailable",
            .custom => |custom| if (custom.action.len > 0) custom.label else "Custom open action is unavailable",
        };
    }

    pub fn defaultOpenShowsFolderIcon(self: *const AppState) bool {
        return self.app_config.default_open_action == .folder;
    }

    pub fn defaultOpenIconTexture(self: *const AppState) ?CachedImageTexture {
        return switch (self.app_config.default_open_action) {
            .folder => null,
            .editor => self.editorLogoTextureForTarget(.configured),
            .cursor => self.editorLogoTextureForTarget(.cursor),
            .vscode => self.editorLogoTextureForTarget(.vscode),
            .zed => self.editorLogoTextureForTarget(.zed),
            .custom => |custom| self.editorLogoTextureForCommand(utils.executableNameForCommand(custom.action)),
        };
    }

    pub fn runDefaultOpenAction(self: *AppState) void {
        if (self.projects.items.len == 0) {
            self.setSidebarNotice("No workspace selected.");
            return;
        }

        log.info("runDefaultOpenAction invoked for workspace path={s}", .{self.currentProject().path});

        switch (self.app_config.default_open_action) {
            .folder => self.openCurrentProjectDirectory(),
            .editor => self.openCurrentProjectEditor(.configured),
            .cursor => self.openCurrentProjectEditor(.cursor),
            .vscode => self.openCurrentProjectEditor(.vscode),
            .zed => self.openCurrentProjectEditor(.zed),
            .custom => |custom| self.runCustomOpenAction(custom),
        }
    }

    pub fn shouldSuppressExternalOpenCloseRequest(self: *AppState, now_ms: i64) bool {
        if (self.external_open_close_suppress_until_ms < now_ms) return false;
        self.external_open_close_suppress_until_ms = 0;
        return true;
    }

    pub fn replaceAppConfig(self: *AppState, next_config: app_config.AppConfig) void {
        self.app_config.deinit(self.allocator);
        self.app_config = next_config;
    }

    pub fn syncSettingsDraftFromConfig(self: *AppState) void {
        self.settings_draft = .{
            .font_size = self.app_config.font_size,
            .terminal_font_size = self.app_config.terminal_font_size,
            .theme_source = self.app_config.theme_config.source,
            .open_action = settingsOpenActionFromConfig(self.app_config.default_open_action),
            .link_open_target = self.app_config.link_open_target,
            .notifications_enabled = self.app_config.notifications_enabled,
        };
    }

    pub fn isSettingsDraftDirty(self: *const AppState) bool {
        const draft = self.settings_draft;
        if (draft.font_size != self.app_config.font_size) return true;
            .check_for_updates_automatically = self.app_config.check_for_updates_automatically,
        if (draft.terminal_font_size != self.app_config.terminal_font_size) return true;
        if (draft.theme_source != self.app_config.theme_config.source) return true;
        if (draft.link_open_target != self.app_config.link_open_target) return true;
        if (draft.notifications_enabled != self.app_config.notifications_enabled) return true;
        return draft.open_action != settingsOpenActionFromConfig(self.app_config.default_open_action);
    }

    pub fn openSettingsModal(self: *AppState) void {
        self.closeSidebarContextMenu();
        self.workspace_header_open_menu_open = false;
        if (draft.check_for_updates_automatically != self.app_config.check_for_updates_automatically) return true;
        self.workspace_header_open_menu_pane_id = null;
        self.browser_inspector_menu_open = false;
        self.syncSettingsDraftFromConfig();
        self.settings_hook_claude_installed = provider_hooks.claudeGlobalHooksInstalled(self.allocator);
        self.settings_hook_codex_installed = provider_hooks.codexGlobalHooksInstalled(self.allocator);
        self.settings_hook_amp_installed = provider_hooks.ampGlobalHooksInstalled(self.allocator);
        self.settings_scroll_y = 0.0;
        self.settings_hover_control = null;
        self.settings_close_hovered = false;
        self.show_settings_modal = true;
        self.palette_modal_text_focus = .none;
        self.blurPaletteComposer();
        self.noteInteraction();
        self.markDirty();
    }

    /// Installs or removes the global Claude notify hooks and refreshes the
        if (self.app_config.check_for_updates_automatically and self.update_state.status == .idle) {
            self.update_state.start();
        }
    /// settings toggle state. Acts immediately (filesystem side effect).
    pub fn toggleClaudeGlobalHooks(self: *AppState) void {
        if (self.settings_hook_claude_installed) {
            provider_hooks.removeClaudeGlobalHooks(self.allocator) catch |err| {
                log.warn("failed to remove global Claude hooks: {s}", .{@errorName(err)});
                self.setSidebarNotice("Could not remove Claude hooks.");
                self.markDirty();
                return;
            };
            self.settings_hook_claude_installed = false;
            self.setSidebarNotice("Disabled global Claude status hooks.");
        } else {
            provider_hooks.ensureClaudeGlobalHooks(self.allocator) catch |err| {
                log.warn("failed to install global Claude hooks: {s}", .{@errorName(err)});
                self.setSidebarNotice("Could not install Claude hooks.");
                self.markDirty();
                return;
            };
            self.settings_hook_claude_installed = true;
            self.setSidebarNotice("Enabled global Claude status hooks.");
        }
        self.markDirty();
    }

    /// Installs or removes the global Codex notify hooks and refreshes the
    /// settings toggle state. Merges into ~/.codex/hooks.json, preserving any
    /// user-owned hooks. Acts immediately (filesystem side effect).
    pub fn toggleCodexGlobalHooks(self: *AppState) void {
        if (self.settings_hook_codex_installed) {
            provider_hooks.removeCodexGlobalHooks(self.allocator) catch |err| {
                log.warn("failed to remove global Codex hooks: {s}", .{@errorName(err)});
                self.setSidebarNotice("Could not remove Codex hooks.");
                self.markDirty();
                return;
            };
            self.settings_hook_codex_installed = false;
            self.setSidebarNotice("Disabled global Codex status hooks.");
        } else {
            provider_hooks.ensureCodexGlobalHooks(self.allocator) catch |err| {
                log.warn("failed to install global Codex hooks: {s}", .{@errorName(err)});
                self.setSidebarNotice("Could not install Codex hooks.");
                self.markDirty();
                return;
            };
            self.settings_hook_codex_installed = true;
            self.setSidebarNotice("Enabled global Codex status hooks.");
        }
        self.markDirty();
    }

    /// Installs or removes the global Amp notify plugin and refreshes the
    /// settings toggle state. Acts immediately (filesystem side effect), like
    /// the Claude/Codex toggles.
    pub fn toggleAmpGlobalHooks(self: *AppState) void {
        if (self.settings_hook_amp_installed) {
            provider_hooks.removeAmpGlobalHooks(self.allocator) catch |err| {
                log.warn("failed to remove global Amp hooks: {s}", .{@errorName(err)});
                self.setSidebarNotice("Could not remove Amp hooks.");
                self.markDirty();
                return;
            };
            self.settings_hook_amp_installed = false;
            self.setSidebarNotice("Disabled global Amp status hooks.");
        } else {
            provider_hooks.ensureAmpGlobalHooks(self.allocator) catch |err| {
                log.warn("failed to install global Amp hooks: {s}", .{@errorName(err)});
                self.setSidebarNotice("Could not install Amp hooks.");
                self.markDirty();
                return;
            };
            self.settings_hook_amp_installed = true;
            self.setSidebarNotice("Enabled global Amp status hooks.");
        }
        self.markDirty();
    }

    pub fn cancelSettingsModal(self: *AppState) void {
        self.show_settings_modal = false;
        self.settings_hover_control = null;
        self.settings_close_hovered = false;
        self.syncSettingsDraftFromConfig();
        self.palette_modal_text_focus = .none;
        self.markDirty();
    }

    pub fn saveSettingsModal(self: *AppState) !void {
        runtime_log.diagnostic("settings save begin theme={s} font={d:.2} terminal_font={d:.2}", .{
            @tagName(self.settings_draft.theme_source),
            self.settings_draft.font_size,
            self.settings_draft.terminal_font_size,
        });
        self.app_config.font_size = theme.clampf(self.settings_draft.font_size, app_config.MIN_FONT_SIZE, app_config.MAX_FONT_SIZE);
        self.app_config.terminal_font_size = theme.clampf(self.settings_draft.terminal_font_size, app_config.MIN_TERMINAL_FONT_SIZE, app_config.MAX_TERMINAL_FONT_SIZE);
        self.app_config.theme_config.source = self.settings_draft.theme_source;
        self.app_config.link_open_target = self.settings_draft.link_open_target;
        self.app_config.notifications_enabled = self.settings_draft.notifications_enabled;
        try self.applySettingsDraftOpenAction();

        try app_config.saveAppConfig(self.allocator, &self.app_config);
        self.app_config_file_mtime = app_config.configFileMtime(self.allocator) catch self.app_config_file_mtime;
        self.applyTerminalFontSizesFromConfig();
        self.app_config_runtime_sync_pending = true;
        const previous_auto_update_check = self.app_config.check_for_updates_automatically;
        errdefer self.app_config.check_for_updates_automatically = previous_auto_update_check;
        self.app_config.check_for_updates_automatically = self.settings_draft.check_for_updates_automatically;
        self.show_settings_modal = false;
        self.settings_hover_control = null;
        self.settings_close_hovered = false;
        self.palette_modal_text_focus = .none;
        self.markDirty();
        runtime_log.diagnostic("settings save done", .{});
    }

    pub fn applyTerminalFontSizesFromConfig(self: *AppState) void {
        for (self.projects.items) |*project| {
            project.applyDefaultTerminalFontSize(self.app_config.terminal_font_size);
        }
    }

    pub fn reloadAppConfigFromDisk(self: *AppState) !void {
        const next_config = try app_config.loadAppConfig(self.allocator);
        self.replaceAppConfig(next_config);
        self.applyTerminalFontSizesFromConfig();
        if (self.show_settings_modal) self.syncSettingsDraftFromConfig();
    }

    pub fn isSettingsModalOpen(self: *const AppState) bool {
        return self.show_settings_modal;
    }

    fn applySettingsDraftOpenAction(self: *AppState) !void {
        if (self.settings_draft.open_action == .custom) return;

        const next: app_config.DefaultOpenAction = switch (self.settings_draft.open_action) {
            .folder => .folder,
            .editor => .editor,
            .cursor => .cursor,
    pub fn startUpdateCheck(self: *AppState) void {
        self.update_state.start();
        self.markDirty();
    }

    pub fn startAutomaticUpdateCheck(self: *AppState) void {
        if (self.app_config.check_for_updates_automatically) self.startUpdateCheck();
    }

    pub fn pollUpdateCheck(self: *AppState) void {
        const previous = self.update_state.status;
        self.update_state.poll();
        if (self.update_state.status != previous) self.markDirty();
    }

    pub fn installAvailableUpdate(self: *AppState) void {
        if (self.update_installer_started) return;
        const launch = update_installer.launch(self.allocator) catch |err| {
            log.warn("failed to launch update installer: {s}", .{@errorName(err)});
            const url = self.update_state.downloadUrl() orelse updater.State.releasesUrl();
            utils.openUrlInDefaultBrowser(self.allocator, url) catch {
                self.setSidebarNotice("Could not start the installer or open the release download.");
                return;
            };
            self.setSidebarNotice("Could not start the installer; opened the release download instead.");
            return;
        };
        self.update_installer_started = true;
        self.update_exit_requested = launch == .started_and_exit_required;
        self.setSidebarNotice(if (self.update_exit_requested)
            "Restarting to install the Verde update…"
        else
            "Verde update installer started. Restart Verde when it completes.");
        self.markDirty();
    }

    pub fn consumeUpdateExitRequest(self: *AppState) bool {
        if (!self.update_exit_requested) return false;
        self.update_exit_requested = false;
        return true;
    }

            .vscode => .vscode,
            .zed => .zed,
            .custom => unreachable,
        };
        const next_tag = std.meta.activeTag(next);
        if (std.meta.activeTag(self.app_config.default_open_action) == next_tag) return;
        self.app_config.default_open_action.deinit(self.allocator);
        self.app_config.default_open_action = next;
    }

    fn settingsOpenActionFromConfig(action: app_config.DefaultOpenAction) SettingsOpenAction {
        return switch (action) {
            .folder => .folder,
            .editor => .editor,
            .cursor => .cursor,
            .vscode => .vscode,
            .zed => .zed,
            .custom => .custom,
        };
    }

    pub fn rethemeTerminalSessions(self: *AppState) !void {
        for (self.projects.items) |*project| {
            try project.terminal_dock.rethemeSessions(self.allocator);
            for (project.terminal_docks.items) |*entry| {
                try entry.dock.rethemeSessions(self.allocator);
            }
        }
    }

    pub fn clearSurfaces(self: *AppState) void {
        for (self.surfaces.items) |*surface| surface.deinit(self.allocator);
        self.surfaces.clearRetainingCapacity();
    }

    pub fn surfaceBySessionId(self: *AppState, session_id: []const u8) ?*SurfaceState {
        for (self.surfaces.items) |*surface| {
            if (std.mem.eql(u8, surface.session_id, session_id)) return surface;
        }
        return null;
    }

    pub fn surfaceBySessionIdConst(self: *const AppState, session_id: []const u8) ?*const SurfaceState {
        for (self.surfaces.items) |*surface| {
            if (std.mem.eql(u8, surface.session_id, session_id)) return surface;
        }
        return null;
    }

    pub fn updateSurface(self: *AppState, update: SurfaceUpdate) !*SurfaceState {
        var surface = self.surfaceBySessionId(update.session_id);
        if (surface == null) {
            try self.surfaces.append(self.allocator, .{
                .session_id = try self.allocator.dupe(u8, update.session_id),
                .workspace_id = try self.allocator.dupe(u8, update.workspace_id orelse ""),
                .workspace_path = try self.allocator.dupe(u8, update.workspace_path orelse ""),
                .dock_id = update.dock_id orelse 0,
                .pane_id = update.pane_id,
                .title = try self.allocator.dupe(u8, update.title orelse ""),
            });
            surface = &self.surfaces.items[self.surfaces.items.len - 1];
        }
        var s = surface.?;
        // Remember the status before this update so we can fire a one-shot
        // desktop notification only on the `!= .done` -> `.done` transition.
        const prev_status = s.status;
        if (update.workspace_id) |value| try replaceOwnedSlice(self.allocator, &s.workspace_id, value);
        if (update.workspace_path) |value| try replaceOwnedSlice(self.allocator, &s.workspace_path, value);
        if (update.dock_id) |value| s.dock_id = value;
        if (update.pane_id) |value| s.pane_id = value;
        if (update.provider) |value| {
            s.provider = value;
            // Pin the provider on the terminal tab so the sidebar can draw the
            // logo after a restart, before the agent process revives.
            if (self.terminalDockForSurface(s)) |dock| {
                _ = dock.setActiveTabPinnedProvider(self.allocator, @tagName(value));
            }
        }
        if (update.provider_thread_id) |value| try replaceOwnedOptionalSlice(self.allocator, &s.provider_thread_id, value);
        if (update.title) |value| {
            try replaceOwnedSlice(self.allocator, &s.title, value);
            // Pin the title on the terminal tab so it persists across restarts
            // (surfaces are in-memory only) and survives Codex's folder-name OSC.
            if (value.len > 0) {
                if (self.terminalDockForSurface(s)) |dock| {
                    _ = dock.setActiveTabPinnedTitle(self.allocator, value);
                }
            }
        }
        if (update.clear) {
            s.status = .idle;
            s.progress = null;
            s.attention = false;
            s.unread_count = 0;
            try replaceOwnedOptionalSlice(self.allocator, &s.last_event_title, null);
            try replaceOwnedOptionalSlice(self.allocator, &s.last_event_body, null);
            _ = self.clearTerminalNotificationBySession(update.session_id);
        } else {
            if (update.status) |value| s.status = value;
            if (update.progress) |value| s.progress = theme.clampf(value, 0.0, 1.0);
            if (update.attention) |value| s.attention = value;
            if (update.unread_increment > 0) s.unread_count +|= update.unread_increment;
            if (update.last_event_title) |value| {
                try replaceOwnedOptionalSlice(self.allocator, &s.last_event_title, value);
                s.last_event_at_ms = unixTimestampMs();
            }
            if (update.last_event_body) |value| {
                try replaceOwnedOptionalSlice(self.allocator, &s.last_event_body, value);
                s.last_event_at_ms = unixTimestampMs();
            }
        }
        // Notify on the completion edge. Runs on the main thread (live commands
        // are drained from the main loop), so spawning the notifier here is safe.
        if (!update.clear and self.app_config.notifications_enabled and
            prev_status != .done and s.status == .done)
        {
            self.fireCompletionNotification(s);
        }
        self.markDirty();
        return s;
    }

    // Resolves the terminal dock that owns a surface (by workspace + dock id),
    // so notify-provided metadata can be pinned onto its tab. Surfaces are
    // in-memory only; pinning onto the tab persists across restarts via the
    // workspace layout.
    fn terminalDockForSurface(self: *AppState, surface: *const SurfaceState) ?*terminal.Dock {
        for (self.projects.items, 0..) |*project, idx| {
            const owns = std.mem.eql(u8, surface.workspace_id, project.id) or
                self.projectPathMatches(surface.workspace_path, project.path);
            if (!owns) continue;
            return self.projectTerminalDockMutable(idx, surface.dock_id);
        }
        return null;
    }

    // Resolves which agent provider a surface belongs to, for the notification
    // logo/title. Only trust explicit notify metadata: falling back to a
    // workspace chat provider can mislabel one terminal agent as another (for
    // example an Amp pane in a workspace whose first saved chat is Codex).
    fn resolveSurfaceProvider(self: *const AppState, surface: *const SurfaceState) ?Provider {
        _ = self;
        if (surface.provider) |p| return p;
        return null;
    }

    // Builds a human-readable title/body from the surface and hands off to the
    // cross-platform notifier. Title prefers the surface's own label, then the
    // provider name; the body names the workspace directory so multiple agents
    // stay distinguishable. The provider also selects the notification logo.
    fn fireCompletionNotification(self: *AppState, surface: *const SurfaceState) void {
        const provider = self.resolveSurfaceProvider(surface);
        const dir = if (surface.workspace_path.len > 0)
            std.fs.path.basename(surface.workspace_path)
        else
            "";

        var title_buf: [128]u8 = undefined;
        const title = if (surface.title.len > 0)
            surface.title
        else if (provider) |p|
            (std.fmt.bufPrint(&title_buf, "{s} finished", .{utils.providerLabel(p)}) catch "Agent finished")
        else
            "Agent finished";

        var body_buf: [256]u8 = undefined;
        const body = if (dir.len > 0)
            (std.fmt.bufPrint(&body_buf, "Completed in {s}", .{dir}) catch "Task completed")
        else
            "Task completed";

        const icon: ?notifier.Icon = if (provider) |p| switch (p) {
            .codex => .{ .key = "codex", .png_bytes = CODEX_LOGO_BYTES },
            .opencode => .{ .key = "opencode", .png_bytes = OPENCODE_LOGO_BYTES },
            .claude => .{ .key = "claude", .png_bytes = CLAUDE_LOGO_BYTES },
            .cursor => .{ .key = "cursor", .png_bytes = CURSOR_LOGO_BYTES },
        } else null;

        notifier.notifyAgentDone(self.allocator, title, body, icon);
    }

    pub fn clearSurfaceAttentionBySession(self: *AppState, session_id: []const u8) bool {
        const terminal_changed = self.clearTerminalNotificationBySession(session_id);
        const surface = self.surfaceBySessionId(session_id) orelse return terminal_changed;
        // Focusing the pane acknowledges a finished turn, so clear the "done"
        // indicator — it shouldn't re-appear in the sidebar once you've come
        // back and looked. Genuine waiting/error states persist (you still need
        // to act on them).
        const done_ack = surface.status == .done;
        if (!surface.attention and surface.unread_count == 0 and !done_ack) return terminal_changed;
        surface.attention = false;
        surface.unread_count = 0;
        if (done_ack) surface.status = .idle;
        self.markDirty();
        return true;
    }

    fn clearTerminalNotificationBySession(self: *AppState, session_id: []const u8) bool {
        var changed = false;
        for (self.projects.items) |*project| {
            if (project.terminal_dock.clearNotificationForSession(session_id)) changed = true;
            for (project.terminal_docks.items) |*entry| {
                if (entry.dock.clearNotificationForSession(session_id)) changed = true;
            }
        }
        return changed;
    }

    pub fn terminalDockSurfaceAttention(self: *const AppState, project_index: usize, dock_id: u32) bool {
        if (project_index >= self.projects.items.len) return false;
        const dock = self.projectTerminalDock(project_index, dock_id) orelse return false;
        const session_id = dock.activeSessionId() orelse return false;
        const surface = self.surfaceBySessionIdConst(session_id) orelse return false;
        return surface.attention or surface.unread_count > 0 or surface.status == .waiting or surface.status == .@"error";
    }

    pub fn projectSurfaceAttention(self: *const AppState, project_index: usize) bool {
        if (project_index >= self.projects.items.len) return false;
        const project = &self.projects.items[project_index];
        for (self.surfaces.items) |*surface| {
            if (std.mem.eql(u8, surface.workspace_id, project.id) or self.projectPathMatches(surface.workspace_path, project.path)) {
                if (!project.workspace_layout.hasTerminalDockPane(surface.dock_id)) continue;
                // The pane you're actively in shouldn't raise a background alert.
                if (self.isFocusedTerminalSurface(project_index, surface.dock_id)) continue;
                if (surface.attention or surface.unread_count > 0 or surface.status == .waiting or surface.status == .@"error") return true;
            }
        }
        return false;
    }

    /// True when (project_index, dock_id) is the terminal pane the user is
    /// currently focused in — used to suppress its own sidebar status/attention
    /// indicators (you're already looking at it).
    pub fn isFocusedTerminalSurface(self: *const AppState, project_index: usize, dock_id: u32) bool {
        if (!self.terminal_focused) return false;
        if (project_index != self.selected_project_index) return false;
        if (project_index >= self.projects.items.len) return false;
        const layout = &self.projects.items[project_index].workspace_layout;
        const pane_id = layout.focused_pane_id orelse return false;
        const pane = layout.paneById(pane_id) orelse return false;
        return switch (pane.ref) {
            .terminal => |ref| ref.dock_id == dock_id,
            else => false,
        };
    }

    /// Returns the terminal surface (if any) bound to a given dock within a
    /// workspace, so the sidebar can render per-pane agent status.
    pub fn projectTerminalSurface(self: *const AppState, project_index: usize, dock_id: u32) ?*const SurfaceState {
        if (project_index >= self.projects.items.len) return null;
        const project = &self.projects.items[project_index];
        for (self.surfaces.items) |*surface| {
            if (surface.dock_id != dock_id) continue;
            if (std.mem.eql(u8, surface.workspace_id, project.id) or self.projectPathMatches(surface.workspace_path, project.path)) {
                return surface;
            }
        }
        return null;
    }

    /// Selects a workspace and focuses one of its open layout panes directly
    /// from the sidebar's live "OPEN" list, restoring it first if minimized.
    pub fn focusWorkspaceOpenPane(self: *AppState, project_index: usize, pane_id: WorkspacePaneId) void {
        if (project_index >= self.projects.items.len) return;
        self.selected_project_index = project_index;
        var project = &self.projects.items[project_index];
        var layout = &project.workspace_layout;
        var target: ?*WorkspacePane = null;
        for (layout.panes.items) |*pane| {
            if (pane.id == pane_id) {
                target = pane;
                break;
            }
        }
        const pane = target orelse return;
        if (pane.minimized) {
            pane.minimized = false;
            layout.ensurePaneInRootSplit(self.allocator, pane_id, .horizontal, 0.64) catch |err| {
                log.err("failed to restore workspace pane from sidebar: {s}", .{@errorName(err)});
            };
        }
        layout.focused_pane_id = pane_id;
        layout.maximized_pane_id = null;
        switch (pane.ref) {
            .chat => |ref| {
                self.terminal_focused = false;
                project.selected_thread_index = ref.thread_index;
                self.requestComposerFocus();
            },
            .terminal => self.requestTerminalFocus(),
            .browser => {
                self.terminal_focused = false;
                self.composer_focused = false;
                self.browser_state.setControlsVisible(true);
                self.browser_state.controller.show() catch |err| {
                    log.warn("failed to show browser pane from sidebar: {s}", .{@errorName(err)});
                };
            },
        }
        self.markDirty();
    }

    fn replaceOwnedSlice(allocator: std.mem.Allocator, dest: *[]u8, value: []const u8) !void {
        const next = try allocator.dupe(u8, value);
        allocator.free(dest.*);
        dest.* = next;
    }

    fn replaceOwnedOptionalSlice(allocator: std.mem.Allocator, dest: *?[]u8, value: ?[]const u8) !void {
        const next = if (value) |v| try allocator.dupe(u8, v) else null;
        if (dest.*) |old| allocator.free(old);
        dest.* = next;
    }

    pub fn hasCustomTerminalLaunchProfile(self: *const AppState) bool {
        return self.app_config.terminal_launch_profiles.len > 0;
    }

    pub fn customTerminalLaunchProfileLabel(self: *const AppState) []const u8 {
        if (self.app_config.terminal_launch_profiles.len == 0) return "Custom";
        return self.app_config.terminal_launch_profiles[0].label;
    }

    pub fn firstCustomTerminalLaunchProfile(self: *const AppState) ?terminal.TerminalLaunchProfile {
        if (self.app_config.terminal_launch_profiles.len == 0) return null;
        const profile = self.app_config.terminal_launch_profiles[0];
        return .{
            .kind = .custom,
            .label = profile.label,
            .command = profile.command,
        };
    }

    pub fn configuredEditorLogoTexture(self: *const AppState) ?CachedImageTexture {
        const name = utils.configuredEditorDisplayName() orelse return null;
        return self.editorLogoTextureForCommand(name);
    }

    pub fn editorLogoTextureForTarget(self: *const AppState, target: ProjectEditorTarget) ?CachedImageTexture {
        return switch (target) {
            .configured => self.configuredEditorLogoTexture(),
            .cursor => self.cursor_logo_texture,
            .vscode => self.vscode_logo_texture,
            .zed => self.zed_logo_texture,
        };
    }

    fn editorLogoTextureForCommand(self: *const AppState, command: []const u8) ?CachedImageTexture {
        if (std.ascii.eqlIgnoreCase(command, "cursor")) return self.cursor_logo_texture;
        if (std.ascii.eqlIgnoreCase(command, "code") or std.ascii.eqlIgnoreCase(command, "code-insiders")) return self.vscode_logo_texture;
        if (std.ascii.eqlIgnoreCase(command, "zed") or std.ascii.eqlIgnoreCase(command, "zeditor")) return self.zed_logo_texture;
        if (std.ascii.eqlIgnoreCase(command, "nvim")) return self.neovim_logo_texture;
        if (std.ascii.eqlIgnoreCase(command, "emacs") or std.ascii.eqlIgnoreCase(command, "emacsclient")) return self.emacs_logo_texture;
        return null;
    }

    pub fn openCurrentProjectDirectory(self: *AppState) void {
        if (self.projects.items.len == 0) {
            self.setSidebarNotice("No workspace selected.");
            return;
        }

        utils.openProjectDirectory(self.allocator, self.currentProject().path) catch |err| {
            log.warn("failed to open workspace directory: {s}", .{@errorName(err)});
            self.setSidebarNotice("Failed to open workspace folder.");
            return;
        };
        log.info("openCurrentProjectDirectory completed", .{});
        self.external_open_close_suppress_until_ms = unixTimestampMs() + EXTERNAL_OPEN_CLOSE_SUPPRESS_MS;
        runtime_log.diagnostic("openCurrentProjectDirectory close suppress until={d}", .{self.external_open_close_suppress_until_ms});
        self.setSidebarNotice("Opened workspace folder.");
    }

    pub fn openCurrentProjectEditor(self: *AppState, target: ProjectEditorTarget) void {
        if (self.projects.items.len == 0) {
            self.setSidebarNotice("No workspace selected.");
            return;
        }

        if (target == .configured and utils.configuredEditorIsNeovim()) {
            self.openCurrentProjectNeovimEditorPane();
            return;
        }

        utils.openProjectEditor(self.allocator, self.currentProject().path, target) catch |err| {
            log.warn("failed to open workspace editor: {s}", .{@errorName(err)});
            self.setSidebarNotice("Failed to open workspace editor.");
            return;
        };
        log.info("openCurrentProjectEditor target={s} completed", .{@tagName(target)});
        self.setSidebarNotice(projectEditorOpenedNotice(target));
    }

    fn openCurrentProjectNeovimEditorPane(self: *AppState) void {
        const command = utils.configuredEditorTerminalCommandAlloc(self.allocator) catch |err| {
            log.warn("failed to build Neovim editor command: {s}", .{@errorName(err)});
            self.setSidebarNotice("Failed to open workspace editor.");
            return;
        } orelse {
            utils.openProjectEditor(self.allocator, self.currentProject().path, .configured) catch |err| {
                log.warn("failed to open workspace editor: {s}", .{@errorName(err)});
                self.setSidebarNotice("Failed to open workspace editor.");
            };
            return;
        };
        defer self.allocator.free(command);

        const pane_id = self.openCurrentProjectTerminalPaneForCommand() orelse return;
        _ = self.writeWorkspaceTerminalPane(pane_id, command) catch |err| {
            log.warn("failed to write Neovim editor command: {s}", .{@errorName(err)});
            self.setSidebarNotice("Failed to open workspace editor.");
            return;
        };
        self.setSidebarNotice("Opened workspace in Neovim.");
        self.markDirty();
    }

    pub fn openTranscriptFileReference(self: *AppState, file_path: []const u8) void {
        const normalized = std.mem.trim(u8, if (std.mem.startsWith(u8, file_path, "file://localhost/"))
            file_path["file://localhost".len..]
        else if (std.mem.startsWith(u8, file_path, "file://"))
            file_path["file://".len..]
        else
            file_path, &std.ascii.whitespace);
        if (normalized.len == 0) {
            self.setSidebarNotice("No file reference selected.");
            return;
        }

        const resolved_path = if (std.fs.path.isAbsolute(normalized)) resolved: {
            break :resolved self.allocator.dupe(u8, normalized) catch |err| {
                log.warn("failed to copy transcript file reference: {s}", .{@errorName(err)});
                self.setSidebarNotice("Failed to open file reference.");
                return;
            };
        } else resolved: {
            break :resolved std.fs.path.join(self.allocator, &.{ self.currentProject().path, normalized }) catch |err| {
                log.warn("failed to resolve transcript file reference: {s}", .{@errorName(err)});
                self.setSidebarNotice("Failed to open file reference.");
                return;
            };
        };
        defer self.allocator.free(resolved_path);

        const result = utils.openFilePreferEditor(self.allocator, resolved_path) catch |err| {
            log.warn("failed to open transcript file reference: {s}", .{@errorName(err)});
            self.setSidebarNotice("Failed to open file reference.");
            return;
        };

        switch (result) {
            .editor => self.setSidebarNotice("Opened file in editor."),
            .file_manager => self.setSidebarNotice("Opened containing folder."),
        }
    }

    pub fn openTranscriptWebLink(self: *AppState, href: []const u8) void {
        self.openConfiguredWebLink(href);
    }

    pub fn openConfiguredWebLink(self: *AppState, href: []const u8) void {
        const trimmed = std.mem.trim(u8, href, &std.ascii.whitespace);
        if (trimmed.len == 0) {
            self.setSidebarNotice("No web link selected.");
            return;
        }

        if (self.app_config.link_open_target == .system_browser) {
            utils.openUrlInDefaultBrowser(self.allocator, trimmed) catch |err| {
                log.warn("failed to open web link in system browser: {s}", .{@errorName(err)});
                self.setSidebarNotice("Failed to open web link in default browser.");
                return;
            };
            self.setSidebarNotice("Opened web link in default browser.");
            return;
        }

        if (self.projects.items.len == 0) {
            self.setSidebarNotice("No workspace selected.");
            return;
        }

        _ = self.openBrowserInWorkspace(self.selected_project_index, trimmed) catch |err| switch (err) {
            error.WorkspaceNotFound => self.setSidebarNotice("No workspace selected."),
            error.BrowserDisabled => self.setSidebarNotice("Browser is disabled."),
            error.EmptyBrowserUrl => self.setSidebarNotice("No web link selected."),
            error.BrowserNavigationFailed => self.setSidebarNotice("Failed to open web link."),
            error.BrowserOpenFailed => self.setSidebarNotice("Failed to open browser."),
            else => {
                log.warn("failed to open transcript web link: {s}", .{@errorName(err)});
                self.setSidebarNotice("Failed to open web link.");
            },
        };
    }

    fn runCustomOpenAction(self: *AppState, custom: app_config.CustomOpenAction) void {
        utils.runCustomProjectCommand(self.allocator, self.currentProject().path, custom.action) catch |err| {
            log.warn("failed to run custom open action: {s}", .{@errorName(err)});
            self.setSidebarNotice("Failed to run custom open action.");
            return;
        };

        var notice_buf: [256]u8 = undefined;
        const notice = std.fmt.bufPrint(&notice_buf, "Ran {s}.", .{custom.label}) catch "Ran custom open action.";
        self.setSidebarNotice(notice);
    }

    pub fn attachClipboardImageToCurrentDraft(self: *AppState) bool {
        if (self.projects.items.len == 0) return false;
        const capture = captureClipboardImage(self.allocator) catch |err| {
            log.err("failed to capture clipboard image: {s}", .{@errorName(err)});
            runtime_log.diagnostic("clipboard image capture failed: {s}", .{@errorName(err)});
            self.setSidebarNotice("Clipboard image paste failed.");
            return false;
        };
        if (capture == null) {
            runtime_log.diagnostic("clipboard image capture unavailable", .{});
            return false;
        }

        const image = capture.?;
        defer self.allocator.free(image.bytes);
        runtime_log.diagnostic("clipboard image captured mime={s} bytes={d}", .{ image.mime, image.bytes.len });

        const image_path = self.writeClipboardImageToStorage(image.mime, image.bytes) catch |err| {
            log.err("failed to persist clipboard image: {s}", .{@errorName(err)});
            runtime_log.diagnostic("clipboard image persist failed: {s}", .{@errorName(err)});
            self.setSidebarNotice("Failed to save clipboard image.");
            return true;
        };
        defer self.allocator.free(image_path);

        const thread = self.currentThreadMutable();
        thread.addDraftImage(self.allocator, image_path, image.mime, image.bytes.len) catch |err| {
            log.err("failed to attach draft image: {s}", .{@errorName(err)});
            runtime_log.diagnostic("clipboard image draft attach failed: {s}", .{@errorName(err)});
            self.setSidebarNotice("Failed to attach clipboard image.");
            return true;
        };
        runtime_log.diagnostic("clipboard image attached mime={s} bytes={d}", .{ image.mime, image.bytes.len });
        self.setSidebarNotice("Clipboard image attached.");
        self.markDirty();
        return true;
    }

    pub fn pasteClipboardTextIntoPaletteComposer(self: *AppState) bool {
        if (self.projects.items.len == 0) return false;
        if (self.isBrowserPaneFocused() or self.browser_address_focused or self.palette_modal_text_focus != .none) {
            runtime_log.diagnostic(
                "palette paste blocked browser_focused={} address_focused={} modal_focus={s}",
                .{ self.isBrowserPaneFocused(), self.browser_address_focused, @tagName(self.palette_modal_text_focus) },
            );
            return false;
        }
        const text = self.readClipboardTextForPaste() orelse {
            runtime_log.diagnostic("palette paste clipboard text unavailable", .{});
            return false;
        };
        defer self.allocator.free(text);
        runtime_log.diagnostic("palette paste clipboard text len={d}", .{text.len});
        const handled = self.insertTextIntoPaletteComposer(text);
        runtime_log.diagnostic("palette paste insert handled={} draft_len={d}", .{ handled, self.currentDraft().len });
        return handled;
    }

    pub fn readClipboardTextForPaste(self: *AppState) ?[]u8 {
        const clipboard_text = sdl.getClipboardText() catch |err| {
            log.warn("failed to read clipboard text: {s}", .{@errorName(err)});
            runtime_log.diagnostic("palette paste SDL clipboard read failed: {s}", .{@errorName(err)});
            return utils.captureClipboardText(self.allocator) catch |fallback_err| {
                log.warn("failed to read fallback clipboard text: {s}", .{@errorName(fallback_err)});
                runtime_log.diagnostic("palette paste fallback clipboard read failed: {s}", .{@errorName(fallback_err)});
                return null;
            };
        };
        defer sdl.free(@ptrCast(clipboard_text));
        const text = std.mem.span(clipboard_text);
        if (text.len > 0) {
            runtime_log.diagnostic("palette paste SDL clipboard text len={d}", .{text.len});
            return self.allocator.dupe(u8, text) catch |err| {
                runtime_log.diagnostic("palette paste clipboard dupe failed: {s}", .{@errorName(err)});
                return null;
            };
        }
        runtime_log.diagnostic("palette paste SDL clipboard empty; trying fallback", .{});
        return utils.captureClipboardText(self.allocator) catch |fallback_err| {
            log.warn("failed to read fallback clipboard text: {s}", .{@errorName(fallback_err)});
            runtime_log.diagnostic("palette paste fallback clipboard read failed: {s}", .{@errorName(fallback_err)});
            return null;
        };
    }

    fn paletteComposerSelectionByteLen(self: *const AppState) usize {
        const anchor = self.palette_composer.selection_anchor orelse return 0;
        const focus = self.palette_composer.selection_focus orelse return 0;
        const text_len = self.palette_composer.text().len;
        const start = @min(@min(anchor, focus), text_len);
        const end = @min(@max(anchor, focus), text_len);
        return end - start;
    }

    fn utf8PrefixLen(value: []const u8, limit: usize) usize {
        const capped = @min(value.len, limit);
        if (capped >= value.len) return value.len;
        var end = capped;
        while (end > 0 and (value[end] & 0b1100_0000) == 0b1000_0000) {
            end -= 1;
        }
        return end;
    }

    fn clampPaletteComposerInsertText(self: *AppState, text: []const u8) []const u8 {
        const max_len = DRAFT_CAPACITY - 1;
        const current_len = self.palette_composer.text().len;
        const selected_len = self.paletteComposerSelectionByteLen();
        const retained_len = current_len - selected_len;
        if (retained_len >= max_len) return "";
        const available = max_len - retained_len;
        if (text.len <= available) return text;
        return text[0..utf8PrefixLen(text, available)];
    }

    fn insertTextIntoPaletteComposer(self: *AppState, text: []const u8) bool {
        if (text.len == 0) return false;
        self.palette_composer.focused = true;
        self.composer_focused = true;
        self.terminal_focused = false;
        self.unfocusBrowserPane();
        const insert_text = self.clampPaletteComposerInsertText(text);
        if (insert_text.len == 0) {
            self.setSidebarNotice("Prompt is full");
            return true;
        }
        if (insert_text.len < text.len) self.setSidebarNotice("Pasted text was truncated to fit the prompt");
        const handled = self.palette_composer.handleInput(self.allocator, .{ .text = insert_text }) catch |err| {
            log.warn("palette composer paste failed: {s}", .{@errorName(err)});
            return false;
        };
        if (handled) {
            self.syncDraftFromPaletteComposer();
            self.noteInteraction();
        }
        return handled;
    }

    pub fn clearCurrentDraftImage(self: *AppState) void {
        self.clearCurrentDraftImageAt(0);
    }

    pub fn clearCurrentDraftImageAt(self: *AppState, index: usize) void {
        if (self.projects.items.len == 0) return;
        const thread = self.currentThreadMutable();
        if (thread.draftImageAt(index)) |image| {
            var threaded = std.Io.Threaded.init_single_threaded;
            std.Io.Dir.deleteFileAbsolute(threaded.io(), image.path) catch {};
            self.evictCachedImageTexture(image.path);
            if (self.modal_image_path) |modal_path| {
                if (std.mem.eql(u8, modal_path, image.path)) {
                    self.allocator.free(modal_path);
                    self.modal_image_path = null;
                }
            }
        }
        thread.clearDraftImageAt(self.allocator, index);
        self.markDirty();
    }

    fn trimThreadMessages(self: *AppState, thread: *ChatThread, incoming_count: usize) void {
        _ = self;
        _ = thread;
        _ = incoming_count;
    }

    fn clearThreadMessages(self: *AppState, thread: *ChatThread) void {
        while (thread.messages.items.len > 0) {
            self.releaseMessage(thread.messages.pop().?);
        }
        thread.clearTranscriptMarkdownEntries(self.allocator);
        thread.clearTranscriptHeightEntries();
    }

    fn replaceThreadWithImportedSnapshot(
        self: *AppState,
        project_index: usize,
        thread_index: usize,
        imported_thread: ai_harness.ReadThreadResult,
    ) !void {
        if (project_index >= self.projects.items.len) return error.ProjectNotFound;
        const project = &self.projects.items[project_index];
        if (thread_index >= project.threads.items.len) return error.ThreadNotFound;

        const existing = &project.threads.items[thread_index];
        var refreshed = try self.buildImportedThread(imported_thread, existing);
        errdefer refreshed.deinit(self.allocator);

        var previous = existing.*;
        existing.* = refreshed;
        previous.deinit(self.allocator);
        self.projects.items[project_index].invalidateSidebarThreadCache();
    }

    fn buildImportedThread(
        self: *AppState,
        imported_thread: ai_harness.ReadThreadResult,
        existing_template: ?*const ChatThread,
    ) !ChatThread {
        var hydrated = try ChatThread.init(self.allocator, imported_thread.title);
        errdefer hydrated.deinit(self.allocator);

        hydrated.committed = true;
        hydrated.last_activity_at = imported_thread.updated_at orelse 0;

        if (hydrated.provider_thread_id) |thread_id| {
            self.allocator.free(thread_id);
            hydrated.provider_thread_id = null;
        }
        hydrated.provider_thread_id = try self.allocator.dupeZ(u8, imported_thread.thread_id);

        if (existing_template) |existing| {
            hydrated.provider = existing.provider;
            hydrated.harness = existing.harness;
            hydrated.reasoning_effort = existing.reasoning_effort;
            if (hydrated.opencode_reasoning_variant) |v| self.allocator.free(v);
            hydrated.opencode_reasoning_variant = if (existing.opencode_reasoning_variant) |v|
                try self.allocator.dupeZ(u8, v)
            else
                null;
            hydrated.fast_mode = existing.fast_mode;
            hydrated.access_mode = existing.access_mode;

            if (hydrated.model_ref) |model_ref| {
                self.allocator.free(model_ref);
            }
            hydrated.model_ref = if (existing.model_ref) |model_ref|
                try self.allocator.dupeZ(u8, model_ref)
            else
                null;

            hydrated.setDraft(existing.currentDraft());
            if (existing.draft_image) |image| {
                try hydrated.setDraftImage(self.allocator, image.path, image.mime, image.byte_size);
            }
        } else {
            hydrated.provider = .codex;
            hydrated.harness = .local_cli;
        }

        for (imported_thread.messages) |message| {
            try hydrated.messages.append(self.allocator, try self.importedChatMessage(message));
        }

        if (hydrated.last_activity_at == 0) {
            hydrated.touch();
        }

        return hydrated;
    }

    fn importedChatMessage(self: *AppState, message: ai_harness.ChatMessage) !ChatMessage {
        const author = try self.dupeZ(message.author);
        errdefer self.allocator.free(author);
        const body = try self.dupeZ(message.body);
        errdefer self.allocator.free(body);

        return .{
            .role = switch (message.role) {
                .user => .user,
                .assistant => .assistant,
                .system => .system,
            },
            .author = author,
            .body = body,
            .image = null,
        };
    }

    fn releaseMessage(self: *AppState, message: ChatMessage) void {
        self.allocator.free(message.author);
        self.allocator.free(message.body);
        if (message.image) |image| {
            self.evictCachedImageTexture(image.path);
            var owned_image = image;
            owned_image.deinit(self.allocator);
        }
        for (message.extra_images) |image| {
            self.evictCachedImageTexture(image.path);
            var owned_image = image;
            owned_image.deinit(self.allocator);
        }
        self.allocator.free(message.extra_images);
    }

    pub fn ensureImageTexture(self: *AppState, path: [:0]const u8) ?CachedImageTexture {
        if (!self.gl_texture_uploads_enabled and self.texture_upload_fn == null) return null;

        if (self.image_texture_cache.getPtr(path)) |cached| {
            return if (cached.valid) cached.* else null;
        }

        const owned_key = self.allocator.dupe(u8, path) catch return null;
        errdefer self.allocator.free(owned_key);

        const loaded = stb_image.load(path) catch |err| {
            log.err("failed to decode attachment preview {s}: {s}", .{ path, @errorName(err) });
            self.image_texture_cache.put(owned_key, .{
                .texture_id = 0,
                .width = 0,
                .height = 0,
                .valid = false,
            }) catch self.allocator.free(owned_key);
            return null;
        };
        defer loaded.deinit();

        const cached = self.uploadLoadedTexture(loaded) orelse {
            self.image_texture_cache.put(owned_key, .{
                .texture_id = 0,
                .width = 0,
                .height = 0,
                .valid = false,
            }) catch self.allocator.free(owned_key);
            return null;
        };

        self.image_texture_cache.put(owned_key, cached) catch {
            cached.deinit();
            return null;
        };
        return cached;
    }

    fn evictCachedImageTexture(self: *AppState, path: []const u8) void {
        if (self.image_texture_cache.fetchRemove(path)) |entry| {
            self.allocator.free(entry.key);
            entry.value.deinit();
        }
    }

    fn releaseAllImageTextures(self: *AppState) void {
        self.clearImageTextureCache();
        if (self.logo_texture) |cached| {
            cached.deinit();
            self.logo_texture = null;
        }
        if (self.opencode_logo_texture) |cached| {
            cached.deinit();
            self.opencode_logo_texture = null;
        }
        if (self.codex_logo_texture) |cached| {
            cached.deinit();
            self.codex_logo_texture = null;
        }
        if (self.claude_logo_texture) |cached| {
            cached.deinit();
            self.claude_logo_texture = null;
        }
        if (self.amp_logo_texture) |cached| {
            cached.deinit();
            self.amp_logo_texture = null;
        }
        if (self.thread_edit_texture) |cached| {
            cached.deinit();
            self.thread_edit_texture = null;
        }
        if (self.cursor_logo_texture) |cached| {
            cached.deinit();
            self.cursor_logo_texture = null;
        }
        if (self.emacs_logo_texture) |cached| {
            cached.deinit();
            self.emacs_logo_texture = null;
        }
        if (self.neovim_logo_texture) |cached| {
            cached.deinit();
            self.neovim_logo_texture = null;
        }
        if (self.vscode_logo_texture) |cached| {
            cached.deinit();
            self.vscode_logo_texture = null;
        }
        if (self.zed_logo_texture) |cached| {
            cached.deinit();
            self.zed_logo_texture = null;
        }
        self.image_texture_cache.deinit();
    }

    fn clearImageTextureCache(self: *AppState) void {
        var it = self.image_texture_cache.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit();
        }
        self.image_texture_cache.clearRetainingCapacity();
    }

    pub fn openImageModal(self: *AppState, path: [:0]const u8) void {
        if (self.modal_image_path) |existing| {
            if (std.mem.eql(u8, existing, path)) {
                return;
            }
            self.allocator.free(existing);
        }
        self.modal_image_path = self.allocator.dupeZ(u8, path) catch return;
    }

    pub fn closeImageModal(self: *AppState) void {
        if (self.modal_image_path) |path| {
            self.allocator.free(path);
            self.modal_image_path = null;
        }
    }

    pub fn openCurrentTranscriptSelectionModal(self: *AppState) void {
        if (self.projects.items.len == 0) return;
        const next_text = self.buildCurrentTranscriptSelectionText() catch return;
        if (self.transcript_selection_text) |existing| {
            self.allocator.free(existing);
        }
        self.transcript_selection_text = next_text;
        self.transcript_selection_modal_requested = true;
    }

    pub fn closeTranscriptSelectionModal(self: *AppState) void {
        self.transcript_selection_modal_requested = false;
        if (self.transcript_selection_text) |text| {
            self.allocator.free(text);
            self.transcript_selection_text = null;
        }
    }

    pub fn transcriptSelectionBuffer(self: *AppState) ?[:0]u8 {
        return self.transcript_selection_text;
    }

    pub fn consumeTranscriptSelectionModalRequest(self: *AppState) bool {
        const requested = self.transcript_selection_modal_requested;
        self.transcript_selection_modal_requested = false;
        return requested;
    }

    pub fn isTranscriptFocused(self: *const AppState) bool {
        return self.transcript_focused and !self.composer_focused and !self.terminal_focused and !self.browser_pane_focused;
    }

    fn ensureTranscriptMarkdownSelectionCurrent(self: *AppState) void {
        if (self.projects.items.len == 0) {
            self.clearTranscriptMarkdownSelection();
            return;
        }

        const project_index = self.selected_project_index;
        const thread_index = self.currentProject().selected_thread_index;
        if (self.transcript_markdown_selection_project_index == project_index and
            self.transcript_markdown_selection_thread_index == thread_index)
        {
            return;
        }

        self.clearTranscriptMarkdownSelection();
    }

    pub fn transcriptMarkdownSelection(self: *AppState) ?TranscriptMarkdownSelection {
        self.ensureTranscriptMarkdownSelectionCurrent();
        const anchor = self.transcript_markdown_selection_anchor orelse return null;
        const focus = self.transcript_markdown_selection_focus orelse return null;
        return .{
            .anchor = anchor,
            .focus = focus,
        };
    }

    pub fn transcriptMarkdownSelectionDragging(self: *AppState) bool {
        self.ensureTranscriptMarkdownSelectionCurrent();
        return self.transcript_markdown_selection_dragging;
    }

    pub fn transcriptMarkdownSelectionActive(self: *AppState) bool {
        self.ensureTranscriptMarkdownSelectionCurrent();
        return self.transcript_markdown_selection_anchor != null and
            self.transcript_markdown_selection_focus != null;
    }

    pub fn beginTranscriptMarkdownSelection(self: *AppState, message_index: usize, point: chat_markdown.SelectionPoint) void {
        if (self.projects.items.len == 0) return;
        const selection_point: TranscriptMarkdownSelectionPoint = .{
            .message_index = message_index,
            .point = point,
        };
        self.transcript_markdown_selection_project_index = self.selected_project_index;
        self.transcript_markdown_selection_thread_index = self.currentProject().selected_thread_index;
        self.transcript_markdown_selection_anchor = selection_point;
        self.transcript_markdown_selection_focus = selection_point;
        self.transcript_markdown_selection_dragging = true;
    }

    pub fn updateTranscriptMarkdownSelection(self: *AppState, message_index: usize, point: chat_markdown.SelectionPoint) void {
        self.ensureTranscriptMarkdownSelectionCurrent();
        if (self.transcript_markdown_selection_anchor == null) return;
        self.transcript_markdown_selection_focus = .{
            .message_index = message_index,
            .point = point,
        };
    }

    pub fn endTranscriptMarkdownSelection(self: *AppState) void {
        self.transcript_markdown_selection_dragging = false;
    }

    pub fn notePaletteWorkspaceMouseMotion(self: *AppState, x: f32, y: f32) void {
        self.palette_mouse_x = x;
        self.palette_mouse_y = y;
        self.palette_mouse_in_workspace = true;
    }

    pub fn blurPaletteComposer(self: *AppState) void {
        self.palette_composer.focused = false;
        self.palette_composer.active_menu = null;
        self.palette_composer.hovered_menu_index = null;
        self.composer_focused = false;
    }

    pub fn closeSidebarContextMenu(self: *AppState) void {
        if (!self.sidebar_context_menu_open) return;
        self.sidebar_context_menu_open = false;
        self.sidebar_context_menu_kind = .none;
        self.markDirty();
    }

    pub fn selectAllTranscriptMarkdownSelection(
        self: *AppState,
        first_message_index: usize,
        first: chat_markdown.SelectionPoint,
        last_message_index: usize,
        last: chat_markdown.SelectionPoint,
    ) void {
        if (self.projects.items.len == 0) return;
        self.transcript_markdown_selection_project_index = self.selected_project_index;
        self.transcript_markdown_selection_thread_index = self.currentProject().selected_thread_index;
        self.transcript_markdown_selection_anchor = .{
            .message_index = first_message_index,
            .point = first,
        };
        self.transcript_markdown_selection_focus = .{
            .message_index = last_message_index,
            .point = last,
        };
        self.transcript_markdown_selection_dragging = false;
    }

    pub fn clearTranscriptMarkdownSelection(self: *AppState) void {
        self.transcript_markdown_selection_project_index = null;
        self.transcript_markdown_selection_thread_index = null;
        self.transcript_markdown_selection_anchor = null;
        self.transcript_markdown_selection_focus = null;
        self.transcript_markdown_selection_dragging = false;
    }

    pub fn transcriptMarkdownBodyView(self: *AppState, message_index: usize, body: []const u8) ?*const chat_markdown.BodyView {
        const entry = self.transcriptMarkdownBodyEntry(message_index, body) orelse return null;
        return &entry.view;
    }

    pub fn cachedTranscriptMessageHeight(
        self: *AppState,
        message_index: usize,
        width: f32,
        body: []const u8,
        role: ChatRole,
        author: []const u8,
        assistant_plain_layout: bool,
        image_present: bool,
    ) ?f32 {
        const thread = self.currentThreadMutable();
        thread.ensureTranscriptHeightEntries(self.allocator);
        if (message_index >= thread.transcript_height_entries.items.len) return null;

        const entry = thread.transcript_height_entries.items[message_index];
        if (!entry.valid) return null;
        if (entry.role != role) return null;
        if (entry.assistant_plain_layout != assistant_plain_layout) return null;
        if (@abs(entry.width - width) > 0.5) return null;
        if (entry.body_hash != std.hash.Wyhash.hash(0, body)) return null;
        if (entry.author_hash != std.hash.Wyhash.hash(0, author)) return null;
        if (entry.image_present != image_present) return null;
        return entry.height;
    }

    pub fn putTranscriptMessageHeight(
        self: *AppState,
        message_index: usize,
        width: f32,
        body: []const u8,
        role: ChatRole,
        author: []const u8,
        assistant_plain_layout: bool,
        image_present: bool,
        height: f32,
    ) void {
        if (height <= 0.0) return;
        const thread = self.currentThreadMutable();
        thread.ensureTranscriptHeightEntries(self.allocator);
        if (message_index >= thread.transcript_height_entries.items.len) return;

        thread.transcript_height_entries.items[message_index] = .{
            .valid = true,
            .role = role,
            .assistant_plain_layout = assistant_plain_layout,
            .width = width,
            .body_hash = std.hash.Wyhash.hash(0, body),
            .author_hash = std.hash.Wyhash.hash(0, author),
            .image_present = image_present,
            .height = height,
        };
    }

    fn ensureTranscriptMarkdownEntries(self: *AppState) void {
        if (self.projects.items.len == 0) {
            self.clearTranscriptMarkdownEntries();
            return;
        }

        const project_index = self.selected_project_index;
        const thread_index = self.currentProject().selected_thread_index;
        const message_count = self.currentThread().messages.items.len;
        if (self.transcript_markdown_project_index == project_index and
            self.transcript_markdown_thread_index == thread_index and
            self.transcript_markdown_entries.items.len == message_count)
        {
            return;
        }

        self.clearTranscriptMarkdownEntries();
        self.transcript_markdown_entries.appendNTimes(self.allocator, null, message_count) catch return;
        self.transcript_markdown_project_index = project_index;
        self.transcript_markdown_thread_index = thread_index;
    }

    fn clearTranscriptMarkdownEntries(self: *AppState) void {
        for (self.transcript_markdown_entries.items) |entry| {
            if (entry) |owned| owned.deinit(self.allocator);
        }
        self.transcript_markdown_entries.clearRetainingCapacity();
        self.transcript_markdown_project_index = null;
        self.transcript_markdown_thread_index = null;
    }

    fn transcriptMarkdownBodyEntry(self: *AppState, message_index: usize, body: []const u8) ?*TranscriptMarkdownBody {
        if (body.len == 0) return null;
        const thread = self.currentThreadMutable();
        thread.ensureTranscriptMarkdownEntries(self.allocator);
        if (message_index >= thread.transcript_markdown_entries.items.len) return null;

        if (thread.transcript_markdown_entries.items[message_index]) |entry| {
            if (!std.mem.eql(u8, entry.owned_body, body)) {
                entry.deinit(self.allocator);
                thread.transcript_markdown_entries.items[message_index] = null;
            } else {
                return entry;
            }
        }

        const created = self.createTranscriptMarkdownBody(body) catch return null;
        thread.transcript_markdown_entries.items[message_index] = created;
        return created;
    }

    fn createTranscriptMarkdownBody(self: *AppState, body: []const u8) !*TranscriptMarkdownBody {
        const entry = try self.allocator.create(TranscriptMarkdownBody);
        errdefer self.allocator.destroy(entry);

        entry.owned_body = try self.allocator.dupe(u8, body);
        errdefer self.allocator.free(entry.owned_body);

        entry.view = try chat_markdown.buildBodyView(self.allocator, entry.owned_body);
        errdefer entry.view.deinit(self.allocator);

        return entry;
    }

    pub fn prewarmThreadTranscriptMarkdown(self: *AppState, project_index: usize, thread_index: usize, max_entries: usize) void {
        if (max_entries == 0 or project_index >= self.projects.items.len) return;
        const project = &self.projects.items[project_index];
        if (thread_index >= project.threads.items.len) return;

        const thread = &project.threads.items[thread_index];
        thread.ensureTranscriptMarkdownEntries(self.allocator);

        var warmed: usize = 0;
        for (thread.messages.items, 0..) |message, message_index| {
            if (warmed >= max_entries) break;
            if (message.body.len == 0 or message_index >= thread.transcript_markdown_entries.items.len) continue;

            if (thread.transcript_markdown_entries.items[message_index]) |entry| {
                if (std.mem.eql(u8, entry.owned_body, message.body)) {
                    warmed += 1;
                    continue;
                }
                entry.deinit(self.allocator);
                thread.transcript_markdown_entries.items[message_index] = null;
            }

            const created = self.createTranscriptMarkdownBody(message.body) catch return;
            thread.transcript_markdown_entries.items[message_index] = created;
            warmed += 1;
        }
    }

    fn buildCurrentTranscriptSelectionText(self: *AppState) ![:0]u8 {
        var buffer = std.ArrayList(u8).empty;
        defer buffer.deinit(self.allocator);

        const thread = self.currentThread();
        for (thread.messages.items, 0..) |message, index| {
            if (index > 0) {
                try buffer.appendSlice(self.allocator, "\n\n");
            }
            try buffer.appendSlice(self.allocator, message.author);

            if (message.image) |image| {
                const image_label = try std.fmt.allocPrint(self.allocator, "\n[Image: {s}]", .{image.file_name});
                defer self.allocator.free(image_label);
                try buffer.appendSlice(self.allocator, image_label);
            }
            for (message.extra_images) |image| {
                const image_label = try std.fmt.allocPrint(self.allocator, "\n[Image: {s}]", .{image.file_name});
                defer self.allocator.free(image_label);
                try buffer.appendSlice(self.allocator, image_label);
            }
            if (message.body.len > 0) {
                try buffer.append(self.allocator, '\n');
                try buffer.appendSlice(self.allocator, message.body);
            }
        }

        if (buffer.items.len == 0) {
            try buffer.appendSlice(self.allocator, "No messages yet.");
        }

        return try self.allocator.dupeZ(u8, buffer.items);
    }

    fn writeClipboardImageToStorage(self: *AppState, mime: []const u8, bytes: []const u8) ![]u8 {
        const images_dir = try std.fs.path.join(self.allocator, &.{ self.storage.pref_path, "clipboard-images" });
        defer self.allocator.free(images_dir);
        var threaded = std.Io.Threaded.init_single_threaded;
        std.Io.Dir.createDirAbsolute(threaded.io(), images_dir, .default_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };

        const ext = extensionForImageMime(mime);
        const timestamp_ms = @as(u64, @intCast(@max(@as(i64, 0), 0)));
        var attempt: usize = 0;
        while (attempt < 256) : (attempt += 1) {
            const file_name = if (attempt == 0)
                try std.fmt.allocPrint(self.allocator, "clipboard-{d}.{s}", .{ timestamp_ms, ext })
            else
                try std.fmt.allocPrint(self.allocator, "clipboard-{d}-{d}.{s}", .{ timestamp_ms, attempt, ext });
            defer self.allocator.free(file_name);

            const image_path = try std.fs.path.join(self.allocator, &.{ images_dir, file_name });
            errdefer self.allocator.free(image_path);

            var threaded_file = std.Io.Threaded.init_single_threaded;
            const file = std.Io.Dir.createFileAbsolute(threaded_file.io(), image_path, .{ .exclusive = true });
            if (file) |created| {
                defer created.close(threaded_file.io());
                var write_buffer: [8 * 1024]u8 = undefined;
                var writer = created.writer(threaded_file.io(), &write_buffer);
                try writer.interface.writeAll(bytes);
                try writer.interface.flush();
                return image_path;
            } else |err| switch (err) {
                error.PathAlreadyExists => {
                    self.allocator.free(image_path);
                    continue;
                },
                else => return err,
            }
        }

        return error.PathAlreadyExists;
    }

    fn currentDraft(self: *const AppState) []const u8 {
        return self.currentProject().currentDraft();
    }

    pub fn currentThreadDraft(self: *const AppState) []const u8 {
        return self.currentDraft();
    }

    /// Shared provider → logo texture lookup for pickers/pills; returns null
    /// until the texture uploads.
    pub fn providerLogoTexture(self: *const AppState, provider: Provider) ?CachedImageTexture {
        return switch (provider) {
            .codex => self.codex_logo_texture,
            .opencode => self.opencode_logo_texture,
            .claude => self.claude_logo_texture,
            .cursor => self.cursor_logo_texture,
        };
    }

    pub fn currentComposerModelLabel(self: *const AppState) []const u8 {
        const thread = self.currentThread();
        const options = composerModelOptions(self, thread.provider);
        if (self.composerModelIndex(thread.provider, thread.model_ref)) |index| {
            if (index < options.len) return std.mem.sliceTo(options[index].label, 0);
        }
        return if (thread.model_ref) |model_ref| std.mem.sliceTo(model_ref, 0) else std.mem.sliceTo(composerDefaultModelRef(self, thread.provider), 0);
    }

    pub fn currentComposerReasoningLabel(self: *const AppState) []const u8 {
        const thread = self.currentThread();
        if (self.composerReasoningIndexForThread(thread)) |index| {
            if (thread.provider == .codex) {
                if (index < CODEX_REASONING_OPTIONS.len) return std.mem.sliceTo(CODEX_REASONING_OPTIONS[index].label, 0);
            } else {
                const rows = self.opencode_reasoning_menu.items;
                if (index < rows.len) return std.mem.sliceTo(rows[index].label, 0);
            }
        }
        if (thread.reasoning_effort) |effort| return reasoningEffortDisplayLabel(effort);
        if (thread.opencode_reasoning_variant) |variant| return std.mem.sliceTo(variant, 0);
        return "Default";
    }

    pub fn currentComposerShowsFastToggle(self: *const AppState) bool {
        const thread = self.currentThread();
        const cursor_model = if (thread.provider == .cursor) self.cursorModelOptionForRef(thread.model_ref) else null;
        return thread.provider == .codex or (cursor_model != null and cursor_model.?.cursor_fast_supported);
    }

    pub fn currentComposerFastLabel(self: *const AppState) []const u8 {
        return if (self.currentThread().fast_mode == .on) "Fast" else "Default";
    }

    pub fn currentComposerAccessLabel(self: *const AppState) []const u8 {
        return switch (self.currentThread().access_mode) {
            .full_access => "Full access",
            .supervised => "Supervised",
        };
    }

    pub fn slashCommandPickerActive(self: *const AppState) bool {
        if (self.projects.items.len == 0) return false;
        return slashCommandPrefix(self.currentDraft()) != null;
    }

    pub fn slashCommandPickerSelectedIndex(self: *const AppState) usize {
        const count = self.slashCommandPickerRowCount();
        if (count == 0) return 0;
        return @min(self.composer_slash_selected, count - 1);
    }

    pub fn slashCommandPickerRowCount(self: *const AppState) usize {
        if (self.projects.items.len == 0) return 0;
        var count: usize = 0;
        const prefix = slashCommandPrefix(self.currentDraft()) orelse return 0;
        for (slash_commands.LOCAL_COMMANDS) |command| {
            if (slashCommandMatchesPrefix(command.name, prefix)) count += 1;
        }
        const provider_commands = ai_harness.slashCommandsForProvider(harnessProviderForDbProvider(self.currentThread().provider));
        for (provider_commands) |command| {
            if (slashCommandMatchesPrefix(command.name, prefix)) count += 1;
        }
        return count;
    }

    pub fn slashCommandPickerRow(self: *const AppState, index: usize) ?SlashPickerRow {
        if (self.projects.items.len == 0) return null;
        const prefix = slashCommandPrefix(self.currentDraft()) orelse return null;
        var current: usize = 0;
        for (slash_commands.LOCAL_COMMANDS) |command| {
            if (!slashCommandMatchesPrefix(command.name, prefix)) continue;
            if (current == index) {
                return .{
                    .name = command.name,
                    .summary = command.summary,
                    .usage = command.usage,
                    .provider_label = "Verde",
                    .disabled = false,
                    .requires_thread = false,
                };
            }
            current += 1;
        }
        const thread = self.currentThread();
        const provider_commands = ai_harness.slashCommandsForProvider(harnessProviderForDbProvider(thread.provider));
        for (provider_commands) |command| {
            if (!slashCommandMatchesPrefix(command.name, prefix)) continue;
            if (current == index) {
                const missing_thread = command.requires_thread and thread.provider_thread_id == null;
                return .{
                    .name = command.name,
                    .summary = command.summary,
                    .usage = command.usage,
                    .provider_label = utils.providerLabel(thread.provider),
                    .disabled = command.availability != .available or missing_thread,
                    .requires_thread = command.requires_thread,
                };
            }
            current += 1;
        }
        return null;
    }

    pub fn selectSlashCommandPickerRow(self: *AppState, index: usize) bool {
        const count = self.slashCommandPickerRowCount();
        if (count == 0 or index >= count) return false;
        self.composer_slash_selected = index;
        self.noteInteraction();
        self.markDirty();
        return true;
    }

    pub fn activateSlashCommandPickerSelection(self: *AppState) bool {
        const count = self.slashCommandPickerRowCount();
        if (count == 0) return false;
        const index = @min(self.composer_slash_selected, count - 1);
        const row = self.slashCommandPickerRow(index) orelse return false;
        if (row.disabled) {
            if (row.requires_thread and self.currentThread().provider_thread_id == null) {
                var buffer: [160]u8 = undefined;
                self.setSidebarNotice(std.fmt.bufPrint(&buffer, "Start a {s} thread before using {s}.", .{ row.provider_label, row.name }) catch "Start a provider thread before using this command.");
            } else {
                var buffer: [160]u8 = undefined;
                self.setSidebarNotice(std.fmt.bufPrint(&buffer, "Command not enabled yet: {s}.", .{row.name}) catch "Command is not enabled yet.");
            }
            self.noteInteraction();
            return true;
        }
        if (std.mem.eql(u8, row.provider_label, "Verde")) {
            self.setDraft(row.name);
            self.appendSlashCommandInsertionSpace();
            self.syncPaletteComposerFromDraft();
            self.palette_composer.cursor = self.palette_composer.text().len;
            self.requestComposerFocus();
            self.noteInteraction();
            return true;
        }
        const should_submit_immediately = std.mem.eql(u8, row.name, "/usage") or
            std.mem.eql(u8, row.name, "/review") or
            (std.mem.eql(u8, row.name, "/compact") and !std.mem.eql(u8, row.provider_label, "Claude"));
        if (should_submit_immediately) {
            self.setDraft(row.name);
            self.syncPaletteComposerFromDraft();
            _ = self.handleProviderSlashCommand(row.name);
            self.noteInteraction();
            return true;
        }
        self.setDraft(row.name);
        self.appendSlashCommandInsertionSpace();
        self.syncPaletteComposerFromDraft();
        self.palette_composer.cursor = self.palette_composer.text().len;
        self.requestComposerFocus();
        self.noteInteraction();
        return true;
    }

    fn appendSlashCommandInsertionSpace(self: *AppState) void {
        const text = self.currentDraft();
        if (text.len > 0 and text[text.len - 1] == ' ') return;
        var buffer: [128]u8 = undefined;
        const next = std.fmt.bufPrint(&buffer, "{s} ", .{text}) catch return;
        self.setDraft(next);
    }

    pub fn closeSlashCommandPicker(self: *AppState) bool {
        if (!self.slashCommandPickerActive()) return false;
        self.clearDraft();
        self.syncPaletteComposerFromDraft();
        self.composer_slash_selected = 0;
        self.noteInteraction();
        return true;
    }

    pub fn clampSlashCommandPickerSelection(self: *AppState) void {
        const count = self.slashCommandPickerRowCount();
        if (count == 0) {
            self.composer_slash_selected = 0;
            return;
        }
        if (self.composer_slash_selected >= count) self.composer_slash_selected = count - 1;
    }

    pub fn currentThread(self: *const AppState) *const ChatThread {
        return self.currentProject().currentThread();
    }

    pub fn currentProjectTerminal(self: *const AppState) *const terminal.Dock {
        if (self.focusedWorkspaceTerminalDockId()) |dock_id| {
            if (self.currentProjectTerminalDock(dock_id)) |dock| return dock;
        }
        return &self.currentProject().terminal_dock;
    }

    pub fn currentProjectTerminalMutable(self: *AppState) *terminal.Dock {
        if (self.focusedWorkspaceTerminalDockId()) |dock_id| {
            if (self.currentProjectTerminalDockMutable(dock_id)) |dock| return dock;
        }
        return &self.currentProjectMutable().terminal_dock;
    }

    pub fn currentProjectTerminalDock(self: *const AppState, dock_id: u32) ?*const terminal.Dock {
        if (self.projects.items.len == 0) return null;
        const project = self.currentProject();
        if (dock_id == 0) return &project.terminal_dock;
        for (project.terminal_docks.items) |*entry| {
            if (entry.id == dock_id) return &entry.dock;
        }
        return null;
    }

    pub fn currentProjectTerminalDockMutable(self: *AppState, dock_id: u32) ?*terminal.Dock {
        if (self.projects.items.len == 0) return null;
        var project = self.currentProjectMutable();
        if (dock_id == 0) return &project.terminal_dock;
        for (project.terminal_docks.items) |*entry| {
            if (entry.id == dock_id) return &entry.dock;
        }
        return null;
    }

    pub fn projectTerminalDock(self: *const AppState, project_index: usize, dock_id: u32) ?*const terminal.Dock {
        if (project_index >= self.projects.items.len) return null;
        const project = &self.projects.items[project_index];
        if (dock_id == 0) return &project.terminal_dock;
        for (project.terminal_docks.items) |*entry| {
            if (entry.id == dock_id) return &entry.dock;
        }
        return null;
    }

    pub fn projectTerminalDockMutable(self: *AppState, project_index: usize, dock_id: u32) ?*terminal.Dock {
        if (project_index >= self.projects.items.len) return null;
        var project = &self.projects.items[project_index];
        if (dock_id == 0) return &project.terminal_dock;
        for (project.terminal_docks.items) |*entry| {
            if (entry.id == dock_id) return &entry.dock;
        }
        return null;
    }

    pub fn focusedWorkspaceTerminalDockId(self: *const AppState) ?u32 {
        if (self.projects.items.len == 0) return null;
        const layout = &self.projects.items[self.selected_project_index].workspace_layout;
        const pane = layout.focusedPane() orelse return null;
        if (pane.minimized) return null;
        return switch (pane.ref) {
            .terminal => |ref| ref.dock_id,
            else => null,
        };
    }

    pub fn createCurrentProjectTerminalTab(self: *AppState, dock_id: u32, profile: terminal.TerminalLaunchProfile) bool {
        if (self.projects.items.len == 0) return false;
        self.createTerminalTabForWorkspaceProfile(self.selected_project_index, dock_id, profile) catch |err| {
            log.warn("failed to create workspace terminal tab: {s}", .{@errorName(err)});
            self.setSidebarNotice("Failed to create terminal tab.");
            return false;
        };
        self.requestTerminalDockFocus(dock_id);
        self.markDirty();
        return true;
    }

    fn createProjectTerminalDock(self: *AppState, project_index: usize) !u32 {
        if (project_index >= self.projects.items.len) return error.NoProjectSelected;
        var project = &self.projects.items[project_index];
        const dock_id = project.next_terminal_dock_id;
        project.next_terminal_dock_id += 1;
        var dock = try terminal.Dock.init(self.allocator);
        dock.setDefaultFontSize(self.app_config.terminal_font_size);
        errdefer dock.deinit(self.allocator);
        try project.terminal_docks.append(self.allocator, .{ .id = dock_id, .dock = dock });
        return dock_id;
    }

    fn createCurrentProjectTerminalDock(self: *AppState) !u32 {
        if (self.projects.items.len == 0) return error.NoProjectSelected;
        return self.createProjectTerminalDock(self.selected_project_index);
    }

    pub fn isTerminalVisible(self: *const AppState) bool {
        if (self.projects.items.len == 0) return false;
        const project = self.currentProject();
        return project.terminal_dock.visible or project.workspace_layout.hasVisiblePaneKind(.terminal);
    }

    pub fn shouldRenderLegacyTerminalDockInChat(self: *const AppState) bool {
        if (self.projects.items.len == 0) return false;
        const project = self.currentProject();
        return project.terminal_dock.visible and !project.workspace_layout.hasVisiblePaneKind(.terminal);
    }

    pub fn isSidebarCollapsed(self: *const AppState) bool {
        return self.sidebar_collapsed;
    }

    pub fn isSidebarHidden(self: *const AppState) bool {
        return self.sidebar_hidden;
    }

    pub fn isSidebarHoverRevealed(self: *const AppState) bool {
        return self.sidebar_hover_revealed;
    }

    pub fn setSidebarCollapsed(self: *AppState, collapsed: bool) void {
        if (self.sidebar_collapsed == collapsed) return;
        self.sidebar_collapsed = collapsed;
        self.markDirty();
    }

    pub fn toggleSidebarCollapsed(self: *AppState) void {
        self.setSidebarCollapsed(!self.sidebar_collapsed);
    }

    pub fn setSidebarHidden(self: *AppState, hidden: bool) void {
        if (self.sidebar_hidden == hidden) return;
        self.sidebar_hidden = hidden;
        if (!hidden) self.sidebar_hover_revealed = false;
        self.markDirty();
    }

    pub fn toggleSidebarHidden(self: *AppState) void {
        self.setSidebarHidden(!self.sidebar_hidden);
    }

    pub fn setSidebarHoverRevealed(self: *AppState, revealed: bool) void {
        const next = self.sidebar_hidden and revealed;
        if (self.sidebar_hover_revealed == next) return;
        self.sidebar_hover_revealed = next;
        self.markDirty();
    }

    pub fn terminalPanelHeight(self: *const AppState, available_height: f32) f32 {
        if (self.projects.items.len == 0) return 0.0;
        return self.currentProjectTerminal().effectiveHeight(available_height);
    }

    pub fn setCurrentProjectTerminalHeight(self: *AppState, available_height: f32, height: f32) void {
        if (self.projects.items.len == 0) return;
        if (self.currentProjectTerminalMutable().setPreferredHeight(available_height, height)) {
            self.markDirty();
        }
    }

    pub fn beginTerminalResizeDrag(self: *AppState, available_height: f32) void {
        if (!self.isTerminalVisible()) return;
        self.terminal_resize_drag_active = true;
        self.terminal_resize_drag_origin_height = self.terminalPanelHeight(available_height);
        self.noteInteraction();
    }

    pub fn updateTerminalResizeDrag(self: *AppState, available_height: f32, drag_delta_y: f32) void {
        if (!self.terminal_resize_drag_active or !self.isTerminalVisible()) return;
        self.setCurrentProjectTerminalHeight(available_height, self.terminal_resize_drag_origin_height - drag_delta_y);
    }

    pub fn endTerminalResizeDrag(self: *AppState) void {
        self.terminal_resize_drag_active = false;
        self.terminal_resize_drag_origin_height = 0.0;
    }

    pub fn toggleCurrentProjectTerminal(self: *AppState) void {
        if (self.projects.items.len == 0) {
            self.setSidebarNotice("No workspace selected.");
            return;
        }

        self.ensureCurrentProjectWorkspace();
        var dock = self.currentProjectTerminalMutable();
        if (!dock.hasRunningSession()) {
            self.restartTerminalDockForWorkspace(self.selected_project_index, 0) catch |err| {
                log.err("failed to start terminal dock: {s}", .{@errorName(err)});
                self.setSidebarNotice("Failed to start terminal.");
                return;
            };
        }

        const layout = &self.projects.items[self.selected_project_index].workspace_layout;
        const focused_kind = if (layout.focusedPane()) |pane| switch (pane.ref) {
            .chat => WorkspacePaneKind.chat,
            .terminal => WorkspacePaneKind.terminal,
            .browser => WorkspacePaneKind.browser,
        } else null;
        const terminal_visible = layout.hasVisiblePaneKind(.terminal);
        if (terminal_visible and focused_kind == .terminal) {
            _ = layout.minimizePaneKind(self.allocator, .terminal);
            dock.visible = false;
            self.endTerminalResizeDrag();
            self.terminal_focused = false;
            self.setSidebarNotice("Terminal hidden.");
            self.markDirty();
            return;
        }

        _ = layout.ensureTerminalPane(self.allocator, 0) catch |err| {
            log.err("failed to open terminal workspace pane: {s}", .{@errorName(err)});
            self.setSidebarNotice("Failed to open terminal pane.");
            return;
        };
        dock.visible = false;
        self.requestTerminalFocus();
        self.setSidebarNotice("Terminal opened.");
        self.markDirty();
    }

    pub fn toggleCurrentProjectTerminalLegacy(self: *AppState) void {
        if (self.projects.items.len == 0) {
            self.setSidebarNotice("No workspace selected.");
            return;
        }

        var dock = self.currentProjectTerminalMutable();
        if (!dock.visible) {
            self.restartTerminalDockForWorkspace(self.selected_project_index, 0) catch |err| {
                log.err("failed to start terminal dock: {s}", .{@errorName(err)});
                self.setSidebarNotice("Failed to start terminal.");
                return;
            };
        }

        const is_visible = dock.toggle();
        if (!is_visible) self.endTerminalResizeDrag();
        if (is_visible) {
            self.requestTerminalFocus();
        } else {
            self.terminal_focused = false;
        }
        self.setSidebarNotice(if (is_visible) "Terminal opened." else "Terminal hidden.");
    }

    // Visible terminal activity within this window keeps the main loop polling
    // at display rate. Input counts because its first same-loop tail can race
    // ConPTY's asynchronous writer and otherwise miss the echo before sleeping.
    const TERMINAL_ACTIVITY_BURST_WINDOW_MS: i64 = 250;
    const TERMINAL_POLL_INTERVAL_MS: i64 = 16;

    fn monotonicMs() i64 {
        return @intCast(@divTrunc(profiler.nowNs(), std.time.ns_per_ms));
    }

    /// True while a visible terminal recently accepted input or produced
    /// output; the main loop uses this to render the next echo/chunk promptly.
    pub fn terminalActivityBurstActive(self: *const AppState) bool {
        if (self.last_terminal_activity_ms == 0) return false;
        return monotonicMs() - self.last_terminal_activity_ms < TERMINAL_ACTIVITY_BURST_WINDOW_MS;
    }

    /// Starts a short active-poll window after accepted terminal input. The
    /// forced poll preserves the immediate post-event check while the cadence
    /// guard prevents high-rate SDL events from opening one pipe RPC each.
    pub fn noteTerminalInputActivity(self: *AppState) void {
        self.last_terminal_activity_ms = monotonicMs();
        self.terminal_poll_requested = true;
    }

    pub fn pollTerminals(self: *AppState) bool {
        var visible_changed = false;
        const now_ms = monotonicMs();
        if (!self.terminal_poll_requested and
            self.last_terminal_poll_ms != 0 and
            now_ms - self.last_terminal_poll_ms < TERMINAL_POLL_INTERVAL_MS)
        {
            return false;
        }
        self.terminal_poll_requested = false;
        self.last_terminal_poll_ms = now_ms;
        for (self.projects.items, 0..) |*project, project_index| {
            const project_selected = project_index == self.selected_project_index;
            const base_visible = project.terminal_dock.visible or project.workspace_layout.hasTerminalDockPane(0);
            if (!project_selected) {
                self.pollManagedProcesses(project_index);
                continue;
            }
            if (project_selected and base_visible and !project.terminal_dock.hasRunningSession() and project.terminal_dock.reserveAutoRestart(now_ms)) {
                const start_result = if (project.terminal_dock.hasRestorableSession())
                    project.terminal_dock.ensureSessionPersistent(self.allocator, project.path, self.storage.pref_path, 0)
                else
                    self.restartTerminalDockForWorkspace(project_index, 0);
                start_result catch |err| {
                    log.err("failed to start visible terminal session: {s}", .{@errorName(err)});
                    if (project_index == self.selected_project_index) self.setSidebarNotice("Terminal session failed.");
                };
                if (project_index == self.selected_project_index) {
                    visible_changed = true;
                }
            }
            if (base_visible or project.terminal_dock.hasRunningSession()) {
                const changed = project.terminal_dock.poll(self.allocator) catch |err| blk: {
                    log.err("failed to poll terminal session: {s}", .{@errorName(err)});
                    if (project_index == self.selected_project_index and base_visible) {
                        self.setSidebarNotice("Terminal session failed.");
                    }
                    break :blk false;
                };
                if (project.terminal_dock.consumeWorkspaceChange()) self.markDirty();
                self.drainTerminalDockNotifications(project_index, 0, &project.terminal_dock) catch |err| {
                    log.warn("failed to apply terminal notification: {s}", .{@errorName(err)});
                };
                if (changed and project_index == self.selected_project_index and base_visible) visible_changed = true;
            }
            var exited_editor_dock_id: ?u32 = null;
            for (project.terminal_docks.items) |*entry| {
                const dock_visible = entry.dock.visible or project.workspace_layout.hasTerminalDockPane(entry.id);
                if (dock_visible and !entry.dock.hasRunningSession() and project.workspace_layout.hasEditorTerminalDockPane(entry.id)) {
                    exited_editor_dock_id = entry.id;
                    break;
                }
                if (project_selected and dock_visible and !entry.dock.hasRunningSession() and entry.dock.reserveAutoRestart(now_ms)) {
                    const start_result = if (entry.dock.hasRestorableSession())
                        entry.dock.ensureSessionPersistent(self.allocator, project.path, self.storage.pref_path, entry.id)
                    else
                        self.restartTerminalDockForWorkspace(project_index, entry.id);
                    start_result catch |err| {
                        log.err("failed to start visible terminal dock {d}: {s}", .{ entry.id, @errorName(err) });
                        if (project_index == self.selected_project_index) self.setSidebarNotice("Terminal session failed.");
                    };
                    if (project_index == self.selected_project_index) {
                        visible_changed = true;
                    }
                }
                if (!dock_visible and !entry.dock.hasRunningSession()) continue;
                const changed = entry.dock.poll(self.allocator) catch |err| blk: {
                    log.err("failed to poll terminal dock {d}: {s}", .{ entry.id, @errorName(err) });
                    if (project_index == self.selected_project_index and dock_visible) {
                        self.setSidebarNotice("Terminal session failed.");
                    }
                    break :blk false;
                };
                if (entry.dock.consumeWorkspaceChange()) self.markDirty();
                self.drainTerminalDockNotifications(project_index, entry.id, &entry.dock) catch |err| {
                    log.warn("failed to apply terminal dock notification: {s}", .{@errorName(err)});
                };
                if (changed and project_index == self.selected_project_index and dock_visible) visible_changed = true;
            }
            if (exited_editor_dock_id) |dock_id| {
                if (self.closeExitedEditorTerminalPane(project_index, dock_id) and project_index == self.selected_project_index) {
                    visible_changed = true;
                }
            }
            self.pollManagedProcesses(project_index);
        }
        if (visible_changed) self.last_terminal_activity_ms = monotonicMs();
        return visible_changed;
    }

    fn closeExitedEditorTerminalPane(self: *AppState, project_index: usize, dock_id: u32) bool {
        if (project_index >= self.projects.items.len) return false;
        var project = &self.projects.items[project_index];
        var layout = &project.workspace_layout;
        const pane_id = layout.visibleTerminalPaneIdForDock(dock_id) orelse return false;
        const pane = layout.paneById(pane_id) orelse return false;
        const terminal_ref = switch (pane.ref) {
            .terminal => |ref| ref,
            else => return false,
        };
        if (terminal_ref.purpose != .editor) return false;
        if (layout.visiblePaneCount() <= 1) return false;

        if (project.terminalDockEntryById(dock_id)) |entry| {
            entry.dock.terminateAllSessions();
            _ = project.removeTerminalDockById(self.allocator, dock_id);
        }
        var removed_ref = layout.closePane(self.allocator, pane_id) orelse return false;
        defer deinitWorkspacePaneRef(&removed_ref, self.allocator);
        if (self.selected_project_index == project_index and !layout.hasVisiblePaneKind(.terminal)) self.terminal_focused = false;
        self.setSidebarNotice("Editor pane closed.");
        self.markDirty();
        return true;
    }

    fn drainTerminalDockNotifications(self: *AppState, project_index: usize, dock_id: u32, dock: *terminal.Dock) !void {
        if (project_index >= self.projects.items.len) return;
        const event = dock.takeActiveNotification() orelse return;
        const project = &self.projects.items[project_index];
        _ = try self.updateSurface(.{
            .session_id = event.session_id,
            .workspace_id = project.id,
            .workspace_path = project.path,
            .dock_id = dock_id,
            .pane_id = event.pane_id,
            .attention = event.attention,
            .unread_increment = 1,
            .last_event_title = if (event.title.len > 0) event.title else "Terminal",
            .last_event_body = event.body,
        });
    }

    /// Returns mutable browser UI/runtime state for desktop control surfaces.
    pub fn browserState(self: *AppState) *browser_runtime.State {
        return &self.browser_state;
    }

    /// Returns read-only browser UI/runtime state for desktop rendering.
    pub fn browserStateConst(self: *const AppState) *const browser_runtime.State {
        return &self.browser_state;
    }

    /// Supplies the native SDL window handle that platform webviews attach under.
    pub fn attachBrowserHostWindow(self: *AppState, handle: ?*anyopaque) void {
        self.browser_state.controller.setHostWindow(handle) catch |err| {
            log.warn("failed to attach browser host window: {s}", .{@errorName(err)});
        };
    }

    /// Opens the browser during startup when an explicit debug environment flag requests it.
    pub fn openBrowserOnLaunchIfRequested(self: *AppState) void {
        if (!self.browser_textures_enabled) return;

        const value = std.mem.sliceTo(std.c.getenv("VERDE_OPEN_BROWSER_ON_START") orelse return, 0);
        if (!std.mem.eql(u8, value, "1")) return;
        self.browser_start_eval_pending = false;
        if (std.c.getenv("VERDE_BROWSER_START_URL")) |raw_start_url| {
            const start_url = std.mem.sliceTo(raw_start_url, 0);
            if (start_url.len > 0) {
                const normalized = self.normalizeBrowserUrl(start_url) catch |err| {
                    log.warn("failed to normalize browser startup URL: {s}", .{@errorName(err)});
                    self.setSidebarNotice("Failed to normalize browser startup URL.");
                    return;
                };
                defer self.allocator.free(normalized);
                self.browser_state.setCurrentUrl(normalized) catch |err| {
                    log.warn("failed to store browser startup URL: {s}", .{@errorName(err)});
                    return;
                };
                self.browser_state.setAddress(normalized);
            }
        }
        if (std.c.getenv("VERDE_BROWSER_START_EVAL")) |raw_start_eval| {
            self.browser_start_eval_pending = std.mem.sliceTo(raw_start_eval, 0).len > 0;
        }
        // Wait a couple of app-loop turns so this exercises the same path as a
        // user click after the window is live instead of front-loading browser
        // creation before the first frame.
        self.browser_launch_open_delay_frames = 2;
    }

    /// Reopens the browser runtime when the selected project restored a visible browser workspace pane.
    pub fn restorePersistedBrowserPaneOnLaunch(self: *AppState) void {
        if (!self.browser_textures_enabled) return;
        if (self.browser_launch_open_delay_frames > 0 or self.browser_state.controls_visible) return;
        if (self.projects.items.len == 0) return;
        var layout = &self.projects.items[self.selected_project_index].workspace_layout;
        if (!layout.hasVisiblePaneKind(.browser)) return;
        if (layout.visibleBrowserPaneId()) |pane_id| {
            self.applyBrowserPaneSnapshotToRuntime(self.selected_project_index, pane_id);
        }
        self.browser_launch_open_delay_frames = 2;
    }

    /// Applies keyboard focus on launch based on the restored focused pane, so a
    /// reopened terminal (or browser/chat) pane is immediately typeable instead
    /// of requiring a manual mouse click to start receiving input.
    pub fn applyInitialWorkspaceFocusOnLaunch(self: *AppState) void {
        if (self.projects.items.len == 0) return;
        const layout = &self.projects.items[self.selected_project_index].workspace_layout;
        const pane_id = layout.focused_pane_id orelse layout.firstVisiblePaneId() orelse return;
        const pane = layout.paneById(pane_id) orelse return;
        switch (pane.ref) {
            .terminal => self.requestTerminalFocus(),
            .browser => self.focusBrowserPane(),
            .chat => self.requestComposerFocus(),
        }
    }

    /// Toggles the desktop browser control surface and the underlying browser runtime.
    pub fn toggleBrowser(self: *AppState) void {
        if (!self.browser_textures_enabled) {
            self.setSidebarNotice("Browser is disabled for the SDL_GPU non-image renderer experiment.");
            return;
        }

        if (self.browser_state.controls_visible) {
            self.hideBrowser();
            return;
        }

        self.ensureCurrentProjectWorkspace();
        const browser_pane_id = if (self.projects.items.len > 0)
            self.projects.items[self.selected_project_index].workspace_layout.ensureBrowserPane(self.allocator) catch |err| {
                log.err("failed to open browser workspace pane: {s}", .{@errorName(err)});
                self.setSidebarNotice("Failed to open browser pane.");
                return;
            }
        else
            null;
        if (self.projects.items.len > 0) {
            self.projects.items[self.selected_project_index].workspace_layout.maximized_pane_id = null;
        }
        if (browser_pane_id) |pane_id| {
            self.applyBrowserPaneSnapshotToRuntime(self.selected_project_index, pane_id);
        }
        const restore_url = if (browser_pane_id) |pane_id|
            self.browserPaneSnapshotUrl(self.selected_project_index, pane_id)
        else
            null;

        self.browser_state.setControlsVisible(true);
        self.browser_address_focused = true;
        self.browser_address_cursor = self.browser_state.addressInput().len;
        self.unfocusBrowserPane();
        self.terminal_focused = false;
        self.composer_focused = false;
        if (browser_pane_id) |pane_id| _ = self.focusCurrentProjectWorkspacePane(pane_id);
        self.browser_state.status = .opening;
        if (restore_url) |url| {
            if (!isBlankBrowserUrl(url)) {
                self.navigateBrowserToUrl(url) catch |err| {
                    log.err("failed to restore browser runtime: {s}", .{@errorName(err)});
                    self.browser_state.status = .failed;
                    self.browser_state.setLastError("Failed to restore browser runtime.") catch {};
                    self.setSidebarNotice("Failed to reopen browser.");
                    return;
                };
                self.blurNativeBrowserForAddressField();
                self.setSidebarNotice("Browser reopened.");
                return;
            }
        } else if (!self.browser_state.controller.runtimeInitialized() and self.browser_state.current_url != null) {
            const url = self.browser_state.current_url.?;
            self.navigateBrowserToUrl(url) catch |err| {
                log.err("failed to restore browser runtime: {s}", .{@errorName(err)});
                self.browser_state.status = .failed;
                self.browser_state.setLastError("Failed to restore browser runtime.") catch {};
                self.setSidebarNotice("Failed to reopen browser.");
                return;
            };
            self.blurNativeBrowserForAddressField();
            self.setSidebarNotice("Browser reopened.");
            return;
        }

        self.browser_state.controller.show() catch |err| {
            log.err("failed to show browser runtime: {s}", .{@errorName(err)});
            self.browser_state.status = .failed;
            self.browser_state.setLastError("Failed to show browser runtime.") catch {};
            self.setSidebarNotice("Failed to show browser.");
            return;
        };
        self.blurNativeBrowserForAddressField();
        self.setSidebarNotice("Browser opened.");
    }

    /// Ensures the singleton browser pane exists in a workspace without selecting that workspace or stealing keyboard focus.
    pub fn openBrowserInWorkspace(self: *AppState, project_index: usize, url: ?[]const u8) !BrowserOpenResult {
        if (!self.browser_textures_enabled) {
            self.setSidebarNotice("Browser is disabled for the SDL_GPU non-image renderer experiment.");
            return error.BrowserDisabled;
        }
        if (project_index >= self.projects.items.len) return error.WorkspaceNotFound;

        const selected_index = self.selected_project_index;
        const selected_focus = if (selected_index < self.projects.items.len)
            self.projects.items[selected_index].workspace_layout.focused_pane_id
        else
            null;
        const selected_focus_was_browser = if (selected_focus) |pane_id| focused: {
            const kind = self.workspacePaneKind(selected_index, pane_id) orelse break :focused false;
            break :focused kind == .browser;
        } else false;

        const previous_workspace = self.browserWorkspaceIndex();
        const moved_from_workspace = if (previous_workspace) |index|
            if (index != project_index) index else null
        else
            null;

        for (self.projects.items, 0..) |*project, index| {
            if (index == project_index) continue;
            _ = project.workspace_layout.closePaneKind(self.allocator, .browser);
        }

        var layout = &self.projects.items[project_index].workspace_layout;
        const browser_pane_id = try layout.ensureBrowserPane(self.allocator);
        layout.maximized_pane_id = null;
        self.applyBrowserPaneSnapshotToRuntime(project_index, browser_pane_id);
        const restore_url = self.browserPaneSnapshotUrl(project_index, browser_pane_id);

        if (project_index == selected_index) {
            self.restoreWorkspaceFocusIfVisible(project_index, selected_focus, browser_pane_id);
        } else {
            self.restoreWorkspaceFocusIfVisible(selected_index, selected_focus, null);
            if (selected_focus_was_browser) self.unfocusBrowserPane();
        }

        self.browser_state.setControlsVisible(true);
        self.browser_address_focused = false;
        self.browser_inspector_menu_open = false;
        self.browser_address_cursor = self.browser_state.addressInput().len;

        if (url) |target_url| {
            try self.navigateBrowserToUrl(target_url);
        } else if (restore_url) |target_url| {
            if (isBlankBrowserUrl(target_url)) {
                try self.showBrowserRuntimeForLiveOpen();
            } else {
                try self.navigateBrowserToUrl(target_url);
            }
        } else if (!self.browser_state.controller.runtimeInitialized() and self.browser_state.current_url != null) {
            try self.navigateBrowserToUrl(self.browser_state.current_url.?);
        } else {
            try self.showBrowserRuntimeForLiveOpen();
        }

        if (project_index == selected_index) {
            self.restoreBrowserSurfaceForRenderedLayout();
            self.syncBrowserPaneBoundsToBackend();
        } else {
            self.noteBrowserPaneNotRendered();
        }

        self.setSidebarNotice("Browser opened.");
        self.markDirty();
        return .{
            .pane_id = browser_pane_id,
            .workspace_index = project_index,
            .moved_from_workspace = moved_from_workspace,
        };
    }

    /// Navigates the browser runtime through the same normalization path used by the address field.
    pub fn navigateBrowserToUrl(self: *AppState, value: []const u8) !void {
        const trimmed = std.mem.trim(u8, value, &std.ascii.whitespace);
        if (trimmed.len == 0) return error.EmptyBrowserUrl;

        const normalized = try self.normalizeBrowserUrl(trimmed);
        defer self.allocator.free(normalized);

        self.browser_state.status = .opening;
        self.browser_state.controller.navigate(normalized) catch |err| {
            log.err("failed to navigate browser runtime: {s}", .{@errorName(err)});
            self.browser_state.status = .failed;
            self.browser_state.setLastError("Failed to navigate browser runtime.") catch {};
            self.setSidebarNotice("Browser navigation failed.");
            return error.BrowserNavigationFailed;
        };
        self.browser_state.setAddress(normalized);
        self.browser_address_cursor = self.browser_state.addressInput().len;
        self.recordVisibleBrowserPaneNavigation(normalized);
        self.setSidebarNotice("Browser navigation requested.");
    }

    /// Returns the workspace currently hosting the singleton browser pane, if any.
    pub fn browserWorkspaceLocation(self: *const AppState) ?BrowserWorkspaceLocation {
        for (self.projects.items, 0..) |project, index| {
            const pane_id = project.workspace_layout.visibleBrowserPaneId() orelse continue;
            return .{
                .index = index,
                .pane_id = pane_id,
            };
        }
        return null;
    }

    /// Returns the workspace currently hosting the singleton browser pane, if any.
    pub fn browserWorkspaceIndex(self: *const AppState) ?usize {
        const location = self.browserWorkspaceLocation() orelse return null;
        return location.index;
    }

    /// Returns the visible singleton browser pane id, if any.
    pub fn browserWorkspacePaneId(self: *const AppState) ?WorkspacePaneId {
        const location = self.browserWorkspaceLocation() orelse return null;
        return location.pane_id;
    }

    fn browserPaneRefMutable(self: *AppState, project_index: usize, pane_id: WorkspacePaneId) ?*BrowserPaneRef {
        if (project_index >= self.projects.items.len) return null;
        const pane = self.projects.items[project_index].workspace_layout.paneByIdMutable(pane_id) orelse return null;
        return switch (pane.ref) {
            .browser => |*ref| ref,
            else => null,
        };
    }

    fn visibleBrowserPaneRefMutable(self: *AppState) ?*BrowserPaneRef {
        const location = self.browserWorkspaceLocation() orelse return null;
        return self.browserPaneRefMutable(location.index, location.pane_id);
    }

    fn browserPaneSnapshotUrl(self: *AppState, project_index: usize, pane_id: WorkspacePaneId) ?[]const u8 {
        const ref = self.browserPaneRefMutable(project_index, pane_id) orelse return null;
        return ref.url;
    }

    fn applyBrowserPaneSnapshotToRuntime(self: *AppState, project_index: usize, pane_id: WorkspacePaneId) void {
        const ref = self.browserPaneRefMutable(project_index, pane_id) orelse return;
        if (ref.url) |url| {
            self.browser_state.setCurrentUrl(url) catch |err| {
                log.warn("failed to restore browser pane URL: {s}", .{@errorName(err)});
            };
            self.browser_state.setAddress(url);
            self.browser_address_cursor = self.browser_state.addressInput().len;
        }
        if (ref.title) |title| {
            self.browser_state.setCurrentTitle(title) catch |err| {
                log.warn("failed to restore browser pane title: {s}", .{@errorName(err)});
            };
        }
    }

    fn recordVisibleBrowserPaneNavigation(self: *AppState, url: []const u8) void {
        const ref = self.visibleBrowserPaneRefMutable() orelse return;
        if (isBlankBrowserUrl(url)) {
            if (ref.url) |existing_url| {
                if (!isBlankBrowserUrl(existing_url)) return;
            }
        }
        ref.recordNavigation(self.allocator, url) catch |err| {
            log.warn("failed to persist browser pane URL history: {s}", .{@errorName(err)});
            return;
        };
        self.markDirty();
    }

    fn recordVisibleBrowserPaneTitle(self: *AppState, title: []const u8) void {
        const ref = self.visibleBrowserPaneRefMutable() orelse return;
        ref.setTitle(self.allocator, title) catch |err| {
            log.warn("failed to persist browser pane title: {s}", .{@errorName(err)});
            return;
        };
        self.markDirty();
    }

    fn navigatePersistedBrowserHistory(self: *AppState, delta: i32) bool {
        const ref = self.visibleBrowserPaneRefMutable() orelse return false;
        const target = ref.historyTarget(delta) orelse return false;
        ref.history_index = target.index;
        ref.setUrl(self.allocator, target.url) catch |err| {
            log.warn("failed to update persisted browser history index: {s}", .{@errorName(err)});
            return false;
        };
        self.browser_state.status = .opening;
        self.browser_state.controller.navigate(target.url) catch |err| {
            log.warn("failed to navigate persisted browser history: {s}", .{@errorName(err)});
            self.browser_state.setLastError("Failed to navigate browser history.") catch {};
            return false;
        };
        self.browser_state.setCurrentUrl(target.url) catch {};
        self.browser_state.setAddress(target.url);
        self.browser_address_cursor = self.browser_state.addressInput().len;
        self.markDirty();
        return true;
    }

    fn showBrowserRuntimeForLiveOpen(self: *AppState) !void {
        self.browser_state.status = .opening;
        self.browser_state.controller.show() catch |err| {
            log.err("failed to show browser runtime: {s}", .{@errorName(err)});
            self.browser_state.status = .failed;
            self.browser_state.setLastError("Failed to show browser runtime.") catch {};
            self.setSidebarNotice("Failed to show browser.");
            return error.BrowserOpenFailed;
        };
    }

    fn restoreWorkspaceFocusIfVisible(self: *AppState, project_index: usize, pane_id: ?WorkspacePaneId, except_pane_id: ?WorkspacePaneId) void {
        if (project_index >= self.projects.items.len) return;
        const wanted = pane_id orelse return;
        if (except_pane_id != null and except_pane_id.? == wanted) return;
        var layout = &self.projects.items[project_index].workspace_layout;
        const pane = layout.paneById(wanted) orelse return;
        if (pane.minimized) return;
        layout.focused_pane_id = wanted;
    }

    fn workspacePaneKind(self: *const AppState, project_index: usize, pane_id: WorkspacePaneId) ?WorkspacePaneKind {
        if (project_index >= self.projects.items.len) return null;
        const pane = self.projects.items[project_index].workspace_layout.paneById(pane_id) orelse return null;
        return std.meta.activeTag(pane.ref);
    }

    fn blurNativeBrowserForAddressField(self: *AppState) void {
        if (!self.browser_address_focused) return;
        self.browser_state.controller.blur() catch |err| {
            log.warn("failed to clear native browser focus for address field: {s}", .{@errorName(err)});
        };
    }

    /// Closes the browser dock and fully tears the browser runtime down until the next open.
    pub fn closeBrowser(self: *AppState) void {
        self.browser_state.setControlsVisible(false);
        self.browser_state.setInspectorEnabled(false);
        self.browser_state.clearSuppressedEvalResults();
        self.browser_surface_suspended_for_palette_overlay = false;
        self.browser_surface_suspended_for_layout = false;
        self.unfocusBrowserPane();
        self.browser_pane_hovered = false;
        self.browser_address_focused = false;
        self.browser_inspector_menu_open = false;
        self.browser_state.controller.shutdown();
        self.browser_state.status = .hidden;
        self.browser_state.setLastError(null) catch {};
        for (self.projects.items) |*project| {
            _ = project.workspace_layout.closePaneKind(self.allocator, .browser);
        }
        self.ensureCurrentProjectWorkspace();
        self.setSidebarNotice("Browser closed.");
        self.markDirty();
    }

    /// Hides the desktop browser control surface and its browser runtime.
    pub fn hideBrowser(self: *AppState) void {
        self.browser_state.setControlsVisible(false);
        self.browser_state.setInspectorEnabled(false);
        self.browser_state.clearSuppressedEvalResults();
        self.browser_surface_suspended_for_palette_overlay = false;
        self.browser_surface_suspended_for_layout = false;
        self.unfocusBrowserPane();
        self.browser_address_focused = false;
        self.browser_inspector_menu_open = false;
        self.browser_state.controller.hide() catch |err| {
            log.err("failed to hide browser runtime: {s}", .{@errorName(err)});
            self.browser_state.status = .failed;
            self.browser_state.setLastError("Failed to hide browser runtime.") catch {};
            self.setSidebarNotice("Failed to hide browser.");
            return;
        };
        if (self.projects.items.len > 0) {
            _ = self.projects.items[self.selected_project_index].workspace_layout.minimizePaneKind(self.allocator, .browser);
        }
        self.setSidebarNotice("Browser hidden.");
        self.markDirty();
    }

    /// Temporarily hides the native browser surface while the host SDL window is hidden/minimized.
    pub fn suspendBrowserForHostWindowHidden(self: *AppState) void {
        if (!self.isBrowserVisible()) return;
        self.unfocusBrowserPane();
        self.browser_address_focused = false;
        self.browser_state.controller.hide() catch |err| {
            log.warn("failed to hide browser runtime for host window lifecycle: {s}", .{@errorName(err)});
            self.browser_state.status = .failed;
            self.browser_state.setLastError("Failed to hide browser runtime while the app window changed visibility.") catch {};
            return;
        };
        self.suppressNextBrowserClosedEvent();
    }

    /// Restores a visible browser dock after the host SDL window is shown/restored.
    pub fn resumeBrowserAfterHostWindowShown(self: *AppState) void {
        if (!self.isBrowserVisible()) return;
        self.browser_state.status = .opening;
        self.browser_state.controller.show() catch |err| {
            log.warn("failed to restore browser runtime after host window lifecycle: {s}", .{@errorName(err)});
            self.browser_state.status = .failed;
            self.browser_state.setLastError("Failed to restore browser runtime after the app window became visible.") catch {};
            return;
        };
        self.syncBrowserPaneBoundsToBackend();
    }

    /// Reports whether the browser dock is visible in the chat workspace.
    pub fn isBrowserVisible(self: *const AppState) bool {
        return self.browser_state.controls_visible;
    }

    /// Reports whether the current browser runtime can host the bundled page inspector.
    pub fn canUseBrowserInspector(self: *const AppState) bool {
        return self.browser_state.controller.supportsInspector();
    }

    fn browserBridgePolicyAllowsCurrentPage(self: *const AppState) bool {
        const page_url = if (self.browser_state.current_url) |url| url else self.browser_state.addressInput();
        return (browser_runtime.BridgePolicy{
            .allow_untrusted = browserBridgePolicyAllowsUntrustedPages(),
        }).allowsHostMessaging(page_url);
    }

    fn browserInspectorPolicyAllowsCurrentPage(self: *const AppState) bool {
        const page_url = if (self.browser_state.current_url) |url| url else self.browser_state.addressInput();
        return (browser_runtime.BridgePolicy{
            .allow_untrusted = browserBridgePolicyAllowsUntrustedPages(),
        }).allowsInspector(page_url);
    }

    fn browserBridgePolicyAllowsUntrustedPages() bool {
        const raw = std.c.getenv("VERDE_BROWSER_ALLOW_UNTRUSTED_BRIDGE") orelse return false;
        const value = std.mem.trim(u8, std.mem.sliceTo(raw, 0), &std.ascii.whitespace);
        return std.mem.eql(u8, value, "1") or
            std.ascii.eqlIgnoreCase(value, "true") or
            std.ascii.eqlIgnoreCase(value, "yes");
    }

    /// Reports whether the bundled browser inspector is currently armed.
    pub fn isBrowserInspectorEnabled(self: *const AppState) bool {
        return self.browser_state.inspectorEnabled();
    }

    /// Reports which interaction mode the bundled browser inspector will use.
    pub fn browserInspectorMode(self: *const AppState) browser_runtime.InspectorMode {
        return self.browser_state.inspectorMode();
    }

    /// Reports whether the browser inspector mode menu is open in Palette UI.
    pub fn isBrowserInspectorMenuOpen(self: *const AppState) bool {
        return self.browser_inspector_menu_open;
    }

    /// Reports whether a Palette overlay has temporarily hidden the native browser surface.
    pub fn isBrowserSurfaceSuspendedForPaletteOverlay(self: *const AppState) bool {
        return self.browser_surface_suspended_for_palette_overlay;
    }

    pub fn isBrowserSurfaceSuspendedForLayout(self: *const AppState) bool {
        return self.browser_surface_suspended_for_layout;
    }

    /// Reports whether the workspace header Open menu is currently open.
    pub fn isWorkspaceHeaderOpenMenuOpen(self: *const AppState) bool {
        return self.workspace_header_open_menu_open;
    }

    /// Reports whether the Add Project modal is currently open.
    pub fn isProjectImportModalOpen(self: *const AppState) bool {
        return self.show_project_creator;
    }

    /// Reports whether the Thread Import modal is currently open.
    pub fn isThreadImportModalOpen(self: *const AppState) bool {
        return self.thread_import_provider != null;
    }

    /// Reports whether the image preview modal is currently open.
    pub fn isImageModalOpen(self: *const AppState) bool {
        return self.modal_image_path != null;
    }

    /// Reports whether the transcript selection modal is currently open.
    pub fn isTranscriptSelectionModalOpen(self: *const AppState) bool {
        return self.transcript_selection_text != null;
    }

    /// Reports which Palette modal text field owns focus.
    pub fn paletteModalTextFocusName(self: *const AppState) []const u8 {
        return @tagName(self.palette_modal_text_focus);
    }

    /// Reports whether a sidebar context menu is open over the workspace.
    pub fn isSidebarContextMenuOpen(self: *const AppState) bool {
        return self.sidebar_context_menu_open;
    }

    /// Reports whether a composer-owned menu/popover is open over the workspace.
    pub fn isComposerMenuOpen(self: *const AppState) bool {
        return self.composer_locked_model_picker_open or
            self.palette_composer.active_menu != null or
            self.palette_model_picker.isOpen() or
            self.run_config_open;
    }

    /// Opens or closes the browser inspector mode menu for live parity smokes.
    pub fn setBrowserInspectorMenuOpen(self: *AppState, open: bool) bool {
        if (open and (!self.isBrowserVisible() or !self.canUseBrowserInspector())) return false;
        self.browser_inspector_menu_open = open;
        if (open) {
            self.browser_address_focused = false;
            self.unfocusBrowserPane();
        }
        self.syncBrowserPaneBoundsToBackend();
        return true;
    }

    /// Opens or closes the workspace header Open menu for live overlay parity smokes.
    pub fn setWorkspaceHeaderOpenMenuOpen(self: *AppState, open: bool) void {
        self.workspace_header_open_menu_open = open;
        if (!open) self.workspace_header_open_menu_pane_id = null;
        if (open) {
            self.browser_inspector_menu_open = false;
            self.browser_address_focused = false;
            self.unfocusBrowserPane();
        }
        self.syncBrowserPaneBoundsToBackend();
    }

    /// Opens or closes a sidebar context menu for live overlay parity smokes.
    pub fn setSidebarContextMenuOpen(self: *AppState, open: bool) void {
        self.sidebar_context_menu_open = open;
        self.sidebar_context_menu_kind = if (open) .project else .none;
        if (open) {
            self.browser_inspector_menu_open = false;
            self.workspace_header_open_menu_open = false;
            self.workspace_header_open_menu_pane_id = null;
            self.browser_address_focused = false;
            self.unfocusBrowserPane();
        }
        self.syncBrowserPaneBoundsToBackend();
    }

    /// Opens or closes a composer-owned menu for live overlay parity smokes.
    pub fn setComposerMenuOpen(self: *AppState, open: bool) void {
        if (open) {
            self.openRunConfigPopover();
            // Empty workspaces cannot host the run-config popover (no current
            // thread), but live parity smokes still expect the overlay flag to
            // report open; fall back to the composer's inert menu marker.
            if (!self.run_config_open) {
                self.palette_composer.active_menu = .reasoning;
                self.palette_composer.hovered_menu_index = 0;
            }
            self.composer_locked_model_picker_open = false;
            self.closePaletteModelPicker();
            self.browser_inspector_menu_open = false;
            self.workspace_header_open_menu_open = false;
            self.workspace_header_open_menu_pane_id = null;
            self.browser_address_focused = false;
            self.unfocusBrowserPane();
        } else {
            self.palette_composer.active_menu = null;
            self.palette_composer.hovered_menu_index = null;
            self.composer_locked_model_picker_open = false;
            self.closePaletteModelPicker();
            self.closeRunConfigPopover();
        }
        self.syncBrowserPaneBoundsToBackend();
    }

    /// Opens or closes the Add Project modal for live overlay parity smokes.
    pub fn setProjectImportModalOpen(self: *AppState, open: bool) void {
        if (open) {
            self.show_project_creator = true;
            self.palette_modal_text_focus = .project_import;
            self.project_import_cursor = self.importDirectoryDraft().len;
            self.browser_inspector_menu_open = false;
            self.workspace_header_open_menu_open = false;
            self.workspace_header_open_menu_pane_id = null;
            self.browser_address_focused = false;
            self.unfocusBrowserPane();
        } else {
            self.cancelProjectImport();
        }
        self.syncBrowserPaneBoundsToBackend();
    }

    /// Opens or closes the Thread Import modal for live overlay parity smokes.
    pub fn setThreadImportModalOpen(self: *AppState, open: bool) void {
        if (open) {
            self.thread_import_provider = .codex;
            self.thread_import_project_index = self.selected_project_index;
            self.thread_import_selected_index = null;
            self.import_thread_id_storage[0] = 0;
            self.palette_modal_text_focus = .thread_import;
            self.thread_import_cursor = 0;
            self.browser_inspector_menu_open = false;
            self.workspace_header_open_menu_open = false;
            self.workspace_header_open_menu_pane_id = null;
            self.browser_address_focused = false;
            self.unfocusBrowserPane();
        } else {
            self.cancelThreadImport();
        }
        self.syncBrowserPaneBoundsToBackend();
    }

    /// Opens or closes the image preview modal for live overlay parity smokes.
    pub fn setImageModalOpen(self: *AppState, open: bool) void {
        if (open) {
            self.openImageModal("live-smoke-image.png");
            self.browser_inspector_menu_open = false;
            self.workspace_header_open_menu_open = false;
            self.workspace_header_open_menu_pane_id = null;
            self.browser_address_focused = false;
            self.unfocusBrowserPane();
        } else {
            self.closeImageModal();
        }
        self.syncBrowserPaneBoundsToBackend();
    }

    /// Opens or closes the transcript selection modal for live overlay parity smokes.
    pub fn setTranscriptSelectionModalOpen(self: *AppState, open: bool) void {
        if (open) {
            self.closeTranscriptSelectionModal();
            self.transcript_selection_text = self.allocator.dupeZ(u8, "Live transcript selection smoke") catch null;
            self.transcript_selection_modal_requested = true;
            self.browser_inspector_menu_open = false;
            self.workspace_header_open_menu_open = false;
            self.workspace_header_open_menu_pane_id = null;
            self.browser_address_focused = false;
            self.unfocusBrowserPane();
        } else {
            self.closeTranscriptSelectionModal();
        }
        self.syncBrowserPaneBoundsToBackend();
    }

    /// Computes the height reserved for the browser dock inside the chat workspace.
    pub fn browserPanelHeight(self: *const AppState, available_height: f32) f32 {
        if (!self.isBrowserVisible()) return 0.0;
        return theme.clampf(available_height * 0.24, theme.scaledUi(182.0), @min(theme.scaledUi(320.0), available_height * 0.42));
    }

    /// Computes the width reserved for the browser pane when the chat workspace is split horizontally.
    pub fn browserPanelWidth(self: *const AppState, available_width: f32) f32 {
        if (!self.isBrowserVisible()) return 0.0;
        return theme.clampf(available_width * 0.5, theme.scaledUi(320.0), available_width * 0.62);
    }

    /// Records the latest browser pane bounds plus the helper input size so SDL events can be remapped correctly.
    pub fn noteBrowserPaneRegion(self: *AppState, min: [2]f32, max: [2]f32, input_size: [2]f32, hovered: bool) void {
        self.browser_pane_min = min;
        self.browser_pane_max = max;
        self.browser_pane_input_size = input_size;
        self.browser_pane_hovered = hovered;
        self.restoreBrowserSurfaceForRenderedLayout();
        self.syncBrowserPaneBoundsToBackend();
    }

    pub fn noteBrowserPaneNotRendered(self: *AppState) void {
        if (!self.isBrowserVisible()) return;
        self.browser_pane_hovered = false;
        self.browser_pane_min = .{ 0.0, 0.0 };
        self.browser_pane_max = .{ 0.0, 0.0 };
        self.browser_pane_input_size = .{ 0.0, 0.0 };
        if (self.browser_surface_suspended_for_layout) return;
        self.browser_state.controller.hide() catch |err| {
            log.warn("failed to hide browser runtime while pane is not rendered: {s}", .{@errorName(err)});
            self.browser_state.status = .failed;
            self.browser_state.setLastError("Failed to hide browser runtime while pane is not visible in the layout.") catch {};
            return;
        };
        self.suppressNextBrowserClosedEvent();
        self.browser_surface_suspended_for_layout = true;
        self.unfocusBrowserPane();
    }

    /// Records the app window origin used to place native child/overlay browser surfaces.
    pub fn noteAppWindowFrame(self: *AppState, screen_x: i32, screen_y: i32, display_scale: f32) void {
        self.app_window_screen_origin = .{ screen_x, screen_y };
        self.app_window_display_scale = @max(display_scale, 0.001);
        self.syncBrowserPaneBoundsToBackend();
    }

    /// Returns the device scale used by WPE when it renders logical browser pixels into a high-density frame.
    pub fn browserPaneDeviceScale(self: *const AppState) f32 {
        const presentation = self.browser_state.controller.presentationKind();
        const runtime = self.browser_state.controller.runtimeKind();
        if (runtime == .native_webview and presentation == .offscreen_texture) {
            return theme.clampf(self.app_window_display_scale, 1.0, 5.0);
        }
        return 1.0;
    }

    /// Returns the browser input coordinate space for the current visible pane rectangle.
    pub fn browserPaneInputSize(self: *const AppState, pane_width: f32, pane_height: f32) [2]f32 {
        const scale = self.browserPaneDeviceScale();
        return .{
            @max(@round(pane_width / scale), 1.0),
            @max(@round(pane_height / scale), 1.0),
        };
    }

    fn syncBrowserPaneBoundsToBackend(self: *AppState) void {
        if (!self.isBrowserVisible()) return;
        if (self.browser_surface_suspended_for_layout) return;
        if (self.browser_pane_max[0] <= self.browser_pane_min[0] or self.browser_pane_max[1] <= self.browser_pane_min[1]) return;
        if (self.syncBrowserSurfaceOcclusion()) return;
        const pane_width = self.browser_pane_max[0] - self.browser_pane_min[0];
        const pane_height = self.browser_pane_max[1] - self.browser_pane_min[1];
        const presentation = self.browser_state.controller.presentationKind();
        const runtime = self.browser_state.controller.runtimeKind();
        const uses_native_surface = switch (presentation) {
            .native_child_view, .native_wayland_surface, .helper_window => true,
            .snapshot_texture, .offscreen_texture, .stub => false,
        };
        const uses_scaled_wpe_texture = runtime == .native_webview and presentation == .offscreen_texture;
        const scale = if (uses_native_surface) @max(self.app_window_display_scale, 0.001) else 1.0;
        const size_scale = if (uses_scaled_wpe_texture) self.browserPaneDeviceScale() else scale;
        const pane_x: i32 = @intFromFloat(@round(self.browser_pane_min[0] / scale));
        const pane_y: i32 = @intFromFloat(@round(self.browser_pane_min[1] / scale));
        const x = if (presentation == .native_wayland_surface)
            pane_x
        else
            self.app_window_screen_origin[0] + pane_x;
        const y = if (presentation == .native_wayland_surface)
            pane_y
        else
            self.app_window_screen_origin[1] + pane_y;
        const width: u32 = @intFromFloat(@max(@round(pane_width / size_scale), 1.0));
        const height: u32 = @intFromFloat(@max(@round(pane_height / size_scale), 1.0));
        self.browser_state.controller.setPaneBounds(.{
            .screen_x = x,
            .screen_y = y,
            .width = width,
            .height = height,
            .scale = if (uses_scaled_wpe_texture) self.browserPaneDeviceScale() else 1.0,
        }) catch |err| {
            log.warn("failed to sync browser pane bounds: {s}", .{@errorName(err)});
        };
    }

    fn restoreBrowserSurfaceForRenderedLayout(self: *AppState) void {
        if (!self.browser_surface_suspended_for_layout) return;
        self.browser_surface_suspended_for_layout = false;
        if (self.browserBlockedByPaletteOverlay()) return;
        self.browser_state.status = .opening;
        self.browser_state.controller.show() catch |err| {
            log.warn("failed to restore browser runtime after pane returned to layout: {s}", .{@errorName(err)});
            self.browser_state.status = .failed;
            self.browser_state.setLastError("Failed to restore browser runtime after pane returned to the layout.") catch {};
            return;
        };
        if (!self.browser_pane_focused) {
            self.browser_state.controller.blur() catch |err| {
                log.warn("failed to clear restored native browser focus: {s}", .{@errorName(err)});
            };
        }
    }

    fn syncBrowserSurfaceOcclusion(self: *AppState) bool {
        const blocked = self.browserBlockedByPaletteOverlay();
        if (blocked) {
            if (!self.browser_surface_suspended_for_palette_overlay) {
                self.browser_state.controller.hide() catch |err| {
                    log.warn("failed to hide browser runtime for palette overlay: {s}", .{@errorName(err)});
                    self.browser_state.status = .failed;
                    self.browser_state.setLastError("Failed to hide browser runtime for Palette overlay.") catch {};
                    return true;
                };
                self.suppressNextBrowserClosedEvent();
                self.browser_surface_suspended_for_palette_overlay = true;
                self.unfocusBrowserPane();
            }
            return true;
        }

        if (self.browser_surface_suspended_for_palette_overlay) {
            self.browser_surface_suspended_for_palette_overlay = false;
            self.browser_state.status = .opening;
            self.browser_state.controller.show() catch |err| {
                log.warn("failed to restore browser runtime after palette overlay: {s}", .{@errorName(err)});
                self.browser_state.status = .failed;
                self.browser_state.setLastError("Failed to restore browser runtime after Palette overlay.") catch {};
                return false;
            };
            if (!self.browser_pane_focused) {
                self.browser_state.controller.blur() catch |err| {
                    log.warn("failed to clear restored native browser focus: {s}", .{@errorName(err)});
                };
            }
        }
        return false;
    }

    fn browserBlockedByPaletteOverlay(self: *const AppState) bool {
        return self.show_project_creator or
            self.show_settings_modal or
            self.rename_project_index != null or
            self.thread_import_provider != null or
            self.modal_image_path != null or
            self.transcript_selection_text != null or
            self.palette_modal_text_focus != .none or
            self.browser_inspector_menu_open or
            self.workspace_header_open_menu_open or
            self.sidebar_context_menu_open or
            self.composer_locked_model_picker_open or
            self.palette_composer.active_menu != null or
            self.palette_model_picker.isOpen() or
            self.run_config_open;
    }

    fn suppressNextBrowserClosedEvent(self: *AppState) void {
        self.browser_suppressed_closed_events = std.math.add(u8, self.browser_suppressed_closed_events, 1) catch std.math.maxInt(u8);
    }

    fn consumeSuppressedBrowserClosedEvent(self: *AppState) bool {
        if (self.browser_suppressed_closed_events == 0) return false;
        self.browser_suppressed_closed_events -= 1;
        return true;
    }

    /// Clears browser-pane keyboard focus when another UI surface takes ownership.
    pub fn unfocusBrowserPane(self: *AppState) void {
        const was_focused = self.browser_pane_focused;
        const native_focused = self.isNativeBrowserSurfaceFocused();
        self.browser_pane_focused = false;
        if (was_focused or native_focused) {
            self.browser_state.controller.blur() catch |err| {
                log.warn("failed to clear native browser focus: {s}", .{@errorName(err)});
            };
        }
    }

    pub fn focusBrowserPane(self: *AppState) void {
        self.browser_pane_focused = true;
        self.terminal_focused = false;
        self.composer_focused = false;
        self.palette_composer.focused = false;
        self.browser_address_focused = false;
        if (self.projects.items.len > 0) {
            var layout = &self.projects.items[self.selected_project_index].workspace_layout;
            if (layout.visibleBrowserPaneId()) |pane_id| {
                layout.focused_pane_id = pane_id;
            }
        }
        self.browser_state.controller.focus() catch |err| {
            log.warn("failed to focus native browser surface: {s}", .{@errorName(err)});
        };
        self.markDirty();
    }

    /// Reports whether the browser pane currently owns keyboard input.
    pub fn isBrowserPaneFocused(self: *const AppState) bool {
        return self.isBrowserVisible() and self.browser_pane_focused;
    }

    /// Reports whether the native child browser view owns OS keyboard input.
    pub fn isNativeBrowserSurfaceFocused(self: *const AppState) bool {
        return self.isBrowserVisible() and self.browser_state.controller.hasNativeFocus();
    }

    /// Reports whether the browser pane is backed by a platform view that receives
    /// keyboard input directly from the OS rather than through SDL forwarding.
    pub fn browserPaneUsesNativeKeyboardSurface(self: *const AppState) bool {
        if (!self.isBrowserVisible()) return false;
        return switch (self.browser_state.controller.presentationKind()) {
            .native_child_view, .native_wayland_surface, .helper_window => true,
            .snapshot_texture, .offscreen_texture, .stub => false,
        };
    }

    /// Reports whether the last rendered browser pane contains the given framebuffer-space point.
    pub fn browserPaneContains(self: *const AppState, x: f32, y: f32) bool {
        if (!self.isBrowserVisible()) return false;
        if (self.browser_pane_max[0] <= self.browser_pane_min[0] or self.browser_pane_max[1] <= self.browser_pane_min[1]) {
            return false;
        }
        return x >= self.browser_pane_min[0] and
            y >= self.browser_pane_min[1] and
            x <= self.browser_pane_max[0] and
            y <= self.browser_pane_max[1];
    }

    /// Forwards browser-pane pointer input after converting it into pane-local coordinates.
    pub fn handleBrowserMouse(self: *AppState, event: browser_runtime.MouseEvent) bool {
        if (!self.isBrowserVisible()) return false;

        const contains_pointer = self.browserPaneContains(event.x, event.y);
        const is_pointer_event = event.button != null or event.wheel_x != 0.0 or event.wheel_y != 0.0;
        if (event.button != null and event.pressed and !contains_pointer) {
            self.unfocusBrowserPane();
            return false;
        }
        if (!contains_pointer and !self.browser_pane_focused) return false;
        if (is_pointer_event and !contains_pointer) return false;
        if (event.button) |button| {
            if (event.pressed and (button == .back or button == .forward)) {
                self.navigateBrowserHistory(if (button == .back) -1 else 1);
                return true;
            }
            if (event.pressed and contains_pointer) {
                self.focusBrowserPane();
            }
        }

        var pane_event = event;
        const displayed_width = self.browser_pane_max[0] - self.browser_pane_min[0];
        const displayed_height = self.browser_pane_max[1] - self.browser_pane_min[1];
        const input_width = @max(self.browser_pane_input_size[0], 1.0);
        const input_height = @max(self.browser_pane_input_size[1], 1.0);
        pane_event.x = (event.x - self.browser_pane_min[0]) * (input_width / @max(displayed_width, 1.0));
        pane_event.y = (event.y - self.browser_pane_min[1]) * (input_height / @max(displayed_height, 1.0));

        const handled = self.browser_state.controller.handleMouse(pane_event) catch |err| {
            log.warn("failed to forward browser mouse input: {s}", .{@errorName(err)});
            return false;
        };
        if (handled and contains_pointer and event.button != null and event.pressed) {
            self.focusBrowserPane();
        }
        if (handled) return true;

        return contains_pointer and is_pointer_event and switch (self.browser_state.controller.presentationKind()) {
            .native_child_view, .native_wayland_surface => true,
            .helper_window, .snapshot_texture, .offscreen_texture, .stub => false,
        };
    }

    /// Forwards browser-pane keyboard and text input when the pane owns focus.
    pub fn handleBrowserKey(self: *AppState, event: browser_runtime.KeyEvent) bool {
        if (!self.isBrowserPaneFocused()) return false;
        return self.browser_state.controller.handleKey(event) catch |err| {
            log.warn("failed to forward browser keyboard input: {s}", .{@errorName(err)});
            return false;
        };
    }

    fn clearBrowserContextMenuLocal(self: *AppState) void {
        for (self.browser_context_menu_items.items) |item| {
            self.allocator.free(item.label);
        }
        self.browser_context_menu_items.clearRetainingCapacity();
        self.browser_context_menu_open = false;
        self.browser_context_menu_anchor_x = 0.0;
        self.browser_context_menu_anchor_y = 0.0;
    }

    pub fn dismissBrowserContextMenu(self: *AppState) void {
        const was_open = self.browser_context_menu_open;
        self.clearBrowserContextMenuLocal();
        if (was_open) {
            self.browser_state.controller.dismissContextMenu() catch |err| {
                log.warn("failed to dismiss browser context menu: {s}", .{@errorName(err)});
            };
        }
    }

    pub fn activateBrowserContextMenuItem(self: *AppState, index: u32) void {
        if (!self.browser_context_menu_open) return;
        var enabled = false;
        for (self.browser_context_menu_items.items) |item| {
            if (item.index == index) {
                enabled = item.enabled and !item.separator and !item.submenu;
                break;
            }
        }
        if (!enabled) return;
        self.clearBrowserContextMenuLocal();
        self.browser_state.controller.activateContextMenuItem(index) catch |err| {
            log.warn("failed to activate browser context menu item: {s}", .{@errorName(err)});
        };
    }

    fn openBrowserContextMenuFromPayload(self: *AppState, payload: []const u8) void {
        var parsed = std.json.parseFromSlice(BrowserContextMenuPayload, self.allocator, payload, .{ .allocate = .alloc_always }) catch |err| {
            log.warn("failed to parse browser context menu payload: {s}", .{@errorName(err)});
            return;
        };
        defer parsed.deinit();

        self.clearBrowserContextMenuLocal();
        const displayed_width = self.browser_pane_max[0] - self.browser_pane_min[0];
        const displayed_height = self.browser_pane_max[1] - self.browser_pane_min[1];
        const input_width = @max(self.browser_pane_input_size[0], 1.0);
        const input_height = @max(self.browser_pane_input_size[1], 1.0);
        self.browser_context_menu_anchor_x = self.browser_pane_min[0] + parsed.value.x * (@max(displayed_width, 1.0) / input_width);
        self.browser_context_menu_anchor_y = self.browser_pane_min[1] + parsed.value.y * (@max(displayed_height, 1.0) / input_height);

        for (parsed.value.items) |item| {
            const label = self.allocator.dupe(u8, item.label) catch |err| {
                log.warn("failed to retain browser context menu label: {s}", .{@errorName(err)});
                continue;
            };
            self.browser_context_menu_items.append(self.allocator, .{
                .index = item.index,
                .label = label,
                .enabled = item.enabled,
                .separator = item.separator,
                .submenu = item.submenu,
            }) catch |err| {
                self.allocator.free(label);
                log.warn("failed to append browser context menu item: {s}", .{@errorName(err)});
            };
        }
        self.browser_context_menu_open = self.browser_context_menu_items.items.len > 0;
        self.browser_address_focused = false;
        self.browser_inspector_menu_open = false;
    }

    /// Re-shows the native browser window without changing dock visibility.
    pub fn reopenBrowserWindow(self: *AppState) void {
        if (!self.browser_state.controller.supportsPopout()) {
            self.setSidebarNotice("Browser pop out is not implemented yet.");
            return;
        }
        self.browser_state.status = .opening;
        self.browser_state.controller.show() catch |err| {
            log.err("failed to re-show browser runtime: {s}", .{@errorName(err)});
            self.browser_state.status = .failed;
            self.browser_state.setLastError("Failed to reopen browser window.") catch {};
            self.setSidebarNotice("Failed to reopen browser window.");
            return;
        };
        self.setSidebarNotice("Browser window reopened.");
    }

    /// Navigates the browser runtime using the current browser address input buffer.
    pub fn navigateBrowserFromAddress(self: *AppState) void {
        self.navigateBrowserToUrl(self.browser_state.addressInput()) catch |err| switch (err) {
            error.EmptyBrowserUrl => {
                self.setSidebarNotice("Enter a browser URL first.");
                return;
            },
            error.BrowserNavigationFailed => return,
            else => {
                self.setSidebarNotice("Failed to normalize browser URL.");
                return;
            },
        };
    }

    /// Navigates typed addresses or reloads when the URL bar already matches the current page.
    pub fn navigateOrReloadBrowserFromAddress(self: *AppState) void {
        const trimmed = std.mem.trim(u8, self.browser_state.addressInput(), &std.ascii.whitespace);
        if (trimmed.len == 0) {
            self.reloadBrowser();
            return;
        }
        const normalized = self.normalizeBrowserUrl(trimmed) catch {
            self.setSidebarNotice("Failed to normalize browser URL.");
            return;
        };
        defer self.allocator.free(normalized);

        if (self.browser_state.current_url) |current_url| {
            if (std.mem.eql(u8, current_url, normalized)) {
                self.reloadBrowser();
                return;
            }
        }

        self.browser_state.status = .opening;
        self.browser_state.controller.navigate(normalized) catch |err| {
            log.err("failed to navigate browser runtime: {s}", .{@errorName(err)});
            self.browser_state.status = .failed;
            self.browser_state.setLastError("Failed to navigate browser runtime.") catch {};
            self.setSidebarNotice("Browser navigation failed.");
            return;
        };
        self.browser_state.setAddress(normalized);
        self.setSidebarNotice("Browser navigation requested.");
    }

    /// Evaluates the current browser JavaScript input inside the browser runtime.
    pub fn evalBrowserScript(self: *AppState) void {
        const trimmed = std.mem.trim(u8, self.browser_state.scriptInput(), &std.ascii.whitespace);
        if (trimmed.len == 0) {
            self.setSidebarNotice("Enter JavaScript first.");
            return;
        }

        self.browser_state.controller.eval(trimmed) catch |err| {
            log.err("failed to evaluate browser script: {s}", .{@errorName(err)});
            self.browser_state.status = .failed;
            self.browser_state.setLastError("Failed to evaluate browser script.") catch {};
            self.setSidebarNotice("Browser script evaluation failed.");
            return;
        };
        self.setSidebarNotice("Browser script evaluation requested.");
    }

    /// Posts the current JSON bridge input into the browser runtime.
    pub fn postBrowserJsonFromInput(self: *AppState) void {
        const trimmed = std.mem.trim(u8, self.browser_state.jsonInput(), &std.ascii.whitespace);
        if (trimmed.len == 0) {
            self.setSidebarNotice("Enter JSON first.");
            return;
        }

        self.browser_state.controller.postJson(trimmed) catch |err| {
            log.err("failed to post browser JSON: {s}", .{@errorName(err)});
            self.browser_state.status = .failed;
            self.browser_state.setLastError("Failed to post browser JSON.") catch {};
            self.setSidebarNotice("Browser JSON bridge failed.");
            return;
        };
        self.setSidebarNotice("Browser JSON bridge requested.");
    }

    /// Toggles the bundled page inspector overlay inside the browser runtime.
    pub fn toggleBrowserInspector(self: *AppState) void {
        if (self.browser_state.inspectorEnabled()) {
            self.disableBrowserInspector(true);
            return;
        }
        self.enableBrowserInspector(true);
    }

    /// Updates the browser inspector mode and reapplies the live inspector when needed.
    pub fn setBrowserInspectorMode(self: *AppState, mode: browser_runtime.InspectorMode) void {
        if (self.browser_state.inspectorMode() == mode) return;

        self.browser_state.setInspectorMode(mode);
        if (!self.browser_state.inspectorEnabled()) {
            self.setSidebarNotice(inspectorModeStoredNotice(mode));
            return;
        }

        self.applyBrowserInspector(true, inspectorModeSwitchedNotice(mode));
    }

    /// Applies queued browser runtime events back onto app-visible browser state.
    pub fn pollBrowser(self: *AppState) bool {
        if (!self.browser_textures_enabled) return false;

        if (self.browser_launch_open_delay_frames == 0 and !self.browser_state.controller.hasBackend()) return false;

        var needs_render = false;
        if (self.browser_launch_open_delay_frames > 0) {
            self.browser_launch_open_delay_frames -= 1;
            if (self.browser_launch_open_delay_frames == 0) {
                self.toggleBrowser();
                needs_render = true;
            }
        }
        needs_render = self.browser_state.controller.uploadFrame() or needs_render;
        while (self.browser_state.controller.pollEvent()) |event| {
            defer event.deinit(self.allocator);
            needs_render = true;
            switch (event) {
                .opened => {
                    self.browser_state.status = .ready;
                    self.browser_state.setLastError(null) catch {};
                },
                .closed => {
                    self.browser_pane_focused = false;
                    self.clearBrowserContextMenuLocal();
                    if (self.consumeSuppressedBrowserClosedEvent()) {
                        continue;
                    }
                    self.browser_state.status = .hidden;
                    self.setSidebarNotice("Browser window closed.");
                },
                .navigated => |url| {
                    self.clearBrowserContextMenuLocal();
                    self.browser_state.status = .ready;
                    self.browser_state.setCurrentUrl(url) catch {};
                    self.browser_state.setAddress(url);
                    self.recordVisibleBrowserPaneNavigation(url);
                    self.browser_state.setLastError(null) catch {};
                },
                .title_changed => |title| {
                    self.browser_state.setCurrentTitle(title) catch {};
                    self.recordVisibleBrowserPaneTitle(title);
                },
                .document_loaded => {
                    self.reapplyBrowserInspectorAfterLoad();
                    self.runBrowserStartupEvalIfRequested();
                },
                .js_message => |message| {
                    const inspector_message = isInspectorBridgeMessage(message);
                    const inspector_message_allowed = inspector_message and
                        self.browser_state.inspectorEnabled() and
                        self.browserInspectorPolicyAllowsCurrentPage();
                    if (!inspector_message_allowed and !self.browserBridgePolicyAllowsCurrentPage()) {
                        const page_url = if (self.browser_state.current_url) |url| url else self.browser_state.addressInput();
                        log.warn("blocked browser bridge message from disallowed page url_len={d}", .{page_url.len});
                        self.browser_state.setLastError("Browser bridge message rejected by origin policy.") catch {};
                        self.setSidebarNotice("Browser bridge message blocked for this page.");
                        continue;
                    }
                    if (isBrowserClipboardMessage(message)) {
                        self.handleBrowserClipboardMessage(message);
                        continue;
                    }
                    if (inspector_message) {
                        if (isInspectorHoverMessage(message) or
                            isInspectorLifecycleMessage(message) or
                            isInspectorPromptChangedMessage(message))
                        {
                            continue;
                        }
                        self.browser_state.setLastJsMessage(message) catch {};
                        if (isInspectorSelectionMessage(message)) {
                            self.setSidebarNotice("Browser inspector captured a selection.");
                        } else if (isInspectorPromptSubmittedMessage(message)) {
                            self.handleInspectorPromptSubmitted(message);
                        }
                        continue;
                    }
                    self.browser_state.setLastJsMessage(message) catch {};
                    self.setSidebarNotice("Browser bridge message received.");
                },
                .eval_result => |result| {
                    self.browser_state.setLastEvalResult(result) catch {};
                    if (self.browser_clipboard_copy_pending) {
                        self.browser_clipboard_copy_pending = false;
                        self.copyBrowserEvalResultToClipboard(result);
                        continue;
                    }
                    if (self.browser_state.consumeSuppressedEvalResult()) {
                        continue;
                    }
                    self.setSidebarNotice("Browser script evaluation completed.");
                },
                .context_menu => |payload| {
                    self.openBrowserContextMenuFromPayload(payload);
                },
                .context_menu_dismissed => {
                    self.clearBrowserContextMenuLocal();
                },
                .failed => |message| {
                    self.browser_state.status = .failed;
                    self.browser_state.setLastError(message) catch {};
                    self.setSidebarNotice("Browser runtime reported a failure.");
                },
            }
        }
        if (self.isNativeBrowserSurfaceFocused() and self.browser_address_focused) {
            self.browser_address_focused = false;
            needs_render = true;
        }
        return needs_render;
    }

    // Adds an https scheme for bare hostnames so the browser control surface accepts normal typed URLs.
    fn normalizeBrowserUrl(self: *AppState, value: []const u8) ![]u8 {
        if (hasUriScheme(value)) {
            return try self.allocator.dupe(u8, value);
        }
        return try std.fmt.allocPrint(self.allocator, "https://{s}", .{value});
    }

    fn hasUriScheme(value: []const u8) bool {
        return std.mem.indexOf(u8, value, "://") != null or
            std.mem.startsWith(u8, value, "about:") or
            std.mem.startsWith(u8, value, "data:") or
            std.mem.startsWith(u8, value, "file:") or
            std.mem.startsWith(u8, value, "blob:") or
            std.mem.startsWith(u8, value, "javascript:") or
            std.mem.startsWith(u8, value, "mailto:");
    }

    fn isBlankBrowserUrl(value: []const u8) bool {
        const trimmed = std.mem.trim(u8, value, &std.ascii.whitespace);
        return std.mem.eql(u8, trimmed, "about:blank");
    }

    fn runBrowserStartupEvalIfRequested(self: *AppState) void {
        if (!self.browser_start_eval_pending) return;
        self.browser_start_eval_pending = false;
        const raw_script = std.c.getenv("VERDE_BROWSER_START_EVAL") orelse return;
        const script = std.mem.sliceTo(raw_script, 0);
        if (script.len == 0) return;
        self.browser_state.controller.eval(script) catch |err| {
            log.warn("failed to run browser startup eval: {s}", .{@errorName(err)});
            self.browser_state.setLastError("Failed to run browser startup eval.") catch {};
            self.setSidebarNotice("Browser startup eval failed.");
        };
    }

    fn inspectorModeStoredNotice(mode: browser_runtime.InspectorMode) []const u8 {
        return switch (mode) {
            .point => "Browser inspector mode set to Point.",
            .draw_box => "Browser inspector mode set to Draw Box.",
            .draw_freeform => "Browser inspector mode set to Draw Freeform.",
        };
    }

    fn inspectorModeSwitchedNotice(mode: browser_runtime.InspectorMode) []const u8 {
        return switch (mode) {
            .point => "Browser inspector switched to Point mode.",
            .draw_box => "Browser inspector switched to Draw Box mode.",
            .draw_freeform => "Browser inspector switched to Draw Freeform mode.",
        };
    }

    fn isBrowserClipboardMessage(message: []const u8) bool {
        return std.mem.indexOf(u8, message, "\"source\":\"verde-browser-clipboard\"") != null;
    }

    fn handleBrowserClipboardMessage(self: *AppState, message: []const u8) void {
        var parsed = std.json.parseFromSlice(BrowserClipboardEvent, self.allocator, message, .{
            .allocate = .alloc_always,
            .ignore_unknown_fields = true,
        }) catch |err| {
            log.warn("failed to parse browser clipboard message: {s}", .{@errorName(err)});
            self.setSidebarNotice("Browser clipboard message could not be parsed.");
            return;
        };
        defer parsed.deinit();

        if (!std.mem.eql(u8, parsed.value.source, "verde-browser-clipboard")) {
            return;
        }
        self.copyBrowserEvalResultToClipboard(parsed.value.text);
    }

    fn handleInspectorPromptSubmitted(self: *AppState, message: []const u8) void {
        if (self.projects.items.len == 0) {
            self.setSidebarNotice("No active chat is available for the browser inspector prompt.");
            return;
        }

        var parsed = std.json.parseFromSlice(InspectorPromptSubmittedEvent, self.allocator, message, .{
            .allocate = .alloc_always,
            .ignore_unknown_fields = true,
        }) catch |err| {
            log.warn("failed to parse inspector prompt submission: {s}", .{@errorName(err)});
            self.setSidebarNotice("Browser inspector prompt could not be parsed.");
            return;
        };
        defer parsed.deinit();

        const prompt = std.mem.trim(u8, parsed.value.payload.prompt, &std.ascii.whitespace);
        if (prompt.len == 0) {
            self.setSidebarNotice("Browser inspector prompt was empty.");
            return;
        }

        const draft_block = buildInspectorDraftBlock(self.allocator, parsed.value.payload.selection, prompt) catch |err| {
            log.warn("failed to build inspector draft block: {s}", .{@errorName(err)});
            self.setSidebarNotice("Browser inspector prompt could not be prepared.");
            return;
        };
        defer self.allocator.free(draft_block);

        const current_draft = self.currentDraft();
        const next_draft = if (current_draft.len == 0)
            self.allocator.dupe(u8, draft_block)
        else
            std.fmt.allocPrint(self.allocator, "{s}\n\n{s}", .{ current_draft, draft_block });
        const resolved_next_draft = next_draft catch |err| {
            log.warn("failed to append inspector prompt to draft: {s}", .{@errorName(err)});
            self.setSidebarNotice("Browser inspector prompt could not be added to the draft.");
            return;
        };
        defer self.allocator.free(resolved_next_draft);

        self.setDraft(resolved_next_draft);
        self.requestComposerFocus();
        self.setSidebarNotice("Browser inspector prompt added to the current chat draft.");
    }

    fn buildInspectorDraftBlock(
        allocator: std.mem.Allocator,
        selection: InspectorSelectionPayload,
        prompt: []const u8,
    ) ![]u8 {
        var buffer = std.ArrayList(u8).empty;
        defer buffer.deinit(allocator);

        const header = try std.fmt.allocPrint(
            allocator,
            "Browser inspector selection\nMode: {s}\n",
            .{selection.mode},
        );
        defer allocator.free(header);
        try buffer.appendSlice(allocator, header);

        if (selection.rect) |rect| {
            const region = try std.fmt.allocPrint(
                allocator,
                "Region: {d:.0} x {d:.0} at ({d:.0}, {d:.0})\n",
                .{ rect.width, rect.height, rect.x, rect.y },
            );
            defer allocator.free(region);
            try buffer.appendSlice(allocator, region);
        }

        if (selection.element) |element| {
            try appendInspectorElementSummary(&buffer, allocator, element, null);
        } else if (selection.elements) |elements| {
            const count = @min(elements.len, 6);
            const selected_label = try std.fmt.allocPrint(
                allocator,
                "Selected elements ({d} shown):\n",
                .{count},
            );
            defer allocator.free(selected_label);
            try buffer.appendSlice(allocator, selected_label);
            for (elements[0..count], 0..) |element, index| {
                try appendInspectorElementSummary(&buffer, allocator, element, index + 1);
            }
            if (elements.len > count) {
                const more_label = try std.fmt.allocPrint(
                    allocator,
                    "... and {d} more element{s}\n",
                    .{ elements.len - count, if (elements.len - count == 1) "" else "s" },
                );
                defer allocator.free(more_label);
                try buffer.appendSlice(allocator, more_label);
            }
        }

        const prompt_label = try std.fmt.allocPrint(
            allocator,
            "Requested change:\n{s}",
            .{prompt},
        );
        defer allocator.free(prompt_label);
        try buffer.appendSlice(allocator, prompt_label);

        return buffer.toOwnedSlice(allocator);
    }

    fn appendInspectorElementSummary(
        buffer: *std.ArrayList(u8),
        allocator: std.mem.Allocator,
        element: InspectorElementPayload,
        index: ?usize,
    ) !void {
        const prefix = if (index) |value|
            try std.fmt.allocPrint(allocator, "{d}. ", .{value})
        else
            try allocator.dupe(u8, "Element: ");
        defer allocator.free(prefix);

        try buffer.appendSlice(allocator, prefix);
        try buffer.appendSlice(allocator, element.selector orelse "(unknown selector)");
        if (element.tagName) |tag_name| {
            const label = try std.fmt.allocPrint(allocator, " [{s}]", .{tag_name});
            defer allocator.free(label);
            try buffer.appendSlice(allocator, label);
        }
        try buffer.append(allocator, '\n');

        if (element.textSnippet) |text_snippet| {
            const trimmed = std.mem.trim(u8, text_snippet, &std.ascii.whitespace);
            if (trimmed.len > 0) {
                const label = try std.fmt.allocPrint(allocator, "   text: {s}\n", .{trimmed});
                defer allocator.free(label);
                try buffer.appendSlice(allocator, label);
            }
        }
        if (element.ariaLabel) |aria_label| {
            const trimmed = std.mem.trim(u8, aria_label, &std.ascii.whitespace);
            if (trimmed.len > 0) {
                const label = try std.fmt.allocPrint(allocator, "   aria-label: {s}\n", .{trimmed});
                defer allocator.free(label);
                try buffer.appendSlice(allocator, label);
            }
        }
        if (element.href) |href| {
            const trimmed = std.mem.trim(u8, href, &std.ascii.whitespace);
            if (trimmed.len > 0) {
                const label = try std.fmt.allocPrint(allocator, "   href: {s}\n", .{trimmed});
                defer allocator.free(label);
                try buffer.appendSlice(allocator, label);
            }
        }
    }

    // Enables the bundled inspector and dispatches one internal eval into the current browser document.
    pub fn enableBrowserInspector(self: *AppState, show_notice: bool) void {
        self.applyBrowserInspector(show_notice, "Browser inspector enabled.");
    }

    // Enables or reapplies the bundled inspector using the currently selected mode.
    fn applyBrowserInspector(self: *AppState, show_notice: bool, success_notice: []const u8) void {
        if (!self.isBrowserVisible()) {
            self.setSidebarNotice("Open the browser before enabling the inspector.");
            return;
        }
        if (!self.canUseBrowserInspector()) {
            self.setSidebarNotice("The browser inspector is not available for this browser backend.");
            return;
        }
        if (!self.browserInspectorPolicyAllowsCurrentPage()) {
            self.setSidebarNotice("Browser inspector is only available for app, localhost, and web pages.");
            return;
        }

        const script = browser_inspector.enableScriptAlloc(self.allocator, self.browser_state.inspectorMode()) catch |err| {
            log.err("failed to build browser inspector script: {s}", .{@errorName(err)});
            if (show_notice) self.setSidebarNotice("Failed to build the browser inspector.");
            return;
        };
        defer self.allocator.free(script);

        self.browser_state.setInspectorEnabled(true);
        self.browser_state.expectSuppressedEvalResult();
        self.browser_state.controller.eval(script) catch |err| {
            _ = self.browser_state.consumeSuppressedEvalResult();
            self.browser_state.setInspectorEnabled(false);
            log.err("failed to enable browser inspector: {s}", .{@errorName(err)});
            if (show_notice) self.setSidebarNotice("Failed to enable the browser inspector.");
            return;
        };
        if (show_notice) self.setSidebarNotice(success_notice);
    }

    // Disables the bundled inspector overlay while leaving the page alive.
    pub fn disableBrowserInspector(self: *AppState, show_notice: bool) void {
        self.browser_state.setInspectorEnabled(false);
        if (!self.isBrowserVisible() or !self.canUseBrowserInspector()) {
            if (show_notice) self.setSidebarNotice("Browser inspector disabled.");
            return;
        }

        self.browser_state.expectSuppressedEvalResult();
        self.browser_state.controller.eval(browser_inspector.disable_script) catch |err| {
            _ = self.browser_state.consumeSuppressedEvalResult();
            log.err("failed to disable browser inspector: {s}", .{@errorName(err)});
            if (show_notice) self.setSidebarNotice("Failed to disable the browser inspector.");
            return;
        };
        if (show_notice) self.setSidebarNotice("Browser inspector disabled.");
    }

    // Reapplies the inspector after the next main-frame load when the user has it armed.
    fn reapplyBrowserInspectorAfterLoad(self: *AppState) void {
        if (!self.browser_state.inspectorEnabled()) return;
        if (!self.canUseBrowserInspector()) return;
        self.applyBrowserInspector(false, "");
    }

    fn isInspectorBridgeMessage(message: []const u8) bool {
        return std.mem.indexOf(u8, message, "\"source\":\"verde-inspector\"") != null;
    }

    fn isInspectorHoverMessage(message: []const u8) bool {
        return std.mem.indexOf(u8, message, "\"type\":\"element:hover\"") != null;
    }

    fn isInspectorLifecycleMessage(message: []const u8) bool {
        return std.mem.indexOf(u8, message, "\"type\":\"inspector:enabled\"") != null or
            std.mem.indexOf(u8, message, "\"type\":\"inspector:disabled\"") != null or
            std.mem.indexOf(u8, message, "\"type\":\"inspector:mode-changed\"") != null;
    }

    fn isInspectorSelectionMessage(message: []const u8) bool {
        return std.mem.indexOf(u8, message, "\"type\":\"element:selected\"") != null or
            std.mem.indexOf(u8, message, "\"type\":\"region:selected\"") != null;
    }

    fn isInspectorPromptSubmittedMessage(message: []const u8) bool {
        return std.mem.indexOf(u8, message, "\"type\":\"prompt:submitted\"") != null;
    }

    fn isInspectorPromptChangedMessage(message: []const u8) bool {
        return std.mem.indexOf(u8, message, "\"type\":\"prompt:changed\"") != null;
    }

    pub fn hasVisibleTerminalSessions(self: *const AppState) bool {
        for (self.projects.items) |*project| {
            if ((project.terminal_dock.visible or project.workspace_layout.hasVisiblePaneKind(.terminal)) and project.terminal_dock.hasRunningSession()) return true;
            if (project.workspace_layout.hasVisiblePaneKind(.terminal)) {
                for (project.terminal_docks.items) |*entry| {
                    if (entry.dock.hasRunningSession()) return true;
                }
            }
        }
        return false;
    }

    pub fn handleTerminalKeyDown(
        self: *AppState,
        keyboard: *const keybinds.NativeKeyboardConfig,
        event: *const sdl.KeyboardEvent,
    ) bool {
        if (!self.canRouteTerminalInput()) return false;
        const dock_id = self.terminalInputDockId() orelse return false;
        if (keyboard.terminalActionForEvent(event)) |action| {
            switch (action) {
                .new_tab => return self.createCurrentProjectTerminalTab(dock_id, .{}),
                .split_up => return self.splitFocusedWorkspacePaneWithTerminalPlacement(.horizontal, false),
                .split_down => return self.splitFocusedWorkspacePaneWithTerminalPlacement(.horizontal, true),
                .split_left => return self.splitFocusedWorkspacePaneWithTerminalPlacement(.vertical, false),
                .split_right => return self.splitFocusedWorkspacePaneWithTerminalPlacement(.vertical, true),
                else => {},
            }
        }
        var dock = self.currentProjectTerminalDockMutable(dock_id) orelse return false;
        const handled = dock.handleKeyDown(self.allocator, keyboard, event);
        if (dock.consumeWorkspaceChange()) self.markDirty();
        if (handled) self.noteTerminalInputActivity();
        return handled;
    }

    pub fn handleTerminalTextInput(self: *AppState, text: [*c]const u8) bool {
        if (!self.canRouteTerminalInput()) return false;
        const dock_id = self.terminalInputDockId() orelse return false;
        var dock = self.currentProjectTerminalDockMutable(dock_id) orelse return false;
        const handled = dock.handleTextInput(std.mem.sliceTo(text, 0));
        if (handled) self.noteTerminalInputActivity();
        return handled;
    }

    fn canRouteTerminalInput(self: *const AppState) bool {
        if (!self.terminal_focused or !self.isTerminalVisible()) return false;
        if (self.shouldRenderLegacyTerminalDockInChat()) return true;
        return self.focusedWorkspacePaneKind() == .terminal;
    }

    fn terminalInputDockId(self: *const AppState) ?u32 {
        if (self.shouldRenderLegacyTerminalDockInChat()) return 0;
        return self.focusedWorkspaceTerminalDockId();
    }

    pub fn ensureCurrentProjectWorkspace(self: *AppState) void {
        if (self.projects.items.len == 0) return;
        const changed = self.projects.items[self.selected_project_index].workspace_layout.ensureDefaultChat(self.allocator) catch |err| {
            log.err("failed to initialize workspace panes: {s}", .{@errorName(err)});
            return;
        };
        if (changed) self.markDirty();
    }

    pub fn focusedWorkspacePaneKind(self: *const AppState) ?WorkspacePaneKind {
        if (self.projects.items.len == 0) return null;
        const layout = &self.projects.items[self.selected_project_index].workspace_layout;
        const pane = layout.focusedPane() orelse return null;
        return switch (pane.ref) {
            .chat => .chat,
            .terminal => .terminal,
            .browser => .browser,
        };
    }

    pub fn focusedWorkspaceChatPaneId(self: *const AppState) ?WorkspacePaneId {
        if (self.projects.items.len == 0) return null;
        const layout = &self.projects.items[self.selected_project_index].workspace_layout;
        const pane_id = layout.focused_pane_id orelse return null;
        return if (self.workspaceChatThreadIndexByPane(pane_id) != null) pane_id else null;
    }

    pub fn currentProjectHasVisibleWorkspaceTerminalPane(self: *const AppState) bool {
        if (self.projects.items.len == 0) return false;
        return self.projects.items[self.selected_project_index].workspace_layout.hasVisiblePaneKind(.terminal);
    }

    pub fn currentProjectVisibleBrowserPaneId(self: *const AppState) ?WorkspacePaneId {
        if (self.projects.items.len == 0) return null;
        return self.projects.items[self.selected_project_index].workspace_layout.visibleBrowserPaneId();
    }

    pub fn threadIsOpenInTui(self: *const AppState, project_index: usize, thread_index: usize) bool {
        if (project_index >= self.projects.items.len) return false;
        const project = &self.projects.items[project_index];
        if (thread_index >= project.threads.items.len) return false;
        const dock_id = project.threads.items[thread_index].tui_dock_id orelse return false;
        return project.workspace_layout.visibleTerminalPaneIdForDock(dock_id) != null;
    }

    pub fn currentProjectWorkspaceRoot(self: *const AppState) ?*const WorkspaceNode {
        if (self.projects.items.len == 0) return null;
        const layout = &self.projects.items[self.selected_project_index].workspace_layout;
        if (layout.maximized_pane_id) |pane_id| {
            if (layout.paneById(pane_id)) |pane| {
                if (!pane.minimized) return layout.root;
            }
        }
        return layout.root;
    }

    pub fn currentProjectWorkspaceMaximizedPaneId(self: *const AppState) ?WorkspacePaneId {
        if (self.projects.items.len == 0) return null;
        const layout = &self.projects.items[self.selected_project_index].workspace_layout;
        const pane_id = layout.maximized_pane_id orelse return null;
        const pane = layout.paneById(pane_id) orelse return null;
        if (pane.minimized) return null;
        return pane_id;
    }

    pub fn workspacePaneKindById(self: *const AppState, pane_id: WorkspacePaneId) ?WorkspacePaneKind {
        if (self.projects.items.len == 0) return null;
        const layout = &self.projects.items[self.selected_project_index].workspace_layout;
        const pane = layout.paneById(pane_id) orelse return null;
        if (pane.minimized) return null;
        return switch (pane.ref) {
            .chat => .chat,
            .terminal => .terminal,
            .browser => .browser,
        };
    }

    pub fn workspaceTerminalDockIdByPane(self: *const AppState, pane_id: WorkspacePaneId) ?u32 {
        if (self.projects.items.len == 0) return null;
        const layout = &self.projects.items[self.selected_project_index].workspace_layout;
        const pane = layout.paneById(pane_id) orelse return null;
        if (pane.minimized) return null;
        return switch (pane.ref) {
            .terminal => |ref| ref.dock_id,
            else => null,
        };
    }

    pub fn workspaceChatThreadIndexByPane(self: *const AppState, pane_id: WorkspacePaneId) ?usize {
        if (self.projects.items.len == 0) return null;
        const project = &self.projects.items[self.selected_project_index];
        const pane = project.workspace_layout.paneById(pane_id) orelse return null;
        if (pane.minimized) return null;
        return switch (pane.ref) {
            .chat => |ref| if (ref.thread_index < project.threads.items.len) ref.thread_index else null,
            else => null,
        };
    }

    fn captureViewFocusSnapshot(self: *const AppState) ViewFocusSnapshot {
        return .{
            .selected_project_index = self.selected_project_index,
            .terminal_focused = self.terminal_focused,
            .composer_focused = self.composer_focused,
            .palette_composer_focused = self.palette_composer.focused,
            .browser_address_focused = self.browser_address_focused,
        };
    }

    fn restoreViewFocusSnapshot(self: *AppState, snapshot: ViewFocusSnapshot) void {
        if (snapshot.selected_project_index < self.projects.items.len) {
            self.selected_project_index = snapshot.selected_project_index;
        } else if (self.projects.items.len > 0) {
            self.selected_project_index = self.projects.items.len - 1;
        } else {
            self.selected_project_index = 0;
        }
        self.terminal_focused = snapshot.terminal_focused;
        self.composer_focused = snapshot.composer_focused;
        self.palette_composer.focused = snapshot.palette_composer_focused;
        self.browser_address_focused = snapshot.browser_address_focused;
        self.syncRenameBuffer();
        self.syncPaletteComposerFromDraft();
    }

    pub fn setWorkspaceChatPaneDraftForProject(self: *AppState, project_index: usize, pane_id: WorkspacePaneId, value: []const u8, append: bool) !bool {
        if (project_index >= self.projects.items.len) return false;
        var project = &self.projects.items[project_index];
        const pane = project.workspace_layout.paneById(pane_id) orelse return false;
        const thread_index = switch (pane.ref) {
            .chat => |ref| ref.thread_index,
            else => return false,
        };
        if (thread_index >= project.threads.items.len) return false;
        var thread = &project.threads.items[thread_index];
        if (append) {
            const current = thread.currentDraft();
            var next: std.ArrayList(u8) = .empty;
            defer next.deinit(self.allocator);
            try next.ensureTotalCapacity(self.allocator, current.len + value.len);
            try next.appendSlice(self.allocator, current);
            try next.appendSlice(self.allocator, value);
            thread.setDraft(next.items);
        } else {
            thread.setDraft(value);
        }
        project.selected_thread_index = thread_index;
        if (self.selected_project_index == project_index) {
            self.terminal_focused = false;
            self.syncPaletteComposerFromDraft();
        }
        self.markDirty();
        return true;
    }

    pub fn setWorkspaceChatPaneDraft(self: *AppState, pane_id: WorkspacePaneId, value: []const u8, append: bool) !bool {
        if (self.projects.items.len == 0) return false;
        return self.setWorkspaceChatPaneDraftForProject(self.selected_project_index, pane_id, value, append);
    }

    pub fn sendWorkspaceChatPanePromptForProject(self: *AppState, project_index: usize, pane_id: WorkspacePaneId, prompt: ?[]const u8) !bool {
        if (project_index >= self.projects.items.len) return false;
        const snapshot = self.captureViewFocusSnapshot();
        const restore_view = project_index != snapshot.selected_project_index;
        if (restore_view) self.selected_project_index = project_index;
        defer if (restore_view) self.restoreViewFocusSnapshot(snapshot);

        if (prompt) |text| {
            if (!try self.setWorkspaceChatPaneDraft(pane_id, text, false)) return false;
        } else if (!self.selectWorkspaceChatPaneThread(pane_id)) return false;

        try self.sendDraft();
        return true;
    }

    pub fn sendWorkspaceChatPanePrompt(self: *AppState, pane_id: WorkspacePaneId, prompt: ?[]const u8) !bool {
        if (self.projects.items.len == 0) return false;
        return self.sendWorkspaceChatPanePromptForProject(self.selected_project_index, pane_id, prompt);
    }

    pub fn followupWorkspaceChatPanePromptForProject(self: *AppState, project_index: usize, pane_id: WorkspacePaneId, prompt: []const u8) !bool {
        if (project_index >= self.projects.items.len) return false;
        const snapshot = self.captureViewFocusSnapshot();
        const restore_view = project_index != snapshot.selected_project_index;
        if (restore_view) self.selected_project_index = project_index;
        defer if (restore_view) self.restoreViewFocusSnapshot(snapshot);

        if (!try self.setWorkspaceChatPaneDraft(pane_id, prompt, false)) return false;
        self.queueOrSteerDraftDuringSend();
        return true;
    }

    pub fn followupWorkspaceChatPanePrompt(self: *AppState, pane_id: WorkspacePaneId, prompt: []const u8) !bool {
        if (self.projects.items.len == 0) return false;
        return self.followupWorkspaceChatPanePromptForProject(self.selected_project_index, pane_id, prompt);
    }

    pub fn stopWorkspaceChatPaneForProject(self: *AppState, project_index: usize, pane_id: WorkspacePaneId) bool {
        if (project_index >= self.projects.items.len) return false;
        const snapshot = self.captureViewFocusSnapshot();
        const restore_view = project_index != snapshot.selected_project_index;
        if (restore_view) self.selected_project_index = project_index;
        defer if (restore_view) self.restoreViewFocusSnapshot(snapshot);

        if (!self.selectWorkspaceChatPaneThread(pane_id)) return false;
        self.abortCurrentThreadSend();
        return true;
    }

    pub fn stopWorkspaceChatPane(self: *AppState, pane_id: WorkspacePaneId) bool {
        if (self.projects.items.len == 0) return false;
        return self.stopWorkspaceChatPaneForProject(self.selected_project_index, pane_id);
    }

    pub fn approveWorkspaceChatPaneForProject(self: *AppState, project_index: usize, pane_id: WorkspacePaneId, decision: ai_harness.ApprovalDecision) bool {
        if (project_index >= self.projects.items.len) return false;
        const snapshot = self.captureViewFocusSnapshot();
        const restore_view = project_index != snapshot.selected_project_index;
        if (restore_view) self.selected_project_index = project_index;
        defer if (restore_view) self.restoreViewFocusSnapshot(snapshot);

        if (!self.selectWorkspaceChatPaneThread(pane_id)) return false;
        self.resolvePendingApproval(decision);
        return true;
    }

    pub fn approveWorkspaceChatPane(self: *AppState, pane_id: WorkspacePaneId, decision: ai_harness.ApprovalDecision) bool {
        if (self.projects.items.len == 0) return false;
        return self.approveWorkspaceChatPaneForProject(self.selected_project_index, pane_id, decision);
    }

    pub fn writeWorkspaceTerminalPaneForProject(self: *AppState, project_index: usize, pane_id: WorkspacePaneId, bytes: []const u8) !bool {
        if (project_index >= self.projects.items.len) return false;
        var project = &self.projects.items[project_index];
        const pane = project.workspace_layout.paneById(pane_id) orelse return false;
        const dock_id = switch (pane.ref) {
            .terminal => |ref| ref.dock_id,
            else => return false,
        };
        const workspace_pane_visible = project.workspace_layout.hasTerminalDockPane(dock_id);
        var dock = self.projectTerminalDockMutable(project_index, dock_id) orelse return false;
        if (!dock.hasRunningSession()) try self.restartTerminalDockForWorkspace(project_index, dock_id);
        const wrote = try dock.writeInputToActivePane(bytes);
        if (wrote and project_index == self.selected_project_index and
            (dock.visible or workspace_pane_visible))
        {
            self.noteTerminalInputActivity();
        }
        return wrote;
    }

    pub fn writeWorkspaceTerminalPane(self: *AppState, pane_id: WorkspacePaneId, bytes: []const u8) !bool {
        if (self.projects.items.len == 0) return false;
        return self.writeWorkspaceTerminalPaneForProject(self.selected_project_index, pane_id, bytes);
    }

    pub fn terminalPaneOutputTailForProject(self: *AppState, project_index: usize, pane_id: WorkspacePaneId, max_bytes: usize) !?[]u8 {
        if (project_index >= self.projects.items.len) return null;
        var project = &self.projects.items[project_index];
        const pane = project.workspace_layout.paneById(pane_id) orelse return null;
        const dock_id = switch (pane.ref) {
            .terminal => |ref| ref.dock_id,
            else => return null,
        };
        var dock = self.projectTerminalDockMutable(project_index, dock_id) orelse return null;
        try self.pollTerminalDockBeforeRead(project_index, dock_id, dock);
        return try dock.activeOutputTailAlloc(self.allocator, max_bytes);
    }

    pub fn terminalPaneOutputTail(self: *AppState, pane_id: WorkspacePaneId, max_bytes: usize) !?[]u8 {
        if (self.projects.items.len == 0) return null;
        return self.terminalPaneOutputTailForProject(self.selected_project_index, pane_id, max_bytes);
    }

    pub fn terminalPaneScreenTextForProject(self: *AppState, project_index: usize, pane_id: WorkspacePaneId) !?[]u8 {
        if (project_index >= self.projects.items.len) return null;
        var project = &self.projects.items[project_index];
        const pane = project.workspace_layout.paneById(pane_id) orelse return null;
        const dock_id = switch (pane.ref) {
            .terminal => |ref| ref.dock_id,
            else => return null,
        };
        var dock = self.projectTerminalDockMutable(project_index, dock_id) orelse return null;
        try self.pollTerminalDockBeforeRead(project_index, dock_id, dock);
        return try dock.activeScreenTextAlloc(self.allocator);
    }

    fn pollTerminalDockBeforeRead(self: *AppState, project_index: usize, dock_id: u32, dock: *terminal.Dock) !void {
        const changed = try dock.poll(self.allocator);
        try self.drainTerminalDockNotifications(project_index, dock_id, dock);
        if (changed and project_index == self.selected_project_index) {
            const project = &self.projects.items[project_index];
            if (dock.visible or project.workspace_layout.hasTerminalDockPane(dock_id)) {
                self.last_terminal_activity_ms = monotonicMs();
                self.markDirty();
            }
        }
    }

    pub fn terminalPaneScreenText(self: *AppState, pane_id: WorkspacePaneId) !?[]u8 {
        if (self.projects.items.len == 0) return null;
        return self.terminalPaneScreenTextForProject(self.selected_project_index, pane_id);
    }

    pub fn refreshProjectStackConfig(self: *AppState, project_index: usize) !void {
        if (project_index >= self.projects.items.len) return;
        var project = &self.projects.items[project_index];
        project.last_stack_config_refresh_ms = unixTimestampMs();
        const maybe_loaded = stack_config.loadFromProject(self.allocator, project.path) catch |err| {
            project.setStackConfigError(self.allocator, @errorName(err));
            return err;
        };
        if (maybe_loaded == null) {
            project.clearStackConfigError(self.allocator);
            project.clearManagedProcesses(self.allocator);
            return;
        }
        var loaded = maybe_loaded.?;
        defer loaded.deinit(self.allocator);
        project.clearStackConfigError(self.allocator);

        var process_index: usize = 0;
        while (process_index < project.managed_processes.items.len) {
            if (stackDefinitionByName(&loaded, project.managed_processes.items[process_index].name) != null) {
                process_index += 1;
                continue;
            }
            var removed = project.managed_processes.orderedRemove(process_index);
            project.terminateManagedProcessSession(&removed);
            removed.deinit(self.allocator);
        }

        for (loaded.processes.items) |definition| {
            if (definition.launchForOs(builtin.os.tag) == null) continue;
            if (project.managedProcessByName(definition.name)) |process| {
                try process.updateFromDefinition(self.allocator, definition);
            } else {
                try project.managed_processes.append(self.allocator, try ManagedProcess.initFromDefinition(self.allocator, definition));
            }
        }
        self.refreshManagedProcessStatuses(project_index);
    }

    fn stackDefinitionByName(config: *const stack_config.Config, name: []const u8) ?*const stack_config.ProcessDefinition {
        for (config.processes.items) |*definition| {
            if (std.mem.eql(u8, definition.name, name) and definition.launchForOs(builtin.os.tag) != null) return definition;
        }
        return null;
    }

    pub fn refreshManagedProcessStatuses(self: *AppState, project_index: usize) void {
        if (project_index >= self.projects.items.len) return;
        const project = &self.projects.items[project_index];
        for (project.managed_processes.items) |*process| {
            const dock_id = process.dock_id orelse continue;
            const dock = self.projectTerminalDock(project_index, dock_id) orelse continue;
            const snapshot = dock.activeSessionSnapshot() orelse continue;
            if (snapshot.running) {
                process.status = .running;
                process.exit_code = null;
                process.signal = null;
                continue;
            }
            if (process.status == .stopped and process.explicit_stop) continue;
            process.exit_code = snapshot.exit_code;
            process.signal = snapshot.signal;
            if (process.last_exit_ms == 0) process.last_exit_ms = unixTimestampMs();
            const clean_exit = snapshot.exit_code != null and snapshot.exit_code.? == 0;
            process.status = if (clean_exit or process.explicit_stop) .stopped else .crashed;
        }
    }

    pub fn pollManagedProcesses(self: *AppState, project_index: usize) void {
        if (project_index >= self.projects.items.len) return;
        const now = unixTimestampMs();
        if (now - self.projects.items[project_index].last_stack_config_refresh_ms >= STACK_CONFIG_REFRESH_MS) {
            self.refreshProjectStackConfig(project_index) catch |err| {
                log.warn("failed to refresh verde stack config: {s}", .{@errorName(err)});
            };
        } else {
            self.refreshManagedProcessStatuses(project_index);
        }

        var restart_names: std.ArrayList([]u8) = .empty;
        defer {
            for (restart_names.items) |name| self.allocator.free(name);
            restart_names.deinit(self.allocator);
        }

        for (self.projects.items[project_index].managed_processes.items) |*process| {
            if (process.explicit_stop) continue;
            if (process.watch.items.len > 0 and process.status == .running) {
                self.pollManagedProcessWatch(project_index, process, now);
            }
            if (process.pending_watch_restart_ms != 0 and now >= process.pending_watch_restart_ms) {
                restart_names.append(self.allocator, self.allocator.dupe(u8, process.name) catch continue) catch continue;
                process.pending_watch_restart_ms = 0;
                process.status = .restarting;
                continue;
            }
            const should_restart_crash = process.status == .crashed and process.restart == .on_crash;
            const should_restart_always = process.status != .running and process.restart == .always and process.last_start_ms != 0;
            if (!should_restart_crash and !should_restart_always) continue;
            if (process.next_restart_ms == 0) {
                process.next_restart_ms = now + managedProcessRestartBackoffMs(process.restart_count);
                process.status = .restarting;
            }
            if (now < process.next_restart_ms) continue;
            restart_names.append(self.allocator, self.allocator.dupe(u8, process.name) catch continue) catch continue;
        }

        for (restart_names.items) |name| {
            if (self.projects.items[project_index].managedProcessByName(name)) |process| {
                process.restart_count += 1;
                process.status = .restarting;
            }
            _ = self.startManagedProcess(project_index, name) catch |err| {
                log.warn("failed to auto-restart managed process {s}: {s}", .{ name, @errorName(err) });
                continue;
            };
        }
    }

    pub fn startManagedProcess(self: *AppState, project_index: usize, name: []const u8) !bool {
        try self.refreshProjectStackConfig(project_index);
        if (project_index >= self.projects.items.len) return false;
        self.selected_project_index = project_index;
        var project = &self.projects.items[project_index];
        const process = project.managedProcessByName(name) orelse return false;
        return try self.startManagedProcessDirect(project_index, process);
    }

    fn startManagedProcessDirect(self: *AppState, project_index: usize, process: *ManagedProcess) !bool {
        if (project_index >= self.projects.items.len) return false;
        self.selected_project_index = project_index;
        var project = &self.projects.items[project_index];
        const dock_id = process.dock_id orelse try self.createProjectTerminalDock(project_index);
        process.dock_id = dock_id;

        const cwd = try self.resolveManagedProcessCwd(project.path, process.cwd);
        defer self.allocator.free(cwd);
        try self.ensureManagedAgentProjectHooks(project.path, process);
        var launch = try self.managedProcessLaunchArgs(process);
        defer launch.deinit(self.allocator);
        try self.restartTerminalDockForWorkspaceProfile(project_index, dock_id, cwd, .{
            .kind = .custom,
            .label = process.name,
            .command = launch.argv.items,
        });
        var dock = self.projectTerminalDockMutable(project_index, dock_id) orelse return false;
        process.status = .running;
        process.exit_code = null;
        process.signal = null;
        process.last_start_ms = unixTimestampMs();
        process.last_exit_ms = 0;
        process.next_restart_ms = 0;
        process.pending_watch_restart_ms = 0;
        process.explicit_stop = false;
        process.pane_id = try project.workspace_layout.ensureTerminalPane(self.allocator, dock_id);
        if (process.kind == .agent and process.notify) {
            if (dock.activeSessionId()) |session_id| {
                _ = try self.updateSurface(.{
                    .session_id = session_id,
                    .workspace_id = project.id,
                    .workspace_path = project.path,
                    .dock_id = dock_id,
                    .pane_id = process.pane_id,
                    .provider = providerFromStack(process.provider),
                    .title = process.name,
                    .status = .working,
                    .attention = false,
                    .last_event_title = process.name,
                    .last_event_body = "Agent started.",
                });
            }
        }
        project.workspace_layout.maximized_pane_id = null;
        self.requestTerminalDockFocus(dock_id);
        self.markDirty();
        return true;
    }

    fn startManagedProcessInNewPane(
        self: *AppState,
        project_index: usize,
        process: *ManagedProcess,
        requested_pane_id: ?WorkspacePaneId,
        axis: WorkspaceSplitAxis,
        new_after: bool,
    ) !bool {
        if (project_index >= self.projects.items.len) return false;
        self.selected_project_index = project_index;
        self.ensureCurrentProjectWorkspace();

        var project = &self.projects.items[project_index];
        var layout = &project.workspace_layout;
        const target_pane_id = requested_pane_id orelse layout.focused_pane_id orelse layout.firstVisiblePaneId() orelse {
            self.setSidebarNotice("No workspace pane selected.");
            return false;
        };
        const target = layout.paneById(target_pane_id) orelse return false;
        if (target.minimized) return false;
        const provider_label = agentTuiProviderLabel(process.provider);

        const cwd = try self.resolveManagedProcessCwd(project.path, process.cwd);
        defer self.allocator.free(cwd);
        try self.ensureManagedAgentProjectHooks(project.path, process);

        const dock_id = self.createProjectTerminalDock(project_index) catch |err| {
            log.err("failed to allocate agent terminal dock: {s}", .{@errorName(err)});
            var notice_buf: [96]u8 = undefined;
            self.setSidebarNotice(std.fmt.bufPrint(&notice_buf, "Failed to create {s} TUI terminal.", .{provider_label}) catch "Failed to create TUI terminal.");
            return false;
        };
        project = &self.projects.items[project_index];
        var launch = try self.managedProcessLaunchArgs(process);
        defer launch.deinit(self.allocator);
        try self.restartTerminalDockForWorkspaceProfile(project_index, dock_id, cwd, .{
            .kind = .custom,
            .label = process.name,
            .command = launch.argv.items,
        });
        var dock = self.projectTerminalDockMutable(project_index, dock_id) orelse return false;

        layout = &project.workspace_layout;
        const new_pane_id = layout.createTerminalPane(self.allocator, dock_id) catch |err| {
            log.err("failed to create agent terminal workspace pane: {s}", .{@errorName(err)});
            var notice_buf: [96]u8 = undefined;
            self.setSidebarNotice(std.fmt.bufPrint(&notice_buf, "Failed to create {s} TUI pane.", .{provider_label}) catch "Failed to create TUI pane.");
            return false;
        };
        layout.splitPaneWithLeaf(self.allocator, target_pane_id, new_pane_id, axis, new_after) catch |err| {
            log.err("failed to split agent terminal workspace pane: {s}", .{@errorName(err)});
            self.setSidebarNotice("Failed to split workspace.");
            return false;
        };

        process.dock_id = dock_id;
        process.pane_id = new_pane_id;
        process.status = .running;
        process.exit_code = null;
        process.signal = null;
        process.last_start_ms = unixTimestampMs();
        process.last_exit_ms = 0;
        process.next_restart_ms = 0;
        process.pending_watch_restart_ms = 0;
        process.explicit_stop = false;
        if (process.kind == .agent and process.notify) {
            if (dock.activeSessionId()) |session_id| {
                _ = try self.updateSurface(.{
                    .session_id = session_id,
                    .workspace_id = project.id,
                    .workspace_path = project.path,
                    .dock_id = dock_id,
                    .pane_id = process.pane_id,
                    .provider = providerFromStack(process.provider),
                    .title = process.name,
                    .status = .working,
                    .attention = false,
                    .last_event_title = process.name,
                    .last_event_body = "Agent started.",
                });
            }
        }
        layout.maximized_pane_id = null;
        dock.visible = false;
        self.requestTerminalDockFocus(dock_id);
        var notice_buf: [96]u8 = undefined;
        self.setSidebarNotice(std.fmt.bufPrint(&notice_buf, "Started {s} TUI.", .{provider_label}) catch "Started TUI.");
        self.markDirty();
        return true;
    }

    fn ensureManagedAgentProjectHooks(self: *AppState, project_path: []const u8, process: *const ManagedProcess) !void {
        if (!(process.kind == .agent and process.hooks)) return;
        switch (process.provider orelse return) {
            .codex => try provider_hooks.ensureCodexProjectHooks(self.allocator, project_path),
            .claude => try provider_hooks.ensureClaudeProjectHooks(self.allocator, project_path),
            .opencode, .cursor, .amp, .other => {},
        }
    }

    pub fn openAgentTui(self: *AppState, project_index: usize, provider: stack_config.AgentProvider) !bool {
        return self.openAgentTuiAtPlacement(project_index, provider, null, .horizontal, true);
    }

    pub fn openAgentTuiAtPlacement(
        self: *AppState,
        project_index: usize,
        provider: stack_config.AgentProvider,
        requested_pane_id: ?WorkspacePaneId,
        axis: WorkspaceSplitAxis,
        new_after: bool,
    ) !bool {
        if (provider == .amp) {
            return try self.openAmpTuiInShellPane(project_index, requested_pane_id, axis, new_after);
        }
        const defaults = defaultAgentTui(provider) orelse return false;
        if (project_index >= self.projects.items.len) return false;
        self.selected_project_index = project_index;
        var project = &self.projects.items[project_index];
        const name = defaults.name;
        if (project.managedProcessByName(name) == null) {
            var process: ManagedProcess = .{
                .name = try self.allocator.dupe(u8, name),
                .kind = .agent,
                .command = try self.allocator.dupe(u8, defaults.command),
                .argv = .empty,
                .cwd = try self.allocator.dupe(u8, "."),
                .restart = .manual,
                .provider = defaults.provider,
                .revive = .attach_or_create,
                .notify = defaults.notify,
                .mcp = defaults.mcp,
                .hooks = defaults.hooks,
                .watch = .empty,
            };
            errdefer process.deinit(self.allocator);
            try project.managed_processes.append(self.allocator, process);
        }
        const process = project.managedProcessByName(name) orelse return false;
        try self.syncDefaultAgentTuiProcess(process, defaults);
        return try self.startManagedProcessInNewPane(project_index, process, requested_pane_id, axis, new_after);
    }

    fn openAmpTuiInShellPane(
        self: *AppState,
        project_index: usize,
        requested_pane_id: ?WorkspacePaneId,
        axis: WorkspaceSplitAxis,
        new_after: bool,
    ) !bool {
        if (project_index >= self.projects.items.len) return false;
        self.selected_project_index = project_index;
        self.ensureCurrentProjectWorkspace();

        var project = &self.projects.items[project_index];
        var layout = &project.workspace_layout;
        const target_pane_id = requested_pane_id orelse layout.focused_pane_id orelse layout.firstVisiblePaneId() orelse {
            self.setSidebarNotice("No workspace pane selected.");
            return false;
        };
        const target = layout.paneById(target_pane_id) orelse return false;
        if (target.minimized) return false;

        const dock_id = self.createProjectTerminalDock(project_index) catch |err| {
            log.err("failed to allocate Amp terminal dock: {s}", .{@errorName(err)});
            self.setSidebarNotice("Failed to create Amp TUI terminal.");
            return false;
        };
        project = &self.projects.items[project_index];
        self.restartTerminalDockForWorkspace(project_index, dock_id) catch |err| {
            log.err("failed to start Amp terminal dock: {s}", .{@errorName(err)});
            self.setSidebarNotice("Failed to start Amp TUI terminal.");
            return false;
        };
        var dock = self.projectTerminalDockMutable(project_index, dock_id) orelse return false;

        layout = &project.workspace_layout;
        const new_pane_id = layout.createTerminalPane(self.allocator, dock_id) catch |err| {
            log.err("failed to create Amp terminal workspace pane: {s}", .{@errorName(err)});
            self.setSidebarNotice("Failed to create Amp TUI pane.");
            return false;
        };
        layout.splitPaneWithLeaf(self.allocator, target_pane_id, new_pane_id, axis, new_after) catch |err| {
            log.err("failed to split Amp terminal workspace pane: {s}", .{@errorName(err)});
            self.setSidebarNotice("Failed to split workspace.");
            return false;
        };
        layout.maximized_pane_id = null;
        dock.visible = false;
        self.requestTerminalDockFocus(dock_id);
        _ = self.writeWorkspaceTerminalPaneForProject(project_index, new_pane_id, "amp\r") catch |err| {
            log.warn("failed to write Amp TUI command: {s}", .{@errorName(err)});
            self.setSidebarNotice("Failed to launch Amp TUI.");
            return false;
        };
        self.setSidebarNotice("Started Amp TUI.");
        self.markDirty();
        return true;
    }

    fn syncDefaultAgentTuiProcess(self: *AppState, process: *ManagedProcess, defaults: DefaultAgentTui) !void {
        if (!(process.kind == .agent and process.provider == defaults.provider)) return;
        if (!isKnownDefaultAgentTuiCommand(defaults.provider, process.command)) return;

        if (!std.mem.eql(u8, process.command, defaults.command)) {
            const command = try self.allocator.dupe(u8, defaults.command);
            self.allocator.free(process.command);
            process.command = command;
        }
        process.restart = .manual;
        process.revive = .attach_or_create;
        process.notify = defaults.notify;
        process.mcp = defaults.mcp;
        process.hooks = defaults.hooks;
    }

    fn providerFromStack(provider: ?stack_config.AgentProvider) ?Provider {
        return switch (provider orelse return null) {
            .codex => .codex,
            .claude => .claude,
            .opencode => .opencode,
            .cursor => .cursor,
            .amp => null,
            .other => null,
        };
    }

    const ManagedProcessLaunch = struct {
        argv: std.ArrayList([]u8) = .empty,

        fn deinit(self: *ManagedProcessLaunch, allocator: std.mem.Allocator) void {
            for (self.argv.items) |arg| allocator.free(arg);
            self.argv.deinit(allocator);
        }
    };

    fn managedProcessLaunchArgs(self: *AppState, process: *const ManagedProcess) !ManagedProcessLaunch {
        var launch: ManagedProcessLaunch = .{};
        errdefer launch.deinit(self.allocator);

        if (process.argv.items.len > 0) {
            const add_codex_hooks = process.kind == .agent and
                process.provider == .codex and
                process.hooks and
                isCodexExecutable(process.argv.items[0]) and
                !argvContains(process.argv.items, "features.codex_hooks");
            for (process.argv.items, 0..) |arg, index| {
                try appendOwnedString(self.allocator, &launch.argv, arg);
                if (index == 0 and add_codex_hooks) {
                    try appendOwnedString(self.allocator, &launch.argv, "-c");
                    try appendOwnedString(self.allocator, &launch.argv, "features.codex_hooks=true");
                }
            }
            return launch;
        }

        if (builtin.os.tag == .windows) {
            try self.appendManagedLaunchOwnedArg(&launch, try self.windowsManagedProcessShellAlloc());
            try appendOwnedString(self.allocator, &launch.argv, "-NoLogo");
            try appendOwnedString(self.allocator, &launch.argv, "-NoProfile");
            try appendOwnedString(self.allocator, &launch.argv, "-Command");
        } else {
            try appendOwnedString(self.allocator, &launch.argv, "/bin/sh");
            try appendOwnedString(self.allocator, &launch.argv, "-lc");
        }
        try self.appendManagedLaunchOwnedArg(&launch, try self.managedProcessLaunchCommand(process));
        return launch;
    }

    fn appendManagedLaunchOwnedArg(self: *AppState, launch: *ManagedProcessLaunch, owned: []u8) !void {
        errdefer self.allocator.free(owned);
        try launch.argv.append(self.allocator, owned);
    }

    fn windowsManagedProcessShellAlloc(self: *AppState) ![]u8 {
        var env_map = try process_env.buildAugmentedEnvMap(self.allocator);
        defer env_map.deinit();
        return process_env.resolveExecutableInEnvMapAlloc(self.allocator, &env_map, "pwsh.exe") catch
            process_env.resolveExecutableInEnvMapAlloc(self.allocator, &env_map, "powershell.exe") catch
            error.WindowsPowerShellNotFound;
    }

    fn argvContains(argv: []const []u8, needle: []const u8) bool {
        for (argv) |arg| {
            if (std.mem.indexOf(u8, arg, needle) != null) return true;
        }
        return false;
    }

    fn isCodexExecutable(path: []const u8) bool {
        const name = std.mem.trimStart(u8, path, " \t\r\n");
        const base_index = std.mem.lastIndexOfAny(u8, name, "/\\");
        const base = if (base_index) |index| name[index + 1 ..] else name;
        return std.ascii.eqlIgnoreCase(base, "codex") or
            std.ascii.eqlIgnoreCase(base, "codex.exe") or
            std.ascii.eqlIgnoreCase(base, "codex.cmd") or
            std.ascii.eqlIgnoreCase(base, "codex.bat");
    }

    fn managedProcessLaunchCommand(self: *AppState, process: *const ManagedProcess) ![]u8 {
        if (!(process.kind == .agent and process.provider == .codex and process.hooks)) {
            return self.allocator.dupe(u8, process.command);
        }
        if (std.mem.indexOf(u8, process.command, "features.codex_hooks") != null) {
            return self.allocator.dupe(u8, process.command);
        }

        const trimmed = std.mem.trim(u8, process.command, " \t\r\n");
        if (std.mem.eql(u8, trimmed, "codex")) {
            return self.allocator.dupe(u8, "codex -c features.codex_hooks=true");
        }
        if (std.mem.startsWith(u8, trimmed, "codex ")) {
            return try std.fmt.allocPrint(self.allocator, "codex -c features.codex_hooks=true {s}", .{trimmed["codex ".len..]});
        }
        return self.allocator.dupe(u8, process.command);
    }

    pub fn stopManagedProcess(self: *AppState, project_index: usize, name: []const u8) !bool {
        try self.refreshProjectStackConfig(project_index);
        if (project_index >= self.projects.items.len) return false;
        var project = &self.projects.items[project_index];
        var process = project.managedProcessByName(name) orelse return false;
        process.explicit_stop = true;
        process.status = .stopped;
        process.last_exit_ms = unixTimestampMs();
        process.next_restart_ms = 0;
        process.pending_watch_restart_ms = 0;
        if (process.dock_id) |dock_id| {
            if (self.projectTerminalDockMutable(project_index, dock_id)) |dock| {
                _ = dock.terminateActiveSession();
            }
        }
        self.markDirty();
        return true;
    }

    pub fn restartManagedProcess(self: *AppState, project_index: usize, name: []const u8) !bool {
        try self.refreshProjectStackConfig(project_index);
        if (project_index >= self.projects.items.len) return false;
        if (self.projects.items[project_index].managedProcessByName(name)) |process| {
            process.restart_count += 1;
            process.status = .restarting;
        }
        _ = try self.stopManagedProcess(project_index, name);
        return try self.startManagedProcess(project_index, name);
    }

    pub fn startProjectStack(self: *AppState, project_index: usize) !usize {
        try self.refreshProjectStackConfig(project_index);
        if (project_index >= self.projects.items.len) return 0;
        var started: usize = 0;
        var names: std.ArrayList([]u8) = .empty;
        defer {
            for (names.items) |name| self.allocator.free(name);
            names.deinit(self.allocator);
        }
        for (self.projects.items[project_index].managed_processes.items) |process| {
            try names.append(self.allocator, try self.allocator.dupe(u8, process.name));
        }
        for (names.items) |name| {
            if (try self.startManagedProcess(project_index, name)) started += 1;
        }
        return started;
    }

    pub fn stopProjectStack(self: *AppState, project_index: usize) !usize {
        try self.refreshProjectStackConfig(project_index);
        if (project_index >= self.projects.items.len) return 0;
        var stopped: usize = 0;
        var names: std.ArrayList([]u8) = .empty;
        defer {
            for (names.items) |name| self.allocator.free(name);
            names.deinit(self.allocator);
        }
        for (self.projects.items[project_index].managed_processes.items) |process| {
            try names.append(self.allocator, try self.allocator.dupe(u8, process.name));
        }
        for (names.items) |name| {
            if (try self.stopManagedProcess(project_index, name)) stopped += 1;
        }
        return stopped;
    }

    pub fn restartProjectStack(self: *AppState, project_index: usize) !usize {
        _ = try self.stopProjectStack(project_index);
        return try self.startProjectStack(project_index);
    }

    pub fn managedProcessLogs(self: *AppState, project_index: usize, name: []const u8, max_bytes: usize) !?[]u8 {
        try self.refreshProjectStackConfig(project_index);
        if (project_index >= self.projects.items.len) return null;
        const project = &self.projects.items[project_index];
        const process = project.managedProcessByName(name) orelse return null;
        const dock_id = process.dock_id orelse return null;
        const dock = self.projectTerminalDock(project_index, dock_id) orelse return null;
        return try dock.activeOutputTailAlloc(self.allocator, max_bytes);
    }

    pub fn managedProcessByNameConst(self: *AppState, project_index: usize, name: []const u8) !?*ManagedProcess {
        try self.refreshProjectStackConfig(project_index);
        if (project_index >= self.projects.items.len) return null;
        return self.projects.items[project_index].managedProcessByName(name);
    }

    pub fn focusManagedProcessTerminal(self: *AppState, project_index: usize, name: []const u8) !bool {
        try self.refreshProjectStackConfig(project_index);
        if (project_index >= self.projects.items.len) return false;
        self.selected_project_index = project_index;
        const process = self.projects.items[project_index].managedProcessByName(name) orelse return false;
        if (process.pane_id) |pane_id| {
            _ = self.focusCurrentProjectWorkspacePane(pane_id);
            if (process.dock_id) |dock_id| self.requestTerminalDockFocus(dock_id);
            return true;
        }
        if (process.dock_id) |dock_id| {
            process.pane_id = try self.projects.items[project_index].workspace_layout.ensureTerminalPane(self.allocator, dock_id);
            _ = self.focusCurrentProjectWorkspacePane(process.pane_id.?);
            self.requestTerminalDockFocus(dock_id);
            self.markDirty();
            return true;
        }
        return false;
    }

    fn handleWorkspaceCommand(self: *AppState, raw_text: []const u8) bool {
        const text = std.mem.trim(u8, raw_text, " \t\r\n");
        if (!std.mem.startsWith(u8, text, "/")) return false;
        var parts = std.mem.tokenizeAny(u8, text, " \t\r\n");
        const root = parts.next() orelse return false;
        if (!std.mem.eql(u8, root, "/stack") and !std.mem.eql(u8, root, "/process")) return false;
        const action = parts.next() orelse {
            self.setSidebarNotice(if (std.mem.eql(u8, root, "/stack")) "Usage: /stack start|stop|restart|status" else "Usage: /process start|stop|restart|focus|crashed <name>");
            return true;
        };
        const project_index = self.selected_project_index;
        if (std.mem.eql(u8, root, "/stack")) {
            if (std.mem.eql(u8, action, "status")) {
                self.refreshProjectStackConfig(project_index) catch |err| {
                    self.setSidebarNotice(@errorName(err));
                    return true;
                };
                self.refreshManagedProcessStatuses(project_index);
                const count: usize = self.projects.items[project_index].managed_processes.items.len;
                self.clearDraft();
                self.syncPaletteComposerFromDraft();
                var buffer: [96]u8 = undefined;
                self.setSidebarNotice(std.fmt.bufPrint(&buffer, "Stack has {d} configured process(es).", .{count}) catch "Stack status updated.");
                return true;
            }
            const result = if (std.mem.eql(u8, action, "start"))
                self.startProjectStack(project_index)
            else if (std.mem.eql(u8, action, "stop"))
                self.stopProjectStack(project_index)
            else if (std.mem.eql(u8, action, "restart"))
                self.restartProjectStack(project_index)
            else {
                self.setSidebarNotice("Usage: /stack start|stop|restart|status");
                return true;
            };
            const count = result catch |err| {
                self.setSidebarNotice(@errorName(err));
                return true;
            };
            self.clearDraft();
            self.syncPaletteComposerFromDraft();
            var buffer: [96]u8 = undefined;
            self.setSidebarNotice(std.fmt.bufPrint(&buffer, "Stack {s}: {d} process(es).", .{ action, count }) catch "Stack command applied.");
            return true;
        }

        if (std.mem.eql(u8, action, "crashed")) {
            self.refreshProjectStackConfig(project_index) catch |err| {
                self.setSidebarNotice(@errorName(err));
                return true;
            };
            self.refreshManagedProcessStatuses(project_index);
            var crashed: usize = 0;
            for (self.projects.items[project_index].managed_processes.items) |process| {
                if (process.status == .crashed) crashed += 1;
            }
            self.clearDraft();
            self.syncPaletteComposerFromDraft();
            var buffer: [96]u8 = undefined;
            self.setSidebarNotice(std.fmt.bufPrint(&buffer, "{d} crashed process(es).", .{crashed}) catch "Crashed process status updated.");
            return true;
        }

        const name = parts.next() orelse {
            self.setSidebarNotice("Usage: /process start|stop|restart|focus <name>");
            return true;
        };
        const changed = if (std.mem.eql(u8, action, "start"))
            self.startManagedProcess(project_index, name)
        else if (std.mem.eql(u8, action, "stop"))
            self.stopManagedProcess(project_index, name)
        else if (std.mem.eql(u8, action, "restart"))
            self.restartManagedProcess(project_index, name)
        else if (std.mem.eql(u8, action, "focus"))
            self.focusManagedProcessTerminal(project_index, name)
        else {
            self.setSidebarNotice("Usage: /process start|stop|restart|focus|crashed <name>");
            return true;
        };
        const changed_result = changed catch |err| {
            self.setSidebarNotice(@errorName(err));
            return true;
        };
        if (!changed_result) {
            self.setSidebarNotice("Process not found.");
            return true;
        }
        self.clearDraft();
        self.syncPaletteComposerFromDraft();
        var buffer: [128]u8 = undefined;
        self.setSidebarNotice(std.fmt.bufPrint(&buffer, "Process {s}: {s}.", .{ action, name }) catch "Process command applied.");
        return true;
    }

    fn handleProviderSlashCommand(self: *AppState, raw_text: []const u8) bool {
        const thread = self.currentThread();
        const provider_commands = ai_harness.slashCommandsForProvider(harnessProviderForDbProvider(thread.provider));
        const parsed = slash_commands.parse(raw_text, provider_commands);
        switch (parsed) {
            .not_slash => return false,
            .local => return false,
            .literal_prompt => |prompt| {
                self.setDraft(prompt);
                self.syncPaletteComposerFromDraft();
                self.sendDraft() catch |err| {
                    log.err("failed to send literal slash draft: {s}", .{@errorName(err)});
                    self.setSidebarNotice("Failed to send message.");
                };
                return true;
            },
            .unknown => |unknown| {
                if (thread.provider == .claude) {
                    const command: ai_harness.ProviderSlashCommand = .{
                        .id = .custom,
                        .name = unknown.name,
                        .summary = "Claude SDK slash command.",
                        .usage = unknown.name,
                        .requires_thread = false,
                    };
                    self.beginProviderSlashCommand(command, unknown.args, raw_text) catch |err| {
                        log.err("failed to start Claude slash command name_len={d}: {s}", .{ unknown.name.len, @errorName(err) });
                        self.setSidebarNotice("Failed to start Claude slash command.");
                        return true;
                    };
                    return true;
                }
                var buffer: [160]u8 = undefined;
                self.setSidebarNotice(std.fmt.bufPrint(
                    &buffer,
                    "Unknown slash command: {s}. Try /stack, /process, or a command supported by this provider.",
                    .{unknown.name},
                ) catch "Unknown slash command.");
                return true;
            },
            .provider => |provider_command| {
                const command = provider_command.command;
                if (command.availability != .available) {
                    var buffer: [160]u8 = undefined;
                    self.setSidebarNotice(std.fmt.bufPrint(&buffer, "Command not enabled yet: {s}. Usage: {s}", .{ command.name, command.usage }) catch "Command is not enabled yet.");
                    return true;
                }
                if (command.requires_thread and thread.provider_thread_id == null) {
                    var buffer: [160]u8 = undefined;
                    self.setSidebarNotice(std.fmt.bufPrint(&buffer, "Start a {s} thread before using {s}.", .{ utils.providerLabel(thread.provider), command.name }) catch "Start a provider thread before using this command.");
                    return true;
                }
                self.beginProviderSlashCommand(command, provider_command.args, raw_text) catch |err| {
                    log.err("failed to start slash command {s}: {s}", .{ command.name, @errorName(err) });
                    self.setSidebarNotice("Failed to start slash command.");
                    return true;
                };
                return true;
            },
        }
    }

    fn beginProviderSlashCommand(
        self: *AppState,
        command: ai_harness.ProviderSlashCommand,
        args: []const u8,
        raw_text: []const u8,
    ) !void {
        const page_alloc = std.heap.page_allocator;
        const project_index = self.selected_project_index;
        const thread_index = self.currentProject().selected_thread_index;
        const project = self.currentProject();
        const thread = self.currentThread();

        self.slash_command_state.mutex.lock();
        if (self.slash_command_state.status == .pending) {
            self.slash_command_state.mutex.unlock();
            self.setSidebarNotice("A slash command is already running.");
            return;
        }
        self.slash_command_state.mutex.unlock();

        const execution_target = self.providerExecutionTargetForProjectThread(project_index, thread, 0) orelse return;
        const execution_cwd = execution_target.cwd();

        const command_display_name = try page_alloc.dupe(u8, command.name);
        errdefer page_alloc.free(command_display_name);

        const request = try page_alloc.create(SlashCommandWorkerRequest);
        errdefer page_alloc.destroy(request);
        request.* = .{
            .provider = thread.provider,
            .harness = thread.harness,
            .project_path = try page_alloc.dupe(u8, project.path),
            .remote_ssh_host = if (execution_target.remoteHost()) |host| try page_alloc.dupe(u8, host) else null,
            .remote_cwd = if (execution_target.remoteHost() != null) try page_alloc.dupe(u8, execution_cwd) else null,
            .thread_id = if (thread.provider_thread_id) |thread_id| try page_alloc.dupe(u8, thread_id) else null,
            .command = command.id,
            .raw_text = try page_alloc.dupe(u8, raw_text),
            .args = try page_alloc.dupe(u8, args),
        };
        errdefer {
            page_alloc.free(request.project_path);
            if (request.remote_ssh_host) |host| page_alloc.free(host);
            if (request.remote_cwd) |cwd| page_alloc.free(cwd);
            if (request.thread_id) |thread_id| page_alloc.free(thread_id);
            page_alloc.free(request.raw_text);
            page_alloc.free(request.args);
        }

        self.slash_command_state.mutex.lock();
        defer self.slash_command_state.mutex.unlock();
        if (self.slash_command_state.error_message) |message| {
            page_alloc.free(message);
            self.slash_command_state.error_message = null;
        }
        if (self.slash_command_state.result) |result| {
            result.deinit(page_alloc);
            self.slash_command_state.result = null;
        }
        if (self.slash_command_state.display_name) |name| {
            page_alloc.free(name);
            self.slash_command_state.display_name = null;
        }
        self.slash_command_state.project_index = project_index;
        self.slash_command_state.thread_index = thread_index;
        self.slash_command_state.provider = thread.provider;
        self.slash_command_state.command = command.id;
        self.slash_command_state.display_name = command_display_name;
        self.slash_command_state.started_at_ms = unixTimestampMs();
        self.slash_command_state.status = .pending;
        self.slash_command_state.worker = std.Thread.spawn(.{}, slashCommandWorker, .{ &self.slash_command_state, request }) catch |err| {
            self.slash_command_state.status = .idle;
            self.slash_command_state.display_name = null;
            self.slash_command_state.started_at_ms = 0;
            return err;
        };

        self.clearDraft();
        self.syncPaletteComposerFromDraft();
        var buffer: [128]u8 = undefined;
        self.setSidebarNotice(std.fmt.bufPrint(&buffer, "Running {s}...", .{command.name}) catch "Running slash command...");
    }

    fn resolveManagedProcessCwd(self: *AppState, project_path: []const u8, raw_cwd: []const u8) ![]u8 {
        if (raw_cwd.len == 0 or std.mem.eql(u8, raw_cwd, ".")) return self.allocator.dupe(u8, project_path);
        const expanded = try platform_paths.expandUserPath(self.allocator, raw_cwd);
        defer self.allocator.free(expanded);
        if (std.fs.path.isAbsolute(expanded)) return self.allocator.dupe(u8, expanded);
        return std.fs.path.join(self.allocator, &.{ project_path, expanded });
    }

    fn managedProcessRestartBackoffMs(restart_count: u32) i64 {
        const capped_shift: u6 = @intCast(@min(restart_count, 5));
        const backoff = MANAGED_PROCESS_BASE_RESTART_BACKOFF_MS * (@as(i64, 1) << capped_shift);
        return @min(backoff, MANAGED_PROCESS_MAX_RESTART_BACKOFF_MS);
    }

    fn pollManagedProcessWatch(self: *AppState, project_index: usize, process: *ManagedProcess, now: i64) void {
        if (now - process.last_watch_scan_ms < MANAGED_PROCESS_WATCH_SCAN_MS) return;
        process.last_watch_scan_ms = now;
        const project = &self.projects.items[project_index];
        const signature = self.scanManagedProcessWatchSignature(project.path, process.watch.items) catch |err| {
            process.watch_error_count += 1;
            log.warn("failed to scan watch patterns for managed process name_len={d}: {s}", .{ process.name.len, @errorName(err) });
            return;
        };
        if (!process.watch_ready or process.watch_signature == 0) {
            process.watch_signature = signature;
            process.watch_ready = true;
            return;
        }
        if (process.watch_signature == signature) return;
        process.watch_signature = signature;
        process.last_watch_change_ms = now;
        process.pending_watch_restart_ms = now + MANAGED_PROCESS_WATCH_DEBOUNCE_MS;
        process.watch_trigger_count += 1;
        process.status = .restarting;
    }

    fn scanManagedProcessWatchSignature(self: *AppState, project_path: []const u8, patterns: []const []u8) !u64 {
        var hasher = std.hash.Wyhash.init(0);
        hashBytes(&hasher, "verde-watch-v1");
        for (patterns) |pattern| hashBytes(&hasher, pattern);

        var threaded = std.Io.Threaded.init_single_threaded;
        var dir = try std.Io.Dir.openDirAbsolute(threaded.io(), project_path, .{ .iterate = true });
        defer dir.close(threaded.io());
        var walker = try dir.walk(self.allocator);
        defer walker.deinit();

        while (try walker.next(threaded.io())) |entry| {
            if (entry.kind == .directory and shouldSkipManagedWatchDirectory(entry.basename)) {
                walker.leave(threaded.io());
                continue;
            }
            const rel_path = std.mem.sliceTo(entry.path, 0);
            if (!managedWatchPathMatches(patterns, rel_path)) continue;
            const stat = entry.dir.statFile(threaded.io(), entry.basename, .{}) catch continue;
            hashBytes(&hasher, rel_path);
            hashU64(&hasher, @intFromEnum(stat.kind));
            hashU64(&hasher, stat.size);
            const mtime_ns: i128 = stat.mtime.nanoseconds;
            hashBytes(&hasher, std.mem.asBytes(&mtime_ns));
        }
        return hasher.final();
    }

    fn shouldSkipManagedWatchDirectory(name: []const u8) bool {
        return std.mem.eql(u8, name, ".git") or
            std.mem.eql(u8, name, ".zig-cache") or
            std.mem.eql(u8, name, "zig-out") or
            std.mem.eql(u8, name, "node_modules");
    }

    fn managedWatchPathMatches(patterns: []const []u8, path: []const u8) bool {
        for (patterns) |pattern| {
            if (globMatch(pattern, path)) return true;
        }
        return false;
    }

    fn globMatch(pattern: []const u8, path: []const u8) bool {
        if (pattern.len == 0) return path.len == 0;
        if (pattern[0] == '*') {
            const deep = pattern.len >= 2 and pattern[1] == '*';
            const rest = if (deep) pattern[2..] else pattern[1..];
            var index: usize = 0;
            while (index <= path.len) : (index += 1) {
                if (!deep and index > 0 and path[index - 1] == '/') break;
                if (globMatch(rest, path[index..])) return true;
            }
            return false;
        }
        if (path.len == 0) return false;
        if (pattern[0] == '?') {
            if (path[0] == '/') return false;
            return globMatch(pattern[1..], path[1..]);
        }
        if (pattern[0] != path[0]) return false;
        return globMatch(pattern[1..], path[1..]);
    }

    fn hashBytes(hasher: *std.hash.Wyhash, bytes: []const u8) void {
        hasher.update(bytes);
        hashU64(hasher, bytes.len);
    }

    fn hashU64(hasher: *std.hash.Wyhash, value: u64) void {
        var copy = value;
        hasher.update(std.mem.asBytes(&copy));
    }

    fn selectWorkspaceChatPaneThread(self: *AppState, pane_id: WorkspacePaneId) bool {
        if (self.projects.items.len == 0) return false;
        var project = &self.projects.items[self.selected_project_index];
        const pane = project.workspace_layout.paneById(pane_id) orelse return false;
        const thread_index = switch (pane.ref) {
            .chat => |ref| ref.thread_index,
            else => return false,
        };
        if (thread_index >= project.threads.items.len) return false;
        project.selected_thread_index = thread_index;
        if (!pane.minimized) project.workspace_layout.focused_pane_id = pane_id;
        self.terminal_focused = false;
        self.unfocusBrowserPane();
        self.browser_address_focused = false;
        self.syncPaletteComposerFromDraft();
        self.markDirty();
        return true;
    }

    pub fn isCurrentProjectWorkspacePaneFocused(self: *const AppState, pane_id: WorkspacePaneId) bool {
        if (self.projects.items.len == 0) return false;
        return self.projects.items[self.selected_project_index].workspace_layout.focused_pane_id == pane_id;
    }

    pub fn isCurrentProjectWorkspacePaneMaximized(self: *const AppState, pane_id: WorkspacePaneId) bool {
        if (self.projects.items.len == 0) return false;
        return self.projects.items[self.selected_project_index].workspace_layout.maximized_pane_id == pane_id;
    }

    pub fn focusWorkspacePane(self: *AppState, project_index: usize, pane_id: WorkspacePaneId) bool {
        if (project_index >= self.projects.items.len) return false;
        var layout = &self.projects.items[project_index].workspace_layout;
        const pane = layout.paneById(pane_id) orelse return false;
        if (pane.minimized) return false;
        // Composer popovers belong to the live composer pane; leaving them
        // open on a pane that no longer renders them would silently keep
        // eating clicks through the popover routing.
        self.closePaletteModelPicker();
        self.closeRunConfigPopover();
        layout.focused_pane_id = pane_id;
        switch (pane.ref) {
            .chat => |ref| {
                var project = &self.projects.items[project_index];
                if (ref.thread_index < project.threads.items.len) {
                    project.selected_thread_index = ref.thread_index;
                }
                if (self.selected_project_index == project_index) {
                    self.terminal_focused = false;
                    self.unfocusBrowserPane();
                    self.browser_address_focused = false;
                    self.syncPaletteComposerFromDraft();
                }
            },
            .terminal => |ref| if (self.selected_project_index == project_index) self.requestTerminalDockFocus(ref.dock_id),
            .browser => {
                if (self.selected_project_index == project_index) {
                    self.terminal_focused = false;
                    self.composer_focused = false;
                    self.palette_composer.focused = false;
                }
            },
        }
        self.markDirty();
        return true;
    }

    pub fn focusCurrentProjectWorkspacePane(self: *AppState, pane_id: WorkspacePaneId) bool {
        if (self.projects.items.len == 0) return false;
        return self.focusWorkspacePane(self.selected_project_index, pane_id);
    }

    pub fn focusPromptForFocusedChatWorkspacePane(self: *AppState) bool {
        if (self.projects.items.len == 0) return false;
        var project = &self.projects.items[self.selected_project_index];
        const pane_id = project.workspace_layout.focused_pane_id orelse return false;
        const pane = project.workspace_layout.paneById(pane_id) orelse return false;
        const thread_index = switch (pane.ref) {
            .chat => |ref| ref.thread_index,
            else => return false,
        };
        if (thread_index >= project.threads.items.len) return false;
        project.selected_thread_index = thread_index;
        self.syncPaletteComposerFromDraft();
        self.palette_composer.focused = true;
        self.composer_focused = true;
        self.terminal_focused = false;
        self.unfocusBrowserPane();
        self.browser_address_focused = false;
        self.ensurePaletteComposerCursorVisible();
        self.markDirty();
        return true;
    }

    pub fn swapCurrentProjectWorkspacePanes(self: *AppState, first_pane_id: WorkspacePaneId, second_pane_id: WorkspacePaneId) bool {
        if (self.projects.items.len == 0) return false;
        var layout = &self.projects.items[self.selected_project_index].workspace_layout;
        if (!layout.swapPaneRefs(first_pane_id, second_pane_id)) return false;
        self.markDirty();
        return true;
    }

    pub fn moveWorkspacePaneInDirection(
        self: *AppState,
        project_index: usize,
        pane_id: WorkspacePaneId,
        direction: WorkspacePaneDirection,
    ) bool {
        if (project_index >= self.projects.items.len) return false;
        var layout = &self.projects.items[project_index].workspace_layout;
        const neighbor_id = layout.neighborPaneId(pane_id, direction) orelse return false;
        if (!layout.swapPaneRefs(pane_id, neighbor_id)) return false;
        layout.focused_pane_id = neighbor_id;
        if (self.selected_project_index == project_index) {
            _ = self.focusCurrentProjectWorkspacePane(neighbor_id);
        } else {
            self.markDirty();
        }
        return true;
    }

    pub fn moveCurrentProjectWorkspacePaneToPlacement(
        self: *AppState,
        source_pane_id: WorkspacePaneId,
        target_pane_id: WorkspacePaneId,
        axis: WorkspaceSplitAxis,
        new_after: bool,
    ) bool {
        if (self.projects.items.len == 0) return false;
        if (source_pane_id == target_pane_id) return false;

        var layout = &self.projects.items[self.selected_project_index].workspace_layout;
        const source = layout.paneByIdMutable(source_pane_id) orelse return false;
        const target = layout.paneById(target_pane_id) orelse return false;
        if (source.minimized or target.minimized) return false;

        // Temporarily hide the source pane so the existing root-prune logic can
        // collapse its old split before we reuse the same pane id at the drop target.
        source.minimized = true;
        if (layout.root) |root_node| {
            const repaired = WorkspaceLayout.pruneRootToVisiblePanes(self.allocator, layout, root_node);
            layout.root = repaired.node;
        }
        const source_again = layout.paneByIdMutable(source_pane_id) orelse return false;
        source_again.minimized = false;

        layout.splitPaneWithLeaf(self.allocator, target_pane_id, source_pane_id, axis, new_after) catch |err| {
            log.err("failed to move workspace pane: {s}", .{@errorName(err)});
            layout.ensurePaneInRootSplit(self.allocator, source_pane_id, axis, 0.5) catch {};
            self.setSidebarNotice("Failed to move workspace pane.");
            self.markDirty();
            return false;
        };
        layout.maximized_pane_id = null;
        _ = self.focusCurrentProjectWorkspacePane(source_pane_id);
        self.markDirty();
        return true;
    }

    pub fn toggleCurrentProjectWorkspacePaneMaximized(self: *AppState, pane_id: WorkspacePaneId) bool {
        if (self.projects.items.len == 0) return false;
        return self.toggleWorkspacePaneMaximized(self.selected_project_index, pane_id);
    }

    pub fn toggleWorkspacePaneMaximized(self: *AppState, project_index: usize, pane_id: WorkspacePaneId) bool {
        if (project_index >= self.projects.items.len) return false;
        var layout = &self.projects.items[project_index].workspace_layout;
        const pane = layout.paneById(pane_id) orelse return false;
        if (pane.minimized) return false;
        runtime_log.diagnostic("pane maximize toggle begin project={d} pane={d} kind={s} currently_maximized={any}", .{
            project_index,
            pane_id,
            @tagName(pane.ref),
            layout.maximized_pane_id,
        });
        layout.maximized_pane_id = if (layout.maximized_pane_id == pane_id) null else pane_id;
        layout.focused_pane_id = pane_id;
        switch (pane.ref) {
            .chat => |ref| {
                var project = &self.projects.items[project_index];
                if (ref.thread_index < project.threads.items.len) {
                    project.selected_thread_index = ref.thread_index;
                }
                if (self.selected_project_index == project_index) self.terminal_focused = false;
            },
            .terminal => |ref| if (self.selected_project_index == project_index) self.requestTerminalDockFocus(ref.dock_id),
            .browser => {
                if (self.selected_project_index == project_index) {
                    self.terminal_focused = false;
                    self.composer_focused = false;
                }
            },
        }
        self.markDirty();
        runtime_log.diagnostic("pane maximize toggle done project={d} pane={d} maximized={any}", .{
            project_index,
            pane_id,
            layout.maximized_pane_id,
        });
        return true;
    }

    pub fn maximizeWorkspacePane(self: *AppState, project_index: usize, pane_id: WorkspacePaneId) bool {
        if (project_index >= self.projects.items.len) return false;
        const layout = &self.projects.items[project_index].workspace_layout;
        if (layout.maximized_pane_id == pane_id) return true;
        return self.toggleWorkspacePaneMaximized(project_index, pane_id);
    }

    pub fn clearCurrentProjectWorkspacePaneMaximized(self: *AppState) bool {
        if (self.projects.items.len == 0) return false;
        return self.clearWorkspacePaneMaximized(self.selected_project_index);
    }

    pub fn clearWorkspacePaneMaximized(self: *AppState, project_index: usize) bool {
        if (project_index >= self.projects.items.len) return false;
        var layout = &self.projects.items[project_index].workspace_layout;
        if (layout.maximized_pane_id == null) return false;
        layout.maximized_pane_id = null;
        self.markDirty();
        return true;
    }

    pub fn closeCurrentProjectWorkspacePane(self: *AppState, pane_id: WorkspacePaneId) bool {
        if (self.projects.items.len == 0) return false;
        return self.closeWorkspacePane(self.selected_project_index, pane_id);
    }

    pub fn closeWorkspacePane(self: *AppState, project_index: usize, pane_id: WorkspacePaneId) bool {
        if (project_index >= self.projects.items.len) return false;
        var project = &self.projects.items[project_index];
        var layout = &project.workspace_layout;
        if (layout.visiblePaneCount() <= 1) {
            self.setSidebarNotice("Cannot close the last workspace pane.");
            return false;
        }
        var removed_ref = layout.closePane(self.allocator, pane_id) orelse return false;
        defer deinitWorkspacePaneRef(&removed_ref, self.allocator);
        switch (removed_ref) {
            .chat => self.setSidebarNotice("Chat pane closed."),
            .terminal => |ref| {
                if (!layout.hasTerminalDockPane(ref.dock_id)) {
                    if (ref.dock_id == 0) {
                        project.terminal_dock.terminateAllSessions();
                        project.terminal_dock.visible = false;
                    } else if (project.terminalDockEntryById(ref.dock_id)) |entry| {
                        entry.dock.terminateAllSessions();
                        _ = project.removeTerminalDockById(self.allocator, ref.dock_id);
                    }
                }
                if (self.selected_project_index == project_index and !layout.hasVisiblePaneKind(.terminal)) self.terminal_focused = false;
                self.setSidebarNotice("Terminal pane closed.");
            },
            .browser => {
                self.browser_state.setControlsVisible(false);
                self.browser_state.setInspectorEnabled(false);
                self.browser_state.clearSuppressedEvalResults();
                self.browser_surface_suspended_for_palette_overlay = false;
                self.browser_surface_suspended_for_layout = false;
                self.unfocusBrowserPane();
                self.browser_pane_hovered = false;
                self.browser_address_focused = false;
                self.browser_inspector_menu_open = false;
                self.browser_state.controller.hide() catch |err| {
                    log.warn("failed to hide browser runtime after closing pane: {s}", .{@errorName(err)});
                };
                self.setSidebarNotice("Browser pane closed.");
            },
        }
        self.clearHerdrClosedPaneMetadata(project_index, pane_id, removed_ref);
        if (layout.root == null) {
            if (layout.firstVisiblePaneId()) |next_id| {
                layout.replaceRootWithLeaf(self.allocator, next_id) catch {
                    layout.focused_pane_id = next_id;
                };
            }
        }
        self.markDirty();
        return true;
    }

    fn clearHerdrClosedPaneMetadata(self: *AppState, project_index: usize, pane_id: WorkspacePaneId, removed_ref: WorkspacePaneRef) void {
        if (project_index >= self.projects.items.len) return;
        var project = &self.projects.items[project_index];
        if (project.herdr_link) |*link| {
            var changed = link.removePaneLinkForVerdePane(self.allocator, pane_id);
            if (link.attach_pane_id) |attach_pane_id| {
                if (attach_pane_id == pane_id) {
                    link.attach_pane_id = null;
                    link.attach_dock_id = null;
                    changed = true;
                }
            }
            switch (removed_ref) {
                .terminal => |ref| {
                    if (link.attach_dock_id) |attach_dock_id| {
                        if (attach_dock_id == ref.dock_id and !project.workspace_layout.hasTerminalDockPane(ref.dock_id)) {
                            link.attach_dock_id = null;
                            link.attach_pane_id = null;
                            changed = true;
                        }
                    }
                },
                else => {},
            }
            if (changed) link.updated_at_ms = unixTimestampMs();
        }
    }

    pub fn closeFocusedWorkspacePane(self: *AppState) bool {
        if (self.projects.items.len == 0) return false;
        const pane_id = self.projects.items[self.selected_project_index].workspace_layout.focused_pane_id orelse return false;
        return self.closeCurrentProjectWorkspacePane(pane_id);
    }

    pub fn splitCurrentProjectWorkspacePaneWithChat(self: *AppState, pane_id: WorkspacePaneId) bool {
        return self.splitCurrentProjectWorkspacePaneWithChatAxis(pane_id, .vertical);
    }

    pub fn splitFocusedWorkspacePaneWithChatAxis(self: *AppState, axis: WorkspaceSplitAxis) bool {
        if (self.projects.items.len == 0) return false;
        const pane_id = self.projects.items[self.selected_project_index].workspace_layout.focused_pane_id orelse return false;
        return self.splitCurrentProjectWorkspacePaneWithChatAxis(pane_id, axis);
    }

    pub fn splitCurrentProjectWorkspacePaneWithChatAxis(self: *AppState, pane_id: WorkspacePaneId, axis: WorkspaceSplitAxis) bool {
        return self.splitCurrentProjectWorkspacePaneWithChatPlacement(pane_id, axis, true);
    }

    pub fn splitCurrentProjectWorkspacePaneWithChatPlacement(self: *AppState, pane_id: WorkspacePaneId, axis: WorkspaceSplitAxis, new_after: bool) bool {
        if (self.projects.items.len == 0) return false;
        return self.splitWorkspacePaneWithChatPlacement(self.selected_project_index, pane_id, axis, new_after);
    }

    pub fn splitWorkspacePaneWithChatAxis(self: *AppState, project_index: usize, pane_id: WorkspacePaneId, axis: WorkspaceSplitAxis) bool {
        return self.splitWorkspacePaneWithChatPlacement(project_index, pane_id, axis, true);
    }

    pub fn splitWorkspacePaneWithChatPlacement(self: *AppState, project_index: usize, pane_id: WorkspacePaneId, axis: WorkspaceSplitAxis, new_after: bool) bool {
        if (project_index >= self.projects.items.len) return false;
        var project = &self.projects.items[project_index];
        var layout = &project.workspace_layout;
        const target = layout.paneById(pane_id) orelse return false;
        if (target.minimized) return false;
        const thread_index = project.addThread(self.allocator) catch |err| {
            log.err("failed to create chat thread for workspace pane: {s}", .{@errorName(err)});
            self.setSidebarNotice("Failed to create a new thread.");
            return false;
        };
        const new_pane_id = layout.createChatPane(self.allocator, thread_index) catch |err| {
            log.err("failed to create chat workspace pane: {s}", .{@errorName(err)});
            self.setSidebarNotice("Failed to create chat pane.");
            return false;
        };
        layout.splitPaneWithLeaf(self.allocator, pane_id, new_pane_id, axis, new_after) catch |err| {
            log.err("failed to split chat workspace pane: {s}", .{@errorName(err)});
            self.setSidebarNotice("Failed to split workspace.");
            return false;
        };
        layout.maximized_pane_id = null;
        project.selected_thread_index = thread_index;
        if (self.selected_project_index == project_index) {
            self.terminal_focused = false;
            self.requestComposerFocus();
            self.syncRenameBuffer();
        }
        self.setSidebarNotice("New chat pane ready.");
        self.markDirty();
        return true;
    }

    pub fn splitCurrentProjectWorkspacePaneWithThread(
        self: *AppState,
        pane_id: WorkspacePaneId,
        thread_index: usize,
        axis: WorkspaceSplitAxis,
        new_after: bool,
    ) bool {
        if (self.projects.items.len == 0) return false;
        var project = &self.projects.items[self.selected_project_index];
        if (thread_index >= project.threads.items.len) return false;
        var layout = &project.workspace_layout;
        const target_pane_id = if (layout.paneById(pane_id) != null)
            pane_id
        else
            layout.focused_pane_id orelse layout.firstVisiblePaneId() orelse pane_id;
        const target = layout.paneById(target_pane_id) orelse return false;
        if (target.minimized) return false;
        const new_pane_id = layout.createChatPane(self.allocator, thread_index) catch |err| {
            log.err("failed to create dropped chat workspace pane: {s}", .{@errorName(err)});
            self.setSidebarNotice("Failed to create chat pane.");
            return false;
        };
        layout.splitPaneWithLeaf(self.allocator, target_pane_id, new_pane_id, axis, new_after) catch |err| {
            log.err("failed to split dropped chat workspace pane: {s}", .{@errorName(err)});
            self.setSidebarNotice("Failed to split workspace.");
            return false;
        };
        layout.maximized_pane_id = null;
        project.selected_thread_index = thread_index;
        self.terminal_focused = false;
        self.requestComposerFocus();
        self.syncRenameBuffer();
        self.markDirty();
        return true;
    }

    pub fn splitCurrentProjectWorkspacePaneWithTerminal(self: *AppState, pane_id: WorkspacePaneId) bool {
        return self.splitCurrentProjectWorkspacePaneWithTerminalAxis(pane_id, .horizontal);
    }

    pub fn splitFocusedWorkspacePaneWithTerminalAxis(self: *AppState, axis: WorkspaceSplitAxis) bool {
        return self.splitFocusedWorkspacePaneWithTerminalPlacement(axis, true);
    }

    pub fn splitFocusedWorkspacePaneWithTerminalPlacement(self: *AppState, axis: WorkspaceSplitAxis, new_after: bool) bool {
        if (self.projects.items.len == 0) return false;
        const pane_id = self.projects.items[self.selected_project_index].workspace_layout.focused_pane_id orelse return false;
        return self.splitCurrentProjectWorkspacePaneWithTerminalPlacement(pane_id, axis, new_after);
    }

    pub fn openTerminalPaneForProjectIndex(self: *AppState, project_index: usize) bool {
        if (project_index >= self.projects.items.len) return false;
        self.selected_project_index = project_index;
        self.ensureCurrentProjectWorkspace();
        const pane_id = self.projects.items[self.selected_project_index].workspace_layout.focused_pane_id orelse return false;
        return self.splitCurrentProjectWorkspacePaneWithTerminalPlacement(pane_id, .horizontal, true);
    }

    fn openCurrentProjectTerminalPaneForCommand(self: *AppState) ?WorkspacePaneId {
        if (self.projects.items.len == 0) return null;
        self.ensureCurrentProjectWorkspace();

        var project = &self.projects.items[self.selected_project_index];
        var layout = &project.workspace_layout;
        const target_pane_id = layout.focused_pane_id orelse layout.firstVisiblePaneId() orelse {
            self.setSidebarNotice("No workspace pane selected.");
            return null;
        };
        const target = layout.paneById(target_pane_id) orelse return null;
        if (target.minimized) return null;

        const dock_id = self.createCurrentProjectTerminalDock() catch |err| {
            log.err("failed to allocate editor terminal dock: {s}", .{@errorName(err)});
            self.setSidebarNotice("Failed to create terminal dock.");
            return null;
        };
        project = &self.projects.items[self.selected_project_index];
        self.restartTerminalDockForWorkspace(self.selected_project_index, dock_id) catch |err| {
            log.err("failed to start editor terminal dock: {s}", .{@errorName(err)});
            self.setSidebarNotice("Failed to start terminal.");
            return null;
        };
        var dock = self.currentProjectTerminalDockMutable(dock_id) orelse return null;

        layout = &project.workspace_layout;
        const new_pane_id = layout.createTerminalPaneWithPurpose(self.allocator, dock_id, .editor) catch |err| {
            log.err("failed to create editor terminal workspace pane: {s}", .{@errorName(err)});
            self.setSidebarNotice("Failed to create terminal pane.");
            return null;
        };
        layout.splitPaneWithLeaf(self.allocator, target_pane_id, new_pane_id, .horizontal, true) catch |err| {
            log.err("failed to split editor terminal workspace pane: {s}", .{@errorName(err)});
            self.setSidebarNotice("Failed to split workspace.");
            return null;
        };
        layout.maximized_pane_id = null;
        dock.visible = false;
        self.requestTerminalDockFocus(dock_id);
        return new_pane_id;
    }

    pub fn openThreadInTui(self: *AppState, project_index: usize, thread_index: usize) void {
        if (project_index >= self.projects.items.len) return;
        var project = &self.projects.items[project_index];
        if (thread_index >= project.threads.items.len) return;
        var thread = &project.threads.items[thread_index];
        const provider_thread_id = thread.provider_thread_id orelse {
            self.setSidebarNotice("Thread has no provider session id yet.");
            return;
        };
        const command = self.tuiResumeCommand(thread.provider, provider_thread_id) catch |err| {
            log.warn("failed to build TUI resume command: {s}", .{@errorName(err)});
            self.setSidebarNotice("Failed to build TUI resume command.");
            return;
        };
        defer self.allocator.free(command);

        self.selected_project_index = project_index;
        self.ensureCurrentProjectWorkspace();

        project = &self.projects.items[project_index];
        thread = &project.threads.items[thread_index];
        var layout = &project.workspace_layout;

        const previous_dock_id = thread.tui_dock_id;
        const pane_id = if (previous_dock_id) |dock_id|
            layout.visibleTerminalPaneIdForDock(dock_id) orelse
                layout.visibleChatPaneIdForThread(thread_index) orelse
                layout.focused_pane_id orelse
                layout.firstVisiblePaneId() orelse
                return
        else
            layout.visibleChatPaneIdForThread(thread_index) orelse
                layout.focused_pane_id orelse
                layout.firstVisiblePaneId() orelse
                return;

        if (previous_dock_id) |dock_id| {
            if (self.currentProjectTerminalDockMutable(dock_id)) |old_dock| {
                old_dock.terminateAllSessions();
            }
        }

        const dock_id = self.createCurrentProjectTerminalDock() catch |err| {
            log.err("failed to allocate TUI terminal dock: {s}", .{@errorName(err)});
            self.setSidebarNotice("Failed to create TUI terminal.");
            return;
        };

        project = &self.projects.items[project_index];
        thread = &project.threads.items[thread_index];
        layout = &project.workspace_layout;
        thread.tui_dock_id = dock_id;
        const pane = layout.paneByIdMutable(pane_id) orelse return;
        self.restartTerminalDockForWorkspace(project_index, dock_id) catch |err| {
            log.err("failed to start TUI terminal dock: {s}", .{@errorName(err)});
            self.setSidebarNotice("Failed to start TUI terminal.");
            return;
        };
        var dock = self.currentProjectTerminalDockMutable(dock_id) orelse return;

        pane.ref = .{ .terminal = .{ .dock_id = dock_id } };
        pane.minimized = false;
        layout.focused_pane_id = pane_id;
        layout.maximized_pane_id = null;
        dock.visible = false;
        self.requestTerminalFocus();
        _ = self.writeWorkspaceTerminalPane(pane_id, command) catch |err| {
            log.warn("failed to write TUI resume command: {s}", .{@errorName(err)});
            self.setSidebarNotice("Failed to write TUI resume command.");
            return;
        };
        self.setSidebarNotice("Thread opened in TUI.");
        self.markDirty();
    }

    pub fn openThreadInChat(self: *AppState, project_index: usize, thread_index: usize) void {
        if (project_index >= self.projects.items.len) return;
        var project = &self.projects.items[project_index];
        if (thread_index >= project.threads.items.len) return;
        const dock_id = project.threads.items[thread_index].tui_dock_id orelse return;

        self.selected_project_index = project_index;
        self.ensureCurrentProjectWorkspace();
        project = &self.projects.items[project_index];
        var layout = &project.workspace_layout;
        const pane_id = layout.visibleTerminalPaneIdForDock(dock_id) orelse layout.focused_pane_id orelse layout.firstVisiblePaneId() orelse return;
        const pane = layout.paneByIdMutable(pane_id) orelse return;
        pane.ref = .{ .chat = .{ .thread_index = thread_index } };
        pane.minimized = false;
        layout.focused_pane_id = pane_id;
        layout.maximized_pane_id = null;
        project.selected_thread_index = thread_index;
        self.terminal_focused = false;
        self.requestComposerFocus();
        self.syncRenameBuffer();
        self.setSidebarNotice("Thread opened in chat.");
        self.markDirty();
    }

    fn tuiResumeCommand(self: *AppState, provider: Provider, thread_id: []const u8) ![]u8 {
        return switch (provider) {
            .codex => std.fmt.allocPrint(self.allocator, "codex resume {s}\n", .{thread_id}),
            .opencode => blk: {
                if (!std.mem.startsWith(u8, thread_id, "ses")) {
                    break :blk self.allocator.dupe(u8, "opencode --continue\n");
                }
                break :blk std.fmt.allocPrint(self.allocator, "opencode --session {s}\n", .{thread_id});
            },
            .claude => std.fmt.allocPrint(self.allocator, "claude --resume {s}\n", .{thread_id}),
            .cursor => std.fmt.allocPrint(self.allocator, "agent --resume {s}\n", .{thread_id}),
        };
    }

    pub fn splitCurrentProjectWorkspacePaneWithTerminalAxis(self: *AppState, pane_id: WorkspacePaneId, axis: WorkspaceSplitAxis) bool {
        return self.splitCurrentProjectWorkspacePaneWithTerminalPlacement(pane_id, axis, true);
    }

    pub fn splitCurrentProjectWorkspacePaneWithTerminalPlacement(self: *AppState, pane_id: WorkspacePaneId, axis: WorkspaceSplitAxis, new_after: bool) bool {
        if (self.projects.items.len == 0) return false;
        return self.splitWorkspacePaneWithTerminalPlacement(self.selected_project_index, pane_id, axis, new_after);
    }

    pub fn splitWorkspacePaneWithTerminalAxis(self: *AppState, project_index: usize, pane_id: WorkspacePaneId, axis: WorkspaceSplitAxis) bool {
        return self.splitWorkspacePaneWithTerminalPlacement(project_index, pane_id, axis, true);
    }

    pub fn splitWorkspacePaneWithTerminalPlacement(self: *AppState, project_index: usize, pane_id: WorkspacePaneId, axis: WorkspaceSplitAxis, new_after: bool) bool {
        if (project_index >= self.projects.items.len) return false;
        var project = &self.projects.items[project_index];
        var layout = &project.workspace_layout;
        const target = layout.paneById(pane_id) orelse return false;
        if (target.minimized) return false;

        const dock_id = self.createProjectTerminalDock(project_index) catch |err| {
            log.err("failed to allocate terminal dock: {s}", .{@errorName(err)});
            self.setSidebarNotice("Failed to create terminal dock.");
            return false;
        };
        self.restartTerminalDockForWorkspace(project_index, dock_id) catch |err| {
            log.err("failed to start terminal dock: {s}", .{@errorName(err)});
            self.setSidebarNotice("Failed to start terminal.");
            return false;
        };
        var dock = self.projectTerminalDockMutable(project_index, dock_id) orelse return false;

        const new_pane_id = layout.createTerminalPane(self.allocator, dock_id) catch |err| {
            log.err("failed to create terminal workspace pane: {s}", .{@errorName(err)});
            self.setSidebarNotice("Failed to create terminal pane.");
            return false;
        };
        layout.splitPaneWithLeaf(self.allocator, pane_id, new_pane_id, axis, new_after) catch |err| {
            log.err("failed to split terminal workspace pane: {s}", .{@errorName(err)});
            self.setSidebarNotice("Failed to split workspace.");
            return false;
        };
        layout.maximized_pane_id = null;
        dock.visible = false;
        if (self.selected_project_index == project_index) self.requestTerminalDockFocus(dock_id);
        self.setSidebarNotice("Terminal pane created.");
        self.markDirty();
        return true;
    }

    pub fn minimizeCurrentProjectWorkspacePane(self: *AppState, pane_id: WorkspacePaneId) bool {
        if (self.projects.items.len == 0) return false;
        return self.minimizeWorkspacePane(self.selected_project_index, pane_id);
    }

    pub fn minimizeWorkspacePane(self: *AppState, project_index: usize, pane_id: WorkspacePaneId) bool {
        if (project_index >= self.projects.items.len) return false;
        var layout = &self.projects.items[project_index].workspace_layout;
        if (layout.visiblePaneCount() <= 1) {
            self.setSidebarNotice("Cannot minimize the last workspace pane.");
            return false;
        }

        for (layout.panes.items) |*pane| {
            if (pane.id != pane_id or pane.minimized) continue;
            pane.minimized = true;
            if (layout.maximized_pane_id == pane_id) layout.maximized_pane_id = null;
            if (layout.firstVisiblePaneId()) |next_id| {
                layout.replaceRootWithLeaf(self.allocator, next_id) catch {
                    layout.focused_pane_id = next_id;
                };
            }
            if (self.selected_project_index == project_index and self.focusedWorkspacePaneKind() != .terminal) self.terminal_focused = false;
            self.setSidebarNotice("Workspace pane minimized.");
            self.markDirty();
            return true;
        }
        return false;
    }

    pub fn minimizeFocusedWorkspacePane(self: *AppState) bool {
        if (self.projects.items.len == 0) return false;
        const pane_id = self.projects.items[self.selected_project_index].workspace_layout.focused_pane_id orelse return false;
        return self.minimizeCurrentProjectWorkspacePane(pane_id);
    }

    pub fn toggleFocusedWorkspacePaneMaximized(self: *AppState) bool {
        if (self.projects.items.len == 0) return false;
        const pane_id = self.projects.items[self.selected_project_index].workspace_layout.focused_pane_id orelse return false;
        return self.toggleCurrentProjectWorkspacePaneMaximized(pane_id);
    }

    pub fn restoreCurrentProjectWorkspacePane(self: *AppState, pane_id: WorkspacePaneId) bool {
        if (self.projects.items.len == 0) return false;
        return self.restoreWorkspacePane(self.selected_project_index, pane_id);
    }

    pub fn restoreWorkspacePane(self: *AppState, project_index: usize, pane_id: WorkspacePaneId) bool {
        if (project_index >= self.projects.items.len) return false;
        var layout = &self.projects.items[project_index].workspace_layout;
        for (layout.panes.items) |*pane| {
            if (pane.id != pane_id or !pane.minimized) continue;
            pane.minimized = false;
            layout.focused_pane_id = pane_id;
            layout.ensurePaneInRootSplit(self.allocator, pane_id, .horizontal, 0.64) catch |err| {
                log.err("failed to restore workspace pane: {s}", .{@errorName(err)});
                return false;
            };
            switch (pane.ref) {
                .chat => {
                    if (self.selected_project_index == project_index) self.terminal_focused = false;
                },
                .terminal => {
                    if (self.selected_project_index == project_index) self.requestTerminalFocus();
                },
                .browser => {
                    self.applyBrowserPaneSnapshotToRuntime(project_index, pane_id);
                    if (self.selected_project_index == project_index) {
                        self.terminal_focused = false;
                        self.composer_focused = false;
                    }
                    self.browser_state.setControlsVisible(true);
                    self.browser_state.controller.show() catch |err| {
                        log.warn("failed to restore browser runtime with pane: {s}", .{@errorName(err)});
                    };
                    if (self.selected_project_index != project_index) self.noteBrowserPaneNotRendered();
                },
            }
            self.setSidebarNotice("Workspace pane restored.");
            self.markDirty();
            return true;
        }
        return false;
    }

    pub fn resizeCurrentProjectWorkspaceSplit(
        self: *AppState,
        first_pane_id: WorkspacePaneId,
        second_pane_id: WorkspacePaneId,
        axis: WorkspaceSplitAxis,
        ratio: f32,
    ) void {
        if (self.projects.items.len == 0) return;
        _ = self.resizeWorkspaceSplit(self.selected_project_index, first_pane_id, second_pane_id, axis, ratio);
    }

    pub fn resizeWorkspaceSplit(
        self: *AppState,
        project_index: usize,
        first_pane_id: WorkspacePaneId,
        second_pane_id: WorkspacePaneId,
        axis: WorkspaceSplitAxis,
        ratio: f32,
    ) bool {
        if (project_index >= self.projects.items.len) return false;
        var layout = &self.projects.items[project_index].workspace_layout;
        if (!layout.resizeSplit(first_pane_id, second_pane_id, axis, ratio)) return false;
        self.markDirty();
        return true;
    }

    pub fn nudgeCurrentProjectWorkspaceSplit(
        self: *AppState,
        first_pane_id: WorkspacePaneId,
        second_pane_id: WorkspacePaneId,
        axis: WorkspaceSplitAxis,
        delta: f32,
    ) bool {
        if (self.projects.items.len == 0) return false;
        var layout = &self.projects.items[self.selected_project_index].workspace_layout;
        if (layout.nudgeSplitRatio(first_pane_id, second_pane_id, axis, delta)) {
            self.markDirty();
            return true;
        }
        return false;
    }

    pub fn focusCurrentProjectWorkspaceTerminalPane(self: *AppState) void {
        if (self.projects.items.len == 0) return;
        var layout = &self.projects.items[self.selected_project_index].workspace_layout;
        for (layout.panes.items) |pane| {
            if (pane.minimized) continue;
            switch (pane.ref) {
                .terminal => {
                    layout.focused_pane_id = pane.id;
                    return;
                },
                else => {},
            }
        }
    }

    pub fn focusCurrentProjectWorkspaceTerminalDock(self: *AppState, dock_id: u32) void {
        if (self.projects.items.len == 0) return;
        var layout = &self.projects.items[self.selected_project_index].workspace_layout;
        for (layout.panes.items) |pane| {
            if (pane.minimized) continue;
            switch (pane.ref) {
                .terminal => |ref| if (ref.dock_id == dock_id) {
                    layout.focused_pane_id = pane.id;
                    return;
                },
                else => {},
            }
        }
    }

    pub fn currentProjectWorkspaceVisiblePaneCount(self: *const AppState) usize {
        if (self.projects.items.len == 0) return 0;
        return self.projects.items[self.selected_project_index].workspace_layout.visiblePaneCount();
    }

    pub fn currentProjectGridNewPanePlacement(self: *const AppState) ?WorkspacePanePlacement {
        if (self.projects.items.len == 0) return null;
        return self.projects.items[self.selected_project_index].workspace_layout.gridNewPanePlacement();
    }

    pub fn currentProjectWorkspaceMinimizedPaneCount(self: *const AppState) usize {
        if (self.projects.items.len == 0) return 0;
        const layout = &self.projects.items[self.selected_project_index].workspace_layout;
        var count: usize = 0;
        for (layout.panes.items) |pane| {
            if (pane.minimized) count += 1;
        }
        return count;
    }

    pub fn currentProjectWorkspaceMinimizedPaneAt(self: *const AppState, index: usize) ?WorkspaceMinimizedPane {
        if (self.projects.items.len == 0) return null;
        const layout = &self.projects.items[self.selected_project_index].workspace_layout;
        var current: usize = 0;
        for (layout.panes.items) |pane| {
            if (!pane.minimized) continue;
            if (current == index) {
                return .{
                    .id = pane.id,
                    .kind = switch (pane.ref) {
                        .chat => .chat,
                        .terminal => .terminal,
                        .browser => .browser,
                    },
                };
            }
            current += 1;
        }
        return null;
    }

    pub fn resetUiDebugFrame(self: *AppState) void {
        self.debug_terminal_window_focused = false;
        self.debug_terminal_hitbox_focused = false;
        self.debug_terminal_hitbox_active = false;
        self.debug_terminal_hitbox_clicked = false;
        self.debug_terminal_focus_requested = false;
        self.browser_pane_hovered = false;
        self.transcript_focused = false;
        self.debug_workspace_visible_pane_count = 0;
    }

    pub fn noteTerminalViewportDebug(
        self: *AppState,
        window_focused: bool,
        hitbox_focused: bool,
        hitbox_active: bool,
        hitbox_clicked: bool,
        focus_requested: bool,
    ) void {
        self.debug_terminal_window_focused = window_focused;
        self.debug_terminal_hitbox_focused = hitbox_focused;
        self.debug_terminal_hitbox_active = hitbox_active;
        self.debug_terminal_hitbox_clicked = hitbox_clicked;
        self.debug_terminal_focus_requested = focus_requested;
    }

    pub fn noteTerminalKeyRouting(self: *AppState, event: *const sdl.KeyboardEvent, handled: bool) void {
        self.debug_last_terminal_scancode = event.scancode;
        self.debug_last_terminal_key_handled = handled;
    }

    pub fn noteTerminalTextRouting(self: *AppState, text: []const u8, handled: bool) void {
        self.debug_last_terminal_text_handled = handled;
        @memset(&self.debug_last_terminal_text, 0);
        const len = @min(text.len, self.debug_last_terminal_text.len - 1);
        @memcpy(self.debug_last_terminal_text[0..len], text[0..len]);
    }

    pub fn currentThreadMutable(self: *AppState) *ChatThread {
        return self.currentProjectMutable().currentThreadMutable();
    }

    pub fn rememberCurrentTranscriptScroll(self: *AppState, scroll_y: f32) void {
        const thread = self.currentThreadMutable();
        thread.transcript_scroll_valid = true;
        thread.transcript_scroll_y = @max(scroll_y, 0.0);
    }

    pub fn rememberWorkspaceChatTranscriptScroll(self: *AppState, pane_id: WorkspacePaneId, scroll_y: f32) void {
        if (self.projects.items.len == 0) return;
        var layout = &self.projects.items[self.selected_project_index].workspace_layout;
        const pane = layout.paneByIdMutable(pane_id) orelse return;
        switch (pane.ref) {
            .chat => |*ref| {
                ref.transcript_scroll_valid = true;
                ref.transcript_scroll_y = @max(scroll_y, 0.0);
            },
            else => {},
        }
    }

    pub fn currentTranscriptScrollY(self: *const AppState) ?f32 {
        const thread = self.currentThread();
        if (!thread.transcript_scroll_valid) return null;
        return thread.transcript_scroll_y;
    }

    pub fn workspaceChatTranscriptScrollY(self: *const AppState, pane_id: WorkspacePaneId) ?f32 {
        if (self.projects.items.len == 0) return null;
        const layout = &self.projects.items[self.selected_project_index].workspace_layout;
        const pane = layout.paneById(pane_id) orelse return null;
        return switch (pane.ref) {
            .chat => |ref| if (ref.transcript_scroll_valid) ref.transcript_scroll_y else null,
            else => null,
        };
    }

    pub fn requestComposerFocus(self: *AppState) void {
        self.composer_focus_requested = true;
        self.terminal_focused = false;
        self.unfocusBrowserPane();
    }

    pub fn requestTerminalFocus(self: *AppState) void {
        self.focusCurrentProjectWorkspaceTerminalPane();
        self.finishTerminalFocusRequest();
    }

    pub fn requestTerminalDockFocus(self: *AppState, dock_id: u32) void {
        self.focusCurrentProjectWorkspaceTerminalDock(dock_id);
        self.finishTerminalFocusRequest();
    }

    fn finishTerminalFocusRequest(self: *AppState) void {
        self.terminal_focused = true;
        self.composer_focused = false;
        self.palette_composer.focused = false;
        self.unfocusBrowserPane();
        self.browser_address_focused = false;
        self.palette_modal_text_focus = .none;
        if (self.focusedWorkspaceTerminalDockId()) |dock_id| {
            if (self.currentProjectTerminalDock(dock_id)) |dock| {
                if (dock.activeSessionId()) |session_id| {
                    _ = self.clearSurfaceAttentionBySession(session_id);
                }
            }
        }
    }

    pub fn consumeComposerFocusRequest(self: *AppState) bool {
        const requested = self.composer_focus_requested;
        self.composer_focus_requested = false;
        return requested;
    }

    pub fn draftBuffer(self: *AppState) [:0]u8 {
        return self.currentProjectMutable().draftBuffer();
    }

    pub fn syncPaletteComposerFromDraft(self: *AppState) void {
        if (self.projects.items.len == 0) return;
        const draft = self.currentDraft();
        if (std.mem.eql(u8, self.palette_composer.text(), draft)) return;
        const callbacks = self.palette_composer.callbacks;
        self.palette_composer.setCallbacks(.{});
        defer self.palette_composer.setCallbacks(callbacks);
        self.palette_composer.setText(self.allocator, draft) catch |err| {
            log.warn("failed to sync palette composer draft: {s}", .{@errorName(err)});
        };
    }

    pub fn syncDraftFromPaletteComposer(self: *AppState) void {
        if (self.projects.items.len == 0) return;
        const text = self.palette_composer.text();
        if (std.mem.eql(u8, self.currentDraft(), text)) return;
        self.setDraft(text);
    }

    pub fn setPaletteComposerBounds(self: *AppState, input_min: [2]f32, input_max: [2]f32) void {
        self.setComposerInputBounds(input_min, input_max);
        self.palette_composer.setBounds(.{
            .x = input_min[0],
            .y = input_min[1],
            .w = @max(input_max[0] - input_min[0], 0.0),
            .h = @max(input_max[1] - input_min[1], 0.0),
        });
    }

    /// Cleared at the start of each workspace paint; see `syncComposerToolbarOverlayHitRects`.
    pub fn invalidateComposerToolbarOverlayHitRects(self: *AppState) void {
        self.composer_toolbar_overlay_valid = false;
    }

    /// Hit targets for `routePaletteComposerToolbarOverlayClick` (cascade on new threads, synthetic
    /// toolbar clicks when the overlay batch sits above the composer's own hit testing).
    pub fn syncComposerToolbarOverlayHitRects(self: *AppState) void {
        self.composer_toolbar_model_rect = self.palette_composer.modelRect();
        self.composer_toolbar_reasoning_rect = self.palette_composer.reasoningRect();
        self.composer_toolbar_fast_rect = self.palette_composer.fastRect();
        self.composer_toolbar_access_rect = self.palette_composer.accessRect();
        self.composer_toolbar_overlay_valid = true;
    }

    pub fn syncPaletteComposerControls(self: *AppState) void {
        if (self.projects.items.len == 0) return;
        self.palette_composer.setCallbacks(.{ .context = self, .on_event = paletteComposerPromptEvent, .get_clipboard = paletteComposerGetClipboard });
        self.palette_composer.setStyle(paletteComposerStyle());
        // Composer font sizes are CSS units in the comptime config but the
        // runtime metrics need to be the actual pixel size, otherwise the
        // placeholder + selectors render at fixed pixel sizes while everything
        // else in the UI scales with the display — looks tiny on HiDPI.
        self.palette_composer.setFontMetrics(paletteComposerTextFontMetrics(theme.scaledUi(PALETTE_COMPOSER_FONT_SIZE)));
        self.palette_composer.setToolbarFontMetrics(paletteEstimatedFontMetrics(theme.scaledUi(PALETTE_COMPOSER_TOOLBAR_FONT_SIZE)));
        self.palette_composer.setIconFontMetrics(paletteEstimatedFontMetrics(theme.scaledUi(PALETTE_COMPOSER_ICON_FONT_SIZE)));
        const thread = self.currentThread();
        // Model + run pills open host popovers (rich picker / run-config
        // panel); fast and access moved into the run-config popover, so their
        // dedicated pills stay hidden.
        self.palette_composer.setExternalModelMenu(true);
        self.palette_composer.setExternalReasoningMenu(true);
        self.palette_composer.setShowFastToggle(false);
        self.palette_composer.setShowAccessToggle(false);
        const hide_placeholder = thread.draftImageCount() > 0;
        self.palette_composer.setPlaceholder(self.allocator, if (!hide_placeholder) "Ask anything, or use / to show available commands" else " ") catch |err| {
            log.warn("failed to sync palette composer placeholder: {s}", .{@errorName(err)});
        };
        const model_options = composerModelOptions(self, thread.provider);
        self.palette_composer.setModelOptions(self, model_options.len, paletteModelLabel);
        self.refreshOpencodeReasoningMenu(thread) catch |err| {
            log.warn("failed to refresh OpenCode reasoning menu: {s}", .{@errorName(err)});
            self.clearOpencodeReasoningMenu();
        };
        // The run pill (former reasoning pill) is always visible: it anchors
        // the run-config popover and summarizes reasoning / speed / access.
        // Its option list stays un-synced on purpose — the built-in dropdown
        // is disabled via setExternalReasoningMenu and the run-config steppers
        // own the reasoning data instead.
        self.palette_composer.setShowReasoningToggle(true);
        // The run pill leads with host-drawn fast/access state glyphs (see
        // chat_panel.renderComposerToolbarIcons); reserve label room for the
        // lock plus, when the provider has a speed tier, the bolt.
        var run_icon_reserve: f32 = COMPOSER_RUN_PILL_ICON_CELL;
        if (self.currentComposerShowsFastToggle()) run_icon_reserve += COMPOSER_RUN_PILL_ICON_CELL;
        self.palette_composer.setReasoningLeadingReserve(run_icon_reserve);
        self.palette_composer.model_index = self.composerModelIndex(thread.provider, thread.model_ref);
        self.palette_composer.setSendState(if (thread.isSendPendingForUi()) .stop else .send);
        if (self.palette_composer.model_index) |index| {
            if (index < model_options.len) {
                self.palette_composer.setModelLabel(self.allocator, std.mem.sliceTo(model_options[index].label, 0)) catch |err| {
                    log.warn("failed to sync palette composer model label: {s}", .{@errorName(err)});
                };
            }
        }
        // Sized for a worst-case dynamic reasoning-variant label plus both
        // fixed segments; overflow degrades to a truncated summary.
        var summary_buf: [192]u8 = undefined;
        self.palette_composer.setReasoningLabel(self.allocator, self.composerRunSummary(&summary_buf)) catch |err| {
            log.warn("failed to sync palette composer run summary label: {s}", .{@errorName(err)});
        };
        if (self.run_config_open) self.syncRunConfigSteppers();
    }

    /// Compact " · "-joined summary of the run settings (reasoning, speed,
    /// access) shown on the composer run pill and the inactive preview pill.
    pub fn composerRunSummary(self: *const AppState, buf: []u8) []const u8 {
        var writer: std.Io.Writer = .fixed(buf);
        var wrote_any = false;
        const thread = self.currentThread();
        const has_reasoning = thread.provider == .codex or self.opencode_reasoning_menu.items.len > 0;
        if (has_reasoning) {
            writer.writeAll(self.currentComposerReasoningLabel()) catch {};
            wrote_any = true;
        }
        if (self.currentComposerShowsFastToggle()) {
            if (wrote_any) writer.writeAll(" · ") catch {};
            writer.writeAll(self.currentComposerFastLabel()) catch {};
            wrote_any = true;
        }
        if (wrote_any) writer.writeAll(" · ") catch {};
        writer.writeAll(self.currentComposerAccessLabel()) catch {};
        return writer.buffered();
    }

    pub fn syncPaletteModelPicker(self: *AppState) void {
        self.palette_model_picker.setCallbacks(.{
            .context = self,
            .on_event = paletteModelPickerEvent,
            // Ctrl+V pastes into the embedded search field while open.
            .get_clipboard = paletteComposerGetClipboard,
        });
        self.palette_model_picker.setStyle(paletteModelPickerStyle());
        self.palette_model_picker.setUiScale(theme.uiScaleFactor());
        self.palette_model_picker.setFontMetrics(paletteEstimatedFontMetrics(theme.scaledUi(15.5)));
        self.rebuildModelPickerEntries() catch |err| {
            log.warn("failed to rebuild model picker entries: {s}", .{@errorName(err)});
        };
        self.palette_model_picker.setItemCount(self.model_picker_entries.items.len);
        self.palette_model_picker.setSelectedItem(self.currentModelPickerSelection());
        self.setPaletteModelPickerBoundsFromToolbar();
    }

    fn appendModelPickerEntries(self: *AppState, provider: Provider) !void {
        const options = composerModelOptions(self, provider);
        for (options, 0..) |_, option_index| {
            try self.model_picker_entries.append(self.allocator, .{ .provider = provider, .option_index = option_index });
        }
    }

    fn rebuildModelPickerEntries(self: *AppState) !void {
        const previous = try self.allocator.dupe(ModelPickerEntry, self.model_picker_entries.items);
        defer self.allocator.free(previous);
        self.model_picker_entries.clearRetainingCapacity();
        if (self.currentThreadAllowsProviderChoice()) {
            for (COMPOSER_PROVIDER_OPTIONS) |candidate| try self.appendModelPickerEntries(candidate);
        } else {
            try self.appendModelPickerEntries(self.currentThread().provider);
        }
        // The rebuilt slice is the change signal: comparing it against the
        // previous entries catches provider switches, async option refreshes,
        // and reorders without a separate fingerprint to keep in sync.
        var changed = previous.len != self.model_picker_entries.items.len;
        if (!changed) {
            for (previous, self.model_picker_entries.items) |old, new| {
                if (old.provider != new.provider or old.option_index != new.option_index) {
                    changed = true;
                    break;
                }
            }
        }
        if (changed) self.palette_model_picker.invalidateItems();
    }

    /// Funnels every model-picker input through one catch-log path so mouse,
    /// keyboard, and text routing stay behaviorally identical.
    fn modelPickerInput(self: *AppState, input: palette.RichPickerInput) bool {
        const handled = self.palette_model_picker.handleInput(self.allocator, input) catch |err| blk: {
            log.warn("model picker input failed: {s}", .{@errorName(err)});
            break :blk false;
        };
        if (handled) self.noteInteraction();
        return handled;
    }

    fn currentModelPickerSelection(self: *const AppState) ?usize {
        const thread = self.currentThread();
        const option_index = self.composerModelIndex(thread.provider, thread.model_ref) orelse return null;
        for (self.model_picker_entries.items, 0..) |entry, index| {
            if (entry.provider == thread.provider and entry.option_index == option_index) return index;
        }
        return null;
    }

    pub fn setPaletteModelPickerBoundsFromToolbar(self: *AppState) void {
        const anchor = self.composer_toolbar_model_rect;
        if (anchor.w <= 0.0 or anchor.h <= 0.0) return;
        const picker_width = (COMPOSER_MODEL_PICKER_WIDTH + COMPOSER_MODEL_PICKER_RAIL_WIDTH) * theme.uiScaleFactor();
        const min_x = if (self.composer_input_bounds_valid) self.composer_input_min[0] else anchor.x;
        const max_x = if (self.composer_input_bounds_valid) self.composer_input_max[0] else anchor.x + picker_width;
        const viewport_top: f32 = theme.scaledUi(8.0);
        const viewport_bottom = if (self.composer_input_bounds_valid)
            self.composer_input_max[1]
        else
            anchor.y + anchor.h;
        self.palette_model_picker.setAnchorRect(anchor);
        self.palette_model_picker.setViewportRect(.{
            .x = min_x,
            .y = viewport_top,
            .w = @max(max_x - min_x, picker_width),
            .h = @max(viewport_bottom - viewport_top, theme.scaledUi(120.0)),
        });
    }

    pub fn openPaletteModelPicker(self: *AppState) void {
        if (self.projects.items.len == 0) return;
        if (self.opencode_model_options.items.len == 0) {
            self.refreshOpencodeModelOptionsCacheAsync();
        }
        if (self.claude_model_options.items.len == 0) {
            self.refreshClaudeModelOptionsCacheAsync();
        }
        if (self.cursor_model_options.items.len == 0) {
            self.refreshCursorModelOptionsCacheAsync();
        }
        self.closeRunConfigPopover();
        self.palette_composer.active_menu = null;
        self.palette_composer.hovered_menu_index = null;
        self.syncPaletteModelPicker();
        _ = self.palette_model_picker.handleInput(self.allocator, .open) catch |err| blk: {
            log.warn("failed to open model picker: {s}", .{@errorName(err)});
            break :blk false;
        };
        self.palette_composer.focused = false;
        self.composer_focused = false;
        // The popover owns typing (search) and arrows while open.
        self.terminal_focused = false;
        self.noteInteraction();
    }

    pub fn closePaletteModelPicker(self: *AppState) void {
        if (!self.palette_model_picker.isOpen()) return;
        _ = self.palette_model_picker.handleInput(self.allocator, .close) catch |err| blk: {
            log.warn("failed to close model picker: {s}", .{@errorName(err)});
            break :blk false;
        };
    }

    /// Fresh, never-sent threads may still switch provider; committed threads
    /// keep their provider so transcripts stay consistent.
    fn currentThreadAllowsProviderChoice(self: *const AppState) bool {
        const thread = self.currentThread();
        return thread.messages.items.len == 0 and
            thread.provider_thread_id == null and
            !thread.isSendPendingForUi();
    }

    /// Which run-config rows apply right now: reasoning and speed depend on the
    /// provider/model, access always applies. Fills `out` in display order.
    pub fn runConfigVisibleRows(self: *const AppState, out: *[3]RunConfigRowKind) usize {
        var count: usize = 0;
        const thread = self.currentThread();
        const reasoning_count: usize = if (thread.provider == .codex)
            CODEX_REASONING_OPTIONS.len
        else
            self.opencode_reasoning_menu.items.len;
        if (reasoning_count > 0) {
            out[count] = .reasoning;
            count += 1;
        }
        if (self.currentComposerShowsFastToggle()) {
            out[count] = .speed;
            count += 1;
        }
        out[count] = .access;
        count += 1;
        return count;
    }

    pub fn syncRunConfigSteppers(self: *AppState) void {
        const thread = self.currentThread();
        const style = paletteRunStepperStyle();
        for (&self.run_steppers, 0..) |*stepper, index| {
            self.run_stepper_contexts[index] = .{ .state = self, .kind = @enumFromInt(@as(u8, @intCast(index))) };
            stepper.setCallbacks(.{ .context = &self.run_stepper_contexts[index], .on_event = paletteRunStepperEvent });
            stepper.setStyle(style);
            stepper.setUiScale(theme.uiScaleFactor());
            stepper.setFontMetrics(paletteEstimatedFontMetrics(theme.scaledUi(13.0)));
        }
        const reasoning = &self.run_steppers[@intFromEnum(RunConfigRowKind.reasoning)];
        reasoning.setStepCount(if (thread.provider == .codex) CODEX_REASONING_OPTIONS.len else self.opencode_reasoning_menu.items.len);
        reasoning.setSelected(composerReasoningIndexForThread(self, thread));
        const speed = &self.run_steppers[@intFromEnum(RunConfigRowKind.speed)];
        speed.setStepCount(RUN_SPEED_STEP_LABELS.len);
        speed.setSelected(if (thread.fast_mode == .on) 1 else 0);
        const access = &self.run_steppers[@intFromEnum(RunConfigRowKind.access)];
        access.setStepCount(RUN_ACCESS_STEP_LABELS.len);
        access.setSelected(if (thread.access_mode == .full_access) 1 else 0);
    }

    /// True when the mouse rests on a clickable composer control — toolbar
    /// pills, the send button, model-picker rows/rail, or run-config stepper
    /// segments — so the main loop can show a pointer (hand) cursor.
    pub fn pointerCursorWanted(self: *const AppState) bool {
        if (self.projects.items.len == 0) return false;
        const point: palette.draw.Vec2 = .{ .x = self.palette_mouse_x, .y = self.palette_mouse_y };
        if (self.palette_model_picker.wantsPointerAt(point)) return true;
        if (self.run_config_open) {
            var kinds: [3]RunConfigRowKind = undefined;
            const count = self.runConfigVisibleRows(&kinds);
            var index: usize = 0;
            while (index < count) : (index += 1) {
                if (self.run_steppers[@intFromEnum(kinds[index])].wantsPointerAt(point)) return true;
            }
        }
        // The overlay-valid flag guarantees the composer toolbar was laid
        // out this frame, so its hit rects are trustworthy.
        if (self.composer_toolbar_overlay_valid and self.palette_composer.hitTest(point) != null) return true;
        return false;
    }

    /// Advances the run-config stepper thumb animations from monotonic
    /// time; called once per rendered frame while the popover is open.
    pub fn tickRunConfigSteppers(self: *AppState) void {
        const now = monotonicMs();
        defer self.run_config_last_tick_ms = now;
        if (self.run_config_last_tick_ms == 0 or now <= self.run_config_last_tick_ms) return;
        // Clamp so a long gap between frames (popover just reopened, app
        // stalled) advances the slide instead of teleporting past it.
        const elapsed: u32 = @intCast(@min(now - self.run_config_last_tick_ms, 100));
        for (&self.run_steppers) |*stepper| stepper.tick(elapsed);
    }

    /// True while a stepper thumb is mid-slide; keeps the main loop pumping
    /// frames for the ~160ms animation window.
    pub fn runConfigStepperAnimating(self: *const AppState) bool {
        if (!self.run_config_open) return false;
        for (&self.run_steppers) |*stepper| {
            if (stepper.isAnimating()) return true;
        }
        return false;
    }

    pub const RunConfigLayout = struct {
        panel: palette.Rect,
        row_kinds: [3]RunConfigRowKind,
        title_rects: [3]palette.Rect,
        row_count: usize,
    };

    /// Computes the run-config popover geometry above the composer run pill
    /// and repositions the visible steppers' bounds as a side effect so render
    /// and hit-testing always agree.
    pub fn layoutRunConfigPopover(self: *AppState) RunConfigLayout {
        const zero_rect: palette.Rect = .{ .x = 0.0, .y = 0.0, .w = 0.0, .h = 0.0 };
        var layout: RunConfigLayout = .{
            .panel = zero_rect,
            .row_kinds = .{ .reasoning, .speed, .access },
            .title_rects = .{ zero_rect, zero_rect, zero_rect },
            .row_count = 0,
        };
        layout.row_count = self.runConfigVisibleRows(&layout.row_kinds);
        const anchor = self.composer_toolbar_reasoning_rect;
        const composer = self.palette_composer.bounds();
        const pad = theme.scaledUi(14.0);
        const title_h = theme.scaledUi(16.0);
        const title_gap = theme.scaledUi(6.0);
        const row_gap = theme.scaledUi(14.0);
        const width = theme.clampf(composer.w * 0.5, theme.scaledUi(330.0), theme.scaledUi(440.0));

        var height = pad * 2.0;
        var index: usize = 0;
        while (index < layout.row_count) : (index += 1) {
            height += title_h + title_gap + self.run_steppers[@intFromEnum(layout.row_kinds[index])].requiredHeight();
            if (index + 1 < layout.row_count) height += row_gap;
        }

        // Keep the panel inside the composer horizontally; when the composer
        // is narrower than the panel, left-align rather than overflow right.
        const x = @max(composer.x, @min(anchor.x, composer.x + @max(composer.w - width, 0.0)));
        const y = @max(anchor.y - height - theme.scaledUi(8.0), theme.scaledUi(8.0));
        layout.panel = .{ .x = x, .y = y, .w = width, .h = height };

        var cursor_y = y + pad;
        index = 0;
        while (index < layout.row_count) : (index += 1) {
            const stepper = &self.run_steppers[@intFromEnum(layout.row_kinds[index])];
            layout.title_rects[index] = .{ .x = x + pad, .y = cursor_y, .w = @max(width - pad * 2.0, 0.0), .h = title_h };
            cursor_y += title_h + title_gap;
            stepper.setBounds(.{ .x = x + pad, .y = cursor_y, .w = @max(width - pad * 2.0, 0.0), .h = stepper.requiredHeight() });
            cursor_y += stepper.requiredHeight() + row_gap;
        }
        return layout;
    }

    pub fn openRunConfigPopover(self: *AppState) void {
        if (self.projects.items.len == 0) return;
        self.closePaletteModelPicker();
        self.palette_composer.active_menu = null;
        self.palette_composer.hovered_menu_index = null;
        self.syncRunConfigSteppers();
        self.run_config_open = true;
        self.run_config_focused_row = 0;
        _ = self.layoutRunConfigPopover();
        self.palette_composer.focused = false;
        self.composer_focused = false;
        // Arrow keys steer the popover's steppers while it is open.
        self.terminal_focused = false;
        self.noteInteraction();
    }

    pub fn closeRunConfigPopover(self: *AppState) void {
        self.run_config_open = false;
    }

    pub fn toggleRunConfigPopover(self: *AppState) void {
        if (self.run_config_open) {
            self.closeRunConfigPopover();
        } else {
            self.openRunConfigPopover();
        }
    }

    pub fn routePaletteComposerTextInput(self: *AppState, text: []const u8) bool {
        if (self.projects.items.len == 0) return false;
        if (self.palette_model_picker.isOpen()) {
            const handled = self.palette_model_picker.handleInput(self.allocator, .{ .text = text }) catch |err| blk: {
                log.warn("model picker text input failed: {s}", .{@errorName(err)});
                break :blk false;
            };
            if (handled) self.noteInteraction();
            return handled;
        }
        if (self.terminal_focused) return false;
        if (!self.palette_composer.focused) return false;
        const insert_text = self.clampPaletteComposerInsertText(text);
        if (insert_text.len == 0) return true;
        const handled = self.palette_composer.handleInput(self.allocator, .{ .text = insert_text }) catch |err| {
            log.warn("palette composer text input failed: {s}", .{@errorName(err)});
            return false;
        };
        if (handled) {
            self.syncDraftFromPaletteComposer();
            self.noteInteraction();
        }
        return handled;
    }

    pub fn routePaletteComposerKeyDown(self: *AppState, event: *const sdl.KeyboardEvent) bool {
        if (self.projects.items.len == 0) return false;
        // Escape never survives `paletteComposerKeyFromSdl`, so close the
        // composer popovers from the raw SDL event before the conversion.
        if (event.key == .escape or event.scancode == .escape) {
            if (self.palette_model_picker.isOpen()) {
                return self.routePaletteModelPickerKey(.{ .code = .escape });
            }
            if (self.run_config_open) {
                self.closeRunConfigPopover();
                self.noteInteraction();
                return true;
            }
        }
        if (self.terminal_focused) return false;
        // Ctrl+1..9 selects the picker's shortcut-chip rows. Digits never
        // survive `paletteComposerKeyFromSdl`, so read the raw SDL key.
        if (self.palette_model_picker.isOpen()) {
            const key_value = @intFromEnum(event.key);
            const ctrl_held = (keymodBits(event.mod) & sdl.Keymod.ctrl) != 0;
            if (ctrl_held and key_value >= '1' and key_value <= '9') {
                const handled = self.palette_model_picker.selectVisibleOrdinal(self.allocator, @intCast(key_value - '1')) catch |err| blk: {
                    log.warn("model picker shortcut select failed: {s}", .{@errorName(err)});
                    break :blk false;
                };
                if (handled) self.noteInteraction();
                return true;
            }
        }
        const palette_key = paletteComposerKeyFromSdl(event) orelse return false;
        if (self.palette_model_picker.isOpen()) {
            // The picker owns typing while open: navigation keys move the
            // highlight, everything else edits the embedded search field.
            return self.routePaletteModelPickerKey(palette_key);
        }
        if (self.routeRunConfigKey(palette_key)) return true;
        if (palette_key.primary and palette_key.code == .v) {
            runtime_log.diagnostic(
                "palette composer received primary-v focused={} draft_len={d}",
                .{ self.palette_composer.focused, self.currentDraft().len },
            );
            return self.pasteClipboardTextIntoPaletteComposer();
        }
        if (!self.palette_composer.focused) return false;
        if (self.routeSlashCommandPickerKey(palette_key)) return true;
        if (self.handlePaletteComposerNavigationKey(palette_key)) {
            self.noteInteraction();
            return true;
        }
        const handled = self.palette_composer.handleInput(self.allocator, .{ .key = palette_key }) catch |err| {
            log.warn("palette composer key input failed: {s}", .{@errorName(err)});
            return false;
        };
        if (handled) {
            self.syncDraftFromPaletteComposer();
            self.noteInteraction();
        }
        return handled;
    }

    pub fn routePaletteComposerMouseButton(self: *AppState, event: *const sdl.MouseButtonEvent, ui_scale: f32) bool {
        if (self.projects.items.len == 0) return false;
        if (event.button != 1) return false;
        const point = paletteMousePoint(event.x, event.y, ui_scale);
        if (event.down and event.clicks >= 2 and self.palette_composer.textRect().contains(point)) {
            return self.routePaletteComposerMultiClick(point, event.clicks);
        }
        if (event.down and self.routePaletteComposerToolbarOverlayClick(point)) return true;
        const input: palette.ComposerPromptInput = if (event.down)
            .{ .mouse_down = point }
        else
            .{ .mouse_up = point };
        const was_focused = self.palette_composer.focused;
        const handled = self.palette_composer.handleInput(self.allocator, input) catch |err| {
            log.warn("palette composer mouse input failed: {s}", .{@errorName(err)});
            return false;
        };
        self.composer_focused = self.palette_composer.focused;
        if (self.composer_focused) {
            self.terminal_focused = false;
            self.unfocusBrowserPane();
        }
        return handled or was_focused != self.palette_composer.focused;
    }

    fn routePaletteComposerToolbarOverlayClick(self: *AppState, point: palette.draw.Vec2) bool {
        if (!self.composer_toolbar_overlay_valid) return false;
        // Model and run pills open host-owned popovers (rich picker /
        // run-config panel); the composer's built-in dropdowns stay disabled
        // via `setExternalModelMenu` / `setExternalReasoningMenu`.
        if (self.composer_toolbar_model_rect.contains(point)) {
            self.openPaletteModelPicker();
            return true;
        }
        if (self.composer_toolbar_reasoning_rect.contains(point) and self.palette_composer.showReasoningToggle()) {
            self.toggleRunConfigPopover();
            return true;
        }
        return false;
    }

    pub fn routePaletteComposerMouseMotion(self: *AppState, event: *const sdl.MouseMotionEvent, ui_scale: f32) bool {
        if (self.projects.items.len == 0) return false;
        const point = paletteMousePoint(event.x, event.y, ui_scale);
        const input: palette.ComposerPromptInput = if (event.state.left != 0)
            .{ .mouse_drag = point }
        else
            .{ .mouse_move = point };
        const handled = self.palette_composer.handleInput(self.allocator, input) catch |err| {
            log.warn("palette composer mouse motion failed: {s}", .{@errorName(err)});
            return false;
        };
        if (handled) {
            self.syncDraftFromPaletteComposer();
            self.noteInteraction();
        }
        return handled;
    }

    pub fn routePaletteComposerWheel(self: *AppState, event: *const sdl.MouseWheelEvent, ui_scale: f32) bool {
        if (self.projects.items.len == 0) return false;
        const handled = self.palette_composer.handleInput(self.allocator, .{
            .mouse_wheel = .{ .point = paletteMousePoint(event.mouse_x, event.mouse_y, ui_scale), .y = event.y },
        }) catch |err| {
            log.warn("palette composer wheel failed: {s}", .{@errorName(err)});
            return false;
        };
        if (handled) self.noteInteraction();
        return handled;
    }

    /// Composer popovers (model picker, run-config panel) render above the
    /// panes at overlay z, so main.zig routes their pointer input ahead of
    /// the pane/transcript handlers via these entry points.
    pub fn routeComposerPopoverMouseButton(self: *AppState, event: *const sdl.MouseButtonEvent, ui_scale: f32) bool {
        if (self.projects.items.len == 0) return false;
        if (event.button != 1) return false;
        const point = paletteMousePoint(event.x, event.y, ui_scale);
        if (self.routePaletteModelPickerMouseButton(point, event.down, event.clicks)) return true;
        return self.routeRunConfigMouseButton(point, event.down);
    }

    pub fn routeComposerPopoverMouseMotion(self: *AppState, event: *const sdl.MouseMotionEvent, ui_scale: f32) bool {
        if (self.projects.items.len == 0) return false;
        const point = paletteMousePoint(event.x, event.y, ui_scale);
        if (self.routePaletteModelPickerMouseMove(point, event.state.left != 0)) return true;
        return self.routeRunConfigMouseMove(point);
    }

    pub fn routeComposerPopoverWheel(self: *AppState, event: *const sdl.MouseWheelEvent, ui_scale: f32) bool {
        if (self.projects.items.len == 0) return false;
        const point = paletteMousePoint(event.mouse_x, event.mouse_y, ui_scale);
        if (self.routePaletteModelPickerWheel(point, event.y)) return true;
        return self.routeRunConfigWheel(point);
    }

    fn routePaletteModelPickerKey(self: *AppState, key: palette.Key) bool {
        if (!self.palette_model_picker.isOpen()) return false;
        return self.modelPickerInput(.{ .key = key });
    }

    fn routeRunConfigKey(self: *AppState, key: palette.Key) bool {
        if (!self.run_config_open) return false;
        var kinds: [3]RunConfigRowKind = undefined;
        const count = self.runConfigVisibleRows(&kinds);
        if (count == 0) {
            self.closeRunConfigPopover();
            return true;
        }
        if (self.run_config_focused_row >= count) self.run_config_focused_row = count - 1;
        switch (key.code) {
            .up => {
                self.run_config_focused_row = (self.run_config_focused_row + count - 1) % count;
                self.noteInteraction();
                return true;
            },
            .down => {
                self.run_config_focused_row = (self.run_config_focused_row + 1) % count;
                self.noteInteraction();
                return true;
            },
            .enter => {
                self.closeRunConfigPopover();
                self.noteInteraction();
                return true;
            },
            .left, .right, .home, .end => {
                _ = self.layoutRunConfigPopover();
                const stepper = &self.run_steppers[@intFromEnum(kinds[self.run_config_focused_row])];
                const handled = stepper.handleInput(.{ .key = key });
                if (handled) self.noteInteraction();
                return true;
            },
            else => return false,
        }
    }

    fn routeSlashCommandPickerKey(self: *AppState, key: palette.Key) bool {
        if (!self.slashCommandPickerActive()) return false;
        const count = self.slashCommandPickerRowCount();
        if (count == 0) {
            if (key.code == .escape) return self.closeSlashCommandPicker();
            return false;
        }
        switch (key.code) {
            .up => {
                self.composer_slash_selected = if (self.composer_slash_selected == 0) count - 1 else self.composer_slash_selected - 1;
                self.noteInteraction();
                self.markDirty();
                return true;
            },
            .down => {
                self.composer_slash_selected = (self.composer_slash_selected + 1) % count;
                self.noteInteraction();
                self.markDirty();
                return true;
            },
            .enter => return self.activateSlashCommandPickerSelection(),
            .escape => return self.closeSlashCommandPicker(),
            else => return false,
        }
    }

    fn routePaletteModelPickerMouseButton(self: *AppState, point: palette.draw.Vec2, down: bool, clicks: u8) bool {
        if (!self.palette_model_picker.isOpen()) return false;
        // Clicking the run pill swaps popovers in one click: dismiss the
        // picker and let the toolbar overlay handler open the run config.
        if (down and self.composer_toolbar_overlay_valid and self.composer_toolbar_reasoning_rect.contains(point)) {
            self.closePaletteModelPicker();
            return false;
        }
        const input: palette.RichPickerInput = if (down)
            .{ .mouse_down = .{ .point = point, .clicks = clicks } }
        else
            .{ .mouse_up = point };
        return self.modelPickerInput(input);
    }

    fn routePaletteModelPickerMouseMove(self: *AppState, point: palette.draw.Vec2, dragging: bool) bool {
        if (!self.palette_model_picker.isOpen()) return false;
        return self.modelPickerInput(if (dragging)
            .{ .mouse_drag = point }
        else
            .{ .mouse_move = point });
    }

    fn routePaletteModelPickerWheel(self: *AppState, point: palette.draw.Vec2, y: f32) bool {
        if (!self.palette_model_picker.isOpen()) return false;
        return self.modelPickerInput(.{ .mouse_wheel = .{ .point = point, .y = y } });
    }

    fn routeRunConfigMouseButton(self: *AppState, point: palette.draw.Vec2, down: bool) bool {
        if (!self.run_config_open) return false;
        if (!down) return false;
        const layout = self.layoutRunConfigPopover();
        var index: usize = 0;
        while (index < layout.row_count) : (index += 1) {
            const stepper = &self.run_steppers[@intFromEnum(layout.row_kinds[index])];
            if (stepper.handleInput(.{ .mouse_down = point })) {
                self.run_config_focused_row = index;
                self.noteInteraction();
                return true;
            }
        }
        if (layout.panel.contains(point)) return true;
        self.closeRunConfigPopover();
        self.noteInteraction();
        // Clicking the model pill swaps popovers in one click: fall through
        // so the toolbar overlay handler opens the model picker. Any other
        // outside click is swallowed so the press does not also activate
        // whatever sits underneath the popover.
        if (self.composer_toolbar_overlay_valid and self.composer_toolbar_model_rect.contains(point)) return false;
        return true;
    }

    fn routeRunConfigMouseMove(self: *AppState, point: palette.draw.Vec2) bool {
        if (!self.run_config_open) return false;
        const layout = self.layoutRunConfigPopover();
        var hovered = false;
        var index: usize = 0;
        while (index < layout.row_count) : (index += 1) {
            const stepper = &self.run_steppers[@intFromEnum(layout.row_kinds[index])];
            if (stepper.handleInput(.{ .mouse_move = point })) hovered = true;
        }
        return hovered or layout.panel.contains(point);
    }

    fn routeRunConfigWheel(self: *AppState, point: palette.draw.Vec2) bool {
        if (!self.run_config_open) return false;
        const layout = self.layoutRunConfigPopover();
        return layout.panel.contains(point);
    }

    fn handlePaletteComposerNavigationKey(self: *AppState, key: palette.Key) bool {
        if (key.primary and key.code == .a) {
            self.palette_composer.selection_anchor = 0;
            self.palette_composer.selection_focus = self.palette_composer.text().len;
            self.palette_composer.cursor = self.palette_composer.text().len;
            self.ensurePaletteComposerCursorVisible();
            return true;
        }

        if (key.code != .up and key.code != .down) return false;
        const text = self.palette_composer.text();
        const metrics = paletteComposerTextFontMetrics(theme.scaledUi(PALETTE_COMPOSER_FONT_SIZE));
        const text_rect = self.palette_composer.textRect();
        const cell = palette.TextLayout.visualCellForOffset(text, self.palette_composer.cursor, metrics, text_rect.w, true);
        const target_row = switch (key.code) {
            .up => if (cell.row == 0) 0 else cell.row - 1,
            .down => cell.row + 1,
            else => unreachable,
        };
        const next = palette.TextLayout.offsetAtVisualCell(text, target_row, cell.x, metrics, text_rect.w, true);
        self.movePaletteComposerCursor(next, key.shift);
        return true;
    }

    fn routePaletteComposerMultiClick(self: *AppState, point: palette.draw.Vec2, clicks: u8) bool {
        _ = self.palette_composer.handleInput(self.allocator, .{ .mouse_down = point }) catch |err| {
            log.warn("palette composer mouse input failed: {s}", .{@errorName(err)});
            return false;
        };
        const text = self.palette_composer.text();
        const offset = self.palette_composer.cursor;
        const range = if (clicks >= 3) blk: {
            const start = palette.input_selection.lineStart(text, offset);
            var end = palette.input_selection.lineEnd(text, offset);
            if (end < text.len) end += 1;
            break :blk palette.input_selection.Range{ .start = start, .end = end };
        } else palette.input_selection.wordRangeAt(text, offset);
        self.palette_composer.selection_anchor = range.start;
        self.palette_composer.selection_focus = range.end;
        self.palette_composer.cursor = range.end;
        self.palette_composer.dragging_selection = false;
        self.composer_focused = true;
        self.terminal_focused = false;
        self.unfocusBrowserPane();
        self.ensurePaletteComposerCursorVisible();
        self.noteInteraction();
        return true;
    }

    fn movePaletteComposerCursor(self: *AppState, next: usize, extend_selection: bool) void {
        const old = self.palette_composer.cursor;
        self.palette_composer.cursor = @min(next, self.palette_composer.text().len);
        if (extend_selection) {
            if (self.palette_composer.selection_anchor == null) self.palette_composer.selection_anchor = old;
            self.palette_composer.selection_focus = self.palette_composer.cursor;
        } else {
            self.palette_composer.selection_anchor = null;
            self.palette_composer.selection_focus = null;
        }
        self.ensurePaletteComposerCursorVisible();
    }

    fn ensurePaletteComposerCursorVisible(self: *AppState) void {
        const text_rect = self.palette_composer.textRect();
        const cursor = self.palette_composer.cursorRect();
        const bottom = text_rect.y + text_rect.h;
        if (cursor.y < text_rect.y) {
            self.palette_composer.setScrollY(self.palette_composer.scrollY() - (text_rect.y - cursor.y));
        } else if (cursor.y + cursor.h > bottom) {
            self.palette_composer.setScrollY(self.palette_composer.scrollY() + cursor.y + cursor.h - bottom);
        }
    }

    pub fn setComposerInputBounds(self: *AppState, input_min: [2]f32, input_max: [2]f32) void {
        self.composer_input_bounds_valid = true;
        self.composer_input_min = input_min;
        self.composer_input_max = input_max;
    }

    pub fn setComposerDraftImageClearRect(self: *AppState, rect: ?palette.Rect) void {
        self.setComposerDraftImageClearRectAt(rect, 0);
    }

    pub fn setComposerDraftImageClearRectAt(self: *AppState, rect: ?palette.Rect, index: usize) void {
        if (rect) |value| {
            self.composer_draft_image_clear_valid = true;
            self.composer_draft_image_clear_rect = value;
            self.composer_draft_image_clear_index = index;
            if (self.composer_draft_image_clear_count < self.composer_draft_image_clear_rects.len) {
                const slot = self.composer_draft_image_clear_count;
                self.composer_draft_image_clear_rects[slot] = value;
                self.composer_draft_image_clear_indices[slot] = index;
                self.composer_draft_image_clear_count += 1;
            }
        } else {
            self.composer_draft_image_clear_valid = false;
            self.composer_draft_image_clear_rect = .{ .x = 0.0, .y = 0.0, .w = 0.0, .h = 0.0 };
            self.composer_draft_image_clear_index = 0;
            self.composer_draft_image_clear_count = 0;
        }
    }

    /// Records the pinned follow-up card hit rect for this frame (or clears it).
    /// Called from the chat workspace render so mouse routing can target the pin.
    pub fn setFollowupPinRect(self: *AppState, rect: ?palette.Rect) void {
        if (rect) |value| {
            self.followup_pin_valid = true;
            self.followup_pin_rect = value;
        } else {
            self.followup_pin_valid = false;
            self.followup_pin_rect = .{ .x = 0.0, .y = 0.0, .w = 0.0, .h = 0.0 };
        }
    }

    /// Routes a click on the pinned follow-up card. A double-click (clicks >= 2)
    /// pulls the queued prompt back into the composer for editing; a single click
    /// is swallowed so it does not fall through to the composer/transcript.
    pub fn handleFollowupPinMouseButton(self: *AppState, x: f32, y: f32, down: bool, clicks: u8) bool {
        if (!self.followup_pin_valid) return false;
        const rect = self.followup_pin_rect;
        if (x < rect.x or y < rect.y or x > rect.x + rect.w or y > rect.y + rect.h) return false;
        if (down and clicks >= 2) self.editPendingFollowup();
        return true;
    }

    /// Pulls the queued/steered follow-up back into the composer so a long-waiting
    /// queued message can be revised. Removes the pin (it is no longer queued); the
    /// user re-queues with Tab or sends normally. Refuses to clobber an in-progress
    /// draft, and ignores Codex steering already accepted inline (`.sent_inline`).
    pub fn editPendingFollowup(self: *AppState) void {
        if (self.projects.items.len == 0) return;
        const thread = self.currentThreadMutable();
        const send_state = thread.send_state;

        send_state.mutex.lock();
        const pending = send_state.pending_followup orelse {
            send_state.mutex.unlock();
            return;
        };
        if (pending.state == .sent_inline) {
            send_state.mutex.unlock();
            return;
        }

        const current = thread.currentDraft();
        if (std.mem.trim(u8, current, &std.ascii.whitespace).len != 0) {
            send_state.mutex.unlock();
            self.setSidebarNotice("Clear the composer to edit the queued message.");
            return;
        }

        const prompt_copy = self.allocator.dupe(u8, pending.prompt) catch {
            send_state.mutex.unlock();
            self.setSidebarNotice("Failed to load the queued message.");
            return;
        };
        defer self.allocator.free(prompt_copy);
        freePendingFollowup(self.allocator, &send_state.pending_followup);
        send_state.pending_followup_signal_sent = false;
        send_state.mutex.unlock();

        self.setDraft(prompt_copy);
        self.resetComposerInputWidget();
        self.palette_composer.focused = true;
        self.composer_focused = true;
        self.setFollowupPinRect(null);
        self.markDirty();
        self.setSidebarNotice("Editing queued message. Press Tab to queue it again.");
    }

    pub fn handleComposerDraftImageClearMouseButton(self: *AppState, x: f32, y: f32, down: bool) bool {
        if (self.projects.items.len == 0) return false;
        if (!self.composer_draft_image_clear_valid) return false;
        var i: usize = self.composer_draft_image_clear_count;
        while (i > 0) {
            i -= 1;
            const rect = self.composer_draft_image_clear_rects[i];
            if (x < rect.x or y < rect.y or x > rect.x + rect.w or y > rect.y + rect.h) continue;
            if (!down) {
                self.clearCurrentDraftImageAt(self.composer_draft_image_clear_indices[i]);
            }
            return true;
        }
        return false;
    }

    fn setCurrentThreadProvider(self: *AppState, provider: Provider) void {
        const thread = self.currentThreadMutable();
        if (thread.provider == provider) return;

        thread.provider = provider;
        if (thread.provider_thread_id) |thread_id| self.allocator.free(thread_id);
        thread.provider_thread_id = null;
        if (thread.model_ref) |model_ref| self.allocator.free(model_ref);
        thread.model_ref = self.allocator.dupeZ(u8, composerDefaultModelRef(self, provider)) catch null;
        thread.reasoning_effort = if (provider == .codex) DEFAULT_CODEX_REASONING_EFFORT else null;
        if (thread.opencode_reasoning_variant) |v| {
            self.allocator.free(v);
            thread.opencode_reasoning_variant = null;
        }
        thread.fast_mode = .off;
        self.markDirty();
    }

    pub fn navigateBrowserHistory(self: *AppState, delta: i32) void {
        if (self.navigatePersistedBrowserHistory(delta)) return;
        const result = if (delta < 0)
            self.browser_state.controller.goBack()
        else
            self.browser_state.controller.goForward();
        result catch |err| {
            log.warn("failed to navigate browser history: {s}", .{@errorName(err)});
            self.browser_state.setLastError("Failed to navigate browser history.") catch {};
            return;
        };
        self.markDirty();
    }

    pub fn reloadBrowser(self: *AppState) void {
        self.browser_state.controller.reload() catch |err| {
            log.warn("failed to reload browser: {s}", .{@errorName(err)});
            self.browser_state.setLastError("Failed to reload browser.") catch {};
            return;
        };
        self.setSidebarNotice("Browser reload requested.");
        self.markDirty();
    }

    pub fn selectAllBrowserFocusedElement(self: *AppState) void {
        const script =
            \\(function(){
            \\  let el=window.__verdeInputTarget;
            \\  if(el&&!el.isConnected)el=null;
            \\  const resolve=(node)=>{
            \\    if(!node)return null;
            \\    if(node.isContentEditable||node instanceof HTMLInputElement||node instanceof HTMLTextAreaElement)return node;
            \\    return (node.closest&&node.closest('input,textarea,[contenteditable="true"]'))||null;
            \\  };
            \\  el=resolve(el)||resolve(document.activeElement);
            \\  if(!el)return false;
            \\  window.__verdeInputTarget=el;
            \\  if(el.focus)el.focus({preventScroll:true});
            \\  if(el instanceof HTMLInputElement||el instanceof HTMLTextAreaElement){
            \\    if(el.setSelectionRange)el.setSelectionRange(0,el.value.length);
            \\    return true;
            \\  }
            \\  if(el.isContentEditable){
            \\    const range=document.createRange();
            \\    range.selectNodeContents(el);
            \\    const selection=window.getSelection();
            \\    if(!selection)return false;
            \\    selection.removeAllRanges();
            \\    selection.addRange(range);
            \\    return true;
            \\  }
            \\  return false;
            \\})()
        ;
        self.browser_state.expectSuppressedEvalResult();
        self.browser_state.controller.eval(script) catch |err| {
            log.warn("failed to select browser focused element text: {s}", .{@errorName(err)});
            return;
        };
        self.markDirty();
    }

    pub fn pasteBrowserTextIntoFocusedElement(self: *AppState, text: []const u8) void {
        var out: std.Io.Writer.Allocating = .init(self.allocator);
        defer out.deinit();
        var stringify: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
        stringify.write(text) catch |err| {
            log.warn("failed to encode browser paste text: {s}", .{@errorName(err)});
            return;
        };
        const encoded = out.written();
        const script = std.fmt.allocPrint(self.allocator,
            \\(function(){{
            \\  const text={s};
            \\  let el=window.__verdeInputTarget;
            \\  if(el&&!el.isConnected)el=null;
            \\  const resolve=(node)=>{{
            \\    if(!node)return null;
            \\    if(node.isContentEditable||node instanceof HTMLInputElement||node instanceof HTMLTextAreaElement)return node;
            \\    return (node.closest&&node.closest('input,textarea,[contenteditable="true"]'))||null;
            \\  }};
            \\  el=resolve(el)||resolve(document.activeElement);
            \\  if(!el)return false;
            \\  window.__verdeInputTarget=el;
            \\  if(el.focus)el.focus({{preventScroll:true}});
            \\  if(el.isContentEditable){{
            \\    document.execCommand('insertText',false,text);
            \\    return true;
            \\  }}
            \\  if(el instanceof HTMLInputElement||el instanceof HTMLTextAreaElement){{
            \\    const start=el.selectionStart??el.value.length;
            \\    const end=el.selectionEnd??el.value.length;
            \\    el.value=el.value.slice(0,start)+text+el.value.slice(end);
            \\    const next=start+text.length;
            \\    if(el.setSelectionRange)el.setSelectionRange(next,next);
            \\    el.dispatchEvent(new InputEvent('input',{{bubbles:true,data:text,inputType:'insertFromPaste'}}));
            \\    return true;
            \\  }}
            \\  return false;
            \\}})()
        , .{encoded}) catch |err| {
            log.warn("failed to build browser paste script: {s}", .{@errorName(err)});
            return;
        };
        defer self.allocator.free(script);
        self.browser_state.expectSuppressedEvalResult();
        self.browser_state.controller.eval(script) catch |err| {
            log.warn("failed to paste browser text: {s}", .{@errorName(err)});
            return;
        };
        self.markDirty();
    }

    pub fn copyBrowserFocusedSelection(self: *AppState, cut: bool) void {
        const script = if (cut)
            \\(function(){
            \\  const post=(text)=>{
            \\    const payload=JSON.stringify({source:'verde-browser-clipboard',text:String(text||''),cut:true});
            \\    if(window.__VERDE_BROWSER_IPC__&&typeof window.__VERDE_BROWSER_IPC__.postMessage==='function'){window.__VERDE_BROWSER_IPC__.postMessage(payload);return;}
            \\    if(window.__VERDE_CEF_IPC__&&typeof window.__VERDE_CEF_IPC__.postMessage==='function'){window.__VERDE_CEF_IPC__.postMessage(payload);return;}
            \\    if(window.verde&&typeof window.verde.postMessage==='function'){window.verde.postMessage(payload);return;}
            \\    if(window.webkit&&window.webkit.messageHandlers&&window.webkit.messageHandlers.verde){window.webkit.messageHandlers.verde.postMessage(payload);}
            \\  };
            \\  let el=window.__verdeInputTarget;
            \\  if(el&&!el.isConnected)el=null;
            \\  const resolve=(node)=>{
            \\    if(!node)return null;
            \\    if(node.isContentEditable||node instanceof HTMLInputElement||node instanceof HTMLTextAreaElement)return node;
            \\    return (node.closest&&node.closest('input,textarea,[contenteditable="true"]'))||null;
            \\  };
            \\  el=resolve(el)||resolve(document.activeElement);
            \\  let text='';
            \\  if(el instanceof HTMLInputElement||el instanceof HTMLTextAreaElement){
            \\    const start=el.selectionStart??0;
            \\    const end=el.selectionEnd??0;
            \\    text=el.value.slice(start,end);
            \\    if(text.length>0){
            \\      el.value=el.value.slice(0,start)+el.value.slice(end);
            \\      if(el.setSelectionRange)el.setSelectionRange(start,start);
            \\      el.dispatchEvent(new InputEvent('input',{bubbles:true,inputType:'deleteByCut'}));
            \\    }
            \\  }else{
            \\    text=String(window.getSelection?.()||'');
            \\    if(text.length>0&&el&&el.isContentEditable){document.execCommand('delete',false);}
            \\  }
            \\  window.__verdeClipboardSelection=text;
            \\  post(text);
            \\  return text.length>0;
            \\})()
        else
            \\(function(){
            \\  const post=(text)=>{
            \\    const payload=JSON.stringify({source:'verde-browser-clipboard',text:String(text||''),cut:false});
            \\    if(window.__VERDE_BROWSER_IPC__&&typeof window.__VERDE_BROWSER_IPC__.postMessage==='function'){window.__VERDE_BROWSER_IPC__.postMessage(payload);return;}
            \\    if(window.__VERDE_CEF_IPC__&&typeof window.__VERDE_CEF_IPC__.postMessage==='function'){window.__VERDE_CEF_IPC__.postMessage(payload);return;}
            \\    if(window.verde&&typeof window.verde.postMessage==='function'){window.verde.postMessage(payload);return;}
            \\    if(window.webkit&&window.webkit.messageHandlers&&window.webkit.messageHandlers.verde){window.webkit.messageHandlers.verde.postMessage(payload);}
            \\  };
            \\  let el=window.__verdeInputTarget;
            \\  if(el&&!el.isConnected)el=null;
            \\  const resolve=(node)=>{
            \\    if(!node)return null;
            \\    if(node.isContentEditable||node instanceof HTMLInputElement||node instanceof HTMLTextAreaElement)return node;
            \\    return (node.closest&&node.closest('input,textarea,[contenteditable="true"]'))||null;
            \\  };
            \\  el=resolve(el)||resolve(document.activeElement);
            \\  let text='';
            \\  if(el instanceof HTMLInputElement||el instanceof HTMLTextAreaElement){
            \\    text=el.value.slice(el.selectionStart??0,el.selectionEnd??0);
            \\  }else{
            \\    text=String(window.getSelection?.()||'');
            \\  }
            \\  window.__verdeClipboardSelection=text;
            \\  post(text);
            \\  return text.length>0;
            \\})()
        ;
        self.browser_state.expectSuppressedEvalResult();
        self.browser_state.controller.eval(script) catch |err| {
            log.warn("failed to capture browser focused selection: {s}", .{@errorName(err)});
            return;
        };
        self.markDirty();
    }

    fn copyBrowserEvalResultToClipboard(self: *AppState, result: []const u8) void {
        if (result.len == 0) return;
        const z = self.allocator.dupeZ(u8, result) catch |err| {
            log.warn("failed to copy browser selection: {s}", .{@errorName(err)});
            return;
        };
        defer self.allocator.free(z);
        sdl.setClipboardText(z) catch |err| {
            log.warn("failed to set browser selection clipboard text: {s}", .{@errorName(err)});
            return;
        };
        self.setSidebarNotice("Browser selection copied.");
    }

    fn setCurrentThreadModelRef(self: *AppState, value: ?[:0]const u8) void {
        const thread = self.currentThreadMutable();
        if (thread.model_ref) |existing| {
            if (value) |next| {
                if (std.mem.eql(u8, existing, next)) return;
            }
            self.allocator.free(existing);
            thread.model_ref = null;
        } else if (value == null) {
            return;
        }

        thread.model_ref = if (value) |next| self.allocator.dupeZ(u8, next) catch null else null;
        self.normalizeOpencodeReasoningVariant(thread);
        if (thread.provider == .cursor) {
            if (thread.opencode_reasoning_variant) |v| {
                self.allocator.free(v);
                thread.opencode_reasoning_variant = null;
            }
            if (self.cursorModelOptionForRef(thread.model_ref)) |opt| {
                if (!opt.cursor_fast_supported) thread.fast_mode = .off;
            } else {
                thread.fast_mode = .off;
            }
        }
        self.markDirty();
    }

    fn composerModelIndex(self: *const AppState, provider: Provider, model_ref: ?[:0]const u8) ?usize {
        const active = model_ref orelse composerDefaultModelRef(self, provider);
        const options = composerModelOptions(self, provider);
        for (options, 0..) |option, index| {
            if (option.value) |value| {
                if (std.mem.eql(u8, active, value)) return index;
            }
        }
        return if (options.len > 0) 0 else null;
    }

    fn composerReasoningIndexForOptions(options: []const ReasoningOption, value: ?ReasoningEffort) ?usize {
        for (options, 0..) |option, index| {
            if (value == null and option.value == null) return index;
            if (value != null and option.value != null and value.? == option.value.?) return index;
        }
        return null;
    }

    fn composerReasoningIndexForThread(self: *const AppState, thread: *const ChatThread) ?usize {
        if (thread.provider == .codex) {
            return composerReasoningIndexForOptions(CODEX_REASONING_OPTIONS[0..], thread.reasoning_effort);
        }
        if (thread.provider == .claude) {
            const rows = self.opencode_reasoning_menu.items;
            for (rows, 0..) |row, i| {
                if (thread.reasoning_effort == null and row.variant == null) return i;
                if (thread.reasoning_effort) |effort| {
                    if (row.variant) |variant| {
                        if (std.mem.eql(u8, @tagName(effort), variant)) return i;
                    }
                }
            }
            return if (rows.len > 0) 0 else null;
        }
        const rows = self.opencode_reasoning_menu.items;
        for (rows, 0..) |row, i| {
            const matches = blk: {
                if (thread.opencode_reasoning_variant == null and row.variant == null) break :blk true;
                if (thread.opencode_reasoning_variant) |v| {
                    if (row.variant) |rv| break :blk std.mem.eql(u8, v, rv);
                }
                break :blk false;
            };
            if (matches) return i;
        }
        return if (rows.len > 0) 0 else null;
    }

    fn composerFastModeIndex(value: FastMode) ?usize {
        for (CODEX_FAST_MODE_OPTIONS, 0..) |option, index| {
            if (option.value == value) return index;
        }
        return null;
    }

    fn composerAccessModeIndex(value: AccessMode) ?usize {
        for (CODEX_ACCESS_MODE_OPTIONS, 0..) |option, index| {
            if (option.value == value) return index;
        }
        return null;
    }

    pub fn handleComposerWheel(self: *AppState, event: *const sdl.MouseWheelEvent) bool {
        if (self.projects.items.len == 0) return false;
        if (!self.composer_input_bounds_valid) return false;
        if (event.mouse_x < self.composer_input_min[0] or event.mouse_x > self.composer_input_max[0]) return false;
        if (event.mouse_y < self.composer_input_min[1] or event.mouse_y > self.composer_input_max[1]) return false;

        self.composer_overlay_scroll_y = @max(0.0, self.composer_overlay_scroll_y - event.y * 48.0);
        self.composer_overlay_follow_cursor = false;
        self.noteInteraction();
        return true;
    }

    pub fn composerOverlayScrollY(self: *const AppState) f32 {
        return self.composer_overlay_scroll_y;
    }

    pub fn setComposerOverlayScrollY(self: *AppState, value: f32) void {
        self.composer_overlay_scroll_y = @max(value, 0.0);
    }

    pub fn shouldComposerOverlayFollowCursor(self: *AppState, cursor_pos: usize, draft_len: usize) bool {
        if (cursor_pos != self.composer_overlay_last_cursor_pos or draft_len != self.composer_overlay_last_draft_len) {
            self.composer_overlay_follow_cursor = true;
        }
        self.composer_overlay_last_cursor_pos = cursor_pos;
        self.composer_overlay_last_draft_len = draft_len;
        return self.composer_overlay_follow_cursor;
    }

    fn setDraft(self: *AppState, value: []const u8) void {
        self.currentProjectMutable().setDraft(value);
        self.markDirty();
    }

    fn clearDraft(self: *AppState) void {
        self.currentProjectMutable().clearDraft();
        self.markDirty();
    }

    fn resetComposerInputWidget(self: *AppState) void {
        self.composer_input_nonce +%= 1;
        self.composer_overlay_scroll_y = 0.0;
        self.composer_overlay_follow_cursor = true;
        self.composer_overlay_last_cursor_pos = 0;
        self.composer_overlay_last_draft_len = 0;
        const callbacks = self.palette_composer.callbacks;
        self.palette_composer.setCallbacks(.{});
        defer self.palette_composer.setCallbacks(callbacks);
        self.palette_composer.setText(self.allocator, self.currentDraft()) catch |err| {
            log.warn("failed to reset palette composer draft: {s}", .{@errorName(err)});
        };
    }

    pub fn updateFileSearch(self: *AppState) void {
        if (self.projects.items.len == 0) {
            self.clearFileSearch();
            return;
        }

        const draft = self.currentDraft();
        const token = trailingFileSearchToken(draft) orelse {
            self.clearFileSearch();
            return;
        };

        const project_path = self.currentProject().path;
        self.ensureFileSearchFinder(project_path) catch {
            self.clearFileSearch();
            self.setSidebarNotice("Failed to initialize file search.");
            return;
        };

        self.file_search_state.visible = true;
        self.file_search_state.token = token;

        const query = draft[token.query_start..token.end];
        const query_changed = self.file_search_state.last_query == null or
            !std.mem.eql(u8, self.file_search_state.last_query.?, query);
        if (!query_changed) return;

        self.file_search_state.clearQuery(self.allocator);
        self.file_search_state.last_query = self.allocator.dupe(u8, query) catch {
            self.clearFileSearch();
            return;
        };

        var search_results = self.file_search_state.finder.?.search(self.allocator, query, 8) catch {
            self.file_search_state.clearResults(self.allocator);
            self.setSidebarNotice("File search failed.");
            return;
        };
        defer search_results.deinit(self.allocator);

        self.file_search_state.setResults(self.allocator, &search_results) catch {
            self.file_search_state.clearResults(self.allocator);
            self.setSidebarNotice("Failed to update file search results.");
        };
    }

    pub fn hasActiveFileSearch(self: *const AppState) bool {
        return self.file_search_state.visible;
    }

    pub fn fileSearchResults(self: *const AppState) []const FileSearchResult {
        return self.file_search_state.results.items;
    }

    pub fn fileSearchIsScanning(self: *const AppState) bool {
        if (self.file_search_state.finder) |*finder| {
            return finder.isScanning();
        }
        return false;
    }

    pub fn fileSearchSelectedIndex(self: *const AppState) usize {
        if (self.file_search_state.results.items.len == 0) return 0;
        return @min(self.file_search_state.selected_index, self.file_search_state.results.items.len - 1);
    }

    pub fn moveFileSearchSelection(self: *AppState, delta: i32) bool {
        if (!self.file_search_state.visible) return false;
        const count = self.file_search_state.results.items.len;
        if (count == 0) return false;

        const current: i32 = @intCast(self.fileSearchSelectedIndex());
        const max_index: i32 = @intCast(count - 1);
        const next = std.math.clamp(current + delta, 0, max_index);
        if (next == current) return true;
        self.file_search_state.selected_index = @intCast(next);
        self.file_search_state.ensure_selection_visible = true;
        return true;
    }

    pub fn consumeFileSearchEnsureSelectionVisible(self: *AppState) bool {
        const should_scroll = self.file_search_state.ensure_selection_visible;
        self.file_search_state.ensure_selection_visible = false;
        return should_scroll;
    }

    pub fn acceptPrimaryFileSearchResult(self: *AppState) bool {
        return self.selectFileSearchResult(self.fileSearchSelectedIndex());
    }

    pub fn selectFileSearchResult(self: *AppState, index: usize) bool {
        if (!self.file_search_state.visible) return false;
        const token = self.file_search_state.token orelse return false;
        if (index >= self.file_search_state.results.items.len) return false;

        const draft = self.currentDraft();
        const choice = self.file_search_state.results.items[index];
        const replacement = std.fmt.allocPrint(self.allocator, "@{s} ", .{choice.relative_path}) catch return false;
        defer self.allocator.free(replacement);

        const next_draft = std.fmt.allocPrint(
            self.allocator,
            "{s}{s}{s}",
            .{
                draft[0..token.at_start],
                replacement,
                draft[token.end..],
            },
        ) catch return false;
        defer self.allocator.free(next_draft);

        self.setDraft(next_draft);
        if (self.file_search_state.last_query) |query| {
            if (self.file_search_state.finder) |*finder| {
                finder.trackQuery(self.allocator, query, choice.path);
            }
        }
        self.clearFileSearch();
        return true;
    }

    pub fn markDirty(self: *AppState) void {
        self.noteInteraction();
        self.dirty = true;
        self.last_dirty_at_ms = unixTimestampMs();
    }

    pub fn noteInteraction(self: *AppState) void {
        self.last_interaction_at_ms = unixTimestampMs();
    }

    pub fn requestTranscriptScrollToBottom(self: *AppState) void {
        if (self.projects.items.len == 0) return;
        // Drop any saved offset so the next transcript layout uses the fresh tail height
        // (e.g. right after appending the user message and starting a stream).
        self.currentThreadMutable().transcript_scroll_valid = false;
        self.transcript_auto_follow_pending = true;
        self.scroll_transcript_to_bottom_frames = 8;
        self.pending_transcript_scroll_px = 0;
        self.pending_transcript_page_steps = 0;
    }

    pub fn requestTranscriptLineScroll(self: *AppState, delta: i16) void {
        if (delta == 0) return;
        self.noteInteraction();
        self.transcript_auto_follow_pending = false;
        self.scroll_transcript_to_bottom_frames = 0;
        self.pending_transcript_scroll_px += @as(f32, @floatFromInt(delta)) * theme.scaledUi(TRANSCRIPT_KEYBOARD_LINE_PX);
        self.markDirty();
    }

    pub fn requestTranscriptPageScroll(self: *AppState, delta: i16) void {
        if (delta == 0) return;
        self.noteInteraction();
        self.transcript_auto_follow_pending = false;
        self.scroll_transcript_to_bottom_frames = 0;
        const next = @as(i32, self.pending_transcript_page_steps) + @as(i32, delta);
        self.pending_transcript_page_steps = @intCast(std.math.clamp(next, -12, 12));
        self.markDirty();
    }

    pub fn importDirectoryDraft(self: *const AppState) []const u8 {
        return std.mem.sliceTo(self.import_path_storage[0..], 0);
    }

    pub fn importPathBuffer(self: *AppState) [:0]u8 {
        return self.import_path_storage[0 .. self.import_path_storage.len - 1 :0];
    }

    pub fn clearImportPath(self: *AppState) void {
        self.import_path_storage[0] = 0;
    }

    fn setImportPath(self: *AppState, value: []const u8) void {
        @memset(&self.import_path_storage, 0);
        const len = @min(value.len, self.import_path_storage.len - 1);
        @memcpy(self.import_path_storage[0..len], value[0..len]);
    }

    fn setImportPathWithTrailingSeparator(self: *AppState, value: []const u8) !void {
        if (value.len > 0 and value[value.len - 1] == std.fs.path.sep) {
            self.setImportPath(value);
            return;
        }
        const with_sep = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ value, std.fs.path.sep_str });
        defer self.allocator.free(with_sep);
        self.setImportPath(with_sep);
    }

    fn renameInput(self: *const AppState) []const u8 {
        return std.mem.sliceTo(self.rename_storage[0..], 0);
    }

    pub fn renameInputPublic(self: *const AppState) []const u8 {
        return self.renameInput();
    }

    pub fn renameBuffer(self: *AppState) [:0]u8 {
        return self.rename_storage[0 .. self.rename_storage.len - 1 :0];
    }

    pub fn syncRenameBuffer(self: *AppState) void {
        if (self.projects.items.len == 0) {
            self.rename_storage[0] = 0;
            return;
        }
        @memset(&self.rename_storage, 0);
        const label = self.currentProject().label;
        const len = @min(label.len, self.rename_storage.len - 1);
        @memcpy(self.rename_storage[0..len], label[0..len]);
    }

    pub fn sidebarNotice(self: *const AppState) []const u8 {
        return std.mem.sliceTo(self.sidebar_notice_storage[0..], 0);
    }

    pub fn setSidebarNotice(self: *AppState, value: []const u8) void {
        @memset(&self.sidebar_notice_storage, 0);
        const len = @min(value.len, self.sidebar_notice_storage.len - 1);
        @memcpy(self.sidebar_notice_storage[0..len], value[0..len]);
        self.markDirty();
    }

    fn clearThreadImportThreads(self: *AppState) void {
        for (self.thread_import_threads.items) |thread| {
            thread.deinit(self.allocator);
        }
        self.thread_import_threads.clearRetainingCapacity();
        self.thread_import_selected_index = null;
        self.thread_import_hover_index = null;
    }

    fn clearHerdrProfileSummaries(self: *AppState) void {
        for (self.herdr_profile_summaries.items) |profile| {
            profile.deinit(self.allocator);
        }
        self.herdr_profile_summaries.clearRetainingCapacity();
        self.herdr_profile_selected_index = null;
        self.herdr_profile_hover_index = null;
    }

    pub fn flushIfDirty(self: *AppState) void {
        if (!self.dirty) return;
        const now = unixTimestampMs();
        if (now - self.last_dirty_at_ms < SAVE_DEBOUNCE_MS) return;
        if (now - self.last_interaction_at_ms < SAVE_DEBOUNCE_MS) return;

        self.flushDirtyNow();
    }

    fn flushDirtyBlocking(self: *AppState) void {
        if (!self.dirty) return;
        self.storage.save(self) catch |err| {
            log.err("failed to save native state: {s}", .{@errorName(err)});
            return;
        };
        self.dirty = false;
    }

    fn flushDirtyNow(self: *AppState) void {
        if (!self.dirty) return;

        var persisted = self.buildPersistedState(std.heap.page_allocator) catch |err| {
            log.err("failed to snapshot native state: {s}", .{@errorName(err)});
            return;
        };
        errdefer persisted.deinit();

        const pref_path = std.heap.page_allocator.dupe(u8, self.storage.pref_path) catch |err| {
            log.err("failed to prepare async native state save: {s}", .{@errorName(err)});
            return;
        };
        errdefer std.heap.page_allocator.free(pref_path);

        const worker = std.Thread.spawn(.{}, savePersistedStateWorker, .{ pref_path, persisted }) catch |err| {
            log.err("failed to start async native state save: {s}", .{@errorName(err)});
            return;
        };
        worker.detach();
        self.dirty = false;
    }

    pub fn reloadFromStorage(self: *AppState) !void {
        _ = self.pollSend();
        if (self.hasAnyPendingSends()) {
            self.setSidebarNotice("Finish running provider requests before refreshing from disk.");
            return;
        }
        self.flushDirtyBlocking();
        self.clearProjects();

        if (try self.storage.load(self.allocator)) |persisted_value| {
            var persisted = persisted_value;
            defer persisted.deinit();
            try self.applyPersisted(persisted.value);
        } else {
            try self.seedDefaultState();
        }
        self.refreshOpencodeModelOptionsCacheAsync();
        self.refreshCursorModelOptionsCacheAsync();

        self.setSidebarNotice("App refreshed from disk.");
        self.requestTranscriptScrollToBottom();
    }

    fn dupeZ(self: *AppState, value: []const u8) ![:0]const u8 {
        return try self.allocator.dupeZ(u8, value);
    }

    fn ensureFileSearchFinder(self: *AppState, project_path: []const u8) !void {
        if (self.file_search_state.project_path) |active_path| {
            if (std.mem.eql(u8, active_path, project_path)) return;

            self.allocator.free(active_path);
            self.file_search_state.project_path = null;
        }

        if (self.file_search_state.finder) |*finder| {
            finder.deinit();
            self.file_search_state.finder = null;
        }

        self.file_search_state.finder = try fff.Finder.init(self.allocator, self.storage.pref_path, project_path);
        self.file_search_state.project_path = try self.allocator.dupe(u8, project_path);
        self.file_search_state.clearQuery(self.allocator);
    }

    fn clearFileSearch(self: *AppState) void {
        self.file_search_state.visible = false;
        self.file_search_state.token = null;
        self.file_search_state.ensure_selection_visible = false;
        self.file_search_state.clearQuery(self.allocator);
        self.file_search_state.clearResults(self.allocator);
    }

    pub fn deinit(self: *AppState) void {
        runtime_log.diagnostic("AppState.deinit begin", .{});
        self.preparePendingSendsForShutdown();
        runtime_log.diagnostic("AppState.deinit pending sends prepared", .{});
        self.finishPickerThread();
        runtime_log.diagnostic("AppState.deinit picker finished", .{});
        self.finishSlashCommandThread();
        runtime_log.diagnostic("AppState.deinit slash command finished", .{});
        self.finishOpencodeModelCacheThread();
        runtime_log.diagnostic("AppState.deinit opencode model cache finished", .{});
        self.finishClaudeModelCacheThread();
        runtime_log.diagnostic("AppState.deinit claude model cache finished", .{});
        self.finishCursorModelCacheThread();
        runtime_log.diagnostic("AppState.deinit cursor model cache finished", .{});
        self.finishProviderReadinessThread();
        runtime_log.diagnostic("AppState.deinit provider readiness finished", .{});
        self.finishAllSendThreads();
        runtime_log.diagnostic("AppState.deinit send threads finished", .{});
        _ = self.pollSend();
        runtime_log.diagnostic("AppState.deinit sends polled", .{});
        ai_harness.shutdownOwnedProviderProcesses();
        runtime_log.diagnostic("AppState.deinit provider processes shutdown", .{});
        self.flushDirtyBlocking();
        runtime_log.diagnostic("AppState.deinit dirty state flushed", .{});
        self.file_search_state.deinit(self.allocator);
        self.palette_composer.deinit(self.allocator);
        self.palette_overlay_batch.deinit(self.allocator);
        self.palette_frame_text.deinit(self.allocator);
        self.palette_frame_text_arena.deinit();
        self.palette_modal_hits.deinit(self.allocator);
        self.code_copy_buttons.deinit(self.allocator);
        self.card_toggle_hits.deinit(self.allocator);
        self.expanded_cards.deinit();
        self.closeTranscriptSelectionModal();
        self.clearProjects();
        self.clearSurfaces();
        self.transcript_markdown_entries.deinit(self.allocator);
        self.clearBrowserContextMenuLocal();
        self.browser_context_menu_items.deinit(self.allocator);
        self.browser_state.deinit();
        self.releaseAllImageTextures();
        self.thread_import_threads.deinit(self.allocator);
        self.clearHerdrProfileSummaries();
        self.herdr_profile_summaries.deinit(self.allocator);
        self.clearOpencodeModelOptions();
        self.clearClaudeModelOptions();
        self.clearCursorModelOptions();
        self.opencode_reasoning_menu.deinit(self.allocator);
        self.opencode_model_options.deinit(self.allocator);
        self.claude_model_options.deinit(self.allocator);
        self.cursor_model_options.deinit(self.allocator);
        self.app_config.deinit(self.allocator);
        self.projects.deinit(self.allocator);
        self.archived_projects.deinit(self.allocator);
        self.surfaces.deinit(self.allocator);
        runtime_log.diagnostic("AppState.deinit complete", .{});
    }

    fn preparePendingSendsForShutdown(self: *AppState) void {
        for (self.projects.items) |*project| {
            for (project.threads.items) |*thread| {
                self.prepareThreadSendForShutdown(project.path, thread);
            }
            for (project.archived_threads.items) |*thread| {
                self.prepareThreadSendForShutdown(project.path, thread);
        self.update_state.deinit();
        runtime_log.diagnostic("AppState.deinit updater finished", .{});
            }
        }
        for (self.archived_projects.items) |*project| {
            for (project.threads.items) |*thread| {
                self.prepareThreadSendForShutdown(project.path, thread);
            }
            for (project.archived_threads.items) |*thread| {
                self.prepareThreadSendForShutdown(project.path, thread);
            }
        }
    }

    pub fn pollPicker(self: *AppState) void {
        var picked_path: ?[]u8 = null;
        var next_status: PickerStatus = .idle;

        self.picker_state.mutex.lock();
        switch (self.picker_state.status) {
            .selected => {
                picked_path = self.picker_state.selected_path;
                self.picker_state.selected_path = null;
                self.picker_state.status = .idle;
                next_status = .selected;
            },
            .cancelled => {
                self.picker_state.status = .idle;
                next_status = .cancelled;
            },
            .unavailable => {
                self.picker_state.status = .idle;
                next_status = .unavailable;
            },
            .failed => {
                self.picker_state.status = .idle;
                next_status = .failed;
            },
            else => {},
        }
        self.picker_state.mutex.unlock();

        if (next_status != .idle) {
            runtime_log.diagnostic("pollPicker completed status={s}", .{@tagName(next_status)});
            log.info("pollPicker completed status={s}", .{@tagName(next_status)});
            self.finishPickerThread();
        }

        const create_parent = self.project_directory_picker_create_parent;
        if (next_status != .idle) self.project_directory_picker_create_parent = false;

        switch (next_status) {
            .selected => {
                if (picked_path) |path| {
                    defer std.heap.page_allocator.free(path);
                    if (self.show_project_creator) {
                        if (create_parent) {
                            self.setImportPathWithTrailingSeparator(path) catch |err| {
                                log.warn("failed to stage selected parent folder: {s}", .{@errorName(err)});
                                self.setSidebarNotice("Folder selected, but path setup failed.");
                                return;
                            };
                        } else {
                            self.setImportPath(path);
                        }
                        self.project_import_cursor = self.importDirectoryDraft().len;
                        self.palette_modal_text_focus = .project_import;
                        self.setSidebarNotice(if (create_parent) "Type the new folder name, then Create directory." else "Folder selected.");
                        self.markDirty();
                    } else {
                        self.setImportPath(path);
                        self.importProjectFromInput() catch |err| {
                            log.warn("failed to import selected workspace: {s}", .{@errorName(err)});
                            self.setSidebarNotice("Folder selected, but workspace import failed.");
                        };
                    }
                }
            },
            .cancelled => self.setSidebarNotice("Folder selection cancelled."),
            .unavailable => self.setSidebarNotice("No supported folder picker found. Install zenity or paste a directory path manually."),
            .failed => self.setSidebarNotice("Folder picker failed."),
            else => {},
        }
    }

    pub fn pollOpencodeModelOptionsCache(self: *AppState) void {
        var loaded_models: ?[]ai_harness.ModelInfo = null;
        var next_status: OpencodeModelCacheStatus = .idle;

        self.opencode_model_cache_state.mutex.lock();
        switch (self.opencode_model_cache_state.status) {
            .completed => {
                loaded_models = self.opencode_model_cache_state.models;
                self.opencode_model_cache_state.models = null;
                self.opencode_model_cache_state.status = .idle;
                next_status = .completed;
            },
            .failed => {
                self.opencode_model_cache_state.status = .idle;
                next_status = .failed;
            },
            else => {},
        }
        self.opencode_model_cache_state.mutex.unlock();

        if (next_status != .idle) {
            self.finishOpencodeModelCacheThread();
        }

        switch (next_status) {
            .completed => {
                const models = loaded_models orelse return;
                defer ai_harness.freeModelInfos(std.heap.page_allocator, models);
                self.clearOpencodeModelOptions();
                if (models.len == 0) return;
                self.populateOpencodeModelOptions(models) catch |err| {
                    log.warn("failed to cache OpenCode configured models: {s}", .{@errorName(err)});
                    self.clearDynamicOpencodeModelOptions();
                    return;
                };
                self.normalizeCurrentOpencodeThreadModel();
            },
            .failed => {
                log.warn("failed to refresh OpenCode model cache", .{});
            },
            else => {},
        }
    }

    pub fn pollCursorModelOptionsCache(self: *AppState) void {
        var loaded_models: ?[]ai_harness.ModelInfo = null;
        var next_status: CursorModelCacheStatus = .idle;

        self.cursor_model_cache_state.mutex.lock();
        switch (self.cursor_model_cache_state.status) {
            .completed => {
                loaded_models = self.cursor_model_cache_state.models;
                self.cursor_model_cache_state.models = null;
                self.cursor_model_cache_state.status = .idle;
                next_status = .completed;
            },
            .failed => {
                self.cursor_model_cache_state.status = .idle;
                next_status = .failed;
            },
            else => {},
        }
        self.cursor_model_cache_state.mutex.unlock();

        if (next_status != .idle) {
            self.finishCursorModelCacheThread();
        }

        switch (next_status) {
            .completed => {
                const models = loaded_models orelse return;
                defer ai_harness.freeModelInfos(std.heap.page_allocator, models);
                self.clearCursorModelOptions();
                if (models.len == 0) return;
                self.populateCursorModelOptions(models) catch |err| {
                    log.warn("failed to cache Cursor models: {s}", .{@errorName(err)});
                    self.clearDynamicCursorModelOptions();
                    return;
                };
                self.saveCursorModelOptionsDiskCache() catch |err| {
                    log.warn("failed to save Cursor model cache: {s}", .{@errorName(err)});
                };
            },
            .failed => {
                log.warn("failed to refresh Cursor model cache", .{});
            },
            else => {},
        }
    }

    pub fn pollClaudeModelOptionsCache(self: *AppState) void {
        var loaded_models: ?[]ai_harness.ModelInfo = null;
        var next_status: ClaudeModelCacheStatus = .idle;

        self.claude_model_cache_state.mutex.lock();
        switch (self.claude_model_cache_state.status) {
            .completed => {
                loaded_models = self.claude_model_cache_state.models;
                self.claude_model_cache_state.models = null;
                self.claude_model_cache_state.status = .idle;
                next_status = .completed;
            },
            .failed => {
                self.claude_model_cache_state.status = .idle;
                next_status = .failed;
            },
            else => {},
        }
        self.claude_model_cache_state.mutex.unlock();

        if (next_status != .idle) {
            self.finishClaudeModelCacheThread();
        }

        switch (next_status) {
            .completed => {
                const models = loaded_models orelse return;
                defer ai_harness.freeModelInfos(std.heap.page_allocator, models);
                self.clearClaudeModelOptions();
                if (models.len == 0) return;
                self.populateClaudeModelOptions(models) catch |err| {
                    log.warn("failed to cache Claude models: {s}", .{@errorName(err)});
                    self.clearDynamicClaudeModelOptions();
                    return;
                };
            },
            .failed => {
                log.warn("failed to refresh Claude model cache", .{});
            },
            else => {},
        }
    }

    pub fn pollSend(self: *AppState) bool {
        if (self.pending_send_count == 0) return false;

        var changed = false;
        for (self.projects.items, 0..) |*project, project_index| {
            for (project.threads.items, 0..) |*thread, thread_index| {
                changed = self.pollThreadSend(project_index, thread_index, thread) or changed;
            }
        }
        return changed;
    }

    pub fn pollSlashCommand(self: *AppState) bool {
        var result: ?ai_harness.RunSlashCommandResult = null;
        var error_message: ?[]u8 = null;
        var display_name: ?[]u8 = null;
        var project_index: usize = 0;
        var thread_index: usize = 0;
        var next_status: SlashCommandStatus = .idle;

        self.slash_command_state.mutex.lock();
        switch (self.slash_command_state.status) {
            .completed => {
                result = self.slash_command_state.result;
                self.slash_command_state.result = null;
                display_name = self.slash_command_state.display_name;
                self.slash_command_state.display_name = null;
                self.slash_command_state.started_at_ms = 0;
                project_index = self.slash_command_state.project_index;
                thread_index = self.slash_command_state.thread_index;
                self.slash_command_state.status = .idle;
                next_status = .completed;
            },
            .failed => {
                error_message = self.slash_command_state.error_message;
                self.slash_command_state.error_message = null;
                display_name = self.slash_command_state.display_name;
                self.slash_command_state.display_name = null;
                self.slash_command_state.started_at_ms = 0;
                project_index = self.slash_command_state.project_index;
                thread_index = self.slash_command_state.thread_index;
                self.slash_command_state.status = .idle;
                next_status = .failed;
            },
            else => {},
        }
        self.slash_command_state.mutex.unlock();

        if (next_status != .idle) {
            self.finishSlashCommandThread();
        }
        if (display_name) |name| {
            std.heap.page_allocator.free(name);
        }

        switch (next_status) {
            .completed => {
                const command_result = result orelse return true;
                defer command_result.deinit(std.heap.page_allocator);
                self.applySlashCommandResult(project_index, thread_index, command_result);
            },
            .failed => {
                if (error_message) |message| {
                    defer std.heap.page_allocator.free(message);
                    self.setSidebarNotice(message);
                } else {
                    self.setSidebarNotice("Slash command failed.");
                }
            },
            else => {},
        }

        return next_status != .idle;
    }

    pub fn currentThreadPendingSlashCommand(self: *AppState) ?PendingSlashCommandDetails {
        if (self.projects.items.len == 0) return null;
        const project_index = self.selected_project_index;
        const thread_index = self.currentProject().selected_thread_index;

        self.slash_command_state.mutex.lock();
        defer self.slash_command_state.mutex.unlock();
        if (self.slash_command_state.status != .pending) return null;
        if (self.slash_command_state.project_index != project_index or self.slash_command_state.thread_index != thread_index) return null;

        return .{
            .provider = self.slash_command_state.provider,
            .command = self.slash_command_state.command,
            .display_name = self.slash_command_state.display_name orelse slashCommandFallbackName(self.slash_command_state.command),
            .started_at_ms = self.slash_command_state.started_at_ms,
        };
    }

    pub fn hasPendingSlashCommand(self: *AppState) bool {
        self.slash_command_state.mutex.lock();
        defer self.slash_command_state.mutex.unlock();
        return self.slash_command_state.status == .pending;
    }

    pub fn currentThreadPendingSlashCommandLabel(self: *AppState) ?[]const u8 {
        const details = self.currentThreadPendingSlashCommand() orelse return null;

        return switch (details.provider) {
            .claude => switch (details.command) {
                .usage => "Loading Claude usage...",
                .compact => "Compacting Claude thread context...",
                else => "Running Claude command...",
            },
            .codex => switch (details.command) {
                .usage => "Loading Codex usage...",
                .goal => "Updating Codex goal...",
                .compact => "Compacting Codex thread context...",
                .review => "Starting Codex review...",
                .shell => "Running Codex shell command...",
                .custom => "Running Codex command...",
            },
            .opencode => "Running OpenCode command...",
            .cursor => "Running Cursor command...",
        };
    }

    fn applySlashCommandResult(
        self: *AppState,
        project_index: usize,
        thread_index: usize,
        result: ai_harness.RunSlashCommandResult,
    ) void {
        if (!result.handled) {
            if (result.notice) |notice| {
                self.setSidebarNotice(notice);
            } else {
                self.setSidebarNotice("Slash command was not handled by this provider.");
            }
            return;
        }

        if (project_index < self.projects.items.len and thread_index < self.projects.items[project_index].threads.items.len) {
            const thread = &self.projects.items[project_index].threads.items[thread_index];
            if (result.thread_id) |provider_thread_id| {
                const changed = thread.provider_thread_id == null or !std.mem.eql(u8, thread.provider_thread_id.?, provider_thread_id);
                if (changed) {
                    const owned = self.allocator.dupeZ(u8, provider_thread_id) catch |err| blk: {
                        log.warn("failed to persist slash command thread id: {s}", .{@errorName(err)});
                        break :blk null;
                    };
                    if (owned) |next| {
                        if (thread.provider_thread_id) |old| self.allocator.free(old);
                        thread.provider_thread_id = next;
                    }
                }
            }

            if (result.transcript_title != null or result.transcript_body != null) {
                const title = result.transcript_title orelse "Provider command";
                const body = result.transcript_body orelse "Done.";
                self.appendMessageToThread(thread, .system, title, body, null, &.{}) catch |err| {
                    log.warn("failed to append slash command result: {s}", .{@errorName(err)});
                };
                if (project_index == self.selected_project_index and thread_index == self.currentProject().selected_thread_index) {
                    self.requestTranscriptScrollToBottom();
                }
            }
        }

        if (result.notice) |notice| {
            self.setSidebarNotice(notice);
        } else {
            self.setSidebarNotice("Slash command completed.");
        }
        self.markDirty();
    }

    pub fn hasRunningBackgroundTasks(self: *const AppState) bool {
        for (self.projects.items) |project| {
            for (project.threads.items) |thread| {
                if (threadHasRunningBackgroundTasks(&thread)) return true;
            }
            for (project.archived_threads.items) |thread| {
                if (threadHasRunningBackgroundTasks(&thread)) return true;
            }
        }
        return false;
    }

    fn threadHasRunningBackgroundTasks(thread: *const ChatThread) bool {
        for (thread.background_tasks.items) |task| {
            if (task.status == .running and task.pid_path != null) return true;
        }
        return false;
    }

    pub fn pollBackgroundTasks(self: *AppState) bool {
        var changed = false;
        for (self.projects.items, 0..) |*project, project_index| {
            for (project.threads.items, 0..) |*thread, thread_index| {
                changed = self.pollThreadBackgroundTasks(project_index, thread_index, thread) or changed;
            }
            for (project.archived_threads.items) |*thread| {
                changed = self.pollThreadBackgroundTasks(project_index, null, thread) or changed;
            }
        }
        return changed;
    }

    fn pollThreadBackgroundTasks(self: *AppState, project_index: usize, thread_index: ?usize, thread: *ChatThread) bool {
        const now_ms = unixTimestampMs();
        var changed = false;

        for (thread.background_tasks.items) |*task| {
            if (task.status != .running) continue;
            if (task.pid_path == null) continue;
            if (task.last_poll_ms != 0 and now_ms - task.last_poll_ms < BACKGROUND_TASK_POLL_MS) continue;
            task.last_poll_ms = now_ms;

            const pid = readBackgroundTaskPid(self.allocator, task.pid_path.?) orelse continue;
            if (backgroundTaskProcessIsAlive(pid)) continue;

            task.status = .completed;
            task.updated_at_ms = now_ms;
            const body = backgroundTaskCompletionBodyAlloc(self.allocator, task) catch |err| {
                log.warn("failed to build background task completion body: {s}", .{@errorName(err)});
                continue;
            };
            defer self.allocator.free(body);
            self.appendMessageToThread(
                thread,
                .system,
                "Background task completed",
                body,
                null,
                &.{},
            ) catch |err| {
                log.warn("failed to append background task completion: {s}", .{@errorName(err)});
                continue;
            };
            if (project_index < self.projects.items.len) {
                self.projects.items[project_index].invalidateSidebarThreadCache();
            }
            if (project_index == self.selected_project_index and thread_index != null and thread_index.? == self.currentProject().selected_thread_index) {
                self.requestTranscriptScrollToBottom();
            }
            changed = true;
        }

        return changed;
    }

    fn backgroundTaskCompletionBodyAlloc(allocator: std.mem.Allocator, task: *const BackgroundTask) ![:0]u8 {
        if (task.task_id) |task_id| {
            if (task.log_path) |log_path| {
                return try ChatThread.allocPrintZCompat(allocator, "{s}\n\nVerde task ID: {s}\nOutput log: {s}", .{
                    task.command,
                    task_id,
                    log_path,
                });
            }
            return try ChatThread.allocPrintZCompat(allocator, "{s}\n\nVerde task ID: {s}", .{
                task.command,
                task_id,
            });
        }
        return try allocator.dupeZ(u8, task.command);
    }

    fn readBackgroundTaskPid(allocator: std.mem.Allocator, pid_path: []const u8) ?u32 {
        var threaded = std.Io.Threaded.init_single_threaded;
        const raw = std.Io.Dir.cwd().readFileAlloc(threaded.io(), pid_path, allocator, .limited(256)) catch return null;
        defer allocator.free(raw);
        const trimmed = std.mem.trim(u8, raw, "\n\r\t ");
        if (trimmed.len == 0) return null;
        return std.fmt.parseInt(u32, trimmed, 10) catch null;
    }

    fn backgroundTaskProcessIsAlive(pid: u32) bool {
        return platform_process.processIdIsAlive(pid);
    }

    fn pollDaemonChatTurn(self: *AppState, thread: *ChatThread) bool {
        const page_alloc = std.heap.page_allocator;
        const send_state = thread.send_state;
        send_state.mutex.lock();
        const turn_id = if (send_state.status == .pending and send_state.daemon_owned and send_state.daemon_turn_id != null)
            page_alloc.dupe(u8, send_state.daemon_turn_id.?) catch null
        else
            null;
        const after_seq = send_state.daemon_last_seq;
        send_state.mutex.unlock();

        const owned_turn_id = turn_id orelse return false;
        defer page_alloc.free(owned_turn_id);

        const response = sessionizer.requestAlloc(page_alloc, self.storage.pref_path, "chat.turn.tail", .{
            .turn_id = owned_turn_id,
            .after_seq = after_seq,
        }, 2) catch |err| {
            log.warn("failed to tail daemon chat turn: {s}", .{@errorName(err)});
            return false;
        };
        defer page_alloc.free(response);
        return self.applyDaemonChatTurnTail(thread, response) catch |err| {
            log.warn("failed to apply daemon chat turn tail: {s}", .{@errorName(err)});
            return false;
        };
    }

    fn applyDaemonChatTurnTail(self: *AppState, thread: *ChatThread, response: []const u8) !bool {
        var parsed = try std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, response, .{});
        defer parsed.deinit();
        const result = try jsonRpcResult(parsed.value);
        if (result != .object) return error.InvalidDaemonResponse;
        const status_text = jsonValueString(result.object.get("status") orelse .null) orelse "running";
        const events = result.object.get("events") orelse .null;
        var changed = false;

        const send_state = thread.send_state;
        send_state.mutex.lock();
        defer send_state.mutex.unlock();
        if (send_state.status != .pending) return false;

        if (jsonValueString(result.object.get("provider_thread_id") orelse .null)) |thread_id| {
            try replacePageOwned(&send_state.provisional_provider_thread_id, thread_id);
        }
        if (jsonValueString(result.object.get("active_turn_id") orelse .null)) |turn_id| {
            try replacePageOwned(&send_state.active_turn_id, turn_id);
        }
        if (events == .array) {
            for (events.array.items) |event_value| {
                if (event_value != .object) continue;
                const seq = jsonValueU64(event_value.object.get("seq") orelse .null) orelse continue;
                const kind = jsonValueString(event_value.object.get("kind") orelse .null) orelse continue;
                const payload_json = jsonValueString(event_value.object.get("payload_json") orelse .null) orelse "{}";
                if (seq > send_state.daemon_last_seq) send_state.daemon_last_seq = seq;
                try self.applyDaemonChatEventLocked(send_state, kind, payload_json);
                changed = true;
            }
        }
        if (result.object.get("pending_approval")) |approval_value| {
            if (approval_value == .object) {
                const call_id = jsonValueString(approval_value.object.get("call_id") orelse .null) orelse "";
                const title = jsonValueString(approval_value.object.get("title") orelse .null) orelse "Approval requested";
                const body = jsonValueString(approval_value.object.get("body") orelse .null) orelse "";
                if (call_id.len > 0 and send_state.pending_approval == null) {
                    send_state.pending_approval = .{
                        .call_id = try std.heap.page_allocator.dupe(u8, call_id),
                        .title = try std.heap.page_allocator.dupe(u8, title),
                        .body = try std.heap.page_allocator.dupe(u8, body),
                    };
                    changed = true;
                }
            }
        }
        if (std.mem.eql(u8, status_text, "completed")) {
            const provider_thread_id = jsonValueString(result.object.get("provider_thread_id") orelse .null) orelse send_state.provisional_provider_thread_id orelse "";
            const reply_text = jsonValueString(result.object.get("result_reply_text") orelse .null) orelse "";
            send_state.result = .{
                .provider_thread_id = try std.heap.page_allocator.dupe(u8, provider_thread_id),
                .reply_text = try std.heap.page_allocator.dupe(u8, reply_text),
            };
            send_state.status = .completed;
            changed = true;
        } else if (std.mem.eql(u8, status_text, "failed")) {
            const message = jsonValueString(result.object.get("error_message") orelse .null) orelse "Provider request failed.";
            send_state.error_message = try std.heap.page_allocator.dupe(u8, message);
            send_state.status = .failed;
            changed = true;
        } else if (std.mem.eql(u8, status_text, "aborted")) {
            send_state.status = .aborted;
            changed = true;
        }
        if (changed) send_state.ui_revision +%= 1;
        return changed;
    }

    fn applyDaemonChatEventLocked(self: *AppState, send_state: *SendState, kind: []const u8, payload_json: []const u8) !void {
        _ = self;
        if (std.mem.eql(u8, kind, "assistant_delta")) {
            const text = daemonPayloadStringAlloc(payload_json, "text") orelse return;
            defer std.heap.page_allocator.free(text);
            try send_state.partial_text.appendSlice(std.heap.page_allocator, text);
        } else if (std.mem.eql(u8, kind, "message")) {
            flushPendingAssistantTextLocked(send_state, std.heap.page_allocator);
            const title = daemonPayloadStringAlloc(payload_json, "title") orelse try std.heap.page_allocator.dupe(u8, "System");
            defer std.heap.page_allocator.free(title);
            const body = daemonPayloadStringAlloc(payload_json, "body") orelse try std.heap.page_allocator.dupe(u8, "");
            defer std.heap.page_allocator.free(body);
            const owned_author = try std.heap.page_allocator.dupe(u8, title);
            errdefer std.heap.page_allocator.free(owned_author);
            const owned_body = try std.heap.page_allocator.dupe(u8, body);
            errdefer std.heap.page_allocator.free(owned_body);
            try send_state.pending_events.append(std.heap.page_allocator, .{ .role = .system, .author = owned_author, .body = owned_body });
        } else if (std.mem.eql(u8, kind, "thread_id")) {
            if (daemonPayloadStringAlloc(payload_json, "thread_id")) |thread_id| {
                defer std.heap.page_allocator.free(thread_id);
                try replacePageOwned(&send_state.provisional_provider_thread_id, thread_id);
            }
        } else if (std.mem.eql(u8, kind, "turn_id")) {
            if (daemonPayloadStringAlloc(payload_json, "turn_id")) |turn_id| {
                defer std.heap.page_allocator.free(turn_id);
                try replacePageOwned(&send_state.active_turn_id, turn_id);
            }
        }
    }

    fn pollThreadSend(self: *AppState, project_index: usize, thread_index: usize, thread: *ChatThread) bool {
        const daemon_changed = self.pollDaemonChatTurn(thread);
        self.capturePendingProviderThreadId(thread);
        self.issuePendingCodexSteer(project_index, thread_index, thread);
        self.issuePendingThreadStop(project_index, self.projects.items[project_index].path, thread);

        var completed_result: ?SendResultPayload = null;
        var failed_message: ?[]u8 = null;
        var had_pending_followup = false;
        var next_status: SendStatus = .idle;
        var completed_events: std.ArrayListUnmanaged(PendingTimelineEvent) = .empty;
        var completed_diff_files: std.ArrayListUnmanaged(PendingDiffFile) = .empty;
        var completed_daemon_turn_id: ?[]u8 = null;
        const send_state = thread.send_state;
        var stream_changed = false;

        if (!send_state.mutex.tryLock()) return false;
        switch (send_state.status) {
            .pending => {
                if (send_state.ui_revision != send_state.polled_ui_revision) {
                    send_state.polled_ui_revision = send_state.ui_revision;
                    stream_changed = true;
                }
                // Force a repaint exactly when the visible seconds in the
                // "Working - mm:ss" label would change. Without this, the
                // main loop sleeps in SDL_WaitEventTimeout(IDLE) while a
                // turn is in flight and no tokens are streaming, so the
                // wall-clock label freezes until the user moves the mouse.
                const safe_started_at_ms = @max(send_state.started_at_ms, 0);
                const elapsed_ms = @max(unixTimestampMs() - safe_started_at_ms, 0);
                const elapsed_seconds = @divTrunc(elapsed_ms, std.time.ms_per_s);
                if (elapsed_seconds != send_state.polled_working_seconds) {
                    send_state.polled_working_seconds = elapsed_seconds;
                    stream_changed = true;
                }
            },
            .completed => {
                had_pending_followup = send_state.pending_followup != null;
                completed_result = send_state.result;
                send_state.result = null;
                if (send_state.provisional_provider_thread_id) |thread_id| {
                    std.heap.page_allocator.free(thread_id);
                    send_state.provisional_provider_thread_id = null;
                }
                if (send_state.active_turn_id) |turn_id| {
                    std.heap.page_allocator.free(turn_id);
                    send_state.active_turn_id = null;
                }
                flushPendingAssistantTextLocked(send_state, std.heap.page_allocator);
                completed_events = send_state.pending_events;
                send_state.pending_events = .empty;
                completed_diff_files = send_state.pending_diff_files;
                send_state.pending_diff_files = .empty;
                freePendingApprovalLocked(std.heap.page_allocator, &send_state.pending_approval);
                send_state.approval_decision = null;
                send_state.provider = null;
                send_state.started_at_ms = 0;
                completed_daemon_turn_id = send_state.daemon_turn_id;
                send_state.daemon_turn_id = null;
                send_state.daemon_owned = false;
                send_state.daemon_last_seq = 0;
                send_state.status = .idle;
                next_status = .completed;
            },
            .aborted => {
                had_pending_followup = send_state.pending_followup != null;
                if (send_state.provisional_provider_thread_id) |thread_id| {
                    std.heap.page_allocator.free(thread_id);
                    send_state.provisional_provider_thread_id = null;
                }
                if (send_state.active_turn_id) |turn_id| {
                    std.heap.page_allocator.free(turn_id);
                    send_state.active_turn_id = null;
                }
                flushPendingAssistantTextLocked(send_state, std.heap.page_allocator);
                completed_events = send_state.pending_events;
                send_state.pending_events = .empty;
                completed_diff_files = send_state.pending_diff_files;
                send_state.pending_diff_files = .empty;
                freePendingApprovalLocked(std.heap.page_allocator, &send_state.pending_approval);
                send_state.approval_decision = null;
                send_state.provider = null;
                send_state.started_at_ms = 0;
                completed_daemon_turn_id = send_state.daemon_turn_id;
                send_state.daemon_turn_id = null;
                send_state.daemon_owned = false;
                send_state.daemon_last_seq = 0;
                send_state.status = .idle;
                next_status = .aborted;
            },
            .failed => {
                failed_message = send_state.error_message;
                send_state.error_message = null;
                if (send_state.provisional_provider_thread_id) |thread_id| {
                    std.heap.page_allocator.free(thread_id);
                    send_state.provisional_provider_thread_id = null;
                }
                if (send_state.active_turn_id) |turn_id| {
                    std.heap.page_allocator.free(turn_id);
                    send_state.active_turn_id = null;
                }
                send_state.partial_text.clearRetainingCapacity();
                completed_events = send_state.pending_events;
                send_state.pending_events = .empty;
                completed_diff_files = send_state.pending_diff_files;
                send_state.pending_diff_files = .empty;
                freePendingApprovalLocked(std.heap.page_allocator, &send_state.pending_approval);
                send_state.approval_decision = null;
                send_state.provider = null;
                send_state.started_at_ms = 0;
                completed_daemon_turn_id = send_state.daemon_turn_id;
                send_state.daemon_turn_id = null;
                send_state.daemon_owned = false;
                send_state.daemon_last_seq = 0;
                send_state.status = .idle;
                next_status = .failed;
            },
            else => {},
        }
        send_state.mutex.unlock();

        if (next_status != .idle) {
            if (self.pending_send_count > 0) self.pending_send_count -= 1;
            thread.finishSendThread();
            if (project_index < self.projects.items.len) {
                self.projects.items[project_index].invalidateSidebarThreadCache();
            }
        }

        switch (next_status) {
            .completed => {
                if (completed_result) |result| {
                    defer std.heap.page_allocator.free(result.provider_thread_id);
                    defer std.heap.page_allocator.free(result.reply_text);
                    defer freePendingTimelineEvents(std.heap.page_allocator, &completed_events);
                    defer freePendingDiffFiles(std.heap.page_allocator, &completed_diff_files);
                    if (thread.provider != .opencode) {
                        appendPendingDiffSummaryEvent(std.heap.page_allocator, &completed_events, completed_diff_files.items);
                    }
                    const should_append_reply_text = !pendingTimelineEventsContainAssistant(completed_events.items);
                    self.applyPendingTimelineEvents(thread, &completed_events) catch |err| {
                        log.err("failed to apply timeline events: {s}", .{@errorName(err)});
                    };
                    self.applySendSuccess(thread, result, should_append_reply_text) catch |err| {
                        log.err("failed to apply send result: {s}", .{@errorName(err)});
                        self.setSidebarNotice("Failed to apply provider reply.");
                    };
                    if (project_index == self.selected_project_index and thread_index == self.currentProject().selected_thread_index) {
                        self.requestTranscriptScrollToBottom();
                    }
                    self.flushDirtyNow();
                    self.consumeDaemonChatTurn(completed_daemon_turn_id);
                }
            },
            .failed => {
                defer freePendingTimelineEvents(std.heap.page_allocator, &completed_events);
                defer freePendingDiffFiles(std.heap.page_allocator, &completed_diff_files);
                if (thread.provider != .opencode) {
                    appendPendingDiffSummaryEvent(std.heap.page_allocator, &completed_events, completed_diff_files.items);
                }
                if (failed_message) |message| {
                    defer std.heap.page_allocator.free(message);
                    self.applySendFailure(thread, &completed_events, message) catch |err| {
                        log.err("failed to apply send failure: {s}", .{@errorName(err)});
                    };
                    self.setSidebarNotice(message);
                } else {
                    self.setSidebarNotice("Provider request failed.");
                }
                self.flushDirtyNow();
                self.consumeDaemonChatTurn(completed_daemon_turn_id);
            },
            .aborted => {
                defer freePendingTimelineEvents(std.heap.page_allocator, &completed_events);
                defer freePendingDiffFiles(std.heap.page_allocator, &completed_diff_files);
                if (thread.provider != .opencode) {
                    appendPendingDiffSummaryEvent(std.heap.page_allocator, &completed_events, completed_diff_files.items);
                }
                self.applyPendingTimelineEvents(thread, &completed_events) catch |err| {
                    log.err("failed to apply aborted timeline events: {s}", .{@errorName(err)});
                };
                thread.stopRunningBackgroundTasks();
                if (!had_pending_followup) {
                    self.appendMessageToThread(
                        thread,
                        .system,
                        "Conversation interrupted",
                        "Tell the model what to do differently.",
                        null,
                        &.{},
                    ) catch |err| {
                        log.err("failed to append interruption notice: {s}", .{@errorName(err)});
                    };
                }
                thread.touch();
                self.markDirty();
                self.setSidebarNotice("Provider reply stopped.");
                self.flushDirtyNow();
                self.consumeDaemonChatTurn(completed_daemon_turn_id);
            },
            else => {},
        }

        if (next_status == .failed) {
            self.clearPendingFollowupAfterFailure(thread);
        }
        if (next_status == .completed or next_status == .aborted) {
            self.dispatchPendingFollowup(project_index, thread_index, thread);
        }
        // Notify on a real chat turn completion. Skip when a follow-up is queued
        // (the turn continues immediately) so we only fire once the agent truly
        // rests, mirroring the terminal-agent `.done` notification.
        if (next_status == .completed and !had_pending_followup) {
            self.maybeNotifyChatCompletion(project_index, thread_index, thread);
        }
        return next_status != .idle or stream_changed or daemon_changed;
    }

    // Fires a desktop notification for a finished in-app chat turn, unless the
    // user is actively watching that thread in the focused window. Provider is
    // known here (no hook/CLI dependency), so the logo is always correct.
    fn maybeNotifyChatCompletion(self: *AppState, project_index: usize, thread_index: usize, thread: *const ChatThread) void {
        if (!self.app_config.notifications_enabled) return;
        if (self.isChatThreadVisibleAndFocused(project_index, thread_index)) return;
        if (project_index >= self.projects.items.len) return;
        const project = &self.projects.items[project_index];

        const title = if (thread.title.len > 0)
            thread.title
        else
            utils.providerLabel(thread.provider);

        const dir = if (project.path.len > 0) std.fs.path.basename(project.path) else "";
        var body_buf: [256]u8 = undefined;
        const body = if (dir.len > 0)
            (std.fmt.bufPrint(&body_buf, "Reply ready in {s}", .{dir}) catch "Reply ready")
        else
            "Reply ready";

        const icon: notifier.Icon = switch (thread.provider) {
            .codex => .{ .key = "codex", .png_bytes = CODEX_LOGO_BYTES },
            .opencode => .{ .key = "opencode", .png_bytes = OPENCODE_LOGO_BYTES },
            .claude => .{ .key = "claude", .png_bytes = CLAUDE_LOGO_BYTES },
            .cursor => .{ .key = "cursor", .png_bytes = CURSOR_LOGO_BYTES },
        };
        notifier.notifyAgentDone(self.allocator, title, body, icon);
    }

    // True when the given chat thread is currently on screen in the focused
    // window: the window holds input focus, its project is selected, and a
    // non-minimized chat pane (respecting maximize) shows that thread.
    fn isChatThreadVisibleAndFocused(self: *const AppState, project_index: usize, thread_index: usize) bool {
        if (!self.window_input_focus) return false;
        if (project_index != self.selected_project_index) return false;
        if (project_index >= self.projects.items.len) return false;
        const layout = &self.projects.items[project_index].workspace_layout;
        if (layout.maximized_pane_id) |max_id| {
            const pane = layout.paneById(max_id) orelse return false;
            return switch (pane.ref) {
                .chat => |ref| ref.thread_index == thread_index,
                else => false,
            };
        }
        for (layout.panes.items) |pane| {
            if (pane.minimized) continue;
            switch (pane.ref) {
                .chat => |ref| if (ref.thread_index == thread_index) return true,
                else => {},
            }
        }
        return false;
    }

    fn capturePendingProviderThreadId(self: *AppState, thread: *ChatThread) void {
        if (thread.provider_thread_id != null) return;

        const send_state = thread.send_state;
        if (!send_state.mutex.tryLock()) return;
        const thread_id = if (send_state.status == .pending and send_state.provisional_provider_thread_id != null)
            self.allocator.dupeZ(u8, send_state.provisional_provider_thread_id.?) catch null
        else
            null;
        send_state.mutex.unlock();

        thread.provider_thread_id = thread_id orelse return;
        self.markDirty();
        self.flushDirtyNow();
    }

    fn issuePendingThreadStop(self: *AppState, project_index: ?usize, project_path: []const u8, thread: *ChatThread) void {
        var provider: Provider = undefined;
        var thread_id: ?[]u8 = null;
        var turn_id: ?[]u8 = null;

        const send_state = thread.send_state;
        if (!send_state.mutex.tryLock()) return;
        if (send_state.status == .pending and send_state.daemon_owned and send_state.stop_requested and !send_state.stop_signal_sent) {
            const daemon_turn_id = if (send_state.daemon_turn_id) |id| self.allocator.dupe(u8, id) catch null else null;
            send_state.stop_signal_sent = daemon_turn_id != null;
            send_state.mutex.unlock();
            const owned_daemon_turn_id = daemon_turn_id orelse return;
            defer self.allocator.free(owned_daemon_turn_id);
            self.cancelDaemonChatTurn(owned_daemon_turn_id);
            return;
        }
        if (send_state.status == .pending and send_state.stop_requested and !send_state.stop_signal_sent) {
            provider = thread.provider;
            const pending_thread_id: ?[]const u8 = if (thread.provider_thread_id) |existing|
                existing
            else if (send_state.provisional_provider_thread_id) |provisional|
                provisional
            else
                null;
            if (pending_thread_id) |resolved_thread_id| {
                if (provider == .opencode or provider == .codex or provider == .claude or send_state.active_turn_id != null) {
                    thread_id = self.allocator.dupe(u8, resolved_thread_id) catch null;
                    turn_id = if (send_state.active_turn_id) |active_turn_id|
                        self.allocator.dupe(u8, active_turn_id) catch null
                    else
                        null;
                    send_state.stop_signal_sent = thread_id != null;
                }
            } else if (provider == .claude) {
                // Claude's current interrupt path targets the active bridge
                // process group, so it can still stop a fresh turn before the
                // SDK has emitted a session id.
                thread_id = self.allocator.dupe(u8, "") catch null;
                send_state.stop_signal_sent = thread_id != null;
            }
        }
        send_state.mutex.unlock();

        const owned_thread_id = thread_id orelse return;
        defer self.allocator.free(owned_thread_id);
        defer if (turn_id) |owned_turn_id| self.allocator.free(owned_turn_id);

        const execution_target = if (project_index) |index|
            self.providerExecutionTargetForProjectThread(index, thread, 0) orelse return
        else
            ProviderExecutionTarget{ .local = project_path };

        self.interruptThreadViaHarness(execution_target, provider, owned_thread_id, turn_id) catch |err| {
            log.warn("failed to interrupt provider turn: {s}", .{@errorName(err)});
            self.setSidebarNotice("Failed to stop provider reply.");
            return;
        };
    }

    fn issuePendingCodexSteer(
        self: *AppState,
        project_index: usize,
        thread_index: usize,
        thread: *ChatThread,
    ) void {
        if (thread.provider != .codex) return;

        var thread_id: ?[]u8 = null;
        var turn_id: ?[]u8 = null;
        var prompt: ?[]u8 = null;

        const send_state = thread.send_state;
        if (!send_state.mutex.tryLock()) return;
        if (send_state.status == .pending and
            !send_state.stop_requested and
            send_state.pending_followup != null and
            send_state.pending_followup.?.kind == .steer and
            !send_state.pending_followup_signal_sent)
        {
            const pending_thread_id: ?[]const u8 = if (thread.provider_thread_id) |existing|
                existing
            else if (send_state.provisional_provider_thread_id) |provisional|
                provisional
            else
                null;
            if (pending_thread_id) |resolved_thread_id| {
                if (send_state.active_turn_id) |active_turn_id| {
                    thread_id = self.allocator.dupe(u8, resolved_thread_id) catch null;
                    turn_id = self.allocator.dupe(u8, active_turn_id) catch null;
                    prompt = self.allocator.dupe(u8, send_state.pending_followup.?.prompt) catch null;
                    send_state.pending_followup_signal_sent = thread_id != null and turn_id != null and prompt != null;
                    if (!send_state.pending_followup_signal_sent) {
                        if (thread_id) |owned_thread_id| {
                            self.allocator.free(owned_thread_id);
                            thread_id = null;
                        }
                        if (turn_id) |owned_turn_id| {
                            self.allocator.free(owned_turn_id);
                            turn_id = null;
                        }
                        if (prompt) |owned_prompt| {
                            self.allocator.free(owned_prompt);
                            prompt = null;
                        }
                    }
                }
            }
        }
        send_state.mutex.unlock();

        const owned_thread_id = thread_id orelse return;
        const owned_turn_id = turn_id orelse {
            self.allocator.free(owned_thread_id);
            return;
        };
        const owned_prompt = prompt orelse {
            self.allocator.free(owned_thread_id);
            self.allocator.free(owned_turn_id);
            return;
        };
        defer self.allocator.free(owned_thread_id);
        defer self.allocator.free(owned_turn_id);
        defer self.allocator.free(owned_prompt);

        const execution_target = self.providerExecutionTargetForProjectThread(project_index, thread, 0) orelse return;

        self.steerThreadViaHarness(execution_target, owned_thread_id, owned_turn_id, owned_prompt) catch |err| {
            send_state.mutex.lock();
            defer send_state.mutex.unlock();
            if (send_state.pending_followup) |*pending_followup| {
                pending_followup.state = .fallback_next_turn;
            }
            send_state.pending_followup_signal_sent = false;
            self.setSidebarNotice(switch (err) {
                error.CodexActiveTurnNotSteerable => "Codex could not steer this turn. It will send after the current reply finishes.",
                else => "Failed to send Codex steer. It will send after the current reply finishes.",
            });
            return;
        };

        send_state.mutex.lock();
        if (send_state.pending_followup) |*pending_followup| {
            pending_followup.state = .sent_inline;
        }
        send_state.pending_followup_signal_sent = true;
        flushPendingAssistantTextLocked(send_state, std.heap.page_allocator);
        const owned_author = std.heap.page_allocator.dupe(u8, "Steering current turn") catch null;
        const owned_body = std.heap.page_allocator.dupe(u8, owned_prompt) catch null;
        if (owned_author) |author| {
            if (owned_body) |body| {
                send_state.pending_events.append(std.heap.page_allocator, .{
                    .role = .system,
                    .author = author,
                    .body = body,
                }) catch {
                    std.heap.page_allocator.free(author);
                    std.heap.page_allocator.free(body);
                };
            } else {
                std.heap.page_allocator.free(author);
            }
        }
        send_state.mutex.unlock();
        if (project_index == self.selected_project_index and thread_index == self.currentProject().selected_thread_index) {
            self.requestTranscriptScrollToBottom();
        }
        self.setSidebarNotice("Codex steer sent. Waiting for the current turn to update.");
    }

    fn dispatchPendingFollowup(self: *AppState, project_index: usize, thread_index: usize, thread: *ChatThread) void {
        const send_state = thread.send_state;
        send_state.mutex.lock();
        const pending = send_state.pending_followup;
        send_state.pending_followup = null;
        send_state.pending_followup_signal_sent = false;
        send_state.stop_requested = false;
        send_state.stop_signal_sent = false;
        send_state.mutex.unlock();

        const followup = pending orelse return;
        defer self.allocator.free(followup.prompt);

        if (followup.kind == .steer and followup.state == .sent_inline) {
            self.setSidebarNotice("Codex steer applied.");
            return;
        }

        const execution_target = self.providerExecutionTargetForProjectThread(project_index, thread, 0) orelse return;

        self.appendMessageToThread(thread, .user, "You", followup.prompt, null, &.{}) catch |err| {
            log.err("failed to append pending follow-up: {s}", .{@errorName(err)});
            self.setSidebarNotice("Failed to append the pending follow-up.");
            return;
        };
        self.beginSendForThread(project_index, thread, followup.prompt, execution_target) catch |err| {
            log.err("failed to start pending follow-up: {s}", .{@errorName(err)});
            self.setSidebarNotice("Failed to send the pending follow-up.");
            return;
        };
        if (project_index == self.selected_project_index and thread_index == self.currentProject().selected_thread_index) {
            self.requestTranscriptScrollToBottom();
        }
        self.setSidebarNotice(switch (followup.kind) {
            .queue => "Queued message sent.",
            .steer => "Codex follow-up sent as a new turn.",
        });
    }

    fn clearPendingFollowupAfterFailure(self: *AppState, thread: *ChatThread) void {
        const send_state = thread.send_state;
        send_state.mutex.lock();
        defer send_state.mutex.unlock();
        freePendingFollowup(self.allocator, &send_state.pending_followup);
        send_state.pending_followup_signal_sent = false;
        send_state.stop_requested = false;
        send_state.stop_signal_sent = false;
    }

    fn finishPickerThread(self: *AppState) void {
        self.picker_state.mutex.lock();
        const maybe_worker = self.picker_state.worker;
        self.picker_state.worker = null;
        self.picker_state.mutex.unlock();

        if (maybe_worker) |worker| {
            worker.join();
        }
    }

    fn finishSlashCommandThread(self: *AppState) void {
        self.slash_command_state.mutex.lock();
        const maybe_worker = self.slash_command_state.worker;
        self.slash_command_state.worker = null;
        self.slash_command_state.mutex.unlock();

        if (maybe_worker) |worker| {
            worker.join();
        }

        self.slash_command_state.mutex.lock();
        const maybe_result = self.slash_command_state.result;
        const maybe_error = self.slash_command_state.error_message;
        const maybe_display_name = self.slash_command_state.display_name;
        self.slash_command_state.result = null;
        self.slash_command_state.error_message = null;
        self.slash_command_state.display_name = null;
        self.slash_command_state.started_at_ms = 0;
        self.slash_command_state.status = .idle;
        self.slash_command_state.mutex.unlock();

        if (maybe_result) |result| {
            result.deinit(std.heap.page_allocator);
        }
        if (maybe_error) |message| {
            std.heap.page_allocator.free(message);
        }
        if (maybe_display_name) |name| {
            std.heap.page_allocator.free(name);
        }
    }

    fn finishOpencodeModelCacheThread(self: *AppState) void {
        self.opencode_model_cache_state.mutex.lock();
        const maybe_worker = self.opencode_model_cache_state.worker;
        self.opencode_model_cache_state.worker = null;
        const maybe_models = self.opencode_model_cache_state.models;
        self.opencode_model_cache_state.models = null;
        self.opencode_model_cache_state.status = .idle;
        self.opencode_model_cache_state.mutex.unlock();

        if (maybe_worker) |worker| {
            worker.join();
        }
        if (maybe_models) |models| {
            ai_harness.freeModelInfos(std.heap.page_allocator, models);
        }
    }

    fn finishClaudeModelCacheThread(self: *AppState) void {
        self.claude_model_cache_state.mutex.lock();
        const maybe_worker = self.claude_model_cache_state.worker;
        self.claude_model_cache_state.worker = null;
        const maybe_models = self.claude_model_cache_state.models;
        self.claude_model_cache_state.models = null;
        self.claude_model_cache_state.status = .idle;
        self.claude_model_cache_state.mutex.unlock();

        if (maybe_worker) |worker| {
            worker.join();
        }
        if (maybe_models) |models| {
            ai_harness.freeModelInfos(std.heap.page_allocator, models);
        }
    }

    fn finishCursorModelCacheThread(self: *AppState) void {
        self.cursor_model_cache_state.mutex.lock();
        const maybe_worker = self.cursor_model_cache_state.worker;
        self.cursor_model_cache_state.worker = null;
        const maybe_models = self.cursor_model_cache_state.models;
        self.cursor_model_cache_state.models = null;
        self.cursor_model_cache_state.status = .idle;
        self.cursor_model_cache_state.mutex.unlock();

        if (maybe_worker) |worker| {
            worker.join();
        }
        if (maybe_models) |models| {
            ai_harness.freeModelInfos(std.heap.page_allocator, models);
        }
    }

    fn finishProviderReadinessThread(self: *AppState) void {
        self.provider_readiness_state.mutex.lock();
        const maybe_worker = self.provider_readiness_state.worker;
        self.provider_readiness_state.worker = null;
        self.provider_readiness_state.mutex.unlock();

        if (maybe_worker) |worker| worker.join();
    }

    fn finishAllSendThreads(self: *AppState) void {
        for (self.projects.items) |*project| {
            for (project.threads.items) |*thread| {
                thread.finishSendThread();
            }
            for (project.archived_threads.items) |*thread| {
                thread.finishSendThread();
            }
        }
        for (self.archived_projects.items) |*project| {
            for (project.threads.items) |*thread| {
                thread.finishSendThread();
            }
            for (project.archived_threads.items) |*thread| {
                thread.finishSendThread();
            }
        }
    }

    fn prepareThreadSendForShutdown(self: *AppState, project_path: []const u8, thread: *ChatThread) void {
        const send_state = thread.send_state;
        send_state.mutex.lock();
        if (send_state.status != .pending) {
            send_state.mutex.unlock();
            return;
        }
        if (send_state.daemon_owned) {
            runtime_log.diagnostic("shutdown leaving daemon-owned send running provider={s} thread_title_len={d}", .{ @tagName(thread.provider), thread.title.len });
            send_state.mutex.unlock();
            return;
        }
        send_state.stop_requested = true;
        send_state.stop_signal_sent = false;
        send_state.approval_decision = .deny;
        send_state.condition.broadcast();
        runtime_log.diagnostic("shutdown requested send stop provider={s} thread_title_len={d}", .{ @tagName(thread.provider), thread.title.len });
        send_state.mutex.unlock();

        self.issuePendingThreadStop(null, project_path, thread);
    }

    pub fn hasPendingStream(self: *AppState) bool {
        if (self.projects.items.len == 0) return false;
        return self.currentThread().isSendPendingForUi();
    }

    pub fn hasAnyPendingSends(self: *AppState) bool {
        if (self.pending_send_count > 0) return true;
        for (self.projects.items) |*project| {
            for (project.threads.items) |*thread| {
                if (thread.isSendPendingForUi()) return true;
            }
            for (project.archived_threads.items) |*thread| {
                if (thread.isSendPendingForUi()) return true;
            }
        }
        for (self.archived_projects.items) |*project| {
            for (project.threads.items) |*thread| {
                if (thread.isSendPendingForUi()) return true;
            }
            for (project.archived_threads.items) |*thread| {
                if (thread.isSendPendingForUi()) return true;
            }
        }
        return false;
    }

    pub fn isPickerPending(self: *AppState) bool {
        self.picker_state.mutex.lock();
        defer self.picker_state.mutex.unlock();
        return self.picker_state.status == .pending;
    }

    pub fn pendingApprovalSnapshot(self: *AppState) !?PendingApproval {
        if (self.projects.items.len == 0) return null;
        const send_state = self.currentThread().send_state;
        send_state.mutex.lock();
        defer send_state.mutex.unlock();

        if (send_state.status != .pending) return null;
        const approval = send_state.pending_approval orelse return null;
        return .{
            .call_id = try self.allocator.dupe(u8, approval.call_id),
            .title = try self.allocator.dupe(u8, approval.title),
            .body = try self.allocator.dupe(u8, approval.body),
        };
    }

    pub fn resolvePendingApproval(self: *AppState, decision: ai_harness.ApprovalDecision) void {
        if (self.projects.items.len == 0) return;
        const send_state = self.currentThread().send_state;
        send_state.mutex.lock();
        const daemon_turn_id = if (send_state.daemon_owned and send_state.daemon_turn_id != null)
            self.allocator.dupe(u8, send_state.daemon_turn_id.?) catch null
        else
            null;
        const call_id = if (send_state.pending_approval) |approval|
            self.allocator.dupe(u8, approval.call_id) catch null
        else
            null;
        if (send_state.pending_approval == null) {
            send_state.mutex.unlock();
            if (daemon_turn_id) |id| self.allocator.free(id);
            if (call_id) |id| self.allocator.free(id);
            return;
        }
        send_state.approval_decision = decision;
        send_state.ui_revision +%= 1;
        send_state.condition.broadcast();
        send_state.mutex.unlock();

        if (daemon_turn_id) |turn_id| {
            defer self.allocator.free(turn_id);
            const approval_call_id = call_id orelse return;
            defer self.allocator.free(approval_call_id);
            self.approveDaemonChatTurn(turn_id, approval_call_id, decision);
        } else if (call_id) |id| {
            self.allocator.free(id);
        }
    }

    fn applySendSuccess(self: *AppState, thread: *ChatThread, result: SendResultPayload, append_reply_text: bool) !void {
        if (thread.provider_thread_id) |thread_id| {
            self.allocator.free(thread_id);
        }
        thread.provider_thread_id = try self.allocator.dupeZ(u8, result.provider_thread_id);
        if (!append_reply_text) {
            thread.touch();
            self.markDirty();
            self.setSidebarNotice("Provider session updated.");
            return;
        }
        if (std.mem.trim(u8, result.reply_text, &std.ascii.whitespace).len > 0 and thread.messages.items.len > 0) {
            const last_message = thread.messages.items[thread.messages.items.len - 1];
            if (last_message.role != .assistant or !std.mem.eql(u8, last_message.body, result.reply_text)) {
                self.trimThreadMessages(thread, 1);
                try thread.messages.append(self.allocator, .{
                    .role = .assistant,
                    .author = try self.dupeZ(chat_threads.providerLabel(thread.provider)),
                    .body = try self.dupeZ(result.reply_text),
                    .image = null,
                });
            }
        } else if (std.mem.trim(u8, result.reply_text, &std.ascii.whitespace).len > 0) {
            self.trimThreadMessages(thread, 1);
            try thread.messages.append(self.allocator, .{
                .role = .assistant,
                .author = try self.dupeZ(chat_threads.providerLabel(thread.provider)),
                .body = try self.dupeZ(result.reply_text),
                .image = null,
            });
        }
        thread.touch();
        self.markDirty();
        self.setSidebarNotice("Provider session updated.");
    }

    fn applyPendingTimelineEvents(self: *AppState, thread: *ChatThread, events: *std.ArrayListUnmanaged(PendingTimelineEvent)) !void {
        if (events.items.len == 0) return;
        self.trimThreadMessages(thread, events.items.len);
        for (events.items) |event| {
            try thread.messages.append(self.allocator, .{
                .role = event.role,
                .author = try self.dupeZ(event.author),
                .body = try self.dupeZ(event.body),
                .image = null,
            });
            if (event.role == .system) {
                thread.noteBackgroundTaskEvent(self.allocator, event.author, event.body) catch |err| {
                    log.warn("failed to record background task event: {s}", .{@errorName(err)});
                };
            }
        }
        thread.touch();
        self.markDirty();
    }

    fn applySendFailure(
        self: *AppState,
        thread: *ChatThread,
        events: *std.ArrayListUnmanaged(PendingTimelineEvent),
        failure_message: []const u8,
    ) !void {
        self.trimThreadMessages(thread, events.items.len + 1);
        for (events.items) |event| {
            try thread.messages.append(self.allocator, .{
                .role = event.role,
                .author = try self.dupeZ(event.author),
                .body = try self.dupeZ(event.body),
                .image = null,
            });
            if (event.role == .system) {
                thread.noteBackgroundTaskEvent(self.allocator, event.author, event.body) catch |err| {
                    log.warn("failed to record background task event: {s}", .{@errorName(err)});
                };
            }
        }
        try thread.messages.append(self.allocator, .{
            .role = .system,
            .author = try self.dupeZ("System"),
            .body = try self.dupeZ(failure_message),
            .image = null,
        });
        thread.touch();
        self.markDirty();
    }

    fn resolveProjectPath(self: *AppState, raw_path: []const u8) ![]u8 {
        const expanded = try platform_paths.expandUserPath(self.allocator, raw_path);
        defer self.allocator.free(expanded);

        var threaded = std.Io.Threaded.init_single_threaded;
        const resolved = if (std.fs.path.isAbsolute(expanded))
            try std.Io.Dir.realPathFileAbsoluteAlloc(threaded.io(), expanded, self.allocator)
        else
            try std.Io.Dir.cwd().realPathFileAlloc(threaded.io(), expanded, self.allocator);

        var threaded_check = std.Io.Threaded.init_single_threaded;
        const dir = try std.Io.Dir.openDirAbsolute(threaded_check.io(), resolved, .{});
        dir.close(threaded_check.io());
        return resolved;
    }

    fn findProjectIndexByPath(self: *const AppState, path: []const u8) ?usize {
        for (self.projects.items, 0..) |project, index| {
            if (self.projectPathMatches(project.path, path)) return index;
        }
        return null;
    }

    fn findArchivedProjectIndexByPath(self: *const AppState, path: []const u8) ?usize {
        for (self.archived_projects.items, 0..) |project, index| {
            if (self.projectPathMatches(project.path, path)) return index;
        }
        return null;
    }

    fn projectPathMatches(self: *const AppState, left: []const u8, right: []const u8) bool {
        return platform_paths.projectPathsEqual(self.allocator, left, right) catch std.mem.eql(u8, left, right);
    }

    fn findThreadIndexByProviderThreadId(self: *const AppState, project_index: usize, provider: Provider, thread_id: []const u8) ?usize {
        if (project_index >= self.projects.items.len) return null;
        const project = &self.projects.items[project_index];
        for (project.threads.items, 0..) |thread, index| {
            if (thread.provider != provider) continue;
            const existing_id = thread.provider_thread_id orelse continue;
            if (std.mem.eql(u8, existing_id, thread_id)) return index;
        }
        return null;
    }

    fn deriveProjectId(self: *AppState, path: []const u8) ![]u8 {
        const comparison_key = try platform_paths.projectComparisonKeyAllocForOs(self.allocator, builtin.os.tag, path);
        defer self.allocator.free(comparison_key);
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(comparison_key);
        return std.fmt.allocPrint(self.allocator, "{x}", .{hasher.final()});
    }

    fn persistedImageSnapshot(allocator: std.mem.Allocator, image: ?ChatImageAttachment) !?PersistedImageAttachment {
        const attachment = image orelse return null;
        return .{
            .path = try allocator.dupe(u8, attachment.path),
            .mime = try allocator.dupe(u8, attachment.mime),
            .byte_size = attachment.byte_size,
        };
    }

    fn dupeOptionalSlice(allocator: std.mem.Allocator, value: ?[]const u8) !?[]const u8 {
        const slice = value orelse return null;
        return try allocator.dupe(u8, slice);
    }

    fn clearProjects(self: *AppState) void {
        self.cancelThreadImport();
        self.clearFileSearch();
        self.clearOpencodeModelOptions();
        if (self.file_search_state.finder) |*finder| {
            finder.deinit();
            self.file_search_state.finder = null;
        }
        if (self.file_search_state.project_path) |project_path| {
            self.allocator.free(project_path);
            self.file_search_state.project_path = null;
        }
        self.clearImageTextureCache();
        self.closeImageModal();
        self.closeTranscriptSelectionModal();
        self.clearTranscriptMarkdownSelection();
        self.clearTranscriptMarkdownEntries();
        for (self.projects.items) |*project| {
            project.deinit(self.allocator);
        }
        self.projects.clearRetainingCapacity();
        for (self.archived_projects.items) |*project| {
            project.deinit(self.allocator);
        }
        self.archived_projects.clearRetainingCapacity();
        self.selected_project_index = 0;
        self.next_project_number = 1;
        self.show_project_creator = false;
        self.clearImportPath();
        self.rename_storage[0] = 0;
        self.dirty = false;
    }

    fn defaultExplorerPath(self: *AppState) ![]u8 {
        if (self.importDirectoryDraft().len > 0) {
            return self.resolveProjectPath(std.mem.trim(u8, self.importDirectoryDraft(), &std.ascii.whitespace));
        }

        if (self.projects.items.len > 0) {
            if (self.resolveProjectPath(self.currentProject().path)) |resolved| {
                return resolved;
            } else |_| {}
        }

        return platform_paths.userHome(self.allocator) catch self.allocator.dupe(u8, ".");
    }

    fn pushCodeCopyButtonTrampoline(context: *anyopaque, hit: chat_markdown.CodeCopyButtonSink) void {
        const self: *AppState = @ptrCast(@alignCast(context));
        self.code_copy_buttons.append(self.allocator, hit) catch |err| {
            log.warn("failed to retain code copy button hit: {s}", .{@errorName(err)});
        };
    }

    /// Returns a recorder the markdown renderer can use to register per-frame
    /// code-block copy buttons. The "recent" feedback window (~1.2s) shows a
    /// transient "Copied" label after a click.
    pub fn codeCopyButtonRecorder(self: *AppState) chat_markdown.CodeCopyButtonRecorder {
        const now_ms: i64 = @intCast(@divTrunc(profiler.nowNs(), std.time.ns_per_ms));
        const active = self.code_copy_recent_until_ms != 0 and now_ms < self.code_copy_recent_until_ms;
        return .{
            .context = @ptrCast(self),
            .push_fn = pushCodeCopyButtonTrampoline,
            .recent_identity = if (active) self.code_copy_recent_identity else 0,
            .recent_active = active,
        };
    }

    /// Records a collapsible card header hit-rect for the current frame.
    /// Use `isCardExpanded` to read the persistent state during rendering and
    /// `consumeCardToggleClick` from the click handler.
    pub fn recordCardToggleHit(self: *AppState, hit: CardToggleHit) void {
        self.card_toggle_hits.append(self.allocator, hit) catch |err| {
            log.warn("failed to retain card toggle hit: {s}", .{@errorName(err)});
        };
    }

    /// Returns true when the given card key was previously toggled to expanded.
    pub fn isCardExpanded(self: *AppState, key: u64) bool {
        return self.expanded_cards.contains(key);
    }

    /// Hit-tests the most recent frame's card-toggle headers. On hit, flips
    /// the expanded state for that key and returns true.
    pub fn consumeCardToggleClick(self: *AppState, x: f32, y: f32) bool {
        for (self.card_toggle_hits.items) |hit| {
            if (x < hit.rect.x or x > hit.rect.x + hit.rect.w) continue;
            if (y < hit.rect.y or y > hit.rect.y + hit.rect.h) continue;
            if (self.expanded_cards.fetchRemove(hit.key) == null) {
                self.expanded_cards.put(hit.key, {}) catch |err| {
                    log.warn("failed to store expanded card: {s}", .{@errorName(err)});
                };
            }
            self.markDirty();
            return true;
        }
        return false;
    }

    /// Hit-tests the most recent frame's code-block copy buttons. On hit,
    /// writes the source text to the system clipboard, sets the "recent"
    /// feedback window, and returns true.
    pub fn consumeCodeCopyButtonClick(self: *AppState, x: f32, y: f32) bool {
        for (self.code_copy_buttons.items) |hit| {
            if (x < hit.rect.x or x > hit.rect.x + hit.rect.w) continue;
            if (y < hit.rect.y or y > hit.rect.y + hit.rect.h) continue;

            const payload = self.palette_frame_text.items[hit.payload_offset .. hit.payload_offset + hit.payload_len];
            const z = self.allocator.dupeZ(u8, payload) catch return true;
            defer self.allocator.free(z);
            sdl.setClipboardText(z) catch |err| {
                log.warn("failed to copy code block to clipboard: {s}", .{@errorName(err)});
                return true;
            };
            self.code_copy_recent_identity = hit.identity;
            const now_ms: i64 = @intCast(@divTrunc(profiler.nowNs(), std.time.ns_per_ms));
            self.code_copy_recent_until_ms = now_ms + 1200;
            self.markDirty();
            return true;
        }
        return false;
    }
};

fn importThreadFailureMessage(provider: Provider, err: anyerror) []const u8 {
    return switch (provider) {
        .codex => switch (err) {
            error.CodexRpcFailed => "Failed to load Codex threads.",
            error.ConnectionClosed => "Codex app-server connection closed.",
            error.NotConnected => "Could not connect to Codex app-server.",
            error.WebSocketUpgradeRejected => "Codex app-server rejected the connection.",
            error.FileNotFound => "The codex executable was not found on PATH.",
            error.UnsupportedOperation => "This provider does not support thread imports.",
            else => "Failed to load Codex threads.",
        },
        .opencode => switch (err) {
            error.OpencodeRequestFailed => "Failed to load OpenCode threads.",
            error.OpencodeServerUnavailable => "OpenCode did not start.",
            error.FileNotFound => "The opencode executable was not found on PATH.",
            error.UnsupportedOperation => "This provider does not support thread imports.",
            else => "Failed to load OpenCode threads.",
        },
        .claude => switch (err) {
            error.ClaudeRequestFailed => "Failed to load Claude threads.",
            error.FileNotFound => "The node executable was not found on PATH.",
            error.UnsupportedOperation => "Claude thread imports are not supported by this SDK.",
            else => "Failed to load Claude threads.",
        },
        .cursor => switch (err) {
            error.FileNotFound => "Cursor CLI `agent` was not found on PATH.",
            error.CursorSignedOut => "Cursor is not authenticated. Run `agent login` or set CURSOR_API_KEY.",
            error.UnsupportedOperation => "Cursor CLI does not support thread imports in this version.",
            else => "Failed to load Cursor threads.",
        },
    };
}

fn readThreadFailureMessage(provider: Provider, err: anyerror) []const u8 {
    return switch (provider) {
        .codex => switch (err) {
            error.CodexRpcFailed => "Failed to import the selected Codex thread.",
            error.ConnectionClosed => "Codex app-server connection closed.",
            error.NotConnected => "Could not connect to Codex app-server.",
            error.WebSocketUpgradeRejected => "Codex app-server rejected the connection.",
            error.FileNotFound => "The codex executable was not found on PATH.",
            error.MissingSessionId => "The selected Codex thread could not be found.",
            error.UnsupportedOperation => "This provider does not support thread imports.",
            else => "Failed to import the selected Codex thread.",
        },
        .opencode => switch (err) {
            error.OpencodeRequestFailed => "Failed to import the selected OpenCode thread.",
            error.OpencodeServerUnavailable => "OpenCode did not start.",
            error.FileNotFound => "The opencode executable was not found on PATH.",
            error.MissingSessionId => "The selected OpenCode thread could not be found.",
            error.UnsupportedOperation => "This provider does not support thread imports.",
            else => "Failed to import the selected OpenCode thread.",
        },
        .claude => switch (err) {
            error.ClaudeRequestFailed => "Failed to import the selected Claude thread.",
            error.FileNotFound => "The node executable was not found on PATH.",
            error.MissingSessionId => "The selected Claude thread could not be found.",
            error.UnsupportedOperation => "Claude thread imports are not supported by this SDK.",
            else => "Failed to import the selected Claude thread.",
        },
        .cursor => switch (err) {
            error.FileNotFound => "Cursor CLI `agent` was not found on PATH.",
            error.CursorSignedOut => "Cursor is not authenticated. Run `agent login` or set CURSOR_API_KEY.",
            error.MissingSessionId => "The selected Cursor thread could not be found.",
            error.UnsupportedOperation => "Cursor CLI does not support thread imports in this version.",
            else => "Failed to import the selected Cursor thread.",
        },
    };
}

fn providerReadinessWorker(state: *ProviderReadinessState) void {
    const snapshot: ProviderReadinessSnapshot = .{
        .codex = detectProviderReadiness(.codex),
        .opencode = detectProviderReadiness(.opencode),
        .claude = detectProviderReadiness(.claude),
        .cursor = detectProviderReadiness(.cursor),
    };

    state.mutex.lock();
    defer state.mutex.unlock();
    state.snapshot = snapshot;
    state.status = .completed;
}

fn detectProviderReadiness(provider: Provider) ProviderReadiness {
    const executable_ready = switch (provider) {
        .codex => process_env.commandExists("codex"),
        .opencode => process_env.commandExists("opencode"),
        .claude => process_env.commandExists("node") and process_env.commandExists("claude"),
        .cursor => process_env.commandExists("agent"),
    };
    if (!executable_ready) return .missing;

    const provider_config = switch (provider) {
        .codex => ai_harness.ProviderConfig{ .codex = .{} },
        .opencode => ai_harness.ProviderConfig{ .opencode = .{
            .allocator = std.heap.page_allocator,
            .working_directory = null,
            .launch_if_missing = true,
        } },
        .claude => ai_harness.ProviderConfig{ .claude = .{} },
        .cursor => ai_harness.ProviderConfig{ .cursor = .{} },
    };
    var client = ai_harness.connect(std.heap.page_allocator, provider_config) catch |err| {
        log.warn("provider readiness connect failed provider={s}: {s}", .{ @tagName(provider), @errorName(err) });
        return if (err == error.FileNotFound) .missing else .unavailable;
    };
    defer client.deinit();

    const auth_state = client.authState() catch |err| {
        log.warn("provider readiness auth failed provider={s}: {s}", .{ @tagName(provider), @errorName(err) });
        return if (err == error.FileNotFound) .missing else .unavailable;
    };
    return switch (auth_state) {
        .signed_in => .ready,
        .signed_out => .signed_out,
        .unknown, .pending => .unavailable,
    };
}

fn opencodeModelCacheWorker(state: *OpencodeModelCacheState) void {
    const provider_config = ai_harness.ProviderConfig{
        .opencode = .{
            .allocator = std.heap.page_allocator,
            .working_directory = null,
            .launch_if_missing = true,
        },
    };

    const models = blk: {
        var client = ai_harness.connect(std.heap.page_allocator, provider_config) catch |err| {
            log.warn("failed to connect to OpenCode for model discovery: {s}", .{@errorName(err)});
            break :blk null;
        };
        defer client.deinit();

        break :blk client.listModels(std.heap.page_allocator) catch |err| {
            log.warn("failed to load OpenCode configured models: {s}", .{@errorName(err)});
            break :blk null;
        };
    };

    state.mutex.lock();
    defer state.mutex.unlock();

    if (models) |loaded| {
        state.models = loaded;
        state.status = .completed;
    } else {
        state.status = .failed;
    }
}

fn cursorModelCacheWorker(state: *CursorModelCacheState) void {
    const provider_config = ai_harness.ProviderConfig{
        .cursor = .{},
    };

    const models = blk: {
        var client = ai_harness.connect(std.heap.page_allocator, provider_config) catch |err| {
            log.warn("failed to connect to Cursor for model discovery: {s}", .{@errorName(err)});
            break :blk null;
        };
        defer client.deinit();

        break :blk client.listModels(std.heap.page_allocator) catch |err| {
            log.warn("failed to load Cursor models: {s}", .{@errorName(err)});
            break :blk null;
        };
    };

    state.mutex.lock();
    defer state.mutex.unlock();

    if (models) |loaded| {
        state.models = loaded;
        state.status = .completed;
    } else {
        state.status = .failed;
    }
}

fn claudeModelCacheWorker(state: *ClaudeModelCacheState) void {
    const provider_config = ai_harness.ProviderConfig{
        .claude = .{},
    };

    const models = blk: {
        var client = ai_harness.connect(std.heap.page_allocator, provider_config) catch |err| {
            log.warn("failed to connect to Claude for model discovery: {s}", .{@errorName(err)});
            break :blk null;
        };
        defer client.deinit();

        break :blk client.listModels(std.heap.page_allocator) catch |err| {
            log.warn("failed to load Claude models: {s}", .{@errorName(err)});
            break :blk null;
        };
    };

    state.mutex.lock();
    defer state.mutex.unlock();

    if (models) |loaded| {
        state.models = loaded;
        state.status = .completed;
    } else {
        state.status = .failed;
    }
}

fn slashCommandWorker(state: *SlashCommandState, request: *SlashCommandWorkerRequest) void {
    const page_alloc = std.heap.page_allocator;
    defer {
        page_alloc.free(request.project_path);
        if (request.remote_ssh_host) |host| page_alloc.free(host);
        if (request.remote_cwd) |cwd| page_alloc.free(cwd);
        if (request.thread_id) |thread_id| page_alloc.free(thread_id);
        page_alloc.free(request.raw_text);
        page_alloc.free(request.args);
        page_alloc.destroy(request);
    }

    runtime_log.diagnostic(
        "slash command worker begin provider={s} command={s} thread_id_len={d}",
        .{ @tagName(request.provider), @tagName(request.command), if (request.thread_id) |thread_id| thread_id.len else 0 },
    );

    const result = runSlashCommandWorker(page_alloc, request);

    state.mutex.lock();
    defer state.mutex.unlock();
    defer loop_wakeup.notify();

    if (result) |payload| {
        runtime_log.diagnostic("slash command worker completed provider={s} command={s}", .{ @tagName(request.provider), @tagName(request.command) });
        state.result = payload;
        state.error_message = null;
        state.status = .completed;
    } else |err| {
        runtime_log.diagnostic("slash command worker failed provider={s} command={s}: {s}", .{ @tagName(request.provider), @tagName(request.command), @errorName(err) });
        state.result = null;
        state.error_message = formatSlashCommandError(page_alloc, request.provider, err) catch null;
        state.status = .failed;
    }
}

fn runSlashCommandWorker(
    allocator: std.mem.Allocator,
    request: *const SlashCommandWorkerRequest,
) !ai_harness.RunSlashCommandResult {
    if (request.harness != .local_cli) return error.UnsupportedHarnessMode;
    if (request.remote_ssh_host != null and request.provider != .codex) return error.UnsupportedRemoteProvider;
    const request_cwd = request.remote_cwd orelse request.project_path;

    const provider_config = switch (request.provider) {
        .opencode => ai_harness.ProviderConfig{
            .opencode = .{
                .allocator = allocator,
                .working_directory = request_cwd,
                .launch_if_missing = true,
            },
        },
        .codex => ai_harness.ProviderConfig{
            .codex = .{
                .cwd = request_cwd,
                .launch_on_connect = true,
                .remote_ssh = if (request.remote_ssh_host) |host| .{
                    .host = host,
                    .cwd = request_cwd,
                } else null,
            },
        },
        .claude => ai_harness.ProviderConfig{
            .claude = .{
                .cwd = request_cwd,
            },
        },
        .cursor => ai_harness.ProviderConfig{
            .cursor = .{
                .cwd = request_cwd,
            },
        },
    };

    var client = try ai_harness.connect(allocator, provider_config);
    defer client.deinit();

    return client.runSlashCommand(allocator, .{
        .thread_id = request.thread_id,
        .cwd = request_cwd,
        .command = request.command,
        .raw_text = request.raw_text,
        .args = request.args,
    });
}

fn formatSlashCommandError(allocator: std.mem.Allocator, provider: Provider, err: anyerror) ![]u8 {
    const message: []const u8 = switch (provider) {
        .codex => switch (err) {
            error.CodexRpcFailed => "Codex slash command failed.",
            error.ConnectionClosed => "Codex app-server connection closed.",
            error.NotConnected => "Could not connect to Codex app-server.",
            error.WebSocketUpgradeRejected => "Codex app-server rejected the connection.",
            error.FileNotFound => "The codex executable was not found on PATH.",
            error.UnsupportedRemoteProvider => "Remote Herdr slash commands currently support Codex only.",
            error.UnsupportedOperation => "Codex does not support this slash command yet.",
            else => "Codex slash command failed.",
        },
        .opencode => switch (err) {
            error.UnsupportedOperation => "OpenCode does not support this slash command yet.",
            else => "OpenCode slash command failed.",
        },
        .claude => switch (err) {
            error.UnsupportedOperation => "Claude does not support this slash command yet.",
            else => "Claude slash command failed.",
        },
        .cursor => switch (err) {
            error.UnsupportedOperation => "Cursor does not support this slash command yet.",
            else => "Cursor slash command failed.",
        },
    };
    return allocator.dupe(u8, message);
}

fn slashCommandFallbackName(command: ai_harness.ProviderSlashCommandId) []const u8 {
    return switch (command) {
        .usage => "/usage",
        .goal => "/goal",
        .compact => "/compact",
        .review => "/review",
        .shell => "/shell",
        .custom => "/command",
    };
}

fn syncThreadFailureMessage(provider: Provider, err: anyerror) []const u8 {
    return switch (provider) {
        .codex => switch (err) {
            error.CodexRpcFailed => "Failed to sync the Codex thread.",
            error.ConnectionClosed => "Codex app-server connection closed.",
            error.NotConnected => "Could not connect to Codex app-server.",
            error.WebSocketUpgradeRejected => "Codex app-server rejected the connection.",
            error.FileNotFound => "The codex executable was not found on PATH.",
            error.UnsupportedOperation => "This provider does not support thread sync.",
            else => "Failed to sync the Codex thread.",
        },
        .opencode => switch (err) {
            error.OpencodeRequestFailed => "Failed to sync the OpenCode thread.",
            error.OpencodeServerUnavailable => "OpenCode did not start.",
            error.FileNotFound => "The opencode executable was not found on PATH.",
            error.UnsupportedOperation => "This provider does not support thread sync.",
            else => "Failed to sync the OpenCode thread.",
        },
        .claude => switch (err) {
            error.ClaudeRequestFailed => "Failed to sync the Claude thread.",
            error.FileNotFound => "The node executable was not found on PATH.",
            error.UnsupportedOperation => "Claude thread sync is not supported by this SDK.",
            else => "Failed to sync the Claude thread.",
        },
        .cursor => switch (err) {
            error.FileNotFound => "Cursor CLI `agent` was not found on PATH.",
            error.CursorSignedOut => "Cursor is not authenticated. Run `agent login` or set CURSOR_API_KEY.",
            error.UnsupportedOperation => "Cursor CLI does not support thread sync in this version.",
            else => "Failed to sync the Cursor thread.",
        },
    };
}

fn failedToStoreThreadListNotice(provider: Provider) []const u8 {
    return switch (provider) {
        .codex => "Failed to store Codex thread list.",
        .opencode => "Failed to store OpenCode thread list.",
        .claude => "Failed to store Claude thread list.",
        .cursor => "Failed to store Cursor thread list.",
    };
}

fn noRecentThreadsNotice(provider: Provider) []const u8 {
    return switch (provider) {
        .codex => "No recent Codex threads found.",
        .opencode => "No recent OpenCode threads found.",
        .claude => "No recent Claude threads found.",
        .cursor => "No recent Cursor threads found.",
    };
}

fn selectThreadNotice(provider: Provider) []const u8 {
    return switch (provider) {
        .codex => "Select a Codex thread or paste a thread ID.",
        .opencode => "Select an OpenCode thread or paste a thread ID.",
        .claude => "Select a Claude thread or paste a thread ID.",
        .cursor => "Select a Cursor thread or paste a thread ID.",
    };
}

fn emptyThreadImportIdNotice(provider: Provider) []const u8 {
    return switch (provider) {
        .codex => "Enter a Codex thread ID or select one from the list.",
        .opencode => "Enter an OpenCode thread ID or select one from the list.",
        .claude => "Enter a Claude thread ID or select one from the list.",
        .cursor => "Enter a Cursor thread ID or select one from the list.",
    };
}

fn duplicateThreadNotice(provider: Provider) []const u8 {
    return switch (provider) {
        .codex => "Codex thread already exists in this workspace.",
        .opencode => "OpenCode thread already exists in this workspace.",
        .claude => "Claude thread already exists in this workspace.",
        .cursor => "Cursor thread already exists in this workspace.",
    };
}

fn failedCreateImportedThreadNotice(provider: Provider) []const u8 {
    return switch (provider) {
        .codex => "Failed to create the imported thread.",
        .opencode => "Failed to create the imported thread.",
        .claude => "Failed to create the imported thread.",
        .cursor => "Failed to create the imported thread.",
    };
}

fn failedAddImportedThreadNotice(provider: Provider) []const u8 {
    return switch (provider) {
        .codex => "Failed to add the imported thread.",
        .opencode => "Failed to add the imported thread.",
        .claude => "Failed to add the imported thread.",
        .cursor => "Failed to add the imported thread.",
    };
}

fn threadImportedNotice(provider: Provider) []const u8 {
    return switch (provider) {
        .codex => "Codex thread imported.",
        .opencode => "OpenCode thread imported.",
        .claude => "Claude thread imported.",
        .cursor => "Cursor thread imported.",
    };
}

fn threadSyncedNotice(provider: Provider) []const u8 {
    return switch (provider) {
        .codex => "Thread synced from Codex.",
        .opencode => "Thread synced from OpenCode.",
        .claude => "Thread synced from Claude.",
        .cursor => "Thread synced from Cursor.",
    };
}

fn projectEditorOpenedNotice(target: ProjectEditorTarget) []const u8 {
    return switch (target) {
        .configured => "Opened workspace in the configured editor.",
        .cursor => "Opened workspace in Cursor.",
        .vscode => "Opened workspace in VS Code.",
        .zed => "Opened workspace in Zed.",
    };
}

fn trailingFileSearchToken(draft: []const u8) ?FileSearchToken {
    if (draft.len == 0) return null;
    if (std.ascii.isWhitespace(draft[draft.len - 1])) return null;

    var token_start = draft.len;
    while (token_start > 0 and !std.ascii.isWhitespace(draft[token_start - 1])) {
        token_start -= 1;
    }

    if (draft[token_start] != '@') return null;
    return .{
        .at_start = token_start,
        .query_start = token_start + 1,
        .end = draft.len,
    };
}

test "empty workspace ignores hidden composer and slash input" {
    var state: AppState = undefined;
    state.projects = .empty;
    state.selected_project_index = 0;

    try std.testing.expect(!state.slashCommandPickerActive());
    try std.testing.expectEqual(@as(usize, 0), state.slashCommandPickerRowCount());
    try std.testing.expect(state.slashCommandPickerRow(0) == null);

    var key_event: sdl.KeyboardEvent = undefined;
    var button_event: sdl.MouseButtonEvent = undefined;
    var motion_event: sdl.MouseMotionEvent = undefined;
    var wheel_event: sdl.MouseWheelEvent = undefined;
    try std.testing.expect(!state.routePaletteComposerTextInput("ignored"));
    try std.testing.expect(!state.routePaletteComposerKeyDown(&key_event));
    try std.testing.expect(!state.routePaletteComposerMouseButton(&button_event, 1.0));
    try std.testing.expect(!state.routePaletteComposerMouseMotion(&motion_event, 1.0));
    try std.testing.expect(!state.routePaletteComposerWheel(&wheel_event, 1.0));
    try std.testing.expect(!state.handleComposerWheel(&wheel_event));
    try std.testing.expect(!state.handleComposerDraftImageClearMouseButton(0.0, 0.0, true));
    try std.testing.expect(!state.attachClipboardImageToCurrentDraft());
    try std.testing.expect(!state.pasteClipboardTextIntoPaletteComposer());

    state.syncPaletteComposerFromDraft();
    state.syncDraftFromPaletteComposer();
    state.syncPaletteComposerControls();
    state.openPaletteModelPicker();
    state.openRunConfigPopover();
    state.clearCurrentDraftImageAt(0);
}

test "completed OpenCode model refresh tolerates zero workspaces" {
    const allocator = std.testing.allocator;
    const page = std.heap.page_allocator;

    const models = try page.alloc(ai_harness.ModelInfo, 1);
    models[0] = .{
        .provider_id = try page.dupe(u8, "test-provider"),
        .provider_name = try page.dupe(u8, "Test Provider"),
        .model_id = try page.dupe(u8, "test-model"),
        .model_name = try page.dupe(u8, "Test Model"),
    };

    var state: AppState = undefined;
    state.allocator = allocator;
    state.projects = .empty;
    state.selected_project_index = 0;
    state.opencode_model_options = .empty;
    state.opencode_reasoning_menu = .empty;
    state.opencode_model_cache_state = .{
        .status = .completed,
        .models = models,
    };
    defer {
        state.clearOpencodeModelOptions();
        state.opencode_model_options.deinit(allocator);
        state.opencode_reasoning_menu.deinit(allocator);
    }

    state.pollOpencodeModelOptionsCache();

    try std.testing.expectEqual(@as(usize, 0), state.projects.items.len);
    try std.testing.expect(state.opencode_model_options.items.len > 0);
}

test "new Codex threads default to GPT-5.6 Sol with low reasoning" {
    try std.testing.expectEqualStrings("gpt-5.6-sol", DEFAULT_CODEX_MODEL);
    try std.testing.expectEqual(ReasoningEffort.low, DEFAULT_CODEX_REASONING_EFFORT);
    try std.testing.expectEqualStrings(DEFAULT_CODEX_MODEL, CODEX_MODEL_OPTIONS[0].value.?);

    var thread = try ChatThread.init(std.testing.allocator, "New thread");
    defer thread.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(DEFAULT_CODEX_MODEL, thread.model_ref.?);
    try std.testing.expectEqual(DEFAULT_CODEX_REASONING_EFFORT, thread.reasoning_effort.?);
}

test "initial send snapshot restores retryable draft and attachment" {
    const allocator = std.testing.allocator;
    var thread = try ChatThread.init(allocator, "New thread");
    defer thread.deinit(allocator);
    thread.setDraft("retry this prompt");
    try thread.setDraftImage(allocator, "/tmp/retry.png", "image/png", 42);

    var state: AppState = undefined;
    state.allocator = allocator;
    state.image_texture_cache = std.StringHashMap(CachedImageTexture).init(allocator);
    defer state.image_texture_cache.deinit();
    state.dirty = false;
    state.last_dirty_at_ms = 0;
    state.last_interaction_at_ms = 0;

    var snapshot = try InitialSendSnapshot.init(allocator, &thread);
    defer snapshot.deinit(allocator);
    try thread.commitFromPrompt(allocator, thread.currentDraft());
    try state.appendMessageToThread(&thread, .user, "You", thread.currentDraft(), &thread.draft_image.?, &.{});

    snapshot.restore(&state, &thread);
    try std.testing.expect(!thread.committed);
    try std.testing.expectEqualStrings("New thread", thread.title);
    try std.testing.expectEqual(@as(usize, 0), thread.messages.items.len);
    try std.testing.expectEqualStrings("retry this prompt", thread.currentDraft());
    try std.testing.expectEqual(@as(usize, 1), thread.draftImageCount());
}

test "workspace layout prunes stale root leaves" {
    const allocator = std.testing.allocator;
    var layout = try WorkspaceLayout.initDefaultChat(allocator);
    defer layout.deinit(allocator);

    const stale_leaf = try WorkspaceLayout.createLeafNode(allocator, 999);
    const existing_root = layout.root.?;
    const split = allocator.create(WorkspaceNode) catch |err| {
        WorkspaceLayout.destroyNode(allocator, stale_leaf);
        return err;
    };
    split.* = .{ .split = .{
        .axis = .vertical,
        .ratio = 0.5,
        .first = stale_leaf,
        .second = existing_root,
    } };
    layout.root = split;

    _ = try layout.ensureDefaultChat(allocator);

    const root = layout.root orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(WorkspacePaneId, 1), switch (root.*) {
        .leaf => |pane_id| pane_id,
        .split => return error.TestExpectedEqual,
    });
    try std.testing.expectEqual(@as(?WorkspacePaneId, 1), layout.focused_pane_id);
}

test "workspace layout grid placement follows pane hotkey order" {
    const allocator = std.testing.allocator;
    var layout = try WorkspaceLayout.initDefaultChat(allocator);
    defer layout.deinit(allocator);

    var placement = layout.gridNewPanePlacement() orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(WorkspacePaneId, 1), placement.pane_id);
    try std.testing.expectEqual(WorkspaceSplitAxis.vertical, placement.axis);
    try std.testing.expect(placement.new_after);

    const pane2 = try layout.createTerminalPane(allocator, 10);
    try layout.splitPaneWithLeaf(allocator, placement.pane_id, pane2, placement.axis, placement.new_after);

    placement = layout.gridNewPanePlacement() orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(WorkspacePaneId, 1), placement.pane_id);
    try std.testing.expectEqual(WorkspaceSplitAxis.horizontal, placement.axis);
    try std.testing.expect(placement.new_after);

    const pane3 = try layout.createTerminalPane(allocator, 11);
    try layout.splitPaneWithLeaf(allocator, placement.pane_id, pane3, placement.axis, placement.new_after);

    placement = layout.gridNewPanePlacement() orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(pane2, placement.pane_id);
    try std.testing.expectEqual(WorkspaceSplitAxis.horizontal, placement.axis);
    try std.testing.expect(placement.new_after);
}

fn unixTimestampSeconds() i64 {
    return @divTrunc(unixTimestampMs(), std.time.ms_per_s);
}

fn unixTimestampMs() i64 {
    return platform_runtime.unixTimestampMs();
}

fn ensureJsonRpcOk(allocator: std.mem.Allocator, response: []const u8) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, response, .{});
    defer parsed.deinit();
    _ = try jsonRpcResult(parsed.value);
}

fn initialSendStartFailureMessage(_: anyerror) []const u8 {
    return "Verde could not start this message. Your draft and attachments are still in the composer; try Send again.";
}

fn ambiguousInitialSendFailureMessage() []const u8 {
    return "Verde could not confirm that the provider request started. Your submitted message is preserved above; copy it before retrying.";
}

fn jsonRpcResult(value: std.json.Value) !std.json.Value {
    if (value != .object) return error.InvalidDaemonResponse;
    if (value.object.get("error")) |_| return error.DaemonRequestFailed;
    return value.object.get("result") orelse return error.InvalidDaemonResponse;
}

fn jsonValueString(value: std.json.Value) ?[]const u8 {
    return switch (value) {
        .string => |text| text,
        else => null,
    };
}

fn jsonValueU64(value: std.json.Value) ?u64 {
    return switch (value) {
        .integer => |int| if (int >= 0) @intCast(int) else null,
        .number_string => |text| std.fmt.parseInt(u64, text, 10) catch null,
        else => null,
    };
}

fn replacePageOwned(slot: *?[]u8, value: []const u8) !void {
    if (slot.*) |existing| {
        if (std.mem.eql(u8, existing, value)) return;
    }
    const next = try std.heap.page_allocator.dupe(u8, value);
    if (slot.*) |existing| std.heap.page_allocator.free(existing);
    slot.* = next;
}

fn daemonPayloadStringAlloc(payload_json: []const u8, field: []const u8) ?[]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, payload_json, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const value = jsonValueString(parsed.value.object.get(field) orelse .null) orelse return null;
    return std.heap.page_allocator.dupe(u8, value) catch null;
}
