//! In-app folder browser overlay: breadcrumbs, a filter/path field, a Places
//! column (home, source roots, recent project folders), and the folder list.
//! Model and navigation live in `state/folder_browser.zig`; the choice is
//! returned through `AppState.finishFolderBrowser`.

const std = @import("std");
const palette = @import("palette");
const theme = @import("theme.zig");
const runtime = @import("runtime.zig");
const workspace_suggestions = @import("../state/workspace_suggestions.zig");

const log = std.log.scoped(.folder_browser_ui);

const NF_COD_FOLDER = "\u{EA83}";
const NF_COD_FOLDER_OPENED = "\u{EAF7}";
const NF_COD_HOME = "\u{EB06}";
const NF_COD_ARROW_UP = "\u{EAA1}";
const NF_COD_HISTORY = "\u{EA82}";
const NF_COD_ADD = "\u{EA60}";

const ROW_H_UI: f32 = 34.0;
const PLACE_ROW_H_UI: f32 = 30.0;
const PLACES_W_UI: f32 = 190.0;
const MAX_VISIBLE: usize = 4096;
const MAX_PLACES: usize = 16;
const MAX_CRUMBS: usize = 32;
/// Common parents of project checkouts listed under Places when present.
const SOURCE_ROOTS = [_][]const u8{ "development", "Development", "dev", "Projects", "projects", "code", "Code", "src", "repos", "Work", "work" };

const Place = struct {
    label_buf: [128]u8 = undefined,
    label_len: usize = 0,
    path_buf: [1024]u8 = undefined,
    path_len: usize = 0,
    icon: []const u8 = NF_COD_FOLDER,
    recent: bool = false,

    fn label(self: *const Place) []const u8 {
        return self.label_buf[0..self.label_len];
    }
    fn path(self: *const Place) []const u8 {
        return self.path_buf[0..self.path_len];
    }
};

const Crumb = struct {
    rect: palette.Rect = .{},
    /// Byte length of the directory prefix this crumb navigates to.
    prefix_len: usize = 0,
};

// Geometry and caches, recomputed every frame by `computeLayout`.
var modal_rect: palette.Rect = .{};
var up_rect: palette.Rect = .{};
var hidden_rect: palette.Rect = .{};
var input_rect: palette.Rect = .{};
var places_rect: palette.Rect = .{};
var list_rect: palette.Rect = .{};
var cancel_rect: palette.Rect = .{};
var select_rect: palette.Rect = .{};
/// "Let Verde create one": zero-size unless the browser is adding a workspace.
var managed_rect: palette.Rect = .{};
var footer_y: f32 = 0.0;
var max_scroll_y: f32 = 0.0;

var visible: [MAX_VISIBLE]usize = undefined;
var visible_count: usize = 0;
/// A trailing "Create folder" row (index `visible_count`) when the filter
/// names a folder that does not exist yet.
var create_offered = false;
var places: [MAX_PLACES]Place = undefined;
var place_count: usize = 0;
var places_ready = false;
var crumbs: [MAX_CRUMBS]Crumb = undefined;
var crumb_count: usize = 0;
var hovered_row: ?usize = null;
/// Detects filter edits so the first match is highlighted as the user types.
var last_query_hash: u64 = 0;

pub fn isOpen(state: *const runtime.AppState) bool {
    return state.folder_browser.open;
}

fn browser(state: *runtime.AppState) *runtime.FolderBrowser {
    return &state.folder_browser;
}

// ---------------------------------------------------------------------------
// Layout
// ---------------------------------------------------------------------------

fn computeLayout(state: *runtime.AppState, width: f32, height: f32) void {
    const model = browser(state);
    syncFilter(model);
    ensurePlaces(state);

    const modal_w = theme.clampf(width * 0.58, theme.scaledUi(560.0), theme.scaledUi(880.0));
    const modal_h = theme.clampf(height * 0.72, theme.scaledUi(420.0), theme.scaledUi(660.0));
    modal_rect = .{ .x = @round((width - modal_w) * 0.5), .y = @round((height - modal_h) * 0.5), .w = @round(modal_w), .h = @round(modal_h) };

    const pad = theme.scaledUi(18.0);
    const inner_x = modal_rect.x + pad;
    const inner_w = modal_rect.w - pad * 2.0;
    const chip_h = theme.scaledUi(26.0);
    const hidden_w = theme.scaledUi(112.0);
    hidden_rect = .{ .x = inner_x + inner_w - hidden_w, .y = modal_rect.y + pad - theme.scaledUi(2.0), .w = hidden_w, .h = chip_h };

    const crumb_y = modal_rect.y + pad + theme.scaledUi(34.0);
    up_rect = .{ .x = inner_x, .y = crumb_y, .w = theme.scaledUi(30.0), .h = chip_h };
    layoutCrumbs(model, up_rect.x + up_rect.w + theme.scaledUi(8.0), crumb_y, inner_x + inner_w, chip_h);

    input_rect = .{ .x = inner_x, .y = crumb_y + chip_h + theme.scaledUi(12.0), .w = inner_w, .h = theme.scaledUi(36.0) };

    const button_h = theme.scaledUi(34.0);
    footer_y = modal_rect.y + modal_rect.h - pad - button_h;
    select_rect = .{ .x = inner_x + inner_w - theme.scaledUi(220.0), .y = footer_y, .w = theme.scaledUi(220.0), .h = button_h };
    cancel_rect = .{ .x = select_rect.x - theme.scaledUi(10.0) - theme.scaledUi(96.0), .y = footer_y, .w = theme.scaledUi(96.0), .h = button_h };
    managed_rect = if (state.folderBrowserOffersManagedWorkspace())
        .{ .x = inner_x, .y = footer_y, .w = theme.scaledUi(190.0), .h = button_h }
    else
        .{};

    const body_y = input_rect.y + input_rect.h + theme.scaledUi(12.0);
    const body_h = @max(footer_y - theme.scaledUi(14.0) - body_y, theme.scaledUi(60.0));
    const places_w = if (inner_w > theme.scaledUi(520.0)) theme.scaledUi(PLACES_W_UI) else 0.0;
    places_rect = .{ .x = inner_x, .y = body_y, .w = places_w, .h = body_h };
    const list_x = inner_x + places_w + (if (places_w > 0.0) theme.scaledUi(12.0) else 0.0);
    list_rect = .{ .x = list_x, .y = body_y, .w = inner_x + inner_w - list_x, .h = body_h };

    const content_h = theme.scaledUi(ROW_H_UI) * @as(f32, @floatFromInt(rowCount()));
    max_scroll_y = @max(content_h - list_rect.h, 0.0);
    model.scroll_y = theme.clampf(model.scroll_y, 0.0, max_scroll_y);
}

