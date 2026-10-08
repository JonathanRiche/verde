//! File viewer tabs (`WorkspacePaneRef.file`): opening/focusing tabs and
//! loading their contents through the daemon (`workspace.files.list` for the
//! workspace roots, `workspace.files.read` for a file).
//!
//! The pane persists an absolute path. On load it maps that path onto the
//! longest matching workspace root (home + verde.toml folders, cached per
//! workspace) and reads `(root id, relative path)`, so the daemon stays the
//! only party deciding what is readable.
//!
//! IO runs on short-lived worker threads (one per call). Finished calls are
//! drained on the UI thread by `pollFileViewer`; workers wake the loop with
//! `loop_wakeup.notify()`. Text is split into lines, tab-expanded, and
//! syntax-tokenized on the worker; images are decoded there too, and only
//! the GPU upload happens on the UI thread.
//!
//! AppState API (`self` is `*AppState`):
//! - `openFileInViewer(abs_path)`: focus the tab already showing `abs_path`,
//!   or open a new file tab. Paths outside every root get a notice instead.
//! - `fileViewerDocument(pane_id)`: per-pane document, created (and its load
//!   started) on first use. `null` only when the pane is not a file pane.
//! - `reloadFileViewerDocument(pane_id)`, `focusFilePane()`,
//!   `pollFileViewer()`, `fileViewerRoots()`.

const std = @import("std");

const palette = @import("palette");
const loop_wakeup = @import("loop_wakeup");
const headless = @import("headless");
const zig_dif = @import("zig_dif");
const daemon_client = @import("../daemon/client.zig");
const utils = @import("../utils.zig");
const platform_runtime = @import("platform_runtime");
const stb_image = @import("../media/stb_image.zig");
const workspace_layout = @import("workspace_layout.zig");
const ui_types = @import("ui_types.zig");
const chat_markdown = @import("../ui/chat_markdown.zig");

const proto = headless.workspace_files_protocol;
const page = std.heap.page_allocator;
const log = std.log.scoped(.file_viewer);

const WorkspacePaneId = workspace_layout.WorkspacePaneId;
pub const Root = proto.Root;
pub const ContentKind = proto.ContentKind;

const ROOTS_TIMEOUT_MS: u32 = 10_000;
const READ_TIMEOUT_MS: u32 = 20_000;
/// Text bytes requested per file; the daemon truncates beyond this.
pub const TEXT_LIMIT_BYTES: u64 = proto.DEFAULT_TEXT_BYTES;
pub const IMAGE_LIMIT_BYTES: u64 = proto.DEFAULT_IMAGE_BYTES;
/// Largest image edge uploaded as a texture.
pub const MAX_IMAGE_EDGE: i32 = 8192;
/// Lines longer than this (display bytes) are drawn without highlighting.
const MAX_HIGHLIGHT_LINE_BYTES: usize = 1000;
const TAB_WIDTH: usize = 4;
/// A tab that has not been drawn for this long reloads when it reappears,
/// so files agents edited in the background are current when looked at.
pub const STALE_RELOAD_MS: i64 = 1500;

// ------------------------------------------------------------------
// Pure helpers (unit tested)
// ------------------------------------------------------------------

pub const Located = struct {
    root: Root,
    /// Root-relative, '/'-separated; "" for the root itself.
    relative: []const u8,
};

/// Maps an absolute path onto the root with the longest matching `path`.
pub fn locate(roots: []const Root, abs_path: []const u8) ?Located {
    var best: ?Located = null;
    for (roots) |root| {
        const base = std.mem.trimEnd(u8, root.path, "/");
        if (!std.mem.startsWith(u8, abs_path, base)) continue;
        const rest = abs_path[base.len..];
        if (rest.len > 0 and rest[0] != '/') continue;
        if (best) |current| {
            if (std.mem.trimEnd(u8, current.root.path, "/").len >= base.len) continue;
        }
        best = .{ .root = root, .relative = std.mem.trim(u8, rest, "/") };
    }
    return best;
}

/// Path shown to agents and in headers: bare for the home root, else
/// prefixed with the root's folder name (matches web/mobile).
pub fn displayPath(allocator: std.mem.Allocator, root_id: []const u8, root_name: []const u8, relative: []const u8) ![]u8 {
    if (std.mem.eql(u8, root_id, proto.HOME_ROOT_ID) or root_name.len == 0) return allocator.dupe(u8, relative);
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ root_name, relative });
}

pub const Line = struct {
    /// Byte span of the source line (without its newline / CR).
    start: u32,
    len: u32,
    /// Tab-expanded text the viewer draws; slices `TextModel.text` when the
    /// line has no tabs.
    display: []const u8,
    token_start: u32 = 0,
    token_count: u32 = 0,
    /// Display columns (codepoints).
    cols: u32 = 0,
};

pub const TextModel = struct {
    lines: []const Line = &.{},
    tokens: []const zig_dif.Token = &.{},
    max_cols: u32 = 0,
    highlighted: bool = false,
};

