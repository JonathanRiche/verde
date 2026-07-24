//! Browser dock rendering for the native shell.

const std = @import("std");
const palette = @import("palette");
const sdl = @import("zsdl3");

const app_state = @import("../state.zig");
const browser_runtime = @import("../browser/mod.zig");
const colors = @import("colors.zig");
const theme = @import("theme.zig");

// Nerd Font Symbols codicon glyphs. Codepoints match the Microsoft Codicons
// table (https://microsoft.github.io/vscode-codicons/dist/codicon.html) and
// are present in SymbolsNerdFontMono-Regular.ttf.
const NF_COD_ARROW_LEFT = "\u{EA9B}";
const NF_COD_ARROW_RIGHT = "\u{EA9C}";
const NF_COD_REFRESH = "\u{EB37}";
const NF_COD_INSPECT = "\u{EBD1}";
const NF_COD_CHEVRON_DOWN = "\u{EAB4}";
const NF_COD_CLOSE = "\u{EA76}";
const NF_COD_ADD = "\u{EA60}";
const NF_COD_COPY = "\u{EBCC}";
const NF_COD_ELLIPSIS = "\u{EA7C}";
const NF_COD_LOADING = "\u{EB19}";
const NF_COD_ERROR = "\u{EA87}";
const NF_COD_PINNED = "\u{EB2B}";
const NF_COD_LOCK = "\u{EA75}";
const NF_COD_WARNING = "\u{EA6C}";
const NF_COD_LINK_EXTERNAL = "\u{EB14}";
const NF_COD_GLOBE = "\u{EB01}";

const TAB_ROW_HEIGHT: f32 = 36.0;
const NAV_ROW_HEIGHT: f32 = 44.0;
const TOOLBAR_HEIGHT: f32 = TAB_ROW_HEIGHT + NAV_ROW_HEIGHT;
const TOOLBAR_BUTTON_SIZE: f32 = 30.0;
const TOOLBAR_BUTTON_RADIUS: f32 = 8.0;
const TOOLBAR_ICON_SIZE: f32 = 15.0;
const TOOLBAR_CHEVRON_SIZE: f32 = 11.0;
const TOOLBAR_GAP: f32 = 6.0;
const TOOLBAR_DROPDOWN_WIDTH: f32 = 20.0;
const TOOLBAR_FIELD_MIN_WIDTH: f32 = 120.0;

const BrowserContextMenuAction = union(enum) {
    backend_item: app_state.BrowserContextMenuItem,
    open_link_current,
    open_link_new_tab,
    close_pane,
};

const BrowserContextMenuHit = struct {
    rect: palette.Rect,
    action: BrowserContextMenuAction,
};

const BrowserHitKind = enum {
    address,
    back,
    forward,
    navigate,
    inspect_toggle,
    inspect_mode_menu,
    inspect_mode_point,
    inspect_mode_draw_box,
    inspect_mode_draw_freeform,
    setup_dev_server,
    new_tab,
    close_tab,
    copy_url,
    open_external,
    overflow,
    security_info,
    close,
};

const BrowserHit = struct {
    rect: palette.Rect,
    kind: BrowserHitKind,
};

var palette_hits: [24]BrowserHit = undefined;
var palette_hit_count: usize = 0;
var palette_toolbar_rect: palette.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 };
var palette_menu_rect: palette.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 };
var palette_context_menu_rect: palette.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 };
var palette_context_menu_panels: [8]palette.Rect = undefined;
var palette_context_menu_panel_count: usize = 0;
var palette_context_menu_hits: [128]BrowserContextMenuHit = undefined;
var palette_context_menu_hit_count: usize = 0;
var palette_mouse_pos: [2]f32 = .{ -1.0, -1.0 };
const BrowserTabHitKind = enum { select, close };
const BrowserTabHit = struct {
    rect: palette.Rect,
    index: usize,
    kind: BrowserTabHitKind,
};
var palette_tab_hits: [64]BrowserTabHit = undefined;
var palette_tab_hit_count: usize = 0;
var tab_drag_source: ?usize = null;
var tab_drag_target: ?usize = null;
var tab_drag_start_x: f32 = 0.0;
var tab_drag_active = false;
var toolbar_overflow_open = false;
var palette_overflow_menu_rect: palette.Rect = .{};

const BrowserOverflowAction = union(enum) {
    select_tab: usize,
    duplicate_tab,
    toggle_pin,
    maximize_pane,
    toggle_detach,
    reload,
    copy_url,
    open_external,
    toggle_inspector,
    close_pane,
};

const BrowserOverflowHit = struct {
    rect: palette.Rect,
    action: BrowserOverflowAction,
    enabled: bool,
};

var palette_overflow_hits: [32]BrowserOverflowHit = undefined;
var palette_overflow_hit_count: usize = 0;

const CLOSE_PANE_MENU_INDEX = std.math.maxInt(u32);

/// Renders the browser dock that manages the in-app browser pane and bridge controls.
pub fn renderDockAt(state: *app_state.AppState, rect: palette.Rect) void {
    renderDockAtWithReserve(state, rect, 0.0);
}

/// Renders the browser dock while leaving toolbar space for workspace chrome.
pub fn renderDockAtWithReserve(state: *app_state.AppState, rect: palette.Rect, toolbar_right_reserve: f32) void {
    if (!state.isBrowserVisible()) return;
    palette_hit_count = 0;
    palette_tab_hit_count = 0;
    palette_toolbar_rect = .{ .x = 0.0, .y = 0.0, .w = 0.0, .h = 0.0 };
    palette_menu_rect = .{ .x = 0.0, .y = 0.0, .w = 0.0, .h = 0.0 };
    palette_context_menu_rect = .{ .x = 0.0, .y = 0.0, .w = 0.0, .h = 0.0 };
    palette_context_menu_panel_count = 0;
    palette_context_menu_hit_count = 0;
    palette_overflow_menu_rect = .{};
    palette_overflow_hit_count = 0;

    const toolbar_height = theme.scaledUi(TOOLBAR_HEIGHT);
    renderPaneCanvas(state, .{
        .x = rect.x,
        .y = rect.y + toolbar_height,
        .w = rect.w,
        .h = @max(rect.h - toolbar_height, theme.scaledUi(180.0)),
    });
    renderToolbar(state, rect, toolbar_right_reserve);
    renderBrowserContextMenu(state);
    renderToolbarTooltip(state);
}

/// Returns the height reserved for the browser pane's toolbar chrome.
pub fn paneToolbarHeight() f32 {
    return theme.scaledUi(TOOLBAR_HEIGHT);
}

/// Returns the top toolbar row used by pane-level actions.
pub fn paneToolbarActionRowHeight() f32 {
    return theme.scaledUi(TAB_ROW_HEIGHT);
}

pub fn handlePaletteMouseMotion(state: *app_state.AppState, x: f32, y: f32) void {
    palette_mouse_pos = .{ x, y };
    if (state.browser_context_menu_open) {
        if (browserContextMenuActionAtPoint(x, y)) |action| {
            switch (action) {
                .backend_item => |item| if (item.enabled and !item.separator) {
                    state.browser_context_menu_selected_index = item.index;
                    state.browser_context_menu_active_parent = if (item.submenu) item.index else item.parent_index;
                },
                .close_pane => {
                    state.browser_context_menu_selected_index = CLOSE_PANE_MENU_INDEX;
                    state.browser_context_menu_active_parent = null;
                },
                .open_link_current, .open_link_new_tab => {
                    state.browser_context_menu_selected_index = null;
                    state.browser_context_menu_active_parent = null;
                },
            }
        }
    }
    // Drag-to-extend the URL-bar selection. We re-find the address hit rect
    // each frame (the toolbar may have re-laid out) so the cursor stays
    // accurate even if the field moves under the pointer.
    if (state.browser_address_drag_active and state.browser_address_focused) {
        if (findHit(.address)) |hit| {
            state.browser_address_cursor = cursorForAddressPoint(state, hit.rect, x);
        }
    }
    if (tab_drag_source != null) {
        if (@abs(x - tab_drag_start_x) >= theme.scaledUi(5.0)) tab_drag_active = true;
        if (tab_drag_active) {
            for (palette_tab_hits[0..palette_tab_hit_count]) |hit| {
                if (hit.kind == .select and rectContainsPoint(hit.rect, x, y)) {
                    tab_drag_target = hit.index;
                    break;
                }
            }
        }
    }
}

/// Returns whether the pointer is over an enabled browser chrome action.
pub fn wantsPointerAt(state: *app_state.AppState, x: f32, y: f32) bool {
    if (!state.isBrowserVisible()) return false;

    if (toolbar_overflow_open and rectContainsPoint(palette_overflow_menu_rect, x, y)) return true;

    var index = palette_hit_count;
    while (index > 0) {
        index -= 1;
        const hit = palette_hits[index];
        if (!rectContainsPoint(hit.rect, x, y)) continue;
        return switch (hit.kind) {
            .address => false,
            .back => state.browserCanGoBack(),
            .forward => state.browserCanGoForward(),
            .inspect_toggle, .inspect_mode_menu => state.canUseBrowserInspector(),
            .copy_url => state.browserState().current_url != null,
            .open_external => state.browserState().current_url != null,
            else => true,
        };
    }

    index = palette_tab_hit_count;
    while (index > 0) {
        index -= 1;
        if (rectContainsPoint(palette_tab_hits[index].rect, x, y)) return true;
    }

    if (state.browser_context_menu_open) {
        if (browserContextMenuActionAtPoint(x, y)) |action| {
            return switch (action) {
                .backend_item => |item| item.enabled and !item.separator,
                .open_link_current, .open_link_new_tab => true,
                .close_pane => true,
            };
        }
    }
    return false;
}

fn findHit(kind: BrowserHitKind) ?BrowserHit {
    var index = palette_hit_count;
    while (index > 0) {
        index -= 1;
        if (palette_hits[index].kind == kind) return palette_hits[index];
    }
    return null;
}

pub fn triggerPaletteToolbarHit(state: *app_state.AppState, name: []const u8) bool {
    const kind = toolbarHitKindByName(name) orelse return false;
    const hit = findHit(kind) orelse return false;
    return handlePaletteMouseButton(
        state,
        hit.rect.x + hit.rect.w * 0.5,
        hit.rect.y + hit.rect.h * 0.5,
        true,
        1,
    );
}

fn toolbarHitKindByName(name: []const u8) ?BrowserHitKind {
    if (std.mem.eql(u8, name, "address")) return .address;
    if (std.mem.eql(u8, name, "back")) return .back;
    if (std.mem.eql(u8, name, "forward")) return .forward;
    if (std.mem.eql(u8, name, "navigate") or std.mem.eql(u8, name, "reload")) return .navigate;
    if (std.mem.eql(u8, name, "inspect-toggle")) return .inspect_toggle;
    if (std.mem.eql(u8, name, "inspect-menu")) return .inspect_mode_menu;
    if (std.mem.eql(u8, name, "inspect-point")) return .inspect_mode_point;
    if (std.mem.eql(u8, name, "inspect-draw-box")) return .inspect_mode_draw_box;
    if (std.mem.eql(u8, name, "inspect-draw-freeform")) return .inspect_mode_draw_freeform;
    if (std.mem.eql(u8, name, "close")) return .close;
    if (std.mem.eql(u8, name, "new-tab")) return .new_tab;
    if (std.mem.eql(u8, name, "close-tab")) return .close_tab;
    if (std.mem.eql(u8, name, "overflow")) return .overflow;
    if (std.mem.eql(u8, name, "open-external")) return .open_external;
    return null;
}