/// Breadcrumbs right-aligned within the row: when the full path does not fit,
/// the leading crumbs drop off so the current folder is always visible.
fn layoutCrumbs(model: *runtime.FolderBrowser, x0: f32, y: f32, x1: f32, h: f32) void {
    crumb_count = 0;
    const dir = model.currentDir();
    const home = model.home.items;
    var starts: [MAX_CRUMBS]usize = undefined;
    var ends: [MAX_CRUMBS]usize = undefined;
    var count: usize = 0;
    var index: usize = 0;
    const under_home = home.len > 1 and std.mem.startsWith(u8, dir, home) and (dir.len == home.len or dir[home.len] == '/');
    if (under_home) {
        starts[0] = 0;
        ends[0] = home.len;
        count = 1;
        index = home.len;
    } else {
        starts[0] = 0;
        ends[0] = 1;
        count = 1;
        index = 1;
    }
    while (index < dir.len and count < MAX_CRUMBS) {
        while (index < dir.len and dir[index] == '/') index += 1;
        if (index >= dir.len) break;
        const start = index;
        while (index < dir.len and dir[index] != '/') index += 1;
        starts[count] = start;
        ends[count] = index;
        count += 1;
    }

    const font_size = theme.scaledUi(13.0);
    const sep_w = theme.scaledUi(16.0);
    var widths: [MAX_CRUMBS]f32 = undefined;
    var first: usize = count;
    var used: f32 = 0.0;
    while (first > 0) {
        const candidate = first - 1;
        const text = crumbLabel(dir, starts[candidate], ends[candidate], candidate, under_home);
        const w = runtime.paletteUiTextPrefixWidth(text, font_size, text.len) + theme.scaledUi(14.0);
        if (used + w + sep_w > x1 - x0 and first < count) break;
        widths[candidate] = w;
        used += w + sep_w;
        first = candidate;
    }
    var x = x0;
    var i = first;
    while (i < count) : (i += 1) {
        crumbs[crumb_count] = .{ .rect = .{ .x = x, .y = y, .w = @min(widths[i], x1 - x), .h = h }, .prefix_len = ends[i] };
        crumb_starts[crumb_count] = starts[i];
        crumb_is_home[crumb_count] = under_home and i == 0;
        crumb_count += 1;
        x += widths[i] + sep_w;
    }
}

var crumb_starts: [MAX_CRUMBS]usize = undefined;
var crumb_is_home: [MAX_CRUMBS]bool = undefined;

fn crumbLabel(dir: []const u8, start: usize, end: usize, index: usize, under_home: bool) []const u8 {
    if (index == 0) return if (under_home) "Home" else "/";
    return dir[start..end];
}

fn rowCount() usize {
    return visible_count + @intFromBool(create_offered);
}

fn syncFilter(model: *runtime.FolderBrowser) void {
    visible_count = model.filtered(&visible);
    create_offered = model.creatableName() != null;
    const hash = std.hash.Wyhash.hash(0, model.query()) ^ std.hash.Wyhash.hash(1, model.currentDir());
    if (hash != last_query_hash) {
        last_query_hash = hash;
        const typing_filter = model.query().len > 0 and !model.queryIsPath();
        model.highlighted = if (typing_filter and rowCount() > 0) 0 else null;
        model.scroll_y = 0.0;
    }
    if (model.highlighted) |row| {
        if (row >= rowCount()) model.highlighted = if (rowCount() > 0) rowCount() - 1 else null;
    }
}