/// Highlighting language for a file name; null draws plain monochrome text.
pub fn highlightLanguage(name: []const u8) ?zig_dif.Language {
    var buffer: [16]u8 = undefined;
    const ext = proto.extension(name, &buffer);
    const map = [_]struct { []const u8, zig_dif.Language }{
        .{ "zig", .zig },        .{ "zon", .zig },
        .{ "ts", .typescript },  .{ "mts", .typescript },
        .{ "cts", .typescript }, .{ "tsx", .tsx },
        .{ "js", .javascript },  .{ "mjs", .javascript },
        .{ "cjs", .javascript }, .{ "jsx", .jsx },
        .{ "json", .json },      .{ "jsonc", .json },
    };
    for (map) |entry| if (std.mem.eql(u8, ext, entry[0])) return entry[1];
    // Other source files get the heuristic tokenizer (strings, numbers,
    // comments, keywords); prose and data files stay plain.
    const code = [_][]const u8{
        "c",    "h",    "cc",   "cpp",   "hpp", "cxx", "m",     "mm",   "rs",   "go",     "py",     "rb",
        "java", "kt",   "kts",  "swift", "cs",  "sh",  "bash",  "zsh",  "fish", "toml",   "yaml",   "yml",
        "css",  "scss", "less", "html",  "htm", "xml", "sql",   "lua",  "vue",  "svelte", "nix",    "php",
        "pl",   "ex",   "exs",  "erl",   "hs",  "ml",  "scala", "dart", "r",    "ps1",    "gradle", "proto",
    };
    for (code) |candidate| if (std.mem.eql(u8, ext, candidate)) return .plain;
    return null;
}

/// Splits `text` into lines (a final newline does not add an empty line),
/// expands tabs, and tokenizes when `language` is set.
pub fn buildTextModel(allocator: std.mem.Allocator, text: []const u8, language: ?zig_dif.Language) !TextModel {
    var lines: std.ArrayList(Line) = .empty;
    var tokens: std.ArrayList(zig_dif.Token) = .empty;
    var tokenizer: ?zig_dif.syntax.Tokenizer = if (language) |lang| .init(lang) else null;
    defer if (tokenizer) |*value| value.deinit();
    var max_cols: u32 = 0;
    var start: usize = 0;
    while (start < text.len) {
        const newline = std.mem.indexOfScalarPos(u8, text, start, '\n');
        const end = newline orelse text.len;
        var source = text[start..end];
        if (source.len > 0 and source[source.len - 1] == '\r') source = source[0 .. source.len - 1];
        const display = try expandTabs(allocator, source);
        var line: Line = .{
            .start = @intCast(start),
            .len = @intCast(source.len),
            .display = display,
            .cols = @intCast(std.unicode.utf8CountCodepoints(display) catch display.len),
        };
        max_cols = @max(max_cols, line.cols);
        if (tokenizer) |*value| {
            line.token_start = @intCast(tokens.items.len);
            if (display.len <= MAX_HIGHLIGHT_LINE_BYTES) {
                const line_tokens = try value.tokenizeLine(allocator, display);
                try tokens.appendSlice(allocator, line_tokens);
                line.token_count = @intCast(line_tokens.len);
            } else if (display.len > 0) {
                try tokens.append(allocator, .{ .kind = .plain, .text = display });
                line.token_count = 1;
            }
        }
        try lines.append(allocator, line);
        start = (newline orelse break) + 1;
    }
    return .{
        .lines = try lines.toOwnedSlice(allocator),
        .tokens = try tokens.toOwnedSlice(allocator),
        .max_cols = max_cols,
        .highlighted = tokenizer != null,
    };
}

fn expandTabs(allocator: std.mem.Allocator, source: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, source, '\t') == null) return source;
    var out: std.ArrayList(u8) = .empty;
    var col: usize = 0;
    for (source) |byte| {
        if (byte == '\t') {
            const spaces = TAB_WIDTH - (col % TAB_WIDTH);
            try out.appendNTimes(allocator, ' ', spaces);
            col += spaces;
            continue;
        }
        try out.append(allocator, byte);
        // Count codepoints, not continuation bytes.
        if (byte & 0xC0 != 0x80) col += 1;
    }
    return out.toOwnedSlice(allocator);
}

/// Source text of lines `first..last` (inclusive, 0-based) joined by '\n'.
pub fn sourceForLines(text: []const u8, lines: []const Line, first: usize, last: usize) []const u8 {
    if (lines.len == 0 or first >= lines.len) return "";
    const end_line = lines[@min(last, lines.len - 1)];
    const start = lines[first].start;
    return text[start .. end_line.start + end_line.len];
}

pub fn messageForError(code: ?[]const u8, message: []const u8) []const u8 {
    const value = code orelse return if (message.len > 0) message else "Could not load this file.";
    const table = [_]struct { []const u8, []const u8 }{
        .{ proto.ERR_NOT_FOUND, "This file no longer exists." },
        .{ proto.ERR_NOT_FILE, "This path is not a regular file." },
        .{ proto.ERR_PATH_OUTSIDE_ROOTS, "This file is outside the workspace folders." },
        .{ proto.ERR_ROOT_NOT_FOUND, "This file's folder is no longer part of the workspace." },
        .{ "method_not_found", "The running Verde daemon does not support the file viewer yet. Restart it to update." },
        .{ "unknown_method", "The running Verde daemon does not support the file viewer yet. Restart it to update." },
        .{ "resource_not_found", "This workspace is not known to the Verde daemon yet." },
    };
    for (table) |entry| if (std.mem.eql(u8, value, entry[0])) return entry[1];
    return if (message.len > 0) message else "Could not load this file.";
}