pub fn handlePaletteMouseButton(state: *app_state.AppState, x: f32, y: f32, down: bool, clicks: u8) bool {
    if (!state.isBrowserVisible()) return false;
    palette_mouse_pos = .{ x, y };

    if (toolbar_overflow_open) {
        if (!down) return rectContainsPoint(palette_overflow_menu_rect, x, y) or rectContainsPoint(palette_toolbar_rect, x, y);
        if (overflowActionAtPoint(x, y)) |hit| {
            if (hit.enabled) activateOverflowAction(state, hit.action);
            toolbar_overflow_open = false;
            state.noteInteraction();
            return true;
        }
        if (rectContainsPoint(palette_overflow_menu_rect, x, y)) return true;
        toolbar_overflow_open = false;
    }

    if (state.browser_context_menu_open) {
        if (!down) {
            return browserContextMenuContainsPoint(x, y);
        }
        if (browserContextMenuContainsPoint(x, y)) {
            if (browserContextMenuActionAtPoint(x, y)) |action| {
                switch (action) {
                    .backend_item => |item| {
                        if (item.enabled and !item.separator and item.submenu) {
                            state.browser_context_menu_selected_index = item.index;
                            state.browser_context_menu_active_parent = item.index;
                        } else if (item.enabled and !item.separator) {
                            state.activateBrowserContextMenuItem(item.index);
                        }
                    },
                    .close_pane => {
                        state.dismissBrowserContextMenu();
                        if (state.currentProjectVisibleBrowserPaneId()) |pane_id| {
                            _ = state.closeCurrentProjectWorkspacePane(pane_id);
                        }
                    },
                    .open_link_current => state.openBrowserContextLink(false),
                    .open_link_new_tab => state.openBrowserContextLink(true),
                }
            }
            state.noteInteraction();
            return true;
        }
        state.dismissBrowserContextMenu();
        if (!state.browserPaneContains(x, y)) return true;
    }

    if (down and (rectContainsPoint(palette_toolbar_rect, x, y) or
        (state.browser_inspector_menu_open and rectContainsPoint(palette_menu_rect, x, y))))
    {
        if (state.currentProjectVisibleBrowserPaneId()) |pane_id| {
            _ = state.focusCurrentProjectWorkspacePane(pane_id);
        }
    }

    if (!down) {
        const dragged = tab_drag_source != null;
        if (tab_drag_active) {
            if (tab_drag_source) |from| {
                if (tab_drag_target) |to| state.moveBrowserTab(from, to);
            }
        }
        tab_drag_source = null;
        tab_drag_target = null;
        tab_drag_active = false;
        state.browser_address_drag_active = false;
        return dragged or rectContainsPoint(palette_toolbar_rect, x, y) or
            (state.browser_inspector_menu_open and rectContainsPoint(palette_menu_rect, x, y));
    }

    var index = palette_hit_count;
    while (index > 0) {
        index -= 1;
        const hit = palette_hits[index];
        if (!rectContainsPoint(hit.rect, x, y)) continue;

        switch (hit.kind) {
            .address => {
                focusAddress(state);
                const address = state.browserState().addressInput();
                const offset = cursorForAddressPoint(state, hit.rect, x);
                if (clicks >= 3) {
                    // Triple-click: select the whole URL — single-line field,
                    // no need for a line scan.
                    state.browser_address_cursor = address.len;
                    state.browser_address_selection_anchor = 0;
                    state.browser_address_drag_active = false;
                } else if (clicks == 2) {
                    const bounds = wordBoundsAt(address, offset);
                    state.browser_address_selection_anchor = bounds.start;
                    state.browser_address_cursor = bounds.end;
                    state.browser_address_drag_active = false;
                } else {
                    state.browser_address_cursor = offset;
                    state.browser_address_selection_anchor = offset;
                    state.browser_address_drag_active = true;
                }
            },
            .back => {
                blurAddress(state);
                state.browser_inspector_menu_open = false;
                state.navigateBrowserHistory(-1);
            },
            .forward => {
                blurAddress(state);
                state.browser_inspector_menu_open = false;
                state.navigateBrowserHistory(1);
            },
            .navigate => {
                blurAddress(state);
                state.browser_inspector_menu_open = false;
                state.navigateOrReloadBrowserFromAddress();
            },
            .inspect_toggle => {
                blurAddress(state);
                state.browser_inspector_menu_open = false;
                if (state.canUseBrowserInspector()) state.toggleBrowserInspector();
            },
            .inspect_mode_menu => {
                blurAddress(state);
                if (state.canUseBrowserInspector()) {
                    state.browser_inspector_menu_open = !state.browser_inspector_menu_open;
                }
            },
            .inspect_mode_point => selectInspectorMode(state, .point),
            .inspect_mode_draw_box => selectInspectorMode(state, .draw_box),
            .inspect_mode_draw_freeform => selectInspectorMode(state, .draw_freeform),
            .setup_dev_server => {
                blurAddress(state);
                state.setupBrowserDevServer();
            },
            .new_tab => {
                blurAddress(state);
                state.createBrowserTab();
            },
            .close_tab => {
                blurAddress(state);
                state.closeBrowserTab(state.activeBrowserTabIndex());
            },
            .copy_url => copyCurrentUrl(state),
            .open_external => state.openCurrentBrowserUrlExternally(),
            .overflow => {
                toolbar_overflow_open = !toolbar_overflow_open;
                state.browser_inspector_menu_open = false;
            },
            .security_info => state.setSidebarNotice(browserSecurityNotice(state.browserState().current_url)),
            .close => {
                blurAddress(state);
                state.browser_inspector_menu_open = false;
                if (state.currentProjectVisibleBrowserPaneId()) |pane_id| {
                    _ = state.closeCurrentProjectWorkspacePane(pane_id);
                } else {
                    state.closeBrowser();
                }
            },
        }
        state.noteInteraction();
        return true;
    }

    var tab_index = palette_tab_hit_count;
    while (tab_index > 0) {
        tab_index -= 1;
        const hit = palette_tab_hits[tab_index];
        if (!rectContainsPoint(hit.rect, x, y)) continue;
        blurAddress(state);
        switch (hit.kind) {
            .select => {
                tab_drag_source = hit.index;
                tab_drag_target = hit.index;
                tab_drag_start_x = x;
                tab_drag_active = false;
                state.switchBrowserTab(hit.index);
            },
            .close => state.closeBrowserTab(hit.index),
        }
        state.noteInteraction();
        return true;
    }

    if (rectContainsPoint(palette_toolbar_rect, x, y) or
        (state.browser_inspector_menu_open and rectContainsPoint(palette_menu_rect, x, y)))
    {
        blurAddress(state);
        if (!rectContainsPoint(palette_menu_rect, x, y)) {
            state.browser_inspector_menu_open = false;
        }
        return true;
    }

    blurAddress(state);
    state.browser_inspector_menu_open = false;
    return false;
}

pub fn handlePaletteTextInput(state: *app_state.AppState, text: []const u8) bool {
    if (!state.browser_address_focused) return false;
    _ = deleteAddressSelection(state);
    insertAddressText(state, text);
    state.noteInteraction();
    return true;
}

pub fn handlePaletteKeyDown(state: *app_state.AppState, event: *const sdl.KeyboardEvent) bool {
    if (state.browser_context_menu_open) return handleBrowserContextMenuKeyDown(state, event);
    if (!state.browser_address_focused) return false;
    if (!event.down) return true;

    const primary = isPrimaryModifierPressed(event.mod);
    const shift = isShiftPressed(event.mod);
    const address_len = state.browserState().addressInput().len;
    switch (event.key) {
        .@"return", .kp_enter => {
            blurAddress(state);
            state.navigateBrowserFromAddress();
        },
        .escape => blurAddress(state),
        .left => {
            const target = state.browser_address_cursor -| 1;
            moveAddressCursor(state, target, shift);
        },
        .right => {
            const target = @min(state.browser_address_cursor + 1, address_len);
            moveAddressCursor(state, target, shift);
        },
        .home => moveAddressCursor(state, 0, shift),
        .end => moveAddressCursor(state, address_len, shift),
        .backspace, .kp_backspace => {
            if (!deleteAddressSelection(state)) deleteAddressBackward(state);
        },
        .delete => {
            if (!deleteAddressSelection(state)) deleteAddressForward(state);
        },
        .a => {
            if (primary) {
                state.browser_address_selection_anchor = 0;
                state.browser_address_cursor = address_len;
            }
        },
        .c => {
            if (primary) copyAddressSelection(state);
        },
        .x => {
            if (primary) {
                copyAddressSelection(state);
                _ = deleteAddressSelection(state);
            }
        },
        .v => {
            if (primary) pasteIntoAddress(state);
        },
        else => return true,
    }
    state.noteInteraction();
    return true;
}

fn handleBrowserContextMenuKeyDown(state: *app_state.AppState, event: *const sdl.KeyboardEvent) bool {
    if (!event.down) return true;
    switch (event.key) {
        .escape => state.dismissBrowserContextMenu(),
        .up => moveBrowserContextMenuSelection(state, -1),
        .down => moveBrowserContextMenuSelection(state, 1),
        .home => selectBrowserContextMenuBoundary(state, false),
        .end => selectBrowserContextMenuBoundary(state, true),
        .left => closeBrowserContextSubmenu(state),
        .right => openSelectedBrowserContextSubmenu(state),
        .@"return", .kp_enter, .space => activateSelectedBrowserContextMenuItem(state),
        else => return true,
    }
    state.noteInteraction();
    return true;
}

fn contextMenuItemByIndex(state: *const app_state.AppState, item_index: u32) ?*const app_state.BrowserContextMenuItem {
    for (state.browser_context_menu_items.items) |*item| {
        if (item.index == item_index) return item;
    }
    return null;
}

fn selectableBrowserContextMenuIndexes(state: *const app_state.AppState, parent_index: ?u32, indexes: *[128]u32) usize {
    return selectableBrowserContextMenuIndexesFromItems(
        state.browser_context_menu_items.items,
        parent_index,
        state.currentProjectVisibleBrowserPaneId() != null,
        indexes,
    );
}

fn selectableBrowserContextMenuIndexesFromItems(
    items: []const app_state.BrowserContextMenuItem,
    parent_index: ?u32,
    include_close_pane: bool,
    indexes: *[128]u32,
) usize {
    var count: usize = 0;
    for (items) |item| {
        if (item.parent_index != parent_index or !item.enabled or item.separator) continue;
        if (count >= indexes.len) break;
        indexes[count] = item.index;
        count += 1;
    }
    if (parent_index == null and include_close_pane and count < indexes.len) {
        indexes[count] = CLOSE_PANE_MENU_INDEX;
        count += 1;
    }
    return count;
}

fn nextBrowserContextMenuSelection(indexes: []const u32, current: ?u32, direction: i32) u32 {
    std.debug.assert(indexes.len > 0);
    var selected: usize = if (direction < 0) indexes.len - 1 else 0;
    if (current) |selected_index| {
        for (indexes, 0..) |item_index, index| {
            if (item_index != selected_index) continue;
            selected = if (direction < 0)
                (index + indexes.len - 1) % indexes.len
            else
                (index + 1) % indexes.len;
            break;
        }
    }
    return indexes[selected];
}

fn moveBrowserContextMenuSelection(state: *app_state.AppState, direction: i32) void {
    var indexes: [128]u32 = undefined;
    const count = selectableBrowserContextMenuIndexes(state, state.browser_context_menu_active_parent, &indexes);
    if (count == 0) return;
    state.browser_context_menu_selected_index = nextBrowserContextMenuSelection(
        indexes[0..count],
        state.browser_context_menu_selected_index,
        direction,
    );
}

