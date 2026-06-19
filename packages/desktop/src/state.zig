const std = @import("std");
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
const keybinds = @import("keybinds.zig");
const loop_wakeup = @import("loop_wakeup.zig");
const notifier = @import("notifier.zig");
const provider_hooks = @import("provider_hooks.zig");
const runtime_log = @import("runtime_log.zig");
const slash_commands = @import("slash_commands.zig");
const stack_config = @import("stack.zig");
const stb_image = @import("stb_image.zig");
const terminal = @import("terminal/terminal.zig");
const theme = @import("ui/theme.zig");
const text_measure = @import("ui/text_measure.zig");
const utils = @import("utils.zig");

/// Arrow-key line step for transcript scroll (scaled px per key repeat).
const TRANSCRIPT_KEYBOARD_LINE_PX: f32 = 29.0;
const STACK_CONFIG_REFRESH_MS: i64 = 2000;
const BACKGROUND_TASK_POLL_MS: i64 = 1000;
const MANAGED_PROCESS_BASE_RESTART_BACKOFF_MS: i64 = 1000;
const MANAGED_PROCESS_MAX_RESTART_BACKOFF_MS: i64 = 30000;
const MANAGED_PROCESS_WATCH_SCAN_MS: i64 = 1000;
const MANAGED_PROCESS_WATCH_DEBOUNCE_MS: i64 = 500;

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
    image_close,
    project_rename_cancel,
    project_rename_submit,
    transcript_close,
    thread_import_refresh,
    thread_import_cancel,
    thread_import_submit,
    thread_import_select,
    project_import_browse,
    project_import_submit,
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
    .reasoning_max_width = 160.0,
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

const COMPOSER_MODEL_CASCADE_WIDTH: f32 = 440.0;
const COMPOSER_MODEL_CASCADE_ROW_HEIGHT: f32 = 42.0;
const COMPOSER_MODEL_CASCADE_PADDING_Y: f32 = 12.0;
const COMPOSER_MODEL_CASCADE_VISIBLE_ROWS: usize = 8;
const COMPOSER_MODEL_CASCADE_GAP: f32 = 8.0;
const COMPOSER_MODEL_CASCADE_ROOT_DROP: f32 = 26.0;
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

fn paletteReasoningLabel(context: ?*anyopaque, index: usize) []const u8 {
    const state = appStateFromContext(context) orelse return "";
    const thread = state.currentThread();
    if (thread.provider == .codex) {
        if (index >= CODEX_REASONING_OPTIONS.len) return "";
        return CODEX_REASONING_OPTIONS[index].label;
    }
    if (thread.provider == .cursor) {
        const rows = state.opencode_reasoning_menu.items;
        if (index >= rows.len) return "";
        return rows[index].label;
    }
    const rows = state.opencode_reasoning_menu.items;
    if (index >= rows.len) return "";
    return rows[index].label;
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
        .model_clicked, .reasoning_clicked => {},
    }
}

fn paletteComposerGetClipboard(context: ?*anyopaque, allocator: std.mem.Allocator) ?[]u8 {
    _ = allocator;
    const state = appStateFromContext(context) orelse return null;
    return state.readClipboardTextForPaste();
}

fn providerForComposerCascadeIndex(index: usize) ?Provider {
    if (index >= COMPOSER_PROVIDER_OPTIONS.len) return null;
    return COMPOSER_PROVIDER_OPTIONS[index];
}

fn composerCascadeIndexForProvider(provider: Provider) ?usize {
    for (COMPOSER_PROVIDER_OPTIONS, 0..) |candidate, index| {
        if (candidate == provider) return index;
    }
    return null;
}

fn paletteModelCascadeLabel(context: ?*anyopaque, path: []const usize, index: usize) []const u8 {
    const state = appStateFromContext(context) orelse return "";
    if (path.len == 0) {
        const provider = providerForComposerCascadeIndex(index) orelse return "";
        return chat_threads.providerLabel(provider);
    }
    if (path.len == 1) {
        const provider = providerForComposerCascadeIndex(path[0]) orelse return "";
        const options = composerModelOptions(state, provider);
        if (index >= options.len) return "";
        return options[index].label;
    }
    return "";
}

fn paletteModelCascadeChildCount(context: ?*anyopaque, path: []const usize, index: usize) usize {
    const state = appStateFromContext(context) orelse return 0;
    if (path.len != 0) return 0;
    const provider = providerForComposerCascadeIndex(index) orelse return 0;
    return composerModelOptions(state, provider).len;
}

fn paletteModelCascadeRenderRowLeading(
    context: ?*anyopaque,
    allocator: std.mem.Allocator,
    batch: *palette.draw.RenderBatch,
    depth: usize,
    path: []const usize,
    index: usize,
    clip: palette.draw.Rect,
    leading_rect: palette.draw.Rect,
) void {
    _ = path;
    if (depth != 0) return;
    const state = appStateFromContext(context) orelse return;
    const provider = providerForComposerCascadeIndex(index) orelse return;
    const tex = switch (provider) {
        .codex => state.codex_logo_texture,
        .opencode => state.opencode_logo_texture,
        .claude => state.claude_logo_texture,
        .cursor => state.cursor_logo_texture,
    } orelse return;
    if (!tex.valid or tex.texture_id == 0) return;
    const inner = @min(leading_rect.w, leading_rect.h);
    const sz = inner * @min(0.68 * 1.5, 0.96);
    const ix = leading_rect.x + (leading_rect.w - sz) * 0.5;
    const iy = leading_rect.y + (leading_rect.h - sz) * 0.5;
    const slot: palette.Rect = .{ .x = ix, .y = iy, .w = sz, .h = sz };
    const c = utils.snapImageRectToPixels(utils.imageRectContain(tex.width, tex.height, slot.x, slot.y, slot.w, slot.h));
    const r: palette.Rect = .{ .x = c.x, .y = c.y, .w = c.w, .h = c.h };
    batch.image(allocator, r, palette.TextureId.init(tex.texture_id), .{
        .x = 0.0,
        .y = 0.0,
        .w = 1.0,
        .h = 1.0,
    }, .{ .r = 1.0, .g = 1.0, .b = 1.0, .a = 1.0 }, clip) catch {};
}

fn paletteModelCascadeStyle() palette.CascadeMenuStyle {
    return .{
        .background_color = paletteColor(theme.COLOR_PANEL_ALT),
        .border_color = paletteColor(theme.COLOR_PANEL_MUTED),
        .highlighted_color = paletteColor(theme.withAlpha(theme.selection(), 190)),
        .text_color = paletteColor(theme.COLOR_WHITE),
        .icon_color = paletteColor(theme.COLOR_TEXT_MUTED),
        .scrollbar_track_color = paletteColor(theme.withAlpha(theme.COLOR_PANEL_MUTED, 110)),
        .scrollbar_thumb_color = paletteColor(theme.withAlpha(theme.COLOR_TEXT_MUTED, 220)),
    };
}