/// Places are gathered once per opening: home, `/`, existing source roots,
/// then recent project folders from the background suggestion scan.
fn ensurePlaces(state: *runtime.AppState) void {
    workspace_suggestions.ensureStarted();
    if (places_ready) return;
    const model = browser(state);
    place_count = 0;
    if (model.isRemote()) {
        // Another machine: only its default root, once the first listing names it.
        if (model.home.items.len > 0) addPlace("Home", model.home.items, NF_COD_HOME, false);
        places_ready = model.home.items.len > 0;
        return;
    }
    const home = model.home.items;
    if (home.len > 0) addPlace("Home", home, NF_COD_HOME, false);
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    for (SOURCE_ROOTS) |root| {
        var buf: [1024]u8 = undefined;
        const path = std.fmt.bufPrint(&buf, "{s}/{s}", .{ home, root }) catch continue;
        const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch continue;
        if (stat.kind == .directory) addPlace(root, path, NF_COD_FOLDER, false);
    }
    addPlace("Computer", "/", NF_COD_FOLDER, false);
    var suggestions: [workspace_suggestions.MAX_SUGGESTIONS]workspace_suggestions.Suggestion = undefined;
    const count = workspace_suggestions.snapshot(&suggestions);
    for (suggestions[0..count]) |*suggestion| addPlace(suggestion.name(), suggestion.path(), NF_COD_HISTORY, true);
    // Recent folders arrive asynchronously; keep polling until they do.
    places_ready = count > 0;
}

fn addPlace(label: []const u8, path: []const u8, icon: []const u8, recent: bool) void {
    if (place_count == MAX_PLACES or label.len > 128 or path.len > 1024) return;
    var place: Place = .{ .icon = icon, .recent = recent, .label_len = label.len, .path_len = path.len };
    @memcpy(place.label_buf[0..label.len], label);
    @memcpy(place.path_buf[0..path.len], path);
    places[place_count] = place;
    place_count += 1;
}

// ---------------------------------------------------------------------------
// Hits, hover, wheel, keys
// ---------------------------------------------------------------------------

pub fn registerHits(
    state: *runtime.AppState,
    width: f32,
    height: f32,
    queueHit: *const fn (*runtime.AppState, palette.Rect, runtime.PaletteModalAction, usize) void,
) void {
    if (!isOpen(state)) {
        places_ready = false;
        return;
    }
    computeLayout(state, width, height);
    // Outside clicks dismiss the topmost modal, which is this browser.
    queueHit(state, .{ .x = 0.0, .y = 0.0, .w = width, .h = height }, .modal_dismiss, 0);
    queueHit(state, modal_rect, .folder_browser_block, 0);
    queueHit(state, input_rect, .folder_browser_input, 0);
    queueHit(state, up_rect, .folder_browser_up, 0);
    queueHit(state, hidden_rect, .folder_browser_hidden, 0);
    queueHit(state, cancel_rect, .folder_browser_cancel, 0);
    queueHit(state, select_rect, .folder_browser_select, 0);
    if (managed_rect.w > 0.0) queueHit(state, managed_rect, .folder_browser_managed, 0);
    for (crumbs[0..crumb_count], 0..) |crumb, index| queueHit(state, crumb.rect, .folder_browser_crumb, index);
    if (places_rect.w > 0.0) {
        for (0..place_count) |index| {
            const rect = placeRect(index);
            if (rect.y + rect.h > places_rect.y + places_rect.h) break;
            queueHit(state, rect, .folder_browser_place, index);
        }
    }
    for (0..rowCount()) |row| {
        const rect = rowRect(state, row);
        if (rect.y + rect.h < list_rect.y or rect.y > list_rect.y + list_rect.h) continue;
        queueHit(state, intersect(rect, list_rect), .folder_browser_row, row);
    }
}

pub fn updateHover(state: *runtime.AppState, x: f32, y: f32) void {
    var next: ?usize = null;
    if (isOpen(state) and rectContains(list_rect, x, y)) {
        const row_h = theme.scaledUi(ROW_H_UI);
        const offset = y - list_rect.y + browser(state).scroll_y;
        if (offset >= 0.0) {
            const row: usize = @intFromFloat(offset / row_h);
            if (row < rowCount()) next = row;
        }
    }
    if (next != hovered_row) {
        hovered_row = next;
        state.markDirty();
    }
}

pub fn handleWheel(state: *runtime.AppState, x: f32, y: f32, wheel_y: f32) bool {
    if (!isOpen(state)) return false;
    if (rectContains(list_rect, x, y)) {
        const model = browser(state);
        model.scroll_y = theme.clampf(model.scroll_y - wheel_y * theme.scaledUi(48.0), 0.0, max_scroll_y);
        state.markDirty();
    }
    return true;
}

pub fn handleClick(state: *runtime.AppState, action: runtime.PaletteModalAction, index: usize, clicks: u8) void {
    const model = browser(state);
    const allocator = state.allocator;
    switch (action) {
        .folder_browser_block => {},
        .folder_browser_cancel => state.finishFolderBrowser(null),
        .folder_browser_select => selectTarget(state),
        .folder_browser_managed => {
            state.createManagedWorkspaceFromFolderBrowser();
            return;
        },
        .folder_browser_up => _ = model.navigateUp(allocator),
        .folder_browser_hidden => model.show_hidden = !model.show_hidden,
        .folder_browser_crumb => if (index < crumb_count) {
            const owned = allocator.dupe(u8, model.currentDir()[0..crumbs[index].prefix_len]) catch return;
            defer allocator.free(owned);
            _ = model.navigate(allocator, if (owned.len == 0) "/" else owned);
        },
        .folder_browser_place => if (index < place_count) {
            _ = model.navigate(allocator, places[index].path());
        },
        .folder_browser_row => if (index < rowCount()) {
            // The "Create directory" row is an action, not a folder to
            // select first: one click creates it.
            if (clicks >= 2 or isCreateRow(index)) {
                openRow(state, index);
            } else {
                model.highlighted = index;
            }
        },
        else => {},
    }
    state.markDirty();
}