fn selectBrowserContextMenuBoundary(state: *app_state.AppState, last: bool) void {
    var indexes: [128]u32 = undefined;
    const count = selectableBrowserContextMenuIndexes(state, state.browser_context_menu_active_parent, &indexes);
    if (count == 0) return;
    state.browser_context_menu_selected_index = indexes[if (last) count - 1 else 0];
}

fn openSelectedBrowserContextSubmenu(state: *app_state.AppState) void {
    const selected = state.browser_context_menu_selected_index orelse return;
    if (selected == CLOSE_PANE_MENU_INDEX) return;
    const item = contextMenuItemByIndex(state, selected) orelse return;
    if (!item.enabled or !item.submenu) return;
    state.browser_context_menu_active_parent = item.index;
    selectBrowserContextMenuBoundary(state, false);
}

fn closeBrowserContextSubmenu(state: *app_state.AppState) void {
    const parent_index = state.browser_context_menu_active_parent orelse return;
    const parent_item = contextMenuItemByIndex(state, parent_index) orelse return;
    state.browser_context_menu_active_parent = parent_item.parent_index;
    state.browser_context_menu_selected_index = parent_item.index;
}

fn activateSelectedBrowserContextMenuItem(state: *app_state.AppState) void {
    const selected = state.browser_context_menu_selected_index orelse return;
    if (selected == CLOSE_PANE_MENU_INDEX) {
        state.dismissBrowserContextMenu();
        if (state.currentProjectVisibleBrowserPaneId()) |pane_id| {
            _ = state.closeCurrentProjectWorkspacePane(pane_id);
        }
        return;
    }
    const item = contextMenuItemByIndex(state, selected) orelse return;
    if (!item.enabled or item.separator) return;
    if (item.submenu) {
        openSelectedBrowserContextSubmenu(state);
        return;
    }
    state.activateBrowserContextMenuItem(item.index);
}

fn moveAddressCursor(state: *app_state.AppState, target: usize, shift: bool) void {
    if (shift) {
        if (state.browser_address_selection_anchor == null) {
            state.browser_address_selection_anchor = state.browser_address_cursor;
        }
    } else {
        clearAddressSelection(state);
    }
    state.browser_address_cursor = target;
}

fn copyAddressSelection(state: *app_state.AppState) void {
    const address = state.browserState().addressInput();
    const sel = addressSelectionRange(state, address) orelse return;
    const slice = address[sel.start..sel.end];
    if (slice.len == 0) return;
    const z = state.allocator.dupeZ(u8, slice) catch return;
    defer state.allocator.free(z);
    sdl.setClipboardText(z) catch |err| {
        app_state.log.warn("failed to copy URL bar selection: {s}", .{@errorName(err)});
    };
}

fn copyCurrentUrl(state: *app_state.AppState) void {
    const url = state.browserState().current_url orelse return;
    const value = state.allocator.dupeZ(u8, url) catch return;
    defer state.allocator.free(value);
    sdl.setClipboardText(value) catch |err| {
        app_state.log.warn("failed to copy current browser URL: {s}", .{@errorName(err)});
    };
}

fn pasteIntoAddress(state: *app_state.AppState) void {
    const text = state.readClipboardTextForPaste() orelse return;
    defer state.allocator.free(text);
    if (text.len == 0) return;
    _ = deleteAddressSelection(state);
    // Strip control chars (newlines from multi-line clipboard contents); the
    // URL field is single-line.
    var sanitized: [4096]u8 = undefined;
    var n: usize = 0;
    for (text) |b| {
        if (b == '\n' or b == '\r' or b == '\t') continue;
        if (n >= sanitized.len) break;
        sanitized[n] = b;
        n += 1;
    }
    insertAddressText(state, sanitized[0..n]);
}

fn isShiftPressed(modifier_state: sdl.Keymod) bool {
    const bits = @as(*const u16, @ptrCast(&modifier_state)).*;
    return (bits & sdl.Keymod.shift) != 0;
}

fn paletteColor(value: [4]f32) palette.Color {
    return .{ .r = value[0], .g = value[1], .b = value[2], .a = value[3] };
}

fn queuePaletteRoundedRect(state: *app_state.AppState, rect: palette.Rect, color: palette.Color, radius: f32) void {
    state.palette_overlay_batch.roundedRect(state.allocator, rect, color, radius) catch |err| {
        app_state.log.warn("failed to queue browser palette rounded rect: {s}", .{@errorName(err)});
    };
}

fn queuePaletteRect(state: *app_state.AppState, rect: palette.Rect, color: palette.Color) void {
    state.palette_overlay_batch.rect(state.allocator, rect, color) catch |err| {
        app_state.log.warn("failed to queue browser palette rect: {s}", .{@errorName(err)});
    };
}

fn queuePaletteBorder(state: *app_state.AppState, rect: palette.Rect, color: palette.Color, radius: f32, width: f32) void {
    state.palette_overlay_batch.rectBorder(state.allocator, rect, color, radius, width) catch |err| {
        app_state.log.warn("failed to queue browser palette border: {s}", .{@errorName(err)});
    };
}

fn queuePaletteText(state: *app_state.AppState, rect: palette.Rect, value: []const u8, color: palette.Color, font_size: f32, clip: ?palette.Rect) void {
    const stable_value = stablePaletteText(state, value) catch |err| {
        app_state.log.warn("failed to retain browser palette text: {s}", .{@errorName(err)});
        return;
    };
    // Variable-width rendering on the `.ui` font role. Caret math goes
    // through `paletteUiTextPrefixWidth` which measures with the same role,
    // so glyph positions and the caret align to the same pixel. Plain
    // `batch.text()` would fall back to the renderer's default font and
    // re-introduce the drift.
    state.palette_overlay_batch.roleText(
        state.allocator,
        rect,
        stable_value,
        color,
        font_size,
        .ui,
        null,
        clip,
    ) catch |err| {
        app_state.log.warn("failed to queue browser palette text: {s}", .{@errorName(err)});
    };
}

fn stablePaletteText(state: *app_state.AppState, value: []const u8) ![]const u8 {
    return try state.palette_frame_text_arena.allocator().dupe(u8, value);
}

fn queuePaletteIcon(
    state: *app_state.AppState,
    rect: palette.Rect,
    glyph: []const u8,
    font_size: f32,
    color: palette.Color,
) void {
    const stable_value = stablePaletteText(state, glyph) catch |err| {
        app_state.log.warn("failed to retain browser palette icon: {s}", .{@errorName(err)});
        return;
    };
    state.palette_overlay_batch.roleText(
        state.allocator,
        snapRect(rect),
        stable_value,
        color,
        font_size,
        .icon,
        null,
        null,
    ) catch |err| {
        app_state.log.warn("failed to queue browser palette icon: {s}", .{@errorName(err)});
    };
}

fn snapRect(rect: palette.Rect) palette.Rect {
    return .{ .x = @round(rect.x), .y = @round(rect.y), .w = @round(rect.w), .h = @round(rect.h) };
}

/// Centers a square `font_size`×`font_size` icon rect inside `button_rect`.
fn iconRectForButton(button_rect: palette.Rect, font_size: f32) palette.Rect {
    return .{
        .x = button_rect.x + (button_rect.w - font_size) * 0.5,
        .y = button_rect.y + (button_rect.h - font_size) * 0.5,
        .w = font_size,
        .h = font_size,
    };
}

/// Renders a single icon toolbar button with consistent state styling. The
/// caller controls the base color (so the accent refresh button can stay green
/// while the neutral nav buttons share a single palette).
fn renderToolbarIconButton(
    state: *app_state.AppState,
    rect: palette.Rect,
    glyph: []const u8,
    base_color: [4]f32,
    icon_color: [4]f32,
    hovered: bool,
    disabled: bool,
) void {
    const bg = if (disabled)
        theme.darken(base_color, 0.04)
    else if (hovered)
        theme.lighten(base_color, 0.10)
    else
        base_color;
    queuePaletteRoundedRect(state, rect, paletteColor(bg), theme.scaledUi(TOOLBAR_BUTTON_RADIUS));
    const icon_size = theme.scaledUi(TOOLBAR_ICON_SIZE);
    queuePaletteIcon(state, iconRectForButton(rect, icon_size), glyph, icon_size, paletteColor(icon_color));
}

// Compact toolbar control: quiet at rest, with a precise hover surface.
fn renderCompactIconButton(
    state: *app_state.AppState,
    rect: palette.Rect,
    glyph: []const u8,
    hovered: bool,
    disabled: bool,
) void {
    if (hovered and !disabled) {
        queuePaletteRoundedRect(state, rect, paletteColor(theme.COLOR_PANEL_ALT), theme.scaledUi(5.0));
    }
    const color = if (disabled) theme.COLOR_TEXT_SUBTLE else if (hovered) theme.COLOR_WHITE else theme.COLOR_TEXT_MUTED;
    const icon_size = theme.scaledUi(13.0);
    queuePaletteIcon(state, iconRectForButton(rect, icon_size), glyph, icon_size, paletteColor(color));
}

fn renderTabIndicator(state: *app_state.AppState, tab_index: usize, tab_rect: palette.Rect) f32 {
    const indicator = state.browserTabIndicator(tab_index);
    const pinned = state.browserTabPinned(tab_index);
    if (indicator == .none and !pinned) return 0.0;

    const rect: palette.Rect = .{
        .x = tab_rect.x + theme.scaledUi(6.0),
        .y = tab_rect.y + (tab_rect.h - theme.scaledUi(14.0)) * 0.5,
        .w = theme.scaledUi(14.0),
        .h = theme.scaledUi(14.0),
    };
    const glyph = switch (indicator) {
        .loading => NF_COD_LOADING,
        .failed => NF_COD_ERROR,
        .none => NF_COD_PINNED,
    };
    const color = if (indicator == .failed) theme.danger() else if (indicator == .loading) theme.accent() else theme.COLOR_TEXT_MUTED;
    queuePaletteIcon(state, rect, glyph, rect.w, paletteColor(color));
    return rect.w + theme.scaledUi(4.0);
}

// Inspector segments retain an accent treatment while the tool is armed.
fn renderInspectorIconButton(
    state: *app_state.AppState,
    rect: palette.Rect,
    glyph: []const u8,
    hovered: bool,
    disabled: bool,
    active: bool,
) void {
    if (active and !disabled) {
        queuePaletteRoundedRect(state, rect, paletteColor(theme.withAlpha(theme.accent(), 92)), theme.scaledUi(5.0));
        queuePaletteBorder(state, rect, paletteColor(theme.withAlpha(theme.accent(), 180)), theme.scaledUi(5.0), theme.scaledUi(1.0));
    } else if (hovered and !disabled) {
        queuePaletteRoundedRect(state, rect, paletteColor(theme.COLOR_PANEL_ALT), theme.scaledUi(5.0));
    }
    const color = if (disabled) theme.COLOR_TEXT_SUBTLE else if (active or hovered) theme.COLOR_WHITE else theme.COLOR_TEXT_MUTED;
    const icon_size = theme.scaledUi(13.0);
    queuePaletteIcon(state, iconRectForButton(rect, icon_size), glyph, icon_size, paletteColor(color));
}