// ------------------------------------------------------------------
// Worker calls
// ------------------------------------------------------------------

const CallKind = enum { roots, read };

const Call = struct {
    kind: CallKind,
    thread: std.Thread = undefined,
    done: std.atomic.Value(bool) = .init(false),
    /// Request identity, page-owned.
    workspace_id: []u8,
    pane_id: WorkspacePaneId = 0,
    path: []u8 = &.{},
    generation: u32 = 0,
    pref_path: []u8,
    params_json: []u8,
    /// Result data; adopted by the document/roots entry on success.
    arena: std.heap.ArenaAllocator = .init(page),
    err_code: ?[]const u8 = null,
    err_message: []const u8 = "",
    roots: []const Root = &.{},
    loaded: Loaded = .{},

    fn destroy(self: *Call) void {
        page.free(self.workspace_id);
        page.free(self.path);
        page.free(self.pref_path);
        page.free(self.params_json);
        if (self.loaded.image) |image| image.deinit();
        self.arena.deinit();
        page.destroy(self);
    }
};

/// A finished `workspace.files.read`, prepared for drawing.
const Loaded = struct {
    name: []const u8 = "",
    kind: ContentKind = .text,
    size: u64 = 0,
    truncated: bool = false,
    mime: ?[]const u8 = null,
    text: []const u8 = "",
    model: TextModel = .{},
    image: ?stb_image.LoadedImage = null,
    image_error: ?[]const u8 = null,
};

fn workerMain(call: *Call) void {
    runCall(call);
    call.done.store(true, .release);
    loop_wakeup.notify();
}

fn runCall(call: *Call) void {
    const arena = call.arena.allocator();
    var params = std.json.parseFromSlice(std.json.Value, page, call.params_json, .{}) catch {
        call.err_message = "Could not encode the request.";
        return;
    };
    defer params.deinit();
    var transport: daemon_client.HeadlessTransport = .{
        .allocator = page,
        .pref_path = call.pref_path,
        .timeout_ms = if (call.kind == .roots) ROOTS_TIMEOUT_MS else READ_TIMEOUT_MS,
    };
    var client = daemon_client.headlessClient(page, &transport);
    const method = switch (call.kind) {
        .roots => proto.METHOD_LIST,
        .read => proto.METHOD_READ,
    };
    var parsed = client.call(method, params.value) catch {
        call.err_message = "Could not reach the Verde daemon, or it took too long to answer.";
        return;
    };
    defer parsed.deinit();
    if (parsed.response.err) |err| {
        call.err_code = arena.dupe(u8, err.code) catch null;
        call.err_message = arena.dupe(u8, err.message) catch "";
        return;
    }
    const value = parsed.response.result orelse {
        call.err_message = "The daemon returned an empty response.";
        return;
    };
    const options: std.json.ParseOptions = .{ .ignore_unknown_fields = true, .allocate = .alloc_always };
    switch (call.kind) {
        .roots => {
            const result = std.json.parseFromValueLeaky(proto.ListResult, arena, value, options) catch {
                call.err_message = "The daemon returned an unexpected response.";
                return;
            };
            call.roots = result.roots;
        },
        .read => {
            const result = std.json.parseFromValueLeaky(proto.ReadResult, arena, value, options) catch {
                call.err_message = "The daemon returned an unexpected response.";
                return;
            };
            prepareRead(call, arena, result) catch {
                call.err_message = "Not enough memory to show this file.";
            };
        },
    }
}

fn prepareRead(call: *Call, arena: std.mem.Allocator, result: proto.ReadResult) !void {
    var loaded: Loaded = .{
        .name = result.name,
        .kind = result.kind,
        .size = result.size,
        .truncated = result.truncated,
        .mime = result.mime,
    };
    switch (result.kind) {
        .text, .markdown => if (result.encoding == .utf8) {
            loaded.text = result.content;
            if (result.kind == .text) loaded.model = try buildTextModel(arena, result.content, highlightLanguage(result.name));
        },
        .image => if (result.encoding == .base64) {
            const decoder = std.base64.standard.Decoder;
            const size = decoder.calcSizeForSlice(result.content) catch {
                loaded.image_error = "The image data is corrupt.";
                call.loaded = loaded;
                return;
            };
            const bytes = try page.alloc(u8, size);
            defer page.free(bytes);
            decoder.decode(bytes, result.content) catch {
                loaded.image_error = "The image data is corrupt.";
                call.loaded = loaded;
                return;
            };
            if (stb_image.loadFromMemory(bytes)) |image| {
                if (image.width <= 0 or image.height <= 0 or image.width > MAX_IMAGE_EDGE or image.height > MAX_IMAGE_EDGE) {
                    image.deinit();
                    loaded.image_error = "This image is too large to preview.";
                } else loaded.image = image;
            } else |_| loaded.image_error = "This image format cannot be previewed.";
        },
        .binary, .external, .too_large => {},
    }
    call.loaded = loaded;
}