/// Browser-owned keys. Returns false for text-editing keys the shared modal
/// field path handles (characters, caret movement, clipboard).
pub fn handleKeyDown(state: *runtime.AppState, event: *const palette.event.KeyEvent) bool {
    if (!isOpen(state)) return false;
    const model = browser(state);
    const primary = event.mod.primary();
    const query_empty = model.query().len == 0;
    switch (event.key) {
        .escape => state.finishFolderBrowser(null),
        .up => moveHighlight(state, -1),
        .down => moveHighlight(state, 1),
        .pageup => moveHighlight(state, -10),
        .pagedown => moveHighlight(state, 10),
        .@"return", .kp_enter => {
            if (primary) {
                selectTarget(state);
            } else if (model.queryIsPath()) {
                const typed = state.allocator.dupe(u8, model.query()) catch return true;
                defer state.allocator.free(typed);
                _ = model.navigate(state.allocator, typed);
            } else if (model.highlighted) |row| {
                openRow(state, row);
            } else {
                selectTarget(state);
            }
        },
        .tab => if (model.highlighted) |row| openRow(state, row),
        .backspace => {
            if (!query_empty) return false;
            _ = model.navigateUp(state.allocator);
        },
        .left => {
            if (!query_empty) return false;
            _ = model.navigateUp(state.allocator);
        },
        .right => {
            if (!query_empty) return false;
            if (model.highlighted) |row| openRow(state, row);
        },
        .h => {
            if (!primary) return false;
            model.show_hidden = !model.show_hidden;
        },
        else => return false,
    }
    state.markDirty();
    return true;
}

fn moveHighlight(state: *runtime.AppState, delta: i32) void {
    const model = browser(state);
    if (rowCount() == 0) {
        model.highlighted = null;
        return;
    }
    const last: i32 = @intCast(rowCount() - 1);
    const current: i32 = if (model.highlighted) |row| @intCast(row) else if (delta > 0) -1 else last + 1;
    const next = std.math.clamp(current + delta, 0, last);
    model.highlighted = @intCast(next);
    // Keep the highlighted row inside the list viewport.
    const row_h = theme.scaledUi(ROW_H_UI);
    const top = @as(f32, @floatFromInt(next)) * row_h;
    if (top < model.scroll_y) model.scroll_y = top;
    if (top + row_h > model.scroll_y + list_rect.h) model.scroll_y = top + row_h - list_rect.h;
}

fn openRow(state: *runtime.AppState, row: usize) void {
    const model = browser(state);
    if (row == visible_count and create_offered) {
        const name = state.allocator.dupe(u8, model.creatableName() orelse return) catch return;
        defer state.allocator.free(name);
        _ = model.createFolder(state.allocator, name);
        return;
    }
    if (row >= visible_count) return;
    const name = state.allocator.dupe(u8, model.entries.items[visible[row]].name) catch return;
    defer state.allocator.free(name);
    _ = model.navigateInto(state.allocator, name);
}

fn isCreateRow(row: usize) bool {
    return create_offered and row == visible_count;
}

/// True while the highlighted row is "Create directory …", so the primary
/// button creates that folder instead of picking the listed one.
fn createRowHighlighted(model: *const runtime.FolderBrowser) bool {
    const row = model.highlighted orelse return false;
    return isCreateRow(row);
}

fn selectTarget(state: *runtime.AppState) void {
    const model = browser(state);
    if (createRowHighlighted(model)) {
        const name = state.allocator.dupe(u8, model.creatableName() orelse return) catch return;
        defer state.allocator.free(name);
        // createFolder navigates into the new folder, which becomes the target.
        if (!model.createFolder(state.allocator, name)) return;
    }
    const target = model.targetPathAlloc(state.allocator, visible[0..visible_count]) catch return;
    defer state.allocator.free(target);
    state.finishFolderBrowser(target);
}

// ---------------------------------------------------------------------------
// Rendering
// ---------------------------------------------------------------------------

pub fn render(state: *runtime.AppState, width: f32, height: f32) void {
    if (!isOpen(state)) return;
    computeLayout(state, width, height);
    const model = browser(state);

    queueRect(state, .{ .x = 0.0, .y = 0.0, .w = width, .h = height }, theme.scrim(0.55));
    // Lighten the always-dark background rather than using panel_alt, which
    // omarchy themes can make a light grey (see command_palette.render).
    queuePanel(state, modal_rect, theme.raise(theme.background(), 0.04), theme.COLOR_PANEL_MUTED, theme.scaledUi(14.0), 1.0);

    const pad = theme.scaledUi(18.0);
    var title_buf: [160]u8 = undefined;
    const title = if (model.isRemote())
        std.fmt.bufPrint(&title_buf, "Choose a folder on {s}", .{model.remoteMachineLabel()}) catch "Choose a folder"
    else if (state.folderBrowserOffersManagedWorkspace()) "Create a workspace" else "Choose a directory";
    queueText(state, .{ .x = modal_rect.x + pad, .y = modal_rect.y + pad, .w = modal_rect.w * 0.6, .h = theme.scaledUi(22.0) }, title, theme.COLOR_WHITE, theme.scaledUi(17.0), modal_rect);
    renderChip(state, hidden_rect, if (model.show_hidden) "Hidden: shown" else "Hidden: off", model.show_hidden);

    renderIconButton(state, up_rect, NF_COD_ARROW_UP, std.fs.path.dirname(model.currentDir()) != null);
    renderCrumbs(state);
    renderField(state);
    if (places_rect.w > 0.0) renderPlaces(state);
    renderRows(state);
    renderFooter(state);
}