/// Renders the inspector toggle and its mode dropdown as a single split-button
/// unit: one shared rounded background, a hairline divider, and per-segment
/// hover pills. This avoids the visual mismatch of two abutting rounded rects.
fn renderInspectorSplitButton(
    state: *app_state.AppState,
    inspect_rect: palette.Rect,
    dropdown_rect: palette.Rect,
    base_color: [4]f32,
    icon_color: [4]f32,
    inspect_hovered: bool,
    dropdown_hovered: bool,
    disabled: bool,
) void {
    const combined: palette.Rect = .{
        .x = inspect_rect.x,
        .y = inspect_rect.y,
        .w = inspect_rect.w + dropdown_rect.w,
        .h = inspect_rect.h,
    };
    const bg = if (disabled) theme.darken(base_color, 0.04) else base_color;
    queuePaletteRoundedRect(state, combined, paletteColor(bg), theme.scaledUi(TOOLBAR_BUTTON_RADIUS));

    if (!disabled and (inspect_hovered or dropdown_hovered)) {
        const pill_inset = theme.scaledUi(2.0);
        const pill_radius = theme.scaledUi(TOOLBAR_BUTTON_RADIUS - 2.0);
        const hover_color = paletteColor(theme.lighten(base_color, 0.10));
        const seg = if (inspect_hovered) inspect_rect else dropdown_rect;
        queuePaletteRoundedRect(state, .{
            .x = seg.x + pill_inset,
            .y = seg.y + pill_inset,
            .w = seg.w - pill_inset * 2.0,
            .h = seg.h - pill_inset * 2.0,
        }, hover_color, pill_radius);
    }

    // Hairline divider between the segments, inset vertically so it reads as
    // a separator rather than a hard edge.
    const divider_inset = theme.scaledUi(8.0);
    queuePaletteRect(state, snapRect(.{
        .x = dropdown_rect.x,
        .y = inspect_rect.y + divider_inset,
        .w = theme.scaledUi(1.0),
        .h = inspect_rect.h - divider_inset * 2.0,
    }), paletteColor(theme.withAlpha(theme.background(), 70)));

    const icon_size = theme.scaledUi(TOOLBAR_ICON_SIZE);
    queuePaletteIcon(state, iconRectForButton(inspect_rect, icon_size), NF_COD_INSPECT, icon_size, paletteColor(icon_color));
    const chevron_size = theme.scaledUi(TOOLBAR_CHEVRON_SIZE);
    queuePaletteIcon(state, iconRectForButton(dropdown_rect, chevron_size), NF_COD_CHEVRON_DOWN, chevron_size, paletteColor(icon_color));
}

/// Renders the compact browser toolbar with URL entry and primary actions.
fn renderToolbar(state: *app_state.AppState, dock_rect: palette.Rect, right_reserve: f32) void {
    const toolbar_height = theme.scaledUi(TOOLBAR_HEIGHT);
    const tab_row_height = theme.scaledUi(TAB_ROW_HEIGHT);
    const button_size = theme.scaledUi(TOOLBAR_BUTTON_SIZE);
    const pad_x = theme.scaledUi(8.0);
    const gap = theme.scaledUi(4.0);

    palette_toolbar_rect = .{ .x = dock_rect.x, .y = dock_rect.y, .w = dock_rect.w, .h = toolbar_height };
    queuePaletteRect(state, palette_toolbar_rect, paletteColor(theme.background()));

    // Tab/title row: tabs expand into the available middle while pane chrome
    // keeps a fixed reserve on the right.
    const tab_count = state.browserTabCount();
    const row_y = dock_rect.y + (tab_row_height - button_size) * 0.5;
    const new_tab_rect: palette.Rect = .{ .x = dock_rect.x + pad_x, .y = row_y, .w = button_size, .h = button_size };
    renderCompactIconButton(state, new_tab_rect, NF_COD_ADD, rectHovered(new_tab_rect), false);
    addPaletteHit(new_tab_rect, .new_tab);

    const row_right = dock_rect.x + dock_rect.w - pad_x;
    const close_pane_rect: palette.Rect = .{ .x = row_right - button_size, .y = row_y, .w = button_size, .h = button_size };
    renderCompactIconButton(state, close_pane_rect, NF_COD_CLOSE, rectHovered(close_pane_rect), false);
    addPaletteHit(close_pane_rect, .close);
    const overflow_rect: palette.Rect = .{
        .x = close_pane_rect.x - right_reserve - gap - button_size,
        .y = row_y,
        .w = button_size,
        .h = button_size,
    };
    renderCompactIconButton(state, overflow_rect, NF_COD_ELLIPSIS, rectHovered(overflow_rect) or toolbar_overflow_open, false);
    addPaletteHit(overflow_rect, .overflow);

    const tabs_x = new_tab_rect.x + new_tab_rect.w + gap;
    const tabs_right = overflow_rect.x - gap;
    const tabs_w = @max(tabs_right - tabs_x, 0.0);
    if (tabs_w >= theme.scaledUi(40.0) and tab_count <= 1) {
        const tab_rect: palette.Rect = .{
            .x = tabs_x,
            .y = row_y,
            .w = @min(tabs_w, theme.scaledUi(190.0)),
            .h = button_size,
        };
        queuePaletteRoundedRect(state, tab_rect, paletteColor(theme.COLOR_PANEL_ALT), theme.scaledUi(6.0));
        queuePaletteBorder(state, tab_rect, paletteColor(theme.COLOR_PANEL_MUTED), theme.scaledUi(6.0), theme.scaledUi(1.0));
        const tab_close_size = theme.scaledUi(18.0);
        const tab_close_rect: palette.Rect = .{
            .x = tab_rect.x + tab_rect.w - tab_close_size - theme.scaledUi(3.0),
            .y = tab_rect.y + (tab_rect.h - tab_close_size) * 0.5,
            .w = tab_close_size,
            .h = tab_close_size,
        };
        const leading = renderTabIndicator(state, 0, tab_rect);
        queuePaletteText(state, .{
            .x = tab_rect.x + theme.scaledUi(6.0) + leading,
            .y = row_y + theme.scaledUi(6.0),
            .w = @max(tab_close_rect.x - tab_rect.x - theme.scaledUi(10.0) - leading, 1.0),
            .h = theme.scaledUi(18.0),
        }, state.browserTabTitle(0), paletteColor(theme.COLOR_TEXT_MUTED), theme.scaledUi(13.0), tab_rect);
        renderCompactIconButton(state, tab_close_rect, NF_COD_CLOSE, rectHovered(tab_close_rect), false);
        palette_tab_hits[palette_tab_hit_count] = .{ .rect = tab_close_rect, .index = 0, .kind = .close };
        palette_tab_hit_count += 1;
    } else if (tabs_w >= theme.scaledUi(40.0)) {
        const visible_count = @min(tab_count, palette_tab_hits.len / 2);
        const tab_width = @min(theme.scaledUi(180.0), @max(tabs_w / @as(f32, @floatFromInt(visible_count)), theme.scaledUi(56.0)));
        const slot_count = @max(@as(usize, 1), @as(usize, @intFromFloat(@floor((tabs_w + gap) / (tab_width + gap)))));
        const active_index = state.activeBrowserTabIndex();
        const first_visible = firstVisibleBrowserTabIndex(tab_count, active_index, slot_count);
        const last_visible = @min(first_visible + slot_count, tab_count);
        var tab_x = tabs_x;
        for (first_visible..last_visible) |tab_index| {
            if (palette_tab_hit_count + 2 > palette_tab_hits.len) break;
            if (tab_x + tab_width > tabs_right) break;
            const tab_rect: palette.Rect = .{ .x = tab_x, .y = row_y, .w = tab_width, .h = button_size };
            const active = tab_index == state.activeBrowserTabIndex();
            queuePaletteRoundedRect(
                state,
                tab_rect,
                paletteColor(if (active or rectHovered(tab_rect)) theme.COLOR_PANEL_ALT else theme.background()),
                theme.scaledUi(6.0),
            );
            queuePaletteBorder(
                state,
                tab_rect,
                paletteColor(if (active) theme.withAlpha(theme.accent(), 150) else theme.COLOR_PANEL_MUTED),
                theme.scaledUi(6.0),
                theme.scaledUi(1.0),
            );
            const tab_close_size = theme.scaledUi(18.0);
            const tab_close_rect: palette.Rect = .{
                .x = tab_rect.x + tab_rect.w - tab_close_size - theme.scaledUi(3.0),
                .y = tab_rect.y + (tab_rect.h - tab_close_size) * 0.5,
                .w = tab_close_size,
                .h = tab_close_size,
            };
            const leading = renderTabIndicator(state, tab_index, tab_rect);
            queuePaletteText(state, .{
                .x = tab_rect.x + theme.scaledUi(8.0) + leading,
                .y = tab_rect.y + theme.scaledUi(6.0),
                .w = @max(tab_close_rect.x - tab_rect.x - theme.scaledUi(12.0) - leading, 1.0),
                .h = theme.scaledUi(18.0),
            }, state.browserTabTitle(tab_index), paletteColor(if (tab_index == state.activeBrowserTabIndex()) theme.COLOR_WHITE else theme.COLOR_TEXT_MUTED), theme.scaledUi(12.0), tab_rect);
            renderCompactIconButton(state, tab_close_rect, NF_COD_CLOSE, rectHovered(tab_close_rect), false);
            palette_tab_hits[palette_tab_hit_count] = .{ .rect = tab_rect, .index = tab_index, .kind = .select };
            palette_tab_hit_count += 1;
            palette_tab_hits[palette_tab_hit_count] = .{ .rect = tab_close_rect, .index = tab_index, .kind = .close };
            palette_tab_hit_count += 1;
            if (tab_drag_active and tab_drag_target == tab_index) {
                queuePaletteBorder(state, tab_rect, paletteColor(theme.accent()), theme.scaledUi(6.0), theme.scaledUi(2.0));
            }
            tab_x += tab_width + gap;
        }
    }

    const nav_y = dock_rect.y + tab_row_height + (theme.scaledUi(NAV_ROW_HEIGHT) - button_size) * 0.5;
    var cursor_x = dock_rect.x + pad_x;
    const show_copy = dock_rect.w >= theme.scaledUi(430.0);
    const show_external = dock_rect.w >= theme.scaledUi(560.0);
    const show_inspector = dock_rect.w >= theme.scaledUi(680.0);
    const trailing_count: f32 = 1.0 +
        @as(f32, if (show_copy) 1.0 else 0.0) +
        @as(f32, if (show_external) 1.0 else 0.0) +
        @as(f32, if (show_inspector) 1.65 else 0.0);
    const address_rect: palette.Rect = .{
        .x = cursor_x + (button_size + gap) * 2.0,
        .y = nav_y,
        .w = @max(dock_rect.w - pad_x * 2.0 - (button_size + gap) * (2.0 + trailing_count), theme.scaledUi(48.0)),
        .h = button_size,
    };
    const back_rect: palette.Rect = .{ .x = cursor_x, .y = nav_y, .w = button_size, .h = button_size };
    renderCompactIconButton(state, back_rect, NF_COD_ARROW_LEFT, rectHovered(back_rect), !state.browserCanGoBack());
    addPaletteHit(back_rect, .back);
    cursor_x += button_size + gap;
    const forward_rect: palette.Rect = .{ .x = cursor_x, .y = nav_y, .w = button_size, .h = button_size };
    renderCompactIconButton(state, forward_rect, NF_COD_ARROW_RIGHT, rectHovered(forward_rect), !state.browserCanGoForward());
    addPaletteHit(forward_rect, .forward);
    addPaletteHit(address_rect, .address);
    renderPaletteAddressField(state, address_rect);

    cursor_x = address_rect.x + address_rect.w + gap;
    const navigate_rect: palette.Rect = .{ .x = cursor_x, .y = nav_y, .w = button_size, .h = button_size };
    renderCompactIconButton(state, navigate_rect, NF_COD_REFRESH, rectHovered(navigate_rect), false);
    addPaletteHit(navigate_rect, .navigate);
    cursor_x += button_size + gap;
    if (show_copy) {
        const copy_rect: palette.Rect = .{ .x = cursor_x, .y = nav_y, .w = button_size, .h = button_size };
        renderCompactIconButton(state, copy_rect, NF_COD_COPY, rectHovered(copy_rect), state.browserState().current_url == null);
        addPaletteHit(copy_rect, .copy_url);
        cursor_x += button_size + gap;
    }
    if (show_external) {
        const external_rect: palette.Rect = .{ .x = cursor_x, .y = nav_y, .w = button_size, .h = button_size };
        renderCompactIconButton(state, external_rect, NF_COD_LINK_EXTERNAL, rectHovered(external_rect), state.browserState().current_url == null);
        addPaletteHit(external_rect, .open_external);
        cursor_x += button_size + gap;
    }
    if (show_inspector) {
        const inspector_active = state.isBrowserInspectorEnabled();
        const inspect_rect: palette.Rect = .{ .x = cursor_x, .y = nav_y, .w = button_size, .h = button_size };
        renderInspectorIconButton(state, inspect_rect, NF_COD_INSPECT, rectHovered(inspect_rect), !state.canUseBrowserInspector(), inspector_active);
        addPaletteHit(inspect_rect, .inspect_toggle);
        const dropdown_width = theme.scaledUi(20.0);
        const inspect_menu_rect: palette.Rect = .{
            .x = inspect_rect.x + inspect_rect.w,
            .y = nav_y,
            .w = dropdown_width,
            .h = button_size,
        };
        renderInspectorIconButton(state, inspect_menu_rect, NF_COD_CHEVRON_DOWN, rectHovered(inspect_menu_rect), !state.canUseBrowserInspector(), inspector_active);
        addPaletteHit(inspect_menu_rect, .inspect_mode_menu);
        if (!state.canUseBrowserInspector()) state.browser_inspector_menu_open = false;
        if (state.browser_inspector_menu_open) {
            renderInspectorModeMenu(state, inspect_menu_rect, state.browserInspectorMode());
        }
    } else {
        state.browser_inspector_menu_open = false;
    }
    if (toolbar_overflow_open) renderToolbarOverflowMenu(state, overflow_rect, show_copy, show_external, show_inspector);
}