pub const PaletteModelCascadeMenu = palette.cascadeMenu(.{
    .width = COMPOSER_MODEL_CASCADE_WIDTH,
    .row_height = COMPOSER_MODEL_CASCADE_ROW_HEIGHT,
    .max_visible_rows = COMPOSER_MODEL_CASCADE_VISIBLE_ROWS,
    .max_depth = 2,
    .padding_x = 14.0,
    .padding_y = COMPOSER_MODEL_CASCADE_PADDING_Y,
    .submenu_gap = COMPOSER_MODEL_CASCADE_GAP,
    .glyph_width = 10.8,
    .font_size = 20.0,
    .chevron_icon = "\u{EAB6}",
    .icon_gap = 12.0,
    .row_leading_width = 34.0,
    .row_leading_to_label_gap = 8.0,
    .render_row_leading = paletteModelCascadeRenderRowLeading,
    .background_color = .{ .r = 0.09, .g = 0.10, .b = 0.13, .a = 1.0 },
    .border_color = .{ .r = 0.24, .g = 0.28, .b = 0.34, .a = 1.0 },
    .highlighted_color = .{ .r = 0.18, .g = 0.21, .b = 0.27, .a = 1.0 },
    .text_color = .{ .r = 0.92, .g = 0.94, .b = 0.98, .a = 1.0 },
    .icon_color = .{ .r = 0.67, .g = 0.71, .b = 0.80, .a = 1.0 },
    .scrollbar_track_color = .{ .r = 0.17, .g = 0.19, .b = 0.22, .a = 0.55 },
    .scrollbar_thumb_color = .{ .r = 0.48, .g = 0.54, .b = 0.64, .a = 0.88 },
    .scrollbar_width = 5.0,
    .corner_radius = 14.0,
    .border_width = 1.0,
    .z_index = 1400,
    .submenu_z_offset = 20,
    .placement = .above,
    .submenu_placement = .right,
    .avoid_forbidden_for_root = false,
    .avoid_forbidden_for_submenus = true,
    .item_count = COMPOSER_PROVIDER_OPTIONS.len,
    .item_label = paletteModelCascadeLabel,
    .child_count = paletteModelCascadeChildCount,
});