fn renderCrumbs(state: *runtime.AppState) void {
    const model = browser(state);
    const dir = model.currentDir();
    const font_size = theme.scaledUi(13.0);
    for (crumbs[0..crumb_count], 0..) |crumb, index| {
        const label = if (crumb_is_home[index]) "Home" else if (crumb.prefix_len <= 1) "/" else dir[crumb_starts[index]..crumb.prefix_len];
        const last = index + 1 == crumb_count;
        const hovered = rectContains(crumb.rect, state.transcript_controller.palette_mouse_x, state.transcript_controller.palette_mouse_y);
        if (hovered or last) {
            queuePanel(state, crumb.rect, theme.raise(theme.background(), if (hovered) 0.12 else 0.08), theme.raise(theme.background(), if (hovered) 0.12 else 0.08), theme.scaledUi(6.0), 1.0);
        }
        queueText(state, .{ .x = crumb.rect.x + theme.scaledUi(7.0), .y = crumb.rect.y + (crumb.rect.h - font_size * 1.25) * 0.5, .w = crumb.rect.w - theme.scaledUi(10.0), .h = font_size * 1.25 }, label, if (last) theme.COLOR_WHITE else theme.COLOR_TEXT_MUTED, font_size, crumb.rect);
        if (!last) {
            const sep_x = crumb.rect.x + crumb.rect.w + theme.scaledUi(4.0);
            queueText(state, .{ .x = sep_x, .y = crumb.rect.y + (crumb.rect.h - font_size * 1.25) * 0.5, .w = theme.scaledUi(10.0), .h = font_size * 1.25 }, "/", theme.COLOR_TEXT_SUBTLE, font_size, modal_rect);
        }
    }
}

fn renderField(state: *runtime.AppState) void {
    const model = browser(state);
    const focused = state.palette_modal_text_focus == .folder_browser;
    const value = model.query();
    queuePanel(state, input_rect, theme.background(), if (focused) theme.accent() else theme.COLOR_PANEL_MUTED, theme.scaledUi(7.0), 1.0);

    const font_size = theme.scaledUi(14.0);
    const line_height = font_size * 1.25;
    const text_x = input_rect.x + theme.scaledUi(10.0);
    const text_y = input_rect.y + (input_rect.h - line_height) * 0.5;
    const text_w = input_rect.w - theme.scaledUi(20.0);
    if (focused) {
        state.modal_text_input_rect = input_rect;
        state.modal_text_input_font_size = font_size;
        if (state.modal_text_selection_anchor) |anchor| {
            const cursor = @min(model.cursor, value.len);
            const a = @min(anchor, value.len);
            if (a != cursor) {
                const x0 = @max(text_x + runtime.paletteUiTextPrefixWidth(value, font_size, @min(a, cursor)), text_x);
                const x1 = @min(text_x + runtime.paletteUiTextPrefixWidth(value, font_size, @max(a, cursor)), text_x + text_w);
                if (x1 > x0) queueRect(state, .{ .x = x0, .y = text_y, .w = x1 - x0, .h = line_height }, theme.withAlpha(theme.selection(), 200));
            }
        }
    }
    const shown = if (value.len > 0) value else "Filter directories, or type a path like ~/code";
    queueText(state, .{ .x = text_x, .y = text_y, .w = text_w, .h = line_height }, shown, if (value.len > 0) theme.COLOR_WHITE else theme.COLOR_TEXT_SUBTLE, font_size, input_rect);
    if (focused) {
        const cursor_x = text_x + runtime.paletteUiTextPrefixWidth(value, font_size, @min(model.cursor, value.len));
        queueRect(state, .{ .x = @round(cursor_x), .y = text_y, .w = @max(@round(theme.scaledUi(1.0)), 1.0), .h = line_height }, theme.COLOR_WHITE);
    }
}

fn placeRect(index: usize) palette.Rect {
    const row_h = theme.scaledUi(PLACE_ROW_H_UI);
    var y = places_rect.y + row_h * @as(f32, @floatFromInt(index));
    // Recent folders sit under their own small heading.
    if (index < place_count and places[index].recent) y += theme.scaledUi(26.0);
    return .{ .x = places_rect.x, .y = y, .w = places_rect.w, .h = row_h };
}