fn firstVisibleBrowserTabIndex(tab_count: usize, active_index: usize, slot_count: usize) usize {
    if (tab_count == 0 or slot_count >= tab_count) return 0;
    const centered_start = @min(active_index, tab_count - 1) -| slot_count / 2;
    return @min(centered_start, tab_count - slot_count);
}

fn renderToolbarOverflowMenu(
    state: *app_state.AppState,
    anchor: palette.Rect,
    copy_visible: bool,
    external_visible: bool,
    inspector_visible: bool,
) void {
    const row_h = theme.scaledUi(30.0);
    const pad = theme.scaledUi(6.0);
    const menu_w = theme.scaledUi(238.0);
    const max_tab_rows = @min(state.browserTabCount(), @as(usize, 8));
    const hidden_action_rows: usize =
        @as(usize, if (copy_visible) 0 else 1) +
        @as(usize, if (external_visible) 0 else 1) +
        @as(usize, if (inspector_visible) 0 else 1);
    const action_rows: usize = 6 + hidden_action_rows;
    const row_count = max_tab_rows + action_rows;
    const menu_h = pad * 2.0 + row_h * @as(f32, @floatFromInt(row_count));
    const min_x = palette_toolbar_rect.x + theme.scaledUi(4.0);
    const max_x = palette_toolbar_rect.x + palette_toolbar_rect.w - menu_w - theme.scaledUi(4.0);
    palette_overflow_menu_rect = .{
        .x = std.math.clamp(anchor.x + anchor.w - menu_w, min_x, @max(min_x, max_x)),
        .y = anchor.y + anchor.h + theme.scaledUi(4.0),
        .w = menu_w,
        .h = menu_h,
    };
    queuePaletteRoundedRect(state, palette_overflow_menu_rect, paletteColor(theme.COLOR_PANEL_ALT), theme.scaledUi(10.0));
    queuePaletteBorder(state, palette_overflow_menu_rect, paletteColor(theme.COLOR_PANEL_MUTED), theme.scaledUi(10.0), theme.scaledUi(1.0));

    var y = palette_overflow_menu_rect.y + pad;
    for (0..max_tab_rows) |tab_index| {
        var label_buf = std.mem.zeroes([160]u8);
        const prefix = if (tab_index == state.activeBrowserTabIndex()) "Current: " else "Tab: ";
        const label = std.fmt.bufPrint(&label_buf, "{s}{s}", .{ prefix, state.browserTabTitle(tab_index) }) catch state.browserTabTitle(tab_index);
        renderToolbarOverflowRow(state, .{ .x = palette_overflow_menu_rect.x + pad, .y = y, .w = menu_w - pad * 2.0, .h = row_h }, label, .{ .select_tab = tab_index }, true);
        y += row_h;
    }

    renderToolbarOverflowRow(state, overflowRowRect(y, row_h, pad, menu_w), "Duplicate active tab", .duplicate_tab, state.browserTabCount() > 0);
    y += row_h;
    renderToolbarOverflowRow(
        state,
        overflowRowRect(y, row_h, pad, menu_w),
        if (state.browserTabPinned(state.activeBrowserTabIndex())) "Unpin active tab" else "Pin active tab",
        .toggle_pin,
        state.browserTabCount() > 0,
    );
    y += row_h;
    const pane_id = state.currentProjectVisibleBrowserPaneId();
    const maximized = if (pane_id) |id| state.isCurrentProjectWorkspacePaneMaximized(id) else false;
    renderToolbarOverflowRow(state, overflowRowRect(y, row_h, pad, menu_w), if (maximized) "Restore pane" else "Maximize pane", .maximize_pane, pane_id != null);
    y += row_h;
    const detached = browserPaneIsDetached(state);
    renderToolbarOverflowRow(state, overflowRowRect(y, row_h, pad, menu_w), if (detached) "Return pane to layout" else "Float pane", .toggle_detach, pane_id != null);
    y += row_h;
    renderToolbarOverflowRow(state, overflowRowRect(y, row_h, pad, menu_w), "Reload page", .reload, true);
    y += row_h;
    if (!copy_visible) {
        renderToolbarOverflowRow(state, overflowRowRect(y, row_h, pad, menu_w), "Copy URL", .copy_url, state.browserState().current_url != null);
        y += row_h;
    }
    if (!external_visible) {
        renderToolbarOverflowRow(state, overflowRowRect(y, row_h, pad, menu_w), "Open in default browser", .open_external, state.browserState().current_url != null);
        y += row_h;
    }
    if (!inspector_visible) {
        renderToolbarOverflowRow(state, overflowRowRect(y, row_h, pad, menu_w), if (state.isBrowserInspectorEnabled()) "Disable inspector" else "Enable inspector", .toggle_inspector, state.canUseBrowserInspector());
        y += row_h;
    }
    renderToolbarOverflowRow(state, overflowRowRect(y, row_h, pad, menu_w), "Close browser pane", .close_pane, pane_id != null);
}

fn overflowRowRect(y: f32, row_h: f32, pad: f32, menu_w: f32) palette.Rect {
    return .{ .x = palette_overflow_menu_rect.x + pad, .y = y, .w = menu_w - pad * 2.0, .h = row_h };
}

fn renderToolbarOverflowRow(
    state: *app_state.AppState,
    rect: palette.Rect,
    label: []const u8,
    action: BrowserOverflowAction,
    enabled: bool,
) void {
    const hovered = rectHovered(rect);
    if (hovered and enabled) {
        queuePaletteRoundedRect(state, rect, paletteColor(theme.lighten(theme.COLOR_PANEL_ALT, 0.08)), theme.scaledUi(6.0));
    }
    queuePaletteText(state, .{
        .x = rect.x + theme.scaledUi(8.0),
        .y = rect.y + (rect.h - theme.scaledUi(13.0) * 1.25) * 0.5,
        .w = rect.w - theme.scaledUi(16.0),
        .h = theme.scaledUi(13.0) * 1.25,
    }, label, paletteColor(if (enabled) theme.COLOR_TEXT_MUTED else theme.COLOR_TEXT_SUBTLE), theme.scaledUi(13.0), rect);
    if (palette_overflow_hit_count < palette_overflow_hits.len) {
        palette_overflow_hits[palette_overflow_hit_count] = .{ .rect = rect, .action = action, .enabled = enabled };
        palette_overflow_hit_count += 1;
    }
}

fn overflowActionAtPoint(x: f32, y: f32) ?BrowserOverflowHit {
    var index = palette_overflow_hit_count;
    while (index > 0) {
        index -= 1;
        const hit = palette_overflow_hits[index];
        if (rectContainsPoint(hit.rect, x, y)) return hit;
    }
    return null;
}

fn browserPaneIsDetached(state: *app_state.AppState) bool {
    const pane_id = state.currentProjectVisibleBrowserPaneId() orelse return false;
    const quick = state.currentProjectQuickPane() orelse return false;
    return quick.pane_id == pane_id and quick.detached;
}

fn activateOverflowAction(state: *app_state.AppState, action: BrowserOverflowAction) void {
    switch (action) {
        .select_tab => |index| state.switchBrowserTab(index),
        .duplicate_tab => state.duplicateBrowserTab(state.activeBrowserTabIndex()),
        .toggle_pin => state.toggleBrowserTabPinned(state.activeBrowserTabIndex()),
        .maximize_pane => if (state.currentProjectVisibleBrowserPaneId()) |pane_id| {
            _ = state.toggleCurrentProjectWorkspacePaneMaximized(pane_id);
        },
        .toggle_detach => if (browserPaneIsDetached(state)) {
            _ = state.returnCurrentProjectQuickPaneToTile();
        } else if (state.currentProjectVisibleBrowserPaneId()) |pane_id| {
            _ = state.focusCurrentProjectWorkspacePane(pane_id);
            _ = state.floatFocusedWorkspacePane();
        },
        .reload => state.reloadBrowser(),
        .copy_url => copyCurrentUrl(state),
        .open_external => state.openCurrentBrowserUrlExternally(),
        .toggle_inspector => if (state.canUseBrowserInspector()) state.toggleBrowserInspector(),
        .close_pane => if (state.currentProjectVisibleBrowserPaneId()) |pane_id| {
            _ = state.closeCurrentProjectWorkspacePane(pane_id);
        },
    }
}

fn renderToolbarTooltip(state: *app_state.AppState) void {
    if (toolbar_overflow_open or state.browser_inspector_menu_open or state.browser_context_menu_open) return;
    var index = palette_hit_count;
    while (index > 0) {
        index -= 1;
        const hit = palette_hits[index];
        if (!rectHovered(hit.rect) or hit.kind == .address) continue;
        const label = toolbarTooltipLabel(state, hit.kind);
        const font_size = theme.scaledUi(11.0);
        const text_w = app_state.paletteUiTextPrefixWidth(label, font_size, label.len);
        const pad_x = theme.scaledUi(7.0);
        const tooltip_w = text_w + pad_x * 2.0;
        const min_x = palette_toolbar_rect.x + theme.scaledUi(4.0);
        const max_x = palette_toolbar_rect.x + palette_toolbar_rect.w - tooltip_w - theme.scaledUi(4.0);
        const rect: palette.Rect = .{
            .x = std.math.clamp(hit.rect.x + hit.rect.w * 0.5 - tooltip_w * 0.5, min_x, @max(min_x, max_x)),
            .y = palette_toolbar_rect.y + palette_toolbar_rect.h + theme.scaledUi(4.0),
            .w = tooltip_w,
            .h = theme.scaledUi(24.0),
        };
        queuePaletteRoundedRect(state, rect, paletteColor(theme.COLOR_PANEL_ALT), theme.scaledUi(5.0));
        queuePaletteBorder(state, rect, paletteColor(theme.COLOR_PANEL_MUTED), theme.scaledUi(5.0), theme.scaledUi(1.0));
        queuePaletteText(state, .{
            .x = rect.x + pad_x,
            .y = rect.y + (rect.h - font_size * 1.25) * 0.5,
            .w = rect.w - pad_x * 2.0,
            .h = font_size * 1.25,
        }, label, paletteColor(theme.COLOR_TEXT_MUTED), font_size, rect);
        return;
    }
}