fn startCall(self: anytype, call_template: Call, params: anytype) bool {
    const state = &self.file_viewer;
    const call = page.create(Call) catch return false;
    call.* = call_template;
    call.params_json = std.json.Stringify.valueAlloc(page, params, .{ .emit_null_optional_fields = false }) catch {
        page.destroy(call);
        return false;
    };
    call.pref_path = page.dupe(u8, self.storage.pref_path) catch {
        page.free(call.params_json);
        page.destroy(call);
        return false;
    };
    state.calls.append(page, call) catch {
        page.free(call.params_json);
        page.free(call.pref_path);
        page.destroy(call);
        return false;
    };
    call.thread = std.Thread.spawn(.{}, workerMain, .{call}) catch {
        _ = state.calls.pop();
        page.free(call.params_json);
        page.free(call.pref_path);
        page.destroy(call);
        return false;
    };
    return true;
}

// ------------------------------------------------------------------
// State
// ------------------------------------------------------------------

pub const RootsStatus = enum { loading, ready, failed };

pub const RootsEntry = struct {
    workspace_id: []u8,
    status: RootsStatus = .loading,
    arena: std.heap.ArenaAllocator = .init(page),
    roots: []const Root = &.{},
    message: []const u8 = "",

    fn deinit(self: *RootsEntry) void {
        page.free(self.workspace_id);
        self.arena.deinit();
    }
};

pub const DocumentStatus = enum { waiting_roots, loading, ready, failed };

/// Selected line range (0-based, inclusive, unordered).
pub const LineSelection = struct {
    anchor: u32,
    head: u32,

    pub fn first(self: LineSelection) u32 {
        return @min(self.anchor, self.head);
    }

    pub fn last(self: LineSelection) u32 {
        return @max(self.anchor, self.head);
    }
};

pub const Document = struct {
    workspace_id: []u8,
    pane_id: WorkspacePaneId,
    /// Absolute path, page-owned.
    path: []u8,
    status: DocumentStatus = .waiting_roots,
    /// Static or arena-owned failure text for `.failed`.
    message: []const u8 = "",
    /// Owns everything below that came from the daemon.
    arena: std.heap.ArenaAllocator = .init(page),
    root_id: []const u8 = "",
    root_name: []const u8 = "",
    relative: []const u8 = "",
    loaded: Loaded = .{},
    has_content: bool = false,
    load_generation: u32 = 0,
    loading: bool = false,
    roots_retried: bool = false,
    texture: ?ui_types.CachedImageTexture = null,
    /// Markdown view (built on first draw) and its rendered command cache,
    /// origin-relative and keyed by width + UI scale.
    markdown: ?chat_markdown.BodyView = null,
    markdown_failed: bool = false,
    md_batch: palette.RenderBatch = .{},
    md_frame_text: std.ArrayList(u8) = .empty,
    md_text_arena: std.heap.ArenaAllocator = .init(page),
    md_valid: bool = false,
    md_width: f32 = 0.0,
    md_scale: f32 = 0.0,
    md_height: f32 = 0.0,
    last_render_ms: i64 = 0,
    /// View state (drawable pixels, except `scroll_y` which lives on the pane).
    scroll_x: f32 = 0.0,
    selection: ?LineSelection = null,

    fn deinit(self: *Document, app: anytype) void {
        self.dropContent(app);
        self.freeOwned(app.allocator);
    }

    fn freeOwned(self: *Document, allocator: std.mem.Allocator) void {
        if (self.loaded.image) |image| image.deinit();
        self.loaded.image = null;
        if (self.markdown) |*view| view.deinit(allocator);
        self.markdown = null;
        self.md_batch.deinit(allocator);
        self.md_frame_text.deinit(allocator);
        self.md_text_arena.deinit();
        page.free(self.workspace_id);
        page.free(self.path);
        self.arena.deinit();
    }

    pub fn invalidateMarkdownCache(self: *Document) void {
        self.md_batch.clear();
        self.md_frame_text.clearRetainingCapacity();
        _ = self.md_text_arena.reset(.retain_capacity);
        self.md_valid = false;
    }

    fn dropContent(self: *Document, app: anytype) void {
        if (self.texture) |texture| app.releaseTexture(texture.texture_id);
        self.texture = null;
        if (self.loaded.image) |image| image.deinit();
        self.loaded.image = null;
        if (self.markdown) |*view| view.deinit(app.allocator);
        self.markdown = null;
        self.markdown_failed = false;
        self.invalidateMarkdownCache();
    }

    /// Display path (bare for home, "<root name>/<rel>" otherwise).
    pub fn displayPath(self: *const Document, allocator: std.mem.Allocator) ![]u8 {
        if (self.root_id.len == 0) return allocator.dupe(u8, self.path);
        return displayPathFor(allocator, self.root_id, self.root_name, self.relative);
    }

    pub fn name(self: *const Document) []const u8 {
        return std.fs.path.basename(self.path);
    }
};

const displayPathFor = displayPath;

pub const State = struct {
    roots: std.ArrayList(RootsEntry) = .empty,
    documents: std.ArrayList(*Document) = .empty,
    calls: std.ArrayList(*Call) = .empty,

    /// Joins every worker (bounded by request timeouts) and frees all data.
    /// Textures are left to the GPU teardown.
    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        for (self.calls.items) |call| {
            call.thread.join();
            call.destroy();
        }
        self.calls.deinit(page);
        for (self.roots.items) |*entry| entry.deinit();
        self.roots.deinit(page);
        for (self.documents.items) |doc| {
            doc.freeOwned(allocator);
            page.destroy(doc);
        }
        self.documents.deinit(page);
    }
};

