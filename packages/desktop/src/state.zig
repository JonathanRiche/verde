const std = @import("std");
const sdl = @import("zsdl3");
const zgui = @import("zgui");
const app_config = @import("config.zig");
const ai_harness = @import("harness.zig");
const browser_runtime = @import("browser/mod.zig");
const chat_threads = @import("chat/threads.zig");
const db_client = @import("db/client.zig");
const db_types = @import("db/types.zig");
const fff = @import("fff.zig");
const stb_image = @import("stb_image.zig");
const terminal = @import("terminal/terminal.zig");
const theme = @import("ui/theme.zig");
const utils = @import("utils.zig");

pub const ReasoningEffort = db_types.ReasoningEffort;
pub const FastMode = db_types.FastMode;
pub const AccessMode = db_types.AccessMode;
pub const ChatRole = db_types.ChatRole;
pub const Provider = db_types.Provider;
pub const Harness = db_types.Harness;
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
pub const DEFAULT_CODEX_MODEL: [:0]const u8 = "gpt-5.4";
pub const DEFAULT_OPENCODE_MODEL: [:0]const u8 = "opencode/gpt-5.4";
pub const IMAGE_MODAL_ID: [:0]const u8 = "AttachmentPreviewModal";
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
const sendWorker = utils.sendWorker;
const uploadTexture = utils.uploadTexture;

