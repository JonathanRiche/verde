const std = @import("std");
const palette = @import("palette");
const sdl = @import("zsdl3");
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
const runtime_log = @import("runtime_log.zig");
const stb_image = @import("stb_image.zig");
const terminal = @import("terminal/terminal.zig");
const theme = @import("ui/theme.zig");
const utils = @import("utils.zig");

/// Same UI font as `main.zig` / `palette_text_gl_draw` (stbtt metrics for layout).
const palette_ui_ttf = @embedFile("assets/fonts/CalSans-Regular.ttf");

extern fn palette_text_gl_measure_codepoint_width(
    font_data: [*]const u8,
    font_len: i32,
    codepoint: i32,
    font_size: f32,
) callconv(.c) f32;

extern fn palette_text_gl_measure_line_width(
    font_data: [*]const u8,
    font_len: i32,
    text: [*]const u8,
    text_len: i32,
    font_size: f32,
) callconv(.c) f32;

/// Width of `text[0..end]` in pixels using the same rules as GL UI text (`palette_text_gl_draw`).
pub fn paletteUiTextPrefixWidth(text: []const u8, font_size: f32, end: usize) f32 {
    const n = @min(end, text.len);
    if (n == 0) return 0.0;
    return palette_text_gl_measure_line_width(
        palette_ui_ttf.ptr,
        @intCast(palette_ui_ttf.len),
        text.ptr,
        @intCast(n),
        font_size,
    );
}

pub const ReasoningEffort = db_types.ReasoningEffort;
pub const FastMode = db_types.FastMode;
pub const AccessMode = db_types.AccessMode;
pub const ChatRole = db_types.ChatRole;
pub const Provider = db_types.Provider;
pub const Harness = db_types.Harness;

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
};

pub const PaletteModalHit = struct {
    rect: palette.Rect,
    action: PaletteModalAction,
    index: usize = 0,
};

pub const PaletteModalTextFocus = enum {
    none,
    project_rename,
    thread_import,
    project_import,
};

const PALETTE_COMPOSER_FONT_SIZE: f32 = 32.0;
const PALETTE_COMPOSER_TOOLBAR_FONT_SIZE: f32 = 26.0;
const PALETTE_COMPOSER_ICON_FONT_SIZE: f32 = 30.0;

pub const PaletteComposerPrompt = palette.composerPrompt(.{
    .padding_x = 24.0,
    .padding_y = 20.0,
    .toolbar_height = 48.0,
    .toolbar_gap = 14.0,
    .control_gap = 14.0,
    .pill_padding_x = 16.0,
    .pill_icon_gap = 10.0,
    .pill_chevron_gap = 10.0,
    .model_min_width = 138.0,
    // Long OpenCode labels include the provider, e.g. "GPT-5.4 (OpenAI)"; cap high enough for measured pill width.
    .model_max_width = 420.0,
    .reasoning_min_width = 92.0,
    .reasoning_max_width = 150.0,
    .fast_min_width = 116.0,
    .fast_max_width = 132.0,
    .access_min_width = 172.0,
    .access_max_width = 192.0,
    .corner_radius = 28.0,
    .border_width = 1.5,
    .background_color = .{ .r = 0.11, .g = 0.15, .b = 0.16, .a = 0.98 },
    .border_color = .{ .r = 0.25, .g = 0.31, .b = 0.34, .a = 1.0 },
    .control_background_color = .{ .r = 0.12, .g = 0.13, .b = 0.16, .a = 0.34 },
    .control_hover_color = .{ .r = 0.16, .g = 0.18, .b = 0.22, .a = 0.78 },
    .separator_color = .{ .r = 0.47, .g = 0.50, .b = 0.56, .a = 0.35 },
    .send_color = .{ .r = 0.25, .g = 0.45, .b = 0.31, .a = 1.0 },
    .send_hover_color = .{ .r = 0.31, .g = 0.52, .b = 0.37, .a = 1.0 },
    .stop_button_color = .{ .r = 0.80, .g = 0.58, .b = 0.10, .a = 1.0 },
    .stop_button_hover_color = .{ .r = 0.92, .g = 0.68, .b = 0.14, .a = 1.0 },
    .text_color = .{ .r = 0.94, .g = 0.96, .b = 0.98, .a = 1.0 },
    .icon_color = .{ .r = 0.70, .g = 0.73, .b = 0.80, .a = 1.0 },
    .selection_color = .{ .r = 0.18, .g = 0.42, .b = 0.72, .a = 0.55 },
    .placeholder_color = .{ .r = 0.39, .g = 0.40, .b = 0.45, .a = 1.0 },
    .font_size = PALETTE_COMPOSER_FONT_SIZE,
    .toolbar_font_size = PALETTE_COMPOSER_TOOLBAR_FONT_SIZE,
    .icon_font_size = PALETTE_COMPOSER_ICON_FONT_SIZE,
    .placeholder = "Ask anything, or use / to show available commands",
    .model_icon = "    ",
    .fast_icon = "    ",
    .access_icon = "    ",
    .chevron_icon = ">",
    .send_icon = "",
    .stop_icon = "x",
});

const COMPOSER_MODEL_CASCADE_WIDTH: f32 = 400.0;
const COMPOSER_MODEL_CASCADE_ROW_HEIGHT: f32 = 40.0;
const COMPOSER_MODEL_CASCADE_PADDING_Y: f32 = 10.0;
const COMPOSER_MODEL_CASCADE_VISIBLE_ROWS: usize = 8;
const COMPOSER_PROVIDER_OPTIONS = [_]Provider{ .codex, .opencode };

fn paletteEstimatedFontAdvance(_: ?*anyopaque, text: []const u8, byte_offset: usize, font_size: f32) palette.FontAdvance {
    if (byte_offset >= text.len) return .{ .byte_len = 0, .width = 0.0 };
    if (text[byte_offset] == '\n') return .{ .byte_len = 1, .width = 0.0 };
    const seq_len = std.unicode.utf8ByteSequenceLength(text[byte_offset]) catch 1;
    const end = @min(byte_offset + seq_len, text.len);
    const cp = std.unicode.utf8Decode(text[byte_offset..end]) catch {
        return .{ .byte_len = 1, .width = @max(font_size * 0.55, 1.0) };
    };
    const w = palette_text_gl_measure_codepoint_width(
        palette_ui_ttf.ptr,
        @intCast(palette_ui_ttf.len),
        @intCast(cp),
        font_size,
    );
    return .{ .byte_len = end - byte_offset, .width = @max(w, 0.0) };
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
    const rows = state.opencode_reasoning_menu.items;
    if (index >= rows.len) return "";
    return rows[index].label;
}

fn composerModelOptions(state: *const AppState, provider: Provider) []const ModelOption {
    return chat_threads.modelOptions(ModelOption, provider, state.opencodeModelOptionsSnapshot(), CODEX_MODEL_OPTIONS[0..]);
}

fn composerDefaultModelRef(state: *const AppState, provider: Provider) [:0]const u8 {
    return switch (provider) {
        .codex => DEFAULT_CODEX_MODEL,
        .opencode => state.cachedDefaultModelRefForProvider(.opencode),
    };
}