fn toolbarTooltipLabel(state: *app_state.AppState, kind: BrowserHitKind) []const u8 {
    return switch (kind) {
        .address => "",
        .back => "Back",
        .forward => "Forward",
        .navigate => if (state.browserState().status == .opening) "Loading" else "Reload",
        .inspect_toggle => if (state.isBrowserInspectorEnabled()) "Disable inspector" else "Enable inspector",
        .inspect_mode_menu => "Inspector mode",
        .inspect_mode_point => "Point inspector",
        .inspect_mode_draw_box => "Box inspector",
        .inspect_mode_draw_freeform => "Freeform inspector",
        .setup_dev_server => "Set up development server",
        .new_tab => "New tab",
        .close_tab => "Close active tab",
        .copy_url => "Copy URL",
        .open_external => "Open in default browser",
        .overflow => "Browser actions",
        .security_info => browserSecurityNotice(state.browserState().current_url),
        .close => "Close browser pane",
    };
}

fn renderInspectorModeMenu(state: *app_state.AppState, anchor: palette.Rect, inspector_mode: browser_runtime.InspectorMode) void {
    const menu_width = theme.scaledUi(180.0);
    const row_height = theme.scaledUi(32.0);
    const pad = theme.scaledUi(8.0);
    palette_menu_rect = .{
        .x = anchor.x + anchor.w - menu_width,
        .y = anchor.y + anchor.h + theme.scaledUi(6.0),
        .w = menu_width,
        .h = row_height * 3.0 + pad * 2.0,
    };
    queuePaletteRoundedRect(state, palette_menu_rect, paletteColor(theme.COLOR_PANEL_ALT), theme.scaledUi(12.0));
    queuePaletteBorder(state, palette_menu_rect, paletteColor(theme.COLOR_PANEL_MUTED), theme.scaledUi(12.0), theme.scaledUi(1.0));

    var y = palette_menu_rect.y + pad;
    renderInspectorModeMenuRow(state, .{ .x = palette_menu_rect.x + pad, .y = y, .w = palette_menu_rect.w - pad * 2.0, .h = row_height }, "Point", inspector_mode == .point, .inspect_mode_point);
    y += row_height;
    renderInspectorModeMenuRow(state, .{ .x = palette_menu_rect.x + pad, .y = y, .w = palette_menu_rect.w - pad * 2.0, .h = row_height }, "Draw Box", inspector_mode == .draw_box, .inspect_mode_draw_box);
    y += row_height;
    renderInspectorModeMenuRow(state, .{ .x = palette_menu_rect.x + pad, .y = y, .w = palette_menu_rect.w - pad * 2.0, .h = row_height }, "Draw Freeform", inspector_mode == .draw_freeform, .inspect_mode_draw_freeform);
}

fn renderInspectorModeMenuRow(state: *app_state.AppState, rect: palette.Rect, label: []const u8, selected: bool, kind: BrowserHitKind) void {
    const hovered = rectHovered(rect);
    if (selected or hovered) {
        queuePaletteRoundedRect(
            state,
            rect,
            paletteColor(if (selected) theme.withAlpha(theme.accent(), 64) else theme.lighten(theme.COLOR_PANEL_ALT, 0.08)),
            theme.scaledUi(6.0),
        );
    }

    const marker = if (selected) "* " else "  ";
    var row_buf = std.mem.zeroes([64]u8);
    const row_label = std.fmt.bufPrint(&row_buf, "{s}{s}", .{ marker, label }) catch label;
    queuePaletteText(state, .{
        .x = rect.x + theme.scaledUi(8.0),
        .y = rect.y + (rect.h - theme.scaledUi(14.0) * 1.25) * 0.5,
        .w = rect.w - theme.scaledUi(16.0),
        .h = theme.scaledUi(14.0) * 1.25,
    }, row_label, paletteColor(if (selected) theme.COLOR_WHITE else theme.COLOR_TEXT_MUTED), theme.scaledUi(14.0), rect);
    addPaletteHit(rect, kind);
}

// Renders the root browser context menu plus the active recursive submenu chain.
fn renderBrowserContextMenu(state: *app_state.AppState) void {
    if (!state.browser_context_menu_open) return;
    if (state.browser_context_menu_selected_index == null) {
        selectBrowserContextMenuBoundary(state, false);
    }
    const root_height = browserContextMenuContentHeight(state, null);
    const root_rect = clampedBrowserContextMenuRect(
        state,
        state.browser_context_menu_anchor_x,
        state.browser_context_menu_anchor_y,
        root_height,
    );
    palette_context_menu_rect = root_rect;
    renderBrowserContextMenuPanel(state, null, root_rect, 0);
}

fn browserContextMenuContentHeight(state: *const app_state.AppState, parent_index: ?u32) f32 {
    const row_height = theme.scaledUi(30.0);
    const separator_height = theme.scaledUi(9.0);
    const pad = theme.scaledUi(6.0);
    var height = pad * 2.0;
    if (parent_index == null and state.browserContextMenuHasLink()) height += row_height * 2.0 + separator_height;
    for (state.browser_context_menu_items.items) |item| {
        if (item.parent_index != parent_index) continue;
        height += if (item.separator) separator_height else row_height;
    }
    if (parent_index == null and state.currentProjectVisibleBrowserPaneId() != null) {
        height += separator_height + row_height;
    }
    return height;
}

fn clampedBrowserContextMenuRect(state: *const app_state.AppState, desired_x: f32, desired_y: f32, height: f32) palette.Rect {
    const menu_width = theme.scaledUi(260.0);
    const edge = theme.scaledUi(4.0);
    const min_x = state.browser_pane_min[0] + edge;
    const min_y = state.browser_pane_min[1] + edge;
    const max_x = state.browser_pane_max[0] - menu_width - edge;
    const max_y = state.browser_pane_max[1] - height - edge;
    return .{
        .x = theme.clampf(desired_x, min_x, @max(min_x, max_x)),
        .y = theme.clampf(desired_y, min_y, @max(min_y, max_y)),
        .w = menu_width,
        .h = height,
    };
}

fn browserContextMenuParentIsOpen(state: *const app_state.AppState, candidate: u32) bool {
    var current = state.browser_context_menu_active_parent;
    while (current) |item_index| {
        if (item_index == candidate) return true;
        const item = contextMenuItemByIndex(state, item_index) orelse return false;
        current = item.parent_index;
    }
    return false;
}

// Renders one menu level and recursively places the open child beside its parent row.
fn renderBrowserContextMenuPanel(state: *app_state.AppState, parent_index: ?u32, panel_rect: palette.Rect, depth: usize) void {
    if (depth >= palette_context_menu_panels.len) return;
    palette_context_menu_panels[palette_context_menu_panel_count] = panel_rect;
    palette_context_menu_panel_count += 1;

    queuePaletteRoundedRect(state, panel_rect, paletteColor(theme.withAlpha(theme.COLOR_PANEL_ALT, 245)), theme.scaledUi(8.0));
    queuePaletteBorder(state, panel_rect, paletteColor(theme.COLOR_PANEL_MUTED), theme.scaledUi(8.0), theme.scaledUi(1.0));

    const row_height = theme.scaledUi(30.0);
    const separator_height = theme.scaledUi(9.0);
    const pad = theme.scaledUi(6.0);
    var row_y = panel_rect.y + pad;
    var open_child: ?app_state.BrowserContextMenuItem = null;
    var open_child_y: f32 = 0.0;

    if (parent_index == null and state.browserContextMenuHasLink()) {
        const current_rect: palette.Rect = .{ .x = panel_rect.x + pad, .y = row_y, .w = panel_rect.w - pad * 2.0, .h = row_height };
        renderBrowserContextLinkRow(state, current_rect, "Open Link", .open_link_current);
        row_y += row_height;
        const new_tab_rect: palette.Rect = .{ .x = panel_rect.x + pad, .y = row_y, .w = panel_rect.w - pad * 2.0, .h = row_height };
        renderBrowserContextLinkRow(state, new_tab_rect, "Open Link in New Tab", .open_link_new_tab);
        row_y += row_height;
        queuePaletteRect(state, snapRect(.{
            .x = panel_rect.x + pad,
            .y = row_y + separator_height * 0.5,
            .w = panel_rect.w - pad * 2.0,
            .h = theme.scaledUi(1.0),
        }), paletteColor(theme.withAlpha(theme.COLOR_PANEL_MUTED, 180)));
        row_y += separator_height;
    }

    for (state.browser_context_menu_items.items) |item| {
        if (item.parent_index != parent_index) continue;
        if (item.separator) {
            queuePaletteRect(state, snapRect(.{
                .x = panel_rect.x + pad,
                .y = row_y + separator_height * 0.5,
                .w = panel_rect.w - pad * 2.0,
                .h = theme.scaledUi(1.0),
            }), paletteColor(theme.withAlpha(theme.COLOR_PANEL_MUTED, 180)));
            row_y += separator_height;
            continue;
        }

        const row_rect: palette.Rect = .{
            .x = panel_rect.x + pad,
            .y = row_y,
            .w = panel_rect.w - pad * 2.0,
            .h = row_height,
        };
        const selected = state.browser_context_menu_selected_index == item.index;
        if (selected or (rectHovered(row_rect) and item.enabled)) {
            queuePaletteRoundedRect(state, row_rect, paletteColor(theme.lighten(theme.COLOR_PANEL_ALT, 0.08)), theme.scaledUi(5.0));
        }
        const trailing_width = if (item.submenu) theme.scaledUi(22.0) else 0.0;
        queuePaletteText(state, .{
            .x = row_rect.x + theme.scaledUi(8.0),
            .y = row_rect.y + (row_rect.h - theme.scaledUi(13.0) * 1.25) * 0.5,
            .w = row_rect.w - theme.scaledUi(16.0) - trailing_width,
            .h = theme.scaledUi(13.0) * 1.25,
        }, item.label, paletteColor(if (item.enabled) theme.COLOR_TEXT_MUTED else theme.COLOR_TEXT_SUBTLE), theme.scaledUi(13.0), row_rect);
        if (item.submenu) {
            queuePaletteText(state, .{
                .x = row_rect.x + row_rect.w - theme.scaledUi(18.0),
                .y = row_rect.y + (row_rect.h - theme.scaledUi(13.0) * 1.25) * 0.5,
                .w = theme.scaledUi(12.0),
                .h = theme.scaledUi(13.0) * 1.25,
            }, ">", paletteColor(if (item.enabled) theme.COLOR_TEXT_MUTED else theme.COLOR_TEXT_SUBTLE), theme.scaledUi(13.0), row_rect);
            if (browserContextMenuParentIsOpen(state, item.index)) {
                open_child = item;
                open_child_y = row_rect.y - pad;
            }
        }
        addBrowserContextMenuHit(row_rect, .{ .backend_item = item });
        row_y += row_height;
    }

    if (parent_index == null and state.currentProjectVisibleBrowserPaneId() != null) {
        queuePaletteRect(state, snapRect(.{
            .x = panel_rect.x + pad,
            .y = row_y + separator_height * 0.5,
            .w = panel_rect.w - pad * 2.0,
            .h = theme.scaledUi(1.0),
        }), paletteColor(theme.withAlpha(theme.COLOR_PANEL_MUTED, 180)));
        row_y += separator_height;
        const close_rect: palette.Rect = .{
            .x = panel_rect.x + pad,
            .y = row_y,
            .w = panel_rect.w - pad * 2.0,
            .h = row_height,
        };
        if (state.browser_context_menu_selected_index == CLOSE_PANE_MENU_INDEX or rectHovered(close_rect)) {
            queuePaletteRoundedRect(state, close_rect, paletteColor(theme.lighten(theme.COLOR_PANEL_ALT, 0.08)), theme.scaledUi(5.0));
        }
        queuePaletteText(state, .{
            .x = close_rect.x + theme.scaledUi(8.0),
            .y = close_rect.y + (close_rect.h - theme.scaledUi(13.0) * 1.25) * 0.5,
            .w = close_rect.w - theme.scaledUi(16.0),
            .h = theme.scaledUi(13.0) * 1.25,
        }, "Close Pane", paletteColor(theme.COLOR_TEXT_MUTED), theme.scaledUi(13.0), close_rect);
        addBrowserContextMenuHit(close_rect, .close_pane);
    }

    if (open_child) |child| {
        const overlap = theme.scaledUi(2.0);
        const right_x = panel_rect.x + panel_rect.w - overlap;
        const child_x = if (right_x + panel_rect.w <= state.browser_pane_max[0] - theme.scaledUi(4.0))
            right_x
        else
            panel_rect.x - panel_rect.w + overlap;
        const child_rect = clampedBrowserContextMenuRect(
            state,
            child_x,
            open_child_y,
            browserContextMenuContentHeight(state, child.index),
        );
        renderBrowserContextMenuPanel(state, child.index, child_rect, depth + 1);
    }
}