fn renderPlaces(state: *runtime.AppState) void {
    const model = browser(state);
    const font_size = theme.scaledUi(13.0);
    var heading_drawn = false;
    for (0..place_count) |index| {
        const place = &places[index];
        const rect = placeRect(index);
        if (rect.y + rect.h > places_rect.y + places_rect.h) break;
        if (place.recent and !heading_drawn) {
            heading_drawn = true;
            const size = theme.scaledUi(11.0);
            queueText(state, .{ .x = rect.x + theme.scaledUi(10.0), .y = rect.y - theme.scaledUi(20.0), .w = rect.w, .h = size * 1.25 }, "RECENT", theme.COLOR_TEXT_SUBTLE, size, places_rect);
        }
        const active = std.mem.eql(u8, model.currentDir(), place.path());
        const hovered = rectContains(rect, state.transcript_controller.palette_mouse_x, state.transcript_controller.palette_mouse_y);
        if (active or hovered) {
            const fill = theme.raise(theme.background(), if (active) 0.1 else 0.07);
            queuePanel(state, rect, fill, fill, theme.scaledUi(6.0), 1.0);
        }
        const icon_size = theme.scaledUi(14.0);
        queueIcon(state, .{ .x = rect.x + theme.scaledUi(9.0), .y = rect.y + (rect.h - icon_size) * 0.5, .w = icon_size, .h = icon_size }, place.icon, if (active) theme.accent() else theme.COLOR_TEXT_MUTED, icon_size, places_rect);
        const text_x = rect.x + theme.scaledUi(31.0);
        queueText(state, .{ .x = text_x, .y = rect.y + (rect.h - font_size * 1.25) * 0.5, .w = rect.x + rect.w - text_x - theme.scaledUi(6.0), .h = font_size * 1.25 }, place.label(), if (active) theme.COLOR_WHITE else theme.COLOR_TEXT_MUTED, font_size, places_rect);
    }
    // Divider between Places and the folder list.
    const stroke = @max(@round(theme.scaledUi(1.0)), 1.0);
    queueRect(state, .{ .x = @round(places_rect.x + places_rect.w + theme.scaledUi(6.0)), .y = places_rect.y, .w = stroke, .h = places_rect.h }, theme.COLOR_PANEL_MUTED);
}

fn rowRect(state: *runtime.AppState, row: usize) palette.Rect {
    const row_h = theme.scaledUi(ROW_H_UI);
    return .{ .x = list_rect.x, .y = list_rect.y + row_h * @as(f32, @floatFromInt(row)) - browser(state).scroll_y, .w = list_rect.w - theme.scaledUi(10.0), .h = row_h };
}

fn renderRows(state: *runtime.AppState) void {
    const model = browser(state);
    if (rowCount() == 0) {
        const message = if (model.remoteLoading() and model.entries.items.len == 0)
            "Loading folders\u{2026}"
        else if (model.query().len > 0 and !model.queryIsPath()) "No directories match." else "No directories here.";
        const size = theme.scaledUi(13.0);
        queueText(state, .{ .x = list_rect.x + theme.scaledUi(10.0), .y = list_rect.y + theme.scaledUi(10.0), .w = list_rect.w, .h = size * 1.25 }, message, theme.COLOR_TEXT_MUTED, size, list_rect);
        return;
    }
    const font_size = theme.scaledUi(14.0);
    const icon_size = theme.scaledUi(15.0);
    for (0..visible_count) |row| {
        const rect = rowRect(state, row);
        if (rect.y + rect.h < list_rect.y or rect.y > list_rect.y + list_rect.h) continue;
        const entry = model.entries.items[visible[row]];
        const highlighted = model.highlighted != null and model.highlighted.? == row;
        if (highlighted or hovered_row == row) {
            const fill = if (highlighted) theme.withAlpha(theme.accent(), 46) else theme.raise(theme.background(), 0.07);
            queueRoundedClipped(state, rect, fill, theme.scaledUi(6.0), list_rect);
        }
        queueIcon(state, .{ .x = rect.x + theme.scaledUi(10.0), .y = rect.y + (rect.h - icon_size) * 0.5, .w = icon_size, .h = icon_size }, if (entry.is_git) NF_COD_FOLDER_OPENED else NF_COD_FOLDER, if (entry.is_git) theme.accent() else theme.COLOR_TEXT_MUTED, icon_size, list_rect);
        // A remote checkout whose origin matches this workspace reads "same origin".
        const badge = if (entry.same_origin) "same origin" else if (entry.is_git) "git" else "";
        const badge_size = theme.scaledUi(11.0);
        const badge_w = runtime.paletteUiTextPrefixWidth(badge, badge_size, badge.len);
        const badge_x = rect.x + rect.w - theme.scaledUi(10.0) - badge_w;
        if (badge.len > 0) queueText(state, .{ .x = badge_x, .y = rect.y + (rect.h - badge_size * 1.25) * 0.5, .w = badge_w, .h = badge_size * 1.25 }, badge, if (entry.same_origin) theme.accent() else theme.COLOR_TEXT_SUBTLE, badge_size, list_rect);
        const text_x = rect.x + theme.scaledUi(34.0);
        queueText(state, .{ .x = text_x, .y = rect.y + (rect.h - font_size * 1.25) * 0.5, .w = @max(badge_x - theme.scaledUi(10.0) - text_x, 0.0), .h = font_size * 1.25 }, entry.name, if (entry.hidden) theme.COLOR_TEXT_MUTED else theme.COLOR_WHITE, font_size, list_rect);
    }
    if (create_offered) renderCreateRow(state, font_size, icon_size);
    if (max_scroll_y > 1.0) {
        const track: palette.Rect = .{ .x = list_rect.x + list_rect.w - theme.scaledUi(4.0), .y = list_rect.y, .w = theme.scaledUi(3.0), .h = list_rect.h };
        const thumb_h = @max(theme.scaledUi(28.0), track.h * (track.h / (track.h + max_scroll_y)));
        const thumb_y = track.y + (track.h - thumb_h) * (model.scroll_y / max_scroll_y);
        queueRounded(state, .{ .x = track.x, .y = thumb_y, .w = track.w, .h = thumb_h }, theme.withAlpha(theme.COLOR_TEXT_MUTED, 160), theme.scaledUi(2.0));
    }
}