// ------------------------------------------------------------------
// AppState-facing API (self is *AppState)
// ------------------------------------------------------------------

fn selectedProjectIndex(self: anytype) ?usize {
    const projects = self.project_controller.projects.items;
    if (projects.len == 0) return null;
    return @min(self.project_controller.selected_index, projects.len - 1);
}

fn rootsEntry(self: anytype, workspace_id: []const u8) ?*RootsEntry {
    for (self.file_viewer.roots.items) |*entry| {
        if (std.mem.eql(u8, entry.workspace_id, workspace_id)) return entry;
    }
    return null;
}

/// Starts (or restarts) the roots fetch for a workspace.
pub fn refreshRoots(self: anytype, workspace_id: []const u8) void {
    const entry = rootsEntry(self, workspace_id) orelse blk: {
        const owned = page.dupe(u8, workspace_id) catch return;
        self.file_viewer.roots.append(page, .{ .workspace_id = owned }) catch {
            page.free(owned);
            return;
        };
        break :blk &self.file_viewer.roots.items[self.file_viewer.roots.items.len - 1];
    };
    for (self.file_viewer.calls.items) |call| {
        if (call.kind == .roots and std.mem.eql(u8, call.workspace_id, workspace_id)) return;
    }
    if (entry.status != .ready) entry.status = .loading;
    const owned_id = page.dupe(u8, workspace_id) catch return;
    if (!startCall(self, .{ .kind = .roots, .workspace_id = owned_id, .pref_path = &.{}, .params_json = &.{} }, proto.ListRequest{ .workspace_id = workspace_id })) {
        page.free(owned_id);
        entry.status = .failed;
        entry.message = "Could not start a daemon request.";
    }
}

/// Roots of the selected workspace, fetching them on first use. Empty while
/// loading.
pub fn fileViewerRoots(self: anytype) []const Root {
    const index = selectedProjectIndex(self) orelse return &.{};
    const workspace_id = self.project_controller.projects.items[index].id;
    const entry = rootsEntry(self, workspace_id) orelse {
        refreshRoots(self, workspace_id);
        return &.{};
    };
    return entry.roots;
}

/// Opens `abs_path` in a file tab of the selected workspace, or focuses the
/// tab already showing it.
pub fn openFileInViewer(self: anytype, abs_path: []const u8) void {
    const project_index = selectedProjectIndex(self) orelse return;
    const normalized = std.fs.path.resolve(self.allocator, &.{abs_path}) catch return;
    defer self.allocator.free(normalized);
    if (!std.fs.path.isAbsolute(normalized)) {
        self.setSidebarNotice("Only absolute file paths can be opened in the viewer.");
        return;
    }
    const project = &self.project_controller.projects.items[project_index];
    if (rootsEntry(self, project.id)) |entry| {
        if (entry.status == .ready and locate(entry.roots, normalized) == null) {
            self.setSidebarNotice("That file is outside this workspace's folders.");
            return;
        }
    } else refreshRoots(self, project.id);

    const layout = &project.workspace_layout;
    if (layout.filePaneIdForPath(normalized)) |pane_id| {
        self.focusWorkspaceOpenPaneFromSidebar(project_index, pane_id);
        self.markDirty();
        return;
    }
    const pane_id = layout.createFilePane(self.allocator, normalized) catch {
        self.setSidebarNotice("Failed to open the file viewer.");
        return;
    };
    const placed = if (layout.root == null or layout.visiblePaneCount() == 0) blk: {
        layout.replaceRootWithLeaf(self.allocator, pane_id) catch break :blk false;
        break :blk true;
    } else blk: {
        const placement: workspace_layout.WorkspacePanePlacement = layout.gridNewPanePlacement() orelse .{
            .pane_id = layout.focused_pane_id orelse layout.firstVisiblePaneId() orelse break :blk false,
            .axis = .vertical,
            .new_after = true,
        };
        layout.splitPaneWithLeaf(self.allocator, placement.pane_id, pane_id, placement.axis, placement.new_after) catch break :blk false;
        break :blk true;
    };
    if (!placed) {
        if (layout.closePane(self.allocator, pane_id)) |removed| {
            var ref = removed;
            workspace_layout.deinitWorkspacePaneRef(&ref, self.allocator);
        }
        self.setSidebarNotice("Failed to open the file viewer.");
        return;
    }
    // Tab order is persisted pane order: new tabs go last.
    _ = layout.movePaneBefore(pane_id, layout.panes.items.len);
    layout.focusCreatedPane(pane_id, self.workspaceScrollingStripActive(layout));
    focusFilePane(self);
    self.markWorkspaceDirty(project_index);
    self.markDirty();
}

/// Keyboard ownership for a focused file tab: nothing else keeps a caret.
pub fn focusFilePane(self: anytype) void {
    self.terminal_controller.focused = false;
    self.composer_controller.focused = false;
    self.composer_controller.composer.focused = false;
    self.browser_controller.address_focused = false;
    self.unfocusBrowserPane();
}