fn renderBrowserContextLinkRow(state: *app_state.AppState, rect: palette.Rect, label: []const u8, action: BrowserContextMenuAction) void {
    if (rectHovered(rect)) {
        queuePaletteRoundedRect(state, rect, paletteColor(theme.lighten(theme.COLOR_PANEL_ALT, 0.08)), theme.scaledUi(5.0));
    }
    queuePaletteText(state, .{
        .x = rect.x + theme.scaledUi(8.0),
        .y = rect.y + (rect.h - theme.scaledUi(13.0) * 1.25) * 0.5,
        .w = rect.w - theme.scaledUi(16.0),
        .h = theme.scaledUi(13.0) * 1.25,
    }, label, paletteColor(theme.COLOR_TEXT_MUTED), theme.scaledUi(13.0), rect);
    addBrowserContextMenuHit(rect, action);
}

fn addBrowserContextMenuHit(rect: palette.Rect, action: BrowserContextMenuAction) void {
    if (palette_context_menu_hit_count >= palette_context_menu_hits.len) return;
    palette_context_menu_hits[palette_context_menu_hit_count] = .{ .rect = rect, .action = action };
    palette_context_menu_hit_count += 1;
}

fn browserContextMenuContainsPoint(x: f32, y: f32) bool {
    for (palette_context_menu_panels[0..palette_context_menu_panel_count]) |panel| {
        if (rectContainsPoint(panel, x, y)) return true;
    }
    return false;
}

fn browserContextMenuActionAtPoint(x: f32, y: f32) ?BrowserContextMenuAction {
    var index = palette_context_menu_hit_count;
    while (index > 0) {
        index -= 1;
        const hit = palette_context_menu_hits[index];
        if (rectContainsPoint(hit.rect, x, y)) return hit.action;
    }
    return null;
}

const BrowserSecurityState = enum {
    secure,
    local,
    insecure,
    internal,
    unknown,
};

fn browserSecurityState(url: ?[]const u8) BrowserSecurityState {
    const value = url orelse return .unknown;
    if (std.mem.startsWith(u8, value, "https://")) return .secure;
    if (std.mem.startsWith(u8, value, "http://localhost") or
        std.mem.startsWith(u8, value, "http://127.") or
        std.mem.startsWith(u8, value, "http://[::1]"))
    {
        return .local;
    }
    if (std.mem.startsWith(u8, value, "http://")) return .insecure;
    if (std.mem.startsWith(u8, value, "about:") or std.mem.startsWith(u8, value, "file:")) return .internal;
    return .unknown;
}

fn browserSecurityNotice(url: ?[]const u8) []const u8 {
    return switch (browserSecurityState(url)) {
        .secure => "Secure HTTPS connection.",
        .local => "Local development page.",
        .insecure => "Connection is not encrypted.",
        .internal => "Browser-internal or local page.",
        .unknown => "Connection security is unavailable.",
    };
}

fn renderPaletteAddressField(state: *app_state.AppState, rect: palette.Rect) void {
    const focused = state.browser_address_focused;
    const address = state.browserState().addressInput();
    const text = if (address.len == 0 and !focused) "https://example.com" else address;
    const font_size = theme.scaledUi(14.0);
    const pad_x = theme.scaledUi(10.0);
    const security_slot = theme.scaledUi(20.0);
    const text_rect: palette.Rect = .{
        .x = rect.x + pad_x + security_slot,
        .y = rect.y + (rect.h - font_size * 1.25) * 0.5,
        .w = rect.w - pad_x * 2.0 - security_slot,
        .h = font_size * 1.25,
    };
    queuePaletteRoundedRect(
        state,
        rect,
        paletteColor(if (focused) theme.lighten(theme.COLOR_PANEL_ALT, 0.10) else theme.COLOR_PANEL_ALT),
        theme.scaledUi(8.0),
    );
    queuePaletteBorder(
        state,
        rect,
        paletteColor(if (state.browserState().status == .failed) theme.danger() else if (focused) theme.accent() else theme.COLOR_PANEL_MUTED),
        theme.scaledUi(8.0),
        theme.scaledUi(1.0),
    );

    const security = browserSecurityState(state.browserState().current_url);
    const security_rect: palette.Rect = .{
        .x = rect.x + theme.scaledUi(7.0),
        .y = rect.y + (rect.h - theme.scaledUi(14.0)) * 0.5,
        .w = theme.scaledUi(14.0),
        .h = theme.scaledUi(14.0),
    };
    const security_glyph = switch (security) {
        .secure => NF_COD_LOCK,
        .insecure => NF_COD_WARNING,
        .local, .internal, .unknown => NF_COD_GLOBE,
    };
    const security_color = switch (security) {
        .secure => theme.success(),
        .local => theme.accent(),
        .insecure => theme.danger(),
        .internal, .unknown => theme.COLOR_TEXT_MUTED,
    };
    queuePaletteIcon(state, security_rect, security_glyph, security_rect.w, paletteColor(security_color));
    addPaletteHit(security_rect, .security_info);

    // Draw selection highlight underneath the text so glyphs read over it.
    if (focused) {
        if (addressSelectionRange(state, address)) |sel| {
            const x0 = text_rect.x + app_state.paletteUiTextPrefixWidth(address, font_size, sel.start);
            const x1 = text_rect.x + app_state.paletteUiTextPrefixWidth(address, font_size, sel.end);
            const clamped_x0 = @max(x0, text_rect.x);
            const clamped_x1 = @min(x1, text_rect.x + text_rect.w);
            if (clamped_x1 > clamped_x0) {
                queuePaletteRect(state, .{
                    .x = clamped_x0,
                    .y = text_rect.y,
                    .w = clamped_x1 - clamped_x0,
                    .h = text_rect.h,
                }, paletteColor(theme.withAlpha(theme.selection(), 200)));
            }
        }
    }

    queuePaletteText(
        state,
        text_rect,
        text,
        paletteColor(if (address.len == 0 and !focused) theme.COLOR_TEXT_SUBTLE else theme.COLOR_WHITE),
        font_size,
        rect,
    );

    if (focused) {
        const cursor = @min(state.browser_address_cursor, address.len);
        const prefix_w = app_state.paletteUiTextPrefixWidth(address, font_size, cursor);
        const caret_x = text_rect.x + prefix_w;
        queuePaletteRect(state, .{
            .x = @min(caret_x, rect.x + rect.w - pad_x - theme.scaledUi(1.5)),
            .y = text_rect.y + theme.scaledUi(1.0),
            .w = theme.scaledUi(1.5),
            .h = text_rect.h - theme.scaledUi(2.0),
        }, paletteColor(theme.COLOR_WHITE));
    }
}

const SelectionRange = struct { start: usize, end: usize };

/// Returns the normalized selection range if the URL bar has a non-empty
/// selection. The anchor + cursor form the unordered endpoints; this returns
/// them in order so callers don't have to worry about direction.
fn addressSelectionRange(state: *app_state.AppState, address: []const u8) ?SelectionRange {
    const anchor = state.browser_address_selection_anchor orelse return null;
    const cursor = @min(state.browser_address_cursor, address.len);
    const a = @min(anchor, address.len);
    if (a == cursor) return null;
    return .{ .start = @min(a, cursor), .end = @max(a, cursor) };
}

fn clearAddressSelection(state: *app_state.AppState) void {
    state.browser_address_selection_anchor = null;
}

fn deleteAddressSelection(state: *app_state.AppState) bool {
    const browser_state = state.browserState();
    const address = browser_state.addressInput();
    const sel = addressSelectionRange(state, address) orelse return false;
    const buffer = browser_state.addressBuffer();
    const current_len = address.len;
    std.mem.copyForwards(u8, buffer[sel.start .. current_len - (sel.end - sel.start)], buffer[sel.end..current_len]);
    buffer[current_len - (sel.end - sel.start)] = 0;
    state.browser_address_cursor = sel.start;
    clearAddressSelection(state);
    return true;
}

fn isWordChar(b: u8) bool {
    return (b >= 'a' and b <= 'z') or (b >= 'A' and b <= 'Z') or (b >= '0' and b <= '9') or b == '_' or b == '-';
}

fn wordBoundsAt(address: []const u8, offset: usize) SelectionRange {
    if (address.len == 0) return .{ .start = 0, .end = 0 };
    var start = @min(offset, address.len);
    var end = start;
    while (start > 0 and isWordChar(address[start - 1])) start -= 1;
    while (end < address.len and isWordChar(address[end])) end += 1;
    // Empty run (clicked on a non-word boundary) — fall back to selecting the
    // single byte under the cursor so a double-click still produces a visible
    // selection.
    if (start == end and end < address.len) end += 1;
    return .{ .start = start, .end = end };
}

fn addPaletteHit(rect: palette.Rect, kind: BrowserHitKind) void {
    if (palette_hit_count >= palette_hits.len) return;
    palette_hits[palette_hit_count] = .{ .rect = rect, .kind = kind };
    palette_hit_count += 1;
}

fn rectHovered(rect: palette.Rect) bool {
    return rectContainsPoint(rect, palette_mouse_pos[0], palette_mouse_pos[1]);
}

fn rectContainsPoint(rect: palette.Rect, x: f32, y: f32) bool {
    return x >= rect.x and y >= rect.y and x <= rect.x + rect.w and y <= rect.y + rect.h;
}

fn focusAddress(state: *app_state.AppState) void {
    state.browser_address_focused = true;
    state.terminal_focused = false;
    state.composer_focused = false;
    state.blurPaletteComposer();
    state.unfocusBrowserPane();
    state.browser_inspector_menu_open = false;
    state.browser_address_cursor = @min(state.browser_address_cursor, state.browserState().addressInput().len);
}

