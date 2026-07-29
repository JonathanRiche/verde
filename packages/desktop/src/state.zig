const std = @import("std");
const builtin = @import("builtin");
const palette = @import("palette");
const sdl = @import("zsdl3");
const profiler = @import("runtime/profiler.zig");
const chat_markdown = @import("ui/chat_markdown.zig");
const chat_handoff = @import("chat/handoff.zig");
const app_config = @import("app/config.zig");
const ai_harness = @import("providers/harness.zig");
const browser_inspector = @import("browser/inspector.zig");
const browser_runtime = @import("browser/mod.zig");
const browser_screenshot = @import("browser/screenshot.zig");
const bang_commands = @import("workspace/bang_commands.zig");
const chat_threads = @import("chat/threads.zig");
const db_client = @import("db/client.zig");
const db_types = @import("db/types.zig");
const herdr = @import("workspace/herdr.zig");
const keybinds = @import("app/keybinds.zig");
const loop_wakeup = @import("loop_wakeup");
const platform_paths = @import("platform_paths");
const platform_runtime = @import("platform_runtime");
const platform_process = @import("platform/process.zig");
const process_env = @import("platform/env.zig");
const provider_hooks = @import("providers/hooks.zig");
const provider_mcp = @import("providers/mcp.zig");
const runtime_log = @import("runtime/log.zig");
const send_runner = @import("chat/send_runner.zig");
const slash_commands = @import("chat/slash_commands.zig");
const stack_config = @import("workspace/stack.zig");
const stb_image = @import("media/stb_image.zig");
const sessionizer = @import("terminal/sessionizer.zig");
const terminal = @import("terminal/terminal.zig");
const theme = @import("ui/theme.zig");
const text_measure = @import("ui/text_measure.zig");
const utils = @import("utils.zig");
const browser_pane = @import("state/browser_pane.zig");
const workspace_layout = @import("state/workspace_layout.zig");
const provider_models = @import("state/provider_models.zig");
const chat_types = @import("state/chat_types.zig");
const state_sync = @import("state/sync.zig");
const state_ui_types = @import("state/ui_types.zig");
const herdr_types = @import("state/herdr_types.zig");
const project_state = @import("state/project.zig");
const state_storage = @import("state/storage.zig");
const persistence = @import("state/persistence.zig");
const command_controller = @import("state/command_controller.zig");
const composer_controller = @import("state/composer_controller.zig");
const browser_controller = @import("state/browser_controller.zig");
const workspace_controller = @import("state/workspace_controller.zig");
const lifecycle_controller = @import("state/lifecycle_controller.zig");
const chat_controller = @import("state/chat_controller.zig");
const provider_controller = @import("state/provider_controller.zig");
const project_controller = @import("state/project_controller.zig");
const file_search_controller = @import("state/file_search_controller.zig");
const herdr_controller = @import("state/herdr_controller.zig");
const handoff_controller = @import("state/handoff_controller.zig");
const settings_controller = @import("state/settings_controller.zig");
const surface_controller = @import("state/surface_controller.zig");
const terminal_controller = @import("state/terminal_controller.zig");
const transcript_controller = @import("state/transcript_controller.zig");

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

pub const ReasoningEffort = provider_models.ReasoningEffort;
pub const FastMode = provider_models.FastMode;
pub const AccessMode = provider_models.AccessMode;
pub const ChatRole = provider_models.ChatRole;
pub const Provider = provider_models.Provider;
pub const AgentTuiProvider = stack_config.AgentProvider;
pub const Harness = provider_models.Harness;

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

pub const SurfaceStatus = surface_controller.SurfaceStatus;
pub const SurfaceUpdate = surface_controller.SurfaceUpdate;
pub const SurfaceState = surface_controller.SurfaceState;
pub const SurfaceProvider = db_types.SurfaceProvider;

pub const PaletteModalAction = enum {
    mcp_onboarding_not_now,
    mcp_onboarding_enable,
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
    handoff_cancel,
    handoff_prepare,
    handoff_surface_gui,
    handoff_surface_tui,
    handoff_provider_codex,
    handoff_provider_opencode,
    handoff_provider_claude,
    handoff_provider_cursor,
    handoff_context_summary,
    handoff_context_recent,
    handoff_context_full,
    handoff_target_new,
    handoff_target_existing,
    handoff_target_next,
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
    settings_theme_option,
    settings_title_provider_option,
    settings_title_model_option,
    command_palette_input,
    command_palette_row,
    command_palette_action_row,
};

pub const SettingsOpenAction = settings_controller.OpenAction;
pub const SettingsDraft = settings_controller.Draft;

pub const PaletteModalHit = struct {
    rect: palette.Rect,
    action: PaletteModalAction,
    index: usize = 0,
};

/// Per-frame hit-test entry for a fenced code block's "Copy" button. The
/// payload bytes live in `palette_frame_text` (cleared each frame), so the
/// offset/length pair is only valid until the next frame's text-buffer reset.
pub const CodeCopyButtonHit = chat_markdown.CodeCopyButtonSink;

pub const BrowserContextMenuItem = browser_controller.BrowserContextMenuItem;
const BrowserContextMenuPayload = browser_controller.BrowserContextMenuPayload;
const BrowserContextMenuPayloadItem = browser_controller.BrowserContextMenuPayloadItem;

pub const CardToggleKind = enum(u8) {
    command_card,
    tool_call_group,
    tool_output,
    diff_file,
};

/// Per-frame hit-test entry for a collapsible card header (command bubble,
/// diff file row). The `key` identifies the card across frames and is also the
/// lookup into `expanded_cards`.
pub const CardToggleHit = struct {
    rect: palette.Rect,
    key: u64,
    kind: CardToggleKind,
    default_expanded: bool = false,
};

pub const BackgroundTaskAction = enum { stop, output };

pub const BackgroundTaskActionHit = struct {
    rect: palette.Rect,
    project_index: usize,
    thread_index: usize,
    task_index: usize,
    message_index: usize,
    action: BackgroundTaskAction,
};

pub const PaletteModalTextFocus = enum {
    none,
    project_rename,
    thread_import,
    project_import,
    command_palette,
};

/// Composer body text size (CSS units, scaled by `setUiScale`). Public because
/// the transcript's bubble body text keys off it (`chat_panel.zig`) so the
/// prompt box and the chat thread always read at the same size.
pub const PALETTE_COMPOSER_FONT_SIZE: f32 = 18.0;
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
        .send_foreground_color = paletteColor(theme.foregroundOn(theme.COLOR_GREEN)),
        .stop_button_color = paletteColor(theme.COLOR_YELLOW),
        .stop_button_hover_color = paletteColor(theme.lighten(theme.COLOR_YELLOW, 0.08)),
        .stop_foreground_color = paletteColor(theme.foregroundOn(theme.COLOR_YELLOW)),
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
    // Kept tight: the chevron column already centers its ink with air on both
    // sides, so a wide gap here reads as dead space after the trailing glyph.
    .pill_chevron_gap = 8.0,
    .model_min_width = 112.0,
    // Long OpenCode labels include the provider, e.g. "GPT-5.4 (OpenAI)"; cap high enough for measured pill width.
    .model_max_width = 270.0,
    .reasoning_min_width = 74.0,
    // The run pill now shows a "Reasoning · Speed · Access" summary, so it
    // needs far more room than the old single reasoning label.
    // Wide enough for the summary text plus three embedded state-glyph cells
    // (COMPOSER_RUN_PILL_ICON_CELL each).
    .reasoning_max_width = 360.0,
    .fast_min_width = 80.0,
    .fast_max_width = 180.0,
    .access_min_width = 138.0,
    // Toolbar label + lock icon + padding; keep above natural measured width for "Full access".
    .access_max_width = 212.0,
    // Space after `pill_padding_x` until label: ~scaled toolbar icon width
    // minus `pill_icon_gap`. Provider PNG slot is 26 CSS px; reserve + gap
    // gives label-start at icon-end + ~12 CSS px on the smallest screens.
    .pill_overlay_icon_reserve = 26.0,
    // Toolbar labels measure with real shaped advances (paletteCachedGlyphAdvance),
    // so this only needs to cover renderer rounding, not font-substitution error.
    .pill_label_width_fudge = 3.0,
    .corner_radius = 18.0,
    .border_width = 1.0,
    // These comptime values are only the pre-first-frame fallback. The
    // component receives the active palette through `setStyle` every frame.
    .background_color = paletteColor(theme.withAlpha(theme.default_colors.panel_alt, 248)),
    .border_color = paletteColor(theme.default_colors.panel_muted),
    .focus_border_color = paletteColor(theme.default_colors.accent),
    .focus_border_width = 1.5,
    // Force the bold pill labels (GPT-5.5, Medium, Fast, Full access) onto the
    // .ui role too so they share CalSans-Regular with the placeholder and the
    // workspace header buttons. The default `.ui_bold` falls through to the
    // renderer's heavy NotoSans-Bold, which reads as a different typeface.
    .bold_font_role = .ui,
    .control_background_color = paletteColor(theme.withAlpha(theme.default_colors.panel_muted, 86)),
    .control_hover_color = paletteColor(theme.withAlpha(theme.lighten(theme.default_colors.panel_alt, 0.08), 210)),
    .separator_color = paletteColor(theme.withAlpha(theme.default_colors.text_subtle, 90)),
    .menu_background_color = paletteColor(theme.default_colors.panel_alt),
    .menu_border_color = paletteColor(theme.default_colors.panel_muted),
    .menu_selected_color = paletteColor(theme.withAlpha(theme.default_colors.selection, 218)),
    .menu_hover_color = paletteColor(theme.lighten(theme.default_colors.panel_alt, 0.08)),
    .send_color = paletteColor(theme.default_colors.accent),
    .send_hover_color = paletteColor(theme.lighten(theme.default_colors.accent, 0.08)),
    .send_foreground_color = paletteColor(theme.default_colors.background),
    .stop_button_color = paletteColor(theme.default_colors.warning),
    .stop_button_hover_color = paletteColor(theme.lighten(theme.default_colors.warning, 0.08)),
    .stop_foreground_color = paletteColor(theme.default_colors.background),
    .text_color = paletteColor(theme.default_colors.text),
    .icon_color = paletteColor(theme.default_colors.text_muted),
    .cursor_color = paletteColor(theme.default_colors.text),
    .selection_color = paletteColor(theme.withAlpha(theme.default_colors.selection, 140)),
    .scrollbar_track_color = paletteColor(theme.withAlpha(theme.default_colors.panel_muted, 110)),
    .scrollbar_thumb_color = paletteColor(theme.withAlpha(theme.default_colors.text_muted, 200)),
    .placeholder_color = paletteColor(theme.withAlpha(theme.default_colors.text_subtle, 220)),
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
/// Width reserved per host-drawn state glyph embedded in the run pill's
/// summary, beside the segment it describes (brain / bolt / lock, ~22px
/// drawn, centered). The ~8px spare splits into the word-side and
/// separator-side gaps, so widening this spaces the glyph away from both
/// neighbors; mirrors the sizing convention of `pill_overlay_icon_reserve`.
pub const COMPOSER_RUN_PILL_ICON_CELL: f32 = 30.0;
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