/// True when the selected workspace's focused pane is a file tab.
pub fn focusedFilePaneId(self: anytype) ?WorkspacePaneId {
    const index = selectedProjectIndex(self) orelse return null;
    const layout = &self.project_controller.projects.items[index].workspace_layout;
    const pane = layout.focusedPane() orelse return null;
    return if (pane.ref == .file) pane.id else null;
}

/// File pane reference in the selected workspace.
pub fn filePaneRef(self: anytype, pane_id: WorkspacePaneId) ?*workspace_layout.FilePaneRef {
    const index = selectedProjectIndex(self) orelse return null;
    const layout = &self.project_controller.projects.items[index].workspace_layout;
    const pane = layout.paneByIdMutable(pane_id) orelse return null;
    return switch (pane.ref) {
        .file => |*ref| ref,
        else => null,
    };
}

/// Document for a file pane of the selected workspace; starts its load on
/// first use.
pub fn fileViewerDocument(self: anytype, pane_id: WorkspacePaneId) ?*Document {
    const index = selectedProjectIndex(self) orelse return null;
    const project = &self.project_controller.projects.items[index];
    const ref = filePaneRef(self, pane_id) orelse return null;
    for (self.file_viewer.documents.items) |doc| {
        if (doc.pane_id != pane_id or !std.mem.eql(u8, doc.workspace_id, project.id)) continue;
        if (std.mem.eql(u8, doc.path, ref.path)) return doc;
        // The pane id now names another file; start over.
        removeDocument(self, doc);
        break;
    }
    const doc = page.create(Document) catch return null;
    const workspace_id = page.dupe(u8, project.id) catch {
        page.destroy(doc);
        return null;
    };
    const path = page.dupe(u8, ref.path) catch {
        page.free(workspace_id);
        page.destroy(doc);
        return null;
    };
    doc.* = .{ .workspace_id = workspace_id, .pane_id = pane_id, .path = path };
    self.file_viewer.documents.append(page, doc) catch {
        doc.deinit(self);
        page.destroy(doc);
        return null;
    };
    startLoad(self, doc);
    return doc;
}

fn removeDocument(self: anytype, doc: *Document) void {
    for (self.file_viewer.documents.items, 0..) |candidate, index| {
        if (candidate != doc) continue;
        _ = self.file_viewer.documents.swapRemove(index);
        break;
    }
    doc.deinit(self);
    page.destroy(doc);
}

/// Re-reads a document from disk, keeping the current content on screen
/// until the new one arrives.
pub fn reloadFileViewerDocument(self: anytype, pane_id: WorkspacePaneId) void {
    const doc = fileViewerDocument(self, pane_id) orelse return;
    if (doc.loading) return;
    startLoad(self, doc);
    self.markDirty();
}

fn startLoad(self: anytype, doc: *Document) void {
    const entry = rootsEntry(self, doc.workspace_id) orelse {
        doc.status = if (doc.has_content) doc.status else .waiting_roots;
        refreshRoots(self, doc.workspace_id);
        doc.loading = true;
        return;
    };
    switch (entry.status) {
        .loading => {
            if (!doc.has_content) doc.status = .waiting_roots;
            doc.loading = true;
            return;
        },
        .failed => {
            failDocument(doc, entry.message);
            return;
        },
        .ready => {},
    }
    const located = locate(entry.roots, doc.path) orelse {
        failDocument(doc, "This file is outside the workspace folders.");
        return;
    };
    // Root/relative strings outlive reloads: keep them in the document
    // arena only when they change.
    if (!std.mem.eql(u8, doc.root_id, located.root.id) or !std.mem.eql(u8, doc.relative, located.relative)) {
        const arena = doc.arena.allocator();
        doc.root_id = arena.dupe(u8, located.root.id) catch return failDocument(doc, "Not enough memory.");
        doc.root_name = arena.dupe(u8, located.root.name) catch return failDocument(doc, "Not enough memory.");
        doc.relative = arena.dupe(u8, located.relative) catch return failDocument(doc, "Not enough memory.");
    }
    doc.load_generation +%= 1;
    const workspace_id = page.dupe(u8, doc.workspace_id) catch return failDocument(doc, "Not enough memory.");
    const path = page.dupe(u8, doc.path) catch {
        page.free(workspace_id);
        return failDocument(doc, "Not enough memory.");
    };
    const started = startCall(self, .{
        .kind = .read,
        .workspace_id = workspace_id,
        .pane_id = doc.pane_id,
        .path = path,
        .generation = doc.load_generation,
        .pref_path = &.{},
        .params_json = &.{},
    }, proto.ReadRequest{
        .workspace_id = doc.workspace_id,
        .root = located.root.id,
        .path = located.relative,
        .max_bytes = TEXT_LIMIT_BYTES,
        .max_image_bytes = IMAGE_LIMIT_BYTES,
    });
    if (!started) {
        page.free(workspace_id);
        page.free(path);
        return failDocument(doc, "Could not start a daemon request.");
    }
    doc.loading = true;
    if (!doc.has_content) doc.status = .loading;
}

fn failDocument(doc: *Document, message: []const u8) void {
    doc.loading = false;
    doc.status = .failed;
    doc.message = message;
}