fn blurAddress(state: *app_state.AppState) void {
    state.browser_address_focused = false;
    state.browser_address_cursor = @min(state.browser_address_cursor, state.browserState().addressInput().len);
    state.browser_address_drag_active = false;
    clearAddressSelection(state);
}

fn selectInspectorMode(state: *app_state.AppState, mode: browser_runtime.InspectorMode) void {
    blurAddress(state);
    state.setBrowserInspectorMode(mode);
    state.browser_inspector_menu_open = false;
}

fn addressIndexForClick(address: []const u8, font_size: f32, rel: f32) usize {
    if (address.len == 0 or rel <= 0.0) return 0;
    const total = app_state.paletteUiTextPrefixWidth(address, font_size, address.len);
    if (rel >= total) return address.len;

    var i: usize = 0;
    while (i < address.len) {
        const step = std.unicode.utf8ByteSequenceLength(address[i]) catch 1;
        const next = @min(i + step, address.len);
        const w_before = app_state.paletteUiTextPrefixWidth(address, font_size, i);
        const w_after = app_state.paletteUiTextPrefixWidth(address, font_size, next);
        if (w_after > rel) {
            return if (rel - w_before <= w_after - rel) i else next;
        }
        i = next;
    }
    return address.len;
}

fn cursorForAddressPoint(state: *app_state.AppState, rect: palette.Rect, x: f32) usize {
    const font_size = theme.scaledUi(14.0);
    const pad_x = theme.scaledUi(10.0);
    const security_slot = theme.scaledUi(20.0);
    const address = state.browserState().addressInput();
    const rel = @max(x - rect.x - pad_x - security_slot, 0.0);
    return @min(addressIndexForClick(address, font_size, rel), address.len);
}

fn insertAddressText(state: *app_state.AppState, text: []const u8) void {
    if (text.len == 0) return;
    const browser_state = state.browserState();
    const buffer = browser_state.addressBuffer();
    const current_len = browser_state.addressInput().len;
    const cursor = @min(state.browser_address_cursor, current_len);
    const available = if (buffer.len > current_len) buffer.len - current_len else 0;
    const insert_len = @min(text.len, available);
    if (insert_len == 0) return;

    std.mem.copyBackwards(u8, buffer[cursor + insert_len .. current_len + insert_len], buffer[cursor..current_len]);
    @memcpy(buffer[cursor .. cursor + insert_len], text[0..insert_len]);
    buffer[current_len + insert_len] = 0;
    state.browser_address_cursor = cursor + insert_len;
}

fn deleteAddressBackward(state: *app_state.AppState) void {
    const browser_state = state.browserState();
    const buffer = browser_state.addressBuffer();
    const current_len = browser_state.addressInput().len;
    const cursor = @min(state.browser_address_cursor, current_len);
    if (cursor == 0) return;
    std.mem.copyForwards(u8, buffer[cursor - 1 .. current_len - 1], buffer[cursor..current_len]);
    buffer[current_len - 1] = 0;
    state.browser_address_cursor = cursor - 1;
}

fn deleteAddressForward(state: *app_state.AppState) void {
    const browser_state = state.browserState();
    const buffer = browser_state.addressBuffer();
    const current_len = browser_state.addressInput().len;
    const cursor = @min(state.browser_address_cursor, current_len);
    if (cursor >= current_len) return;
    std.mem.copyForwards(u8, buffer[cursor .. current_len - 1], buffer[cursor + 1 .. current_len]);
    buffer[current_len - 1] = 0;
    state.browser_address_cursor = cursor;
}

fn isPrimaryModifierPressed(modifier_state: sdl.Keymod) bool {
    const bits = @as(*const u16, @ptrCast(&modifier_state)).*;
    return (bits & (sdl.Keymod.ctrl | sdl.Keymod.gui)) != 0;
}

/// Renders the in-app browser pane canvas or the current scaffold placeholder.
fn renderPaneCanvas(state: *app_state.AppState, pane_rect: palette.Rect) void {
    const browser_state = state.browserState();
    const pane_hovered = rectHovered(pane_rect);
    const input_size = state.browserPaneInputSize(pane_rect.w, pane_rect.h);
    state.noteBrowserPaneRegion(
        .{ pane_rect.x, pane_rect.y },
        .{ pane_rect.x + pane_rect.w, pane_rect.y + pane_rect.h },
        input_size,
        pane_hovered,
    );

    const page_is_empty = browserPageIsEmpty(browser_state);
    state.noteBrowserEmptyStateRendered(page_is_empty);

    queuePaletteRect(state, pane_rect, paletteColor(theme.background()));

    if (page_is_empty) {
        renderPanePlaceholder(state, pane_rect);
        return;
    }

    if (browser_state.controller.paneTexture()) |pane_texture| {
        if (pane_texture.isReady()) {
            state.palette_overlay_batch.image(
                state.allocator,
                snapRect(pane_rect),
                palette.TextureId.init(pane_texture.texture_id),
                .{ .x = 0.0, .y = 0.0, .w = 1.0, .h = 1.0 },
                paletteColor(theme.COLOR_WHITE),
                null,
            ) catch {};
            return;
        }
    }

    // Fall back to the full pane bounds while the browser frame has not arrived yet.
    renderPanePlaceholder(state, pane_rect);
}

fn renderWrappedPaletteText(
    state: *app_state.AppState,
    rect: palette.Rect,
    value: []const u8,
    color: palette.Color,
    font_size: f32,
    max_lines: usize,
) f32 {
    const line_height = font_size * 1.35;
    var cursor: usize = 0;
    var line: usize = 0;
    while (cursor < value.len and line < max_lines) : (line += 1) {
        while (cursor < value.len and value[cursor] == ' ') cursor += 1;
        if (cursor >= value.len) break;

        const line_start = cursor;
        var line_end = cursor;
        var scan = cursor;
        while (scan < value.len) {
            const word_end = std.mem.findScalarPos(u8, value, scan, ' ') orelse value.len;
            if (app_state.paletteUiTextPrefixWidth(value[line_start..word_end], font_size, word_end - line_start) > rect.w and line_end > line_start) break;
            line_end = word_end;
            scan = word_end;
            while (scan < value.len and value[scan] == ' ') scan += 1;
        }
        if (line_end == line_start) line_end = std.mem.findScalarPos(u8, value, cursor, ' ') orelse value.len;
        queuePaletteText(state, .{
            .x = rect.x,
            .y = rect.y + @as(f32, @floatFromInt(line)) * line_height,
            .w = rect.w,
            .h = line_height,
        }, value[line_start..line_end], color, font_size, rect);
        cursor = line_end;
    }
    return @as(f32, @floatFromInt(line)) * line_height;
}

// Renders the browser's useful empty/loading region.
fn renderPanePlaceholder(state: *app_state.AppState, pane_rect: palette.Rect) void {
    const content_width = @min(pane_rect.w - theme.scaledUi(48.0), theme.scaledUi(520.0));
    if (content_width <= 0.0) return;
    const title_size = theme.scaledUi(22.0);
    const body_size = theme.scaledUi(14.0);
    const button_width = theme.scaledUi(170.0);
    const button_height = theme.scaledUi(38.0);
    const block_height = theme.scaledUi(180.0);
    const x = pane_rect.x + (pane_rect.w - content_width) * 0.5;
    const y = pane_rect.y + @max((pane_rect.h - block_height) * 0.38, theme.scaledUi(28.0));

    queuePaletteText(state, .{ .x = x, .y = y, .w = content_width, .h = title_size * 1.3 }, "Browse and verify", paletteColor(theme.COLOR_WHITE), title_size, pane_rect);
    const body_y = y + theme.scaledUi(38.0);
    const body_height = renderWrappedPaletteText(state, .{
        .x = x,
        .y = body_y,
        .w = content_width,
        .h = body_size * 5.4,
    }, "Your agent can browse, interact with, and screenshot pages in this browser. Enter a URL above or start your development server to preview and verify your app.", paletteColor(theme.COLOR_TEXT_MUTED), body_size, 4);

    const button_rect: palette.Rect = .{
        .x = x,
        .y = body_y + body_height + theme.scaledUi(18.0),
        .w = button_width,
        .h = button_height,
    };
    const button_fill = if (rectHovered(button_rect)) theme.lighten(theme.accent(), 0.08) else theme.accent();
    queuePaletteRoundedRect(state, button_rect, paletteColor(button_fill), theme.scaledUi(8.0));
    queuePaletteText(state, .{
        .x = button_rect.x + theme.scaledUi(14.0),
        .y = button_rect.y + (button_rect.h - body_size * 1.25) * 0.5,
        .w = button_rect.w - theme.scaledUi(28.0),
        .h = body_size * 1.25,
    }, "Set up dev server", paletteColor(theme.foregroundOn(button_fill)), body_size, button_rect);
    addPaletteHit(button_rect, .setup_dev_server);
}

fn browserPageIsEmpty(browser_state: *const browser_runtime.State) bool {
    const raw = browser_state.current_url orelse browser_state.addressInput();
    const url = std.mem.trim(u8, raw, &std.ascii.whitespace);
    return url.len == 0 or std.mem.eql(u8, url, "about:blank");
}

test "browser context-menu keyboard selection filters rows by level and wraps" {
    var label: [0]u8 = .{};
    const items = [_]app_state.BrowserContextMenuItem{
        .{ .index = 1, .label = &label, .enabled = true, .separator = false, .submenu = true, .parent_index = null },
        .{ .index = 2, .label = &label, .enabled = false, .separator = false, .submenu = false, .parent_index = null },
        .{ .index = 3, .label = &label, .enabled = true, .separator = true, .submenu = false, .parent_index = null },
        .{ .index = 4, .label = &label, .enabled = true, .separator = false, .submenu = false, .parent_index = 1 },
    };
    var indexes: [128]u32 = undefined;

    const root_count = selectableBrowserContextMenuIndexesFromItems(&items, null, true, &indexes);
    try std.testing.expectEqualSlices(u32, &.{ 1, CLOSE_PANE_MENU_INDEX }, indexes[0..root_count]);
    try std.testing.expectEqual(@as(u32, 1), nextBrowserContextMenuSelection(indexes[0..root_count], CLOSE_PANE_MENU_INDEX, 1));
    try std.testing.expectEqual(CLOSE_PANE_MENU_INDEX, nextBrowserContextMenuSelection(indexes[0..root_count], 1, -1));

    const child_count = selectableBrowserContextMenuIndexesFromItems(&items, 1, false, &indexes);
    try std.testing.expectEqualSlices(u32, &.{4}, indexes[0..child_count]);
}

test "narrow tab windows keep the active browser tab visible" {
    try std.testing.expectEqual(@as(usize, 0), firstVisibleBrowserTabIndex(8, 0, 3));
    try std.testing.expectEqual(@as(usize, 3), firstVisibleBrowserTabIndex(8, 4, 3));
    try std.testing.expectEqual(@as(usize, 5), firstVisibleBrowserTabIndex(8, 7, 3));
    try std.testing.expectEqual(@as(usize, 0), firstVisibleBrowserTabIndex(2, 1, 3));
}

test "browser security presentation distinguishes remote local and internal URLs" {
    try std.testing.expectEqual(BrowserSecurityState.secure, browserSecurityState("https://verdeai.dev"));
    try std.testing.expectEqual(BrowserSecurityState.local, browserSecurityState("http://localhost:3000"));
    try std.testing.expectEqual(BrowserSecurityState.insecure, browserSecurityState("http://example.com"));
    try std.testing.expectEqual(BrowserSecurityState.internal, browserSecurityState("about:blank"));
    try std.testing.expectEqual(BrowserSecurityState.unknown, browserSecurityState(null));
}