const Mutex = state_sync.Mutex;
const Condition = state_sync.Condition;

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
            state.composer_controller.bang_history_message_index = null;
            state.setDraft(text);
            state.updateFileSearch();
            state.clampSlashCommandPickerSelection();
        },
        .submitted => {
            if (state.currentThread().isSendPendingForUi()) {
                if (state.currentThread().provider == .codex) {
                    state.queueDraftDuringSend();
                } else {
                    state.setSidebarNotice("This thread is still running. Press Tab to queue a follow-up.");
                }
                return;
            }
            if (state.acceptPrimaryFileSearchResult()) return;
            if (state.handleBangCommandSubmission()) return;
            if (state.handleWorkspaceCommand(state.currentProject().currentDraft())) return;
            if (state.handleProviderSlashCommand(state.currentProject().currentDraft())) return;
            state.sendDraft() catch |err| {
                log.err("failed to send draft: {s}", .{@errorName(err)});
                state.setSidebarNotice(chat_controller.initialSendStartFailureMessage(err));
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
            state.composer_controller.focused = focused;
            if (focused) {
                state.terminal_controller.focused = false;
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
    if (index >= state.composer_controller.model_picker_entries.items.len) return null;
    return state.composer_controller.model_picker_entries.items[index];
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
        .open_changed => |open| {
            if (!open) state.restoreComposerAfterShortcutPopover();
        },
        .highlighted => {},
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

pub const ProjectEditorTarget = state_ui_types.ProjectEditorTarget;

pub const log = std.log.scoped(.native_shell);

pub const ORG_NAME: [:0]const u8 = "verde";
pub const APP_NAME: [:0]const u8 = "Native";
pub const LEGACY_STATE_FILE_NAME = "state.json";
const CURSOR_MODEL_CACHE_FILE_NAME = "cursor-models.json";
pub const DEFAULT_CODEX_MODEL = provider_models.DEFAULT_CODEX_MODEL;
pub const DEFAULT_CODEX_REASONING_EFFORT = provider_models.DEFAULT_CODEX_REASONING_EFFORT;
pub const DEFAULT_OPENCODE_MODEL = provider_models.DEFAULT_OPENCODE_MODEL;
pub const DEFAULT_CLAUDE_MODEL = provider_models.DEFAULT_CLAUDE_MODEL;
pub const DEFAULT_CURSOR_MODEL = provider_models.DEFAULT_CURSOR_MODEL;
pub const IMAGE_MODAL_ID: [:0]const u8 = "AttachmentPreviewModal";
pub const THREAD_IMPORT_MODAL_ID: [:0]const u8 = "ThreadImportModal";
pub const TRANSCRIPT_SELECTION_MODAL_ID: [:0]const u8 = "TranscriptSelectionModal";
pub const VERDE_LOGO_BYTES = @embedFile("assets/verde_logo_mask.png");
pub const OPENCODE_LOGO_BYTES = surface_controller.OPENCODE_LOGO_BYTES;
pub const CODEX_LOGO_BYTES = surface_controller.CODEX_LOGO_BYTES;
pub const CLAUDE_LOGO_BYTES = surface_controller.CLAUDE_LOGO_BYTES;
pub const AMP_LOGO_BYTES = @embedFile("assets/amp-logo.png");
pub const THREAD_EDIT_BYTES = @embedFile("assets/thread_edit.png");
pub const CURSOR_LOGO_BYTES = surface_controller.CURSOR_LOGO_BYTES;
pub const EMACS_LOGO_BYTES = @embedFile("assets/editor_logos/emacs.png");
pub const NEOVIM_LOGO_BYTES = @embedFile("assets/editor_logos/neovim.png");
pub const VSCODE_LOGO_BYTES = @embedFile("assets/editor_logos/vscode.png");
pub const ZED_LOGO_BYTES = @embedFile("assets/editor_logos/zed.png");

const PersistedChatCompletion = db_types.PersistedChatCompletion;
const PersistedImageAttachment = db_types.PersistedImageAttachment;
const PersistedHerdrWorkspaceLink = db_types.PersistedHerdrWorkspaceLink;
const PersistedMessage = db_types.PersistedMessage;
const PersistedProject = db_types.PersistedProject;
const PersistedState = db_types.PersistedState;
const PersistedSurfaceCompletion = db_types.PersistedSurfaceCompletion;
const PersistedThread = db_types.PersistedThread;

// `utils.zig` owns the cross-cutting runtime helpers that are shared with the UI shell.
const SendWorkerRequest = utils.SendWorkerRequest;
const approvalPolicyForMode = utils.approvalPolicyForMode;
const captureClipboardImage = utils.captureClipboardImage;
const extensionForImageMime = utils.extensionForImageMime;
const cancelLingeringToolCallEvents = utils.cancelLingeringToolCallEvents;
const transientThinkStatus = utils.transientThinkStatus;
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
const upsertPendingToolCallEvent = utils.upsertPendingToolCallEvent;
const uploadTexture = utils.uploadTexture;

pub const ModelOption = provider_models.ModelOption;
const OpencodeReasoningMenuRow = provider_models.OpencodeReasoningMenuRow;
const PersistedCursorModelOption = provider_models.PersistedCursorModelOption;
const persistedCursorModelCacheNeedsRefresh = provider_models.persistedCursorModelCacheNeedsRefresh;
const cursorReasoningValueLabel = provider_models.cursorReasoningValueLabel;
const parseReasoningEffort = provider_models.parseReasoningEffort;
const claudeEffortValueLabel = provider_models.claudeEffortValueLabel;
const reasoningEffortDisplayLabel = provider_models.reasoningEffortDisplayLabel;
pub const ReasoningOption = provider_models.ReasoningOption;
const FastModeOption = provider_models.FastModeOption;
const AccessModeOption = provider_models.AccessModeOption;

const TranscriptMarkdownBody = chat_types.TranscriptMarkdownBody;
const TranscriptHeightEntry = chat_types.TranscriptHeightEntry;

pub const TranscriptMarkdownSelectionPoint = transcript_controller.MarkdownSelectionPoint;
pub const TranscriptMarkdownSelection = transcript_controller.MarkdownSelection;

pub const OPENCODE_MODEL_OPTIONS = provider_models.OPENCODE_MODEL_OPTIONS;
pub const CODEX_MODEL_OPTIONS = provider_models.CODEX_MODEL_OPTIONS;
pub const CURSOR_MODEL_OPTIONS = provider_models.CURSOR_MODEL_OPTIONS;
const CLAUDE_STANDARD_EFFORT_VALUES = provider_models.CLAUDE_STANDARD_EFFORT_VALUES;
const CLAUDE_FULL_EFFORT_VALUES = provider_models.CLAUDE_FULL_EFFORT_VALUES;
pub const CLAUDE_MODEL_OPTIONS = provider_models.CLAUDE_MODEL_OPTIONS;
pub const CODEX_REASONING_OPTIONS = provider_models.CODEX_REASONING_OPTIONS;
pub const CODEX_FAST_MODE_OPTIONS = provider_models.CODEX_FAST_MODE_OPTIONS;
pub const CODEX_ACCESS_MODE_OPTIONS = provider_models.CODEX_ACCESS_MODE_OPTIONS;

pub const ChatMessage = chat_types.ChatMessage;
pub const ChatImageAttachment = chat_types.ChatImageAttachment;

pub const SlashPickerRow = struct {
    name: []const u8,
    summary: []const u8,
    usage: []const u8,
    provider_label: []const u8,
    disabled: bool,
    requires_thread: bool,
};

pub const BackgroundTaskStatus = chat_types.BackgroundTaskStatus;
pub const BackgroundTask = chat_types.BackgroundTask;
pub const ChatThread = chat_types.ChatThread;

pub const PickerStatus = state_ui_types.PickerStatus;
pub const PickerState = state_ui_types.PickerState;

const OpencodeModelCacheStatus = provider_controller.OpencodeModelCacheStatus;
const OpencodeModelCacheState = provider_controller.OpencodeModelCacheState;
const CursorModelCacheStatus = provider_controller.CursorModelCacheStatus;
const CursorModelCacheState = provider_controller.CursorModelCacheState;
const ClaudeModelCacheStatus = provider_controller.ClaudeModelCacheStatus;
const ClaudeModelCacheState = provider_controller.ClaudeModelCacheState;
pub const ProviderReadiness = provider_controller.ProviderReadiness;
pub const ProviderReadinessSnapshot = provider_controller.ProviderReadinessSnapshot;
const ProviderReadinessStatus = provider_controller.ProviderReadinessStatus;
const ProviderReadinessState = provider_controller.ProviderReadinessState;

const SlashCommandStatus = command_controller.SlashCommandStatus;
const SlashCommandState = command_controller.SlashCommandState;
pub const PendingSlashCommandDetails = command_controller.PendingSlashCommandDetails;
const SlashCommandWorkerRequest = command_controller.SlashCommandWorkerRequest;

const FileSearchToken = file_search_controller.Token;
pub const FileSearchResult = file_search_controller.Result;

pub const ImportThreadSummary = struct {
    id: [:0]const u8,
    title: [:0]const u8,

    fn deinit(self: ImportThreadSummary, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.title);
    }
};

pub const HerdrProfileSummary = herdr_controller.ProfileSummary;

pub const TextureBackend = state_ui_types.TextureBackend;
pub const CachedImageTexture = state_ui_types.CachedImageTexture;

pub const WorkspacePaneId = workspace_layout.WorkspacePaneId;
pub const WorkspacePaneKind = workspace_layout.WorkspacePaneKind;
pub const WorkspacePaneRef = workspace_layout.WorkspacePaneRef;
pub const ChatPaneRef = workspace_layout.ChatPaneRef;
pub const TerminalPaneRef = workspace_layout.TerminalPaneRef;
pub const TerminalPanePurpose = workspace_layout.TerminalPanePurpose;

pub const BrowserTabRef = browser_pane.BrowserTabRef;
pub const BrowserPaneRef = browser_pane.BrowserPaneRef;

pub const BrowserOpenResult = browser_controller.BrowserOpenResult;

pub const OpenChatResult = workspace_controller.OpenChatResult;
pub const OpenChatRequest = workspace_controller.OpenChatRequest;

pub const BrowserScreenshotResult = browser_controller.BrowserScreenshotResult;
pub const BrowserTabIndicator = browser_controller.BrowserTabIndicator;
pub const BrowserWorkspaceLocation = browser_controller.BrowserWorkspaceLocation;
const browserToggleCloses = browser_controller.browserToggleCloses;
const browserNavigationUrlIsPersistable = browser_controller.browserNavigationUrlIsPersistable;
const browserUrlsHaveSameOrigin = browser_controller.browserUrlsHaveSameOrigin;

pub const WorkspacePane = workspace_layout.WorkspacePane;
pub const WorkspacePanePlacement = workspace_layout.WorkspacePanePlacement;

pub const TerminalDockEntry = project_state.TerminalDockEntry;
pub const ManagedProcessStatus = project_state.ManagedProcessStatus;
pub const ManagedProcess = project_state.ManagedProcess;
pub const WorkspaceLease = project_state.WorkspaceLease;
pub const TerminalProcessOutcome = project_state.TerminalProcessOutcome;
pub const TerminalProcessOutcomeStatus = project_state.TerminalProcessOutcomeStatus;

pub const CommandClass = workspace_controller.CommandClass;
pub const classifyWorkspaceCommand = workspace_controller.classifyWorkspaceCommand;
pub const inferredWorkspaceResource = workspace_controller.inferredWorkspaceResource;
pub const workspaceResourcesOverlap = workspace_controller.workspaceResourcesOverlap;
const appendOwnedString = workspace_controller.appendOwnedString;

const DefaultAgentTui = terminal_controller.DefaultAgentTui;
const OPENCODE_TUI_COMMAND = terminal_controller.OPENCODE_TUI_COMMAND;
const defaultAgentTui = terminal_controller.defaultAgentTui;
const isKnownDefaultAgentTuiCommand = terminal_controller.isKnownDefaultAgentTuiCommand;
const agentTuiProviderLabel = terminal_controller.agentTuiProviderLabel;

pub const WorkspaceSplitAxis = workspace_layout.WorkspaceSplitAxis;
pub const WorkspacePaneDirection = workspace_layout.WorkspacePaneDirection;
pub const WorkspaceNode = workspace_layout.WorkspaceNode;
pub const FloatingPaneGeometry = workspace_layout.FloatingPaneGeometry;
pub const FloatingQuickPane = workspace_layout.FloatingQuickPane;
pub const WorkspaceLayout = workspace_layout.WorkspaceLayout;
const deinitWorkspacePaneRef = workspace_layout.deinitWorkspacePaneRef;

pub const HerdrPanePresentation = herdr_types.HerdrPanePresentation;
pub const HerdrPaneProvider = herdr_types.HerdrPaneProvider;
const ProviderExecutionTarget = herdr_types.ProviderExecutionTarget;
pub const HerdrPaneLink = herdr_types.HerdrPaneLink;
pub const HerdrWorkspaceLink = herdr_types.HerdrWorkspaceLink;
pub const HerdrOpenResult = herdr_controller.HerdrOpenResult;
pub const HerdrHandoffWorkspaceResult = herdr_controller.HerdrHandoffWorkspaceResult;
pub const HerdrHandoffResult = herdr_controller.HerdrHandoffResult;
pub const HerdrUnlinkPreviousLink = herdr_controller.HerdrUnlinkPreviousLink;
pub const HerdrUnlinkWorkspaceResult = herdr_controller.HerdrUnlinkWorkspaceResult;
pub const HerdrUnlinkResult = herdr_controller.HerdrUnlinkResult;
const herdrUiFailureMessage = herdr_controller.herdrUiFailureMessage;

pub const Project = project_state.Project;

pub const Storage = state_storage.Storage;

pub const SendStatus = chat_types.SendStatus;
pub const FollowupKind = chat_types.FollowupKind;
pub const FollowupState = chat_types.FollowupState;
pub const PendingFollowup = chat_types.PendingFollowup;
pub const SendState = chat_types.SendState;
pub const TitleGenerationStatus = chat_types.TitleGenerationStatus;
pub const TitleGenerationState = chat_types.TitleGenerationState;
const OpeningExchange = chat_types.OpeningExchange;
const TitleGenerationRequest = chat_types.TitleGenerationRequest;
pub const PendingApproval = chat_types.PendingApproval;
pub const PendingDiffFile = chat_types.PendingDiffFile;
pub const PendingTimelineEvent = chat_types.PendingTimelineEvent;
pub const SendResultPayload = chat_types.SendResultPayload;

const BangCommandRequest = chat_controller.BangCommandRequest;
const bangCommandWorker = chat_controller.bangCommandWorker;
const InitialSendSnapshot = chat_controller.InitialSendSnapshot;

const freePendingFollowup = chat_types.freePendingFollowup;

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

const ComposerControllerState = composer_controller.State(
    PaletteComposerPrompt,
    PaletteModelPicker,
    ModelPickerEntry,
    PaletteRunStepper,
    RunStepperContext,
);

pub const HandoffTargetSurface = handoff_controller.TargetSurface;

pub const AppState = struct {
    pub const DRAFT_CAPACITY = chat_types.DRAFT_CAPACITY;

    allocator: std.mem.Allocator,
    storage: *const Storage,
    project_controller: project_controller.State,
    surface_controller: surface_controller.State,
    import_path_storage: [DRAFT_CAPACITY:0]u8,
    rename_storage: [256:0]u8,
    sidebar_notice_storage: [256:0]u8,
    import_thread_id_storage: [256:0]u8,
    import_notice_storage: [256:0]u8,
    herdr_controller: herdr_controller.State,
    sidebar_collapsed: bool,
    sidebar_hidden: bool,
    sidebar_hover_revealed: bool,
    composer_controller: ComposerControllerState,
    palette_overlay_batch: palette.RenderBatch,
    palette_frame_text: std.ArrayList(u8),
    palette_frame_text_arena: std.heap.ArenaAllocator,
    palette_modal_hits: std.ArrayList(PaletteModalHit),
    palette_modal_pointer_captured: bool,
    code_copy_buttons: std.ArrayList(CodeCopyButtonHit),
    code_copy_recent_identity: u64,
    code_copy_recent_until_ms: i64,
    card_toggle_hits: std.ArrayList(CardToggleHit),
    background_task_action_hits: std.ArrayList(BackgroundTaskActionHit),
    expanded_cards: std.AutoHashMap(u64, bool),
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
    terminal_controller: terminal_controller.State,
    // Whether the OS window currently holds input focus. Updated from SDL
    // window focus events; used to gate chat-completion notifications so we
    // don't notify about a turn the user is actively watching.
    window_input_focus: bool,
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
    rename_thread_index: ?usize,
    thread_import_provider: ?Provider,
    thread_import_project_index: ?usize,
    thread_import_selected_index: ?usize,
    /// Row index in `thread_import_threads` under the cursor (import modal list).
    thread_import_hover_index: ?usize,
    thread_import_threads: std.ArrayList(ImportThreadSummary),
    handoff_controller: handoff_controller.State,
    /// Command palette (Ctrl+Shift+P overlay). `ui/command_palette.zig` owns result
    /// building and rendering; these are the cross-cutting bits the input
    /// router and keybind dispatch need.
    command_controller: command_controller.State,
    settings_controller: settings_controller.State,
    app_config_file_mtime: i128,
    app_config_runtime_sync_pending: bool,
    project_directory_browse_requested: bool,
    project_directory_picker_create_parent: bool,
    picker_state: PickerState,
    slash_command_state: SlashCommandState,
    provider_controller: provider_controller.State,
    file_search_controller: file_search_controller.State,
    browser_controller: browser_controller.State,
    /// Palette sidebar thread row under the cursor (hover highlight).
    sidebar_thread_hover: ?SidebarThreadHover,
    sidebar_project_hover: ?usize,
    sidebar_new_thread_hover: ?usize,
    /// Split "Open" header menu (folder / editors); palette workspace chrome only.
    workspace_header_open_menu_open: bool,
    workspace_header_open_menu_pane_id: ?WorkspacePaneId,
    sidebar_context_menu_open: bool,
    sidebar_context_menu_kind: SidebarContextMenuKind,
    sidebar_context_menu_project_index: usize,
    sidebar_context_menu_thread_index: usize,
    sidebar_context_menu_anchor_x: f32,
    sidebar_context_menu_anchor_y: f32,
    transcript_controller: transcript_controller.State,
    lifecycle: lifecycle_controller.State,
    chat_controller: chat_controller.State,
    /// Set by the sidebar render pass whenever it draws a pulsing status pip
    /// this frame; cleared at the top of renderRoot. The main loop reads the
    /// previous frame's value to keep a ~30fps animation tick going (the loop
    /// otherwise sleeps and the pulse would step at the 1Hz label cadence).
    sidebar_pulse_animating: bool,
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
        var browser_controller_state = try browser_controller.State.init(allocator);
        errdefer browser_controller_state.deinit(allocator);

        var state: AppState = .{
            .allocator = allocator,
            .storage = storage,
            .project_controller = .{},
            .surface_controller = .{},
            .import_path_storage = std.mem.zeroes([DRAFT_CAPACITY:0]u8),
            .rename_storage = std.mem.zeroes([256:0]u8),
            .sidebar_notice_storage = std.mem.zeroes([256:0]u8),
            .import_thread_id_storage = std.mem.zeroes([256:0]u8),
            .import_notice_storage = std.mem.zeroes([256:0]u8),
            .herdr_controller = .{},
            .sidebar_collapsed = false,
            .sidebar_hidden = false,
            .sidebar_hover_revealed = false,
            .composer_controller = ComposerControllerState.init(),
            .palette_overlay_batch = .{},
            .palette_frame_text = .empty,
            .palette_frame_text_arena = std.heap.ArenaAllocator.init(allocator),
            .palette_modal_hits = .empty,
            .palette_modal_pointer_captured = false,
            .code_copy_buttons = .empty,
            .code_copy_recent_identity = 0,
            .code_copy_recent_until_ms = 0,
            .card_toggle_hits = .empty,
            .background_task_action_hits = .empty,
            .expanded_cards = std.AutoHashMap(u64, bool).init(allocator),
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
            .terminal_controller = .{},
            .window_input_focus = true,
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
            .rename_thread_index = null,
            .thread_import_provider = null,
            .thread_import_project_index = null,
            .thread_import_selected_index = null,
            .thread_import_hover_index = null,
            .thread_import_threads = .empty,
            .handoff_controller = .{},
            .command_controller = .{},
            .settings_controller = .{},
            .app_config_file_mtime = -1,
            .app_config_runtime_sync_pending = false,
            .project_directory_browse_requested = false,
            .project_directory_picker_create_parent = false,
            .picker_state = .{},
            .slash_command_state = .{},
            .provider_controller = .{},
            .file_search_controller = .{},
            .browser_controller = browser_controller_state,
            .sidebar_thread_hover = null,
            .sidebar_project_hover = null,
            .sidebar_new_thread_hover = null,
            .workspace_header_open_menu_open = false,
            .workspace_header_open_menu_pane_id = null,
            .sidebar_context_menu_open = false,
            .sidebar_context_menu_kind = .none,
            .sidebar_context_menu_project_index = 0,
            .sidebar_context_menu_thread_index = 0,
            .sidebar_context_menu_anchor_x = 0.0,
            .sidebar_context_menu_anchor_y = 0.0,
            .transcript_controller = .{},
            .lifecycle = .{},
            .chat_controller = .{},
            .sidebar_pulse_animating = false,
            .external_open_close_suppress_until_ms = 0,
        };
        state.composer_controller.composer.setCallbacks(.{});

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
        if (state.app_config.mcp_integration_enabled) {
            state.settings_controller.mcp_summary = provider_mcp.install(state.allocator) catch |err| blk: {
                log.warn("failed to refresh enabled provider MCP registrations: {s}", .{@errorName(err)});
                break :blk provider_mcp.inspect(state.allocator);
            };
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

    pub const opencodeModelOptionsSnapshot = provider_controller.opencodeModelOptionsSnapshot;
    pub const claudeModelOptionsSnapshot = provider_controller.claudeModelOptionsSnapshot;
    pub const cursorModelOptionsSnapshot = provider_controller.cursorModelOptionsSnapshot;
    pub const cachedDefaultModelRefForProvider = provider_controller.cachedDefaultModelRefForProvider;
    pub const startOpencodeModelOptionsRefresh = provider_controller.startOpencodeModelOptionsRefresh;
    pub const startCursorModelOptionsRefresh = provider_controller.startCursorModelOptionsRefresh;
    pub const startClaudeModelOptionsRefresh = provider_controller.startClaudeModelOptionsRefresh;
    pub const startProviderReadinessCheck = provider_controller.startProviderReadinessCheck;
    pub const completeMcpOnboarding = provider_controller.completeMcpOnboarding;
    pub const pollProviderReadiness = provider_controller.pollProviderReadiness;
    pub const providerReadinessSnapshot = provider_controller.providerReadinessSnapshot;
    pub const dismissProviderOnboarding = provider_controller.dismissProviderOnboarding;
    pub const recheckProviderReadiness = provider_controller.recheckProviderReadiness;
    pub const openProviderSetupGuide = provider_controller.openProviderSetupGuide;
    pub const refreshOpencodeModelOptionsCacheAsync = provider_controller.refreshOpencodeModelOptionsCacheAsync;
    pub const refreshCursorModelOptionsCacheAsync = provider_controller.refreshCursorModelOptionsCacheAsync;
    pub const refreshClaudeModelOptionsCacheAsync = provider_controller.refreshClaudeModelOptionsCacheAsync;
    pub const duplicateReasoningVariantKeys = provider_controller.duplicateReasoningVariantKeys;
    pub const populateOpencodeModelOptions = provider_controller.populateOpencodeModelOptions;
    pub const opencodeModelIdSuffixFromRef = provider_controller.opencodeModelIdSuffixFromRef;
    pub const opencodeSortedModelsContainModelIdFromOrder = provider_controller.opencodeSortedModelsContainModelIdFromOrder;
    pub const opencodeModelSortLessThan = provider_controller.opencodeModelSortLessThan;
    pub const populateCursorModelOptions = provider_controller.populateCursorModelOptions;
    pub const populateClaudeModelOptions = provider_controller.populateClaudeModelOptions;
    pub const asciiCaseInsensitiveCompare = provider_controller.asciiCaseInsensitiveCompare;
    pub const normalizeCurrentOpencodeThreadModel = provider_controller.normalizeCurrentOpencodeThreadModel;
    pub const opencodeModelOptionForRef = provider_controller.opencodeModelOptionForRef;
    pub const refreshOpencodeReasoningMenu = provider_controller.refreshOpencodeReasoningMenu;
    pub const refreshCursorReasoningMenu = provider_controller.refreshCursorReasoningMenu;
    pub const refreshClaudeReasoningMenu = provider_controller.refreshClaudeReasoningMenu;
    pub const cursorModelOptionForRef = provider_controller.cursorModelOptionForRef;
    pub const claudeModelOptionForRef = provider_controller.claudeModelOptionForRef;
    pub const cursorModelParamsJsonAlloc = provider_controller.cursorModelParamsJsonAlloc;
    pub const normalizeOpencodeReasoningVariant = provider_controller.normalizeOpencodeReasoningVariant;
    pub const clearDynamicOpencodeModelOptions = provider_controller.clearDynamicOpencodeModelOptions;
    pub const clearOpencodeReasoningMenu = provider_controller.clearOpencodeReasoningMenu;
    pub const clearOpencodeModelOptions = provider_controller.clearOpencodeModelOptions;
    pub const clearDynamicCursorModelOptions = provider_controller.clearDynamicCursorModelOptions;
    pub const clearDynamicClaudeModelOptions = provider_controller.clearDynamicClaudeModelOptions;
    pub const clearClaudeModelOptions = provider_controller.clearClaudeModelOptions;
    pub const clearCursorModelOptions = provider_controller.clearCursorModelOptions;
    pub const loadCursorModelOptionsDiskCache = provider_controller.loadCursorModelOptionsDiskCache;
    pub const saveCursorModelOptionsDiskCache = provider_controller.saveCursorModelOptionsDiskCache;

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
        try self.project_controller.projects.append(self.allocator, project);
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
        const index = self.project_controller.projects.items.len - 1;
        self.project_controller.selected_index = index;
        self.syncRenameBuffer();
        self.project_controller.show_creator = false;
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

    pub fn ensureDirectoryPath(self: *AppState, raw_path: []const u8) ![]u8 {
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

    pub fn appendMessageToThread(
        self: *AppState,
        thread: *ChatThread,
        role: ChatRole,
        author: []const u8,
        body: []const u8,
        image: ?*const ChatImageAttachment,
        extra_images: []const ChatImageAttachment,
    ) !void {
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

    pub fn appendInitialSendFailure(self: *AppState, thread: *ChatThread, message: []const u8) void {
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
        self.project_controller.show_creator = false;
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
        runtime_log.diagnostic("browseForWorkspaceDirectory entry show_project_creator={} draft_len={d}", .{ self.project_controller.show_creator, self.importDirectoryDraft().len });
        log.info("browseForWorkspaceDirectory entry show_project_creator={} draft_len={d}", .{ self.project_controller.show_creator, self.importDirectoryDraft().len });
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
        if (self.project_controller.projects.items.len == 0) return;
        self.renameProjectAtIndex(self.project_controller.selected_index, self.renameInput()) catch |err| switch (err) {
            error.EmptyProjectName => self.setSidebarNotice("Workspace name cannot be empty."),
            else => self.setSidebarNotice("Rename failed."),
        };
    }

    pub fn renameProjectAtIndex(self: *AppState, index: usize, label: []const u8) !void {
        if (index >= self.project_controller.projects.items.len) return error.ProjectNotFound;
        const trimmed = std.mem.trim(u8, label, &std.ascii.whitespace);
        if (trimmed.len == 0) return error.EmptyProjectName;

        const project = &self.project_controller.projects.items[index];
        const copied = try self.allocator.dupeZ(u8, trimmed);
        self.allocator.free(project.label);
        project.label = copied;
        if (self.project_controller.selected_index == index) self.syncRenameBuffer();
        self.setSidebarNotice("Workspace renamed.");
        self.markDirty();
    }

    pub fn beginProjectRename(self: *AppState, index: usize) void {
        if (index >= self.project_controller.projects.items.len) return;
        if (self.project_controller.show_creator) self.cancelProjectImport();
        self.project_controller.selected_index = index;
        self.rename_project_index = index;
        self.rename_thread_index = null;
        self.syncRenameBuffer();
        self.palette_modal_text_focus = .project_rename;
        self.project_rename_cursor = self.renameInput().len;
        self.setSidebarNotice("");
    }

    pub fn beginCurrentThreadRename(self: *AppState) void {
        if (self.project_controller.selected_index >= self.project_controller.projects.items.len) return;
        const project = &self.project_controller.projects.items[self.project_controller.selected_index];
        if (project.selected_thread_index >= project.threads.items.len) return;
        self.beginThreadRename(self.project_controller.selected_index, project.selected_thread_index);
    }

    pub fn beginThreadRename(self: *AppState, project_index: usize, thread_index: usize) void {
        if (project_index >= self.project_controller.projects.items.len) return;
        const project = &self.project_controller.projects.items[project_index];
        if (thread_index >= project.threads.items.len) return;
        if (self.project_controller.show_creator) self.cancelProjectImport();
        self.project_controller.selected_index = project_index;
        project.selected_thread_index = thread_index;
        self.rename_project_index = project_index;
        self.rename_thread_index = thread_index;
        self.syncThreadRenameBuffer(project.threads.items[thread_index].title);
        self.palette_modal_text_focus = .project_rename;
        self.project_rename_cursor = self.renameInput().len;
        self.setSidebarNotice("");
    }

    pub fn selectProjectAtIndex(self: *AppState, index: usize) bool {
        if (index >= self.project_controller.projects.items.len) return false;
        self.project_controller.selected_index = index;
        self.ensureCurrentProjectWorkspace();
        self.restorePersistedBrowserPaneAfterProjectSelection(index);
        const focused_pane_id = self.project_controller.projects.items[index].workspace_layout.focused_pane_id;
        if (focused_pane_id) |pane_id| _ = self.focusWorkspacePane(index, pane_id);
        self.workspace_header_open_menu_open = false;
        self.workspace_header_open_menu_pane_id = null;
        self.sidebar_context_menu_open = false;
        self.syncRenameBuffer();
        self.markDirty();
        return true;
    }

    pub fn selectAdjacentProject(self: *AppState, direction: isize) bool {
        if (self.project_controller.projects.items.len == 0 or direction == 0) return false;
        const len: isize = @intCast(self.project_controller.projects.items.len);
        const current: isize = @intCast(self.project_controller.selected_index);
        const next: usize = @intCast(@mod(current + direction, len));
        return self.selectProjectAtIndex(next);
    }

    pub fn beginThreadImport(self: *AppState, index: usize, provider: Provider) void {
        if (index >= self.project_controller.projects.items.len) return;
        if (self.project_controller.show_creator) self.cancelProjectImport();
        if (self.herdr_controller.picker_project_index != null) self.cancelHerdrProfilePicker();
        self.project_controller.selected_index = index;
        self.rename_project_index = null;
        self.rename_thread_index = null;
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
        if (index >= self.project_controller.projects.items.len) return;
        if (self.project_controller.show_creator) self.cancelProjectImport();
        if (self.thread_import_provider != null) self.cancelThreadImport();
        self.project_controller.selected_index = index;
        self.rename_project_index = null;
        self.rename_thread_index = null;
        self.herdr_controller.picker_project_index = index;
        self.herdr_controller.selected_index = null;
        self.herdr_controller.hover_index = null;
        self.palette_modal_text_focus = .none;
        self.setHerdrProfileNotice("");
        self.clearHerdrProfileSummaries();
        self.refreshHerdrProfileList();
    }

    pub fn cancelHerdrProfilePicker(self: *AppState) void {
        self.herdr_controller.picker_project_index = null;
        self.herdr_controller.selected_index = null;
        self.herdr_controller.hover_index = null;
        self.palette_modal_text_focus = .none;
        self.setHerdrProfileNotice("");
        self.clearHerdrProfileSummaries();
        self.markDirty();
    }

    pub fn refreshHerdrProfileList(self: *AppState) void {
        if (self.herdr_controller.picker_project_index == null) return;
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
            self.herdr_controller.summaries.append(self.allocator, summary) catch {
                self.setHerdrProfileNotice("Could not store Herdr profile list.");
                return;
            };
        }

        if (self.herdr_controller.summaries.items.len == 0) {
            self.setHerdrProfileNotice("No Herdr profiles configured. Use `verde herdr profiles add` first.");
        } else {
            self.herdr_controller.selected_index = 0;
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
        if (index >= self.herdr_controller.summaries.items.len) return;
        self.herdr_controller.selected_index = index;
        self.markDirty();
    }

    pub fn handoffProjectToSelectedHerdrProfile(self: *AppState) void {
        const project_index = self.herdr_controller.picker_project_index orelse return;
        const profile_index = self.herdr_controller.selected_index orelse {
            self.setHerdrProfileNotice("Select a Herdr profile first.");
            return;
        };
        if (project_index >= self.project_controller.projects.items.len or profile_index >= self.herdr_controller.summaries.items.len) return;
        const profile = self.herdr_controller.summaries.items[profile_index];
        self.handoffProjectToRemoteHerdrProfile(project_index, profile);
    }

    fn handoffProjectToRemoteHerdrProfile(self: *AppState, project_index: usize, profile: HerdrProfileSummary) void {
        if (project_index >= self.project_controller.projects.items.len) return;
        const project = &self.project_controller.projects.items[project_index];
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
        if (project_index >= self.project_controller.projects.items.len) {
            self.cancelThreadImport();
            return;
        }

        self.clearThreadImportThreads();

        const project = &self.project_controller.projects.items[project_index];
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

    /// Opens a thread in a brand-new chat pane split off the focused pane,
    /// preserving the existing layout. This is the command palette's
    /// Ctrl+Enter / "Open in New Pane" path; plain Enter goes through
    /// `selectThreadForProject` (reuse a visible chat pane) instead.
    pub fn openThreadInWorkspaceSplit(self: *AppState, project_index: usize, thread_index: usize) void {
        if (project_index >= self.project_controller.projects.items.len) return;
        var project = &self.project_controller.projects.items[project_index];
        if (thread_index >= project.threads.items.len) return;
        self.project_controller.selected_index = project_index;
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
        layout.focusCreatedPane(new_pane_id);
        project.selected_thread_index = thread_index;
        self.terminal_controller.focused = false;
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
        return std.mem.sliceTo(self.herdr_controller.notice_storage[0..], 0);
    }

    pub fn setHerdrProfileNotice(self: *AppState, value: []const u8) void {
        @memset(&self.herdr_controller.notice_storage, 0);
        const len = @min(value.len, self.herdr_controller.notice_storage.len - 1);
        @memcpy(self.herdr_controller.notice_storage[0..len], value[0..len]);
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
        if (project_index >= self.project_controller.projects.items.len) {
            self.cancelThreadImport();
            return;
        }

        const trimmed_id = std.mem.trim(u8, self.threadImportThreadId(), &std.ascii.whitespace);
        if (trimmed_id.len == 0) {
            self.setThreadImportNotice(emptyThreadImportIdNotice(provider));
            return;
        }

        if (self.findThreadIndexByProviderThreadId(project_index, provider, trimmed_id)) |thread_index| {
            self.project_controller.selected_index = project_index;
            self.project_controller.projects.items[project_index].selected_thread_index = thread_index;
            self.requestComposerFocus();
            self.requestTranscriptScrollToBottom();
            self.setSidebarNotice(duplicateThreadNotice(provider));
            self.cancelThreadImport();
            return;
        }

        const project = &self.project_controller.projects.items[project_index];
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

        self.project_controller.projects.items[project_index].threads.append(self.allocator, imported) catch {
            self.setThreadImportNotice(failedAddImportedThreadNotice(provider));
            return;
        };
        self.project_controller.projects.items[project_index].invalidateSidebarThreadCache();
        self.project_controller.selected_index = project_index;
        self.project_controller.projects.items[project_index].selected_thread_index = self.project_controller.projects.items[project_index].threads.items.len - 1;
        self.requestComposerFocus();
        self.requestTranscriptScrollToBottom();
        self.markDirty();
        self.setSidebarNotice(threadImportedNotice(provider));
        self.cancelThreadImport();
    }

    pub fn syncThreadFromProvider(self: *AppState, project_index: usize, thread_index: usize) void {
        if (project_index >= self.project_controller.projects.items.len) {
            self.setSidebarNotice("Workspace not found.");
            return;
        }

        const project = &self.project_controller.projects.items[project_index];
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

        self.project_controller.selected_index = project_index;
        self.project_controller.projects.items[project_index].selected_thread_index = thread_index;
        self.requestComposerFocus();
        self.syncRenameBuffer();
        self.requestTranscriptScrollToBottom();
        self.markDirty();
        self.setSidebarNotice(threadSyncedNotice(provider));
    }

    pub fn finishProjectRename(self: *AppState) void {
        if (self.rename_project_index) |index| {
            if (index < self.project_controller.projects.items.len) {
                self.project_controller.selected_index = index;
                if (self.rename_thread_index) |thread_index| {
                    self.renameThreadAtIndex(index, thread_index, self.renameInput()) catch |err| switch (err) {
                        error.EmptyThreadTitle => self.setSidebarNotice("Chat title cannot be empty."),
                        else => self.setSidebarNotice("Rename failed."),
                    };
                } else {
                    self.renameSelectedProject();
                }
            }
        }
        self.rename_project_index = null;
        self.rename_thread_index = null;
        if (self.palette_modal_text_focus == .project_rename) self.palette_modal_text_focus = .none;
    }

    pub fn cancelProjectRename(self: *AppState) void {
        self.rename_project_index = null;
        self.rename_thread_index = null;
        if (self.palette_modal_text_focus == .project_rename) self.palette_modal_text_focus = .none;
        self.syncRenameBuffer();
    }

    pub fn renameThreadAtIndex(self: *AppState, project_index: usize, thread_index: usize, title: []const u8) !void {
        if (project_index >= self.project_controller.projects.items.len) return error.ProjectNotFound;
        const project = &self.project_controller.projects.items[project_index];
        if (thread_index >= project.threads.items.len) return error.ThreadNotFound;
        const trimmed = std.mem.trim(u8, title, &std.ascii.whitespace);
        if (trimmed.len == 0) return error.EmptyThreadTitle;

        const owned = try self.allocator.dupeZ(u8, trimmed);
        const thread = &project.threads.items[thread_index];
        thread.discardPendingGeneratedTitle();
        self.allocator.free(thread.title);
        thread.title = owned;
        thread.touch();
        project.invalidateSidebarThreadCache();
        self.setSidebarNotice("Chat renamed.");
        self.markDirty();
    }

    /// Reorders the workspace list, moving the project at `from` so it lands
    /// immediately before slot `before` (in current array coordinates; pass
    /// `projects.items.len` to drop at the end). Keeps `selected_project_index`
    /// pointing at the same logical workspace and persists the new order.
    pub fn moveProject(self: *AppState, from: usize, before: usize) void {
        const len = self.project_controller.projects.items.len;
        if (from >= len) return;

        var insert_at = before;
        if (insert_at > from) insert_at -= 1;
        if (insert_at >= len) insert_at = len - 1;
        if (insert_at == from) return;

        const sel_is_from = self.project_controller.selected_index == from;
        const moved = self.project_controller.projects.orderedRemove(from);
        self.project_controller.projects.insert(self.allocator, insert_at, moved) catch {
            // Best effort: restore near the original slot so we never drop it.
            self.project_controller.projects.insert(self.allocator, from, moved) catch {
                self.project_controller.projects.append(self.allocator, moved) catch {};
            };
            return;
        };

        if (sel_is_from) {
            self.project_controller.selected_index = insert_at;
        } else {
            var s = self.project_controller.selected_index;
            if (s > from) s -= 1;
            if (s >= insert_at) s += 1;
            self.project_controller.selected_index = s;
        }
        self.browser_controller.projectMoved(from, insert_at);

        self.syncRenameBuffer();
        self.markDirty();
    }

    fn restoreClosedProject(self: *AppState, archived_index: usize, unread_count: u8) !void {
        if (archived_index >= self.project_controller.archived_projects.items.len) return error.ProjectNotFound;
        var restored = self.project_controller.archived_projects.orderedRemove(archived_index);
        var restored_appended = false;
        errdefer if (!restored_appended) restored.deinit(self.allocator);
        restored.archived = false;
        restored.unread_count = unread_count;
        if (restored.threads.items.len == 0) {
            _ = try restored.addThread(self.allocator);
        }
        try restored.normalize(self.allocator, self.app_config.terminal_font_size);
        try self.project_controller.projects.append(self.allocator, restored);
        restored_appended = true;
        self.project_controller.selected_index = self.project_controller.projects.items.len - 1;
        self.ensureCurrentProjectWorkspace();
        self.restorePersistedBrowserPaneAfterProjectSelection(self.project_controller.selected_index);
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
        if (self.project_controller.archived_projects.items.len == 0) {
            self.setSidebarNotice("No closed workspaces to reopen.");
            return false;
        }
        return self.reopenClosedProjectAtIndex(self.project_controller.archived_projects.items.len - 1);
    }

    pub fn closeProjectAtIndex(self: *AppState, index: usize) void {
        _ = self.closeProjectAtIndexResult(index);
    }

    pub fn closeProjectAtIndexResult(self: *AppState, index: usize) bool {
        if (index >= self.project_controller.projects.items.len) return false;
        if (self.projectHasPendingSend(index)) {
            self.setSidebarNotice("Finish this workspace's running provider requests before closing it.");
            return false;
        }
        if (projectHasRunningBackgroundTasks(&self.project_controller.projects.items[index])) {
            self.setSidebarNotice("Stop this workspace's background tasks before closing it.");
            return false;
        }

        self.cancelThreadImport();
        const closed_selected_project = self.project_controller.selected_index == index;
        const closed_active_browser = if (self.browser_controller.runtime_project_index) |runtime_index|
            runtime_index == index
        else
            false;
        if (closed_active_browser) self.deactivateBrowserRuntime(true);
        var removed = self.project_controller.projects.orderedRemove(index);
        removed.archived = true;
        removed.terminal_dock.visible = false;
        removed.terminateWorkspaceSessions();
        self.project_controller.archived_projects.append(self.allocator, removed) catch |err| {
            var failed = removed;
            failed.deinit(self.allocator);
            self.setSidebarNotice(@errorName(err));
            return false;
        };

        if (self.project_controller.projects.items.len == 0) {
            self.project_controller.selected_index = 0;
        } else if (self.project_controller.selected_index == index) {
            self.project_controller.selected_index = @min(index, self.project_controller.projects.items.len - 1);
        } else if (self.project_controller.selected_index > index) {
            self.project_controller.selected_index -= 1;
        }
        if (!closed_active_browser) _ = self.browser_controller.projectRemoved(index);
        if (self.project_controller.projects.items.len > 0 and (closed_active_browser or closed_selected_project)) {
            self.restorePersistedBrowserPaneAfterProjectSelection(self.project_controller.selected_index);
        }

        self.rename_project_index = null;
        self.rename_thread_index = null;
        self.syncRenameBuffer();
        self.setSidebarNotice("Workspace closed.");
        self.markDirty();
        return true;
    }

    fn projectHasPendingSend(self: *const AppState, index: usize) bool {
        if (index >= self.project_controller.projects.items.len) return false;
        for (self.project_controller.projects.items[index].threads.items) |*thread| {
            if (thread.isSendPending()) {
                return true;
            }
        }
        return false;
    }

    fn projectHasRunningBackgroundTasks(project: *const Project) bool {
        for (project.threads.items) |*thread| if (threadHasRunningBackgroundTasks(thread)) return true;
        for (project.archived_threads.items) |*thread| if (threadHasRunningBackgroundTasks(thread)) return true;
        return false;
    }

    pub fn archiveThreadAtIndex(self: *AppState, project_index: usize, thread_index: usize) void {
        if (project_index >= self.project_controller.projects.items.len) {
            self.setSidebarNotice("Workspace not found.");
            return;
        }

        const project = &self.project_controller.projects.items[project_index];
        if (thread_index >= project.threads.items.len) {
            self.setSidebarNotice("Thread not found.");
            return;
        }

        if (project.threads.items[thread_index].isSendPending()) {
            self.setSidebarNotice("Finish this thread's provider request before archiving.");
            return;
        }
        if (threadHasRunningBackgroundTasks(&project.threads.items[thread_index])) {
            self.setSidebarNotice("Stop this thread's background tasks before archiving so their controls remain available.");
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

        self.project_controller.selected_index = project_index;
        self.syncRenameBuffer();
        self.requestTranscriptScrollToBottom();
        self.markDirty();
        self.setSidebarNotice("Thread archived.");
    }

    pub fn createThreadForProject(self: *AppState, index: usize) void {
        if (index >= self.project_controller.projects.items.len) return;
        if (self.app_config.new_chat_pane_behavior == .new_pane) {
            self.project_controller.selected_index = index;
            var layout = &self.project_controller.projects.items[index].workspace_layout;
            _ = layout.ensureDefaultChat(self.allocator) catch |err| {
                log.err("failed to prepare workspace for new chat pane: {s}", .{@errorName(err)});
                self.setSidebarNotice("Failed to prepare the workspace.");
                return;
            };
            if (layout.gridNewPanePlacement()) |placement| {
                _ = self.splitWorkspacePaneWithChatPlacement(index, placement.pane_id, placement.axis, placement.new_after);
                return;
            }
            const target_pane_id = layout.focused_pane_id orelse layout.firstVisiblePaneId() orelse {
                self.setSidebarNotice("No workspace pane selected.");
                return;
            };
            _ = self.splitWorkspacePaneWithChatPlacement(index, target_pane_id, .vertical, true);
            return;
        }

        var project = &self.project_controller.projects.items[index];
        const thread_index = project.addThread(self.allocator) catch {
            self.setSidebarNotice("Failed to create a new thread.");
            return;
        };
        self.project_controller.selected_index = index;
        self.focusProjectThreadInWorkspace(index, thread_index) catch |err| {
            log.err("failed to focus new thread workspace pane: {s}", .{@errorName(err)});
        };
        self.requestComposerFocus();
        self.syncRenameBuffer();
        self.setSidebarNotice("New thread ready.");
        self.markDirty();
    }

    pub fn selectThreadForProject(self: *AppState, project_index: usize, thread_index: usize) void {
        if (project_index >= self.project_controller.projects.items.len) return;
        const project = &self.project_controller.projects.items[project_index];
        if (thread_index >= project.threads.items.len) return;
        self.project_controller.selected_index = project_index;
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
        if (project_index >= self.project_controller.projects.items.len) return;
        var project = &self.project_controller.projects.items[project_index];
        if (thread_index >= project.threads.items.len) return;
        var layout = &project.workspace_layout;
        _ = try layout.ensureDefaultChat(self.allocator);

        var chat_pane_id = layout.retargetPreferredChatPane(thread_index);
        var created_pane = false;

        if (chat_pane_id == null) {
            const new_pane_id = try layout.createChatPane(self.allocator, thread_index);
            const target_pane_id = layout.focused_pane_id orelse layout.firstVisiblePaneId();
            if (target_pane_id) |target_id| {
                try layout.splitPaneWithLeaf(self.allocator, target_id, new_pane_id, .vertical, true);
            } else {
                try layout.replaceRootWithLeaf(self.allocator, new_pane_id);
            }
            chat_pane_id = new_pane_id;
            created_pane = true;
        }

        if (created_pane) {
            layout.focusCreatedPane(chat_pane_id.?);
        } else {
            layout.focused_pane_id = chat_pane_id;
            layout.maximized_pane_id = null;
        }
        project.selected_thread_index = thread_index;
        self.terminal_controller.focused = false;
    }

    pub const providerExecutionTargetForProjectThread = chat_controller.providerExecutionTargetForProjectThread;
    pub const handleBangCommandSubmission = chat_controller.handleBangCommandSubmission;
    pub const beginBangCommand = chat_controller.beginBangCommand;
    pub const retryBangCommand = chat_controller.retryBangCommand;
    pub const sendDraft = chat_controller.sendDraft;
    pub const abortCurrentThreadSend = chat_controller.abortCurrentThreadSend;
    pub const queueOrSteerDraftDuringSend = chat_controller.queueOrSteerDraftDuringSend;
    pub const queueDraftDuringSend = chat_controller.queueDraftDuringSend;
    pub const storeDraftDuringSend = chat_controller.storeDraftDuringSend;
    pub const pendingFollowupSnapshot = chat_controller.pendingFollowupSnapshot;
    pub const pendingFollowupHint = chat_controller.pendingFollowupHint;
    pub const sendPromptViaHarness = chat_controller.sendPromptViaHarness;
    pub const interruptThreadViaHarness = chat_controller.interruptThreadViaHarness;
    pub const steerThreadViaHarness = chat_controller.steerThreadViaHarness;
    pub const beginSendForThread = chat_controller.beginSendForThread;
    pub const beginSendForThreadWithReadyDaemon = chat_controller.beginSendForThreadWithReadyDaemon;
    pub const beginSendDraft = chat_controller.beginSendDraft;
    pub const ensureSessionDaemon = chat_controller.ensureSessionDaemon;
    pub const startDaemonChatTurn = chat_controller.startDaemonChatTurn;
    pub const daemonChatTurnExists = chat_controller.daemonChatTurnExists;
    pub const cancelDaemonChatTurn = chat_controller.cancelDaemonChatTurn;
    pub const approveDaemonChatTurn = chat_controller.approveDaemonChatTurn;
    pub const consumeDaemonChatTurn = chat_controller.consumeDaemonChatTurn;
    pub const restoreDaemonChatTurnsOnLaunch = chat_controller.restoreDaemonChatTurnsOnLaunch;
    pub const threadByLocalId = chat_controller.threadByLocalId;
    pub const applyPersisted = persistence.applyPersisted;
    pub const restorePersistedSurfaceCompletions = persistence.restorePersistedSurfaceCompletions;
    pub const restorePersistedChatCompletions = persistence.restorePersistedChatCompletions;
    pub const buildPersistedState = persistence.buildPersistedState;
    pub const applyPersistedTerminalDocksJson = persistence.applyPersistedTerminalDocksJson;
    pub const seedDefaultState = persistence.seedDefaultState;
    pub const clearSurfaces = surface_controller.clearSurfaces;
    pub const surfaceBySessionId = surface_controller.surfaceBySessionId;
    pub const surfaceBySessionIdConst = surface_controller.surfaceBySessionIdConst;
    pub const updateSurface = surface_controller.updateSurface;
    pub const clearSurfaceAttentionBySession = surface_controller.clearSurfaceAttentionBySession;
    pub const clearSurfaceAttentionForDock = surface_controller.clearSurfaceAttentionForDock;
    pub const terminalDockSurfaceAttention = surface_controller.terminalDockSurfaceAttention;
    pub const isFocusedTerminalSurface = surface_controller.isFocusedTerminalSurface;
    pub const projectTerminalSurface = surface_controller.projectTerminalSurface;
    pub const replaceAppConfig = settings_controller.replaceAppConfig;
    pub const syncSettingsDraftFromConfig = settings_controller.syncSettingsDraftFromConfig;
    pub const isSettingsDraftDirty = settings_controller.isSettingsDraftDirty;
    pub const openSettingsModal = settings_controller.openSettingsModal;
    pub const toggleGlobalMcpIntegration = settings_controller.toggleGlobalMcpIntegration;
    pub const toggleClaudeGlobalHooks = settings_controller.toggleClaudeGlobalHooks;
    pub const toggleCodexGlobalHooks = settings_controller.toggleCodexGlobalHooks;
    pub const toggleCursorGlobalHooks = settings_controller.toggleCursorGlobalHooks;
    pub const toggleGrokGlobalHooks = settings_controller.toggleGrokGlobalHooks;
    pub const toggleAmpGlobalHooks = settings_controller.toggleAmpGlobalHooks;
    pub const toggleProviderGlobalHooks = settings_controller.toggleProviderGlobalHooks;
    pub const cancelSettingsModal = settings_controller.cancelSettingsModal;
    pub const saveSettingsModal = settings_controller.saveSettingsModal;
    pub const applyTerminalFontSizesFromConfig = settings_controller.applyTerminalFontSizesFromConfig;
    pub const reloadAppConfigFromDisk = settings_controller.reloadAppConfigFromDisk;
    pub const tickSettingsModalAnimation = settings_controller.tickSettingsModalAnimation;
    pub const settingsModalAnimating = settings_controller.settingsModalAnimating;
    pub const settingsThemeChoiceCount = settings_controller.settingsThemeChoiceCount;
    pub const settingsThemeChoiceLabel = settings_controller.settingsThemeChoiceLabel;
    pub const selectSettingsThemeChoice = settings_controller.selectSettingsThemeChoice;
    pub const settingsChatTitleProviderCount = settings_controller.settingsChatTitleProviderCount;
    pub const settingsChatTitleProviderSelectedIndex = settings_controller.settingsChatTitleProviderSelectedIndex;
    pub const settingsChatTitleProviderLabel = settings_controller.settingsChatTitleProviderLabel;
    pub const settingsChatTitleModelCount = settings_controller.settingsChatTitleModelCount;
    pub const settingsChatTitleModelLabel = settings_controller.settingsChatTitleModelLabel;
    pub const settingsChatTitleModelSelectedIndex = settings_controller.settingsChatTitleModelSelectedIndex;
    pub const settingsChatTitleModelSelectedLabel = settings_controller.settingsChatTitleModelSelectedLabel;
    pub const selectSettingsChatTitleProvider = settings_controller.selectSettingsChatTitleProvider;
    pub const selectSettingsChatTitleModel = settings_controller.selectSettingsChatTitleModel;
    pub const settingsChatTitleModelRef = settings_controller.settingsChatTitleModelRef;
    pub const startUpdateCheck = settings_controller.startUpdateCheck;
    pub const startAutomaticUpdateCheck = settings_controller.startAutomaticUpdateCheck;
    pub const pollUpdateCheck = settings_controller.pollUpdateCheck;
    pub const installAvailableUpdate = settings_controller.installAvailableUpdate;
    pub const updateInstallerButtonEnabled = settings_controller.updateInstallerButtonEnabled;
    pub const updateInstallerButtonLabel = settings_controller.updateInstallerButtonLabel;
    pub const pollUpdateInstallerTerminal = settings_controller.pollUpdateInstallerTerminal;
    pub const isUpdateInstallerTerminal = settings_controller.isUpdateInstallerTerminal;
    pub const consumeUpdateExitRequest = settings_controller.consumeUpdateExitRequest;
    pub const currentProjectTerminal = terminal_controller.currentProjectTerminal;
    pub const currentProjectTerminalMutable = terminal_controller.currentProjectTerminalMutable;
    pub const currentProjectTerminalDock = terminal_controller.currentProjectTerminalDock;
    pub const currentProjectTerminalDockMutable = terminal_controller.currentProjectTerminalDockMutable;
    pub const projectTerminalDock = terminal_controller.projectTerminalDock;
    pub const projectTerminalDockMutable = terminal_controller.projectTerminalDockMutable;
    pub const workspaceAgentTuiProvider = terminal_controller.workspaceAgentTuiProvider;
    pub const workspaceAgentTuiHistoryAt = terminal_controller.workspaceAgentTuiHistoryAt;
    pub const openWorkspaceAgentTuiHistory = terminal_controller.openWorkspaceAgentTuiHistory;
    pub const focusedWorkspaceTerminalDockId = terminal_controller.focusedWorkspaceTerminalDockId;
    pub const createCurrentProjectTerminalTab = terminal_controller.createCurrentProjectTerminalTab;
    pub const createProjectTerminalDock = terminal_controller.createProjectTerminalDock;
    pub const createCurrentProjectTerminalDock = terminal_controller.createCurrentProjectTerminalDock;
    pub const isTerminalVisible = terminal_controller.isTerminalVisible;
    pub const shouldRenderLegacyTerminalDockInChat = terminal_controller.shouldRenderLegacyTerminalDockInChat;
    pub const toggleCurrentProjectTerminal = terminal_controller.toggleCurrentProjectTerminal;
    pub const terminalActivityBurstActive = terminal_controller.terminalActivityBurstActive;
    pub const noteTerminalInputActivity = terminal_controller.noteTerminalInputActivity;
    pub const pollTerminals = terminal_controller.pollTerminals;
    pub const drainTerminalDockNotifications = terminal_controller.drainTerminalDockNotifications;
    pub const handleTerminalKeyDown = terminal_controller.handleTerminalKeyDown;
    pub const handleTerminalTextInput = terminal_controller.handleTerminalTextInput;
    pub const requestTerminalFocus = terminal_controller.requestTerminalFocus;
    pub const requestTerminalDockFocus = terminal_controller.requestTerminalDockFocus;
    pub const beginHandoffFromFocusedPane = handoff_controller.beginHandoffFromFocusedPane;
    pub const beginThreadHandoff = handoff_controller.beginThreadHandoff;
    pub const cancelHandoff = handoff_controller.cancelHandoff;
    pub const setHandoffTargetSurface = handoff_controller.setHandoffTargetSurface;
    pub const setHandoffTargetProvider = handoff_controller.setHandoffTargetProvider;
    pub const setHandoffUseExisting = handoff_controller.setHandoffUseExisting;
    pub const cycleHandoffExistingTarget = handoff_controller.cycleHandoffExistingTarget;
    pub const handoffExistingTargetLabel = handoff_controller.handoffExistingTargetLabel;
    pub const setHandoffContextMode = handoff_controller.setHandoffContextMode;
    pub const handoffPreviewText = handoff_controller.handoffPreviewText;
    pub const handoffTargetModelLabel = handoff_controller.handoffTargetModelLabel;
    pub const prepareHandoffTarget = handoff_controller.prepareHandoffTarget;
    pub const openCommandPalette = command_controller.openCommandPalette;
    pub const closeCommandPalette = command_controller.closeCommandPalette;
    pub const commandPaletteQuery = command_controller.commandPaletteQuery;
    pub const commandPaletteQueryBuffer = command_controller.commandPaletteQueryBuffer;
    pub const flushIfDirty = lifecycle_controller.flushIfDirty;
    pub const flushDirtyBlocking = lifecycle_controller.flushDirtyBlocking;
    pub const flushDirtyNow = lifecycle_controller.flushDirtyNow;
    pub const currentThreadMutable = transcript_controller.currentThreadMutable;
    pub const rememberCurrentTranscriptScroll = transcript_controller.rememberCurrentTranscriptScroll;
    pub const rememberWorkspaceChatTranscriptScroll = transcript_controller.rememberWorkspaceChatTranscriptScroll;
    pub const currentTranscriptScrollY = transcript_controller.currentTranscriptScrollY;
    pub const workspaceChatTranscriptScrollY = transcript_controller.workspaceChatTranscriptScrollY;
    pub const acknowledgeFocusedChatCompletion = transcript_controller.acknowledgeFocusedChatCompletion;
    pub const acknowledgeFocusedPaneCompletion = transcript_controller.acknowledgeFocusedPaneCompletion;
    pub const clearChatCompletion = transcript_controller.clearChatCompletion;
    pub const requestComposerFocus = composer_controller.requestComposerFocus;
    pub const consumePendingHerdrOpenRequest = herdr_controller.consumePendingHerdrOpenRequest;
    pub const openOrCreateHerdrWorkspace = herdr_controller.openOrCreateHerdrWorkspace;
    pub const handoffHerdrWorkspaces = herdr_controller.handoffHerdrWorkspaces;
    pub const unlinkHerdrWorkspaces = herdr_controller.unlinkHerdrWorkspaces;
    pub const handoffProjectToLocalHerdrFromUi = herdr_controller.handoffProjectToLocalHerdrFromUi;
    pub const unlinkProjectHerdrFromUi = herdr_controller.unlinkProjectHerdrFromUi;
    pub const focusProjectHerdrAttachTerminal = herdr_controller.focusProjectHerdrAttachTerminal;
    pub const restartTerminalDockForWorkspace = herdr_controller.restartTerminalDockForWorkspace;
    pub const restartTerminalDockForWorkspaceProfile = herdr_controller.restartTerminalDockForWorkspaceProfile;
    pub const createTerminalTabForWorkspaceProfile = herdr_controller.createTerminalTabForWorkspaceProfile;

    pub const currentProject = project_controller.currentProject;
    pub const currentProjectMutable = project_controller.currentProjectMutable;

    pub fn canOpenCurrentProjectDirectory(self: *const AppState) bool {
        return self.project_controller.projects.items.len > 0 and utils.canOpenProjectDirectory();
    }

    pub fn canOpenCurrentProjectEditor(self: *const AppState, target: ProjectEditorTarget) bool {
        if (self.project_controller.projects.items.len == 0) return false;
        if (target == .configured and utils.configuredEditorIsNeovim()) return true;
        return utils.canOpenProjectEditor(target);
    }

    pub fn canRunDefaultOpenAction(self: *const AppState) bool {
        if (self.project_controller.projects.items.len == 0) return false;
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
        if (self.project_controller.projects.items.len == 0) {
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

    pub fn rethemeTerminalSessions(self: *AppState) !void {
        for (self.project_controller.projects.items) |*project| {
            try project.terminal_dock.rethemeSessions(self.allocator);
            for (project.terminal_docks.items) |*entry| {
                try entry.dock.rethemeSessions(self.allocator);
            }
        }
    }

    /// Selects a workspace and reveals one of its open layout panes, leaving
    /// any maximized view.
    pub fn focusWorkspaceOpenPane(self: *AppState, project_index: usize, pane_id: WorkspacePaneId) void {
        self.focusWorkspaceOpenPaneWithZoom(project_index, pane_id, false);
    }

    /// Selects a pane from the sidebar while keeping a maximized workspace maximized.
    pub fn focusWorkspaceOpenPaneFromSidebar(self: *AppState, project_index: usize, pane_id: WorkspacePaneId) void {
        self.focusWorkspaceOpenPaneWithZoom(project_index, pane_id, true);
    }

    /// Focuses a pane by its zero-based position in the current workspace's sidebar list.
    pub fn focusCurrentProjectWorkspacePaneAtSidebarIndex(self: *AppState, pane_index: usize) bool {
        if (self.project_controller.projects.items.len == 0) return false;
        const project_index = self.project_controller.selected_index;
        const layout = &self.project_controller.projects.items[project_index].workspace_layout;
        if (pane_index >= layout.panes.items.len) return false;

        self.focusWorkspaceOpenPaneFromSidebar(project_index, layout.panes.items[pane_index].id);
        return true;
    }

    /// Cycles through the current workspace's panes in their sidebar list order.
    pub fn focusCurrentProjectWorkspacePaneInSidebarOrder(self: *AppState, delta: i32) bool {
        if (self.project_controller.projects.items.len == 0 or delta == 0) return false;
        const project_index = self.project_controller.selected_index;
        const layout = &self.project_controller.projects.items[project_index].workspace_layout;
        if (layout.panes.items.len == 0) return false;

        var current_index: ?usize = null;
        if (layout.focused_pane_id) |focused_pane_id| {
            for (layout.panes.items, 0..) |pane, index| {
                if (pane.id == focused_pane_id) {
                    current_index = index;
                    break;
                }
            }
        }

        const target_index = if (current_index) |index|
            if (delta < 0)
                if (index == 0) layout.panes.items.len - 1 else index - 1
            else if (index + 1 == layout.panes.items.len)
                0
            else
                index + 1
        else if (delta < 0)
            layout.panes.items.len - 1
        else
            0;
        return self.focusCurrentProjectWorkspacePaneAtSidebarIndex(target_index);
    }

    fn focusWorkspaceOpenPaneWithZoom(self: *AppState, project_index: usize, pane_id: WorkspacePaneId, preserve_zoom: bool) void {
        if (project_index >= self.project_controller.projects.items.len) return;
        const previous_project_index = self.project_controller.selected_index;
        if (preserve_zoom and previous_project_index < self.project_controller.projects.items.len and previous_project_index != project_index) {
            const previous_layout = &self.project_controller.projects.items[previous_project_index].workspace_layout;
            if (previous_layout.quick_pane) |*quick| quick.visible = false;
        }
        self.project_controller.selected_index = project_index;
        var project = &self.project_controller.projects.items[project_index];
        var layout = &project.workspace_layout;
        if (layout.quick_pane) |*quick| {
            if (quick.detached and quick.pane_id == pane_id) {
                quick.visible = true;
                layout.focused_pane_id = pane_id;
                self.restorePersistedBrowserPaneAfterProjectSelection(project_index);
                _ = self.focusWorkspacePane(project_index, pane_id);
                self.markDirty();
                return;
            }
            // A sidebar selection is explicit navigation away from the quick
            // pane. Minimize its overlay without destroying the pane/session,
            // and remember the selected tiled pane for the next toggle-away.
            if (preserve_zoom and quick.visible) {
                quick.visible = false;
                if (layout.rootContainsPane(pane_id)) quick.return_focus_pane_id = pane_id;
            }
        }
        const was_maximized = layout.maximized_pane_id != null;
        var target: ?*WorkspacePane = null;
        for (layout.panes.items) |*pane| {
            if (pane.id == pane_id) {
                target = pane;
                break;
            }
        }
        const pane = target orelse return;
        layout.focused_pane_id = pane_id;
        layout.maximized_pane_id = if (preserve_zoom and was_maximized) pane_id else null;
        self.restorePersistedBrowserPaneAfterProjectSelection(project_index);
        switch (pane.ref) {
            .chat, .terminal => {},
            .browser => {
                self.browser_controller.runtime.setControlsVisible(true);
                self.browser_controller.runtime.controller.show() catch |err| {
                    log.warn("failed to show browser pane from sidebar: {s}", .{@errorName(err)});
                };
            },
        }
        _ = self.focusWorkspacePane(project_index, pane_id);
        self.markDirty();
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
        if (self.project_controller.projects.items.len == 0) {
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
        if (self.project_controller.projects.items.len == 0) {
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

        if (self.project_controller.projects.items.len == 0) {
            self.setSidebarNotice("No workspace selected.");
            return;
        }

        _ = self.openBrowserInWorkspace(self.project_controller.selected_index, trimmed) catch |err| switch (err) {
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
        if (self.project_controller.projects.items.len == 0) return false;
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
        if (self.project_controller.projects.items.len == 0) return false;
        if (self.isBrowserPaneFocused() or self.browser_controller.address_focused or self.palette_modal_text_focus != .none) {
            runtime_log.diagnostic(
                "palette paste blocked browser_focused={} address_focused={} modal_focus={s}",
                .{ self.isBrowserPaneFocused(), self.browser_controller.address_focused, @tagName(self.palette_modal_text_focus) },
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
        const anchor = self.composer_controller.composer.selection_anchor orelse return 0;
        const focus = self.composer_controller.composer.selection_focus orelse return 0;
        const text_len = self.composer_controller.composer.text().len;
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
        const current_len = self.composer_controller.composer.text().len;
        const selected_len = self.paletteComposerSelectionByteLen();
        const retained_len = current_len - selected_len;
        if (retained_len >= max_len) return "";
        const available = max_len - retained_len;
        if (text.len <= available) return text;
        return text[0..utf8PrefixLen(text, available)];
    }

    fn insertTextIntoPaletteComposer(self: *AppState, text: []const u8) bool {
        if (text.len == 0) return false;
        self.composer_controller.composer.focused = true;
        self.composer_controller.focused = true;
        self.terminal_controller.focused = false;
        self.unfocusBrowserPane();
        const insert_text = self.clampPaletteComposerInsertText(text);
        if (insert_text.len == 0) {
            self.setSidebarNotice("Prompt is full");
            return true;
        }
        if (insert_text.len < text.len) self.setSidebarNotice("Pasted text was truncated to fit the prompt");
        const handled = self.composer_controller.composer.handleInput(self.allocator, .{ .text = insert_text }) catch |err| {
            log.warn("palette composer paste failed: {s}", .{@errorName(err)});
            return false;
        };
        if (handled) {
            self.syncDraftFromPaletteComposer();
            self.noteInteraction();
        }
        return handled;
    }

    pub fn clearCurrentDraftImageAt(self: *AppState, index: usize) void {
        if (self.project_controller.projects.items.len == 0) return;
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

    fn replaceThreadWithImportedSnapshot(
        self: *AppState,
        project_index: usize,
        thread_index: usize,
        imported_thread: ai_harness.ReadThreadResult,
    ) !void {
        if (project_index >= self.project_controller.projects.items.len) return error.ProjectNotFound;
        const project = &self.project_controller.projects.items[project_index];
        if (thread_index >= project.threads.items.len) return error.ThreadNotFound;

        const existing = &project.threads.items[thread_index];
        var refreshed = try self.buildImportedThread(imported_thread, existing);
        errdefer refreshed.deinit(self.allocator);

        var previous = existing.*;
        existing.* = refreshed;
        previous.deinit(self.allocator);
        self.project_controller.projects.items[project_index].invalidateSidebarThreadCache();
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

    pub fn releaseMessage(self: *AppState, message: ChatMessage) void {
        self.allocator.free(message.author);
        self.allocator.free(message.body);
        if (message.tool_call_id) |call_id| self.allocator.free(call_id);
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

    pub const closeTranscriptSelectionModal = transcript_controller.closeTranscriptSelectionModal;
    pub const transcriptSelectionBuffer = transcript_controller.transcriptSelectionBuffer;
    pub const consumeTranscriptSelectionModalRequest = transcript_controller.consumeTranscriptSelectionModalRequest;
    pub const isTranscriptFocused = transcript_controller.isTranscriptFocused;
    pub const ensureTranscriptMarkdownSelectionCurrent = transcript_controller.ensureTranscriptMarkdownSelectionCurrent;
    pub const transcriptMarkdownSelection = transcript_controller.transcriptMarkdownSelection;
    pub const transcriptMarkdownSelectionDragging = transcript_controller.transcriptMarkdownSelectionDragging;
    pub const transcriptMarkdownSelectionActive = transcript_controller.transcriptMarkdownSelectionActive;
    pub const beginTranscriptMarkdownSelection = transcript_controller.beginTranscriptMarkdownSelection;
    pub const updateTranscriptMarkdownSelection = transcript_controller.updateTranscriptMarkdownSelection;
    pub const endTranscriptMarkdownSelection = transcript_controller.endTranscriptMarkdownSelection;
    pub const notePaletteWorkspaceMouseMotion = transcript_controller.notePaletteWorkspaceMouseMotion;
    pub const selectAllTranscriptMarkdownSelection = transcript_controller.selectAllTranscriptMarkdownSelection;
    pub const clearTranscriptMarkdownSelection = transcript_controller.clearTranscriptMarkdownSelection;
    pub const transcriptMarkdownBodyView = transcript_controller.transcriptMarkdownBodyView;
    pub const cachedTranscriptMessageHeight = transcript_controller.cachedTranscriptMessageHeight;
    pub const putTranscriptMessageHeight = transcript_controller.putTranscriptMessageHeight;
    pub const ensureTranscriptMarkdownEntries = transcript_controller.ensureTranscriptMarkdownEntries;
    pub const clearTranscriptMarkdownEntries = transcript_controller.clearTranscriptMarkdownEntries;
    pub const transcriptMarkdownBodyEntry = transcript_controller.transcriptMarkdownBodyEntry;
    pub const createTranscriptMarkdownBody = transcript_controller.createTranscriptMarkdownBody;
    pub const buildCurrentTranscriptSelectionText = transcript_controller.buildCurrentTranscriptSelectionText;

    pub fn blurPaletteComposer(self: *AppState) void {
        self.composer_controller.composer.focused = false;
        self.composer_controller.composer.active_menu = null;
        self.composer_controller.composer.hovered_menu_index = null;
        self.composer_controller.focused = false;
    }

    pub fn closeSidebarContextMenu(self: *AppState) void {
        if (!self.sidebar_context_menu_open) return;
        self.sidebar_context_menu_open = false;
        self.sidebar_context_menu_kind = .none;
        self.markDirty();
    }

    fn writeClipboardImageToStorage(self: *AppState, mime: []const u8, bytes: []const u8) ![]u8 {
        return self.writeImageBytesToStorage("clipboard-images", "clipboard", extensionForImageMime(mime), bytes);
    }

    // Persists encoded image bytes under `{pref_path}/{dir_name}` with a
    // timestamped, collision-retrying file name and returns the owned path.
    pub fn writeImageBytesToStorage(
        self: *AppState,
        dir_name: []const u8,
        prefix: []const u8,
        ext: []const u8,
        bytes: []const u8,
    ) ![]u8 {
        const images_dir = try std.fs.path.join(self.allocator, &.{ self.storage.pref_path, dir_name });
        defer self.allocator.free(images_dir);
        var threaded = std.Io.Threaded.init_single_threaded;
        std.Io.Dir.createDirAbsolute(threaded.io(), images_dir, .default_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };

        const timestamp_ms = @as(u64, @intCast(@max(unixTimestampMs(), 0)));
        var attempt: usize = 0;
        while (attempt < 256) : (attempt += 1) {
            const file_name = if (attempt == 0)
                try std.fmt.allocPrint(self.allocator, "{s}-{d}.{s}", .{ prefix, timestamp_ms, ext })
            else
                try std.fmt.allocPrint(self.allocator, "{s}-{d}-{d}.{s}", .{ prefix, timestamp_ms, attempt, ext });
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

    pub fn currentDraft(self: *const AppState) []const u8 {
        return self.currentProject().currentDraft();
    }

    pub fn composerInBangCommandMode(self: *const AppState) bool {
        return self.project_controller.projects.items.len > 0 and bang_commands.isShellMode(self.currentDraft());
    }

    pub fn currentWorkspacePath(self: *const AppState) []const u8 {
        return if (self.project_controller.projects.items.len > 0) self.currentProject().path else "";
    }

    fn escapeBangCommandMode(self: *AppState) bool {
        if (!self.composerInBangCommandMode()) return false;
        const escaped = bang_commands.escapedShellDraft(self.currentDraft());
        self.setDraft(escaped);
        self.syncPaletteComposerFromDraft();
        self.composer_controller.bang_history_message_index = null;
        self.setSidebarNotice("Returned to chat mode. Draft preserved.");
        self.noteInteraction();
        return true;
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
        if (thread.provider == .codex) {
            if (self.composerReasoningIndexForThread(thread)) |index| {
                if (index < CODEX_REASONING_OPTIONS.len) return std.mem.sliceTo(CODEX_REASONING_OPTIONS[index].label, 0);
            }
        }
        // Menu-independent for the other providers: the shared reasoning menu
        // tracks the focused thread only, so unfocused pane previews must
        // label from the thread's own fields. Matches the menu rows' labels
        // for the focused thread (they are built from the same values).
        if (thread.reasoning_effort) |effort| return reasoningEffortDisplayLabel(effort);
        if (thread.opencode_reasoning_variant) |variant| {
            const raw = std.mem.sliceTo(variant, 0);
            return if (thread.provider == .cursor) cursorReasoningValueLabel(raw) else raw;
        }
        return "Default";
    }

    /// Whether the run summary carries a reasoning-level segment; keeps the
    /// summary builder and the chat panel's glyph-slot ordering in sync.
    pub fn currentComposerShowsReasoningSegment(self: *const AppState) bool {
        return self.threadReasoningGauge(self.currentThread()) != null;
    }

    /// Position/count of `thread`'s reasoning level within the same row list
    /// `refreshOpencodeReasoningMenu` would build for it (leading "Default"
    /// row included). Derived from the thread's own provider/model
    /// capabilities — NOT the shared popover menu, which only tracks the
    /// focused thread — so unfocused pane previews summarize correctly. Null
    /// when the provider/model exposes no reasoning levels.
    const ReasoningGauge = struct { index: usize, count: usize };

    fn threadReasoningGauge(self: *const AppState, thread: *const ChatThread) ?ReasoningGauge {
        switch (thread.provider) {
            .codex => return .{
                .index = composerReasoningIndexForOptions(CODEX_REASONING_OPTIONS[0..], thread.reasoning_effort) orelse 0,
                .count = CODEX_REASONING_OPTIONS.len,
            },
            .claude => {
                const opt = self.claudeModelOptionForRef(thread.model_ref) orelse return null;
                if (!opt.reasoning_supported) return null;
                const values = opt.claude_effort_values orelse CLAUDE_STANDARD_EFFORT_VALUES[0..];
                var count: usize = 1; // leading "Default" row
                var index: usize = 0;
                for (values) |value| {
                    const effort = parseReasoningEffort(value) orelse continue;
                    if (thread.reasoning_effort) |selected| {
                        if (selected == effort) index = count;
                    }
                    count += 1;
                }
                if (count <= 1) return null;
                return .{ .index = index, .count = count };
            },
            .opencode => {
                const opt = self.opencodeModelOptionForRef(thread.model_ref) orelse return null;
                if (!opt.reasoning_supported) return null;
                const keys = opt.reasoning_variant_keys orelse return null;
                if (keys.len == 0) return null;
                var index: usize = 0;
                for (keys, 0..) |key, i| {
                    if (thread.opencode_reasoning_variant) |variant| {
                        if (std.mem.eql(u8, std.mem.sliceTo(variant, 0), std.mem.sliceTo(key, 0))) index = i + 1;
                    }
                }
                return .{ .index = index, .count = keys.len + 1 };
            },
            .cursor => {
                const opt = self.cursorModelOptionForRef(thread.model_ref) orelse return null;
                const values = opt.cursor_reasoning_values orelse return null;
                if (values.len == 0) return null;
                var index: usize = 0;
                for (values, 0..) |value, i| {
                    if (thread.opencode_reasoning_variant) |variant| {
                        if (std.mem.eql(u8, std.mem.sliceTo(variant, 0), std.mem.sliceTo(value, 0))) index = i + 1;
                    }
                }
                return .{ .index = index, .count = values.len + 1 };
            },
        }
    }

    /// 0..1 gauge for the run pill's brain glyph: position of the selected
    /// reasoning level within the provider's ordered level list.
    /// (index+1)/count so the lowest level keeps a visible sliver instead of
    /// an empty silhouette; single-level (or unknown) lists read as full.
    pub fn currentComposerReasoningFillRatio(self: *const AppState) f32 {
        const gauge = self.threadReasoningGauge(self.currentThread()) orelse return 1.0;
        if (gauge.count <= 1) return 1.0;
        return @as(f32, @floatFromInt(@min(gauge.index, gauge.count - 1) + 1)) / @as(f32, @floatFromInt(gauge.count));
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
        if (self.project_controller.projects.items.len == 0) return false;
        return slashCommandPrefix(self.currentDraft()) != null;
    }

    pub fn slashCommandPickerSelectedIndex(self: *const AppState) usize {
        const count = self.slashCommandPickerRowCount();
        if (count == 0) return 0;
        return @min(self.composer_controller.slash_selected, count - 1);
    }

    pub fn slashCommandPickerRowCount(self: *const AppState) usize {
        if (self.project_controller.projects.items.len == 0) return 0;
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
        if (self.project_controller.projects.items.len == 0) return null;
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
        self.composer_controller.slash_selected = index;
        self.noteInteraction();
        self.markDirty();
        return true;
    }

    pub fn activateSlashCommandPickerSelection(self: *AppState) bool {
        const count = self.slashCommandPickerRowCount();
        if (count == 0) return false;
        const index = @min(self.composer_controller.slash_selected, count - 1);
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
            if (std.mem.eql(u8, row.name, "/handoff")) {
                self.clearDraft();
                self.syncPaletteComposerFromDraft();
                self.beginHandoffFromFocusedPane();
                self.noteInteraction();
                return true;
            }
            self.setDraft(row.name);
            self.appendSlashCommandInsertionSpace();
            self.syncPaletteComposerFromDraft();
            self.composer_controller.composer.cursor = self.composer_controller.composer.text().len;
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
        self.composer_controller.composer.cursor = self.composer_controller.composer.text().len;
        self.requestComposerFocus();
        self.noteInteraction();
        return true;
    }

    /// Runs the focused Claude or Codex thread's `/usage` command without
    /// replacing a draft the user may already be composing.
    pub fn showCurrentProviderUsage(self: *AppState) bool {
        if (self.project_controller.projects.items.len == 0) return false;
        if (self.hasPendingSlashCommand()) {
            self.setSidebarNotice("A slash command is already running.");
            return true;
        }

        const thread = self.currentThread();
        const commands = ai_harness.slashCommandsForProvider(harnessProviderForDbProvider(thread.provider));
        for (commands) |command| {
            if (command.id != .usage or command.availability != .available) continue;

            const saved_draft = self.allocator.dupe(u8, self.currentDraft()) catch {
                self.setSidebarNotice("Failed to preserve the current draft before loading usage.");
                return true;
            };
            defer self.allocator.free(saved_draft);

            self.beginProviderSlashCommand(command, "", "/usage") catch |err| {
                log.err("failed to start provider usage command: {s}", .{@errorName(err)});
                self.setSidebarNotice("Failed to load provider usage.");
                return true;
            };
            self.setDraft(saved_draft);
            self.syncPaletteComposerFromDraft();
            self.noteInteraction();
            return true;
        }

        self.setSidebarNotice("Usage details are not available for this provider.");
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
        self.composer_controller.slash_selected = 0;
        self.noteInteraction();
        return true;
    }

    pub fn clampSlashCommandPickerSelection(self: *AppState) void {
        const count = self.slashCommandPickerRowCount();
        if (count == 0) {
            self.composer_controller.slash_selected = 0;
            return;
        }
        if (self.composer_controller.slash_selected >= count) self.composer_controller.slash_selected = count - 1;
    }

    pub fn currentThread(self: *const AppState) *const ChatThread {
        return self.currentProject().currentThread();
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

    /// Returns mutable browser UI/runtime state for desktop control surfaces.
    pub fn browserState(self: *AppState) *browser_runtime.State {
        return &self.browser_controller.runtime;
    }

    /// Returns read-only browser UI/runtime state for desktop rendering.
    pub fn browserStateConst(self: *const AppState) *const browser_runtime.State {
        return &self.browser_controller.runtime;
    }

    /// Supplies the native SDL window handle that platform webviews attach under.
    pub const attachBrowserHostWindow = browser_controller.attachBrowserHostWindow;
    pub const openBrowserOnLaunchIfRequested = browser_controller.openBrowserOnLaunchIfRequested;
    pub const restorePersistedBrowserPaneOnLaunch = browser_controller.restorePersistedBrowserPaneOnLaunch;
    pub const applyInitialWorkspaceFocusOnLaunch = browser_controller.applyInitialWorkspaceFocusOnLaunch;
    pub const toggleBrowser = browser_controller.toggleBrowser;
    pub const openBrowserInWorkspace = browser_controller.openBrowserInWorkspace;
    pub const activateBrowserInWorkspace = browser_controller.activateBrowserInWorkspace;
    pub const closeBrowserInWorkspace = browser_controller.closeBrowserInWorkspace;
    pub const navigateBrowserToUrl = browser_controller.navigateBrowserToUrl;
    pub const recoverBrowser = browser_controller.recoverBrowser;
    pub const injectBrowserPointer = browser_controller.injectBrowserPointer;
    pub const browserWorkspaceLocation = browser_controller.browserWorkspaceLocation;
    pub const browserWorkspaceIndex = browser_controller.browserWorkspaceIndex;
    pub const browserWorkspacePaneId = browser_controller.browserWorkspacePaneId;
    pub const browserPaneIdInWorkspace = browser_controller.browserPaneIdInWorkspace;
    pub const browserPaneRefMutable = browser_controller.browserPaneRefMutable;
    pub const visibleBrowserPaneRefMutable = browser_controller.visibleBrowserPaneRefMutable;
    pub const browserPaneSnapshotUrl = browser_controller.browserPaneSnapshotUrl;
    pub const restorePersistedBrowserPaneAfterProjectSelection = browser_controller.restorePersistedBrowserPaneAfterProjectSelection;
    pub const applyBrowserPaneSnapshotToRuntime = browser_controller.applyBrowserPaneSnapshotToRuntime;
    pub const recordVisibleBrowserPaneNavigation = browser_controller.recordVisibleBrowserPaneNavigation;
    pub const recordVisibleBrowserPaneTitle = browser_controller.recordVisibleBrowserPaneTitle;
    pub const setActiveBrowserTabLoadState = browser_controller.setActiveBrowserTabLoadState;
    pub const navigatePersistedBrowserHistory = browser_controller.navigatePersistedBrowserHistory;
    pub const restartBrowserRuntimeForCrossOriginNavigation = browser_controller.restartBrowserRuntimeForCrossOriginNavigation;
    pub const showBrowserRuntimeForLiveOpen = browser_controller.showBrowserRuntimeForLiveOpen;
    pub const restoreWorkspaceFocusIfVisible = browser_controller.restoreWorkspaceFocusIfVisible;
    pub const workspacePaneKind = browser_controller.workspacePaneKind;
    pub const blurNativeBrowserForAddressField = browser_controller.blurNativeBrowserForAddressField;
    pub const deactivateBrowserRuntime = browser_controller.deactivateBrowserRuntime;
    pub const closeBrowser = browser_controller.closeBrowser;
    pub const suspendBrowserForHostWindowHidden = browser_controller.suspendBrowserForHostWindowHidden;
    pub const resumeBrowserAfterHostWindowShown = browser_controller.resumeBrowserAfterHostWindowShown;
    pub const isBrowserVisible = browser_controller.isBrowserVisible;
    pub const isBrowserRuntimeActive = browser_controller.isBrowserRuntimeActive;
    pub const isBrowserRuntimeActiveInWorkspace = browser_controller.isBrowserRuntimeActiveInWorkspace;
    pub const canUseBrowserInspector = browser_controller.canUseBrowserInspector;
    pub const browserBridgePolicyAllowsCurrentPage = browser_controller.browserBridgePolicyAllowsCurrentPage;
    pub const browserInspectorPolicyAllowsCurrentPage = browser_controller.browserInspectorPolicyAllowsCurrentPage;
    pub const browserBridgePolicyAllowsUntrustedPages = browser_controller.browserBridgePolicyAllowsUntrustedPages;
    pub const isBrowserInspectorEnabled = browser_controller.isBrowserInspectorEnabled;
    pub const browserInspectorMode = browser_controller.browserInspectorMode;
    pub const isBrowserInspectorMenuOpen = browser_controller.isBrowserInspectorMenuOpen;
    pub const isBrowserSurfaceSuspendedForPaletteOverlay = browser_controller.isBrowserSurfaceSuspendedForPaletteOverlay;
    pub const isBrowserSurfaceSuspendedForLayout = browser_controller.isBrowserSurfaceSuspendedForLayout;
    pub const isBrowserSurfaceSuspendedForEmptyState = browser_controller.isBrowserSurfaceSuspendedForEmptyState;
    pub const isWorkspaceHeaderOpenMenuOpen = browser_controller.isWorkspaceHeaderOpenMenuOpen;
    pub const isProjectImportModalOpen = browser_controller.isProjectImportModalOpen;
    pub const isThreadImportModalOpen = browser_controller.isThreadImportModalOpen;
    pub const isImageModalOpen = browser_controller.isImageModalOpen;
    pub const isTranscriptSelectionModalOpen = browser_controller.isTranscriptSelectionModalOpen;
    pub const paletteModalTextFocusName = browser_controller.paletteModalTextFocusName;
    pub const isSidebarContextMenuOpen = browser_controller.isSidebarContextMenuOpen;
    pub const isComposerMenuOpen = browser_controller.isComposerMenuOpen;
    pub const setBrowserInspectorMenuOpen = browser_controller.setBrowserInspectorMenuOpen;
    pub const setWorkspaceHeaderOpenMenuOpen = browser_controller.setWorkspaceHeaderOpenMenuOpen;
    pub const setSidebarContextMenuOpen = browser_controller.setSidebarContextMenuOpen;
    pub const setComposerMenuOpen = browser_controller.setComposerMenuOpen;
    pub const setProjectImportModalOpen = browser_controller.setProjectImportModalOpen;
    pub const setThreadImportModalOpen = browser_controller.setThreadImportModalOpen;
    pub const setImageModalOpen = browser_controller.setImageModalOpen;
    pub const setTranscriptSelectionModalOpen = browser_controller.setTranscriptSelectionModalOpen;
    pub const browserPanelHeight = browser_controller.browserPanelHeight;
    pub const browserPanelWidth = browser_controller.browserPanelWidth;
    pub const noteBrowserPaneRegion = browser_controller.noteBrowserPaneRegion;
    pub const noteBrowserEmptyStateRendered = browser_controller.noteBrowserEmptyStateRendered;
    pub const noteBrowserPaneNotRendered = browser_controller.noteBrowserPaneNotRendered;
    pub const noteAppWindowFrame = browser_controller.noteAppWindowFrame;
    pub const browserPaneDeviceScale = browser_controller.browserPaneDeviceScale;
    pub const browserPaneInputSize = browser_controller.browserPaneInputSize;
    pub const syncBrowserPaneBoundsToBackend = browser_controller.syncBrowserPaneBoundsToBackend;
    pub const restoreBrowserSurfaceForRenderedLayout = browser_controller.restoreBrowserSurfaceForRenderedLayout;
    pub const syncBrowserSurfaceOcclusion = browser_controller.syncBrowserSurfaceOcclusion;
    pub const browserBlockedByPaletteOverlay = browser_controller.browserBlockedByPaletteOverlay;
    pub const suppressNextBrowserClosedEvent = browser_controller.suppressNextBrowserClosedEvent;
    pub const consumeSuppressedBrowserClosedEvent = browser_controller.consumeSuppressedBrowserClosedEvent;
    pub const unfocusBrowserPane = browser_controller.unfocusBrowserPane;
    pub const focusBrowserPane = browser_controller.focusBrowserPane;
    pub const isBrowserPaneFocused = browser_controller.isBrowserPaneFocused;
    pub const isNativeBrowserSurfaceFocused = browser_controller.isNativeBrowserSurfaceFocused;
    pub const browserPaneUsesNativeKeyboardSurface = browser_controller.browserPaneUsesNativeKeyboardSurface;
    pub const browserPaneContains = browser_controller.browserPaneContains;
    pub const browserCursorShapeAtPoint = browser_controller.browserCursorShapeAtPoint;
    pub const nativeBrowserOwnsCursor = browser_controller.nativeBrowserOwnsCursor;
    pub const handleBrowserMouse = browser_controller.handleBrowserMouse;
    pub const handleBrowserKey = browser_controller.handleBrowserKey;
    pub const clearBrowserContextMenuLocal = browser_controller.clearBrowserContextMenuLocal;
    pub const dismissBrowserContextMenu = browser_controller.dismissBrowserContextMenu;
    pub const activateBrowserContextMenuItem = browser_controller.activateBrowserContextMenuItem;
    pub const appendBrowserContextMenuPayloadItems = browser_controller.appendBrowserContextMenuPayloadItems;
    pub const openBrowserContextMenuFromPayload = browser_controller.openBrowserContextMenuFromPayload;
    pub const browserContextMenuHasLink = browser_controller.browserContextMenuHasLink;
    pub const openBrowserContextLink = browser_controller.openBrowserContextLink;
    pub const reopenBrowserWindow = browser_controller.reopenBrowserWindow;
    pub const navigateBrowserFromAddress = browser_controller.navigateBrowserFromAddress;
    pub const captureBrowserScreenshot = browser_controller.captureBrowserScreenshot;
    pub const setupBrowserDevServer = browser_controller.setupBrowserDevServer;
    pub const navigateOrReloadBrowserFromAddress = browser_controller.navigateOrReloadBrowserFromAddress;
    pub const evalBrowserScript = browser_controller.evalBrowserScript;
    pub const postBrowserJsonFromInput = browser_controller.postBrowserJsonFromInput;
    pub const toggleBrowserInspector = browser_controller.toggleBrowserInspector;
    pub const setBrowserInspectorMode = browser_controller.setBrowserInspectorMode;
    pub const pollBrowser = browser_controller.pollBrowser;
    pub const noteBrowserFramePresented = browser_controller.noteBrowserFramePresented;
    pub const pollPendingBrowserDevServer = browser_controller.pollPendingBrowserDevServer;
    pub const clearPendingBrowserDevServer = browser_controller.clearPendingBrowserDevServer;
    pub const localDevServerUrl = browser_controller.localDevServerUrl;
    pub const isLoopbackAuthority = browser_controller.isLoopbackAuthority;
    pub const normalizeBrowserUrl = browser_controller.normalizeBrowserUrl;
    pub const hasUriScheme = browser_controller.hasUriScheme;
    pub const isBlankBrowserUrl = browser_controller.isBlankBrowserUrl;
    pub const runBrowserStartupEvalIfRequested = browser_controller.runBrowserStartupEvalIfRequested;
    pub const inspectorModeStoredNotice = browser_controller.inspectorModeStoredNotice;
    pub const inspectorModeSwitchedNotice = browser_controller.inspectorModeSwitchedNotice;
    pub const isBrowserClipboardMessage = browser_controller.isBrowserClipboardMessage;
    pub const handleBrowserClipboardMessage = browser_controller.handleBrowserClipboardMessage;
    pub const handleInspectorPromptSubmitted = browser_controller.handleInspectorPromptSubmitted;
    pub const threadHasPendingFollowup = browser_controller.threadHasPendingFollowup;
    pub const queueInspectorPromptAsFollowup = browser_controller.queueInspectorPromptAsFollowup;
    pub const fillInspectorPromptIntoTui = browser_controller.fillInspectorPromptIntoTui;
    pub const fallbackInspectorPromptToDraft = browser_controller.fallbackInspectorPromptToDraft;
    pub const captureInspectorSelectionImage = browser_controller.captureInspectorSelectionImage;
    pub const applyInspectorPromptTarget = browser_controller.applyInspectorPromptTarget;
    pub const pushInspectorPromptTargets = browser_controller.pushInspectorPromptTargets;
    pub const notifyInspectorPromptResult = browser_controller.notifyInspectorPromptResult;
    pub const buildInspectorContextBlock = browser_controller.buildInspectorContextBlock;
    pub const appendInspectorElementSummary = browser_controller.appendInspectorElementSummary;
    pub const enableBrowserInspector = browser_controller.enableBrowserInspector;
    pub const applyBrowserInspector = browser_controller.applyBrowserInspector;
    pub const inspectorThemeJsonAlloc = browser_controller.inspectorThemeJsonAlloc;
    pub const cssHexFromColor = browser_controller.cssHexFromColor;
    pub const disableBrowserInspector = browser_controller.disableBrowserInspector;
    pub const reapplyBrowserInspectorAfterLoad = browser_controller.reapplyBrowserInspectorAfterLoad;
    pub const isInspectorBridgeMessage = browser_controller.isInspectorBridgeMessage;
    pub const isInspectorHoverMessage = browser_controller.isInspectorHoverMessage;
    pub const isInspectorLifecycleMessage = browser_controller.isInspectorLifecycleMessage;
    pub const isInspectorDisabledMessage = browser_controller.isInspectorDisabledMessage;
    pub const isInspectorSelectionMessage = browser_controller.isInspectorSelectionMessage;
    pub const isInspectorPromptSubmittedMessage = browser_controller.isInspectorPromptSubmittedMessage;
    pub const isInspectorPromptChangedMessage = browser_controller.isInspectorPromptChangedMessage;
    pub const navigateBrowserHistory = browser_controller.navigateBrowserHistory;
    pub const browserTabCount = browser_controller.browserTabCount;
    pub const activeBrowserTabIndex = browser_controller.activeBrowserTabIndex;
    pub const browserTabTitle = browser_controller.browserTabTitle;
    pub const browserTabPinned = browser_controller.browserTabPinned;
    pub const browserTabIndicator = browser_controller.browserTabIndicator;
    pub const browserCanGoBack = browser_controller.browserCanGoBack;
    pub const browserCanGoForward = browser_controller.browserCanGoForward;
    pub const createBrowserTab = browser_controller.createBrowserTab;
    pub const duplicateBrowserTab = browser_controller.duplicateBrowserTab;
    pub const toggleBrowserTabPinned = browser_controller.toggleBrowserTabPinned;
    pub const moveBrowserTab = browser_controller.moveBrowserTab;
    pub const switchBrowserTab = browser_controller.switchBrowserTab;
    pub const closeBrowserTab = browser_controller.closeBrowserTab;
    pub const activateBrowserTabRuntime = browser_controller.activateBrowserTabRuntime;
    pub const reloadBrowser = browser_controller.reloadBrowser;
    pub const openCurrentBrowserUrlExternally = browser_controller.openCurrentBrowserUrlExternally;
    pub const selectAllBrowserFocusedElement = browser_controller.selectAllBrowserFocusedElement;
    pub const pasteBrowserTextIntoFocusedElement = browser_controller.pasteBrowserTextIntoFocusedElement;
    pub const copyBrowserFocusedSelection = browser_controller.copyBrowserFocusedSelection;
    pub const copyBrowserEvalResultToClipboard = browser_controller.copyBrowserEvalResultToClipboard;

    pub const ensureCurrentProjectWorkspace = workspace_controller.ensureCurrentProjectWorkspace;
    pub const focusedWorkspacePaneKind = workspace_controller.focusedWorkspacePaneKind;
    pub const focusedWorkspaceChatPaneId = workspace_controller.focusedWorkspaceChatPaneId;
    pub const currentProjectHasVisibleWorkspaceTerminalPane = workspace_controller.currentProjectHasVisibleWorkspaceTerminalPane;
    pub const currentProjectVisibleBrowserPaneId = workspace_controller.currentProjectVisibleBrowserPaneId;
    pub const threadIsOpenInTui = workspace_controller.threadIsOpenInTui;
    pub const currentProjectWorkspaceRoot = workspace_controller.currentProjectWorkspaceRoot;
    pub const currentProjectWorkspaceMaximizedPaneId = workspace_controller.currentProjectWorkspaceMaximizedPaneId;
    pub const currentProjectQuickPane = workspace_controller.currentProjectQuickPane;
    pub const floatFocusedWorkspacePane = workspace_controller.floatFocusedWorkspacePane;
    pub const toggleCurrentProjectQuickPane = workspace_controller.toggleCurrentProjectQuickPane;
    pub const createFloatingQuickTerminal = workspace_controller.createFloatingQuickTerminal;
    pub const restoreFocusBehindQuickPane = workspace_controller.restoreFocusBehindQuickPane;
    pub const minimizeCurrentProjectQuickPane = workspace_controller.minimizeCurrentProjectQuickPane;
    pub const toggleCurrentProjectQuickPaneMaximized = workspace_controller.toggleCurrentProjectQuickPaneMaximized;
    pub const toggleCurrentProjectQuickPanePinned = workspace_controller.toggleCurrentProjectQuickPanePinned;
    pub const returnCurrentProjectQuickPaneToTile = workspace_controller.returnCurrentProjectQuickPaneToTile;
    pub const setCurrentProjectQuickPaneGeometry = workspace_controller.setCurrentProjectQuickPaneGeometry;
    pub const workspacePaneKindById = workspace_controller.workspacePaneKindById;
    pub const workspaceTerminalDockIdByPane = workspace_controller.workspaceTerminalDockIdByPane;
    pub const workspaceChatThreadIndexByPane = workspace_controller.workspaceChatThreadIndexByPane;
    pub const captureViewFocusSnapshot = workspace_controller.captureViewFocusSnapshot;
    pub const restoreViewFocusSnapshot = workspace_controller.restoreViewFocusSnapshot;
    pub const setWorkspaceChatPaneDraftForProject = workspace_controller.setWorkspaceChatPaneDraftForProject;
    pub const setWorkspaceChatPaneDraft = workspace_controller.setWorkspaceChatPaneDraft;
    pub const sendWorkspaceChatPanePromptForProject = workspace_controller.sendWorkspaceChatPanePromptForProject;
    pub const sendWorkspaceChatPanePrompt = workspace_controller.sendWorkspaceChatPanePrompt;
    pub const followupWorkspaceChatPanePromptForProject = workspace_controller.followupWorkspaceChatPanePromptForProject;
    pub const followupWorkspaceChatPanePrompt = workspace_controller.followupWorkspaceChatPanePrompt;
    pub const stopWorkspaceChatPaneForProject = workspace_controller.stopWorkspaceChatPaneForProject;
    pub const stopWorkspaceChatPane = workspace_controller.stopWorkspaceChatPane;
    pub const approveWorkspaceChatPaneForProject = workspace_controller.approveWorkspaceChatPaneForProject;
    pub const approveWorkspaceChatPane = workspace_controller.approveWorkspaceChatPane;
    pub const writeWorkspaceTerminalPaneForProject = workspace_controller.writeWorkspaceTerminalPaneForProject;
    pub const writeWorkspaceTerminalPane = workspace_controller.writeWorkspaceTerminalPane;
    pub const writeWorkspaceTerminalKeyForProject = workspace_controller.writeWorkspaceTerminalKeyForProject;
    pub const pasteWorkspaceTerminalPaneForProject = workspace_controller.pasteWorkspaceTerminalPaneForProject;
    pub const terminalPaneOutputTailForProject = workspace_controller.terminalPaneOutputTailForProject;
    pub const terminalPaneOutputTail = workspace_controller.terminalPaneOutputTail;
    pub const terminalPaneScreenTextForProject = workspace_controller.terminalPaneScreenTextForProject;
    pub const pollTerminalDockBeforeRead = workspace_controller.pollTerminalDockBeforeRead;
    pub const pollWorkspaceTerminalProcessLifecycles = workspace_controller.pollWorkspaceTerminalProcessLifecycles;
    pub const pollPendingTerminalSessionTeardowns = workspace_controller.pollPendingTerminalSessionTeardowns;
    pub const syncTerminalDockProcessLifecycle = workspace_controller.syncTerminalDockProcessLifecycle;
    pub const finishTerminalSessionsForTeardown = workspace_controller.finishTerminalSessionsForTeardown;
    pub const terminalPaneScreenText = workspace_controller.terminalPaneScreenText;
    pub const pruneExpiredWorkspaceLeases = workspace_controller.pruneExpiredWorkspaceLeases;
    pub const acquireWorkspaceLease = workspace_controller.acquireWorkspaceLease;
    pub const releaseWorkspaceLease = workspace_controller.releaseWorkspaceLease;
    pub const releaseWorkspaceLeasesForTerminalOwner = workspace_controller.releaseWorkspaceLeasesForTerminalOwner;
    pub const activeWorkspaceLeaseCount = workspace_controller.activeWorkspaceLeaseCount;

    pub fn refreshProjectStackConfig(self: *AppState, project_index: usize) !void {
        if (project_index >= self.project_controller.projects.items.len) return;
        var project = &self.project_controller.projects.items[project_index];
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
        if (project_index >= self.project_controller.projects.items.len) return;
        const project = &self.project_controller.projects.items[project_index];
        for (project.managed_processes.items) |*process| {
            const dock_id = process.dock_id orelse continue;
            const dock = self.projectTerminalDock(project_index, dock_id) orelse {
                finalizeExplicitManagedProcessStop(process);
                continue;
            };
            const snapshot = dock.activeSessionSnapshot() orelse {
                finalizeExplicitManagedProcessStop(process);
                continue;
            };
            if (process.explicit_stop) {
                if (snapshot.running) {
                    process.status = .stopping;
                    continue;
                }
                process.exit_code = snapshot.exit_code;
                process.signal = snapshot.signal;
                finalizeExplicitManagedProcessStop(process);
                continue;
            }
            if (snapshot.running) {
                process.status = .running;
                process.exit_code = null;
                process.signal = null;
                continue;
            }
            process.exit_code = snapshot.exit_code;
            process.signal = snapshot.signal;
            if (process.last_exit_ms == 0) process.last_exit_ms = unixTimestampMs();
            const clean_exit = snapshot.exit_code != null and snapshot.exit_code.? == 0;
            process.status = if (clean_exit) .stopped else .crashed;
        }
    }

    fn finalizeExplicitManagedProcessStop(process: *ManagedProcess) void {
        if (!process.explicit_stop) return;
        process.status = .stopped;
        if (process.last_exit_ms == 0) process.last_exit_ms = unixTimestampMs();
    }

    pub fn pollManagedProcesses(self: *AppState, project_index: usize) void {
        if (project_index >= self.project_controller.projects.items.len) return;
        const now = unixTimestampMs();
        if (now - self.project_controller.projects.items[project_index].last_stack_config_refresh_ms >= STACK_CONFIG_REFRESH_MS) {
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

        for (self.project_controller.projects.items[project_index].managed_processes.items) |*process| {
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
            if (self.project_controller.projects.items[project_index].managedProcessByName(name)) |process| {
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
        if (project_index >= self.project_controller.projects.items.len) return false;
        self.project_controller.selected_index = project_index;
        var project = &self.project_controller.projects.items[project_index];
        const process = project.managedProcessByName(name) orelse return false;
        return try self.startManagedProcessDirect(project_index, process);
    }

    fn startManagedProcessDirect(self: *AppState, project_index: usize, process: *ManagedProcess) !bool {
        if (project_index >= self.project_controller.projects.items.len) return false;
        self.project_controller.selected_index = project_index;
        var project = &self.project_controller.projects.items[project_index];
        const dock_id = if (process.dock_id) |saved_dock_id|
            if (project.terminalDockEntryById(saved_dock_id) != null)
                saved_dock_id
            else stale: {
                process.dock_id = null;
                process.pane_id = null;
                break :stale try self.createProjectTerminalDock(project_index);
            }
        else
            try self.createProjectTerminalDock(project_index);
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
        const terminal_pane_open = project.workspace_layout.visibleTerminalPaneIdForDock(dock_id) != null;
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
        if (terminal_pane_open) {
            project.workspace_layout.maximized_pane_id = null;
        } else {
            project.workspace_layout.focusCreatedPane(process.pane_id.?);
        }
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
        if (project_index >= self.project_controller.projects.items.len) return false;
        self.project_controller.selected_index = project_index;
        self.ensureCurrentProjectWorkspace();

        var project = &self.project_controller.projects.items[project_index];
        var layout = &project.workspace_layout;
        const target_pane_id = requested_pane_id orelse layout.focused_pane_id orelse layout.firstVisiblePaneId() orelse {
            self.setSidebarNotice("No workspace pane selected.");
            return false;
        };
        _ = layout.paneById(target_pane_id) orelse return false;
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
        project = &self.project_controller.projects.items[project_index];
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
        if (process.provider) |provider| {
            _ = dock.setActiveTabPinnedProvider(self.allocator, @tagName(provider));
        }
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
        layout.focusCreatedPane(new_pane_id);
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
            // Hooks add status reporting but are not required to run Cursor.
            // Keep automatic TUI launch fail-open for malformed user config;
            // explicit Settings/CLI installation still reports the error.
            .cursor => provider_hooks.ensureCursorProjectHooks(self.allocator, project_path) catch |err| {
                log.warn("could not install Cursor project status hooks: {s}", .{@errorName(err)});
            },
            // Grok project hooks require an explicit folder-trust grant. Its
            // personal hook is guarded by Verde pane environment variables,
            // so it remains inert in every other terminal.
            .grok => provider_hooks.ensureGrokGlobalHooks(self.allocator) catch |err| {
                log.warn("could not install Grok personal status hooks: {s}", .{@errorName(err)});
            },
            .opencode, .amp, .other => {},
        }
    }

    pub fn openAgentTui(self: *AppState, project_index: usize, provider: stack_config.AgentProvider) !bool {
        return self.openAgentTuiAtPlacement(project_index, provider, null, .horizontal, true);
    }

    pub fn grokTuiInstalled() bool {
        // Provider probing must stay side-effect free: resolving PATH is enough
        // to drive the setup state without starting Grok or touching auth.
        return process_env.commandExists("grok");
    }

    pub fn openGrokSetupGuide(self: *AppState) void {
        utils.openUrlInDefaultBrowser(self.allocator, "https://docs.x.ai/build/overview#install") catch |err| {
            log.warn("failed to open Grok Build setup guide: {s}", .{@errorName(err)});
            self.setSidebarNotice("Could not open the Grok Build setup guide.");
            return;
        };
        self.setSidebarNotice("Opened the Grok Build setup guide.");
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
        if (provider == .grok and !grokTuiInstalled()) {
            self.setSidebarNotice("Grok Build is not installed. Run “Set Up Grok Build” from the command palette.");
            return false;
        }
        const defaults = defaultAgentTui(provider) orelse return false;
        if (project_index >= self.project_controller.projects.items.len) return false;
        self.project_controller.selected_index = project_index;
        var project = &self.project_controller.projects.items[project_index];
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
        if (project_index >= self.project_controller.projects.items.len) return false;
        self.project_controller.selected_index = project_index;
        self.ensureCurrentProjectWorkspace();

        var project = &self.project_controller.projects.items[project_index];
        var layout = &project.workspace_layout;
        const target_pane_id = requested_pane_id orelse layout.focused_pane_id orelse layout.firstVisiblePaneId() orelse {
            self.setSidebarNotice("No workspace pane selected.");
            return false;
        };
        _ = layout.paneById(target_pane_id) orelse return false;

        const dock_id = self.createProjectTerminalDock(project_index) catch |err| {
            log.err("failed to allocate Amp terminal dock: {s}", .{@errorName(err)});
            self.setSidebarNotice("Failed to create Amp TUI terminal.");
            return false;
        };
        project = &self.project_controller.projects.items[project_index];
        self.restartTerminalDockForWorkspace(project_index, dock_id) catch |err| {
            log.err("failed to start Amp terminal dock: {s}", .{@errorName(err)});
            self.setSidebarNotice("Failed to start Amp TUI terminal.");
            return false;
        };
        var dock = self.projectTerminalDockMutable(project_index, dock_id) orelse return false;
        _ = dock.setActiveTabPinnedProvider(self.allocator, @tagName(stack_config.AgentProvider.amp));

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
        layout.focusCreatedPane(new_pane_id);
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

    fn providerFromStack(provider: ?stack_config.AgentProvider) ?SurfaceProvider {
        return switch (provider orelse return null) {
            .codex => .codex,
            .claude => .claude,
            .opencode => .opencode,
            .cursor => .cursor,
            .grok => .grok,
            .amp => .amp,
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
                !argvContainsCodexHooksFeature(process.argv.items);
            for (process.argv.items, 0..) |arg, index| {
                try appendOwnedString(self.allocator, &launch.argv, arg);
                if (index == 0 and add_codex_hooks) {
                    try appendOwnedString(self.allocator, &launch.argv, "-c");
                    try appendOwnedString(self.allocator, &launch.argv, "features.hooks=true");
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

    fn argvContainsCodexHooksFeature(argv: []const []const u8) bool {
        for (argv) |arg| {
            if (containsCodexHooksFeature(arg)) return true;
        }
        return false;
    }

    fn containsCodexHooksFeature(text: []const u8) bool {
        return std.mem.indexOf(u8, text, "features.hooks") != null or
            std.mem.indexOf(u8, text, "features.codex_hooks") != null;
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
        if (containsCodexHooksFeature(process.command)) {
            return self.allocator.dupe(u8, process.command);
        }

        const trimmed = std.mem.trim(u8, process.command, " \t\r\n");
        if (std.mem.eql(u8, trimmed, "codex")) {
            return self.allocator.dupe(u8, "codex -c features.hooks=true");
        }
        if (std.mem.startsWith(u8, trimmed, "codex ")) {
            return try std.fmt.allocPrint(self.allocator, "codex -c features.hooks=true {s}", .{trimmed["codex ".len..]});
        }
        return self.allocator.dupe(u8, process.command);
    }

    pub fn stopManagedProcess(self: *AppState, project_index: usize, name: []const u8) !bool {
        try self.refreshProjectStackConfig(project_index);
        if (project_index >= self.project_controller.projects.items.len) return false;
        var project = &self.project_controller.projects.items[project_index];
        var process = project.managedProcessByName(name) orelse return false;
        process.explicit_stop = true;
        process.status = .stopping;
        process.last_exit_ms = 0;
        process.next_restart_ms = 0;
        process.pending_watch_restart_ms = 0;
        if (process.dock_id) |dock_id| {
            if (self.projectTerminalDockMutable(project_index, dock_id)) |dock| {
                _ = dock.terminateActiveSession();
            }
        }
        self.refreshManagedProcessStatuses(project_index);
        self.markDirty();
        return true;
    }

    pub fn restartManagedProcess(self: *AppState, project_index: usize, name: []const u8) !bool {
        try self.refreshProjectStackConfig(project_index);
        if (project_index >= self.project_controller.projects.items.len) return false;
        if (self.project_controller.projects.items[project_index].managedProcessByName(name)) |process| {
            process.restart_count += 1;
            process.status = .restarting;
        }
        _ = try self.stopManagedProcess(project_index, name);
        return try self.startManagedProcess(project_index, name);
    }

    pub fn startProjectStack(self: *AppState, project_index: usize) !usize {
        try self.refreshProjectStackConfig(project_index);
        if (project_index >= self.project_controller.projects.items.len) return 0;
        var started: usize = 0;
        var names: std.ArrayList([]u8) = .empty;
        defer {
            for (names.items) |name| self.allocator.free(name);
            names.deinit(self.allocator);
        }
        for (self.project_controller.projects.items[project_index].managed_processes.items) |process| {
            try names.append(self.allocator, try self.allocator.dupe(u8, process.name));
        }
        for (names.items) |name| {
            if (try self.startManagedProcess(project_index, name)) started += 1;
        }
        return started;
    }

    pub fn stopProjectStack(self: *AppState, project_index: usize) !usize {
        try self.refreshProjectStackConfig(project_index);
        if (project_index >= self.project_controller.projects.items.len) return 0;
        var stopped: usize = 0;
        var names: std.ArrayList([]u8) = .empty;
        defer {
            for (names.items) |name| self.allocator.free(name);
            names.deinit(self.allocator);
        }
        for (self.project_controller.projects.items[project_index].managed_processes.items) |process| {
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
        if (project_index >= self.project_controller.projects.items.len) return null;
        const project = &self.project_controller.projects.items[project_index];
        const process = project.managedProcessByName(name) orelse return null;
        const dock_id = process.dock_id orelse return null;
        const dock = self.projectTerminalDock(project_index, dock_id) orelse return null;
        return try dock.activeOutputTailAlloc(self.allocator, max_bytes);
    }

    pub fn managedProcessByNameConst(self: *AppState, project_index: usize, name: []const u8) !?*ManagedProcess {
        try self.refreshProjectStackConfig(project_index);
        if (project_index >= self.project_controller.projects.items.len) return null;
        return self.project_controller.projects.items[project_index].managedProcessByName(name);
    }

    pub fn focusManagedProcessTerminal(self: *AppState, project_index: usize, name: []const u8) !bool {
        try self.refreshProjectStackConfig(project_index);
        if (project_index >= self.project_controller.projects.items.len) return false;
        self.project_controller.selected_index = project_index;
        const process = self.project_controller.projects.items[project_index].managedProcessByName(name) orelse return false;
        if (process.pane_id) |pane_id| {
            _ = self.focusCurrentProjectWorkspacePane(pane_id);
            if (process.dock_id) |dock_id| self.requestTerminalDockFocus(dock_id);
            return true;
        }
        if (process.dock_id) |dock_id| {
            process.pane_id = try self.project_controller.projects.items[project_index].workspace_layout.ensureTerminalPane(self.allocator, dock_id);
            self.project_controller.projects.items[project_index].workspace_layout.focusCreatedPane(process.pane_id.?);
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
        if (std.mem.eql(u8, root, "/handoff")) {
            if (parts.next() != null) {
                self.setSidebarNotice("Usage: /handoff");
                return true;
            }
            self.clearDraft();
            self.syncPaletteComposerFromDraft();
            self.beginHandoffFromFocusedPane();
            return true;
        }
        if (!std.mem.eql(u8, root, "/stack") and !std.mem.eql(u8, root, "/process")) return false;
        const action = parts.next() orelse {
            self.setSidebarNotice(if (std.mem.eql(u8, root, "/stack")) "Usage: /stack start|stop|restart|status" else "Usage: /process start|stop|restart|focus|crashed <name>");
            return true;
        };
        const project_index = self.project_controller.selected_index;
        if (std.mem.eql(u8, root, "/stack")) {
            if (std.mem.eql(u8, action, "status")) {
                self.refreshProjectStackConfig(project_index) catch |err| {
                    self.setSidebarNotice(@errorName(err));
                    return true;
                };
                self.refreshManagedProcessStatuses(project_index);
                const count: usize = self.project_controller.projects.items[project_index].managed_processes.items.len;
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
            for (self.project_controller.projects.items[project_index].managed_processes.items) |process| {
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
                    "Unknown slash command: {s}. Try /handoff, /stack, /process, or a command supported by this provider.",
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
        const project_index = self.project_controller.selected_index;
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
        const project = &self.project_controller.projects.items[project_index];
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

    pub const selectWorkspaceChatPaneThread = workspace_controller.selectWorkspaceChatPaneThread;
    pub const isCurrentProjectWorkspacePaneFocused = workspace_controller.isCurrentProjectWorkspacePaneFocused;
    pub const isCurrentProjectWorkspacePaneMaximized = workspace_controller.isCurrentProjectWorkspacePaneMaximized;
    pub const focusWorkspacePane = workspace_controller.focusWorkspacePane;
    pub const focusCurrentProjectWorkspacePane = workspace_controller.focusCurrentProjectWorkspacePane;
    pub const focusPromptForFocusedChatWorkspacePane = workspace_controller.focusPromptForFocusedChatWorkspacePane;
    pub const swapCurrentProjectWorkspacePanes = workspace_controller.swapCurrentProjectWorkspacePanes;
    pub const moveWorkspacePaneInDirection = workspace_controller.moveWorkspacePaneInDirection;
    pub const moveCurrentProjectWorkspacePaneToPlacement = workspace_controller.moveCurrentProjectWorkspacePaneToPlacement;
    pub const toggleCurrentProjectWorkspacePaneMaximized = workspace_controller.toggleCurrentProjectWorkspacePaneMaximized;
    pub const toggleWorkspacePaneMaximized = workspace_controller.toggleWorkspacePaneMaximized;
    pub const maximizeWorkspacePane = workspace_controller.maximizeWorkspacePane;
    pub const clearCurrentProjectWorkspacePaneMaximized = workspace_controller.clearCurrentProjectWorkspacePaneMaximized;
    pub const clearWorkspacePaneMaximized = workspace_controller.clearWorkspacePaneMaximized;
    pub const closeCurrentProjectWorkspacePane = workspace_controller.closeCurrentProjectWorkspacePane;
    pub const closeWorkspacePane = workspace_controller.closeWorkspacePane;
    pub const clearHerdrClosedPaneMetadata = workspace_controller.clearHerdrClosedPaneMetadata;
    pub const closeFocusedWorkspacePane = workspace_controller.closeFocusedWorkspacePane;
    pub const splitCurrentProjectWorkspacePaneWithChat = workspace_controller.splitCurrentProjectWorkspacePaneWithChat;
    pub const splitFocusedWorkspacePaneWithChatAxis = workspace_controller.splitFocusedWorkspacePaneWithChatAxis;
    pub const splitCurrentProjectWorkspacePaneWithChatAxis = workspace_controller.splitCurrentProjectWorkspacePaneWithChatAxis;
    pub const splitCurrentProjectWorkspacePaneWithChatPlacement = workspace_controller.splitCurrentProjectWorkspacePaneWithChatPlacement;
    pub const splitWorkspacePaneWithChatAxis = workspace_controller.splitWorkspacePaneWithChatAxis;
    pub const openWorkspaceChat = workspace_controller.openWorkspaceChat;
    pub const resolveChatCreationSettings = workspace_controller.resolveChatCreationSettings;
    pub const modelOptionForProvider = workspace_controller.modelOptionForProvider;
    pub const codexSupportsReasoningEffort = workspace_controller.codexSupportsReasoningEffort;
    pub const providerSupportsModel = workspace_controller.providerSupportsModel;
    pub const splitWorkspacePaneWithChatPlacement = workspace_controller.splitWorkspacePaneWithChatPlacement;
    pub const createWorkspaceChatPane = workspace_controller.createWorkspaceChatPane;
    pub const splitCurrentProjectWorkspacePaneWithThread = workspace_controller.splitCurrentProjectWorkspacePaneWithThread;
    pub const splitCurrentProjectWorkspacePaneWithTerminal = workspace_controller.splitCurrentProjectWorkspacePaneWithTerminal;
    pub const splitFocusedWorkspacePaneWithTerminalAxis = workspace_controller.splitFocusedWorkspacePaneWithTerminalAxis;
    pub const splitFocusedWorkspacePaneWithTerminalPlacement = workspace_controller.splitFocusedWorkspacePaneWithTerminalPlacement;
    pub const openTerminalPaneForProjectIndex = workspace_controller.openTerminalPaneForProjectIndex;
    pub const openCurrentProjectTerminalPaneForCommand = workspace_controller.openCurrentProjectTerminalPaneForCommand;
    pub const openThreadInTui = workspace_controller.openThreadInTui;
    pub const openThreadInChat = workspace_controller.openThreadInChat;
    pub const tuiResumeCommand = workspace_controller.tuiResumeCommand;
    pub const splitCurrentProjectWorkspacePaneWithTerminalAxis = workspace_controller.splitCurrentProjectWorkspacePaneWithTerminalAxis;
    pub const splitCurrentProjectWorkspacePaneWithTerminalPlacement = workspace_controller.splitCurrentProjectWorkspacePaneWithTerminalPlacement;
    pub const splitWorkspacePaneWithTerminalAxis = workspace_controller.splitWorkspacePaneWithTerminalAxis;
    pub const splitWorkspacePaneWithTerminalPlacement = workspace_controller.splitWorkspacePaneWithTerminalPlacement;
    pub const toggleFocusedWorkspacePaneMaximized = workspace_controller.toggleFocusedWorkspacePaneMaximized;
    pub const resizeCurrentProjectWorkspaceSplit = workspace_controller.resizeCurrentProjectWorkspaceSplit;
    pub const resizeWorkspaceSplit = workspace_controller.resizeWorkspaceSplit;
    pub const nudgeCurrentProjectWorkspaceSplit = workspace_controller.nudgeCurrentProjectWorkspaceSplit;
    pub const focusCurrentProjectWorkspaceTerminalPane = workspace_controller.focusCurrentProjectWorkspaceTerminalPane;
    pub const focusCurrentProjectWorkspaceTerminalDock = workspace_controller.focusCurrentProjectWorkspaceTerminalDock;
    pub const currentProjectWorkspaceVisiblePaneCount = workspace_controller.currentProjectWorkspaceVisiblePaneCount;
    pub const currentProjectGridNewPanePlacement = workspace_controller.currentProjectGridNewPanePlacement;

    pub fn resetUiDebugFrame(self: *AppState) void {
        self.terminal_controller.debug_window_focused = false;
        self.terminal_controller.debug_hitbox_focused = false;
        self.terminal_controller.debug_hitbox_active = false;
        self.terminal_controller.debug_hitbox_clicked = false;
        self.terminal_controller.debug_focus_requested = false;
        self.browser_controller.pane_hovered = false;
        self.transcript_controller.focused = false;
        self.terminal_controller.debug_workspace_visible_pane_count = 0;
    }

    pub fn noteTerminalKeyRouting(self: *AppState, event: *const sdl.KeyboardEvent, handled: bool) void {
        self.terminal_controller.debug_last_scancode = event.scancode;
        self.terminal_controller.debug_last_key_handled = handled;
    }

    pub fn noteTerminalTextRouting(self: *AppState, text: []const u8, handled: bool) void {
        self.terminal_controller.debug_last_text_handled = handled;
        @memset(&self.terminal_controller.debug_last_text, 0);
        const len = @min(text.len, self.terminal_controller.debug_last_text.len - 1);
        @memcpy(self.terminal_controller.debug_last_text[0..len], text[0..len]);
    }

    pub fn draftBuffer(self: *AppState) [:0]u8 {
        return self.currentProjectMutable().draftBuffer();
    }

    pub fn syncPaletteComposerFromDraft(self: *AppState) void {
        if (self.project_controller.projects.items.len == 0) return;
        const draft = self.currentDraft();
        if (std.mem.eql(u8, self.composer_controller.composer.text(), draft)) return;
        const callbacks = self.composer_controller.composer.callbacks;
        self.composer_controller.composer.setCallbacks(.{});
        defer self.composer_controller.composer.setCallbacks(callbacks);
        self.composer_controller.composer.setText(self.allocator, draft) catch |err| {
            log.warn("failed to sync palette composer draft: {s}", .{@errorName(err)});
        };
    }

    pub fn syncDraftFromPaletteComposer(self: *AppState) void {
        if (self.project_controller.projects.items.len == 0) return;
        const text = self.composer_controller.composer.text();
        if (std.mem.eql(u8, self.currentDraft(), text)) return;
        self.setDraft(text);
    }

    pub fn setPaletteComposerBounds(self: *AppState, input_min: [2]f32, input_max: [2]f32) void {
        self.setComposerInputBounds(input_min, input_max);
        self.composer_controller.composer.setBounds(.{
            .x = input_min[0],
            .y = input_min[1],
            .w = @max(input_max[0] - input_min[0], 0.0),
            .h = @max(input_max[1] - input_min[1], 0.0),
        });
    }

    /// Cleared at the start of each workspace paint; see `syncComposerToolbarOverlayHitRects`.
    pub fn invalidateComposerToolbarOverlayHitRects(self: *AppState) void {
        self.composer_controller.toolbar_overlay_valid = false;
    }

    /// Hit targets for `routePaletteComposerToolbarOverlayClick` (cascade on new threads, synthetic
    /// toolbar clicks when the overlay batch sits above the composer's own hit testing).
    pub fn syncComposerToolbarOverlayHitRects(self: *AppState) void {
        self.composer_controller.toolbar_model_rect = self.composer_controller.composer.modelRect();
        self.composer_controller.toolbar_reasoning_rect = self.composer_controller.composer.reasoningRect();
        self.composer_controller.toolbar_fast_rect = self.composer_controller.composer.fastRect();
        self.composer_controller.toolbar_access_rect = self.composer_controller.composer.accessRect();
        self.composer_controller.toolbar_overlay_valid = true;
    }

    pub fn syncPaletteComposerControls(self: *AppState) void {
        if (self.project_controller.projects.items.len == 0) return;
        self.composer_controller.composer.setCallbacks(.{ .context = self, .on_event = paletteComposerPromptEvent, .get_clipboard = paletteComposerGetClipboard });
        self.composer_controller.composer.setStyle(paletteComposerStyle());
        // Composer font sizes are CSS units in the comptime config but the
        // runtime metrics need to be the actual pixel size, otherwise the
        // placeholder + selectors render at fixed pixel sizes while everything
        // else in the UI scales with the display — looks tiny on HiDPI.
        // Geometry must scale with the same factor as the font metrics below,
        // otherwise pills keep CSS-sized padding/icon cells while their labels
        // and the host-drawn glyphs grow — icons end up on top of the text on
        // HiDPI displays (and worst in narrow split panes).
        self.composer_controller.composer.setUiScale(theme.uiScaleFactor());
        self.composer_controller.composer.setFontMetrics(paletteComposerTextFontMetrics(theme.scaledUi(PALETTE_COMPOSER_FONT_SIZE)));
        self.composer_controller.composer.setToolbarFontMetrics(paletteEstimatedFontMetrics(theme.scaledUi(PALETTE_COMPOSER_TOOLBAR_FONT_SIZE)));
        self.composer_controller.composer.setIconFontMetrics(paletteEstimatedFontMetrics(theme.scaledUi(PALETTE_COMPOSER_ICON_FONT_SIZE)));
        const thread = self.currentThread();
        // Model + run pills open host popovers (rich picker / run-config
        // panel); fast and access moved into the run-config popover, so their
        // dedicated pills stay hidden.
        self.composer_controller.composer.setExternalModelMenu(true);
        self.composer_controller.composer.setExternalReasoningMenu(true);
        self.composer_controller.composer.setShowFastToggle(false);
        self.composer_controller.composer.setShowAccessToggle(false);
        const hide_placeholder = thread.draftImageCount() > 0;
        const placeholder = if (self.composerInBangCommandMode())
            "Enter a shell command..."
        else if (!hide_placeholder)
            "Ask anything, or use / to show available commands"
        else
            " ";
        self.composer_controller.composer.setPlaceholder(self.allocator, placeholder) catch |err| {
            log.warn("failed to sync palette composer placeholder: {s}", .{@errorName(err)});
        };
        const model_options = composerModelOptions(self, thread.provider);
        self.composer_controller.composer.setModelOptions(self, model_options.len, paletteModelLabel);
        self.refreshOpencodeReasoningMenu(thread) catch |err| {
            log.warn("failed to refresh OpenCode reasoning menu: {s}", .{@errorName(err)});
            self.clearOpencodeReasoningMenu();
        };
        // The run pill (former reasoning pill) is always visible: it anchors
        // the run-config popover and summarizes reasoning / speed / access.
        // Its option list stays un-synced on purpose — the built-in dropdown
        // is disabled via setExternalReasoningMenu and the run-config steppers
        // own the reasoning data instead.
        self.composer_controller.composer.setShowReasoningToggle(true);
        self.composer_controller.composer.model_index = self.composerModelIndex(thread.provider, thread.model_ref);
        const send_pending = thread.isSendPendingForUi();
        self.composer_controller.composer.setSendState(if (send_pending) .stop else .send);
        self.composer_controller.composer.setStopPulseFactor(if (send_pending) theme.activityPulse(profiler.nowNs()) else 1.0);
        if (self.composer_controller.composer.model_index) |index| {
            if (index < model_options.len) {
                self.composer_controller.composer.setModelLabel(self.allocator, std.mem.sliceTo(model_options[index].label, 0)) catch |err| {
                    log.warn("failed to sync palette composer model label: {s}", .{@errorName(err)});
                };
            }
        }
        // Sized for a worst-case dynamic reasoning-variant label plus both
        // fixed segments; overflow degrades to a truncated summary.
        var summary_buf: [192]u8 = undefined;
        const run_summary = self.composerRunSummaryParts(&summary_buf);
        self.composer_controller.composer.setReasoningLabel(self.allocator, run_summary.text) catch |err| {
            log.warn("failed to sync palette composer run summary label: {s}", .{@errorName(err)});
        };
        // Host-drawn state glyphs sit inside the run pill label after the
        // word each one describes — brain after the reasoning segment,
        // bolt/circle after speed, lock after access (drawn in
        // chat_panel.renderComposerToolbarIcons).
        var run_slots: [3]palette.ComposerPromptIconSlot = undefined;
        var run_slot_count: usize = 0;
        if (run_summary.reasoning_offset) |offset| {
            run_slots[run_slot_count] = .{ .byte_offset = offset, .width = COMPOSER_RUN_PILL_ICON_CELL };
            run_slot_count += 1;
        }
        if (run_summary.fast_offset) |offset| {
            run_slots[run_slot_count] = .{ .byte_offset = offset, .width = COMPOSER_RUN_PILL_ICON_CELL };
            run_slot_count += 1;
        }
        run_slots[run_slot_count] = .{ .byte_offset = run_summary.access_offset, .width = COMPOSER_RUN_PILL_ICON_CELL };
        run_slot_count += 1;
        self.composer_controller.composer.setReasoningIconSlots(run_slots[0..run_slot_count]);
        if (self.composer_controller.run_config_open) self.syncRunConfigSteppers();
    }

    /// Run-config summary text plus the byte offsets of the speed and access
    /// segments, so `syncPaletteComposerControls` can pin each host-drawn state
    /// glyph beside the word it describes on the run pill. Offsets point at the
    /// end of each segment: the glyph trails its word so it cannot read as
    /// belonging to the preceding segment (e.g. the bolt hugging "High ·").
    pub const ComposerRunSummary = struct {
        text: []const u8,
        /// End of the reasoning segment; null when the provider has no
        /// reasoning levels.
        reasoning_offset: ?usize = null,
        /// End of the speed segment; null when the provider has no speed tier.
        fast_offset: ?usize = null,
        /// End of the access segment (always present in the summary).
        access_offset: usize = 0,
    };

    /// Compact " · "-joined summary of the run settings (reasoning, speed,
    /// access) shown on the composer run pill and the inactive preview pill.
    pub fn composerRunSummaryParts(self: *const AppState, buf: []u8) ComposerRunSummary {
        var writer: std.Io.Writer = .fixed(buf);
        var result: ComposerRunSummary = .{ .text = "" };
        var wrote_any = false;
        if (self.currentComposerShowsReasoningSegment()) {
            writer.writeAll(self.currentComposerReasoningLabel()) catch {};
            result.reasoning_offset = writer.buffered().len;
            wrote_any = true;
        }
        if (self.currentComposerShowsFastToggle()) {
            if (wrote_any) writer.writeAll(" · ") catch {};
            writer.writeAll(self.currentComposerFastLabel()) catch {};
            result.fast_offset = writer.buffered().len;
            wrote_any = true;
        }
        if (wrote_any) writer.writeAll(" · ") catch {};
        writer.writeAll(self.currentComposerAccessLabel()) catch {};
        result.access_offset = writer.buffered().len;
        result.text = writer.buffered();
        return result;
    }

    pub fn syncPaletteModelPicker(self: *AppState) void {
        self.composer_controller.model_picker.setCallbacks(.{
            .context = self,
            .on_event = paletteModelPickerEvent,
            // Ctrl+V pastes into the embedded search field while open.
            .get_clipboard = paletteComposerGetClipboard,
        });
        self.composer_controller.model_picker.setStyle(paletteModelPickerStyle());
        self.composer_controller.model_picker.setUiScale(theme.uiScaleFactor());
        self.composer_controller.model_picker.setFontMetrics(paletteEstimatedFontMetrics(theme.scaledUi(15.5)));
        self.rebuildModelPickerEntries() catch |err| {
            log.warn("failed to rebuild model picker entries: {s}", .{@errorName(err)});
        };
        self.composer_controller.model_picker.setItemCount(self.composer_controller.model_picker_entries.items.len);
        self.composer_controller.model_picker.setSelectedItem(self.currentModelPickerSelection());
        self.setPaletteModelPickerBoundsFromToolbar();
    }

    fn appendModelPickerEntries(self: *AppState, provider: Provider) !void {
        const options = composerModelOptions(self, provider);
        for (options, 0..) |_, option_index| {
            try self.composer_controller.model_picker_entries.append(self.allocator, .{ .provider = provider, .option_index = option_index });
        }
    }

    fn rebuildModelPickerEntries(self: *AppState) !void {
        const previous = try self.allocator.dupe(ModelPickerEntry, self.composer_controller.model_picker_entries.items);
        defer self.allocator.free(previous);
        self.composer_controller.model_picker_entries.clearRetainingCapacity();
        if (self.currentThreadAllowsProviderChoice()) {
            for (COMPOSER_PROVIDER_OPTIONS) |candidate| try self.appendModelPickerEntries(candidate);
        } else {
            try self.appendModelPickerEntries(self.currentThread().provider);
        }
        // The rebuilt slice is the change signal: comparing it against the
        // previous entries catches provider switches, async option refreshes,
        // and reorders without a separate fingerprint to keep in sync.
        var changed = previous.len != self.composer_controller.model_picker_entries.items.len;
        if (!changed) {
            for (previous, self.composer_controller.model_picker_entries.items) |old, new| {
                if (old.provider != new.provider or old.option_index != new.option_index) {
                    changed = true;
                    break;
                }
            }
        }
        if (changed) self.composer_controller.model_picker.invalidateItems();
    }

    /// Funnels every model-picker input through one catch-log path so mouse,
    /// keyboard, and text routing stay behaviorally identical.
    fn modelPickerInput(self: *AppState, input: palette.RichPickerInput) bool {
        const handled = self.composer_controller.model_picker.handleInput(self.allocator, input) catch |err| blk: {
            log.warn("model picker input failed: {s}", .{@errorName(err)});
            break :blk false;
        };
        if (handled) self.noteInteraction();
        return handled;
    }

    fn currentModelPickerSelection(self: *const AppState) ?usize {
        const thread = self.currentThread();
        const option_index = self.composerModelIndex(thread.provider, thread.model_ref) orelse return null;
        for (self.composer_controller.model_picker_entries.items, 0..) |entry, index| {
            if (entry.provider == thread.provider and entry.option_index == option_index) return index;
        }
        return null;
    }

    pub fn setPaletteModelPickerBoundsFromToolbar(self: *AppState) void {
        const anchor = self.composer_controller.toolbar_model_rect;
        if (anchor.w <= 0.0 or anchor.h <= 0.0) return;
        const picker_width = (COMPOSER_MODEL_PICKER_WIDTH + COMPOSER_MODEL_PICKER_RAIL_WIDTH) * theme.uiScaleFactor();
        const min_x = if (self.composer_controller.input_bounds_valid) self.composer_controller.input_min[0] else anchor.x;
        const max_x = if (self.composer_controller.input_bounds_valid) self.composer_controller.input_max[0] else anchor.x + picker_width;
        const viewport_top: f32 = theme.scaledUi(8.0);
        const viewport_bottom = if (self.composer_controller.input_bounds_valid)
            self.composer_controller.input_max[1]
        else
            anchor.y + anchor.h;
        self.composer_controller.model_picker.setAnchorRect(anchor);
        self.composer_controller.model_picker.setViewportRect(.{
            .x = min_x,
            .y = viewport_top,
            .w = @max(max_x - min_x, picker_width),
            .h = @max(viewport_bottom - viewport_top, theme.scaledUi(120.0)),
        });
    }

    pub fn openPaletteModelPicker(self: *AppState) void {
        if (self.project_controller.projects.items.len == 0) return;
        self.composer_controller.popover_restore_focus = false;
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
        self.composer_controller.composer.active_menu = null;
        self.composer_controller.composer.hovered_menu_index = null;
        self.syncPaletteModelPicker();
        _ = self.composer_controller.model_picker.handleInput(self.allocator, .open) catch |err| blk: {
            log.warn("failed to open model picker: {s}", .{@errorName(err)});
            break :blk false;
        };
        self.composer_controller.composer.focused = false;
        self.composer_controller.focused = false;
        // The popover owns typing (search) and arrows while open.
        self.terminal_controller.focused = false;
        self.noteInteraction();
    }

    pub fn closePaletteModelPicker(self: *AppState) void {
        self.composer_controller.popover_restore_focus = false;
        if (!self.composer_controller.model_picker.isOpen()) return;
        _ = self.composer_controller.model_picker.handleInput(self.allocator, .close) catch |err| blk: {
            log.warn("failed to close model picker: {s}", .{@errorName(err)});
            break :blk false;
        };
    }

    pub fn togglePaletteModelPickerFromShortcut(self: *AppState) void {
        const restore_focus = self.composer_controller.popover_restore_focus or
            self.composer_controller.composer.focused or self.composer_controller.focused;
        if (self.composer_controller.model_picker.isOpen()) {
            self.closePaletteModelPicker();
            if (restore_focus) self.requestComposerFocus();
            self.noteInteraction();
            return;
        }
        self.openPaletteModelPicker();
        if (self.composer_controller.model_picker.isOpen()) {
            self.composer_controller.popover_restore_focus = restore_focus;
        }
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
        for (&self.composer_controller.run_steppers, 0..) |*stepper, index| {
            self.composer_controller.run_stepper_contexts[index] = .{ .state = self, .kind = @enumFromInt(@as(u8, @intCast(index))) };
            stepper.setCallbacks(.{ .context = &self.composer_controller.run_stepper_contexts[index], .on_event = paletteRunStepperEvent });
            stepper.setStyle(style);
            stepper.setUiScale(theme.uiScaleFactor());
            stepper.setFontMetrics(paletteEstimatedFontMetrics(theme.scaledUi(13.0)));
        }
        const reasoning = &self.composer_controller.run_steppers[@intFromEnum(RunConfigRowKind.reasoning)];
        reasoning.setStepCount(if (thread.provider == .codex) CODEX_REASONING_OPTIONS.len else self.opencode_reasoning_menu.items.len);
        reasoning.setSelected(composerReasoningIndexForThread(self, thread));
        const speed = &self.composer_controller.run_steppers[@intFromEnum(RunConfigRowKind.speed)];
        speed.setStepCount(RUN_SPEED_STEP_LABELS.len);
        speed.setSelected(if (thread.fast_mode == .on) 1 else 0);
        const access = &self.composer_controller.run_steppers[@intFromEnum(RunConfigRowKind.access)];
        access.setStepCount(RUN_ACCESS_STEP_LABELS.len);
        access.setSelected(if (thread.access_mode == .full_access) 1 else 0);
    }

    /// True when the mouse rests on a clickable Palette control so the main
    /// loop can show a pointer (hand) cursor.
    pub fn pointerCursorWanted(self: *const AppState) bool {
        const point: palette.draw.Vec2 = .{ .x = self.transcript_controller.palette_mouse_x, .y = self.transcript_controller.palette_mouse_y };
        for (self.palette_modal_hits.items) |hit| {
            const interactive = switch (hit.action) {
                .mcp_onboarding_not_now,
                .mcp_onboarding_enable,
                .provider_onboarding_close,
                .provider_onboarding_recheck,
                .provider_onboarding_open_guide,
                .image_close,
                .project_rename_cancel,
                .project_rename_submit,
                .transcript_close,
                .thread_import_refresh,
                .thread_import_cancel,
                .thread_import_submit,
                .thread_import_select,
                .herdr_profile_refresh,
                .herdr_profile_cancel,
                .herdr_profile_submit,
                .herdr_profile_select,
                .handoff_cancel,
                .handoff_prepare,
                .handoff_surface_gui,
                .handoff_surface_tui,
                .handoff_provider_codex,
                .handoff_provider_opencode,
                .handoff_provider_claude,
                .handoff_provider_cursor,
                .handoff_context_summary,
                .handoff_context_recent,
                .handoff_context_full,
                .handoff_target_new,
                .handoff_target_existing,
                .handoff_target_next,
                .project_import_browse,
                .project_import_submit,
                .project_import_create_dir,
                .project_import_cancel,
                .settings_control,
                .settings_theme_option,
                .settings_title_provider_option,
                .settings_title_model_option,
                .settings_close,
                .settings_cancel,
                .settings_save,
                .command_palette_row,
                .command_palette_action_row,
                => true,
                .modal_dismiss,
                .modal_block,
                .project_rename_input,
                .thread_import_input,
                .project_import_input,
                .command_palette_input,
                => false,
            };
            if (interactive and hit.rect.contains(point)) return true;
        }
        if (self.palette_modal_hits.items.len > 0) return false;
        if (self.project_controller.projects.items.len == 0) return false;
        if (self.composer_controller.model_picker.wantsPointerAt(point)) return true;
        if (!self.settings_controller.modal_visible) {
            for (self.card_toggle_hits.items) |hit| {
                if (hit.rect.contains(point)) return true;
            }
            for (self.code_copy_buttons.items) |hit| {
                if (hit.rect.contains(point)) return true;
            }
        }
        if (self.composer_controller.run_config_open) {
            var kinds: [3]RunConfigRowKind = undefined;
            const count = self.runConfigVisibleRows(&kinds);
            var index: usize = 0;
            while (index < count) : (index += 1) {
                if (self.composer_controller.run_steppers[@intFromEnum(kinds[index])].wantsPointerAt(point)) return true;
            }
        }
        // The overlay-valid flag guarantees the composer toolbar was laid
        // out this frame, so its hit rects are trustworthy.
        if (self.composer_controller.toolbar_overlay_valid and self.composer_controller.composer.hitTest(point) != null) return true;
        return false;
    }

    /// Advances the run-config stepper thumb animations from monotonic
    /// time; called once per rendered frame while the popover is open.
    pub fn tickRunConfigSteppers(self: *AppState) void {
        const now = monotonicMs();
        defer self.composer_controller.run_config_last_tick_ms = now;
        if (self.composer_controller.run_config_last_tick_ms == 0 or now <= self.composer_controller.run_config_last_tick_ms) return;
        // Clamp so a long gap between frames (popover just reopened, app
        // stalled) advances the slide instead of teleporting past it.
        const elapsed: u32 = @intCast(@min(now - self.composer_controller.run_config_last_tick_ms, 100));
        for (&self.composer_controller.run_steppers) |*stepper| stepper.tick(elapsed);
    }

    /// True while a stepper thumb is mid-slide; keeps the main loop pumping
    /// frames for the ~160ms animation window.
    pub fn runConfigStepperAnimating(self: *const AppState) bool {
        if (!self.composer_controller.run_config_open) return false;
        for (&self.composer_controller.run_steppers) |*stepper| {
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
        const anchor = self.composer_controller.toolbar_reasoning_rect;
        const composer = self.composer_controller.composer.bounds();
        const pad = theme.scaledUi(14.0);
        const title_h = theme.scaledUi(16.0);
        const title_gap = theme.scaledUi(6.0);
        const row_gap = theme.scaledUi(14.0);
        const width = theme.clampf(composer.w * 0.5, theme.scaledUi(330.0), theme.scaledUi(440.0));

        var height = pad * 2.0;
        var index: usize = 0;
        while (index < layout.row_count) : (index += 1) {
            height += title_h + title_gap + self.composer_controller.run_steppers[@intFromEnum(layout.row_kinds[index])].requiredHeight();
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
            const stepper = &self.composer_controller.run_steppers[@intFromEnum(layout.row_kinds[index])];
            layout.title_rects[index] = .{ .x = x + pad, .y = cursor_y, .w = @max(width - pad * 2.0, 0.0), .h = title_h };
            cursor_y += title_h + title_gap;
            stepper.setBounds(.{ .x = x + pad, .y = cursor_y, .w = @max(width - pad * 2.0, 0.0), .h = stepper.requiredHeight() });
            cursor_y += stepper.requiredHeight() + row_gap;
        }
        return layout;
    }

    pub fn openRunConfigPopover(self: *AppState) void {
        if (self.project_controller.projects.items.len == 0) return;
        self.composer_controller.popover_restore_focus = false;
        self.closePaletteModelPicker();
        self.composer_controller.composer.active_menu = null;
        self.composer_controller.composer.hovered_menu_index = null;
        self.syncRunConfigSteppers();
        self.composer_controller.run_config_open = true;
        self.composer_controller.run_config_focused_row = 0;
        _ = self.layoutRunConfigPopover();
        self.composer_controller.composer.focused = false;
        self.composer_controller.focused = false;
        // Arrow keys steer the popover's steppers while it is open.
        self.terminal_controller.focused = false;
        self.noteInteraction();
    }

    pub fn closeRunConfigPopover(self: *AppState) void {
        self.composer_controller.popover_restore_focus = false;
        self.composer_controller.run_config_open = false;
    }

    pub fn toggleRunConfigPopover(self: *AppState) void {
        if (self.composer_controller.run_config_open) {
            self.closeRunConfigPopover();
        } else {
            self.openRunConfigPopover();
        }
    }

    pub fn toggleRunConfigPopoverFromShortcut(self: *AppState) void {
        const restore_focus = self.composer_controller.popover_restore_focus or
            self.composer_controller.composer.focused or self.composer_controller.focused;
        if (self.composer_controller.run_config_open) {
            self.closeRunConfigPopover();
            if (restore_focus) self.requestComposerFocus();
            self.noteInteraction();
            return;
        }
        self.openRunConfigPopover();
        if (self.composer_controller.run_config_open) self.composer_controller.popover_restore_focus = restore_focus;
    }

    fn closeRunConfigPopoverFromKeyboard(self: *AppState) void {
        const restore_focus = self.composer_controller.popover_restore_focus;
        self.closeRunConfigPopover();
        if (restore_focus) self.requestComposerFocus();
    }

    fn restoreComposerAfterShortcutPopover(self: *AppState) void {
        const restore_focus = self.composer_controller.popover_restore_focus;
        self.composer_controller.popover_restore_focus = false;
        if (restore_focus) self.requestComposerFocus();
    }

    pub fn routePaletteComposerTextInput(self: *AppState, text: []const u8) bool {
        if (self.project_controller.projects.items.len == 0) return false;
        if (self.composer_controller.model_picker.isOpen()) {
            const handled = self.composer_controller.model_picker.handleInput(self.allocator, .{ .text = text }) catch |err| blk: {
                log.warn("model picker text input failed: {s}", .{@errorName(err)});
                break :blk false;
            };
            if (handled) self.noteInteraction();
            return handled;
        }
        if (self.terminal_controller.focused) return false;
        if (!self.composer_controller.composer.focused) return false;
        const insert_text = self.clampPaletteComposerInsertText(text);
        if (insert_text.len == 0) return true;
        const handled = self.composer_controller.composer.handleInput(self.allocator, .{ .text = insert_text }) catch |err| {
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
        if (self.project_controller.projects.items.len == 0) return false;
        // Escape never survives `paletteComposerKeyFromSdl`, so close the
        // composer popovers from the raw SDL event before the conversion.
        if (event.key == .escape or event.scancode == .escape) {
            if (self.composer_controller.model_picker.isOpen()) {
                return self.routePaletteModelPickerKey(.{ .code = .escape });
            }
            if (self.composer_controller.run_config_open) {
                self.closeRunConfigPopoverFromKeyboard();
                self.noteInteraction();
                return true;
            }
            if (self.escapeBangCommandMode()) return true;
        }
        if (self.terminal_controller.focused) return false;
        // Ctrl+1..9 selects the picker's shortcut-chip rows. Digits never
        // survive `paletteComposerKeyFromSdl`, so read the raw SDL key.
        if (self.composer_controller.model_picker.isOpen()) {
            const key_value = @intFromEnum(event.key);
            const ctrl_held = (keymodBits(event.mod) & sdl.Keymod.ctrl) != 0;
            if (ctrl_held and key_value >= '1' and key_value <= '9') {
                const handled = self.composer_controller.model_picker.selectVisibleOrdinal(self.allocator, @intCast(key_value - '1')) catch |err| blk: {
                    log.warn("model picker shortcut select failed: {s}", .{@errorName(err)});
                    break :blk false;
                };
                if (handled) self.noteInteraction();
                return true;
            }
        }
        const palette_key = paletteComposerKeyFromSdl(event) orelse return false;
        if (self.composer_controller.model_picker.isOpen()) {
            // The picker owns typing while open: navigation keys move the
            // highlight, everything else edits the embedded search field.
            return self.routePaletteModelPickerKey(palette_key);
        }
        if (self.routeRunConfigKey(palette_key)) return true;
        if (palette_key.primary and palette_key.code == .v) {
            runtime_log.diagnostic(
                "palette composer received primary-v focused={} draft_len={d}",
                .{ self.composer_controller.composer.focused, self.currentDraft().len },
            );
            return self.pasteClipboardTextIntoPaletteComposer();
        }
        if (!self.composer_controller.composer.focused) return false;
        if (self.routeSlashCommandPickerKey(palette_key)) return true;
        if (self.recallBangCommand(palette_key)) {
            self.noteInteraction();
            return true;
        }
        if (self.handlePaletteComposerNavigationKey(palette_key)) {
            self.noteInteraction();
            return true;
        }
        const handled = self.composer_controller.composer.handleInput(self.allocator, .{ .key = palette_key }) catch |err| {
            log.warn("palette composer key input failed: {s}", .{@errorName(err)});
            return false;
        };
        if (handled) {
            self.syncDraftFromPaletteComposer();
            self.noteInteraction();
        }
        return handled;
    }

    fn recallBangCommand(self: *AppState, key: palette.Key) bool {
        if (key.primary or key.shift or key.alt) return false;
        if (key.code != .up and key.code != .down) return false;
        const draft = self.currentDraft();
        if (draft.len > 0 and draft[0] != '!') return false;
        const messages = self.currentThread().messages.items;
        if (key.code == .up) {
            var index = self.composer_controller.bang_history_message_index orelse messages.len;
            while (index > 0) {
                index -= 1;
                const body = messages[index].body;
                if (messages[index].role != .user or body.len < 2 or body[0] != '!' or body[1] == '!') continue;
                self.setDraft(body);
                self.syncPaletteComposerFromDraft();
                self.composer_controller.bang_history_message_index = index;
                return true;
            }
            return false;
        }

        var index = (self.composer_controller.bang_history_message_index orelse return false) + 1;
        while (index < messages.len) : (index += 1) {
            const body = messages[index].body;
            if (messages[index].role != .user or body.len < 2 or body[0] != '!' or body[1] == '!') continue;
            self.setDraft(body);
            self.syncPaletteComposerFromDraft();
            self.composer_controller.bang_history_message_index = index;
            return true;
        }
        self.composer_controller.bang_history_message_index = null;
        self.clearDraft();
        self.syncPaletteComposerFromDraft();
        return true;
    }

    pub fn routePaletteComposerMouseButton(self: *AppState, event: *const sdl.MouseButtonEvent, ui_scale: f32) bool {
        if (self.project_controller.projects.items.len == 0) return false;
        if (event.button != 1) return false;
        const point = paletteMousePoint(event.x, event.y, ui_scale);
        if (event.down and event.clicks >= 2 and self.composer_controller.composer.textRect().contains(point)) {
            return self.routePaletteComposerMultiClick(point, event.clicks);
        }
        if (event.down and self.routePaletteComposerToolbarOverlayClick(point)) return true;
        const input: palette.ComposerPromptInput = if (event.down)
            .{ .mouse_down = point }
        else
            .{ .mouse_up = point };
        const was_focused = self.composer_controller.composer.focused;
        const handled = self.composer_controller.composer.handleInput(self.allocator, input) catch |err| {
            log.warn("palette composer mouse input failed: {s}", .{@errorName(err)});
            return false;
        };
        self.composer_controller.focused = self.composer_controller.composer.focused;
        if (self.composer_controller.focused) {
            self.terminal_controller.focused = false;
            self.unfocusBrowserPane();
        }
        return handled or was_focused != self.composer_controller.composer.focused;
    }

    fn routePaletteComposerToolbarOverlayClick(self: *AppState, point: palette.draw.Vec2) bool {
        if (!self.composer_controller.toolbar_overlay_valid) return false;
        // Model and run pills open host-owned popovers (rich picker /
        // run-config panel); the composer's built-in dropdowns stay disabled
        // via `setExternalModelMenu` / `setExternalReasoningMenu`.
        if (self.composer_controller.toolbar_model_rect.contains(point)) {
            self.openPaletteModelPicker();
            return true;
        }
        if (self.composer_controller.toolbar_reasoning_rect.contains(point) and self.composer_controller.composer.showReasoningToggle()) {
            self.toggleRunConfigPopover();
            return true;
        }
        return false;
    }

    pub fn routePaletteComposerMouseMotion(self: *AppState, event: *const sdl.MouseMotionEvent, ui_scale: f32) bool {
        if (self.project_controller.projects.items.len == 0) return false;
        const point = paletteMousePoint(event.x, event.y, ui_scale);
        const input: palette.ComposerPromptInput = if (event.state.left != 0)
            .{ .mouse_drag = point }
        else
            .{ .mouse_move = point };
        const handled = self.composer_controller.composer.handleInput(self.allocator, input) catch |err| {
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
        if (self.project_controller.projects.items.len == 0) return false;
        const handled = self.composer_controller.composer.handleInput(self.allocator, .{
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
        if (self.project_controller.projects.items.len == 0) return false;
        if (event.button != 1) return false;
        const point = paletteMousePoint(event.x, event.y, ui_scale);
        if (self.routePaletteModelPickerMouseButton(point, event.down, event.clicks)) return true;
        return self.routeRunConfigMouseButton(point, event.down);
    }

    pub fn routeComposerPopoverMouseMotion(self: *AppState, event: *const sdl.MouseMotionEvent, ui_scale: f32) bool {
        if (self.project_controller.projects.items.len == 0) return false;
        const point = paletteMousePoint(event.x, event.y, ui_scale);
        if (self.routePaletteModelPickerMouseMove(point, event.state.left != 0)) return true;
        return self.routeRunConfigMouseMove(point);
    }

    pub fn routeComposerPopoverWheel(self: *AppState, event: *const sdl.MouseWheelEvent, ui_scale: f32) bool {
        if (self.project_controller.projects.items.len == 0) return false;
        const point = paletteMousePoint(event.mouse_x, event.mouse_y, ui_scale);
        if (self.routePaletteModelPickerWheel(point, event.y)) return true;
        return self.routeRunConfigWheel(point);
    }

    fn routePaletteModelPickerKey(self: *AppState, key: palette.Key) bool {
        if (!self.composer_controller.model_picker.isOpen()) return false;
        return self.modelPickerInput(.{ .key = key });
    }

    fn routeRunConfigKey(self: *AppState, key: palette.Key) bool {
        if (!self.composer_controller.run_config_open) return false;
        var kinds: [3]RunConfigRowKind = undefined;
        const count = self.runConfigVisibleRows(&kinds);
        if (count == 0) {
            self.closeRunConfigPopoverFromKeyboard();
            return true;
        }
        if (self.composer_controller.run_config_focused_row >= count) self.composer_controller.run_config_focused_row = count - 1;
        switch (key.code) {
            .up => {
                self.composer_controller.run_config_focused_row = (self.composer_controller.run_config_focused_row + count - 1) % count;
                self.noteInteraction();
                return true;
            },
            .down => {
                self.composer_controller.run_config_focused_row = (self.composer_controller.run_config_focused_row + 1) % count;
                self.noteInteraction();
                return true;
            },
            .enter => {
                self.closeRunConfigPopoverFromKeyboard();
                self.noteInteraction();
                return true;
            },
            .left, .right, .home, .end => {
                _ = self.layoutRunConfigPopover();
                const stepper = &self.composer_controller.run_steppers[@intFromEnum(kinds[self.composer_controller.run_config_focused_row])];
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
                self.composer_controller.slash_selected = if (self.composer_controller.slash_selected == 0) count - 1 else self.composer_controller.slash_selected - 1;
                self.noteInteraction();
                self.markDirty();
                return true;
            },
            .down => {
                self.composer_controller.slash_selected = (self.composer_controller.slash_selected + 1) % count;
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
        if (!self.composer_controller.model_picker.isOpen()) return false;
        // Clicking the run pill swaps popovers in one click: dismiss the
        // picker and let the toolbar overlay handler open the run config.
        if (down and self.composer_controller.toolbar_overlay_valid and self.composer_controller.toolbar_reasoning_rect.contains(point)) {
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
        if (!self.composer_controller.model_picker.isOpen()) return false;
        return self.modelPickerInput(if (dragging)
            .{ .mouse_drag = point }
        else
            .{ .mouse_move = point });
    }

    fn routePaletteModelPickerWheel(self: *AppState, point: palette.draw.Vec2, y: f32) bool {
        if (!self.composer_controller.model_picker.isOpen()) return false;
        return self.modelPickerInput(.{ .mouse_wheel = .{ .point = point, .y = y } });
    }

    fn routeRunConfigMouseButton(self: *AppState, point: palette.draw.Vec2, down: bool) bool {
        if (!self.composer_controller.run_config_open) return false;
        if (!down) return false;
        const layout = self.layoutRunConfigPopover();
        var index: usize = 0;
        while (index < layout.row_count) : (index += 1) {
            const stepper = &self.composer_controller.run_steppers[@intFromEnum(layout.row_kinds[index])];
            if (stepper.handleInput(.{ .mouse_down = point })) {
                self.composer_controller.run_config_focused_row = index;
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
        if (self.composer_controller.toolbar_overlay_valid and self.composer_controller.toolbar_model_rect.contains(point)) return false;
        return true;
    }

    fn routeRunConfigMouseMove(self: *AppState, point: palette.draw.Vec2) bool {
        if (!self.composer_controller.run_config_open) return false;
        const layout = self.layoutRunConfigPopover();
        var hovered = false;
        var index: usize = 0;
        while (index < layout.row_count) : (index += 1) {
            const stepper = &self.composer_controller.run_steppers[@intFromEnum(layout.row_kinds[index])];
            if (stepper.handleInput(.{ .mouse_move = point })) hovered = true;
        }
        return hovered or layout.panel.contains(point);
    }

    fn routeRunConfigWheel(self: *AppState, point: palette.draw.Vec2) bool {
        if (!self.composer_controller.run_config_open) return false;
        const layout = self.layoutRunConfigPopover();
        return layout.panel.contains(point);
    }

    fn handlePaletteComposerNavigationKey(self: *AppState, key: palette.Key) bool {
        if (key.primary and key.code == .a) {
            self.composer_controller.composer.selection_anchor = 0;
            self.composer_controller.composer.selection_focus = self.composer_controller.composer.text().len;
            self.composer_controller.composer.cursor = self.composer_controller.composer.text().len;
            self.ensurePaletteComposerCursorVisible();
            return true;
        }

        if (key.code != .up and key.code != .down) return false;
        const text = self.composer_controller.composer.text();
        const metrics = paletteComposerTextFontMetrics(theme.scaledUi(PALETTE_COMPOSER_FONT_SIZE));
        const text_rect = self.composer_controller.composer.textRect();
        const cell = palette.TextLayout.visualCellForOffset(text, self.composer_controller.composer.cursor, metrics, text_rect.w, true);
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
        _ = self.composer_controller.composer.handleInput(self.allocator, .{ .mouse_down = point }) catch |err| {
            log.warn("palette composer mouse input failed: {s}", .{@errorName(err)});
            return false;
        };
        const text = self.composer_controller.composer.text();
        const offset = self.composer_controller.composer.cursor;
        const range = if (clicks >= 3) blk: {
            const start = palette.input_selection.lineStart(text, offset);
            var end = palette.input_selection.lineEnd(text, offset);
            if (end < text.len) end += 1;
            break :blk palette.input_selection.Range{ .start = start, .end = end };
        } else palette.input_selection.wordRangeAt(text, offset);
        self.composer_controller.composer.selection_anchor = range.start;
        self.composer_controller.composer.selection_focus = range.end;
        self.composer_controller.composer.cursor = range.end;
        self.composer_controller.composer.dragging_selection = false;
        self.composer_controller.focused = true;
        self.terminal_controller.focused = false;
        self.unfocusBrowserPane();
        self.ensurePaletteComposerCursorVisible();
        self.noteInteraction();
        return true;
    }

    fn movePaletteComposerCursor(self: *AppState, next: usize, extend_selection: bool) void {
        const old = self.composer_controller.composer.cursor;
        self.composer_controller.composer.cursor = @min(next, self.composer_controller.composer.text().len);
        if (extend_selection) {
            if (self.composer_controller.composer.selection_anchor == null) self.composer_controller.composer.selection_anchor = old;
            self.composer_controller.composer.selection_focus = self.composer_controller.composer.cursor;
        } else {
            self.composer_controller.composer.selection_anchor = null;
            self.composer_controller.composer.selection_focus = null;
        }
        self.ensurePaletteComposerCursorVisible();
    }

    pub fn ensurePaletteComposerCursorVisible(self: *AppState) void {
        const text_rect = self.composer_controller.composer.textRect();
        const cursor = self.composer_controller.composer.cursorRect();
        const bottom = text_rect.y + text_rect.h;
        if (cursor.y < text_rect.y) {
            self.composer_controller.composer.setScrollY(self.composer_controller.composer.scrollY() - (text_rect.y - cursor.y));
        } else if (cursor.y + cursor.h > bottom) {
            self.composer_controller.composer.setScrollY(self.composer_controller.composer.scrollY() + cursor.y + cursor.h - bottom);
        }
    }

    pub fn setComposerInputBounds(self: *AppState, input_min: [2]f32, input_max: [2]f32) void {
        self.composer_controller.input_bounds_valid = true;
        self.composer_controller.input_min = input_min;
        self.composer_controller.input_max = input_max;
    }

    pub fn setComposerDraftImageClearRect(self: *AppState, rect: ?palette.Rect) void {
        self.setComposerDraftImageClearRectAt(rect, 0);
    }

    pub fn setComposerDraftImageClearRectAt(self: *AppState, rect: ?palette.Rect, index: usize) void {
        if (rect) |value| {
            self.composer_controller.draft_image_clear_valid = true;
            self.composer_controller.draft_image_clear_rect = value;
            self.composer_controller.draft_image_clear_index = index;
            if (self.composer_controller.draft_image_clear_count < self.composer_controller.draft_image_clear_rects.len) {
                const slot = self.composer_controller.draft_image_clear_count;
                self.composer_controller.draft_image_clear_rects[slot] = value;
                self.composer_controller.draft_image_clear_indices[slot] = index;
                self.composer_controller.draft_image_clear_count += 1;
            }
        } else {
            self.composer_controller.draft_image_clear_valid = false;
            self.composer_controller.draft_image_clear_rect = .{ .x = 0.0, .y = 0.0, .w = 0.0, .h = 0.0 };
            self.composer_controller.draft_image_clear_index = 0;
            self.composer_controller.draft_image_clear_count = 0;
        }
    }

    /// Records the pinned follow-up card hit rect for this frame (or clears it).
    /// Called from the chat workspace render so mouse routing can target the pin.
    pub fn setFollowupPinRect(self: *AppState, rect: ?palette.Rect) void {
        if (rect) |value| {
            self.composer_controller.followup_pin_valid = true;
            self.composer_controller.followup_pin_rect = value;
        } else {
            self.composer_controller.followup_pin_valid = false;
            self.composer_controller.followup_pin_rect = .{ .x = 0.0, .y = 0.0, .w = 0.0, .h = 0.0 };
        }
    }

    /// Routes a click on the pinned follow-up card. A double-click (clicks >= 2)
    /// pulls the queued prompt back into the composer for editing; a single click
    /// is swallowed so it does not fall through to the composer/transcript.
    pub fn handleFollowupPinMouseButton(self: *AppState, x: f32, y: f32, down: bool, clicks: u8) bool {
        if (!self.composer_controller.followup_pin_valid) return false;
        const rect = self.composer_controller.followup_pin_rect;
        if (x < rect.x or y < rect.y or x > rect.x + rect.w or y > rect.y + rect.h) return false;
        if (down and clicks >= 2) self.editPendingFollowup();
        return true;
    }

    /// Pulls the queued/steered follow-up back into the composer so a long-waiting
    /// queued message can be revised. Removes the pin (it is no longer queued); the
    /// user re-queues with Tab or sends normally. Refuses to clobber an in-progress
    /// draft, and ignores Codex steering already accepted inline (`.sent_inline`).
    pub fn editPendingFollowup(self: *AppState) void {
        if (self.project_controller.projects.items.len == 0) return;
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
        self.composer_controller.composer.focused = true;
        self.composer_controller.focused = true;
        self.setFollowupPinRect(null);
        self.markDirty();
        self.setSidebarNotice(if (thread.provider == .codex)
            "Editing follow-up. Press Enter to queue it, or Tab to steer."
        else
            "Editing queued message. Press Tab to queue it again.");
    }

    pub fn handleComposerDraftImageClearMouseButton(self: *AppState, x: f32, y: f32, down: bool) bool {
        if (self.project_controller.projects.items.len == 0) return false;
        if (!self.composer_controller.draft_image_clear_valid) return false;
        var i: usize = self.composer_controller.draft_image_clear_count;
        while (i > 0) {
            i -= 1;
            const rect = self.composer_controller.draft_image_clear_rects[i];
            if (x < rect.x or y < rect.y or x > rect.x + rect.w or y > rect.y + rect.h) continue;
            if (!down) {
                self.clearCurrentDraftImageAt(self.composer_controller.draft_image_clear_indices[i]);
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

    pub fn handleComposerWheel(self: *AppState, event: *const sdl.MouseWheelEvent) bool {
        if (self.project_controller.projects.items.len == 0) return false;
        if (!self.composer_controller.input_bounds_valid) return false;
        if (event.mouse_x < self.composer_controller.input_min[0] or event.mouse_x > self.composer_controller.input_max[0]) return false;
        if (event.mouse_y < self.composer_controller.input_min[1] or event.mouse_y > self.composer_controller.input_max[1]) return false;

        self.composer_controller.overlay_scroll_y = @max(0.0, self.composer_controller.overlay_scroll_y - event.y * 48.0);
        self.composer_controller.overlay_follow_cursor = false;
        self.noteInteraction();
        return true;
    }

    pub fn setDraft(self: *AppState, value: []const u8) void {
        self.currentProjectMutable().setDraft(value);
        self.markDirty();
    }

    pub fn clearDraft(self: *AppState) void {
        self.currentProjectMutable().clearDraft();
        self.markDirty();
    }

    pub fn resetComposerInputWidget(self: *AppState) void {
        self.composer_controller.input_nonce +%= 1;
        self.composer_controller.overlay_scroll_y = 0.0;
        self.composer_controller.overlay_follow_cursor = true;
        self.composer_controller.overlay_last_cursor_pos = 0;
        self.composer_controller.overlay_last_draft_len = 0;
        const callbacks = self.composer_controller.composer.callbacks;
        self.composer_controller.composer.setCallbacks(.{});
        defer self.composer_controller.composer.setCallbacks(callbacks);
        self.composer_controller.composer.setText(self.allocator, self.currentDraft()) catch |err| {
            log.warn("failed to reset palette composer draft: {s}", .{@errorName(err)});
        };
    }

    pub const updateFileSearch = file_search_controller.updateFileSearch;
    pub const hasActiveFileSearch = file_search_controller.hasActiveFileSearch;
    pub const fileSearchResults = file_search_controller.fileSearchResults;
    pub const fileSearchIsScanning = file_search_controller.fileSearchIsScanning;
    pub const fileSearchSelectedIndex = file_search_controller.fileSearchSelectedIndex;
    pub const moveFileSearchSelection = file_search_controller.moveFileSearchSelection;
    pub const acceptPrimaryFileSearchResult = file_search_controller.acceptPrimaryFileSearchResult;
    pub const selectFileSearchResult = file_search_controller.selectFileSearchResult;
    pub const ensureFileSearchFinder = file_search_controller.ensureFileSearchFinder;
    pub const clearFileSearch = file_search_controller.clearFileSearch;

    pub const markDirty = lifecycle_controller.markDirty;
    pub const noteInteraction = lifecycle_controller.noteInteraction;
    pub const requestTranscriptScrollToBottom = transcript_controller.requestTranscriptScrollToBottom;
    pub const requestTranscriptLineScroll = transcript_controller.requestTranscriptLineScroll;
    pub const requestTranscriptPageScroll = transcript_controller.requestTranscriptPageScroll;

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

    pub fn renameInput(self: *const AppState) []const u8 {
        return std.mem.sliceTo(self.rename_storage[0..], 0);
    }

    pub fn renameBuffer(self: *AppState) [:0]u8 {
        return self.rename_storage[0 .. self.rename_storage.len - 1 :0];
    }

    pub fn syncRenameBuffer(self: *AppState) void {
        if (self.project_controller.projects.items.len == 0) {
            self.rename_storage[0] = 0;
            return;
        }
        @memset(&self.rename_storage, 0);
        const label = self.currentProject().label;
        const len = @min(label.len, self.rename_storage.len - 1);
        @memcpy(self.rename_storage[0..len], label[0..len]);
    }

    fn syncThreadRenameBuffer(self: *AppState, title: []const u8) void {
        @memset(&self.rename_storage, 0);
        const len = @min(title.len, self.rename_storage.len - 1);
        @memcpy(self.rename_storage[0..len], title[0..len]);
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
        for (self.herdr_controller.summaries.items) |profile| {
            profile.deinit(self.allocator);
        }
        self.herdr_controller.summaries.clearRetainingCapacity();
        self.herdr_controller.selected_index = null;
        self.herdr_controller.hover_index = null;
    }

    pub fn dupeZ(self: *AppState, value: []const u8) ![:0]const u8 {
        return try self.allocator.dupeZ(u8, value);
    }

    pub fn deinit(self: *AppState) void {
        runtime_log.diagnostic("AppState.deinit begin", .{});
        startShutdownWatchdog();
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
        self.deinitBackgroundTaskPoller();
        runtime_log.diagnostic("AppState.deinit background task poller finished", .{});
        self.settings_controller.update.deinit();
        runtime_log.diagnostic("AppState.deinit updater finished", .{});
        self.finishAllSendThreads();
        runtime_log.diagnostic("AppState.deinit send threads finished", .{});
        self.finishAllTitleGenerationThreads();
        runtime_log.diagnostic("AppState.deinit title generation threads finished", .{});
        _ = self.pollSend();
        runtime_log.diagnostic("AppState.deinit sends polled", .{});
        ai_harness.shutdownOwnedProviderProcesses();
        runtime_log.diagnostic("AppState.deinit provider processes shutdown", .{});
        self.flushDirtyBlocking();
        runtime_log.diagnostic("AppState.deinit dirty state flushed", .{});
        self.file_search_controller.deinit(self.allocator);
        self.composer_controller.composer.deinit(self.allocator);
        self.palette_overlay_batch.deinit(self.allocator);
        self.palette_frame_text.deinit(self.allocator);
        self.palette_frame_text_arena.deinit();
        self.palette_modal_hits.deinit(self.allocator);
        self.code_copy_buttons.deinit(self.allocator);
        self.card_toggle_hits.deinit(self.allocator);
        self.background_task_action_hits.deinit(self.allocator);
        self.expanded_cards.deinit();
        self.closeTranscriptSelectionModal();
        self.clearProjects();
        self.clearSurfaces();
        self.transcript_controller.markdown_entries.deinit(self.allocator);
        self.transcript_controller.diff_view_cache.deinit(self.allocator);
        self.browser_controller.deinit(self.allocator);
        self.releaseAllImageTextures();
        self.thread_import_threads.deinit(self.allocator);
        if (self.handoff_controller.preview) |preview| self.allocator.free(preview);
        self.clearHerdrProfileSummaries();
        self.herdr_controller.summaries.deinit(self.allocator);
        self.clearOpencodeModelOptions();
        self.clearClaudeModelOptions();
        self.clearCursorModelOptions();
        self.opencode_reasoning_menu.deinit(self.allocator);
        self.opencode_model_options.deinit(self.allocator);
        self.claude_model_options.deinit(self.allocator);
        self.cursor_model_options.deinit(self.allocator);
        if (self.settings_controller.chat_title_model) |model| self.allocator.free(model);
        self.app_config.deinit(self.allocator);
        self.project_controller.projects.deinit(self.allocator);
        self.project_controller.archived_projects.deinit(self.allocator);
        self.surface_controller.surfaces.deinit(self.allocator);
        shutdown_watchdog_deinit_complete.store(true, .release);
        runtime_log.diagnostic("AppState.deinit complete", .{});
    }

    fn preparePendingSendsForShutdown(self: *AppState) void {
        for (self.project_controller.projects.items) |*project| {
            for (project.threads.items) |*thread| {
                self.prepareThreadSendForShutdown(project.path, thread);
            }
            for (project.archived_threads.items) |*thread| {
                self.prepareThreadSendForShutdown(project.path, thread);
            }
        }
        for (self.project_controller.archived_projects.items) |*project| {
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
                    if (self.project_controller.show_creator) {
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

    pub const pollOpencodeModelOptionsCache = provider_controller.pollOpencodeModelOptionsCache;
    pub const pollCursorModelOptionsCache = provider_controller.pollCursorModelOptionsCache;
    pub const pollClaudeModelOptionsCache = provider_controller.pollClaudeModelOptionsCache;

    pub const pollSend = chat_controller.pollSend;
    pub const pollTitleGenerations = chat_controller.pollTitleGenerations;
    pub const pollThreadTitleGeneration = chat_controller.pollThreadTitleGeneration;
    pub const openingExchange = chat_controller.openingExchange;
    pub const boundedUtf8Prefix = chat_controller.boundedUtf8Prefix;
    pub const startTitleGeneration = chat_controller.startTitleGeneration;
    pub const maybeStartAutomaticTitleGeneration = chat_controller.maybeStartAutomaticTitleGeneration;
    pub const canRegenerateCurrentThreadTitle = chat_controller.canRegenerateCurrentThreadTitle;
    pub const canRegenerateThreadTitle = chat_controller.canRegenerateThreadTitle;
    pub const regenerateCurrentThreadTitle = chat_controller.regenerateCurrentThreadTitle;
    pub const regenerateThreadTitleAtIndex = chat_controller.regenerateThreadTitleAtIndex;
    pub const pollSlashCommand = chat_controller.pollSlashCommand;
    pub const currentThreadPendingSlashCommand = chat_controller.currentThreadPendingSlashCommand;
    pub const hasPendingSlashCommand = chat_controller.hasPendingSlashCommand;
    pub const currentThreadPendingSlashCommandLabel = chat_controller.currentThreadPendingSlashCommandLabel;
    pub const applySlashCommandResult = chat_controller.applySlashCommandResult;
    pub const hasRunningBackgroundTasks = chat_controller.hasRunningBackgroundTasks;
    pub const threadHasRunningBackgroundTasks = chat_controller.threadHasRunningBackgroundTasks;
    pub const pollBackgroundTasks = chat_controller.pollBackgroundTasks;
    pub const pollThreadBackgroundTasks = chat_controller.pollThreadBackgroundTasks;
    pub const deinitBackgroundTaskPoller = chat_controller.deinitBackgroundTaskPoller;
    pub const backgroundTaskCompletionBodyAlloc = chat_controller.backgroundTaskCompletionBodyAlloc;
    pub const readBackgroundTaskPid = chat_controller.readBackgroundTaskPid;
    pub const backgroundTaskProcessIsAlive = chat_controller.backgroundTaskProcessIsAlive;
    pub const pollDaemonChatTurn = chat_controller.pollDaemonChatTurn;
    pub const applyDaemonChatTurnTail = chat_controller.applyDaemonChatTurnTail;
    pub const applyDaemonChatEventLocked = chat_controller.applyDaemonChatEventLocked;
    pub const applyDaemonDiffEventLocked = chat_controller.applyDaemonDiffEventLocked;
    pub const parseToolCallKind = chat_controller.parseToolCallKind;
    pub const parseToolCallStatus = chat_controller.parseToolCallStatus;
    pub const pollThreadSend = chat_controller.pollThreadSend;
    pub const noteChatCompletion = chat_controller.noteChatCompletion;
    pub const isChatThreadFocused = chat_controller.isChatThreadFocused;
    pub const capturePendingProviderThreadId = chat_controller.capturePendingProviderThreadId;
    pub const issuePendingThreadStop = chat_controller.issuePendingThreadStop;
    pub const issuePendingCodexSteer = chat_controller.issuePendingCodexSteer;
    pub const dispatchPendingFollowup = chat_controller.dispatchPendingFollowup;
    pub const clearPendingFollowupAfterFailure = chat_controller.clearPendingFollowupAfterFailure;
    pub const finishPickerThread = chat_controller.finishPickerThread;
    pub const finishSlashCommandThread = chat_controller.finishSlashCommandThread;
    pub const finishOpencodeModelCacheThread = chat_controller.finishOpencodeModelCacheThread;
    pub const finishClaudeModelCacheThread = chat_controller.finishClaudeModelCacheThread;
    pub const finishCursorModelCacheThread = chat_controller.finishCursorModelCacheThread;
    pub const finishProviderReadinessThread = chat_controller.finishProviderReadinessThread;
    pub const finishAllSendThreads = chat_controller.finishAllSendThreads;
    pub const finishAllTitleGenerationThreads = chat_controller.finishAllTitleGenerationThreads;
    pub const prepareThreadSendForShutdown = chat_controller.prepareThreadSendForShutdown;
    pub const hasPendingStream = chat_controller.hasPendingStream;
    pub const hasAnyPendingSends = chat_controller.hasAnyPendingSends;
    pub const pendingSendCount = chat_controller.pendingSendCount;
    pub const isPickerPending = chat_controller.isPickerPending;
    pub const pendingApprovalSnapshot = chat_controller.pendingApprovalSnapshot;
    pub const resolvePendingApproval = chat_controller.resolvePendingApproval;
    pub const applySendSuccess = chat_controller.applySendSuccess;
    pub const applyPendingTimelineEvents = chat_controller.applyPendingTimelineEvents;
    pub const reconcileCodexBackgroundSnapshot = chat_controller.reconcileCodexBackgroundSnapshot;
    pub const applySendFailure = chat_controller.applySendFailure;

    pub fn resolveProjectPath(self: *AppState, raw_path: []const u8) ![]u8 {
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

    pub fn findProjectIndexByPath(self: *const AppState, path: []const u8) ?usize {
        for (self.project_controller.projects.items, 0..) |project, index| {
            if (self.projectPathMatches(project.path, path)) return index;
        }
        return null;
    }

    fn findArchivedProjectIndexByPath(self: *const AppState, path: []const u8) ?usize {
        for (self.project_controller.archived_projects.items, 0..) |project, index| {
            if (self.projectPathMatches(project.path, path)) return index;
        }
        return null;
    }

    pub fn projectPathMatches(self: *const AppState, left: []const u8, right: []const u8) bool {
        return platform_paths.projectPathsEqual(self.allocator, left, right) catch std.mem.eql(u8, left, right);
    }

    fn findThreadIndexByProviderThreadId(self: *const AppState, project_index: usize, provider: Provider, thread_id: []const u8) ?usize {
        if (project_index >= self.project_controller.projects.items.len) return null;
        const project = &self.project_controller.projects.items[project_index];
        for (project.threads.items, 0..) |thread, index| {
            if (thread.provider != provider) continue;
            const existing_id = thread.provider_thread_id orelse continue;
            if (std.mem.eql(u8, existing_id, thread_id)) return index;
        }
        return null;
    }

    pub fn deriveProjectId(self: *AppState, path: []const u8) ![]u8 {
        const comparison_key = try platform_paths.projectComparisonKeyAllocForOs(self.allocator, builtin.os.tag, path);
        defer self.allocator.free(comparison_key);
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(comparison_key);
        return std.fmt.allocPrint(self.allocator, "{x}", .{hasher.final()});
    }

    fn dupeOptionalSlice(allocator: std.mem.Allocator, value: ?[]const u8) !?[]const u8 {
        const slice = value orelse return null;
        return try allocator.dupe(u8, slice);
    }

    fn clearProjects(self: *AppState) void {
        self.cancelThreadImport();
        self.clearFileSearch();
        self.clearOpencodeModelOptions();
        if (self.file_search_controller.finder) |*finder| {
            finder.deinit();
            self.file_search_controller.finder = null;
        }
        if (self.file_search_controller.project_path) |project_path| {
            self.allocator.free(project_path);
            self.file_search_controller.project_path = null;
        }
        self.clearImageTextureCache();
        self.closeImageModal();
        self.closeTranscriptSelectionModal();
        self.clearTranscriptMarkdownSelection();
        self.clearTranscriptMarkdownEntries();
        for (self.project_controller.projects.items) |*project| {
            project.deinit(self.allocator);
        }
        self.project_controller.projects.clearRetainingCapacity();
        for (self.project_controller.archived_projects.items) |*project| {
            project.deinit(self.allocator);
        }
        self.project_controller.archived_projects.clearRetainingCapacity();
        self.project_controller.selected_index = 0;
        self.project_controller.next_project_number = 1;
        self.project_controller.show_creator = false;
        self.clearImportPath();
        self.rename_storage[0] = 0;
        self.lifecycle.dirty = false;
    }

    fn defaultExplorerPath(self: *AppState) ![]u8 {
        if (self.importDirectoryDraft().len > 0) {
            return self.resolveProjectPath(std.mem.trim(u8, self.importDirectoryDraft(), &std.ascii.whitespace));
        }

        if (self.project_controller.projects.items.len > 0) {
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

    pub fn recordBackgroundTaskActionHit(self: *AppState, hit: BackgroundTaskActionHit) void {
        self.background_task_action_hits.append(self.allocator, hit) catch |err| {
            log.warn("failed to retain background task action hit: {s}", .{@errorName(err)});
        };
    }

    pub fn recordBackgroundTaskActionForMessage(self: *AppState, rect: palette.Rect, message_index: usize, body: []const u8, action: BackgroundTaskAction) void {
        if (rect.w < 2 or rect.h < 2) return;
        for (self.project_controller.projects.items, 0..) |*project, project_index| for (project.threads.items, 0..) |*thread, thread_index| {
            if (message_index >= thread.messages.items.len or !std.mem.eql(u8, thread.messages.items[message_index].body, body)) continue;
            const task = chat_controller.backgroundTaskForEventBody(thread, body) orelse continue;
            const task_index = (@intFromPtr(task) - @intFromPtr(thread.background_tasks.items.ptr)) / @sizeOf(BackgroundTask);
            self.recordBackgroundTaskActionHit(.{ .rect = rect, .project_index = project_index, .thread_index = thread_index, .task_index = task_index, .message_index = message_index, .action = action });
            return;
        };
    }

    pub fn consumeBackgroundTaskActionClick(self: *AppState, x: f32, y: f32) bool {
        for (self.background_task_action_hits.items) |hit| {
            if (x < hit.rect.x or x > hit.rect.x + hit.rect.w or y < hit.rect.y or y > hit.rect.y + hit.rect.h) continue;
            if (hit.project_index >= self.project_controller.projects.items.len) return true;
            var project = &self.project_controller.projects.items[hit.project_index];
            if (hit.thread_index >= project.threads.items.len) return true;
            const thread = &project.threads.items[hit.thread_index];
            if (hit.message_index >= thread.messages.items.len) return true;
            if (hit.task_index >= thread.background_tasks.items.len) return true;
            const task = &thread.background_tasks.items[hit.task_index];
            if (chat_controller.backgroundTaskForEventBody(thread, thread.messages.items[hit.message_index].body) != task) {
                self.setSidebarNotice("Background task is no longer available.");
                return true;
            }
            switch (hit.action) {
                .stop => self.stopBackgroundTask(hit.project_index, thread, task),
                .output => self.openBackgroundTaskOutput(hit.project_index, task, hit.message_index),
            }
            return true;
        }
        return false;
    }

    fn stopBackgroundTask(self: *AppState, project_index: usize, thread: *ChatThread, task: *BackgroundTask) void {
        if (task.status != .running or task.stop_requested) return;
        if (task.provider == .codex or task.process_id != null) {
            const thread_id = task.provider_thread_id orelse {
                self.setSidebarNotice("Codex background task is missing its thread ID.");
                return;
            };
            const process_id = task.process_id orelse {
                self.setSidebarNotice("Codex background task is missing its process ID.");
                return;
            };
            const target = self.providerExecutionTargetForProjectThread(project_index, thread, 0) orelse return;
            const config: ai_harness.ProviderConfig = .{ .codex = .{
                .cwd = target.cwd(),
                .launch_on_connect = false,
                .remote_ssh = if (target.remoteHost()) |host| .{ .host = host, .cwd = target.cwd() } else null,
            } };
            var client = ai_harness.connect(self.allocator, config) catch |err| {
                log.warn("failed to connect for background task stop: {s}", .{@errorName(err)});
                self.setSidebarNotice("Failed to connect to Codex to stop the background task.");
                return;
            };
            defer client.deinit();
            client.terminateBackgroundTerminal(thread_id, process_id) catch |err| {
                log.warn("failed to stop Codex background task: {s}", .{@errorName(err)});
                self.setSidebarNotice("Codex could not stop the background task.");
                return;
            };
            task.stop_requested = true;
            task.status = .stopped;
            const body = backgroundTaskCompletionBodyAlloc(self.allocator, task) catch return;
            defer self.allocator.free(body);
            self.appendMessageToThread(thread, .system, "Background task stopped", body, null, &.{}) catch return;
            self.markDirty();
            return;
        }
        if (!task.pid_verified) {
            self.setSidebarNotice("Cannot safely stop this restored PID; wait for a new live task event.");
            return;
        }
        const pid = task.pid orelse if (task.pid_path) |path| readBackgroundTaskPid(self.allocator, path) else null;
        const resolved_pid = pid orelse {
            self.setSidebarNotice("Background task PID is not available yet.");
            return;
        };
        platform_process.terminateProcessIdTree(resolved_pid) catch |err| {
            log.warn("failed to stop background process tree: {s}", .{@errorName(err)});
            self.setSidebarNotice("Failed to request background task termination.");
            return;
        };
        task.pid = resolved_pid;
        task.stop_requested = true;
        task.last_poll_ms = 0;
        self.setSidebarNotice("Stopping background task...");
        self.markDirty();
    }

    fn openBackgroundTaskOutput(self: *AppState, project_index: usize, task: *BackgroundTask, message_index: usize) void {
        const log_path = task.log_path orelse {
            const key = commandCardKey(message_index);
            self.expanded_cards.put(key, true) catch {};
            self.setSidebarNotice("Codex process details are shown in the expanded card; retained live output is not exposed by this API.");
            self.markDirty();
            return;
        };
        const command = backgroundLogFollowCommandAlloc(self.allocator, log_path) catch {
            self.setSidebarNotice("Failed to prepare background task output command.");
            return;
        };
        defer self.allocator.free(command);
        self.project_controller.selected_index = project_index;
        const pane_id = self.openCurrentProjectTerminalPaneForCommand() orelse return;
        _ = self.writeWorkspaceTerminalPane(pane_id, command) catch {
            self.setSidebarNotice("Failed to open background task output.");
            return;
        };
        self.markDirty();
    }

    pub fn commandCardKey(message_index: usize) u64 {
        var hasher = std.hash.Wyhash.init(0xC0DEC0DEC0DEC0DE);
        hasher.update(std.mem.asBytes(&message_index));
        hasher.update("command_card");
        return hasher.final();
    }

    fn backgroundLogFollowCommandAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
        var escaped: std.ArrayList(u8) = .empty;
        defer escaped.deinit(allocator);
        for (path) |byte| {
            if (byte == '\'') try escaped.appendSlice(allocator, if (builtin.os.tag == .windows) "''" else "'\\''") else try escaped.append(allocator, byte);
        }
        return if (builtin.os.tag == .windows)
            std.fmt.allocPrint(allocator, "Get-Content -LiteralPath '{s}' -Tail 200 -Wait\r", .{escaped.items})
        else
            std.fmt.allocPrint(allocator, "tail -n 200 -f -- '{s}'\n", .{escaped.items});
    }

    /// Returns true when the given card key was previously toggled to expanded.
    pub fn isCardExpanded(self: *AppState, key: u64) bool {
        return self.isCardExpandedDefault(key, false);
    }

    pub fn isCardExpandedDefault(self: *AppState, key: u64, default_expanded: bool) bool {
        return self.expanded_cards.get(key) orelse default_expanded;
    }

    pub fn setDiffLayoutPreference(self: *AppState, preference: app_config.DiffLayoutPreference) void {
        if (self.app_config.diff_layout_preference == preference) return;
        self.app_config.diff_layout_preference = preference;
        self.settings_controller.draft.diff_layout_preference = preference;
        app_config.saveAppConfig(self.allocator, &self.app_config) catch |err| {
            log.warn("failed to save diff layout preference: {s}", .{@errorName(err)});
        };
        self.markDirty();
    }

    /// Hit-tests the most recent frame's card-toggle headers. On hit, flips
    /// the expanded state for that key and returns true.
    pub fn consumeCardToggleClick(self: *AppState, x: f32, y: f32) bool {
        for (self.card_toggle_hits.items) |hit| {
            if (x < hit.rect.x or x > hit.rect.x + hit.rect.w) continue;
            if (y < hit.rect.y or y > hit.rect.y + hit.rect.h) continue;
            const expanded = !self.isCardExpandedDefault(hit.key, hit.default_expanded);
            self.expanded_cards.put(hit.key, expanded) catch |err| {
                log.warn("failed to store expanded card: {s}", .{@errorName(err)});
            };
            if (hit.kind == .tool_call_group and self.app_config.tool_call_group_preference == .remember_last) {
                self.app_config.tool_call_groups_last_expanded = expanded;
                app_config.saveAppConfig(self.allocator, &self.app_config) catch |err| {
                    log.warn("failed to save tool call group expansion preference: {s}", .{@errorName(err)});
                };
            }
            self.markDirty();
            return true;
        }
        return false;
    }

    /// Registers a transcript copy action using the same per-frame payload
    /// storage and feedback state as fenced Markdown code blocks.
    pub fn recordTranscriptCopyHit(self: *AppState, rect: palette.Rect, payload: []const u8, identity: u64) void {
        const payload_offset = self.palette_frame_text.items.len;
        self.palette_frame_text.appendSlice(self.allocator, payload) catch |err| {
            log.warn("failed to retain transcript copy payload: {s}", .{@errorName(err)});
            return;
        };
        self.code_copy_buttons.append(self.allocator, .{
            .rect = rect,
            .payload_offset = payload_offset,
            .payload_len = payload.len,
            .identity = identity,
        }) catch |err| {
            log.warn("failed to retain transcript copy hit: {s}", .{@errorName(err)});
        };
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

/// Shutdown joins provider worker threads whose I/O can block on a stuck
/// peer (observed live 2026-07-15: an opencode health probe never returned,
/// leaving the window closed but the process only killable via SIGKILL).
/// 10s is generous for every legitimate deinit step while short enough that
/// a wedged close still terminates without user intervention.
const SHUTDOWN_WATCHDOG_TIMEOUT_MS: u64 = 10_000;
const SHUTDOWN_WATCHDOG_POLL_MS: u64 = 200;

var shutdown_watchdog_deinit_complete: std.atomic.Value(bool) = .init(false);

fn startShutdownWatchdog() void {
    const thread = std.Thread.spawn(.{}, shutdownWatchdogMain, .{}) catch |err| {
        runtime_log.diagnostic("shutdown watchdog spawn failed: {s}", .{@errorName(err)});
        return;
    };
    thread.detach();
}

fn shutdownWatchdogMain() void {
    var waited_ms: u64 = 0;
    while (waited_ms < SHUTDOWN_WATCHDOG_TIMEOUT_MS) : (waited_ms += SHUTDOWN_WATCHDOG_POLL_MS) {
        if (shutdown_watchdog_deinit_complete.load(.acquire)) return;
        platform_runtime.sleepMillis(SHUTDOWN_WATCHDOG_POLL_MS);
    }
    if (shutdown_watchdog_deinit_complete.load(.acquire)) return;
    runtime_log.diagnostic(
        "AppState.deinit watchdog expired after {d} ms; forcing process exit",
        .{SHUTDOWN_WATCHDOG_TIMEOUT_MS},
    );
    std.process.exit(0);
}

const providerReadinessWorker = provider_controller.providerReadinessWorker;
const opencodeModelCacheWorker = provider_controller.opencodeModelCacheWorker;
const cursorModelCacheWorker = provider_controller.cursorModelCacheWorker;
const claudeModelCacheWorker = provider_controller.claudeModelCacheWorker;

const titleGenerationWorker = chat_controller.titleGenerationWorker;

const slashCommandWorker = command_controller.slashCommandWorker;
const slashCommandFallbackName = command_controller.slashCommandFallbackName;

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

test "empty workspace ignores hidden composer and slash input" {
    var state: AppState = undefined;
    state.project_controller.projects = .empty;
    state.project_controller.selected_index = 0;

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

test "browser toggle opens another workspace without closing its active browser" {
    try std.testing.expect(!browserToggleCloses(false, null, 1));
    try std.testing.expect(browserToggleCloses(true, null, 1));
    try std.testing.expect(browserToggleCloses(true, 1, 1));
    try std.testing.expect(!browserToggleCloses(true, 0, 1));
}

test "browser origin comparison preserves same-site runtime only" {
    try std.testing.expect(browserUrlsHaveSameOrigin("about:blank", "about:blank"));
    try std.testing.expect(browserUrlsHaveSameOrigin("https://example.com/one", "https://EXAMPLE.com/two"));
    try std.testing.expect(browserUrlsHaveSameOrigin("https://example.com/", "https://example.com:443/path"));
    try std.testing.expect(!browserUrlsHaveSameOrigin("http://example.com/", "https://example.com/"));
    try std.testing.expect(!browserUrlsHaveSameOrigin("https://example.com/", "https://example.org/"));
    try std.testing.expect(!browserUrlsHaveSameOrigin("https://example.com:8443/", "https://example.com/"));
}

test "browser navigation persistence rejects empty backend URI events" {
    try std.testing.expect(!browserNavigationUrlIsPersistable(""));
    try std.testing.expect(!browserNavigationUrlIsPersistable(" \t\r\n"));
    try std.testing.expect(browserNavigationUrlIsPersistable("about:blank"));
    try std.testing.expect(browserNavigationUrlIsPersistable("https://example.com/"));
}

test "shared browser runtime routes state through its workspace owner" {
    const allocator = std.testing.allocator;
    var state: AppState = undefined;
    state.allocator = allocator;
    state.project_controller.projects = .empty;
    state.project_controller.selected_index = 0;
    state.browser_controller.runtime_project_index = null;
    defer {
        for (state.project_controller.projects.items) |*project| project.deinit(allocator);
        state.project_controller.projects.deinit(allocator);
    }

    var first_project = try Project.init(allocator, "first", "First", "/tmp/first", 0);
    state.project_controller.projects.append(allocator, first_project) catch |err| {
        first_project.deinit(allocator);
        return err;
    };
    var second_project = try Project.init(allocator, "second", "Second", "/tmp/second", 0);
    state.project_controller.projects.append(allocator, second_project) catch |err| {
        second_project.deinit(allocator);
        return err;
    };

    const first_pane_id = try state.project_controller.projects.items[0].workspace_layout.ensureBrowserPane(allocator);
    const second_pane_id = try state.project_controller.projects.items[1].workspace_layout.ensureBrowserPane(allocator);
    try state.browserPaneRefMutable(0, first_pane_id).?.activeTab().?.recordNavigation(allocator, "https://first.example/");
    try state.browserPaneRefMutable(1, second_pane_id).?.activeTab().?.recordNavigation(allocator, "https://second.example/");

    state.browser_controller.runtime_project_index = 1;
    try std.testing.expectEqual(@as(usize, 1), state.browserWorkspaceLocation().?.index);
    try std.testing.expectEqual(second_pane_id, state.browserWorkspacePaneId().?);
    try std.testing.expectEqualStrings("https://second.example/", state.browserPaneSnapshotUrl(1, second_pane_id).?);
    try std.testing.expectEqualStrings("https://first.example/", state.browserPaneSnapshotUrl(0, first_pane_id).?);

    state.browser_controller.runtime_project_index = 0;
    try std.testing.expectEqual(@as(usize, 0), state.browserWorkspaceLocation().?.index);
    try std.testing.expectEqual(first_pane_id, state.browserWorkspacePaneId().?);
    try std.testing.expect(state.browserPaneIdInWorkspace(1) != null);
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
    state.project_controller.projects = .empty;
    state.project_controller.selected_index = 0;
    state.opencode_model_options = .empty;
    state.opencode_reasoning_menu = .empty;
    state.provider_controller.opencode_model_cache = .{
        .status = .completed,
        .models = models,
    };
    defer {
        state.clearOpencodeModelOptions();
        state.opencode_model_options.deinit(allocator);
        state.opencode_reasoning_menu.deinit(allocator);
    }

    state.pollOpencodeModelOptionsCache();

    try std.testing.expectEqual(@as(usize, 0), state.project_controller.projects.items.len);
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

test "provider-aware chat creation scopes mutation and rejects invalid models" {
    const allocator = std.testing.allocator;
    var state: AppState = undefined;
    state.allocator = allocator;
    state.project_controller.projects = .empty;
    state.project_controller.selected_index = 0;
    state.opencode_model_options = .empty;
    state.claude_model_options = .empty;
    state.cursor_model_options = .empty;
    state.lifecycle.dirty = false;
    state.lifecycle.last_dirty_at_ms = 0;
    state.lifecycle.last_interaction_at_ms = 0;
    @memset(&state.sidebar_notice_storage, 0);
    defer {
        for (state.project_controller.projects.items) |*project| project.deinit(allocator);
        state.project_controller.projects.deinit(allocator);
    }

    var first = try Project.init(allocator, "first", "First", "/tmp/first", 0);
    state.project_controller.projects.append(allocator, first) catch |err| {
        first.deinit(allocator);
        return err;
    };
    var second = try Project.init(allocator, "second", "Second", "/tmp/second", 0);
    state.project_controller.projects.append(allocator, second) catch |err| {
        second.deinit(allocator);
        return err;
    };

    const first_thread_count = state.project_controller.projects.items[0].threads.items.len;
    const first_pane_count = state.project_controller.projects.items[0].workspace_layout.panes.items.len;
    const second_thread_count = state.project_controller.projects.items[1].threads.items.len;
    const second_pane_count = state.project_controller.projects.items[1].workspace_layout.panes.items.len;
    const second_focused_pane = state.project_controller.projects.items[1].workspace_layout.focused_pane_id;

    try std.testing.expect(state.providerSupportsModel(.opencode, DEFAULT_OPENCODE_MODEL));
    try std.testing.expect(state.providerSupportsModel(.codex, DEFAULT_CODEX_MODEL));
    try std.testing.expect(state.providerSupportsModel(.claude, DEFAULT_CLAUDE_MODEL));
    try std.testing.expect(state.providerSupportsModel(.cursor, DEFAULT_CURSOR_MODEL));

    const result = try state.openWorkspaceChat(1, .{
        .provider = .cursor,
        .model_ref = "composer-2",
        .target_pane_id = 1,
        .axis = .vertical,
        .focus = false,
    });
    try std.testing.expectEqual(@as(usize, 0), state.project_controller.selected_index);
    try std.testing.expectEqual(first_thread_count, state.project_controller.projects.items[0].threads.items.len);
    try std.testing.expectEqual(first_pane_count, state.project_controller.projects.items[0].workspace_layout.panes.items.len);
    try std.testing.expectEqual(second_thread_count + 1, state.project_controller.projects.items[1].threads.items.len);
    try std.testing.expectEqual(second_pane_count + 1, state.project_controller.projects.items[1].workspace_layout.panes.items.len);
    try std.testing.expectEqual(second_focused_pane, state.project_controller.projects.items[1].workspace_layout.focused_pane_id);
    try std.testing.expect(!result.focused);
    const thread = &state.project_controller.projects.items[1].threads.items[result.thread_index];
    try std.testing.expectEqual(Provider.cursor, thread.provider);
    try std.testing.expectEqualStrings("composer-2", thread.model_ref.?);

    const default_cases = [_]struct {
        provider: Provider,
        model: []const u8,
    }{
        .{ .provider = .opencode, .model = state.cachedDefaultModelRefForProvider(.opencode) },
        .{ .provider = .codex, .model = DEFAULT_CODEX_MODEL },
        .{ .provider = .claude, .model = DEFAULT_CLAUDE_MODEL },
        .{ .provider = .cursor, .model = DEFAULT_CURSOR_MODEL },
    };
    for (default_cases) |case| {
        const default_result = try state.openWorkspaceChat(1, .{
            .provider = case.provider,
            .target_pane_id = 1,
            .focus = false,
        });
        const default_thread = &state.project_controller.projects.items[1].threads.items[default_result.thread_index];
        try std.testing.expectEqual(case.provider, default_thread.provider);
        try std.testing.expectEqualStrings(case.model, default_thread.model_ref.?);
        if (case.provider == .codex) {
            try std.testing.expectEqual(DEFAULT_CODEX_REASONING_EFFORT, default_thread.reasoning_effort.?);
        } else {
            try std.testing.expect(default_thread.reasoning_effort == null);
        }
        try std.testing.expect(default_thread.opencode_reasoning_variant == null);
        try std.testing.expectEqual(FastMode.off, default_thread.fast_mode);
    }

    const configured_result = try state.openWorkspaceChat(1, .{
        .provider = .codex,
        .reasoning_effort = .medium,
        .fast_mode = .off,
        .target_pane_id = 1,
        .focus = false,
    });
    const configured_thread = &state.project_controller.projects.items[1].threads.items[configured_result.thread_index];
    try std.testing.expectEqual(ReasoningEffort.medium, configured_thread.reasoning_effort.?);
    try std.testing.expectEqual(FastMode.off, configured_thread.fast_mode);
    try std.testing.expect(state.lifecycle.dirty);

    const persisted_result = try state.openWorkspaceChat(1, .{
        .provider = .codex,
        .reasoning_effort = .high,
        .fast_mode = .on,
        .target_pane_id = 1,
        .focus = false,
    });
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const persisted = try persistence.threadSnapshot(
        arena.allocator(),
        &state.project_controller.projects.items[1].threads.items[persisted_result.thread_index],
    );
    try std.testing.expectEqual(ReasoningEffort.high, persisted.reasoning_effort.?);
    try std.testing.expectEqual(FastMode.on, persisted.fast_mode.?);
    try std.testing.expect(persisted.reasoning_variant == null);

    const thread_count_before_rejection = state.project_controller.projects.items[1].threads.items.len;
    const pane_count_before_rejection = state.project_controller.projects.items[1].workspace_layout.panes.items.len;
    try std.testing.expectError(error.InvalidModel, state.openWorkspaceChat(1, .{
        .provider = .codex,
        .model_ref = "composer-2",
        .target_pane_id = 1,
    }));
    try std.testing.expectEqual(thread_count_before_rejection, state.project_controller.projects.items[1].threads.items.len);
    try std.testing.expectEqual(pane_count_before_rejection, state.project_controller.projects.items[1].workspace_layout.panes.items.len);

    try std.testing.expectError(error.UnsupportedReasoningEffort, state.openWorkspaceChat(1, .{
        .provider = .codex,
        .reasoning_effort = .max,
        .target_pane_id = 1,
    }));
    try std.testing.expectError(error.UnsupportedReasoningEffort, state.openWorkspaceChat(1, .{
        .provider = .opencode,
        .reasoning_effort = .medium,
        .target_pane_id = 1,
    }));
    try std.testing.expectError(error.UnsupportedReasoningVariant, state.openWorkspaceChat(1, .{
        .provider = .codex,
        .reasoning_variant = "high",
        .target_pane_id = 1,
    }));
    try std.testing.expectError(error.ConflictingReasoningSettings, state.openWorkspaceChat(1, .{
        .provider = .codex,
        .reasoning_effort = .high,
        .reasoning_variant = "high",
        .target_pane_id = 1,
    }));
    try std.testing.expectError(error.UnsupportedFastMode, state.openWorkspaceChat(1, .{
        .provider = .opencode,
        .fast_mode = .off,
        .target_pane_id = 1,
    }));
    try std.testing.expectEqual(thread_count_before_rejection, state.project_controller.projects.items[1].threads.items.len);
    try std.testing.expectEqual(pane_count_before_rejection, state.project_controller.projects.items[1].workspace_layout.panes.items.len);

    try std.testing.expectError(error.TargetPaneNotFound, state.openWorkspaceChat(1, .{
        .provider = .codex,
        .target_pane_id = 999,
    }));
    try std.testing.expectEqual(thread_count_before_rejection, state.project_controller.projects.items[1].threads.items.len);
    try std.testing.expectEqual(pane_count_before_rejection, state.project_controller.projects.items[1].workspace_layout.panes.items.len);
}

test "provider-aware chat creation focuses requested pane" {
    const allocator = std.testing.allocator;
    var project = try Project.init(allocator, "test", "Test", "/tmp/test", 0);
    defer project.deinit(allocator);

    const cases = [_]struct {
        provider: Provider,
        model: []const u8,
    }{
        .{ .provider = .opencode, .model = DEFAULT_OPENCODE_MODEL },
        .{ .provider = .codex, .model = DEFAULT_CODEX_MODEL },
        .{ .provider = .claude, .model = DEFAULT_CLAUDE_MODEL },
        .{ .provider = .cursor, .model = DEFAULT_CURSOR_MODEL },
    };
    const previous_pane_count = project.workspace_layout.panes.items.len;
    for (cases) |case| {
        const result = try AppState.createWorkspaceChatPane(
            &project,
            allocator,
            case.provider,
            case.model,
            .{
                .reasoning_effort = if (case.provider == .codex) DEFAULT_CODEX_REASONING_EFFORT else null,
                .reasoning_variant = null,
                .fast_mode = .off,
            },
            null,
            .horizontal,
            true,
        );
        try std.testing.expect(result.focused);
        try std.testing.expectEqual(@as(?WorkspacePaneId, result.pane_id), project.workspace_layout.focused_pane_id);
        try std.testing.expectEqual(result.thread_index, project.selected_thread_index);
        try std.testing.expectEqual(case.provider, project.threads.items[result.thread_index].provider);
        try std.testing.expectEqualStrings(case.model, project.threads.items[result.thread_index].model_ref.?);
    }
    try std.testing.expectEqual(previous_pane_count + cases.len, project.workspace_layout.panes.items.len);
}

test "focused chat creation transfers zoom to the new pane" {
    const allocator = std.testing.allocator;
    var project = try Project.init(allocator, "test", "Test", "/tmp/test", 0);
    defer project.deinit(allocator);

    const initial_pane_id = project.workspace_layout.focused_pane_id orelse return error.TestExpectedEqual;
    project.workspace_layout.maximized_pane_id = initial_pane_id;

    const zoomed_result = try AppState.createWorkspaceChatPane(
        &project,
        allocator,
        .codex,
        DEFAULT_CODEX_MODEL,
        .{
            .reasoning_effort = DEFAULT_CODEX_REASONING_EFFORT,
            .reasoning_variant = null,
            .fast_mode = .off,
        },
        initial_pane_id,
        .vertical,
        true,
    );
    try std.testing.expectEqual(@as(?WorkspacePaneId, zoomed_result.pane_id), project.workspace_layout.focused_pane_id);
    try std.testing.expectEqual(@as(?WorkspacePaneId, zoomed_result.pane_id), project.workspace_layout.maximized_pane_id);

    project.workspace_layout.maximized_pane_id = null;
    const unzoomed_result = try AppState.createWorkspaceChatPane(
        &project,
        allocator,
        .codex,
        DEFAULT_CODEX_MODEL,
        .{
            .reasoning_effort = DEFAULT_CODEX_REASONING_EFFORT,
            .reasoning_variant = null,
            .fast_mode = .off,
        },
        zoomed_result.pane_id,
        .horizontal,
        true,
    );
    try std.testing.expectEqual(@as(?WorkspacePaneId, unzoomed_result.pane_id), project.workspace_layout.focused_pane_id);
    try std.testing.expect(project.workspace_layout.maximized_pane_id == null);
}

test "sidebar open pane focus keeps the clicked terminal pane maximized" {
    const allocator = std.testing.allocator;
    var state: AppState = undefined;
    state.allocator = allocator;
    state.project_controller.projects = .empty;
    state.surface_controller.surfaces = .empty;
    state.project_controller.selected_index = 0;
    state.browser_controller.runtime = try browser_runtime.State.init(allocator);
    state.browser_controller.runtime_project_index = null;
    state.browser_controller.pane_focused = false;
    state.browser_controller.address_focused = true;
    state.terminal_controller.focused = false;
    state.composer_controller.focused = true;
    state.composer_controller.composer = PaletteComposerPrompt.init();
    state.composer_controller.composer.focused = true;
    state.composer_controller.model_picker = PaletteModelPicker.init(0);
    state.composer_controller.popover_restore_focus = false;
    state.composer_controller.run_config_open = false;
    state.palette_modal_text_focus = .none;
    state.lifecycle.dirty = false;
    state.lifecycle.last_dirty_at_ms = 0;
    state.lifecycle.last_interaction_at_ms = 0;
    @memset(&state.rename_storage, 0);
    @memset(&state.sidebar_notice_storage, 0);
    defer {
        for (state.project_controller.projects.items) |*project| project.deinit(allocator);
        state.project_controller.projects.deinit(allocator);
        state.surface_controller.surfaces.deinit(allocator);
        state.composer_controller.composer.deinit(allocator);
        state.browser_controller.deinit(allocator);
    }

    var project = try Project.init(allocator, "test", "Test", "/tmp/test", 0);
    state.project_controller.projects.append(allocator, project) catch |err| {
        project.deinit(allocator);
        return err;
    };
    const layout = &state.project_controller.projects.items[0].workspace_layout;
    const chat_pane_id = layout.panes.items[0].id;
    const first_terminal_pane_id = try layout.createTerminalPane(allocator, 1);
    const clicked_terminal_pane_id = try layout.createTerminalPane(allocator, 2);
    layout.focused_pane_id = first_terminal_pane_id;
    layout.maximized_pane_id = first_terminal_pane_id;

    state.focusWorkspaceOpenPaneFromSidebar(0, clicked_terminal_pane_id);

    try std.testing.expectEqual(@as(?WorkspacePaneId, clicked_terminal_pane_id), layout.focused_pane_id);
    try std.testing.expectEqual(@as(?WorkspacePaneId, clicked_terminal_pane_id), layout.maximized_pane_id);
    try std.testing.expect(state.terminal_controller.focused);
    try std.testing.expect(!state.composer_controller.focused);
    try std.testing.expect(!state.composer_controller.composer.focused);
    try std.testing.expect(!state.browser_controller.address_focused);

    try std.testing.expect(state.focusCurrentProjectWorkspacePaneInSidebarOrder(1));
    try std.testing.expectEqual(@as(?WorkspacePaneId, chat_pane_id), layout.focused_pane_id);
    try std.testing.expectEqual(@as(?WorkspacePaneId, chat_pane_id), layout.maximized_pane_id);
    try std.testing.expect(state.composer_controller.focused);
    try std.testing.expect(state.composer_controller.composer.focused);
    try std.testing.expect(!state.terminal_controller.focused);
    try std.testing.expect(state.focusCurrentProjectWorkspacePaneInSidebarOrder(-1));
    try std.testing.expectEqual(@as(?WorkspacePaneId, clicked_terminal_pane_id), layout.focused_pane_id);
    try std.testing.expectEqual(@as(?WorkspacePaneId, clicked_terminal_pane_id), layout.maximized_pane_id);
    try std.testing.expect(state.terminal_controller.focused);
    try std.testing.expect(!state.composer_controller.focused);
    try std.testing.expect(!state.composer_controller.composer.focused);
    try std.testing.expect(state.focusCurrentProjectWorkspacePaneInSidebarOrder(-1));
    try std.testing.expectEqual(@as(?WorkspacePaneId, first_terminal_pane_id), layout.focused_pane_id);
    try std.testing.expectEqual(@as(?WorkspacePaneId, first_terminal_pane_id), layout.maximized_pane_id);
    try std.testing.expect(state.focusCurrentProjectWorkspacePaneAtSidebarIndex(2));
    try std.testing.expectEqual(@as(?WorkspacePaneId, clicked_terminal_pane_id), layout.focused_pane_id);
    try std.testing.expectEqual(@as(?WorkspacePaneId, clicked_terminal_pane_id), layout.maximized_pane_id);
    try std.testing.expect(!state.focusCurrentProjectWorkspacePaneAtSidebarIndex(3));

    layout.quick_pane = .{
        .pane_id = clicked_terminal_pane_id,
        .visible = false,
        .detached = true,
        .return_focus_pane_id = chat_pane_id,
    };
    layout.focused_pane_id = chat_pane_id;
    layout.maximized_pane_id = chat_pane_id;
    state.focusWorkspaceOpenPaneFromSidebar(0, clicked_terminal_pane_id);
    try std.testing.expect(layout.quick_pane.?.visible);
    try std.testing.expectEqual(@as(?WorkspacePaneId, clicked_terminal_pane_id), layout.focused_pane_id);
    try std.testing.expectEqual(@as(?WorkspacePaneId, chat_pane_id), layout.maximized_pane_id);
    try std.testing.expect(!layout.rootContainsPane(clicked_terminal_pane_id));
    try std.testing.expect(state.terminal_controller.focused);
    try std.testing.expect(state.isTerminalVisible());
    try std.testing.expect(state.canRouteTerminalInput());

    state.focusWorkspaceOpenPaneFromSidebar(0, chat_pane_id);
    try std.testing.expect(!layout.quick_pane.?.visible);
    try std.testing.expectEqual(@as(?WorkspacePaneId, chat_pane_id), layout.quick_pane.?.return_focus_pane_id);
    try std.testing.expectEqual(@as(?WorkspacePaneId, chat_pane_id), layout.focused_pane_id);
    try std.testing.expectEqual(@as(?WorkspacePaneId, chat_pane_id), layout.maximized_pane_id);
    try std.testing.expect(!layout.rootContainsPane(clicked_terminal_pane_id));
    try std.testing.expect(!state.terminal_controller.focused);
    try std.testing.expect(!state.canRouteTerminalInput());

    state.focusWorkspaceOpenPaneFromSidebar(0, clicked_terminal_pane_id);
    try std.testing.expect(layout.quick_pane.?.visible);
    try std.testing.expectEqual(@as(?WorkspacePaneId, clicked_terminal_pane_id), layout.focused_pane_id);
    try std.testing.expect(state.terminal_controller.focused);
    try std.testing.expect(state.canRouteTerminalInput());
    layout.quick_pane = null;

    const result = try state.openWorkspaceChat(0, .{
        .provider = .codex,
        .model_ref = DEFAULT_CODEX_MODEL,
        .target_pane_id = chat_pane_id,
        .axis = .vertical,
    });
    try std.testing.expect(result.focused);
    try std.testing.expectEqual(@as(?WorkspacePaneId, result.pane_id), layout.focused_pane_id);
    try std.testing.expect(state.composer_controller.focused);
    try std.testing.expect(state.composer_controller.composer.focused);
    try std.testing.expect(!state.terminal_controller.focused);

    try std.testing.expect(state.focusCurrentProjectWorkspacePane(clicked_terminal_pane_id));
    try std.testing.expect(state.closeCurrentProjectWorkspacePane(clicked_terminal_pane_id));
    try std.testing.expectEqual(@as(?WorkspacePaneId, chat_pane_id), layout.focused_pane_id);
    try std.testing.expect(state.composer_controller.focused);
    try std.testing.expect(state.composer_controller.composer.focused);
    try std.testing.expect(!state.terminal_controller.focused);
}

test "sidebar pane selection restores a sibling browser URL snapshot" {
    const allocator = std.testing.allocator;
    var state: AppState = undefined;
    state.allocator = allocator;
    state.project_controller.projects = .empty;
    state.surface_controller.surfaces = .empty;
    state.project_controller.selected_index = 0;
    state.browser_controller.runtime = try browser_runtime.State.init(allocator);
    state.browser_controller.runtime_project_index = null;
    state.browser_textures_enabled = false;
    state.browser_controller.pane_focused = false;
    state.browser_controller.address_focused = false;
    state.terminal_controller.focused = false;
    state.composer_controller.focused = true;
    state.composer_controller.composer = PaletteComposerPrompt.init();
    state.composer_controller.composer.focused = true;
    state.composer_controller.model_picker = PaletteModelPicker.init(0);
    state.composer_controller.popover_restore_focus = false;
    state.composer_controller.run_config_open = false;
    state.palette_modal_text_focus = .none;
    state.lifecycle.dirty = false;
    state.lifecycle.last_dirty_at_ms = 0;
    state.lifecycle.last_interaction_at_ms = 0;
    defer {
        for (state.project_controller.projects.items) |*project| project.deinit(allocator);
        state.project_controller.projects.deinit(allocator);
        state.surface_controller.surfaces.deinit(allocator);
        state.composer_controller.composer.deinit(allocator);
        state.browser_controller.deinit(allocator);
    }

    var project = try Project.init(allocator, "test", "Test", "/tmp/test", 0);
    state.project_controller.projects.append(allocator, project) catch |err| {
        project.deinit(allocator);
        return err;
    };
    const layout = &state.project_controller.projects.items[0].workspace_layout;
    const chat_pane_id = layout.panes.items[0].id;
    const browser_pane_id = try layout.ensureBrowserPane(allocator);
    const browser_ref = state.browserPaneRefMutable(0, browser_pane_id) orelse return error.TestExpectedEqual;
    try browser_ref.activeTab().?.recordNavigation(allocator, "https://example.com/restored");
    layout.focused_pane_id = chat_pane_id;

    state.focusWorkspaceOpenPaneFromSidebar(0, chat_pane_id);

    try std.testing.expectEqualStrings("https://example.com/restored", state.browser_controller.runtime.current_url.?);
    try std.testing.expectEqualStrings("https://example.com/restored", state.browser_controller.runtime.addressInput());

    state.focusWorkspaceOpenPaneFromSidebar(0, browser_pane_id);

    try std.testing.expect(state.browser_controller.pane_focused);
    try std.testing.expect(!state.browser_controller.address_focused);
    try std.testing.expect(!state.terminal_controller.focused);
    try std.testing.expect(!state.composer_controller.focused);
    try std.testing.expect(!state.composer_controller.composer.focused);
}

test "workspace selection restores focused pane keyboard ownership" {
    const allocator = std.testing.allocator;
    var state: AppState = undefined;
    state.allocator = allocator;
    state.project_controller.projects = .empty;
    state.surface_controller.surfaces = .empty;
    state.project_controller.selected_index = 0;
    state.browser_controller.runtime = try browser_runtime.State.init(allocator);
    state.browser_controller.runtime_project_index = null;
    state.browser_controller.pane_focused = false;
    state.browser_controller.address_focused = false;
    state.terminal_controller.focused = false;
    state.composer_controller.focused = false;
    state.composer_controller.composer = PaletteComposerPrompt.init();
    state.composer_controller.model_picker = PaletteModelPicker.init(0);
    state.composer_controller.popover_restore_focus = false;
    state.composer_controller.run_config_open = false;
    state.palette_modal_text_focus = .none;
    state.workspace_header_open_menu_open = false;
    state.workspace_header_open_menu_pane_id = null;
    state.sidebar_context_menu_open = false;
    state.lifecycle.dirty = false;
    state.lifecycle.last_dirty_at_ms = 0;
    state.lifecycle.last_interaction_at_ms = 0;
    @memset(&state.rename_storage, 0);
    defer {
        for (state.project_controller.projects.items) |*project| project.deinit(allocator);
        state.project_controller.projects.deinit(allocator);
        state.surface_controller.surfaces.deinit(allocator);
        state.composer_controller.composer.deinit(allocator);
        state.browser_controller.deinit(allocator);
    }

    var chat_project = try Project.init(allocator, "chat", "Chat", "/tmp/chat", 0);
    state.project_controller.projects.append(allocator, chat_project) catch |err| {
        chat_project.deinit(allocator);
        return err;
    };
    var terminal_project = try Project.init(allocator, "terminal", "Terminal", "/tmp/terminal", 0);
    const terminal_pane_id = try terminal_project.workspace_layout.createTerminalPane(allocator, 9);
    try terminal_project.workspace_layout.ensurePaneInRootSplit(allocator, terminal_pane_id, .vertical, 0.5);
    terminal_project.workspace_layout.focused_pane_id = terminal_pane_id;
    state.project_controller.projects.append(allocator, terminal_project) catch |err| {
        terminal_project.deinit(allocator);
        return err;
    };

    try std.testing.expect(state.selectProjectAtIndex(1));
    try std.testing.expectEqual(@as(usize, 1), state.project_controller.selected_index);
    try std.testing.expect(state.terminal_controller.focused);
    try std.testing.expect(!state.composer_controller.focused);
    try std.testing.expect(!state.composer_controller.composer.focused);

    try std.testing.expect(state.selectProjectAtIndex(0));
    try std.testing.expectEqual(@as(usize, 0), state.project_controller.selected_index);
    try std.testing.expect(!state.terminal_controller.focused);
    try std.testing.expect(state.composer_controller.focused);
    try std.testing.expect(state.composer_controller.composer.focused);
}

test "visible chat is not treated as focused when a sibling pane owns focus" {
    const allocator = std.testing.allocator;
    var state: AppState = undefined;
    state.allocator = allocator;
    state.project_controller.projects = .empty;
    state.project_controller.selected_index = 0;
    state.window_input_focus = true;
    defer {
        for (state.project_controller.projects.items) |*project| project.deinit(allocator);
        state.project_controller.projects.deinit(allocator);
    }

    var project = try Project.init(allocator, "test", "Test", "/tmp/test", 0);
    state.project_controller.projects.append(allocator, project) catch |err| {
        project.deinit(allocator);
        return err;
    };

    const layout = &state.project_controller.projects.items[0].workspace_layout;
    const chat_pane_id = layout.panes.items[0].id;
    const terminal_pane_id = try layout.createTerminalPane(allocator, 1);
    layout.focused_pane_id = terminal_pane_id;

    try std.testing.expect(!state.isChatThreadFocused(0, 0));
    layout.focused_pane_id = chat_pane_id;
    try std.testing.expect(state.isChatThreadFocused(0, 0));
    state.window_input_focus = false;
    try std.testing.expect(!state.isChatThreadFocused(0, 0));
}

test "Codex hook feature detection accepts current and legacy names" {
    try std.testing.expect(AppState.containsCodexHooksFeature("features.hooks=true"));
    try std.testing.expect(AppState.containsCodexHooksFeature("features.codex_hooks=false"));
    try std.testing.expect(!AppState.containsCodexHooksFeature("features.goals=true"));

    const current_argv = [_][]const u8{ "codex", "-c", "features.hooks=true" };
    const legacy_argv = [_][]const u8{ "codex", "--config=features.codex_hooks=true" };
    try std.testing.expect(AppState.argvContainsCodexHooksFeature(&current_argv));
    try std.testing.expect(AppState.argvContainsCodexHooksFeature(&legacy_argv));
}

test "removing a managed process dock clears its stale association" {
    const allocator = std.testing.allocator;
    var project = try Project.init(allocator, "test", "Test", "/tmp", 0);
    defer project.deinit(allocator);

    var dock = try terminal.Dock.init(allocator);
    project.terminal_docks.append(allocator, .{ .id = 2, .dock = dock }) catch |err| {
        dock.deinit(allocator);
        return err;
    };

    var process: ManagedProcess = .{
        .name = try allocator.dupe(u8, "matchit"),
        .kind = .process,
        .command = try allocator.dupe(u8, "bun run matchit"),
        .cwd = try allocator.dupe(u8, "."),
        .restart = .manual,
        .status = .running,
        .dock_id = 2,
        .pane_id = 39,
    };
    project.managed_processes.append(allocator, process) catch |err| {
        process.deinit(allocator);
        return err;
    };

    try std.testing.expect(project.removeTerminalDockById(allocator, 2));
    const detached = project.managedProcessByName("matchit") orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(ManagedProcessStatus.stopped, detached.status);
    try std.testing.expect(detached.dock_id == null);
    try std.testing.expect(detached.pane_id == null);
    try std.testing.expect(detached.explicit_stop);
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
    state.lifecycle.dirty = false;
    state.lifecycle.last_dirty_at_ms = 0;
    state.lifecycle.last_interaction_at_ms = 0;

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

test "dev server URL detection accepts loopback URLs only" {
    try std.testing.expectEqualStrings(
        "http://localhost:5173/app",
        AppState.localDevServerUrl("ready at http://localhost:5173/app\n").?,
    );
    try std.testing.expectEqualStrings(
        "https://127.0.0.1:8443",
        AppState.localDevServerUrl("Local: https://127.0.0.1:8443, press h for help").?,
    );
    try std.testing.expect(AppState.localDevServerUrl("docs: https://example.com") == null);
    try std.testing.expect(AppState.localDevServerUrl("bad: http://localhost.example.com:5173") == null);
    try std.testing.expect(AppState.localDevServerUrl("bad: http://127.0.0.11:5173") == null);
}

test "workspace commands classify conservatively and infer shared resources" {
    try std.testing.expectEqual(CommandClass.build, classifyWorkspaceCommand("mise run build"));
    try std.testing.expectEqual(CommandClass.@"test", classifyWorkspaceCommand("bun test packages/desktop"));
    try std.testing.expectEqual(CommandClass.formatter, classifyWorkspaceCommand("zig fmt src/main.zig"));
    try std.testing.expectEqual(CommandClass.package_install, classifyWorkspaceCommand("pnpm install"));
    try std.testing.expectEqual(CommandClass.migration, classifyWorkspaceCommand("rails db:migrate"));
    try std.testing.expectEqual(CommandClass.dev_server, classifyWorkspaceCommand("npm run dev"));
    try std.testing.expectEqual(CommandClass.other, classifyWorkspaceCommand("rg TODO src"));
    try std.testing.expectEqual(CommandClass.other, classifyWorkspaceCommand("cat build/log.txt"));
    try std.testing.expectEqualStrings("build", inferredWorkspaceResource("cargo test").?);
    try std.testing.expect(inferredWorkspaceResource("rg TODO src") == null);
    const build_resources = [_][]const u8{ "build", "port:3000" };
    const build_request = [_][]const u8{"build"};
    const dependency_resources = [_][]const u8{"deps"};
    const database_resources = [_][]const u8{"db"};
    try std.testing.expect(workspaceResourcesOverlap(build_resources[0..], build_request[0..]));
    try std.testing.expect(!workspaceResourcesOverlap(dependency_resources[0..], database_resources[0..]));
}

test "workspace leases reject conflicts, renew, expire, and enforce ownership" {
    const allocator = std.testing.allocator;
    var state: AppState = undefined;
    state.allocator = allocator;
    state.project_controller.projects = .empty;
    defer {
        for (state.project_controller.projects.items) |*project| project.deinit(allocator);
        state.project_controller.projects.deinit(allocator);
    }

    var project = try Project.init(allocator, "lease-test", "Lease test", "/tmp/lease-test", 0);
    state.project_controller.projects.append(allocator, project) catch |err| {
        project.deinit(allocator);
        return err;
    };

    const resources = [_][]const u8{"build"};
    const first = try state.acquireWorkspaceLease(0, "agent-a", "mise run build", &resources, 60_000, false);
    const first_expiry = first.expires_at_ms;
    try std.testing.expectEqualStrings("lease:1", first.id);
    try std.testing.expectError(error.LeaseConflict, state.acquireWorkspaceLease(0, "agent-b", "cargo test", &resources, 60_000, false));

    const renewed = try state.acquireWorkspaceLease(0, "agent-a", "cargo test", &resources, 120_000, false);
    try std.testing.expectEqualStrings("lease:1", renewed.id);
    try std.testing.expect(renewed.expires_at_ms >= first_expiry);
    try std.testing.expectEqual(@as(usize, 0), state.releaseWorkspaceLease(0, "agent-b", renewed.id));
    try std.testing.expectEqual(@as(usize, 1), state.releaseWorkspaceLease(0, "agent-a", renewed.id));

    const expiring = try state.acquireWorkspaceLease(0, "agent-a", "mise run build", &resources, 60_000, false);
    expiring.expires_at_ms = 0;
    try std.testing.expectEqual(@as(usize, 0), state.activeWorkspaceLeaseCount(0));
}

test "terminal teardown releases leases for only the exact session owner" {
    const allocator = std.testing.allocator;
    var state: AppState = undefined;
    state.allocator = allocator;
    state.project_controller.projects = .empty;
    defer {
        for (state.project_controller.projects.items) |*project| project.deinit(allocator);
        state.project_controller.projects.deinit(allocator);
    }

    var project = try Project.init(allocator, "lease-owner-test", "Lease owner test", "/tmp/lease-owner-test", 0);
    state.project_controller.projects.append(allocator, project) catch |err| {
        project.deinit(allocator);
        return err;
    };

    const build = [_][]const u8{"build"};
    const dependencies = [_][]const u8{"deps"};
    const database = [_][]const u8{"db"};
    _ = try state.acquireWorkspaceLease(0, "verde:workspace:dock:4:pane:1", "mise run build", &build, 60_000, false);
    _ = try state.acquireWorkspaceLease(0, "verde:workspace:dock:4:pane:1", "pnpm install", &dependencies, 60_000, false);
    _ = try state.acquireWorkspaceLease(0, "verde:workspace:dock:4:pane:10", "rails db:migrate", &database, 60_000, false);

    try std.testing.expectEqual(
        @as(usize, 2),
        state.releaseWorkspaceLeasesForTerminalOwner(0, "verde:workspace:dock:4:pane:1"),
    );
    try std.testing.expectEqual(@as(usize, 1), state.activeWorkspaceLeaseCount(0));
    try std.testing.expectEqualStrings(
        "verde:workspace:dock:4:pane:10",
        state.project_controller.projects.items[0].workspace_leases.items[0].owner,
    );
}

test "terminal teardown prefers the revived live session owner" {
    const allocator = std.testing.allocator;
    var state: AppState = undefined;
    state.allocator = allocator;
    state.project_controller.projects = .empty;
    defer {
        for (state.project_controller.projects.items) |*project| project.deinit(allocator);
        state.project_controller.projects.deinit(allocator);
    }

    var project = try Project.init(allocator, "lease-revive-test", "Lease revive test", "/tmp/lease-revive-test", 0);
    state.project_controller.projects.append(allocator, project) catch |err| {
        project.deinit(allocator);
        return err;
    };

    const build = [_][]const u8{"build"};
    const dependencies = [_][]const u8{"deps"};
    _ = try state.acquireWorkspaceLease(0, "persisted-session", "old build", &build, 60_000, false);
    _ = try state.acquireWorkspaceLease(0, "live-session", "live dependencies", &dependencies, 60_000, false);

    const owner = terminal.preferredTeardownSessionId("live-session", "persisted-session").?;
    try std.testing.expectEqualStrings("live-session", owner);
    try std.testing.expectEqual(@as(usize, 1), state.releaseWorkspaceLeasesForTerminalOwner(0, owner));
    try std.testing.expectEqual(@as(usize, 1), state.activeWorkspaceLeaseCount(0));
    try std.testing.expectEqualStrings(
        "persisted-session",
        state.project_controller.projects.items[0].workspace_leases.items[0].owner,
    );
}

test "daemon diff event becomes a persisted live timeline event" {
    var send_state: SendState = .{};
    defer freePendingTimelineEvents(std.heap.page_allocator, &send_state.pending_events);
    defer freePendingDiffFiles(std.heap.page_allocator, &send_state.pending_diff_files);

    try AppState.applyDaemonDiffEventLocked(
        &send_state,
        "{\"files\":[{\"path\":\"src/main.zig\",\"additions\":1,\"deletions\":1,\"patch\":\"@@ -1 +1 @@\\n-old\\n+new\\n\"}]}",
    );

    try std.testing.expectEqual(@as(usize, 1), send_state.pending_diff_files.items.len);
    try std.testing.expectEqualStrings("src/main.zig", send_state.pending_diff_files.items[0].path);
    try std.testing.expectEqual(@as(usize, 1), send_state.pending_events.items.len);
    try std.testing.expect(utils.isPersistedDiffBody(send_state.pending_events.items[0].body));
    try std.testing.expect(std.mem.indexOf(u8, send_state.pending_events.items[0].body, "+new") != null);
}

fn unixTimestampSeconds() i64 {
    return @divTrunc(unixTimestampMs(), std.time.ms_per_s);
}

fn monotonicMs() i64 {
    return @intCast(@divTrunc(profiler.nowNs(), std.time.ns_per_ms));
}

fn unixTimestampMs() i64 {
    return platform_runtime.unixTimestampMs();
}

test "inspector disabled lifecycle messages are distinguished from other events" {
    try std.testing.expect(AppState.isInspectorDisabledMessage("{\"source\":\"verde-inspector\",\"type\":\"inspector:disabled\"}"));
    try std.testing.expect(!AppState.isInspectorDisabledMessage("{\"source\":\"verde-inspector\",\"type\":\"inspector:enabled\"}"));
}

test "browser context-menu payload retains an optional link disposition target" {
    const allocator = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(
        BrowserContextMenuPayload,
        allocator,
        "{\"x\":12,\"y\":18,\"link_url\":\"https://example.com/docs\",\"items\":[]}",
        .{ .allocate = .alloc_always },
    );
    defer parsed.deinit();
    try std.testing.expectEqualStrings("https://example.com/docs", parsed.value.link_url.?);
}