// Trailing row that creates the typed folder name in the listed directory.
fn renderCreateRow(state: *runtime.AppState, font_size: f32, icon_size: f32) void {
    const model = browser(state);
    const name = model.creatableName() orelse return;
    const row = visible_count;
    const rect = rowRect(state, row);
    if (rect.y + rect.h < list_rect.y or rect.y > list_rect.y + list_rect.h) return;
    const highlighted = model.highlighted != null and model.highlighted.? == row;
    if (highlighted or hovered_row == row) {
        const fill = if (highlighted) theme.withAlpha(theme.accent(), 46) else theme.raise(theme.background(), 0.07);
        queueRoundedClipped(state, rect, fill, theme.scaledUi(6.0), list_rect);
    }
    queueIcon(state, .{ .x = rect.x + theme.scaledUi(10.0), .y = rect.y + (rect.h - icon_size) * 0.5, .w = icon_size, .h = icon_size }, NF_COD_ADD, theme.accent(), icon_size, list_rect);
    var label_buf: [320]u8 = undefined;
    const label = std.fmt.bufPrint(&label_buf, "Create directory \u{201C}{s}\u{201D} here", .{name}) catch "Create directory here";
    const text_x = rect.x + theme.scaledUi(34.0);
    queueText(state, .{ .x = text_x, .y = rect.y + (rect.h - font_size * 1.25) * 0.5, .w = rect.x + rect.w - text_x - theme.scaledUi(10.0), .h = font_size * 1.25 }, label, theme.accent(), font_size, list_rect);
}

fn renderFooter(state: *runtime.AppState) void {
    const model = browser(state);
    const target = model.targetPathAlloc(state.allocator, visible[0..visible_count]) catch return;
    defer state.allocator.free(target);
    const size = theme.scaledUi(12.0);
    if (managed_rect.w > 0.0) renderButton(state, managed_rect, "Let Verde create one", false);
    const info_x = if (managed_rect.w > 0.0) managed_rect.x + managed_rect.w + theme.scaledUi(14.0) else modal_rect.x + theme.scaledUi(18.0);
    const info_rect: palette.Rect = .{ .x = info_x, .y = footer_y, .w = @max(cancel_rect.x - info_x - theme.scaledUi(12.0), 0.0), .h = cancel_rect.h };
    if (model.notice.len > 0) {
        queueText(state, .{ .x = info_rect.x, .y = info_rect.y + (info_rect.h - size * 1.25) * 0.5, .w = info_rect.w, .h = size * 1.25 }, model.notice, theme.COLOR_YELLOW, size, info_rect);
    } else {
        const hint = "Enter opens · Ctrl+Enter selects · Backspace goes up";
        queueText(state, .{ .x = info_rect.x, .y = info_rect.y + (info_rect.h - size * 1.25) * 0.5, .w = info_rect.w, .h = size * 1.25 }, hint, theme.COLOR_TEXT_SUBTLE, size, info_rect);
    }

    renderButton(state, cancel_rect, "Cancel", false);
    var label_buf: [160]u8 = undefined;
    // With "Create directory …" highlighted the button creates that folder
    // and picks it, so name the typed folder rather than the listed one.
    const creating = createRowHighlighted(model);
    const name = if (creating) model.creatableName() orelse "" else std.fs.path.basename(target);
    const adds = state.folderBrowserOffersManagedWorkspace();
    const verb = if (creating)
        (if (adds) "Create & add" else "Create & select")
    else if (model.isRemote()) "Use" else if (adds) "Add" else "Select";
    const label = std.fmt.bufPrint(&label_buf, "{s} \u{201C}{s}\u{201D}", .{ verb, if (name.len == 0) "/" else name }) catch verb;
    renderButton(state, select_rect, label, true);
}

fn renderButton(state: *runtime.AppState, rect: palette.Rect, label: []const u8, primary: bool) void {
    const hovered = rectContains(rect, state.transcript_controller.palette_mouse_x, state.transcript_controller.palette_mouse_y);
    const base = if (primary) theme.accent() else theme.raise(theme.background(), 0.08);
    const fill = if (hovered) theme.raise(base, 0.06) else base;
    queuePanel(state, rect, fill, if (primary) fill else theme.COLOR_PANEL_MUTED, theme.scaledUi(7.0), 1.0);
    const font_size = theme.scaledUi(13.5);
    const max_w = rect.w - theme.scaledUi(20.0);
    const label_w = @min(runtime.paletteUiTextPrefixWidth(label, font_size, label.len), max_w);
    queueText(state, .{ .x = rect.x + (rect.w - label_w) * 0.5, .y = rect.y + (rect.h - font_size * 1.25) * 0.5, .w = label_w, .h = font_size * 1.25 }, label, if (primary) theme.foregroundOn(fill) else theme.COLOR_WHITE, font_size, rect);
}