fn paletteComposerPromptEvent(context: ?*anyopaque, event: palette.ComposerPromptEvent) void {
    const state = appStateFromContext(context) orelse return;
    switch (event) {
        .text_changed => |text| state.setDraft(text),
        .submitted => {
            if (state.currentThread().isSendPendingForUi()) {
                state.setSidebarNotice("This thread is still running. Press Tab to queue or steer a follow-up.");
                return;
            }
            if (state.acceptPrimaryFileSearchResult()) return;
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
            if (state.currentThread().provider != .codex) return;
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
                state.browser_pane_focused = false;
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
    } orelse return;
    if (!tex.valid or tex.texture_id == 0) return;
    const sz = @min(leading_rect.w, leading_rect.h) * 0.68;
    const ix = leading_rect.x + (leading_rect.w - sz) * 0.5;
    const iy = leading_rect.y + (leading_rect.h - sz) * 0.5;
    const r: palette.Rect = .{ .x = ix, .y = iy, .w = sz, .h = sz };
    batch.image(allocator, r, palette.TextureId.init(tex.texture_id), .{
        .x = 0.0,
        .y = 0.0,
        .w = 1.0,
        .h = 1.0,
    }, .{ .r = 1.0, .g = 1.0, .b = 1.0, .a = 1.0 }, clip) catch {};
}

pub const PaletteModelCascadeMenu = palette.cascadeMenu(.{
    .width = COMPOSER_MODEL_CASCADE_WIDTH,
    .row_height = COMPOSER_MODEL_CASCADE_ROW_HEIGHT,
    .max_visible_rows = COMPOSER_MODEL_CASCADE_VISIBLE_ROWS,
    .max_depth = 2,
    .padding_x = 14.0,
    .padding_y = COMPOSER_MODEL_CASCADE_PADDING_Y,
    .submenu_gap = 8.0,
    .glyph_width = 10.8,
    .font_size = 20.0,
    .chevron_icon = ">",
    .icon_gap = 12.0,
    .row_leading_width = 34.0,
    .row_leading_to_label_gap = 8.0,
    .render_row_leading = paletteModelCascadeRenderRowLeading,
    .background_color = .{ .r = 0.09, .g = 0.10, .b = 0.13, .a = 0.98 },
    .border_color = .{ .r = 0.24, .g = 0.28, .b = 0.34, .a = 1.0 },
    .highlighted_color = .{ .r = 0.18, .g = 0.21, .b = 0.27, .a = 0.94 },
    .text_color = .{ .r = 0.92, .g = 0.94, .b = 0.98, .a = 1.0 },
    .icon_color = .{ .r = 0.67, .g = 0.71, .b = 0.80, .a = 1.0 },
    .scrollbar_track_color = .{ .r = 0.17, .g = 0.19, .b = 0.22, .a = 0.55 },
    .scrollbar_thumb_color = .{ .r = 0.48, .g = 0.54, .b = 0.64, .a = 0.88 },
    .scrollbar_width = 5.0,
    .corner_radius = 14.0,
    .border_width = 1.0,
    .z_index = 200,
    .submenu_z_offset = 10,
    .placement = .above,
    .submenu_placement = .right,
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
pub const DEFAULT_CODEX_MODEL: [:0]const u8 = "gpt-5.5";
pub const DEFAULT_OPENCODE_MODEL: [:0]const u8 = "opencode/gpt-5.4";
pub const IMAGE_MODAL_ID: [:0]const u8 = "AttachmentPreviewModal";
pub const THREAD_IMPORT_MODAL_ID: [:0]const u8 = "ThreadImportModal";
pub const TRANSCRIPT_SELECTION_MODAL_ID: [:0]const u8 = "TranscriptSelectionModal";
pub const VERDE_LOGO_BYTES = @embedFile("assets/verde_logo.png");
pub const OPENCODE_LOGO_BYTES = @embedFile("assets/opencode-logo-dark.png");
pub const CODEX_LOGO_BYTES = @embedFile("assets/OpenAI-white-monoblossom.png");
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
};

const OpencodeReasoningMenuRow = struct {
    label: [:0]const u8,
    /// Null selects the default (no `variant` field on the wire).
    variant: ?[:0]const u8,
};

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
    messages: std.ArrayList(ChatMessage),
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
            .messages = .empty,
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
        @memset(&self.draft_storage, 0);
        const len = @min(value.len, AppState.DRAFT_CAPACITY - 1);
        @memcpy(self.draft_storage[0..len], value[0..len]);
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
        self.send_state.mutex.unlock();

        if (maybe_worker) |worker| {
            worker.join();
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

extern fn glDeleteTextures(n: c_int, textures: [*]const c_uint) void;
pub const CachedImageTexture = struct {
    texture_id: c_uint,
    width: i32,
    height: i32,
    valid: bool,

    fn deinit(self: CachedImageTexture) void {
        if (!self.valid or self.texture_id == 0) return;
        var textures = [_]c_uint{self.texture_id};
        glDeleteTextures(1, &textures);
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
    threads: std.ArrayList(ChatThread),
    archived_threads: std.ArrayList(ChatThread),
    selected_thread_index: usize = 0,
    sidebar_thread_indices: std.ArrayList(usize) = .empty,
    sidebar_committed_thread_count: usize = 0,
    sidebar_thread_cache_dirty: bool = true,

    fn init(allocator: std.mem.Allocator, id: []const u8, label: []const u8, path: []const u8, unread_count: u8) !Project {
        var terminal_dock = try terminal.Dock.init(allocator);
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
            .threads = .empty,
            .archived_threads = .empty,
            .selected_thread_index = 0,
            .sidebar_thread_indices = .empty,
            .sidebar_committed_thread_count = 0,
            .sidebar_thread_cache_dirty = true,
        };
        try project.addThread(allocator);
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

    fn addThread(self: *Project, allocator: std.mem.Allocator) !void {
        var thread = try ChatThread.init(allocator, "New thread");
        errdefer thread.deinit(allocator);
        try self.threads.append(allocator, thread);
        self.selected_thread_index = self.threads.items.len - 1;
    }

    fn normalize(self: *Project, allocator: std.mem.Allocator) !void {
        if (!self.archived and self.threads.items.len == 0) {
            try self.addThread(allocator);
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
    thread,
};

pub const AppState = struct {
    const DRAFT_CAPACITY = 8192;
    const SAVE_DEBOUNCE_MS: i64 = 750;

    allocator: std.mem.Allocator,
    storage: *const Storage,
    projects: std.ArrayList(Project),
    archived_projects: std.ArrayList(Project),
    selected_project_index: usize,
    next_project_number: usize,
    import_path_storage: [DRAFT_CAPACITY:0]u8,
    rename_storage: [256:0]u8,
    sidebar_notice_storage: [256:0]u8,
    import_thread_id_storage: [256:0]u8,
    import_notice_storage: [256:0]u8,
    sidebar_collapsed: bool,
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
    palette_modal_hits: std.ArrayList(PaletteModalHit),
    palette_modal_text_focus: PaletteModalTextFocus,
    project_rename_cursor: usize,
    project_import_cursor: usize,
    thread_import_cursor: usize,
    terminal_focused: bool,
    terminal_resize_drag_active: bool,
    terminal_resize_drag_origin_height: f32,
    debug_terminal_window_focused: bool,
    debug_terminal_hitbox_focused: bool,
    debug_terminal_hitbox_active: bool,
    debug_terminal_hitbox_clicked: bool,
    debug_terminal_focus_requested: bool,
    debug_last_terminal_key_handled: bool,
    debug_last_terminal_text_handled: bool,
    debug_last_terminal_scancode: ?sdl.Scancode,
    debug_last_terminal_text: [32:0]u8,
    composer_picker_provider: ?Provider,
    composer_locked_model_picker_open: bool,
    opencode_model_options: std.ArrayList(ModelOption),
    opencode_reasoning_menu: std.ArrayList(OpencodeReasoningMenuRow),
    image_texture_cache: std.StringHashMap(CachedImageTexture),
    logo_texture: ?CachedImageTexture,
    opencode_logo_texture: ?CachedImageTexture,
    codex_logo_texture: ?CachedImageTexture,
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
    show_project_creator: bool,
    project_directory_browse_requested: bool,
    picker_state: PickerState,
    opencode_model_cache_state: OpencodeModelCacheState,
    file_search_state: FileSearchState,
    browser_state: browser_runtime.State,
    browser_launch_open_delay_frames: u8,
    browser_pane_min: [2]f32,
    browser_pane_max: [2]f32,
    browser_pane_input_size: [2]f32,
    browser_pane_hovered: bool,
    /// Palette sidebar thread row under the cursor (hover highlight).
    sidebar_thread_hover: ?SidebarThreadHover,
    browser_pane_focused: bool,
    browser_address_focused: bool,
    browser_address_cursor: usize,
    browser_inspector_menu_open: bool,
    /// Split "Open" header menu (folder / editors); palette workspace chrome only.
    workspace_header_open_menu_open: bool,
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
    pending_transcript_line_scroll_steps: i16,
    pending_transcript_page_scroll_steps: i16,
    dirty: bool,
    last_dirty_at_ms: i64,
    last_interaction_at_ms: i64,
    pending_send_count: usize,

    pub fn init(allocator: std.mem.Allocator, storage: *const Storage, initial_config: app_config.AppConfig) !AppState {
        var browser_state = try browser_runtime.State.init(allocator);
        errdefer browser_state.deinit();

        var state: AppState = .{
            .allocator = allocator,
            .storage = storage,
            .projects = .empty,
            .archived_projects = .empty,
            .selected_project_index = 0,
            .next_project_number = 4,
            .import_path_storage = std.mem.zeroes([DRAFT_CAPACITY:0]u8),
            .rename_storage = std.mem.zeroes([256:0]u8),
            .sidebar_notice_storage = std.mem.zeroes([256:0]u8),
            .import_thread_id_storage = std.mem.zeroes([256:0]u8),
            .import_notice_storage = std.mem.zeroes([256:0]u8),
            .sidebar_collapsed = false,
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
            .palette_modal_hits = .empty,
            .palette_modal_text_focus = .none,
            .project_rename_cursor = 0,
            .project_import_cursor = 0,
            .thread_import_cursor = 0,
            .terminal_focused = false,
            .terminal_resize_drag_active = false,
            .terminal_resize_drag_origin_height = 0.0,
            .debug_terminal_window_focused = false,
            .debug_terminal_hitbox_focused = false,
            .debug_terminal_hitbox_active = false,
            .debug_terminal_hitbox_clicked = false,
            .debug_terminal_focus_requested = false,
            .debug_last_terminal_key_handled = false,
            .debug_last_terminal_text_handled = false,
            .debug_last_terminal_scancode = null,
            .debug_last_terminal_text = std.mem.zeroes([32:0]u8),
            .composer_picker_provider = null,
            .composer_locked_model_picker_open = false,
            .opencode_model_options = .empty,
            .opencode_reasoning_menu = .empty,
            .image_texture_cache = std.StringHashMap(CachedImageTexture).init(allocator),
            .logo_texture = null,
            .opencode_logo_texture = null,
            .codex_logo_texture = null,
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
            .show_project_creator = false,
            .project_directory_browse_requested = false,
            .picker_state = .{},
            .opencode_model_cache_state = .{},
            .file_search_state = .{},
            .browser_state = browser_state,
            .browser_launch_open_delay_frames = 0,
            .browser_pane_min = .{ 0.0, 0.0 },
            .browser_pane_max = .{ 0.0, 0.0 },
            .browser_pane_input_size = .{ 0.0, 0.0 },
            .browser_pane_hovered = false,
            .sidebar_thread_hover = null,
            .browser_pane_focused = false,
            .browser_address_focused = false,
            .browser_address_cursor = 0,
            .browser_inspector_menu_open = false,
            .workspace_header_open_menu_open = false,
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
            .pending_transcript_line_scroll_steps = 0,
            .pending_transcript_page_scroll_steps = 0,
            .dirty = false,
            .last_dirty_at_ms = 0,
            .last_interaction_at_ms = 0,
            .pending_send_count = 0,
        };
        state.palette_composer.setCallbacks(.{});

        if (try storage.load(allocator)) |persisted_value| {
            var persisted = persisted_value;
            defer persisted.deinit();
            try state.applyPersisted(persisted.value);
        } else {
            try state.seedDefaultState();
        }
        state.logo_texture = utils.loadEmbeddedTexture(VERDE_LOGO_BYTES);
        state.opencode_logo_texture = utils.loadEmbeddedTexture(OPENCODE_LOGO_BYTES);
        state.codex_logo_texture = utils.loadEmbeddedTexture(CODEX_LOGO_BYTES);
        state.thread_edit_texture = utils.loadEmbeddedTexture(THREAD_EDIT_BYTES);
        state.cursor_logo_texture = utils.loadEmbeddedTexture(CURSOR_LOGO_BYTES);
        state.emacs_logo_texture = utils.loadEmbeddedTexture(EMACS_LOGO_BYTES);
        state.neovim_logo_texture = utils.loadEmbeddedTexture(NEOVIM_LOGO_BYTES);
        state.vscode_logo_texture = utils.loadEmbeddedTexture(VSCODE_LOGO_BYTES);
        state.zed_logo_texture = utils.loadEmbeddedTexture(ZED_LOGO_BYTES);
        return state;
    }

    pub fn opencodeModelOptionsSnapshot(self: *const AppState) []const ModelOption {
        return if (self.opencode_model_options.items.len > 0)
            self.opencode_model_options.items
        else
            OPENCODE_MODEL_OPTIONS[0..];
    }

    pub fn cachedDefaultModelRefForProvider(self: *const AppState, provider: Provider) [:0]const u8 {
        return switch (provider) {
            .codex => DEFAULT_CODEX_MODEL,
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

    fn duplicateReasoningVariantKeys(allocator: std.mem.Allocator, src: ?[][:0]const u8) !?[][:0]const u8 {
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

    const AddProjectResult = enum {
        created,
        restored,
    };

    fn addProject(self: *AppState, label: []const u8, path: []const u8, unread_count: u8) !AddProjectResult {
        const id = try self.deriveProjectId(path);
        defer self.allocator.free(id);
        if (self.findArchivedProjectIndexByPath(path)) |archived_index| {
            var restored = self.archived_projects.orderedRemove(archived_index);
            restored.archived = false;
            restored.unread_count = unread_count;
            if (restored.threads.items.len == 0) {
                try restored.addThread(self.allocator);
            }
            try restored.normalize(self.allocator);
            try self.projects.append(self.allocator, restored);
            self.markDirty();
            return .restored;
        }
        try self.projects.append(self.allocator, try Project.init(self.allocator, id, label, path, unread_count));
        self.markDirty();
        return .created;
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
        const trimmed = std.mem.trim(u8, self.importDirectoryDraft(), &std.ascii.whitespace);
        if (trimmed.len == 0) {
            self.setSidebarNotice("Enter a project directory path first.");
            return;
        }

        const resolved = try self.resolveProjectPath(trimmed);
        defer self.allocator.free(resolved);

        if (self.findProjectIndexByPath(resolved) != null) {
            self.setSidebarNotice("That directory is already in the project rail.");
            return;
        }

        const label = utils.projectLabelFromPath(resolved);
        const add_result = try self.addProject(label, resolved, 0);
        self.selected_project_index = self.projects.items.len - 1;
        self.clearImportPath();
        self.project_import_cursor = 0;
        self.syncRenameBuffer();
        self.setSidebarNotice(if (add_result == .restored) "Project restored from archive." else "Project imported.");
        self.show_project_creator = false;
        self.palette_modal_text_focus = .none;
        self.markDirty();
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
        runtime_log.diagnostic("browseForProjectDirectory entry show_project_creator={} draft_len={d}", .{ self.show_project_creator, self.importDirectoryDraft().len });
        log.info("browseForProjectDirectory entry show_project_creator={} draft_len={d}", .{ self.show_project_creator, self.importDirectoryDraft().len });
        const target_path = self.defaultExplorerPath() catch |err| {
            runtime_log.diagnostic("browseForProjectDirectory defaultExplorerPath failed: {s}", .{@errorName(err)});
            log.warn("browseForProjectDirectory defaultExplorerPath failed: {s}", .{@errorName(err)});
            self.setSidebarNotice(@errorName(err));
            return;
        };
        runtime_log.diagnostic("browseForProjectDirectory target_path={s}", .{target_path});
        log.info("browseForProjectDirectory target_path={s}", .{target_path});
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
            runtime_log.diagnostic("browseForProjectDirectory ignored: picker already pending", .{});
            log.info("browseForProjectDirectory ignored: picker already pending", .{});
            page_alloc.free(owned_target);
            self.setSidebarNotice("Folder picker already open.");
            return;
        }

        self.picker_state.status = .pending;
        self.picker_state.selected_path = null;
        self.picker_state.worker = std.Thread.spawn(.{}, pickerWorker, .{ &self.picker_state, owned_target }) catch {
            page_alloc.free(owned_target);
            self.picker_state.status = .failed;
            runtime_log.diagnostic("browseForProjectDirectory failed to spawn picker worker", .{});
            log.warn("browseForProjectDirectory failed to spawn picker worker", .{});
            self.setSidebarNotice("Failed to start folder picker.");
            return;
        };
        runtime_log.diagnostic("browseForProjectDirectory spawned picker worker", .{});
        log.info("browseForProjectDirectory spawned picker worker", .{});
        self.setSidebarNotice("Waiting for folder selection...");
    }

    pub fn requestBrowseForProjectDirectory(self: *AppState) void {
        runtime_log.diagnostic("requestBrowseForProjectDirectory queued", .{});
        log.info("requestBrowseForProjectDirectory queued", .{});
        self.project_directory_browse_requested = true;
        self.markDirty();
    }

    pub fn processDeferredProjectDirectoryBrowse(self: *AppState) void {
        if (!self.project_directory_browse_requested) return;
        runtime_log.diagnostic("processDeferredProjectDirectoryBrowse running", .{});
        log.info("processDeferredProjectDirectoryBrowse running", .{});
        self.project_directory_browse_requested = false;
        self.browseForProjectDirectory();
    }

    fn renameSelectedProject(self: *AppState) void {
        if (self.projects.items.len == 0) return;
        const trimmed = std.mem.trim(u8, self.renameInput(), &std.ascii.whitespace);
        if (trimmed.len == 0) {
            self.setSidebarNotice("Project name cannot be empty.");
            return;
        }

        const project = self.currentProjectMutable();
        self.allocator.free(project.label);
        project.label = self.allocator.dupeZ(u8, trimmed) catch {
            self.setSidebarNotice("Rename failed.");
            return;
        };
        self.setSidebarNotice("Project renamed.");
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
            self.setSidebarNotice("Project not found.");
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

    pub fn archiveProjectAtIndex(self: *AppState, index: usize) void {
        if (index >= self.projects.items.len) return;
        self.selected_project_index = index;
        self.archiveSelectedProject();
        self.rename_project_index = null;
    }

    fn archiveSelectedProject(self: *AppState) void {
        if (self.projects.items.len == 0) return;
        for (self.projects.items[self.selected_project_index].threads.items) |*thread| {
            if (thread.isSendPending()) {
                self.setSidebarNotice("Finish this project's running provider requests before archiving it.");
                return;
            }
        }
        self.cancelThreadImport();
        var removed = self.projects.orderedRemove(self.selected_project_index);
        removed.archived = true;
        removed.terminal_dock.visible = false;
        removed.archiveAllThreads(self.allocator) catch {
            removed.deinit(self.allocator);
            self.setSidebarNotice("Failed to archive the project.");
            return;
        };
        self.archived_projects.append(self.allocator, removed) catch |err| {
            var failed = removed;
            failed.deinit(self.allocator);
            self.setSidebarNotice(@errorName(err));
            return;
        };

        if (self.projects.items.len == 0) {
            self.selected_project_index = 0;
        } else if (self.selected_project_index >= self.projects.items.len) {
            self.selected_project_index = self.projects.items.len - 1;
        }

        self.syncRenameBuffer();
        self.setSidebarNotice("Project archived.");
        self.markDirty();
    }

    pub fn archiveThreadAtIndex(self: *AppState, project_index: usize, thread_index: usize) void {
        if (project_index >= self.projects.items.len) {
            self.setSidebarNotice("Project not found.");
            return;
        }

        var project = &self.projects.items[project_index];
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
            project.addThread(self.allocator) catch {
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
        project.addThread(self.allocator) catch {
            self.setSidebarNotice("Failed to create a new thread.");
            return;
        };
        self.selected_project_index = index;
        self.requestComposerFocus();
        self.syncRenameBuffer();
        self.setSidebarNotice("New thread ready.");
        self.markDirty();
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

        if (thread.draftImageCount() > 0) {
            self.setSidebarNotice("Queued follow-up messages do not support image attachments yet.");
            return;
        }

        const kind: FollowupKind = switch (thread.provider) {
            .codex => .steer,
            .opencode => .queue,
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
        };

        var client = try ai_harness.connect(self.allocator, provider_config);
        defer client.deinit();

        return client.sendPrompt(self.allocator, .{
            .thread_id = if (thread.provider_thread_id) |thread_id| thread_id else null,
            .thread_title = thread.title,
            .prompt = prompt,
            .cwd = project.path,
            .model = if (thread.model_ref) |model_ref| model_ref else null,
            .opencode_variant = if (thread.provider == .opencode) thread.opencode_reasoning_variant else null,
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
            if (project.terminal_layout_json) |layout_json| {
                loaded.terminal_dock.applyPersistedLayoutJson(self.allocator, layout_json) catch |err| {
                    log.warn("failed to restore terminal layout: {s}", .{@errorName(err)});
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
                    try loaded.addThread(self.allocator);
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
            }

            try loaded.normalize(self.allocator);

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
        const terminal_layout_json = try project.terminal_dock.persistedLayoutJson(allocator);
        errdefer if (terminal_layout_json) |value| allocator.free(value);

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
            .selected_thread_index = if (project.archived or project.threads.items.len == 0) 0 else chat_threads.selectedCommittedThreadIndex(project),
            .threads = try threads.toOwnedSlice(allocator),
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

    fn currentProjectMutable(self: *AppState) *Project {
        return &self.projects.items[self.selected_project_index];
    }

    pub fn canOpenCurrentProjectDirectory(self: *const AppState) bool {
        return self.projects.items.len > 0 and utils.canOpenProjectDirectory();
    }

    pub fn canOpenCurrentProjectEditor(self: *const AppState, target: ProjectEditorTarget) bool {
        return self.projects.items.len > 0 and utils.canOpenProjectEditor(target);
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
            .folder => if (self.canOpenCurrentProjectDirectory()) "Open this project's folder" else "No system folder opener was found",
            .editor => if (self.canOpenCurrentProjectEditor(.configured)) "Open this project in the configured editor" else "Configured editor is unavailable",
            .cursor => if (self.canOpenCurrentProjectEditor(.cursor)) "Open this project in Cursor" else "Cursor is unavailable",
            .vscode => if (self.canOpenCurrentProjectEditor(.vscode)) "Open this project in VS Code" else "VS Code is unavailable",
            .zed => if (self.canOpenCurrentProjectEditor(.zed)) "Open this project in Zed" else "Zed is unavailable",
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
            self.setSidebarNotice("No project selected.");
            return;
        }

        log.info("runDefaultOpenAction invoked for project path={s}", .{self.currentProject().path});

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
            self.setSidebarNotice("No project selected.");
            return;
        }

        utils.openProjectDirectory(self.allocator, self.currentProject().path) catch |err| {
            log.warn("failed to open project directory: {s}", .{@errorName(err)});
            self.setSidebarNotice("Failed to open project folder.");
            return;
        };
        log.info("openCurrentProjectDirectory completed", .{});
        self.setSidebarNotice("Opened project folder.");
    }

    pub fn openCurrentProjectEditor(self: *AppState, target: ProjectEditorTarget) void {
        if (self.projects.items.len == 0) {
            self.setSidebarNotice("No project selected.");
            return;
        }

        utils.openProjectEditor(self.allocator, self.currentProject().path, target) catch |err| {
            log.warn("failed to open project editor: {s}", .{@errorName(err)});
            self.setSidebarNotice("Failed to open project editor.");
            return;
        };
        log.info("openCurrentProjectEditor target={s} completed", .{@tagName(target)});
        self.setSidebarNotice(projectEditorOpenedNotice(target));
    }

    pub fn openTranscriptFileReference(self: *AppState, file_path: []const u8) void {
        const result = utils.openFilePreferEditor(self.allocator, file_path) catch |err| {
            log.warn("failed to open transcript file reference: {s}", .{@errorName(err)});
            self.setSidebarNotice("Failed to open file reference.");
            return;
        };

        switch (result) {
            .editor => self.setSidebarNotice("Opened file in editor."),
            .file_manager => self.setSidebarNotice("Opened containing folder."),
        }
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

    fn readClipboardTextForPaste(self: *AppState) ?[]u8 {
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

    fn insertTextIntoPaletteComposer(self: *AppState, text: []const u8) bool {
        if (text.len == 0) return false;
        self.palette_composer.focused = true;
        self.composer_focused = true;
        self.terminal_focused = false;
        self.browser_pane_focused = false;
        const handled = self.palette_composer.handleInput(self.allocator, .{ .text = text }) catch |err| {
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

        const cached = uploadTexture(loaded) orelse {
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
        author: []const u8,
        image_present: bool,
    ) ?f32 {
        const thread = self.currentThreadMutable();
        thread.ensureTranscriptHeightEntries(self.allocator);
        if (message_index >= thread.transcript_height_entries.items.len) return null;

        const entry = thread.transcript_height_entries.items[message_index];
        if (!entry.valid) return null;
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
        author: []const u8,
        image_present: bool,
        height: f32,
    ) void {
        if (height <= 0.0) return;
        const thread = self.currentThreadMutable();
        thread.ensureTranscriptHeightEntries(self.allocator);
        if (message_index >= thread.transcript_height_entries.items.len) return;

        thread.transcript_height_entries.items[message_index] = .{
            .valid = true,
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

    pub fn currentThread(self: *const AppState) *const ChatThread {
        return self.currentProject().currentThread();
    }

    pub fn currentProjectTerminal(self: *const AppState) *const terminal.Dock {
        return &self.currentProject().terminal_dock;
    }

    pub fn currentProjectTerminalMutable(self: *AppState) *terminal.Dock {
        return &self.currentProjectMutable().terminal_dock;
    }

    pub fn isTerminalVisible(self: *const AppState) bool {
        return self.projects.items.len > 0 and self.currentProjectTerminal().visible;
    }

    pub fn isSidebarCollapsed(self: *const AppState) bool {
        return self.sidebar_collapsed;
    }

    pub fn setSidebarCollapsed(self: *AppState, collapsed: bool) void {
        if (self.sidebar_collapsed == collapsed) return;
        self.sidebar_collapsed = collapsed;
        self.markDirty();
    }

    pub fn toggleSidebarCollapsed(self: *AppState) void {
        self.setSidebarCollapsed(!self.sidebar_collapsed);
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
            self.setSidebarNotice("No project selected.");
            return;
        }

        var dock = self.currentProjectTerminalMutable();
        if (!dock.visible) {
            const project_path = self.currentProject().path;
            dock.ensureSession(self.allocator, project_path) catch |err| {
                log.err("failed to start terminal dock: {s}", .{@errorName(err)});
                self.setSidebarNotice("Failed to start terminal.");
                return;
            };
        }

        const is_visible = dock.toggle();
        if (!is_visible) self.endTerminalResizeDrag();
        self.terminal_focused = is_visible;
        self.setSidebarNotice(if (is_visible) "Terminal opened." else "Terminal hidden.");
    }

    pub fn pollTerminals(self: *AppState) void {
        for (self.projects.items, 0..) |*project, project_index| {
            if (!project.terminal_dock.visible and !project.terminal_dock.hasRunningSession()) continue;
            project.terminal_dock.poll(self.allocator) catch |err| {
                log.err("failed to poll terminal session: {s}", .{@errorName(err)});
                if (project_index == self.selected_project_index and project.terminal_dock.visible) {
                    self.setSidebarNotice("Terminal session failed.");
                }
            };
        }
        for (self.archived_projects.items) |*project| {
            if (!project.terminal_dock.visible and !project.terminal_dock.hasRunningSession()) continue;
            project.terminal_dock.poll(self.allocator) catch |err| {
                log.err("failed to poll archived terminal session: {s}", .{@errorName(err)});
            };
        }
    }

    /// Returns mutable browser UI/runtime state for desktop control surfaces.
    pub fn browserState(self: *AppState) *browser_runtime.State {
        return &self.browser_state;
    }

    /// Returns read-only browser UI/runtime state for desktop rendering.
    pub fn browserStateConst(self: *const AppState) *const browser_runtime.State {
        return &self.browser_state;
    }

    /// Opens the browser during startup when an explicit debug environment flag requests it.
    pub fn openBrowserOnLaunchIfRequested(self: *AppState) void {
        const value = std.mem.sliceTo(std.c.getenv("VERDE_OPEN_BROWSER_ON_START") orelse return, 0);
        if (!std.mem.eql(u8, value, "1")) return;
        // Wait a couple of app-loop turns so this exercises the same path as a
        // user click after the window is live instead of front-loading browser
        // creation before the first frame.
        self.browser_launch_open_delay_frames = 2;
    }

    /// Toggles the desktop browser control surface and the underlying browser runtime.
    pub fn toggleBrowser(self: *AppState) void {
        if (self.browser_state.controls_visible) {
            self.hideBrowser();
            return;
        }

        const restore_last_url = !self.browser_state.controller.runtimeInitialized() and self.browser_state.current_url != null;
        self.browser_state.setControlsVisible(true);
        self.browser_address_focused = true;
        self.browser_address_cursor = self.browser_state.addressInput().len;
        self.browser_pane_focused = false;
        self.terminal_focused = false;
        self.composer_focused = false;
        self.browser_state.status = .opening;
        if (restore_last_url) {
            const url = self.browser_state.current_url.?;
            self.browser_state.controller.navigate(url) catch |err| {
                log.err("failed to restore browser runtime: {s}", .{@errorName(err)});
                self.browser_state.status = .failed;
                self.browser_state.setLastError("Failed to restore browser runtime.") catch {};
                self.setSidebarNotice("Failed to reopen browser.");
                return;
            };
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
        self.setSidebarNotice("Browser opened.");
    }

    /// Closes the browser dock and fully tears the runtime down so CEF exits until the next open.
    pub fn closeBrowser(self: *AppState) void {
        self.browser_state.setControlsVisible(false);
        self.browser_state.setInspectorEnabled(false);
        self.browser_state.clearSuppressedEvalResults();
        self.browser_pane_focused = false;
        self.browser_pane_hovered = false;
        self.browser_address_focused = false;
        self.browser_inspector_menu_open = false;
        self.browser_state.controller.shutdown();
        self.browser_state.status = .hidden;
        self.browser_state.setLastError(null) catch {};
        self.setSidebarNotice("Browser closed.");
    }

    /// Hides the desktop browser control surface and its browser runtime.
    pub fn hideBrowser(self: *AppState) void {
        self.browser_state.setControlsVisible(false);
        self.browser_state.setInspectorEnabled(false);
        self.browser_state.clearSuppressedEvalResults();
        self.browser_pane_focused = false;
        self.browser_address_focused = false;
        self.browser_inspector_menu_open = false;
        self.browser_state.controller.hide() catch |err| {
            log.err("failed to hide browser runtime: {s}", .{@errorName(err)});
            self.browser_state.status = .failed;
            self.browser_state.setLastError("Failed to hide browser runtime.") catch {};
            self.setSidebarNotice("Failed to hide browser.");
            return;
        };
        self.setSidebarNotice("Browser hidden.");
    }

    /// Reports whether the browser dock is visible in the chat workspace.
    pub fn isBrowserVisible(self: *const AppState) bool {
        return self.browser_state.controls_visible;
    }

    /// Reports whether the current browser runtime can host the bundled CEF inspector.
    pub fn canUseBrowserInspector(self: *const AppState) bool {
        return self.browser_state.controller.runtimeKind() == .cef and self.browser_state.controller.sdkConfigured();
    }

    /// Reports whether the bundled browser inspector is currently armed.
    pub fn isBrowserInspectorEnabled(self: *const AppState) bool {
        return self.browser_state.inspectorEnabled();
    }

    /// Reports which interaction mode the bundled browser inspector will use.
    pub fn browserInspectorMode(self: *const AppState) browser_runtime.InspectorMode {
        return self.browser_state.inspectorMode();
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
    }

    /// Clears browser-pane keyboard focus when another UI surface takes ownership.
    pub fn unfocusBrowserPane(self: *AppState) void {
        self.browser_pane_focused = false;
    }

    /// Reports whether the browser pane currently owns keyboard input.
    pub fn isBrowserPaneFocused(self: *const AppState) bool {
        return self.isBrowserVisible() and self.browser_pane_focused;
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
            self.browser_pane_focused = false;
            return false;
        }
        if (!contains_pointer and !self.browser_pane_focused) return false;
        if (is_pointer_event and !contains_pointer) return false;

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
            self.browser_pane_focused = true;
            self.terminal_focused = false;
            self.composer_focused = false;
        }
        return handled;
    }

    /// Forwards browser-pane keyboard and text input when the pane owns focus.
    pub fn handleBrowserKey(self: *AppState, event: browser_runtime.KeyEvent) bool {
        if (!self.isBrowserPaneFocused()) return false;
        return self.browser_state.controller.handleKey(event) catch |err| {
            log.warn("failed to forward browser keyboard input: {s}", .{@errorName(err)});
            return false;
        };
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
        const trimmed = std.mem.trim(u8, self.browser_state.addressInput(), &std.ascii.whitespace);
        if (trimmed.len == 0) {
            self.setSidebarNotice("Enter a browser URL first.");
            return;
        }
        const normalized = self.normalizeBrowserUrl(trimmed) catch {
            self.setSidebarNotice("Failed to normalize browser URL.");
            return;
        };
        defer self.allocator.free(normalized);

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

    /// Toggles the bundled page inspector overlay inside the CEF browser runtime.
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
    pub fn pollBrowser(self: *AppState) void {
        if (self.browser_launch_open_delay_frames == 0 and !self.browser_state.controller.hasBackend()) return;

        if (self.browser_launch_open_delay_frames > 0) {
            self.browser_launch_open_delay_frames -= 1;
            if (self.browser_launch_open_delay_frames == 0) {
                self.toggleBrowser();
            }
        }
        while (self.browser_state.controller.pollEvent()) |event| {
            defer event.deinit(self.allocator);
            switch (event) {
                .opened => {
                    self.browser_state.status = .ready;
                    self.browser_state.setLastError(null) catch {};
                },
                .closed => {
                    self.browser_state.status = .hidden;
                    self.browser_pane_focused = false;
                    self.setSidebarNotice("Browser window closed.");
                },
                .navigated => |url| {
                    self.browser_state.status = .ready;
                    self.browser_state.setCurrentUrl(url) catch {};
                    self.browser_state.setAddress(url);
                    self.browser_state.setLastError(null) catch {};
                },
                .title_changed => {},
                .document_loaded => {
                    self.reapplyBrowserInspectorAfterLoad();
                },
                .js_message => |message| {
                    if (isInspectorBridgeMessage(message)) {
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
                    if (self.browser_state.consumeSuppressedEvalResult()) {
                        continue;
                    }
                    self.setSidebarNotice("Browser script evaluation completed.");
                },
                .failed => |message| {
                    self.browser_state.status = .failed;
                    self.browser_state.setLastError(message) catch {};
                    self.setSidebarNotice("Browser runtime reported a failure.");
                },
            }
        }
    }

    // Adds an https scheme for bare hostnames so the browser control surface accepts normal typed URLs.
    fn normalizeBrowserUrl(self: *AppState, value: []const u8) ![]u8 {
        if (std.mem.indexOf(u8, value, "://") != null) {
            return try self.allocator.dupe(u8, value);
        }
        if (std.mem.startsWith(u8, value, "about:")) {
            return try self.allocator.dupe(u8, value);
        }
        return try std.fmt.allocPrint(self.allocator, "https://{s}", .{value});
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
    fn enableBrowserInspector(self: *AppState, show_notice: bool) void {
        self.applyBrowserInspector(show_notice, "Browser inspector enabled.");
    }

    // Enables or reapplies the bundled inspector using the currently selected mode.
    fn applyBrowserInspector(self: *AppState, show_notice: bool, success_notice: []const u8) void {
        if (!self.isBrowserVisible()) {
            self.setSidebarNotice("Open the browser before enabling the inspector.");
            return;
        }
        if (!self.canUseBrowserInspector()) {
            self.setSidebarNotice("The browser inspector currently requires a real CEF runtime.");
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
    fn disableBrowserInspector(self: *AppState, show_notice: bool) void {
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
            if (project.terminal_dock.visible and project.terminal_dock.hasRunningSession()) return true;
        }
        return false;
    }

    pub fn handleTerminalKeyDown(
        self: *AppState,
        keyboard: *const keybinds.NativeKeyboardConfig,
        event: *const sdl.KeyboardEvent,
    ) bool {
        if (!self.terminal_focused or !self.isTerminalVisible()) return false;
        var dock = self.currentProjectTerminalMutable();
        const handled = dock.handleKeyDown(self.allocator, keyboard, event);
        if (dock.consumeWorkspaceChange()) self.markDirty();
        return handled;
    }

    pub fn handleTerminalTextInput(self: *AppState, text: [*c]const u8) bool {
        if (!self.terminal_focused or !self.isTerminalVisible()) return false;
        return self.currentProjectTerminalMutable().handleTextInput(std.mem.sliceTo(text, 0));
    }

    pub fn resetUiDebugFrame(self: *AppState) void {
        self.debug_terminal_window_focused = false;
        self.debug_terminal_hitbox_focused = false;
        self.debug_terminal_hitbox_active = false;
        self.debug_terminal_hitbox_clicked = false;
        self.debug_terminal_focus_requested = false;
        self.browser_pane_hovered = false;
        self.transcript_focused = false;
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

    pub fn currentTranscriptScrollY(self: *const AppState) ?f32 {
        const thread = self.currentThread();
        if (!thread.transcript_scroll_valid) return null;
        return thread.transcript_scroll_y;
    }

    pub fn requestComposerFocus(self: *AppState) void {
        self.composer_focus_requested = true;
        self.terminal_focused = false;
        self.browser_pane_focused = false;
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
        self.palette_composer.setFontMetrics(paletteEstimatedFontMetrics(PALETTE_COMPOSER_FONT_SIZE));
        self.palette_composer.setToolbarFontMetrics(paletteEstimatedFontMetrics(PALETTE_COMPOSER_TOOLBAR_FONT_SIZE));
        self.palette_composer.setIconFontMetrics(paletteEstimatedFontMetrics(PALETTE_COMPOSER_ICON_FONT_SIZE));
        const thread = self.currentThread();
        const show_fast_toggle = thread.provider == .codex;
        self.palette_composer.setShowFastToggle(show_fast_toggle);
        self.palette_composer.setPlaceholder(self.allocator, if (thread.draftImageCount() == 0) "Ask anything, or use / to show available commands" else " ") catch |err| {
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
        const reasoning_count: usize = if (thread.provider == .codex)
            CODEX_REASONING_OPTIONS.len
        else
            self.opencode_reasoning_menu.items.len;
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
        self.palette_model_cascade.setFontMetrics(paletteEstimatedFontMetrics(20.0));
        self.palette_model_cascade.setItemCount(COMPOSER_PROVIDER_OPTIONS.len);
    }

    pub fn setPaletteModelCascadeBoundsFromToolbar(self: *AppState) void {
        const anchor = self.composer_toolbar_model_rect;
        if (anchor.w <= 0.0 or anchor.h <= 0.0) return;

        const root_height = COMPOSER_MODEL_CASCADE_PADDING_Y * 2.0 +
            COMPOSER_MODEL_CASCADE_ROW_HEIGHT * @as(f32, @floatFromInt(COMPOSER_PROVIDER_OPTIONS.len));
        const total_width = COMPOSER_MODEL_CASCADE_WIDTH * 2.0 + 6.0;
        const min_x = if (self.composer_input_bounds_valid) self.composer_input_min[0] else anchor.x;
        const max_x = if (self.composer_input_bounds_valid) self.composer_input_max[0] else anchor.x + total_width;
        const x = @max(min_x, @min(anchor.x, max_x - total_width));
        self.palette_model_cascade.setAnchorRect(anchor);
        self.palette_model_cascade.clearForbiddenRect();
        self.palette_model_cascade.setViewportRect(.{
            .x = min_x,
            .y = 8.0,
            .w = @max(max_x - min_x, total_width),
            .h = @max(anchor.y - 16.0, root_height),
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

    pub fn routePaletteComposerTextInput(self: *AppState, text: []const u8) bool {
        if (!self.palette_composer.focused) return false;
        const handled = self.palette_composer.handleInput(self.allocator, .{ .text = text }) catch |err| {
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
            self.browser_pane_focused = false;
        }
        return handled or was_focused != self.palette_composer.focused;
    }

    fn routePaletteComposerToolbarOverlayClick(self: *AppState, point: palette.draw.Vec2) bool {
        if (!self.composer_toolbar_overlay_valid) return false;
        if (self.composer_toolbar_model_rect.contains(point)) {
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
        else if (self.currentThread().provider == .codex and self.composer_toolbar_fast_rect.contains(point))
            self.palette_composer.fastRect()
        else if (self.composer_toolbar_access_rect.contains(point))
            self.palette_composer.accessRect()
        else
            return false;

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
            self.browser_pane_focused = false;
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
        const metrics = paletteEstimatedFontMetrics(PALETTE_COMPOSER_FONT_SIZE);
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
        self.browser_pane_focused = false;
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

    fn composerReasoningIndex(value: ?ReasoningEffort) ?usize {
        for (CODEX_REASONING_OPTIONS, 0..) |option, index| {
            if (value == null and option.value == null) return index;
            if (value != null and option.value != null and value.? == option.value.?) return index;
        }
        return null;
    }

    fn composerReasoningIndexForThread(self: *const AppState, thread: *const ChatThread) ?usize {
        if (thread.provider == .codex) {
            return composerReasoningIndex(thread.reasoning_effort);
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
    }

    pub fn requestTranscriptLineScroll(self: *AppState, delta: i16) void {
        if (delta == 0) return;
        self.noteInteraction();
        self.transcript_auto_follow_pending = false;
        self.scroll_transcript_to_bottom_frames = 0;
        const next = @as(i32, self.pending_transcript_line_scroll_steps) + delta;
        self.pending_transcript_line_scroll_steps = @intCast(std.math.clamp(next, -32, 32));
    }

    pub fn requestTranscriptPageScroll(self: *AppState, delta: i16) void {
        if (delta == 0) return;
        self.noteInteraction();
        self.transcript_auto_follow_pending = false;
        self.scroll_transcript_to_bottom_frames = 0;
        const next = @as(i32, self.pending_transcript_page_scroll_steps) + delta;
        self.pending_transcript_page_scroll_steps = @intCast(std.math.clamp(next, -16, 16));
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
        self.pollSend();
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
        self.preparePendingSendsForShutdown();
        ai_harness.shutdownOwnedProviderProcesses();
        self.finishPickerThread();
        self.finishOpencodeModelCacheThread();
        self.finishAllSendThreads();
        self.pollSend();
        self.flushDirtyBlocking();
        self.file_search_state.deinit(self.allocator);
        self.palette_composer.deinit(self.allocator);
        self.palette_overlay_batch.deinit(self.allocator);
        self.palette_frame_text.deinit(self.allocator);
        self.palette_modal_hits.deinit(self.allocator);
        self.closeTranscriptSelectionModal();
        self.clearProjects();
        self.transcript_markdown_entries.deinit(self.allocator);
        self.browser_state.deinit();
        self.releaseAllImageTextures();
        self.thread_import_threads.deinit(self.allocator);
        self.clearOpencodeModelOptions();
        self.opencode_reasoning_menu.deinit(self.allocator);
        self.opencode_model_options.deinit(self.allocator);
        self.app_config.deinit(self.allocator);
        self.projects.deinit(self.allocator);
        self.archived_projects.deinit(self.allocator);
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
                            log.warn("failed to import selected project: {s}", .{@errorName(err)});
                            self.setSidebarNotice("Folder selected, but project import failed.");
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

    pub fn pollSend(self: *AppState) void {
        if (self.pending_send_count == 0) return;

        for (self.projects.items, 0..) |*project, project_index| {
            for (project.threads.items, 0..) |*thread, thread_index| {
                self.pollThreadSend(project_index, thread_index, thread);
            }
        }
    }

    fn pollThreadSend(self: *AppState, project_index: usize, thread_index: usize, thread: *ChatThread) void {
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

        if (!send_state.mutex.tryLock()) return;
        switch (send_state.status) {
            .completed => {
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
                if (provider == .opencode or send_state.active_turn_id != null) {
                    thread_id = self.allocator.dupe(u8, resolved_thread_id) catch null;
                    turn_id = if (send_state.active_turn_id) |active_turn_id|
                        self.allocator.dupe(u8, active_turn_id) catch null
                    else
                        null;
                    send_state.stop_signal_sent = thread_id != null;
                }
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
        send_state.mutex.unlock();

        self.issuePendingThreadStop(project_path, thread);
    }

    pub fn hasPendingStream(self: *AppState) bool {
        if (self.projects.items.len == 0) return false;
        return self.currentThread().isSendPendingForUi();
    }

    pub fn hasAnyPendingSends(self: *AppState) bool {
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
    };
}

fn failedToStoreThreadListNotice(provider: Provider) []const u8 {
    return switch (provider) {
        .codex => "Failed to store Codex thread list.",
        .opencode => "Failed to store OpenCode thread list.",
    };
}

fn noRecentThreadsNotice(provider: Provider) []const u8 {
    return switch (provider) {
        .codex => "No recent Codex threads found.",
        .opencode => "No recent OpenCode threads found.",
    };
}

fn selectThreadNotice(provider: Provider) []const u8 {
    return switch (provider) {
        .codex => "Select a Codex thread or paste a thread ID.",
        .opencode => "Select an OpenCode thread or paste a thread ID.",
    };
}

fn emptyThreadImportIdNotice(provider: Provider) []const u8 {
    return switch (provider) {
        .codex => "Enter a Codex thread ID or select one from the list.",
        .opencode => "Enter an OpenCode thread ID or select one from the list.",
    };
}

fn duplicateThreadNotice(provider: Provider) []const u8 {
    return switch (provider) {
        .codex => "Codex thread already exists in this project.",
        .opencode => "OpenCode thread already exists in this project.",
    };
}

fn failedCreateImportedThreadNotice(provider: Provider) []const u8 {
    return switch (provider) {
        .codex => "Failed to create the imported thread.",
        .opencode => "Failed to create the imported thread.",
    };
}

fn failedAddImportedThreadNotice(provider: Provider) []const u8 {
    return switch (provider) {
        .codex => "Failed to add the imported thread.",
        .opencode => "Failed to add the imported thread.",
    };
}

fn threadImportedNotice(provider: Provider) []const u8 {
    return switch (provider) {
        .codex => "Codex thread imported.",
        .opencode => "OpenCode thread imported.",
    };
}

fn threadSyncedNotice(provider: Provider) []const u8 {
    return switch (provider) {
        .codex => "Thread synced from Codex.",
        .opencode => "Thread synced from OpenCode.",
    };
}

fn projectEditorOpenedNotice(target: ProjectEditorTarget) []const u8 {
    return switch (target) {
        .configured => "Opened project in the configured editor.",
        .cursor => "Opened project in Cursor.",
        .vscode => "Opened project in VS Code.",
        .zed => "Opened project in Zed.",
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

fn unixTimestampSeconds() i64 {
    return @divTrunc(unixTimestampMs(), std.time.ms_per_s);
}

fn unixTimestampMs() i64 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.REALTIME, &ts) != 0) return 0;
    return @as(i64, @intCast(ts.sec)) * std.time.ms_per_s +
        @divTrunc(@as(i64, @intCast(ts.nsec)), std.time.ns_per_ms);
}