fn findDocument(self: anytype, workspace_id: []const u8, pane_id: WorkspacePaneId, path: []const u8) ?*Document {
    for (self.file_viewer.documents.items) |doc| {
        if (doc.pane_id == pane_id and std.mem.eql(u8, doc.workspace_id, workspace_id) and std.mem.eql(u8, doc.path, path)) return doc;
    }
    return null;
}

/// Drains finished workers; frees documents whose pane is gone. Called once
/// per loop iteration from `main.zig`.
pub fn pollFileViewer(self: anytype) void {
    const state = &self.file_viewer;
    var changed = false;
    var index: usize = 0;
    while (index < state.calls.items.len) {
        const call = state.calls.items[index];
        if (!call.done.load(.acquire)) {
            index += 1;
            continue;
        }
        _ = state.calls.orderedRemove(index);
        call.thread.join();
        applyCall(self, call);
        call.destroy();
        changed = true;
    }
    if (pruneDocuments(self)) changed = true;
    if (changed) self.markDirty();
}

fn applyCall(self: anytype, call: *Call) void {
    switch (call.kind) {
        .roots => {
            const entry = rootsEntry(self, call.workspace_id) orelse return;
            if (call.err_message.len > 0 or call.err_code != null) {
                // Keep previously fetched roots usable after a transient failure.
                if (entry.status != .ready) {
                    entry.status = .failed;
                    entry.arena.deinit();
                    entry.arena = .init(page);
                    entry.message = entry.arena.allocator().dupe(u8, messageForError(call.err_code, call.err_message)) catch "";
                }
            } else {
                entry.arena.deinit();
                entry.arena = call.arena;
                call.arena = .init(page);
                entry.roots = call.roots;
                entry.status = .ready;
                entry.message = "";
            }
            // Documents that waited for these roots start now.
            for (self.file_viewer.documents.items) |doc| {
                if (!std.mem.eql(u8, doc.workspace_id, call.workspace_id)) continue;
                if (doc.status == .waiting_roots or (doc.loading and !hasReadInFlight(self, doc))) {
                    doc.loading = false;
                    startLoad(self, doc);
                }
            }
        },
        .read => {
            const doc = findDocument(self, call.workspace_id, call.pane_id, call.path) orelse return;
            if (call.generation != doc.load_generation) return;
            doc.loading = false;
            if (call.err_message.len > 0 or call.err_code != null) {
                const code = call.err_code orelse "";
                if (std.mem.eql(u8, code, proto.ERR_ROOT_NOT_FOUND) and !doc.roots_retried) {
                    // verde.toml folders changed: refetch roots and retry once.
                    doc.roots_retried = true;
                    if (rootsEntry(self, doc.workspace_id)) |entry| entry.status = .loading;
                    refreshRoots(self, doc.workspace_id);
                    doc.loading = true;
                    return;
                }
                doc.dropContent(self);
                doc.has_content = false;
                doc.loaded = .{};
                doc.status = .failed;
                doc.message = messageForError(call.err_code, call.err_message);
                // Error text from the daemon lives in the call arena.
                if (doc.message.ptr == call.err_message.ptr) {
                    doc.message = doc.arena.allocator().dupe(u8, call.err_message) catch "Could not load this file.";
                }
                return;
            }
            // Swap in the new content. Root strings move with the arena, so
            // re-home them first.
            const root_id = call.arena.allocator().dupe(u8, doc.root_id) catch return;
            const root_name = call.arena.allocator().dupe(u8, doc.root_name) catch return;
            const relative = call.arena.allocator().dupe(u8, doc.relative) catch return;
            doc.dropContent(self);
            doc.arena.deinit();
            doc.arena = call.arena;
            call.arena = .init(page);
            doc.root_id = root_id;
            doc.root_name = root_name;
            doc.relative = relative;
            doc.loaded = call.loaded;
            call.loaded = .{};
            doc.has_content = true;
            doc.roots_retried = false;
            doc.status = .ready;
            doc.message = "";
            if (doc.loaded.image) |image| {
                const width: u32 = @intCast(image.width);
                const height: u32 = @intCast(image.height);
                doc.texture = self.uploadRgbaTexture(width, height, image.pixels[0 .. @as(usize, width) * height * 4]);
                image.deinit();
                doc.loaded.image = null;
                if (doc.texture == null) doc.loaded.image_error = "Could not upload the image.";
            }
            // Clamp a selection that no longer fits the new line count.
            if (doc.selection) |selection| {
                const count: u32 = @intCast(doc.loaded.model.lines.len);
                if (count == 0 or selection.last() >= count) doc.selection = null;
            }
        },
    }
}

fn hasReadInFlight(self: anytype, doc: *const Document) bool {
    for (self.file_viewer.calls.items) |call| {
        if (call.kind == .read and call.pane_id == doc.pane_id and std.mem.eql(u8, call.workspace_id, doc.workspace_id)) return true;
    }
    return false;
}

fn pruneDocuments(self: anytype) bool {
    var removed = false;
    var index: usize = 0;
    while (index < self.file_viewer.documents.items.len) {
        const doc = self.file_viewer.documents.items[index];
        if (documentPaneAlive(self, doc)) {
            index += 1;
            continue;
        }
        removeDocument(self, doc);
        removed = true;
    }
    return removed;
}