fn renderChip(state: *runtime.AppState, rect: palette.Rect, label: []const u8, active: bool) void {
    const hovered = rectContains(rect, state.transcript_controller.palette_mouse_x, state.transcript_controller.palette_mouse_y);
    const fill = theme.raise(theme.background(), if (hovered) 0.12 else 0.07);
    queuePanel(state, rect, fill, if (active) theme.accent() else theme.COLOR_PANEL_MUTED, theme.scaledUi(6.0), 1.0);
    const font_size = theme.scaledUi(12.0);
    const label_w = runtime.paletteUiTextPrefixWidth(label, font_size, label.len);
    queueText(state, .{ .x = rect.x + (rect.w - label_w) * 0.5, .y = rect.y + (rect.h - font_size * 1.25) * 0.5, .w = label_w, .h = font_size * 1.25 }, label, if (active) theme.COLOR_WHITE else theme.COLOR_TEXT_MUTED, font_size, rect);
}

fn renderIconButton(state: *runtime.AppState, rect: palette.Rect, icon: []const u8, enabled: bool) void {
    const hovered = enabled and rectContains(rect, state.transcript_controller.palette_mouse_x, state.transcript_controller.palette_mouse_y);
    const fill = theme.raise(theme.background(), if (hovered) 0.12 else 0.07);
    queuePanel(state, rect, fill, theme.COLOR_PANEL_MUTED, theme.scaledUi(6.0), 1.0);
    const size = theme.scaledUi(14.0);
    queueIcon(state, .{ .x = rect.x + (rect.w - size) * 0.5, .y = rect.y + (rect.h - size) * 0.5, .w = size, .h = size }, icon, if (enabled) theme.COLOR_WHITE else theme.COLOR_TEXT_SUBTLE, size, rect);
}

// ---------------------------------------------------------------------------
// Draw helpers
// ---------------------------------------------------------------------------

fn paletteColor(value: [4]f32) palette.Color {
    return .{ .r = value[0], .g = value[1], .b = value[2], .a = value[3] };
}

fn rectContains(rect: palette.Rect, x: f32, y: f32) bool {
    return x >= rect.x and y >= rect.y and x <= rect.x + rect.w and y <= rect.y + rect.h;
}

fn intersect(a: palette.Rect, b: palette.Rect) palette.Rect {
    const x0 = @max(a.x, b.x);
    const y0 = @max(a.y, b.y);
    const x1 = @min(a.x + a.w, b.x + b.w);
    const y1 = @min(a.y + a.h, b.y + b.h);
    return .{ .x = x0, .y = y0, .w = @max(x1 - x0, 0.0), .h = @max(y1 - y0, 0.0) };
}

fn stableText(state: *runtime.AppState, value: []const u8) ?[]const u8 {
    return state.palette_frame_text_arena.allocator().dupe(u8, value) catch |err| {
        log.warn("failed to retain folder browser text: {s}", .{@errorName(err)});
        return null;
    };
}

fn queueRect(state: *runtime.AppState, rect: palette.Rect, color: [4]f32) void {
    state.palette_overlay_batch.rect(state.allocator, rect, paletteColor(color)) catch {};
}

fn queueRounded(state: *runtime.AppState, rect: palette.Rect, color: [4]f32, radius: f32) void {
    state.palette_overlay_batch.roundedRect(state.allocator, rect, paletteColor(color), radius) catch {};
}

fn queueRoundedClipped(state: *runtime.AppState, rect: palette.Rect, color: [4]f32, radius: f32, clip: palette.Rect) void {
    state.palette_overlay_batch.roundedRectClipped(state.allocator, rect, paletteColor(color), radius, clip) catch {};
}

/// One bordered surface per Palette's crisp-chrome rules: a single `panel`
/// command on pixel-snapped edges with a whole-pixel stroke.
fn queuePanel(state: *runtime.AppState, rect: palette.Rect, fill: [4]f32, border: [4]f32, radius: f32, width_ui: f32) void {
    const left = @round(rect.x);
    const top = @round(rect.y);
    const snapped: palette.Rect = .{ .x = left, .y = top, .w = @round(rect.x + rect.w) - left, .h = @round(rect.y + rect.h) - top };
    const stroke = @max(@round(theme.scaledUi(width_ui)), 1.0);
    state.palette_overlay_batch.panel(state.allocator, snapped, paletteColor(fill), paletteColor(border), radius, stroke) catch {};
}

fn queueText(state: *runtime.AppState, rect: palette.Rect, value: []const u8, color: [4]f32, font_size: f32, clip: palette.Rect) void {
    const stable_value = stableText(state, value) orelse return;
    const effective_clip = intersect(.{ .x = rect.x, .y = clip.y, .w = rect.w, .h = clip.h }, clip);
    if (effective_clip.w <= 0.0 or effective_clip.h <= 0.0) return;
    state.palette_overlay_batch.roleText(state.allocator, rect, stable_value, paletteColor(color), font_size, .ui, null, effective_clip) catch {};
}

fn queueIcon(state: *runtime.AppState, rect: palette.Rect, glyph: []const u8, color: [4]f32, font_size: f32, clip: palette.Rect) void {
    const stable = stableText(state, glyph) orelse return;
    state.palette_overlay_batch.roleText(state.allocator, rect, stable, paletteColor(color), font_size, .icon, null, clip) catch {};
}