pub const ModelOption = struct {
    label: [:0]const u8,
    value: ?[:0]const u8 = null,
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

pub const OPENCODE_MODEL_OPTIONS = [_]ModelOption{
    .{ .label = "GPT-5.4", .value = "opencode/gpt-5.4" },
    .{ .label = "Claude Opus 4.6", .value = "opencode/claude-opus-4-6" },
    .{ .label = "Claude Sonnet 4.5", .value = "opencode/claude-sonnet-4-5" },
    .{ .label = "Gemini 3.1 Pro", .value = "opencode/gemini-3.1-pro" },
};

pub const CODEX_MODEL_OPTIONS = [_]ModelOption{
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
    .{ .label = "Extra High", .value = .xhigh },
};

pub const CODEX_FAST_MODE_OPTIONS = [_]FastModeOption{
    .{ .label = "Off", .value = .off },
    .{ .label = "On", .value = .on },
};

pub const CODEX_ACCESS_MODE_OPTIONS = [_]AccessModeOption{
    .{ .label = "Full access", .value = .full_access },
    .{ .label = "Supervised", .value = .supervised },
};

const ChatMessage = struct {
    role: ChatRole,
    author: [:0]const u8,
    body: [:0]const u8,
    image: ?ChatImageAttachment = null,
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
    committed: bool = false,
    last_activity_at: i64 = 0,
    provider_thread_id: ?[:0]const u8 = null,
    model_ref: ?[:0]const u8 = null,
    reasoning_effort: ?ReasoningEffort = null,
    fast_mode: FastMode = .off,
    access_mode: AccessMode = .full_access,
    provider: Provider = .opencode,
    harness: Harness = .local_cli,
    messages: std.ArrayList(ChatMessage),
    draft_image: ?ChatImageAttachment = null,
    draft_storage: [AppState.DRAFT_CAPACITY:0]u8,

    fn init(allocator: std.mem.Allocator, title: []const u8) !ChatThread {
        return .{
            .title = try allocator.dupeZ(u8, title),
            .committed = false,
            .last_activity_at = 0,
            .model_ref = try allocator.dupeZ(u8, DEFAULT_CODEX_MODEL),
            .reasoning_effort = .high,
            .fast_mode = .off,
            .access_mode = .full_access,
            .provider = .codex,
            .harness = .local_cli,
            .messages = .empty,
            .draft_image = null,
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

    fn clearDraftImage(self: *ChatThread, allocator: std.mem.Allocator) void {
        if (self.draft_image) |*image| {
            image.deinit(allocator);
            self.draft_image = null;
        }
    }

    fn commitFromPrompt(self: *ChatThread, allocator: std.mem.Allocator, prompt: []const u8) !void {
        self.committed = true;
        self.last_activity_at = std.time.timestamp();
        const next_title = try chat_threads.makeThreadTitle(allocator, prompt);
        allocator.free(self.title);
        self.title = next_title;
    }

    fn touch(self: *ChatThread) void {
        self.last_activity_at = std.time.timestamp();
    }

    fn deinit(self: *ChatThread, allocator: std.mem.Allocator) void {
        allocator.free(self.title);
        if (self.provider_thread_id) |thread_id| allocator.free(thread_id);
        if (self.model_ref) |model_ref| allocator.free(model_ref);
        for (self.messages.items) |message| {
            allocator.free(message.author);
            allocator.free(message.body);
            if (message.image) |*image| image.deinit(allocator);
        }
        self.messages.deinit(allocator);
        self.clearDraftImage(allocator);
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
    mutex: std.Thread.Mutex = .{},
    status: PickerStatus = .idle,
    selected_path: ?[]u8 = null,
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
    unread_count: u8 = 0,
    collapsed: bool = false,
    thread_list_expanded: bool = false,
    terminal_dock: terminal.Dock,
    threads: std.ArrayList(ChatThread),
    selected_thread_index: usize = 0,

    fn init(allocator: std.mem.Allocator, id: []const u8, label: []const u8, path: []const u8, unread_count: u8) !Project {
        var terminal_dock = try terminal.Dock.init(allocator);
        errdefer terminal_dock.deinit(allocator);
        var project: Project = .{
            .id = try allocator.dupeZ(u8, id),
            .label = try allocator.dupeZ(u8, label),
            .path = try allocator.dupeZ(u8, path),
            .unread_count = unread_count,
            .collapsed = false,
            .thread_list_expanded = false,
            .terminal_dock = terminal_dock,
            .threads = .empty,
            .selected_thread_index = 0,
        };
        try project.addThread(allocator);
        return project;
    }

    pub fn currentThread(self: *const Project) *const ChatThread {
        return &self.threads.items[self.selected_thread_index];
    }

    pub fn currentThreadMutable(self: *Project) *ChatThread {
        return &self.threads.items[self.selected_thread_index];
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
        try self.threads.append(allocator, try ChatThread.init(allocator, "New thread"));
        self.selected_thread_index = self.threads.items.len - 1;
    }

    fn normalize(self: *Project, allocator: std.mem.Allocator) !void {
        if (self.threads.items.len == 0) {
            try self.addThread(allocator);
        }
        if (self.selected_thread_index >= self.threads.items.len) {
            self.selected_thread_index = self.threads.items.len - 1;
        }
        for (self.threads.items) |*thread| {
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
    }
};

pub const Storage = struct {
    allocator: std.mem.Allocator,
    pref_path: []const u8,
    client: db_client.Client,

    pub fn init(allocator: std.mem.Allocator) !Storage {
        const pref_path = sdl.getPrefPath(ORG_NAME, APP_NAME) orelse return error.SdlError;
        try std.fs.cwd().makePath(pref_path);
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
        var dir = try std.fs.openDirAbsolute(self.pref_path, .{});
        defer dir.close();

        const bytes = dir.readFileAlloc(allocator, LEGACY_STATE_FILE_NAME, 1024 * 1024) catch |err| switch (err) {
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
pub const SendStatus = enum {
    idle,
    pending,
    completed,
    failed,
};
pub const SendState = struct {
    mutex: std.Thread.Mutex = .{},
    condition: std.Thread.Condition = .{},
    status: SendStatus = .idle,
    result: ?SendResultPayload = null,
    error_message: ?[]u8 = null,
    provider: ?Provider = null,
    project_index: ?usize = null,
    thread_index: ?usize = null,
    partial_text: std.ArrayListUnmanaged(u8) = .empty,
    pending_events: std.ArrayListUnmanaged(PendingTimelineEvent) = .empty,
    pending_diff_files: std.ArrayListUnmanaged(PendingDiffFile) = .empty,
    pending_approval: ?PendingApproval = null,
    approval_decision: ?ai_harness.ApprovalDecision = null,
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
    project_index: usize,
    thread_index: usize,
    provider_thread_id: []const u8,
    reply_text: []const u8,
};
pub const AppState = struct {
    const DRAFT_CAPACITY = 8192;

    allocator: std.mem.Allocator,
    storage: *const Storage,
    projects: std.ArrayList(Project),
    selected_project_index: usize,
    next_project_number: usize,
    import_path_storage: [DRAFT_CAPACITY:0]u8,
    rename_storage: [256:0]u8,
    sidebar_notice_storage: [256:0]u8,
    composer_focused: bool,
    terminal_focused: bool,
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
    show_project_creator: bool,
    picker_state: PickerState,
    file_search_state: FileSearchState,
    browser_state: browser_runtime.State,
    browser_launch_open_delay_frames: u8,
    browser_pane_min: [2]f32,
    browser_pane_max: [2]f32,
    browser_pane_hovered: bool,
    browser_pane_focused: bool,
    send_state: SendState,
    scroll_transcript_to_bottom: bool,
    dirty: bool,

    pub fn init(allocator: std.mem.Allocator, storage: *const Storage, initial_config: app_config.AppConfig) !AppState {
        var browser_state = try browser_runtime.State.init(allocator);
        errdefer browser_state.deinit();

        var state: AppState = .{
            .allocator = allocator,
            .storage = storage,
            .projects = .empty,
            .selected_project_index = 0,
            .next_project_number = 4,
            .import_path_storage = std.mem.zeroes([DRAFT_CAPACITY:0]u8),
            .rename_storage = std.mem.zeroes([256:0]u8),
            .sidebar_notice_storage = std.mem.zeroes([256:0]u8),
            .composer_focused = false,
            .terminal_focused = false,
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
            .show_project_creator = false,
            .picker_state = .{},
            .file_search_state = .{},
            .browser_state = browser_state,
            .browser_launch_open_delay_frames = 0,
            .browser_pane_min = .{ 0.0, 0.0 },
            .browser_pane_max = .{ 0.0, 0.0 },
            .browser_pane_hovered = false,
            .browser_pane_focused = false,
            .send_state = .{},
            .scroll_transcript_to_bottom = true,
            .dirty = false,
        };

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

    fn addProject(self: *AppState, label: []const u8, path: []const u8, unread_count: u8) !void {
        const id = try self.deriveProjectId(path);
        defer self.allocator.free(id);
        try self.projects.append(self.allocator, try Project.init(self.allocator, id, label, path, unread_count));
        self.markDirty();
    }

    fn appendMessage(self: *AppState, role: ChatRole, author: []const u8, body: []const u8, image: ?*const ChatImageAttachment) !void {
        const thread = self.currentThreadMutable();
        self.trimThreadMessages(thread, 1);

        try thread.messages.append(self.allocator, .{
            .role = role,
            .author = try self.dupeZ(author),
            .body = try self.dupeZ(body),
            .image = if (image) |attachment|
                try ChatImageAttachment.init(self.allocator, attachment.path, attachment.mime, attachment.byte_size)
            else
                null,
        });
        thread.touch();
        self.markDirty();
    }

    pub fn importProjectFromInput(self: *AppState) !void {
        const trimmed = std.mem.trim(u8, self.importPath(), &std.ascii.whitespace);
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
        try self.addProject(label, resolved, 0);
        self.selected_project_index = self.projects.items.len - 1;
        self.clearImportPath();
        self.syncRenameBuffer();
        self.setSidebarNotice("Project imported.");
        self.show_project_creator = false;
        self.markDirty();
    }

    pub fn browseForProjectDirectory(self: *AppState) void {
        const target_path = self.defaultExplorerPath() catch |err| {
            self.setSidebarNotice(@errorName(err));
            return;
        };
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
            page_alloc.free(owned_target);
            self.setSidebarNotice("Folder picker already open.");
            return;
        }

        self.picker_state.status = .pending;
        self.picker_state.selected_path = null;
        self.picker_state.worker = std.Thread.spawn(.{}, pickerWorker, .{ &self.picker_state, owned_target }) catch {
            page_alloc.free(owned_target);
            self.picker_state.status = .failed;
            self.setSidebarNotice("Failed to start folder picker.");
            return;
        };
        self.setSidebarNotice("Waiting for folder selection...");
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
        self.selected_project_index = index;
        self.rename_project_index = index;
        self.syncRenameBuffer();
        self.setSidebarNotice("");
    }

    pub fn finishProjectRename(self: *AppState) void {
        if (self.rename_project_index) |index| {
            if (index < self.projects.items.len) {
                self.selected_project_index = index;
                self.renameSelectedProject();
            }
        }
        self.rename_project_index = null;
    }

    pub fn cancelProjectRename(self: *AppState) void {
        self.rename_project_index = null;
        self.syncRenameBuffer();
    }

    pub fn removeProjectAtIndex(self: *AppState, index: usize) void {
        if (index >= self.projects.items.len) return;
        self.selected_project_index = index;
        self.removeSelectedProject();
        self.rename_project_index = null;
    }

    fn removeSelectedProject(self: *AppState) void {
        if (self.projects.items.len == 0) return;
        var removed = self.projects.orderedRemove(self.selected_project_index);
        removed.deinit(self.allocator);

        if (self.projects.items.len == 0) {
            self.selected_project_index = 0;
        } else if (self.selected_project_index >= self.projects.items.len) {
            self.selected_project_index = self.projects.items.len - 1;
        }

        self.syncRenameBuffer();
        self.setSidebarNotice("Project removed from recents.");
        self.markDirty();
    }

    pub fn createThreadForProject(self: *AppState, index: usize) void {
        if (index >= self.projects.items.len) return;
        var project = &self.projects.items[index];
        project.addThread(self.allocator) catch {
            self.setSidebarNotice("Failed to create a new thread.");
            return;
        };
        self.selected_project_index = index;
        self.syncRenameBuffer();
        self.setSidebarNotice("New thread ready.");
        self.markDirty();
    }

    pub fn sendDraft(self: *AppState) !void {
        const draft = self.currentDraft();
        const draft_image = self.currentThread().draft_image;
        if (draft.len == 0 and draft_image == null) return;

        self.send_state.mutex.lock();
        const send_pending = self.send_state.status == .pending;
        self.send_state.mutex.unlock();
        if (send_pending) {
            self.setSidebarNotice("A provider request is already running.");
            return;
        }

        if (draft_image != null and self.currentThread().provider != .codex) {
            self.setSidebarNotice("Image attachments are available for Codex threads only right now.");
            return;
        }

        const trimmed_title = std.mem.trim(u8, draft, &std.ascii.whitespace);
        const thread = self.currentThreadMutable();
        if (!thread.committed) {
            try thread.commitFromPrompt(self.allocator, if (trimmed_title.len > 0) trimmed_title else "Image");
        }
        var draft_image_copy = draft_image;
        try self.appendMessage(.user, "You", draft, if (draft_image_copy) |*image| image else null);
        try self.beginSendDraft(draft);
        self.clearDraft();
        thread.clearDraftImage(self.allocator);
        self.setSidebarNotice("Waiting for provider reply...");
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
                    .launch_on_connect = true,
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
            .reasoning_effort = thread.reasoning_effort,
            .approval_policy = approvalPolicyForMode(thread.provider, thread.access_mode),
            .sandbox_mode = sandboxModeForMode(thread.provider, thread.access_mode),
        });
    }

    fn beginSendDraft(self: *AppState, prompt: []const u8) !void {
        const page_alloc = std.heap.page_allocator;
        const project = self.currentProject();
        const thread = self.currentThread();

        const request = try page_alloc.create(SendWorkerRequest);
        errdefer page_alloc.destroy(request);
        request.* = .{
            .send_state_ptr = &self.send_state,
            .project_index = self.selected_project_index,
            .thread_index = self.currentProject().selected_thread_index,
            .provider = thread.provider,
            .harness = thread.harness,
            .project_path = try page_alloc.dupe(u8, project.path),
            .prompt = try page_alloc.dupe(u8, prompt),
            .image_path = if (thread.draft_image) |image| try page_alloc.dupe(u8, image.path) else null,
            .provider_thread_id = if (thread.provider_thread_id) |thread_id| try page_alloc.dupe(u8, thread_id) else null,
            .thread_title = try page_alloc.dupe(u8, thread.title),
            .model_ref = if (thread.model_ref) |model_ref| try page_alloc.dupe(u8, model_ref) else null,
            .reasoning_effort = thread.reasoning_effort,
            .fast_mode = thread.fast_mode,
            .access_mode = thread.access_mode,
        };
        errdefer {
            page_alloc.free(request.project_path);
            page_alloc.free(request.prompt);
            if (request.image_path) |image_path| page_alloc.free(image_path);
            if (request.provider_thread_id) |thread_id| page_alloc.free(thread_id);
            page_alloc.free(request.thread_title);
            if (request.model_ref) |model_ref| page_alloc.free(model_ref);
        }

        self.send_state.mutex.lock();
        defer self.send_state.mutex.unlock();
        self.send_state.status = .pending;
        self.send_state.result = null;
        self.send_state.error_message = null;
        self.send_state.provider = thread.provider;
        self.send_state.project_index = request.project_index;
        self.send_state.thread_index = request.thread_index;
        self.send_state.partial_text.clearRetainingCapacity();
        freePendingTimelineEventsLocked(page_alloc, &self.send_state.pending_events);
        freePendingDiffFilesLocked(page_alloc, &self.send_state.pending_diff_files);
        freePendingApprovalLocked(page_alloc, &self.send_state.pending_approval);
        self.send_state.approval_decision = null;
        self.send_state.worker = try std.Thread.spawn(.{}, sendWorker, .{ &self.send_state, request });
    }

    fn applyPersisted(self: *AppState, persisted: PersistedState) !void {
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
            loaded.collapsed = project.collapsed orelse false;
            loaded.thread_list_expanded = project.thread_list_expanded orelse false;
            for (loaded.threads.items) |*thread| {
                thread.deinit(self.allocator);
            }
            loaded.threads.clearRetainingCapacity();

            if (project.threads) |threads| {
                for (threads) |persisted_thread| {
                    var thread = try ChatThread.init(self.allocator, persisted_thread.title);
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
                    try loaded.threads.append(self.allocator, thread);
                }
                if (loaded.threads.items.len == 0) {
                    try loaded.addThread(self.allocator);
                }
                loaded.selected_thread_index = @min(project.selected_thread_index, loaded.threads.items.len - 1);
            } else {
                var thread = try ChatThread.init(self.allocator, "New thread");
                thread.committed = project.messages.len > 0;
                thread.last_activity_at = if (thread.committed) std.time.timestamp() else 0;
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
                try loaded.threads.append(self.allocator, thread);
                loaded.selected_thread_index = 0;
            }

            if (index == 0 and project.messages.len == 0 and project.threads == null and persisted.messages != null) {
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

            try self.projects.append(self.allocator, loaded);
        }

        self.selected_project_index = @min(persisted.selected_project_index, self.projects.items.len - 1);
        self.next_project_number = self.projects.items.len + 1;
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

        loaded.value = .{
            .selected_project_index = self.selected_project_index,
            .projects = try projects.toOwnedSlice(arena),
        };
        return loaded;
    }

    fn persistedProjectSnapshot(self: *const AppState, allocator: std.mem.Allocator, project: *const Project) !PersistedProject {
        var threads: std.ArrayList(PersistedThread) = .empty;
        defer threads.deinit(allocator);

        for (project.threads.items) |thread| {
            if (!thread.committed) continue;
            try threads.append(allocator, try self.persistedThreadSnapshot(allocator, &thread));
        }

        return .{
            .id = try allocator.dupe(u8, project.id),
            .label = try allocator.dupe(u8, project.label),
            .path = try allocator.dupe(u8, project.path),
            .unread_count = project.unread_count,
            .collapsed = project.collapsed,
            .thread_list_expanded = project.thread_list_expanded,
            .selected_thread_index = chat_threads.selectedCommittedThreadIndex(project),
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
            .committed = thread.committed,
            .last_activity_at = if (thread.last_activity_at == 0) null else thread.last_activity_at,
            .provider_thread_id = try dupeOptionalSlice(allocator, thread.provider_thread_id),
            .model_ref = try dupeOptionalSlice(allocator, thread.model_ref),
            .reasoning_effort = thread.reasoning_effort,
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

    pub fn attachClipboardImageToCurrentDraft(self: *AppState) void {
        const capture = captureClipboardImage(self.allocator) catch |err| {
            log.err("failed to capture clipboard image: {s}", .{@errorName(err)});
            self.setSidebarNotice("Clipboard image paste failed.");
            return;
        };
        if (capture == null) {
            self.setSidebarNotice("No image found on the clipboard.");
            return;
        }

        const image = capture.?;
        defer self.allocator.free(image.bytes);

        const image_path = self.writeClipboardImageToStorage(image.mime, image.bytes) catch |err| {
            log.err("failed to persist clipboard image: {s}", .{@errorName(err)});
            self.setSidebarNotice("Failed to save clipboard image.");
            return;
        };
        defer self.allocator.free(image_path);

        const thread = self.currentThreadMutable();
        thread.setDraftImage(self.allocator, image_path, image.mime, image.bytes.len) catch |err| {
            log.err("failed to attach draft image: {s}", .{@errorName(err)});
            self.setSidebarNotice("Failed to attach clipboard image.");
            return;
        };
        self.setSidebarNotice("Clipboard image attached.");
        self.markDirty();
    }

    pub fn clearCurrentDraftImage(self: *AppState) void {
        const thread = self.currentThreadMutable();
        if (thread.draft_image) |image| {
            std.fs.deleteFileAbsolute(image.path) catch {};
            self.evictCachedImageTexture(image.path);
            if (self.modal_image_path) |modal_path| {
                if (std.mem.eql(u8, modal_path, image.path)) {
                    self.allocator.free(modal_path);
                    self.modal_image_path = null;
                }
            }
        }
        thread.clearDraftImage(self.allocator);
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
    }

    fn releaseMessage(self: *AppState, message: ChatMessage) void {
        self.allocator.free(message.author);
        self.allocator.free(message.body);
        if (message.image) |image| {
            self.evictCachedImageTexture(image.path);
            var owned_image = image;
            owned_image.deinit(self.allocator);
        }
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
                zgui.openPopup(IMAGE_MODAL_ID, .{});
                return;
            }
            self.allocator.free(existing);
        }
        self.modal_image_path = self.allocator.dupeZ(u8, path) catch return;
        zgui.openPopup(IMAGE_MODAL_ID, .{});
    }

    pub fn closeImageModal(self: *AppState) void {
        if (self.modal_image_path) |path| {
            self.allocator.free(path);
            self.modal_image_path = null;
        }
    }

    fn writeClipboardImageToStorage(self: *AppState, mime: []const u8, bytes: []const u8) ![]u8 {
        const images_dir = try std.fs.path.join(self.allocator, &.{ self.storage.pref_path, "clipboard-images" });
        defer self.allocator.free(images_dir);
        std.fs.makeDirAbsolute(images_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };

        const ext = extensionForImageMime(mime);
        const timestamp_ms = @as(u64, @intCast(@max(@as(i64, 0), std.time.milliTimestamp())));
        var attempt: usize = 0;
        while (attempt < 256) : (attempt += 1) {
            const file_name = if (attempt == 0)
                try std.fmt.allocPrint(self.allocator, "clipboard-{d}.{s}", .{ timestamp_ms, ext })
            else
                try std.fmt.allocPrint(self.allocator, "clipboard-{d}-{d}.{s}", .{ timestamp_ms, attempt, ext });
            defer self.allocator.free(file_name);

            const image_path = try std.fs.path.join(self.allocator, &.{ images_dir, file_name });
            errdefer self.allocator.free(image_path);

            const file = std.fs.createFileAbsolute(image_path, .{ .exclusive = true });
            if (file) |created| {
                defer created.close();
                try created.writeAll(bytes);
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

    pub fn terminalPanelHeight(self: *const AppState, available_height: f32) f32 {
        if (self.projects.items.len == 0) return 0.0;
        return self.currentProjectTerminal().effectiveHeight(available_height);
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
        self.terminal_focused = is_visible;
        self.setSidebarNotice(if (is_visible) "Terminal opened." else "Terminal hidden.");
    }

    pub fn pollTerminals(self: *AppState) void {
        for (self.projects.items, 0..) |*project, project_index| {
            project.terminal_dock.poll(self.allocator) catch |err| {
                log.err("failed to poll terminal session: {s}", .{@errorName(err)});
                if (project_index == self.selected_project_index and project.terminal_dock.visible) {
                    self.setSidebarNotice("Terminal session failed.");
                }
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
        const value = std.posix.getenv("VERDE_OPEN_BROWSER_ON_START") orelse return;
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

        self.browser_state.setControlsVisible(true);
        self.browser_state.status = .opening;
        self.browser_state.controller.show() catch |err| {
            log.err("failed to show browser runtime: {s}", .{@errorName(err)});
            self.browser_state.status = .failed;
            self.browser_state.setLastError("Failed to show browser runtime.") catch {};
            self.setSidebarNotice("Failed to show browser.");
            return;
        };
        self.setSidebarNotice("Browser opened.");
    }

    /// Hides the desktop browser control surface and its browser runtime.
    pub fn hideBrowser(self: *AppState) void {
        self.browser_state.setControlsVisible(false);
        self.browser_pane_focused = false;
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

    /// Records the latest browser pane bounds so SDL events can target the correct in-app viewport.
    pub fn noteBrowserPaneRegion(self: *AppState, min: [2]f32, max: [2]f32, hovered: bool) void {
        self.browser_pane_min = min;
        self.browser_pane_max = max;
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
        pane_event.x = event.x - self.browser_pane_min[0];
        pane_event.y = event.y - self.browser_pane_min[1];

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

    /// Applies queued browser runtime events back onto app-visible browser state.
    pub fn pollBrowser(self: *AppState) void {
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
                .title_changed => |_| {},
                .js_message => |message| {
                    self.browser_state.setLastJsMessage(message) catch {};
                    self.setSidebarNotice("Browser bridge message received.");
                },
                .eval_result => |result| {
                    self.browser_state.setLastEvalResult(result) catch {};
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

    pub fn hasActiveTerminalSessions(self: *const AppState) bool {
        for (self.projects.items) |*project| {
            if (project.terminal_dock.hasRunningSession()) return true;
        }
        return false;
    }

    pub fn handleTerminalKeyDown(self: *AppState, event: *const sdl.KeyboardEvent) bool {
        if (!self.terminal_focused or !self.isTerminalVisible()) return false;
        return self.currentProjectTerminalMutable().handleKeyDown(event);
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

    pub fn draftBuffer(self: *AppState) [:0]u8 {
        return self.currentProjectMutable().draftBuffer();
    }

    fn setDraft(self: *AppState, value: []const u8) void {
        self.currentProjectMutable().setDraft(value);
        self.markDirty();
    }

    fn clearDraft(self: *AppState) void {
        self.currentProjectMutable().clearDraft();
        self.markDirty();
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
        self.dirty = true;
    }

    pub fn requestTranscriptScrollToBottom(self: *AppState) void {
        self.scroll_transcript_to_bottom = true;
    }

    fn importPath(self: *const AppState) []const u8 {
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
    }

    pub fn flushIfDirty(self: *AppState) void {
        if (!self.dirty) return;

        self.storage.save(self) catch |err| {
            log.err("failed to save native state: {s}", .{@errorName(err)});
            return;
        };
        self.dirty = false;
    }

    pub fn reloadFromStorage(self: *AppState) !void {
        self.flushIfDirty();
        self.clearProjects();

        if (try self.storage.load(self.allocator)) |persisted_value| {
            var persisted = persisted_value;
            defer persisted.deinit();
            try self.applyPersisted(persisted.value);
        } else {
            try self.seedDefaultState();
        }

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
        self.finishPickerThread();
        self.finishSendThread();
        self.pollSend();
        self.flushIfDirty();
        self.send_state.partial_text.deinit(std.heap.page_allocator);
        freePendingTimelineEvents(std.heap.page_allocator, &self.send_state.pending_events);
        freePendingDiffFiles(std.heap.page_allocator, &self.send_state.pending_diff_files);
        freePendingApproval(std.heap.page_allocator, &self.send_state.pending_approval);
        self.file_search_state.deinit(self.allocator);
        self.clearProjects();
        self.browser_state.deinit();
        self.releaseAllImageTextures();
        self.app_config.deinit(self.allocator);
        self.projects.deinit(self.allocator);
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
            self.finishPickerThread();
        }

        switch (next_status) {
            .selected => {
                if (picked_path) |path| {
                    defer std.heap.page_allocator.free(path);
                    self.setImportPath(path);
                    self.setSidebarNotice("Folder selected.");
                }
            },
            .cancelled => self.setSidebarNotice("Folder selection cancelled."),
            .unavailable => self.setSidebarNotice("No folder picker found. Paste a directory path manually."),
            .failed => self.setSidebarNotice("Folder picker failed."),
            else => {},
        }
    }

    pub fn pollSend(self: *AppState) void {
        var completed_result: ?SendResultPayload = null;
        var failed_message: ?[]u8 = null;
        var next_status: SendStatus = .idle;
        var completed_events: std.ArrayListUnmanaged(PendingTimelineEvent) = .empty;
        var completed_diff_files: std.ArrayListUnmanaged(PendingDiffFile) = .empty;
        var failed_project_index: ?usize = null;
        var failed_thread_index: ?usize = null;

        self.send_state.mutex.lock();
        switch (self.send_state.status) {
            .completed => {
                completed_result = self.send_state.result;
                self.send_state.result = null;
                flushPendingAssistantTextLocked(&self.send_state, std.heap.page_allocator);
                completed_events = self.send_state.pending_events;
                self.send_state.pending_events = .empty;
                completed_diff_files = self.send_state.pending_diff_files;
                self.send_state.pending_diff_files = .empty;
                freePendingApprovalLocked(std.heap.page_allocator, &self.send_state.pending_approval);
                self.send_state.approval_decision = null;
                self.send_state.provider = null;
                self.send_state.project_index = null;
                self.send_state.thread_index = null;
                self.send_state.status = .idle;
                next_status = .completed;
            },
            .failed => {
                failed_message = self.send_state.error_message;
                self.send_state.error_message = null;
                self.send_state.partial_text.clearRetainingCapacity();
                completed_events = self.send_state.pending_events;
                self.send_state.pending_events = .empty;
                completed_diff_files = self.send_state.pending_diff_files;
                self.send_state.pending_diff_files = .empty;
                failed_project_index = self.send_state.project_index;
                failed_thread_index = self.send_state.thread_index;
                freePendingApprovalLocked(std.heap.page_allocator, &self.send_state.pending_approval);
                self.send_state.approval_decision = null;
                self.send_state.provider = null;
                self.send_state.project_index = null;
                self.send_state.thread_index = null;
                self.send_state.status = .idle;
                next_status = .failed;
            },
            else => {},
        }
        self.send_state.mutex.unlock();

        if (next_status != .idle) {
            self.finishSendThread();
        }

        switch (next_status) {
            .completed => {
                if (completed_result) |result| {
                    defer std.heap.page_allocator.free(result.provider_thread_id);
                    defer std.heap.page_allocator.free(result.reply_text);
                    defer freePendingTimelineEvents(std.heap.page_allocator, &completed_events);
                    defer freePendingDiffFiles(std.heap.page_allocator, &completed_diff_files);
                    appendPendingDiffSummaryEvent(std.heap.page_allocator, &completed_events, completed_diff_files.items);
                    const should_append_reply_text = !pendingTimelineEventsContainAssistant(completed_events.items);
                    self.applyPendingTimelineEvents(result, &completed_events) catch |err| {
                        log.err("failed to apply timeline events: {s}", .{@errorName(err)});
                    };
                    self.applySendSuccess(result, should_append_reply_text) catch |err| {
                        log.err("failed to apply send result: {s}", .{@errorName(err)});
                        self.setSidebarNotice("Failed to apply provider reply.");
                    };
                }
            },
            .failed => {
                defer freePendingTimelineEvents(std.heap.page_allocator, &completed_events);
                defer freePendingDiffFiles(std.heap.page_allocator, &completed_diff_files);
                appendPendingDiffSummaryEvent(std.heap.page_allocator, &completed_events, completed_diff_files.items);
                if (failed_message) |message| {
                    defer std.heap.page_allocator.free(message);
                    if (failed_project_index) |project_index| {
                        if (failed_thread_index) |thread_index| {
                            self.applySendFailure(project_index, thread_index, &completed_events, message) catch |err| {
                                log.err("failed to apply send failure: {s}", .{@errorName(err)});
                            };
                        }
                    }
                    self.setSidebarNotice(message);
                } else {
                    self.setSidebarNotice("Provider request failed.");
                }
            },
            else => {},
        }
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

    fn finishSendThread(self: *AppState) void {
        self.send_state.mutex.lock();
        const maybe_worker = self.send_state.worker;
        self.send_state.worker = null;
        self.send_state.mutex.unlock();

        if (maybe_worker) |worker| {
            worker.join();
        }
    }

    pub fn hasPendingStream(self: *AppState) bool {
        self.send_state.mutex.lock();
        defer self.send_state.mutex.unlock();

        if (self.send_state.status != .pending) return false;
        if (self.send_state.project_index != self.selected_project_index) return false;
        if (self.send_state.thread_index != self.currentProject().selected_thread_index) return false;
        return true;
    }

    pub fn isPickerPending(self: *AppState) bool {
        self.picker_state.mutex.lock();
        defer self.picker_state.mutex.unlock();
        return self.picker_state.status == .pending;
    }

    pub fn pendingApprovalSnapshot(self: *AppState) !?PendingApproval {
        self.send_state.mutex.lock();
        defer self.send_state.mutex.unlock();

        if (self.send_state.status != .pending) return null;
        if (self.send_state.project_index != self.selected_project_index) return null;
        if (self.send_state.thread_index != self.currentProject().selected_thread_index) return null;
        const approval = self.send_state.pending_approval orelse return null;
        return .{
            .call_id = try self.allocator.dupe(u8, approval.call_id),
            .title = try self.allocator.dupe(u8, approval.title),
            .body = try self.allocator.dupe(u8, approval.body),
        };
    }

    pub fn resolvePendingApproval(self: *AppState, decision: ai_harness.ApprovalDecision) void {
        self.send_state.mutex.lock();
        defer self.send_state.mutex.unlock();
        if (self.send_state.pending_approval == null) return;
        self.send_state.approval_decision = decision;
        self.send_state.condition.broadcast();
    }

    fn applySendSuccess(self: *AppState, result: SendResultPayload, append_reply_text: bool) !void {
        if (result.project_index >= self.projects.items.len) return;
        const project = &self.projects.items[result.project_index];
        if (result.thread_index >= project.threads.items.len) return;
        const thread = &project.threads.items[result.thread_index];

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

    fn applyPendingTimelineEvents(self: *AppState, result: SendResultPayload, events: *std.ArrayListUnmanaged(PendingTimelineEvent)) !void {
        if (events.items.len == 0) return;
        if (result.project_index >= self.projects.items.len) return;
        const project = &self.projects.items[result.project_index];
        if (result.thread_index >= project.threads.items.len) return;
        const thread = &project.threads.items[result.thread_index];

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
        project_index: usize,
        thread_index: usize,
        events: *std.ArrayListUnmanaged(PendingTimelineEvent),
        failure_message: []const u8,
    ) !void {
        if (project_index >= self.projects.items.len) return;
        const project = &self.projects.items[project_index];
        if (thread_index >= project.threads.items.len) return;
        const thread = &project.threads.items[thread_index];

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
            const home = std.posix.getenv("HOME") orelse return error.EnvironmentVariableNotFound;
            break :blk try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ home, raw_path[2..] });
        } else try self.allocator.dupe(u8, raw_path);
        defer self.allocator.free(expanded);

        const resolved = if (std.fs.path.isAbsolute(expanded))
            try std.fs.realpathAlloc(self.allocator, expanded)
        else blk: {
            const cwd = std.fs.cwd();
            break :blk try cwd.realpathAlloc(self.allocator, expanded);
        };

        var dir = try std.fs.openDirAbsolute(resolved, .{});
        dir.close();
        return resolved;
    }

    fn findProjectIndexByPath(self: *const AppState, path: []const u8) ?usize {
        for (self.projects.items, 0..) |project, index| {
            if (std.mem.eql(u8, project.path, path)) return index;
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
        self.clearFileSearch();
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
        for (self.projects.items) |*project| {
            project.deinit(self.allocator);
        }
        self.projects.clearRetainingCapacity();
        self.selected_project_index = 0;
        self.next_project_number = 1;
        self.show_project_creator = false;
        self.clearImportPath();
        self.rename_storage[0] = 0;
        self.dirty = false;
    }

    fn defaultExplorerPath(self: *AppState) ![]u8 {
        if (self.importPath().len > 0) {
            return self.resolveProjectPath(std.mem.trim(u8, self.importPath(), &std.ascii.whitespace));
        }

        if (self.projects.items.len > 0) {
            if (self.resolveProjectPath(self.currentProject().path)) |resolved| {
                return resolved;
            } else |_| {}
        }

        const home = std.posix.getenv("HOME") orelse return self.allocator.dupe(u8, ".");
        return self.allocator.dupe(u8, home);
    }
};

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