fn documentPaneAlive(self: anytype, doc: *const Document) bool {
    for (self.project_controller.projects.items) |*project| {
        if (!std.mem.eql(u8, project.id, doc.workspace_id)) continue;
        const pane = project.workspace_layout.paneById(doc.pane_id) orelse return false;
        return switch (pane.ref) {
            .file => |ref| std.mem.eql(u8, ref.path, doc.path),
            else => false,
        };
    }
    return false;
}

/// Opens the tab's file with the system default application.
pub fn openFileViewerExternally(self: anytype, pane_id: WorkspacePaneId) void {
    const ref = filePaneRef(self, pane_id) orelse return;
    utils.openPathWithSystemHandler(self.allocator, ref.path) catch |err| {
        log.warn("failed to open file externally: {s}", .{@errorName(err)});
        self.setSidebarNotice("Failed to open file with the system default app.");
        return;
    };
    // The external app takes focus; don't treat that as a close request.
    self.external_open_close_suppress_until_ms = platform_runtime.unixTimestampMs() + EXTERNAL_OPEN_CLOSE_SUPPRESS_MS;
}

const EXTERNAL_OPEN_CLOSE_SUPPRESS_MS: i64 = 2000;

/// Records a draw; returns true when the tab reappeared after being hidden
/// long enough that its content should be refreshed.
pub fn noteDocumentRendered(self: anytype, doc: *Document, now_ms: i64) void {
    const hidden_for = now_ms - doc.last_render_ms;
    const reappeared = doc.last_render_ms != 0 and hidden_for > STALE_RELOAD_MS;
    doc.last_render_ms = now_ms;
    if (reappeared and doc.status == .ready and !doc.loading) startLoad(self, doc);
}

// ------------------------------------------------------------------
// Tests
// ------------------------------------------------------------------

test "locate picks the longest matching root and rejects siblings" {
    const roots = [_]Root{
        .{ .id = "home", .name = "verde", .path = "/w/verde" },
        .{ .id = "cloud", .name = "cloud", .path = "/w/verde/cloud" },
        .{ .id = "other", .name = "other", .path = "/w/other/" },
    };
    const home = locate(&roots, "/w/verde/src/main.zig").?;
    try std.testing.expectEqualStrings("home", home.root.id);
    try std.testing.expectEqualStrings("src/main.zig", home.relative);
    const nested = locate(&roots, "/w/verde/cloud/app.ts").?;
    try std.testing.expectEqualStrings("cloud", nested.root.id);
    try std.testing.expectEqualStrings("app.ts", nested.relative);
    try std.testing.expectEqualStrings("README", locate(&roots, "/w/other/README").?.relative);
    try std.testing.expect(locate(&roots, "/w/verde-cloud/x") == null);
    try std.testing.expect(locate(&roots, "/elsewhere") == null);
    try std.testing.expectEqualStrings("", locate(&roots, "/w/verde").?.relative);
}

test "display path is bare for home and folder-prefixed otherwise" {
    const allocator = std.testing.allocator;
    const home = try displayPath(allocator, "home", "verde", "src/a.zig");
    defer allocator.free(home);
    try std.testing.expectEqualStrings("src/a.zig", home);
    const other = try displayPath(allocator, "verde-cloud", "verde-cloud", "app.ts");
    defer allocator.free(other);
    try std.testing.expectEqualStrings("verde-cloud/app.ts", other);
}

test "text model splits lines, expands tabs, and keeps source spans" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const text = "a\tb\r\n\nconst x = 1;\n";
    const model = try buildTextModel(arena.allocator(), text, .zig);
    try std.testing.expectEqual(@as(usize, 3), model.lines.len);
    try std.testing.expectEqualStrings("a   b", model.lines[0].display);
    try std.testing.expectEqualStrings("a\tb", text[model.lines[0].start..][0..model.lines[0].len]);
    try std.testing.expectEqualStrings("", model.lines[1].display);
    try std.testing.expect(model.lines[2].token_count > 0);
    try std.testing.expectEqual(@as(u32, 12), model.max_cols);
    try std.testing.expectEqualStrings("\nconst x = 1;", sourceForLines(text, model.lines, 1, 2));
    try std.testing.expectEqualStrings("a\tb", sourceForLines(text, model.lines, 0, 0));

    const plain = try buildTextModel(arena.allocator(), "no newline", null);
    try std.testing.expectEqual(@as(usize, 1), plain.lines.len);
    try std.testing.expect(!plain.highlighted);
    const empty = try buildTextModel(arena.allocator(), "", null);
    try std.testing.expectEqual(@as(usize, 0), empty.lines.len);
}

test "highlight language covers known code and leaves prose plain" {
    try std.testing.expectEqual(zig_dif.Language.zig, highlightLanguage("build.zig.zon").?);
    try std.testing.expectEqual(zig_dif.Language.tsx, highlightLanguage("App.TSX").?);
    try std.testing.expectEqual(zig_dif.Language.plain, highlightLanguage("main.rs").?);
    try std.testing.expect(highlightLanguage("notes.txt") == null);
    try std.testing.expect(highlightLanguage("LICENSE") == null);
}