fn paletteModelCascadeEvent(context: ?*anyopaque, event: palette.CascadeMenuEvent) void {
    const state = appStateFromContext(context) orelse return;
    switch (event) {
        .selected => |selection| {
            if (selection.path.len != 1) return;
            const provider = providerForComposerCascadeIndex(selection.path[0]) orelse return;
            const options = composerModelOptions(state, provider);
            if (selection.index >= options.len) return;
            state.setCurrentThreadProvider(provider);
            state.setCurrentThreadModelRef(options[selection.index].value);
            state.syncPaletteComposerControls();
        },
        .highlighted, .open_changed => {},
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
pub const DEFAULT_CODEX_MODEL: [:0]const u8 = "gpt-5.5";
pub const DEFAULT_OPENCODE_MODEL: [:0]const u8 = "opencode/gpt-5.4";
pub const DEFAULT_CLAUDE_MODEL: [:0]const u8 = "default";
pub const DEFAULT_CURSOR_MODEL: [:0]const u8 = "composer-2";
pub const IMAGE_MODAL_ID: [:0]const u8 = "AttachmentPreviewModal";
pub const THREAD_IMPORT_MODAL_ID: [:0]const u8 = "ThreadImportModal";
pub const TRANSCRIPT_SELECTION_MODAL_ID: [:0]const u8 = "TranscriptSelectionModal";
pub const VERDE_LOGO_BYTES = @embedFile("assets/verde_logo.png");
pub const OPENCODE_LOGO_BYTES = @embedFile("assets/opencode-logo-dark.png");
pub const CODEX_LOGO_BYTES = @embedFile("assets/OpenAI-white-monoblossom.png");
pub const CLAUDE_LOGO_BYTES = @embedFile("assets/claude-logo.png");
pub const THREAD_EDIT_BYTES = @embedFile("assets/thread_edit.png");
pub const CURSOR_LOGO_BYTES = @embedFile("assets/editor_logos/cursor.png");
pub const EMACS_LOGO_BYTES = @embedFile("assets/editor_logos/emacs.png");
pub const NEOVIM_LOGO_BYTES = @embedFile("assets/editor_logos/neovim.png");
pub const VSCODE_LOGO_BYTES = @embedFile("assets/editor_logos/vscode.png");
pub const ZED_LOGO_BYTES = @embedFile("assets/editor_logos/zed.png");

const LoadedPersistedState = db_types.LoadedState;
const PersistedImageAttachment = db_types.PersistedImageAttachment;
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
    .{ .label = "GPT-5.5", .value = "gpt-5.5" },
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

        return .{
            .title = try allocator.dupeZ(u8, title),
            .committed = false,
            .last_activity_at = 0,
            .model_ref = try allocator.dupeZ(u8, DEFAULT_CODEX_MODEL),
            .reasoning_effort = .medium,
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
        return try allocPrintZCompat(allocator, "/tmp/verde-claude-bg-{s}.pid", .{task_id});
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
        if (backgroundTaskMetadataValue(body_raw, "Verde task ID:")) |task_id| {
            const previous_matches = task.task_id != null and std.mem.eql(u8, task.task_id.?, task_id);
            try replaceOptionalZ(allocator, &task.task_id, task_id);
            if (task.pid_path == null or !previous_matches) {
                if (task.pid_path) |existing| allocator.free(existing);
                task.pid_path = try backgroundTaskPidPathForId(allocator, task_id);
            }
        }
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
    command: ai_harness.ProviderSlashCommandId = .usage,
    result: ?ai_harness.RunSlashCommandResult = null,
    error_message: ?[]u8 = null,
};

const SlashCommandWorkerRequest = struct {
    provider: Provider,
    harness: Harness,
    project_path: []u8,
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
        var process: ManagedProcess = .{
            .name = try allocator.dupe(u8, definition.name),
            .kind = definition.kind,
            .command = try allocator.dupe(u8, definition.command),
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
        for (definition.watch.items) |pattern| {
            try process.watch.append(allocator, try allocator.dupe(u8, pattern));
        }
        return process;
    }

    fn updateFromDefinition(self: *ManagedProcess, allocator: std.mem.Allocator, definition: stack_config.ProcessDefinition) !void {
        self.kind = definition.kind;
        self.restart = definition.restart;
        self.provider = definition.provider;
        self.revive = definition.revive;
        self.notify = definition.notify;
        self.mcp = definition.mcp;
        self.hooks = definition.hooks;
        var reset_watch_state = false;
        if (!std.mem.eql(u8, self.command, definition.command)) {
            allocator.free(self.command);
            self.command = try allocator.dupe(u8, definition.command);
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
            try self.watch.append(allocator, try allocator.dupe(u8, pattern));
        }
        if (reset_watch_state) self.resetWatchState();
    }

    fn deinit(self: *ManagedProcess, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.command);
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
};

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

fn defaultAgentTui(provider: stack_config.AgentProvider) ?DefaultAgentTui {
    return switch (provider) {
        .codex => .{ .name = "codex", .command = "codex", .provider = .codex, .notify = true, .mcp = true, .hooks = true },
        .claude => .{ .name = "claude", .command = "claude", .provider = .claude },
        .opencode => .{ .name = "opencode", .command = OPENCODE_TUI_COMMAND, .provider = .opencode },
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

pub const Project = struct {
    id: [:0]const u8,
    label: [:0]const u8,
    path: [:0]const u8,
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

    fn archiveAllThreads(self: *Project, allocator: std.mem.Allocator) !void {
        while (self.threads.items.len > 0) {
            var thread = self.threads.orderedRemove(self.threads.items.len - 1);
            thread.archived = true;
            try self.archived_threads.append(allocator, thread);
        }
        self.selected_thread_index = 0;
        self.invalidateSidebarThreadCache();
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
    palette_model_cascade: PaletteModelCascadeMenu,
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
    /// Command palette (Ctrl+P overlay). `ui/command_palette.zig` owns result
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
    show_settings_modal: bool,
    settings_draft: SettingsDraft,
    settings_hook_claude_installed: bool,
    settings_hook_codex_installed: bool,
    settings_scroll_y: f32,
    settings_hover_control: ?u8,
    settings_close_hovered: bool,
    app_config_file_mtime: i128,
    app_config_runtime_sync_pending: bool,
    project_directory_browse_requested: bool,
    picker_state: PickerState,
    slash_command_state: SlashCommandState,
    opencode_model_cache_state: OpencodeModelCacheState,
    claude_model_cache_state: ClaudeModelCacheState,
    cursor_model_cache_state: CursorModelCacheState,
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
    /// Monotonic ms timestamp of the last visible terminal output, driving a
    /// short fast-poll burst so TUI redraws aren't capped at the idle wake
    /// cadence (terminal output is pull-only; there is no fd to wake on).
    last_terminal_output_ms: i64,

    pub const InitOptions = struct {
        gl_texture_uploads_enabled: bool = true,
        browser_textures_enabled: bool = true,
        texture_upload_context: ?*anyopaque = null,
        texture_upload_fn: ?TextureUploadFn = null,
    };

    pub const TextureUploadFn = *const fn (context: ?*anyopaque, loaded: stb_image.LoadedImage) ?CachedImageTexture;

    pub fn init(allocator: std.mem.Allocator, storage: *const Storage, initial_config: app_config.AppConfig, options: InitOptions) !AppState {
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
            .palette_model_cascade = PaletteModelCascadeMenu.initFromConfig(),
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
            .command_palette_open = false,
            .command_palette_scope_project = null,
            .command_palette_query_storage = std.mem.zeroes([256:0]u8),
            .command_palette_cursor = 0,
            .command_palette_selected = 0,
            .command_palette_action_menu_open = false,
            .command_palette_action_selected = 0,
            .keyboard_config = null,
            .show_project_creator = false,
            .show_settings_modal = false,
            .settings_draft = .{},
            .settings_hook_claude_installed = false,
            .settings_hook_codex_installed = false,
            .settings_scroll_y = 0.0,
            .settings_hover_control = null,
            .settings_close_hovered = false,
            .app_config_file_mtime = -1,
            .app_config_runtime_sync_pending = false,
            .project_directory_browse_requested = false,
            .picker_state = .{},
            .slash_command_state = .{},
            .opencode_model_cache_state = .{},
            .claude_model_cache_state = .{},
            .cursor_model_cache_state = .{},
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
            .last_terminal_output_ms = 0,
        };
        state.palette_composer.setCallbacks(.{});

        if (try storage.load(allocator)) |persisted_value| {
            var persisted = persisted_value;
            defer persisted.deinit();
            try state.applyPersisted(persisted.value);
        } else {
            try state.seedDefaultState();
        }
        state.loadCursorModelOptionsDiskCache() catch |err| {
            log.warn("failed to load Cursor model cache: {s}", .{@errorName(err)});
            state.clearCursorModelOptions();
        };
        if (options.gl_texture_uploads_enabled or options.texture_upload_fn != null) {
            state.logo_texture = state.loadEmbeddedTexture(VERDE_LOGO_BYTES);
            state.opencode_logo_texture = state.loadEmbeddedTexture(OPENCODE_LOGO_BYTES);
            state.codex_logo_texture = state.loadEmbeddedTexture(CODEX_LOGO_BYTES);
            state.claude_logo_texture = state.loadEmbeddedTexture(CLAUDE_LOGO_BYTES);
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
            var restored = self.archived_projects.orderedRemove(archived_index);
            restored.archived = false;
            restored.unread_count = unread_count;
            if (restored.threads.items.len == 0) {
                _ = try restored.addThread(self.allocator);
            }
            try restored.normalize(self.allocator, self.app_config.terminal_font_size);
            try self.projects.append(self.allocator, restored);
            self.markDirty();
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
        self.setSidebarNotice(if (add_result == .restored) "Workspace restored from archive." else "Workspace imported.");
        self.markDirty();
        return .{
            .index = index,
            .restored = add_result == .restored,
        };
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

    pub fn importProjectFromInput(self: *AppState) !void {
        _ = self.createProjectFromPath(self.importDirectoryDraft()) catch |err| switch (err) {
            error.EmptyProjectPath => {
                self.setSidebarNotice("Enter a workspace directory path first.");
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

    pub fn browseForProjectDirectory(self: *AppState) void {
        runtime_log.diagnostic("browseForWorkspaceDirectory entry show_project_creator={} draft_len={d}", .{ self.show_project_creator, self.importDirectoryDraft().len });
        log.info("browseForWorkspaceDirectory entry show_project_creator={} draft_len={d}", .{ self.show_project_creator, self.importDirectoryDraft().len });
        const target_path = self.defaultExplorerPath() catch |err| {
            runtime_log.diagnostic("browseForWorkspaceDirectory defaultExplorerPath failed: {s}", .{@errorName(err)});
            log.warn("browseForWorkspaceDirectory defaultExplorerPath failed: {s}", .{@errorName(err)});
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
            self.setSidebarNotice("Folder picker already open.");
            return;
        }

        self.picker_state.status = .pending;
        self.picker_state.selected_path = null;
        self.picker_state.worker = std.Thread.spawn(.{}, pickerWorker, .{ &self.picker_state, owned_target }) catch {
            page_alloc.free(owned_target);
            self.picker_state.status = .failed;
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

    pub fn beginThreadImport(self: *AppState, index: usize, provider: Provider) void {
        if (index >= self.projects.items.len) return;
        if (self.show_project_creator) self.cancelProjectImport();
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

    /// Opens the command palette overlay. `scope_project` restricts results to
    /// one workspace's thread history (the sidebar "History" entry point);
    /// `null` is the global Ctrl+P scope (commands + threads everywhere).
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
            self.setThreadImportNotice(importThreadFailureMessage(provider, err));
            return;
        };
        defer imported_thread.deinit(self.allocator);

        var imported = self.buildImportedThread(imported_thread, null) catch {
            self.setThreadImportNotice(failedCreateImportedThreadNotice(provider));
            return;
        };
        errdefer imported.deinit(self.allocator);

        imported.provider = provider;
        if (imported.model_ref) |model_ref| {
            self.allocator.free(model_ref);
            imported.model_ref = null;
        }
        imported.model_ref = self.allocator.dupeZ(u8, self.cachedDefaultModelRefForProvider(provider)) catch {
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

    pub fn archiveProjectAtIndex(self: *AppState, index: usize) void {
        _ = self.archiveProjectAtIndexResult(index);
    }

    pub fn archiveProjectAtIndexResult(self: *AppState, index: usize) bool {
        if (index >= self.projects.items.len) return false;
        if (self.projectHasPendingSend(index)) {
            self.setSidebarNotice("Finish this workspace's running provider requests before archiving it.");
            return false;
        }

        self.cancelThreadImport();
        var removed = self.projects.orderedRemove(index);
        removed.archived = true;
        removed.terminal_dock.visible = false;
        removed.archiveAllThreads(self.allocator) catch {
            removed.deinit(self.allocator);
            self.setSidebarNotice("Failed to archive the workspace.");
            return false;
        };
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
        self.setSidebarNotice("Workspace archived.");
        self.markDirty();
        return true;
    }

    fn archiveSelectedProject(self: *AppState) void {
        if (self.projects.items.len == 0) return;
        _ = self.archiveProjectAtIndexResult(self.selected_project_index);
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

    pub fn sendDraft(self: *AppState) !void {
        const draft = self.currentDraft();
        const draft_image = self.currentThread().draft_image;
        const draft_image_count = self.currentThread().draftImageCount();
        if (draft.len == 0 and draft_image_count == 0) return;

        if (self.currentThread().isSendPending()) {
            self.setSidebarNotice("This chat already has a provider request running.");
            return;
        }

        const trimmed_title = std.mem.trim(u8, draft, &std.ascii.whitespace);
        const thread = self.currentThreadMutable();
        if (!thread.committed) {
            try thread.commitFromPrompt(self.allocator, if (trimmed_title.len > 0) trimmed_title else "Image");
        }
        var draft_image_copy = draft_image;
        try self.appendMessageToThread(thread, .user, "You", draft, if (draft_image_copy) |*image| image else null, thread.draft_extra_images.items);
        self.currentProjectMutable().invalidateSidebarThreadCache();
        try self.beginSendForThread(self.currentProject().path, thread, draft);
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
            .queue => "Queued for the next OpenCode turn.",
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
        project_path: []const u8,
        provider: Provider,
        thread_id: []const u8,
        turn_id: ?[]const u8,
    ) !void {
        const provider_config = switch (provider) {
            .opencode => ai_harness.ProviderConfig{
                .opencode = .{
                    .allocator = self.allocator,
                    .working_directory = project_path,
                    .launch_if_missing = true,
                },
            },
            .codex => ai_harness.ProviderConfig{
                .codex = .{
                    .cwd = project_path,
                    .launch_on_connect = false,
                },
            },
            .claude => ai_harness.ProviderConfig{
                .claude = .{
                    .cwd = project_path,
                },
            },
            .cursor => ai_harness.ProviderConfig{
                .cursor = .{
                    .cwd = project_path,
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
        project_path: []const u8,
        thread_id: []const u8,
        turn_id: []const u8,
        prompt: []const u8,
    ) !void {
        const provider_config = ai_harness.ProviderConfig{
            .codex = .{
                .cwd = project_path,
                .launch_on_connect = false,
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

    fn beginSendForThread(self: *AppState, project_path: []const u8, thread: *ChatThread, prompt: []const u8) !void {
        const page_alloc = std.heap.page_allocator;

        const request = try page_alloc.create(SendWorkerRequest);
        errdefer page_alloc.destroy(request);
        const extra_image_paths = try page_alloc.alloc([]u8, thread.draft_extra_images.items.len);
        errdefer page_alloc.free(extra_image_paths);
        for (thread.draft_extra_images.items, 0..) |image, index| {
            extra_image_paths[index] = try page_alloc.dupe(u8, image.path);
        }
        request.* = .{
            .send_state_ptr = thread.send_state,
            .provider = thread.provider,
            .harness = thread.harness,
            .project_path = try page_alloc.dupe(u8, project_path),
            .prompt = try page_alloc.dupe(u8, prompt),
            .image_path = if (thread.draft_image) |image| try page_alloc.dupe(u8, image.path) else null,
            .image_paths = extra_image_paths,
            .provider_thread_id = if (thread.provider_thread_id) |thread_id| try page_alloc.dupe(u8, thread_id) else null,
            .thread_title = try page_alloc.dupe(u8, thread.title),
            .model_ref = if (thread.model_ref) |model_ref| try page_alloc.dupe(u8, model_ref) else null,
            .reasoning_effort = thread.reasoning_effort,
            .opencode_reasoning_variant = blk: {
                if (thread.provider != .opencode) break :blk null;
                if (thread.opencode_reasoning_variant) |v| {
                    break :blk try page_alloc.dupe(u8, v);
                }
                break :blk null;
            },
            .cursor_model_params_json = if (thread.provider == .cursor) try self.cursorModelParamsJsonAlloc(page_alloc, thread) else null,
            .fast_mode = thread.fast_mode,
            .access_mode = thread.access_mode,
        };
        errdefer {
            page_alloc.free(request.project_path);
            page_alloc.free(request.prompt);
            if (request.image_path) |image_path| page_alloc.free(image_path);
            for (request.image_paths) |image_path| page_alloc.free(image_path);
            page_alloc.free(request.image_paths);
            if (request.provider_thread_id) |thread_id| page_alloc.free(thread_id);
            page_alloc.free(request.thread_title);
            if (request.model_ref) |model_ref| page_alloc.free(model_ref);
            if (request.opencode_reasoning_variant) |variant| page_alloc.free(variant);
            if (request.cursor_model_params_json) |params| page_alloc.free(params);
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
        if (send_state.active_turn_id) |turn_id| {
            page_alloc.free(turn_id);
            send_state.active_turn_id = null;
        }
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
        send_state.worker = std.Thread.spawn(.{}, sendWorker, .{ send_state, request }) catch |err| {
            send_state.status = .idle;
            send_state.started_at_ms = 0;
            send_state.provider = null;
            return err;
        };
        self.pending_send_count += 1;
    }

    fn beginSendDraft(self: *AppState, prompt: []const u8) !void {
        return self.beginSendForThread(self.currentProject().path, self.currentThreadMutable(), prompt);
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
                    thread.archived = project.archived or persisted_thread.archived;
                    thread.committed = persisted_thread.committed;
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
            .selected_thread_index = if (project.archived or project.threads.items.len == 0) 0 else chat_threads.selectedCommittedThreadIndex(project),
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
            .notifications_enabled = self.app_config.notifications_enabled,
        };
    }

    pub fn isSettingsDraftDirty(self: *const AppState) bool {
        const draft = self.settings_draft;
        if (draft.font_size != self.app_config.font_size) return true;
        if (draft.terminal_font_size != self.app_config.terminal_font_size) return true;
        if (draft.theme_source != self.app_config.theme_config.source) return true;
        if (draft.notifications_enabled != self.app_config.notifications_enabled) return true;
        return draft.open_action != settingsOpenActionFromConfig(self.app_config.default_open_action);
    }

    pub fn openSettingsModal(self: *AppState) void {
        self.closeSidebarContextMenu();
        self.workspace_header_open_menu_open = false;
        self.workspace_header_open_menu_pane_id = null;
        self.browser_inspector_menu_open = false;
        self.syncSettingsDraftFromConfig();
        self.settings_hook_claude_installed = provider_hooks.claudeGlobalHooksInstalled(self.allocator);
        self.settings_hook_codex_installed = provider_hooks.codexGlobalHooksInstalled(self.allocator);
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
        self.app_config.notifications_enabled = self.settings_draft.notifications_enabled;
        try self.applySettingsDraftOpenAction();

        try app_config.saveAppConfig(self.allocator, &self.app_config);
        self.app_config_file_mtime = app_config.configFileMtime(self.allocator) catch self.app_config_file_mtime;
        self.applyTerminalFontSizesFromConfig();
        self.app_config_runtime_sync_pending = true;
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
                std.mem.eql(u8, surface.workspace_path, project.path);
            if (!owns) continue;
            return self.projectTerminalDockMutable(idx, surface.dock_id);
        }
        return null;
    }

    // Resolves which agent provider a surface belongs to, for the notification
    // logo/title. The surface itself usually has no provider (the Codex Stop
    // hook calls `verde notify` without one), so fall back to the owning
    // project's managed agent process, then its first chat thread.
    fn resolveSurfaceProvider(self: *const AppState, surface: *const SurfaceState) ?Provider {
        if (surface.provider) |p| return p;
        for (self.projects.items) |*project| {
            const owns = std.mem.eql(u8, surface.workspace_id, project.id) or
                std.mem.eql(u8, surface.workspace_path, project.path);
            if (!owns) continue;
            for (project.managed_processes.items) |process| {
                if (process.kind == .agent) {
                    if (providerFromStack(process.provider)) |p| return p;
                }
            }
            if (project.threads.items.len > 0) return project.threads.items[0].provider;
            return null;
        }
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
            if (std.mem.eql(u8, surface.workspace_id, project.id) or std.mem.eql(u8, surface.workspace_path, project.path)) {
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
            if (std.mem.eql(u8, surface.workspace_id, project.id) or std.mem.eql(u8, surface.workspace_path, project.path)) {
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
        const trimmed = std.mem.trim(u8, href, &std.ascii.whitespace);
        if (trimmed.len == 0) {
            self.setSidebarNotice("No web link selected.");
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
        return slashCommandPrefix(self.currentDraft()) != null;
    }

    pub fn slashCommandPickerSelectedIndex(self: *const AppState) usize {
        const count = self.slashCommandPickerRowCount();
        if (count == 0) return 0;
        return @min(self.composer_slash_selected, count - 1);
    }

    pub fn slashCommandPickerRowCount(self: *const AppState) usize {
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
        if (std.mem.eql(u8, row.name, "/usage") or std.mem.eql(u8, row.name, "/compact")) {
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
        const project_path = self.currentProject().path;
        if (!dock.hasRunningSession()) {
            dock.ensureSessionPersistent(self.allocator, project_path, self.storage.pref_path, 0) catch |err| {
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
            const project_path = self.currentProject().path;
            dock.ensureSessionPersistent(self.allocator, project_path, self.storage.pref_path, 0) catch |err| {
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

    // Visible terminal output within this window keeps the main loop polling
    // at display rate. Long enough to bridge frame-to-frame gaps of a TUI
    // redrawing continuously; short enough that one stray prompt repaint
    // doesn't keep the loop hot.
    const TERMINAL_OUTPUT_BURST_WINDOW_MS: i64 = 250;

    fn monotonicMs() i64 {
        return @intCast(@divTrunc(profiler.nowNs(), std.time.ns_per_ms));
    }

    /// True while a visible terminal recently produced output; the main loop
    /// uses this to shorten its event wait so the next chunk renders promptly.
    pub fn terminalOutputBurstActive(self: *const AppState) bool {
        if (self.last_terminal_output_ms == 0) return false;
        return monotonicMs() - self.last_terminal_output_ms < TERMINAL_OUTPUT_BURST_WINDOW_MS;
    }

    pub fn pollTerminals(self: *AppState) bool {
        var visible_changed = false;
        for (self.projects.items, 0..) |*project, project_index| {
            const project_selected = project_index == self.selected_project_index;
            const base_visible = project.terminal_dock.visible or project.workspace_layout.hasTerminalDockPane(0);
            if (!project_selected) {
                self.pollManagedProcesses(project_index);
                continue;
            }
            if (project_selected and base_visible and !project.terminal_dock.hasRunningSession()) {
                project.terminal_dock.ensureSessionPersistent(self.allocator, project.path, self.storage.pref_path, 0) catch |err| {
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
                if (project_selected and dock_visible and !entry.dock.hasRunningSession()) {
                    entry.dock.ensureSessionPersistent(self.allocator, project.path, self.storage.pref_path, entry.id) catch |err| {
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
        if (visible_changed) self.last_terminal_output_ms = monotonicMs();
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

    /// Reports whether a composer-owned menu/cascade is open over the workspace.
    pub fn isComposerMenuOpen(self: *const AppState) bool {
        return self.composer_locked_model_picker_open or
            self.palette_composer.active_menu != null or
            self.palette_model_cascade.isOpen();
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
            self.palette_composer.active_menu = .reasoning;
            self.palette_composer.hovered_menu_index = 0;
            self.composer_locked_model_picker_open = false;
            _ = self.palette_model_cascade.handleInput(.close);
            self.browser_inspector_menu_open = false;
            self.workspace_header_open_menu_open = false;
            self.workspace_header_open_menu_pane_id = null;
            self.browser_address_focused = false;
            self.unfocusBrowserPane();
        } else {
            self.palette_composer.active_menu = null;
            self.palette_composer.hovered_menu_index = null;
            self.composer_locked_model_picker_open = false;
            _ = self.palette_model_cascade.handleInput(.close);
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
            self.palette_model_cascade.isOpen();
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
                        log.warn("blocked browser bridge message from disallowed page URL: {s}", .{page_url});
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
        if (keyboard.terminalActionForEvent(event)) |action| {
            switch (action) {
                .split_up => return self.splitFocusedWorkspacePaneWithTerminalPlacement(.horizontal, false),
                .split_down => return self.splitFocusedWorkspacePaneWithTerminalPlacement(.horizontal, true),
                .split_left => return self.splitFocusedWorkspacePaneWithTerminalPlacement(.vertical, false),
                .split_right => return self.splitFocusedWorkspacePaneWithTerminalPlacement(.vertical, true),
                else => {},
            }
        }
        var dock = self.currentProjectTerminalMutable();
        const handled = dock.handleKeyDown(self.allocator, keyboard, event);
        if (dock.consumeWorkspaceChange()) self.markDirty();
        return handled;
    }

    pub fn handleTerminalTextInput(self: *AppState, text: [*c]const u8) bool {
        if (!self.canRouteTerminalInput()) return false;
        return self.currentProjectTerminalMutable().handleTextInput(std.mem.sliceTo(text, 0));
    }

    fn canRouteTerminalInput(self: *const AppState) bool {
        if (!self.terminal_focused or !self.isTerminalVisible()) return false;
        if (self.shouldRenderLegacyTerminalDockInChat()) return true;
        return self.focusedWorkspacePaneKind() == .terminal;
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
        var dock = self.projectTerminalDockMutable(project_index, dock_id) orelse return false;
        try dock.ensureSessionPersistent(self.allocator, project.path, self.storage.pref_path, dock_id);
        return try dock.writeInputToActivePane(bytes);
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
        const dock = self.projectTerminalDock(project_index, dock_id) orelse return null;
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
        const dock = self.projectTerminalDock(project_index, dock_id) orelse return null;
        return try dock.activeScreenTextAlloc(self.allocator);
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
            if (std.mem.eql(u8, definition.name, name)) return definition;
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
        return try self.startManagedProcessDirect(project, process);
    }

    fn startManagedProcessDirect(self: *AppState, project: *Project, process: *ManagedProcess) !bool {
        const dock_id = process.dock_id orelse try self.createCurrentProjectTerminalDock();
        process.dock_id = dock_id;

        const cwd = try self.resolveManagedProcessCwd(project.path, process.cwd);
        defer self.allocator.free(cwd);
        try self.ensureManagedAgentProjectHooks(project.path, process);
        var dock = self.currentProjectTerminalDockMutable(dock_id) orelse return false;
        const command = try self.managedProcessLaunchCommand(process);
        defer self.allocator.free(command);
        const command_args = [_][]const u8{ "/bin/sh", "-lc", command };
        try dock.restartWithProfilePersistent(self.allocator, cwd, .{
            .kind = .custom,
            .label = process.name,
            .command = &command_args,
        }, self.storage.pref_path, dock_id);
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
        self.terminal_focused = true;
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
        var dock = self.projectTerminalDockMutable(project_index, dock_id) orelse return false;
        const command = try self.managedProcessLaunchCommand(process);
        defer self.allocator.free(command);
        const command_args = [_][]const u8{ "/bin/sh", "-lc", command };
        try dock.restartWithProfilePersistent(self.allocator, cwd, .{
            .kind = .custom,
            .label = process.name,
            .command = &command_args,
        }, self.storage.pref_path, dock_id);

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
        self.terminal_focused = true;
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

        const request = try page_alloc.create(SlashCommandWorkerRequest);
        errdefer page_alloc.destroy(request);
        request.* = .{
            .provider = thread.provider,
            .harness = thread.harness,
            .project_path = try page_alloc.dupe(u8, project.path),
            .thread_id = if (thread.provider_thread_id) |thread_id| try page_alloc.dupe(u8, thread_id) else null,
            .command = command.id,
            .raw_text = try page_alloc.dupe(u8, raw_text),
            .args = try page_alloc.dupe(u8, args),
        };
        errdefer {
            page_alloc.free(request.project_path);
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
        self.slash_command_state.project_index = project_index;
        self.slash_command_state.thread_index = thread_index;
        self.slash_command_state.command = command.id;
        self.slash_command_state.status = .pending;
        self.slash_command_state.worker = std.Thread.spawn(.{}, slashCommandWorker, .{ &self.slash_command_state, request }) catch |err| {
            self.slash_command_state.status = .idle;
            return err;
        };

        self.clearDraft();
        self.syncPaletteComposerFromDraft();
        var buffer: [128]u8 = undefined;
        self.setSidebarNotice(std.fmt.bufPrint(&buffer, "Running {s}...", .{command.name}) catch "Running slash command...");
    }

    fn resolveManagedProcessCwd(self: *AppState, project_path: []const u8, raw_cwd: []const u8) ![]u8 {
        if (raw_cwd.len == 0 or std.mem.eql(u8, raw_cwd, ".")) return self.allocator.dupe(u8, project_path);
        if (std.fs.path.isAbsolute(raw_cwd)) return self.allocator.dupe(u8, raw_cwd);
        return std.fs.path.join(self.allocator, &.{ project_path, raw_cwd });
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
            log.warn("failed to scan watch patterns for managed process {s}: {s}", .{ process.name, @errorName(err) });
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
        var dock = self.currentProjectTerminalDockMutable(dock_id) orelse return null;
        dock.ensureSessionPersistent(self.allocator, project.path, self.storage.pref_path, dock_id) catch |err| {
            log.err("failed to start editor terminal dock: {s}", .{@errorName(err)});
            self.setSidebarNotice("Failed to start terminal.");
            return null;
        };

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
        var dock = self.currentProjectTerminalDockMutable(dock_id) orelse return;
        dock.restartWithProfilePersistent(self.allocator, project.path, .{}, self.storage.pref_path, dock_id) catch |err| {
            log.err("failed to start TUI terminal dock: {s}", .{@errorName(err)});
            self.setSidebarNotice("Failed to start TUI terminal.");
            return;
        };

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
        var dock = self.projectTerminalDockMutable(project_index, dock_id) orelse return false;
        dock.ensureSessionPersistent(self.allocator, project.path, self.storage.pref_path, dock_id) catch |err| {
            log.err("failed to start terminal dock: {s}", .{@errorName(err)});
            self.setSidebarNotice("Failed to start terminal.");
            return false;
        };

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
        if (self.selected_project_index == project_index) self.requestTerminalFocus();
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
        const cursor_model = if (thread.provider == .cursor) self.cursorModelOptionForRef(thread.model_ref) else null;
        const show_fast_toggle = thread.provider == .codex or (cursor_model != null and cursor_model.?.cursor_fast_supported);
        self.palette_composer.setShowFastToggle(show_fast_toggle);
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
        const show_reasoning = thread.provider == .codex or self.opencode_reasoning_menu.items.len > 0;
        self.palette_composer.setShowReasoningToggle(show_reasoning);
        const reasoning_count: usize = switch (thread.provider) {
            .codex => CODEX_REASONING_OPTIONS.len,
            else => self.opencode_reasoning_menu.items.len,
        };
        self.palette_composer.setReasoningOptions(self, reasoning_count, paletteReasoningLabel);
        self.palette_composer.model_index = self.composerModelIndex(thread.provider, thread.model_ref);
        self.palette_composer.reasoning_index = composerReasoningIndexForThread(self, thread);
        if (show_fast_toggle) {
            self.palette_composer.fast_enabled = thread.fast_mode == .on;
        } else {
            self.palette_composer.fast_enabled = false;
        }
        self.palette_composer.access_enabled = thread.access_mode == .full_access;
        self.palette_composer.setSendState(if (thread.isSendPendingForUi()) .stop else .send);
        if (self.palette_composer.model_index) |index| {
            if (index < model_options.len) {
                self.palette_composer.setModelLabel(self.allocator, std.mem.sliceTo(model_options[index].label, 0)) catch |err| {
                    log.warn("failed to sync palette composer model label: {s}", .{@errorName(err)});
                };
            }
        }
        if (self.palette_composer.reasoning_index) |index| {
            if (thread.provider == .codex) {
                if (index < CODEX_REASONING_OPTIONS.len) {
                    self.palette_composer.setReasoningLabel(self.allocator, CODEX_REASONING_OPTIONS[index].label) catch |err| {
                        log.warn("failed to sync palette composer reasoning label: {s}", .{@errorName(err)});
                    };
                }
            } else {
                const rows = self.opencode_reasoning_menu.items;
                if (index < rows.len) {
                    self.palette_composer.setReasoningLabel(self.allocator, std.mem.sliceTo(rows[index].label, 0)) catch |err| {
                        log.warn("failed to sync palette composer reasoning label: {s}", .{@errorName(err)});
                    };
                }
            }
        }
        if (show_fast_toggle) {
            self.palette_composer.setFastLabel(self.allocator, if (thread.fast_mode == .on) "Fast" else "Default") catch |err| {
                log.warn("failed to sync palette composer fast label: {s}", .{@errorName(err)});
            };
        }
        self.palette_composer.setAccessLabel(self.allocator, switch (thread.access_mode) {
            .full_access => "Full access",
            .supervised => "Supervised",
        }) catch |err| {
            log.warn("failed to sync palette composer access label: {s}", .{@errorName(err)});
        };
    }

    pub fn syncPaletteModelCascadeMenu(self: *AppState) void {
        self.palette_model_cascade.setCallbacks(.{ .context = self, .on_event = paletteModelCascadeEvent });
        self.palette_model_cascade.setStyle(paletteModelCascadeStyle());
        self.palette_model_cascade.setFontMetrics(paletteEstimatedFontMetrics(20.0));
        self.palette_model_cascade.setItemCount(COMPOSER_PROVIDER_OPTIONS.len);
    }

    pub fn setPaletteModelCascadeBoundsFromToolbar(self: *AppState) void {
        const anchor = self.composer_toolbar_model_rect;
        if (anchor.w <= 0.0 or anchor.h <= 0.0) return;

        const composer_rect: palette.Rect = if (self.composer_input_bounds_valid) .{
            .x = self.composer_input_min[0],
            .y = self.composer_input_min[1],
            .w = @max(self.composer_input_max[0] - self.composer_input_min[0], 0.0),
            .h = @max(self.composer_input_max[1] - self.composer_input_min[1], 0.0),
        } else anchor;
        const root_height = COMPOSER_MODEL_CASCADE_PADDING_Y * 2.0 +
            COMPOSER_MODEL_CASCADE_ROW_HEIGHT * @as(f32, @floatFromInt(COMPOSER_PROVIDER_OPTIONS.len));
        const total_width = COMPOSER_MODEL_CASCADE_WIDTH * 2.0 + COMPOSER_MODEL_CASCADE_GAP;
        const min_x = if (self.composer_input_bounds_valid) self.composer_input_min[0] else anchor.x;
        const max_x = if (self.composer_input_bounds_valid) self.composer_input_max[0] else anchor.x + total_width;
        const viewport_top: f32 = 8.0;
        const viewport_bottom = @max(viewport_top + root_height, composer_rect.y + composer_rect.h);
        const x = @max(min_x, @min(anchor.x, max_x - total_width));
        var menu_anchor = anchor;
        menu_anchor.y += COMPOSER_MODEL_CASCADE_ROOT_DROP;
        self.palette_model_cascade.setAnchorRect(menu_anchor);
        self.palette_model_cascade.setForbiddenRect(self.palette_composer.toolbarRect());
        self.palette_model_cascade.setViewportRect(.{
            .x = min_x,
            .y = viewport_top,
            .w = @max(max_x - min_x, total_width),
            .h = @max(viewport_bottom - viewport_top, root_height),
        });
        self.palette_model_cascade.setBounds(.{
            .x = x,
            .y = anchor.y,
            .w = COMPOSER_MODEL_CASCADE_WIDTH,
            .h = root_height,
        });
    }

    pub fn openPaletteModelCascadeMenu(self: *AppState) void {
        if (self.opencode_model_options.items.len == 0) {
            self.refreshOpencodeModelOptionsCacheAsync();
        }
        if (self.claude_model_options.items.len == 0) {
            self.refreshClaudeModelOptionsCacheAsync();
        }
        if (self.cursor_model_options.items.len == 0) {
            self.refreshCursorModelOptionsCacheAsync();
        }
        self.palette_composer.active_menu = null;
        self.palette_composer.hovered_menu_index = null;
        self.syncPaletteModelCascadeMenu();
        self.setPaletteModelCascadeBoundsFromToolbar();
        _ = self.palette_model_cascade.handleInput(.open);

        const thread = self.currentThread();
        if (composerCascadeIndexForProvider(thread.provider)) |provider_index| {
            self.palette_model_cascade.highlighted[0] = provider_index;
            self.palette_model_cascade.highlighted[1] = null;
            self.palette_model_cascade.scroll_y[1] = 0.0;
            const model_count = composerModelOptions(self, thread.provider).len;
            if (model_count > 0) {
                self.palette_model_cascade.active_depth = 2;
                if (self.composerModelIndex(thread.provider, thread.model_ref)) |model_index| {
                    self.palette_model_cascade.highlighted[1] = model_index;
                    const max_visible_rows = COMPOSER_MODEL_CASCADE_VISIBLE_ROWS;
                    if (model_index >= max_visible_rows) {
                        const first_visible = model_index - max_visible_rows + 1;
                        self.palette_model_cascade.scroll_y[1] = @as(f32, @floatFromInt(first_visible)) * COMPOSER_MODEL_CASCADE_ROW_HEIGHT;
                    }
                }
            }
        }
    }

    fn currentThreadNeedsProviderModelCascade(self: *const AppState) bool {
        const thread = self.currentThread();
        return thread.messages.items.len == 0 and
            thread.provider_thread_id == null and
            !thread.isSendPendingForUi();
    }

    pub fn routePaletteComposerTextInput(self: *AppState, text: []const u8) bool {
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
        if (self.terminal_focused) return false;
        const palette_key = paletteComposerKeyFromSdl(event) orelse return false;
        if (palette_key.primary and palette_key.code == .v) {
            runtime_log.diagnostic(
                "palette composer received primary-v focused={} draft_len={d}",
                .{ self.palette_composer.focused, self.currentDraft().len },
            );
            return self.pasteClipboardTextIntoPaletteComposer();
        }
        if (self.routePaletteModelCascadeKey(palette_key)) return true;
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
        if (event.button != 1) return false;
        const point = paletteMousePoint(event.x, event.y, ui_scale);
        if (self.routePaletteModelCascadeMouseButton(point, event.down)) return true;
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
        if (self.composer_toolbar_model_rect.contains(point) and self.currentThreadNeedsProviderModelCascade()) {
            self.openPaletteModelCascadeMenu();
            self.palette_composer.focused = false;
            self.composer_focused = false;
            self.noteInteraction();
            return true;
        }
        const target = if (self.composer_toolbar_model_rect.contains(point))
            self.palette_composer.modelRect()
        else if (self.composer_toolbar_reasoning_rect.contains(point))
            self.palette_composer.reasoningRect()
        else if (self.palette_composer.showFastToggle() and self.composer_toolbar_fast_rect.contains(point))
            self.palette_composer.fastRect()
        else if (self.composer_toolbar_access_rect.contains(point))
            self.palette_composer.accessRect()
        else
            return false;

        _ = self.palette_model_cascade.handleInput(.close);
        const target_point: palette.draw.Vec2 = .{
            .x = target.x + target.w * 0.5,
            .y = target.y + target.h * 0.5,
        };
        const was_focused = self.palette_composer.focused;
        const handled = self.palette_composer.handleInput(self.allocator, .{ .mouse_down = target_point }) catch |err| {
            log.warn("palette composer toolbar overlay click failed: {s}", .{@errorName(err)});
            return false;
        };
        self.composer_focused = self.palette_composer.focused;
        if (self.composer_focused) {
            self.terminal_focused = false;
            self.unfocusBrowserPane();
        }
        if (handled) self.noteInteraction();
        return handled or was_focused != self.palette_composer.focused;
    }

    pub fn routePaletteComposerMouseMotion(self: *AppState, event: *const sdl.MouseMotionEvent, ui_scale: f32) bool {
        const point = paletteMousePoint(event.x, event.y, ui_scale);
        if (self.routePaletteModelCascadeMouseMove(point, event.state.left != 0)) return true;
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
        if (self.routePaletteModelCascadeWheel(paletteMousePoint(event.mouse_x, event.mouse_y, ui_scale), event.y)) return true;
        const handled = self.palette_composer.handleInput(self.allocator, .{
            .mouse_wheel = .{ .point = paletteMousePoint(event.mouse_x, event.mouse_y, ui_scale), .y = event.y },
        }) catch |err| {
            log.warn("palette composer wheel failed: {s}", .{@errorName(err)});
            return false;
        };
        if (handled) self.noteInteraction();
        return handled;
    }

    fn routePaletteModelCascadeKey(self: *AppState, key: palette.Key) bool {
        if (!self.palette_model_cascade.isOpen()) return false;
        const handled = self.palette_model_cascade.handleInput(.{ .key = key });
        if (handled) self.noteInteraction();
        return handled;
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

    fn routePaletteModelCascadeMouseButton(self: *AppState, point: palette.draw.Vec2, down: bool) bool {
        if (!self.palette_model_cascade.isOpen()) return false;
        const handled = self.palette_model_cascade.handleInput(if (down)
            .{ .mouse_down = .{ .point = point } }
        else
            .{ .mouse_up = point });
        if (handled) self.noteInteraction();
        return handled;
    }

    fn routePaletteModelCascadeMouseMove(self: *AppState, point: palette.draw.Vec2, dragging: bool) bool {
        if (!self.palette_model_cascade.isOpen()) return false;
        const handled = self.palette_model_cascade.handleInput(if (dragging)
            .{ .mouse_drag = point }
        else
            .{ .mouse_move = point });
        if (handled) self.noteInteraction();
        return handled;
    }

    fn routePaletteModelCascadeWheel(self: *AppState, point: palette.draw.Vec2, y: f32) bool {
        if (!self.palette_model_cascade.isOpen()) return false;
        const handled = self.palette_model_cascade.handleInput(.{ .mouse_wheel = .{ .point = point, .y = y } });
        if (handled) self.noteInteraction();
        return handled;
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

    pub fn handleComposerDraftImageClearMouseButton(self: *AppState, x: f32, y: f32, down: bool) bool {
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
        thread.reasoning_effort = null;
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

        switch (next_status) {
            .selected => {
                if (picked_path) |path| {
                    defer std.heap.page_allocator.free(path);
                    if (self.show_project_creator) {
                        self.setImportPath(path);
                        self.project_import_cursor = self.importDirectoryDraft().len;
                        self.setSidebarNotice("Folder selected.");
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
                self.normalizeOpencodeReasoningVariant(self.currentThreadMutable());
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
        var project_index: usize = 0;
        var thread_index: usize = 0;
        var next_status: SlashCommandStatus = .idle;

        self.slash_command_state.mutex.lock();
        switch (self.slash_command_state.status) {
            .completed => {
                result = self.slash_command_state.result;
                self.slash_command_state.result = null;
                project_index = self.slash_command_state.project_index;
                thread_index = self.slash_command_state.thread_index;
                self.slash_command_state.status = .idle;
                next_status = .completed;
            },
            .failed => {
                error_message = self.slash_command_state.error_message;
                self.slash_command_state.error_message = null;
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

    pub fn currentThreadPendingSlashCommandLabel(self: *AppState) ?[]const u8 {
        if (self.projects.items.len == 0) return null;
        const project_index = self.selected_project_index;
        const thread_index = self.currentProject().selected_thread_index;

        self.slash_command_state.mutex.lock();
        defer self.slash_command_state.mutex.unlock();
        if (self.slash_command_state.status != .pending) return null;
        if (self.slash_command_state.project_index != project_index or self.slash_command_state.thread_index != thread_index) return null;

        return switch (self.slash_command_state.command) {
            .usage => "Loading Codex usage...",
            .goal => "Updating Codex goal...",
            .compact => "Compacting thread context...",
            .review => "Starting Codex review...",
            .shell => "Running Codex shell command...",
        };
    }

    fn applySlashCommandResult(
        self: *AppState,
        project_index: usize,
        thread_index: usize,
        result: ai_harness.RunSlashCommandResult,
    ) void {
        if (!result.handled) {
            self.setSidebarNotice("Slash command was not handled by this provider.");
            return;
        }

        if (project_index < self.projects.items.len and thread_index < self.projects.items[project_index].threads.items.len) {
            if (result.transcript_title != null or result.transcript_body != null) {
                const title = result.transcript_title orelse "Provider command";
                const body = result.transcript_body orelse "Done.";
                const thread = &self.projects.items[project_index].threads.items[thread_index];
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

    fn readBackgroundTaskPid(allocator: std.mem.Allocator, pid_path: []const u8) ?std.posix.pid_t {
        var threaded = std.Io.Threaded.init_single_threaded;
        const raw = std.Io.Dir.cwd().readFileAlloc(threaded.io(), pid_path, allocator, .limited(256)) catch return null;
        defer allocator.free(raw);
        const trimmed = std.mem.trim(u8, raw, "\n\r\t ");
        if (trimmed.len == 0) return null;
        return std.fmt.parseInt(std.posix.pid_t, trimmed, 10) catch null;
    }

    fn backgroundTaskProcessIsAlive(pid: std.posix.pid_t) bool {
        if (pid <= 0) return false;
        const group_alive = blk: {
            std.posix.kill(-pid, @enumFromInt(0)) catch |group_err| switch (group_err) {
                error.ProcessNotFound => break :blk false,
                error.PermissionDenied => break :blk true,
                else => break :blk false,
            };
            break :blk true;
        };
        if (group_alive) return true;
        std.posix.kill(pid, @enumFromInt(0)) catch |pid_err| switch (pid_err) {
            error.ProcessNotFound => return false,
            error.PermissionDenied => return true,
            else => return false,
        };
        return true;
    }

    fn pollThreadSend(self: *AppState, project_index: usize, thread_index: usize, thread: *ChatThread) bool {
        self.capturePendingProviderThreadId(thread);
        self.issuePendingCodexSteer(self.projects.items[project_index].path, project_index, thread_index, thread);
        self.issuePendingThreadStop(self.projects.items[project_index].path, thread);

        var completed_result: ?SendResultPayload = null;
        var failed_message: ?[]u8 = null;
        var had_pending_followup = false;
        var next_status: SendStatus = .idle;
        var completed_events: std.ArrayListUnmanaged(PendingTimelineEvent) = .empty;
        var completed_diff_files: std.ArrayListUnmanaged(PendingDiffFile) = .empty;
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
        return next_status != .idle or stream_changed;
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

    fn issuePendingThreadStop(self: *AppState, project_path: []const u8, thread: *ChatThread) void {
        var provider: Provider = undefined;
        var thread_id: ?[]u8 = null;
        var turn_id: ?[]u8 = null;

        const send_state = thread.send_state;
        if (!send_state.mutex.tryLock()) return;
        if (send_state.status == .pending and send_state.stop_requested and !send_state.stop_signal_sent) {
            provider = thread.provider;
            const pending_thread_id: ?[]const u8 = if (thread.provider_thread_id) |existing|
                existing
            else if (send_state.provisional_provider_thread_id) |provisional|
                provisional
            else
                null;
            if (pending_thread_id) |resolved_thread_id| {
                if (provider == .opencode or provider == .claude or send_state.active_turn_id != null) {
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

        self.interruptThreadViaHarness(project_path, provider, owned_thread_id, turn_id) catch |err| {
            log.warn("failed to interrupt provider turn: {s}", .{@errorName(err)});
            self.setSidebarNotice("Failed to stop provider reply.");
            return;
        };
    }

    fn issuePendingCodexSteer(
        self: *AppState,
        project_path: []const u8,
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

        self.steerThreadViaHarness(project_path, owned_thread_id, owned_turn_id, owned_prompt) catch |err| {
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

        self.appendMessageToThread(thread, .user, "You", followup.prompt, null, &.{}) catch |err| {
            log.err("failed to append pending follow-up: {s}", .{@errorName(err)});
            self.setSidebarNotice("Failed to append the pending follow-up.");
            return;
        };
        self.beginSendForThread(self.projects.items[project_index].path, thread, followup.prompt) catch |err| {
            log.err("failed to start pending follow-up: {s}", .{@errorName(err)});
            self.setSidebarNotice("Failed to send the pending follow-up.");
            return;
        };
        if (project_index == self.selected_project_index and thread_index == self.currentProject().selected_thread_index) {
            self.requestTranscriptScrollToBottom();
        }
        self.setSidebarNotice(switch (followup.kind) {
            .queue => "Queued OpenCode message sent.",
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
        self.slash_command_state.result = null;
        self.slash_command_state.error_message = null;
        self.slash_command_state.status = .idle;
        self.slash_command_state.mutex.unlock();

        if (maybe_result) |result| {
            result.deinit(std.heap.page_allocator);
        }
        if (maybe_error) |message| {
            std.heap.page_allocator.free(message);
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
        send_state.stop_requested = true;
        send_state.stop_signal_sent = false;
        send_state.approval_decision = .deny;
        send_state.condition.broadcast();
        runtime_log.diagnostic("shutdown requested send stop provider={s} thread_title={s}", .{ @tagName(thread.provider), thread.title });
        send_state.mutex.unlock();

        self.issuePendingThreadStop(project_path, thread);
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
        defer send_state.mutex.unlock();
        if (send_state.pending_approval == null) return;
        send_state.approval_decision = decision;
        send_state.ui_revision +%= 1;
        send_state.condition.broadcast();
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
        const expanded = if (std.mem.startsWith(u8, raw_path, "~/")) blk: {
            const home = std.mem.sliceTo(std.c.getenv("HOME") orelse return error.EnvironmentVariableNotFound, 0);
            break :blk try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ home, raw_path[2..] });
        } else try self.allocator.dupe(u8, raw_path);
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
            if (std.mem.eql(u8, project.path, path)) return index;
        }
        return null;
    }

    fn findArchivedProjectIndexByPath(self: *const AppState, path: []const u8) ?usize {
        for (self.archived_projects.items, 0..) |project, index| {
            if (std.mem.eql(u8, project.path, path)) return index;
        }
        return null;
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
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(path);
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

        const home = std.mem.sliceTo(std.c.getenv("HOME") orelse return self.allocator.dupe(u8, "."), 0);
        return self.allocator.dupe(u8, home);
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
        if (request.thread_id) |thread_id| page_alloc.free(thread_id);
        page_alloc.free(request.raw_text);
        page_alloc.free(request.args);
        page_alloc.destroy(request);
    }

    runtime_log.diagnostic(
        "slash command worker begin provider={s} command={s} thread_id={s}",
        .{ @tagName(request.provider), @tagName(request.command), request.thread_id orelse "(none)" },
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

    const provider_config = switch (request.provider) {
        .opencode => ai_harness.ProviderConfig{
            .opencode = .{
                .allocator = allocator,
                .working_directory = request.project_path,
                .launch_if_missing = true,
            },
        },
        .codex => ai_harness.ProviderConfig{
            .codex = .{
                .cwd = request.project_path,
                .launch_on_connect = true,
            },
        },
        .claude => ai_harness.ProviderConfig{
            .claude = .{
                .cwd = request.project_path,
            },
        },
        .cursor => ai_harness.ProviderConfig{
            .cursor = .{
                .cwd = request.project_path,
            },
        },
    };

    var client = try ai_harness.connect(allocator, provider_config);
    defer client.deinit();

    return client.runSlashCommand(allocator, .{
        .thread_id = request.thread_id,
        .cwd = request.project_path,
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
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.REALTIME, &ts) != 0) return 0;
    return @as(i64, @intCast(ts.sec)) * std.time.ms_per_s +
        @divTrunc(@as(i64, @intCast(ts.nsec)), std.time.ns_per_ms);
}
