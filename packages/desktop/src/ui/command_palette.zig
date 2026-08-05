//! Command palette overlay (Ctrl+Shift+P): a Raycast-style launcher mixing static
//! commands, thread history search, and workspace switching in one ranked
//! list. The static command set is the `STATIC_COMMANDS` table below — adding
//! a palette entry is adding one row there. Dynamic results (threads,
//! workspaces) come from the collector functions in `rebuildResults`.
//!
//! Input routing lives in `layout.zig` (modal hits, text editing) and
//! `main.zig` (keybind dispatch); this module owns result building, layout,
//! rendering, and activation.

const std = @import("std");
const palette = @import("palette");
const sdl = @import("zsdl3");
const theme = @import("theme.zig");
const runtime = @import("runtime.zig");
const sidebar = @import("sidebar.zig");
const workspace_panes = @import("workspace_panes.zig");
const native_state = @import("../state.zig");
const app_config = @import("../app/config.zig");
const keybinds = @import("../app/keybinds.zig");
const platform_runtime = @import("platform_runtime");
const Provider = native_state.Provider;
const AgentProvider = native_state.AgentTuiProvider;

const log = std.log.scoped(.native_ui_command_palette);

/// Hard cap on rendered rows per frame; results beyond this are reachable by
/// narrowing the query, matching how launcher UIs bound their lists.
const MAX_ROWS: usize = 64;
/// Scratch candidate pool scored before the top results are taken.
const MAX_CANDIDATES: usize = 512;
const ROW_H_CSS: f32 = 42.0;
const HEADER_H_CSS: f32 = 26.0;
const INPUT_H_CSS: f32 = 38.0;
const FOOTER_H_CSS: f32 = 30.0;
const PAD_CSS: f32 = 14.0;

const Section = enum { threads, panes, workspaces, app };

fn sectionName(section: Section) []const u8 {
    return switch (section) {
        .threads => "threads",
        .panes => "panes",
        .workspaces => "workspaces",
        .app => "app",
    };
}

/// One static palette entry. `keywords` are extra fuzzy-match terms beyond
/// the title; `keybind` selects which loaded accelerator to show as a hint.
const Command = struct {
    id: []const u8,
    title: []const u8,
    keywords: []const u8 = "",
    section: Section = .app,
    keybind: ?KeybindRef = null,
    enabled: *const fn (state: *runtime.AppState) bool = alwaysEnabled,
    run: *const fn (state: *runtime.AppState) void,
    /// History/scope commands re-target the palette instead of leaving it.
    keeps_open: bool = false,
};

/// Names the keybind-config slice used for a command's accelerator hint, so
/// hints stay correct when the user rebinds in verde.json.
const KeybindRef = enum {
    new_thread,
    chat_model_picker,
    chat_run_config,
    toggle_sidebar,
    toggle_browser,
    toggle_terminal,
    workspace_close,
    workspace_toggle_maximize,
    workspace_toggle_quick_pane,
    workspace_split_chat_vertical,
    workspace_split_chat_horizontal,
    workspace_split_terminal_vertical,
    workspace_split_terminal_horizontal,
    workspace_previous_pane,
    workspace_next_pane,
};

/// Static command table — add a row here to add a palette entry.
const STATIC_COMMANDS = [_]Command{
    .{ .id = "thread.new", .title = "New Chat", .keywords = "thread conversation start", .section = .threads, .keybind = .new_thread, .run = runNewChat, .enabled = hasProjects },
    .{ .id = "thread.choose_model", .title = "Choose Chat Model", .keywords = "provider initial picker", .section = .threads, .keybind = .chat_model_picker, .run = runChooseChatModel, .enabled = hasFocusedGuiChat },
    .{ .id = "thread.run_config", .title = "Configure Reasoning and Run Settings", .keywords = "effort speed access permissions", .section = .threads, .keybind = .chat_run_config, .run = runChatRunConfig, .enabled = hasFocusedGuiChat },
    .{ .id = "thread.rename_current", .title = "Rename Current Chat", .keywords = "thread title label", .section = .threads, .run = runRenameCurrentChat, .enabled = currentThreadCommitted },
    .{ .id = "thread.regenerate_title", .title = "Regenerate Chat Title", .keywords = "thread rename luna automatic", .section = .threads, .run = runRegenerateChatTitle, .enabled = canRegenerateChatTitle },
    .{ .id = "thread.sync_current", .title = "Sync Current Thread", .keywords = "refresh provider", .section = .threads, .run = runSyncCurrentThread, .enabled = canSyncCurrentThread },
    .{ .id = "thread.handoff_current", .title = "Handoff Current Chat or TUI", .keywords = "transfer provider model agent continue context", .section = .threads, .run = runHandoffCurrent, .enabled = canHandoffFocusedPane },
    .{ .id = "thread.open_current_codex_tui", .title = "Open Codex TUI for Current Thread", .keywords = "open codex tui current thread terminal resume active focused", .section = .threads, .run = runOpenCurrentThreadInTui, .enabled = canOpenFocusedCodexThreadInTui },
    .{ .id = "thread.open_current_tui", .title = "Open Current Thread in TUI", .keywords = "open agent tui current thread opencode claude cursor terminal resume active focused", .section = .threads, .run = runOpenCurrentThreadInTui, .enabled = canOpenFocusedNonCodexThreadInTui },
    .{ .id = "thread.archive_current", .title = "Archive Current Thread", .keywords = "delete remove chat", .section = .threads, .run = runArchiveCurrentThread, .enabled = currentThreadNotPending },
    .{ .id = "thread.import_codex", .title = "Import Codex Thread", .keywords = "resume session", .section = .threads, .run = runImportCodex, .enabled = hasProjects },
    .{ .id = "thread.import_opencode", .title = "Import OpenCode Thread", .keywords = "resume session", .section = .threads, .run = runImportOpencode, .enabled = hasProjects },
    .{ .id = "thread.import_claude", .title = "Import Claude Thread", .keywords = "resume session", .section = .threads, .run = runImportClaude, .enabled = hasProjects },
    .{ .id = "pane.split_chat_right", .title = "Split Chat Right", .keywords = "vsplit vertical pane", .section = .panes, .keybind = .workspace_split_chat_vertical, .run = runSplitChatRight, .enabled = hasProjects },
    .{ .id = "pane.split_chat_down", .title = "Split Chat Down", .keywords = "hsplit horizontal pane stacked", .section = .panes, .keybind = .workspace_split_chat_horizontal, .run = runSplitChatDown, .enabled = hasProjects },
    .{ .id = "pane.split_terminal_right", .title = "Split Terminal Right", .keywords = "vsplit vertical shell", .section = .panes, .keybind = .workspace_split_terminal_vertical, .run = runSplitTerminalRight, .enabled = hasProjects },
    .{ .id = "pane.split_terminal_down", .title = "Split Terminal Down", .keywords = "hsplit horizontal shell stacked", .section = .panes, .keybind = .workspace_split_terminal_horizontal, .run = runSplitTerminalDown, .enabled = hasProjects },
    .{ .id = "pane.terminal", .title = "Open Terminal Pane", .keywords = "shell console", .section = .panes, .keybind = .toggle_terminal, .run = runOpenTerminal, .enabled = hasProjects },
    .{ .id = "pane.browser", .title = "Toggle Browser Pane", .keywords = "web url", .section = .panes, .keybind = .toggle_browser, .run = runToggleBrowser, .enabled = hasProjects },
    .{ .id = "browser.tab.new", .title = "Browser: New Tab", .keywords = "web page create", .section = .panes, .run = runNewBrowserTab, .enabled = hasBrowserPane },
    .{ .id = "browser.tab.duplicate", .title = "Browser: Duplicate Active Tab", .keywords = "web page copy", .section = .panes, .run = runDuplicateBrowserTab, .enabled = hasBrowserTab },
    .{ .id = "browser.tab.pin", .title = "Browser: Pin or Unpin Active Tab", .keywords = "web page keep", .section = .panes, .run = runToggleBrowserTabPinned, .enabled = hasBrowserTab },
    .{ .id = "browser.tab.move_left", .title = "Browser: Move Active Tab Left", .keywords = "web page reorder", .section = .panes, .run = runMoveBrowserTabLeft, .enabled = canMoveBrowserTabLeft },
    .{ .id = "browser.tab.move_right", .title = "Browser: Move Active Tab Right", .keywords = "web page reorder", .section = .panes, .run = runMoveBrowserTabRight, .enabled = canMoveBrowserTabRight },
    .{ .id = "browser.tab.close", .title = "Browser: Close Active Tab", .keywords = "web page remove", .section = .panes, .run = runCloseBrowserTab, .enabled = hasBrowserTab },
    .{ .id = "pane.close", .title = "Close Pane", .section = .panes, .keybind = .workspace_close, .run = runClosePane, .enabled = hasProjects },
    .{ .id = "pane.zoom", .title = "Zoom Pane", .keywords = "maximize restore fullscreen", .section = .panes, .keybind = .workspace_toggle_maximize, .run = runZoomPane, .enabled = hasProjects },
    .{ .id = "pane.previous", .title = "Previous Pane", .keywords = "niri scroll focus left up back", .section = .panes, .keybind = .workspace_previous_pane, .run = runPreviousPane, .enabled = canFocusPreviousPane },
    .{ .id = "pane.next", .title = "Next Pane", .keywords = "niri scroll focus right down forward", .section = .panes, .keybind = .workspace_next_pane, .run = runNextPane, .enabled = canFocusNextPane },
    .{ .id = "pane.float", .title = "Float Focused Pane", .keywords = "quick scratch overlay", .section = .panes, .run = runFloatPane, .enabled = hasProjects },
    .{ .id = "pane.quick_toggle", .title = "New or Toggle Quick Terminal", .keywords = "create show hide scratch floating overlay", .section = .panes, .keybind = .workspace_toggle_quick_pane, .run = runToggleQuickPane, .enabled = hasProjects },
    .{ .id = "pane.quick_maximize", .title = "Maximize or Restore Quick Pane", .keywords = "floating overlay", .section = .panes, .run = runMaximizeQuickPane, .enabled = hasQuickPane },
    .{ .id = "pane.quick_minimize", .title = "Minimize Quick Pane", .keywords = "hide floating overlay", .section = .panes, .run = runMinimizeQuickPane, .enabled = hasQuickPane },
    .{ .id = "pane.quick_pin", .title = "Pin or Unpin Quick Pane", .keywords = "floating dim backdrop", .section = .panes, .run = runPinQuickPane, .enabled = hasQuickPane },
    .{ .id = "pane.quick_tile", .title = "Return Quick Pane to Tile", .keywords = "dock floating", .section = .panes, .run = runTileQuickPane, .enabled = hasQuickPane },
    .{ .id = "workspace.scrolling_use_global", .title = "Scrolling Layout: Use Global Default", .keywords = "niri panes mode inherit reset", .section = .workspaces, .run = runScrollingUseGlobal, .enabled = hasProjects },
    .{ .id = "workspace.scrolling_automatic", .title = "Scrolling Layout: Automatic", .keywords = "niri panes mode threshold tiled", .section = .workspaces, .run = runScrollingAutomatic, .enabled = hasProjects },
    .{ .id = "workspace.scrolling_always", .title = "Scrolling Layout: Always", .keywords = "niri panes mode pin enable", .section = .workspaces, .run = runScrollingAlways, .enabled = hasProjects },
    .{ .id = "workspace.scrolling_disabled", .title = "Scrolling Layout: Disabled", .keywords = "niri panes mode tiled off disable", .section = .workspaces, .run = runScrollingDisabled, .enabled = hasProjects },
    .{ .id = "workspace.scrolling_reset_column_width", .title = "Reset Scrolling Column Width", .keywords = "niri panes resize default per view", .section = .workspaces, .run = runResetScrollingColumnWidth, .enabled = hasCustomScrollingColumnWidth },
    .{ .id = "workspace.add", .title = "Add Workspace", .keywords = "new project folder directory", .section = .workspaces, .run = runAddWorkspace },
    .{ .id = "workspace.rename", .title = "Rename Workspace", .keywords = "label", .section = .workspaces, .run = runRenameWorkspace, .enabled = hasProjects },
    .{ .id = "workspace.close", .title = "Close Workspace", .keywords = "archive remove project save state", .section = .workspaces, .run = runCloseWorkspace, .enabled = workspaceNotBusy },
    .{ .id = "workspace.reopen", .title = "Reopen Last Closed Workspace", .keywords = "restore archived project", .section = .workspaces, .run = runReopenWorkspace, .enabled = hasClosedWorkspaces },
    .{ .id = "workspace.codex_tui", .title = "Start New Codex TUI", .keywords = "agent terminal workspace fresh openai", .section = .workspaces, .run = runOpenCodexTui, .enabled = hasProjects },
    .{ .id = "workspace.claude_tui", .title = "Start New Claude TUI", .keywords = "agent terminal workspace fresh anthropic claude code", .section = .workspaces, .run = runOpenClaudeTui, .enabled = hasProjects },
    .{ .id = "workspace.opencode_tui", .title = "Start New OpenCode TUI", .keywords = "agent terminal workspace fresh opencode", .section = .workspaces, .run = runOpenOpencodeTui, .enabled = hasProjects },
    .{ .id = "workspace.cursor_tui", .title = "Start New Cursor TUI", .keywords = "agent terminal workspace fresh cursor agent", .section = .workspaces, .run = runOpenCursorTui, .enabled = hasProjects },
    .{ .id = "workspace.grok_tui", .title = "Start New Grok TUI", .keywords = "agent terminal workspace fresh xai grok build", .section = .workspaces, .run = runOpenGrokTui, .enabled = hasProjectsAndGrok },
    .{ .id = "app.grok_setup", .title = "Set Up Grok Build", .keywords = "install xai agent provider tui", .section = .app, .run = runGrokSetup, .enabled = grokSetupNeeded },
    .{ .id = "workspace.amp_tui", .title = "Start New Amp TUI", .keywords = "agent terminal workspace fresh amp sourcegraph", .section = .workspaces, .run = runOpenAmpTui, .enabled = hasProjects },
    .{ .id = "workspace.herdr_handoff", .title = "Handoff Workspace to Herdr", .keywords = "runtime local terminal tui phone", .section = .workspaces, .run = runHerdrHandoffWorkspace, .enabled = hasProjects },
    .{ .id = "workspace.herdr_handoff_remote", .title = "Handoff Workspace to Remote Herdr", .keywords = "remote profile ssh tailscale runtime terminal tui phone", .section = .workspaces, .run = runHerdrRemoteHandoffWorkspace, .enabled = hasProjects },
    .{ .id = "workspace.herdr_focus_terminal", .title = "Open/Focus Herdr Terminal", .keywords = "runtime terminal tui", .section = .workspaces, .run = runFocusHerdrTerminal, .enabled = currentWorkspaceHerdrLinked },
    .{ .id = "workspace.herdr_unlink", .title = "Run Workspace Locally", .keywords = "unlink herdr runtime local", .section = .workspaces, .run = runUnlinkHerdrWorkspace, .enabled = currentWorkspaceHerdrLinked },
    .{ .id = "app.history", .title = "History: This Workspace", .keywords = "saved chats threads search recent", .section = .app, .run = runHistoryThisWorkspace, .enabled = hasProjects, .keeps_open = true },
    .{ .id = "app.settings", .title = "Open Settings", .keywords = "preferences config options", .section = .app, .run = runSettings },
    .{ .id = "app.sidebar", .title = "Toggle Sidebar", .keywords = "rail collapse", .section = .app, .keybind = .toggle_sidebar, .run = runToggleSidebar },
};

const ThreadRef = struct { project: usize, thread: usize };
const AgentTuiRef = struct { project: usize, dock: u32 };

const ResultRef = union(enum) {
    /// Non-selectable section label.
    header: []const u8,
    /// Index into `STATIC_COMMANDS`.
    command: usize,
    thread: ThreadRef,
    agent_tui: AgentTuiRef,
    /// Project index for a "Switch to <workspace>" row.
    workspace: usize,
    /// Archived-project index for a "Reopen <workspace>" row.
    closed_workspace: usize,
};

const Result = struct {
    ref: ResultRef,
    score: i32 = 0,
};

const Candidate = struct {
    ref: ResultRef,
    score: i32,
};

const HistoryEntry = struct {
    ref: ResultRef,
    at: i64,
};

/// Per-frame layout + results, rebuilt by `computeLayout` (called both from
/// the pre-event hit registration and the render pass, so hits and visuals
/// agree even when state changed between the two).
var results: [MAX_ROWS]Result = undefined;
var result_count: usize = 0;
var row_rects: [MAX_ROWS]palette.Rect = undefined;
var modal_rect: palette.Rect = .{};
var input_rect: palette.Rect = .{};
var list_rect: palette.Rect = .{};
var scroll_y: f32 = 0.0;
var max_scroll_y: f32 = 0.0;
var hovered_row: ?usize = null;
/// Query snapshot used to detect edits and reset selection/scroll.
var last_query: [256]u8 = undefined;
var last_query_len: usize = 0;
var last_scope: ?usize = null;

/// Action submenu geometry (Tab on a thread row).
const MAX_ACTIONS: usize = 6;
const ThreadAction = enum { open, open_split, open_tui, sync, handoff, archive };
var action_rects: [MAX_ACTIONS]palette.Rect = undefined;
var action_kinds: [MAX_ACTIONS]ThreadAction = undefined;
var action_labels: [MAX_ACTIONS][]const u8 = undefined;
var action_enabled: [MAX_ACTIONS]bool = undefined;
var action_count: usize = 0;
var action_menu_rect: palette.Rect = .{};

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

pub const StaticCommandInfo = struct {
    id: []const u8,
    title: []const u8,
    section: []const u8,
    enabled: bool,
};

pub const RunStaticCommandResult = enum {
    ran,
    not_found,
    disabled,
};

/// Returns the number of stable command-palette entries exposed to live IPC.
pub fn staticCommandCount() usize {
    return STATIC_COMMANDS.len;
}

/// Returns public metadata for one static command-palette entry.
pub fn staticCommandInfo(state: *runtime.AppState, index: usize) ?StaticCommandInfo {
    if (index >= STATIC_COMMANDS.len) return null;
    const command = STATIC_COMMANDS[index];
    return .{
        .id = command.id,
        .title = command.title,
        .section = sectionName(command.section),
        .enabled = command.enabled(state),
    };
}

/// Runs one static command-palette entry by stable id, mirroring UI activation.
pub fn runStaticCommandById(state: *runtime.AppState, id: []const u8) RunStaticCommandResult {
    const command_id = if (std.mem.eql(u8, id, "workspace.archive")) "workspace.close" else id;
    for (STATIC_COMMANDS) |command| {
        if (!std.mem.eql(u8, command.id, command_id)) continue;
        if (!command.enabled(state)) {
            state.setSidebarNotice(disabledNoticeForCommand(state, command.id));
            return .disabled;
        }
        if (!command.keeps_open) state.closeCommandPalette();
        command.run(state);
        state.markDirty();
        return .ran;
    }
    return .not_found;
}

/// Registers modal hit targets (scrim, input, rows, action submenu) for the
/// current frame. Mirrors the settings-modal pattern in `layout.zig`.
pub fn registerHits(
    state: *runtime.AppState,
    width: f32,
    height: f32,
    queueHit: *const fn (*runtime.AppState, palette.Rect, runtime.PaletteModalAction, usize) void,
) void {
    if (!state.command_controller.open) return;
    computeLayout(state, width, height);
    const scrim: palette.Rect = .{ .x = 0.0, .y = 0.0, .w = width, .h = height };
    queueHit(state, scrim, .modal_dismiss, 0);
    queueHit(state, modal_rect, .modal_block, 0);
    queueHit(state, input_rect, .command_palette_input, 0);
    var i: usize = 0;
    while (i < result_count) : (i += 1) {
        if (results[i].ref == .header) continue;
        if (!rowVisible(row_rects[i])) continue;
        queueHit(state, row_rects[i], .command_palette_row, i);
    }
    if (state.command_controller.action_menu_open) {
        var ai: usize = 0;
        while (ai < action_count) : (ai += 1) {
            queueHit(state, action_rects[ai], .command_palette_action_row, ai);
        }
    }
}

/// Updates the hovered result row from the retained modal hits.
pub fn updateHover(state: *runtime.AppState, x: f32, y: f32) void {
    if (!state.command_controller.open) {
        if (hovered_row != null) {
            hovered_row = null;
            state.markDirty();
        }
        return;
    }
    var new_hover: ?usize = null;
    var i = state.palette_modal_hits.items.len;
    while (i > 0) {
        i -= 1;
        const hit = state.palette_modal_hits.items[i];
        if (hit.action != .command_palette_row) continue;
        if (!rectContainsPoint(hit.rect, x, y)) continue;
        new_hover = hit.index;
        break;
    }
    if (hovered_row == new_hover) return;
    hovered_row = new_hover;
    state.markDirty();
}

/// Routes wheel input to the result list while the palette is open.
pub fn handleWheel(state: *runtime.AppState, width: f32, height: f32, x: f32, y: f32, wheel_y: f32) bool {
    if (!state.command_controller.open) return false;
    _ = width;
    _ = height;
    if (!rectContainsPoint(modal_rect, x, y)) return true; // swallow: scrim owns the screen
    scroll_y = theme.clampf(scroll_y - wheel_y * theme.scaledUi(48.0), 0.0, max_scroll_y);
    state.markDirty();
    return true;
}

/// Palette-owned keys: navigation, activation, scope toggle, dismissal.
/// Returns false for keys the shared modal text-editing path should handle
/// (cursor movement, clipboard, backspace, character input).
pub fn handleKeyDown(state: *runtime.AppState, event: *const sdl.KeyboardEvent) bool {
    if (!state.command_controller.open) return false;
    const primary = (keymodBits(event.mod) & (sdl.Keymod.ctrl | sdl.Keymod.gui)) != 0;
    switch (event.key) {
        .escape => {
            if (state.command_controller.action_menu_open) {
                state.command_controller.action_menu_open = false;
            } else {
                state.closeCommandPalette();
            }
            state.markDirty();
            return true;
        },
        .up => {
            if (state.command_controller.action_menu_open) {
                moveActionSelection(state, -1);
            } else {
                moveSelection(state, -1);
            }
            return true;
        },
        .down => {
            if (state.command_controller.action_menu_open) {
                moveActionSelection(state, 1);
            } else {
                moveSelection(state, 1);
            }
            return true;
        },
        .tab => {
            toggleActionMenu(state);
            return true;
        },
        .@"return", .kp_enter => {
            if (state.command_controller.action_menu_open) {
                runActionRow(state, state.command_controller.action_selected);
            } else {
                activateRow(state, state.command_controller.selected, primary);
            }
            return true;
        },
        .p => {
            // Ctrl+Shift+P while open: scoped → widen to global; global → toggle off.
            if (primary) {
                if (state.command_controller.scope_project != null) {
                    state.command_controller.scope_project = null;
                    state.command_controller.selected = 0;
                    scroll_y = 0.0;
                    state.markDirty();
                } else {
                    state.closeCommandPalette();
                }
                return true;
            }
            return false;
        },
        else => return false,
    }
}

/// Default activation for a result row (click or Enter). `split` is the
/// Ctrl+Enter "open in new pane" variant for thread rows.
pub fn activateRow(state: *runtime.AppState, row_index: usize, split: bool) void {
    if (row_index >= result_count) return;
    state.noteInteraction();
    switch (results[row_index].ref) {
        .header => {},
        .command => |ci| {
            const command = STATIC_COMMANDS[ci];
            if (!command.enabled(state)) {
                state.setSidebarNotice(disabledNoticeForCommand(state, command.id));
                return;
            }
            if (!command.keeps_open) state.closeCommandPalette();
            command.run(state);
            state.markDirty();
        },
        .thread => |tr| {
            state.closeCommandPalette();
            openThread(state, tr, split);
        },
        .agent_tui => |tui| {
            state.closeCommandPalette();
            openAgentTuiHistoryEntry(state, tui);
        },
        .workspace => |pi| {
            state.closeCommandPalette();
            if (pi < state.project_controller.projects.items.len) {
                state.project_controller.selected_index = pi;
                state.ensureCurrentProjectWorkspace();
                state.syncRenameBuffer();
                state.markDirty();
            }
        },
        .closed_workspace => |ai| {
            state.closeCommandPalette();
            _ = state.reopenClosedProjectAtIndex(ai);
        },
    }
}

/// Runs a row from the Tab action submenu against the selected thread.
pub fn runActionRow(state: *runtime.AppState, action_index: usize) void {
    if (action_index >= action_count) return;
    const selected = state.command_controller.selected;
    if (selected >= result_count) return;
    const tr = switch (results[selected].ref) {
        .thread => |t| t,
        else => return,
    };
    if (!action_enabled[action_index]) return;
    state.command_controller.action_menu_open = false;
    state.noteInteraction();
    switch (action_kinds[action_index]) {
        .open => {
            state.closeCommandPalette();
            openThread(state, tr, false);
        },
        .open_split => {
            state.closeCommandPalette();
            openThread(state, tr, true);
        },
        .open_tui => {
            state.closeCommandPalette();
            if (state.threadIsOpenInTui(tr.project, tr.thread)) {
                state.openThreadInChat(tr.project, tr.thread);
            } else {
                state.openThreadInTui(tr.project, tr.thread);
            }
        },
        .sync => {
            state.closeCommandPalette();
            state.syncThreadFromProvider(tr.project, tr.thread);
        },
        .handoff => {
            state.closeCommandPalette();
            openThread(state, tr, false);
            state.beginHandoffFromFocusedPane();
        },
        .archive => {
            state.archiveThreadAtIndex(tr.project, tr.thread);
            state.command_controller.selected = 0;
            state.markDirty();
        },
    }
}

/// Renders the palette overlay: scrim, chrome, search field, scope line,
/// result rows, optional action submenu, footer key hints, and scrollbar.
pub fn render(state: *runtime.AppState, width: f32, height: f32) void {
    if (!state.command_controller.open) return;
    computeLayout(state, width, height);

    // Scrim + modal chrome. The panel fill derives from the dark `background`
    // via a small lighten, NOT COLOR_PANEL_ALT: under omarchy themes panel_alt /
    // panel_muted are sourced from terminal color0/color8, which can be *light*
    // mid-grays. Using them as the body-text backdrop produced light-text-on-
    // light-panel and made the palette unreadable. Lightening the (always dark)
    // background keeps a subtle elevation while guaranteeing the text tokens land
    // on a dark surface, matching the contrast the rest of the UI gets on PANEL.
    // The scrim is a touch heavier (0.55) so background content reads as dimmed.
    queueRect(state, .{ .x = 0.0, .y = 0.0, .w = width, .h = height }, paletteColor(theme.scrim(0.55)));
    queueRoundedRect(state, modal_rect, paletteColor(theme.lighten(theme.background(), 0.04)), theme.scaledUi(16.0));
    queueBorder(state, modal_rect, paletteColor(theme.COLOR_PANEL_MUTED), theme.scaledUi(16.0), theme.scaledUi(1.0));

    renderSearchField(state);
    renderScopeLine(state);
    renderRows(state);
    renderFooter(state);
    if (state.command_controller.action_menu_open) renderActionMenu(state);

    // Scrollbar on the list region when results overflow.
    if (max_scroll_y > 1.0 and list_rect.h > theme.scaledUi(32.0)) {
        const track: palette.Rect = .{
            .x = modal_rect.x + modal_rect.w - theme.scaledUi(8.0),
            .y = list_rect.y + theme.scaledUi(2.0),
            .w = theme.scaledUi(3.0),
            .h = list_rect.h - theme.scaledUi(4.0),
        };
        const thumb_h = @max(theme.scaledUi(28.0), track.h * (track.h / (track.h + max_scroll_y)));
        const thumb_y = track.y + (track.h - thumb_h) * (scroll_y / max_scroll_y);
        queueRoundedRect(state, track, paletteColor(theme.withAlpha(theme.COLOR_PANEL_MUTED, 120)), theme.scaledUi(2.0));
        queueRoundedRect(state, .{ .x = track.x, .y = thumb_y, .w = track.w, .h = thumb_h }, paletteColor(theme.withAlpha(theme.COLOR_TEXT_MUTED, 200)), theme.scaledUi(2.0));
    }
}

// ---------------------------------------------------------------------------
// Layout + result building
// ---------------------------------------------------------------------------

/// Recomputes the modal geometry and result rows for the current state. Pure
/// function of state + window size; cheap enough to run twice per frame.
fn computeLayout(state: *runtime.AppState, width: f32, height: f32) void {
    const modal_w = theme.clampf(width * 0.46, theme.scaledUi(480.0), theme.scaledUi(720.0));
    const modal_h = theme.clampf(height * 0.62, theme.scaledUi(340.0), theme.scaledUi(640.0));
    // Anchored in the upper third like launcher UIs, so results grow downward
    // and the eye line stays stable while typing.
    const modal_y = @max(height * 0.14, theme.scaledUi(24.0));
    modal_rect = .{ .x = (width - modal_w) * 0.5, .y = modal_y, .w = modal_w, .h = modal_h };

    const pad = theme.scaledUi(PAD_CSS);
    input_rect = .{
        .x = modal_rect.x + pad,
        .y = modal_rect.y + pad,
        .w = modal_rect.w - pad * 2.0,
        .h = theme.scaledUi(INPUT_H_CSS),
    };
    const scope_h = theme.scaledUi(22.0);
    const list_top = input_rect.y + input_rect.h + scope_h + theme.scaledUi(4.0);
    const footer_h = theme.scaledUi(FOOTER_H_CSS);
    list_rect = .{
        .x = modal_rect.x + pad,
        .y = list_top,
        .w = modal_rect.w - pad * 2.0,
        .h = @max(modal_rect.y + modal_rect.h - footer_h - list_top, 0.0),
    };

    rebuildResults(state);

    // Row geometry: headers are shorter than selectable rows.
    var y = list_rect.y - scroll_y;
    var i: usize = 0;
    while (i < result_count) : (i += 1) {
        const h = if (results[i].ref == .header) theme.scaledUi(HEADER_H_CSS) else theme.scaledUi(ROW_H_CSS);
        row_rects[i] = .{ .x = list_rect.x, .y = y, .w = list_rect.w, .h = h };
        y += h;
    }
    const content_h = y + scroll_y - list_rect.y;
    max_scroll_y = @max(content_h - list_rect.h, 0.0);
    scroll_y = theme.clampf(scroll_y, 0.0, max_scroll_y);

    ensureSelectedVisible(state);

    // Re-derive row rects after any scroll adjustment so hits match visuals.
    y = list_rect.y - scroll_y;
    i = 0;
    while (i < result_count) : (i += 1) {
        const h = if (results[i].ref == .header) theme.scaledUi(HEADER_H_CSS) else theme.scaledUi(ROW_H_CSS);
        row_rects[i] = .{ .x = list_rect.x, .y = y, .w = list_rect.w, .h = h };
        y += h;
    }

    computeActionMenuLayout(state);
}

/// Builds the result list for the current query + scope, resetting selection
/// when either changed since the last frame.
fn rebuildResults(state: *runtime.AppState) void {
    const query = state.commandPaletteQuery();
    const query_changed = query.len != last_query_len or
        !std.mem.eql(u8, last_query[0..last_query_len], query) or
        !scopeEq(last_scope, state.command_controller.scope_project);
    if (query_changed) {
        const n = @min(query.len, last_query.len);
        @memcpy(last_query[0..n], query[0..n]);
        last_query_len = n;
        last_scope = state.command_controller.scope_project;
        state.command_controller.selected = 0;
        state.command_controller.action_menu_open = false;
        scroll_y = 0.0;
    }

    result_count = 0;
    if (state.command_controller.scope_project) |pi| {
        buildScopedHistory(state, pi, query);
    } else if (query.len == 0) {
        buildSuggestions(state);
    } else {
        buildRanked(state, query);
    }
    clampSelection(state);
}

/// Empty-query global view: recent threads, then the command table, then
/// workspace switching — the palette's "home screen".
fn buildSuggestions(state: *runtime.AppState) void {
    var recent: [8]struct { ref: ThreadRef, at: i64 } = undefined;
    var recent_count: usize = 0;
    for (state.project_controller.projects.items, 0..) |*project, pi| {
        for (project.threads.items, 0..) |*thread, ti| {
            if (!thread.committed or thread.archived) continue;
            const at = thread.last_activity_at;
            // Insertion sort into the small recency buffer.
            var pos = recent_count;
            while (pos > 0 and recent[pos - 1].at < at) : (pos -= 1) {}
            if (pos >= recent.len) continue;
            const tail = @min(recent_count, recent.len - 1);
            var j = tail;
            while (j > pos) : (j -= 1) recent[j] = recent[j - 1];
            recent[pos] = .{ .ref = .{ .project = pi, .thread = ti }, .at = at };
            if (recent_count < recent.len) recent_count += 1;
        }
    }
    if (recent_count > 0) {
        appendResult(.{ .header = "RECENT CHATS" });
        for (recent[0..recent_count]) |entry| appendResult(.{ .thread = entry.ref });
    }
    appendResult(.{ .header = "COMMANDS" });
    for (STATIC_COMMANDS, 0..) |command, ci| {
        if (!command.enabled(state)) continue;
        appendResult(.{ .command = ci });
    }
    if (state.project_controller.projects.items.len > 1) {
        appendResult(.{ .header = "WORKSPACES" });
        for (state.project_controller.projects.items, 0..) |_, pi| {
            if (pi == state.project_controller.selected_index) continue;
            appendResult(.{ .workspace = pi });
        }
    }
    if (state.project_controller.archived_projects.items.len > 0) {
        appendResult(.{ .header = "CLOSED WORKSPACES" });
        var remaining = state.project_controller.archived_projects.items.len;
        while (remaining > 0) {
            remaining -= 1;
            appendResult(.{ .closed_workspace = remaining });
        }
    }
}

/// Sidebar "History" scope: one workspace's agent TUIs and committed threads,
/// recency bucketed when browsing and filtered when searching.
fn buildScopedHistory(state: *runtime.AppState, project_index: usize, query: []const u8) void {
    if (project_index >= state.project_controller.projects.items.len) return;
    const project = &state.project_controller.projects.items[project_index];
    var entries: [MAX_CANDIDATES]HistoryEntry = undefined;
    var entry_count: usize = 0;

    const dock_count = project.terminal_docks.items.len + 1;
    for (0..dock_count) |dock_index| {
        const dock_id: u32 = if (dock_index == 0) 0 else project.terminal_docks.items[dock_index - 1].id;
        const activity_at_ms = state.workspaceAgentTuiHistoryAt(project_index, dock_id);
        if (activity_at_ms == 0) continue;
        const provider = state.workspaceAgentTuiProvider(project_index, dock_id) orelse continue;
        if (query.len > 0 and !matchAgentTui(state, project_index, dock_id, provider, query)) continue;
        if (entry_count >= entries.len) break;
        entries[entry_count] = .{
            .ref = .{ .agent_tui = .{ .project = project_index, .dock = dock_id } },
            .at = @divTrunc(activity_at_ms, std.time.ms_per_s),
        };
        entry_count += 1;
    }

    const sorted = project.sortedCommittedThreadIndices(state.allocator);
    for (sorted) |ti| {
        if (ti >= project.threads.items.len or entry_count >= entries.len) continue;
        const thread = &project.threads.items[ti];
        if (query.len > 0 and matchThread(thread, query) == null) continue;
        entries[entry_count] = .{
            .ref = .{ .thread = .{ .project = project_index, .thread = ti } },
            .at = thread.last_activity_at,
        };
        entry_count += 1;
    }

    std.sort.pdq(HistoryEntry, entries[0..entry_count], {}, historyEntryLessThan);
    const now = unixTimestampSeconds();
    var bucket: usize = 0; // 0 = none emitted, 1 = today, 2 = week, 3 = older
    for (entries[0..entry_count]) |entry| {
        if (query.len == 0) {
            const age = now - entry.at;
            const next_bucket: usize = if (age < 60 * 60 * 24) 1 else if (age < 60 * 60 * 24 * 7) 2 else 3;
            if (next_bucket > bucket) {
                bucket = next_bucket;
                appendResult(.{ .header = switch (next_bucket) {
                    1 => "TODAY",
                    2 => "THIS WEEK",
                    else => "OLDER",
                } });
            }
        }
        appendResult(entry.ref);
        if (result_count >= MAX_ROWS) break;
    }
}

fn historyEntryLessThan(_: void, a: HistoryEntry, b: HistoryEntry) bool {
    return a.at > b.at;
}

/// Query view: every source scored into one ranked list.
fn buildRanked(state: *runtime.AppState, query: []const u8) void {
    var candidates: [MAX_CANDIDATES]Candidate = undefined;
    var candidate_count: usize = 0;

    for (STATIC_COMMANDS, 0..) |command, ci| {
        if (!command.enabled(state)) continue;
        const title_score = fuzzyScore(command.title, query);
        const keyword_score = fuzzyScore(command.keywords, query);
        const best = maxOptional(title_score, if (keyword_score) |s| s - 100 else null);
        if (best) |score| {
            appendCandidate(&candidates, &candidate_count, .{ .ref = .{ .command = ci }, .score = score + 50 });
        }
    }
    const now = unixTimestampSeconds();
    for (state.project_controller.projects.items, 0..) |*project, pi| {
        const label_score = fuzzyScore(project.label, query);
        if (label_score) |score| {
            if (pi != state.project_controller.selected_index) {
                appendCandidate(&candidates, &candidate_count, .{ .ref = .{ .workspace = pi }, .score = score + 25 });
            }
        }
        for (project.threads.items, 0..) |*thread, ti| {
            if (!thread.committed or thread.archived) continue;
            if (matchThread(thread, query)) |score| {
                // Mild recency boost keeps fresh threads above stale equal
                // matches without letting recency beat match quality.
                const age_days: i32 = @intCast(@min(@divTrunc(@max(now - thread.last_activity_at, 0), 60 * 60 * 24), 30));
                appendCandidate(&candidates, &candidate_count, .{
                    .ref = .{ .thread = .{ .project = pi, .thread = ti } },
                    .score = score + (30 - age_days),
                });
            }
        }
        const dock_count = project.terminal_docks.items.len + 1;
        for (0..dock_count) |dock_index| {
            const dock_id: u32 = if (dock_index == 0) 0 else project.terminal_docks.items[dock_index - 1].id;
            if (state.workspaceAgentTuiHistoryAt(pi, dock_id) == 0) continue;
            const provider = state.workspaceAgentTuiProvider(pi, dock_id) orelse continue;
            if (!matchAgentTui(state, pi, dock_id, provider, query)) continue;
            appendCandidate(&candidates, &candidate_count, .{
                .ref = .{ .agent_tui = .{ .project = pi, .dock = dock_id } },
                .score = fuzzyScore(agentTuiSearchLabel(provider), query) orelse 200,
            });
        }
    }
    for (state.project_controller.archived_projects.items, 0..) |*project, ai| {
        const label_score = fuzzyScore(project.label, query);
        const path_score = fuzzyScore(project.path, query);
        const action_score = maxOptional(
            fuzzyScore("reopen workspace", query),
            fuzzyScore("closed workspace", query),
        );
        const best = maxOptional(
            maxOptional(label_score, if (path_score) |s| s - 50 else null),
            if (action_score) |s| s - @as(i32, @intCast(@min(ai, 40))) else null,
        );
        if (best) |score| {
            appendCandidate(&candidates, &candidate_count, .{ .ref = .{ .closed_workspace = ai }, .score = score + 20 });
        }
    }

    std.sort.pdq(Candidate, candidates[0..candidate_count], {}, candidateLessThan);
    for (candidates[0..@min(candidate_count, MAX_ROWS)]) |candidate| {
        appendResult(candidate.ref);
    }
}

fn candidateLessThan(_: void, a: Candidate, b: Candidate) bool {
    return a.score > b.score;
}

fn appendCandidate(buf: *[MAX_CANDIDATES]Candidate, count: *usize, candidate: Candidate) void {
    if (count.* >= buf.len) return;
    buf[count.*] = candidate;
    count.* += 1;
}

fn appendResult(ref: ResultRef) void {
    if (result_count >= MAX_ROWS) return;
    results[result_count] = .{ .ref = ref };
    result_count += 1;
}

/// Scores a thread against the query: title fuzzy match first, then message
/// bodies (substring only, query >= 3 chars, capped scan) as a weaker hit.
fn matchThread(thread: anytype, query: []const u8) ?i32 {
    if (fuzzyScore(thread.title, query)) |score| return score;
    if (query.len < 3) return null;
    // Body scan budget: enough to cover long threads without making each
    // keystroke scan megabytes across every workspace.
    var budget: usize = 64 * 1024;
    for (thread.messages.items) |*message| {
        const body = message.body[0..@min(message.body.len, budget)];
        if (asciiIndexOfIgnoreCase(body, query) != null) return 200;
        if (budget <= body.len) break;
        budget -= body.len;
    }
    return null;
}

fn matchAgentTui(state: *runtime.AppState, project_index: usize, dock_id: u32, provider: AgentProvider, query: []const u8) bool {
    if (fuzzyScore(agentTuiSearchLabel(provider), query) != null) return true;
    var title_buf: [96]u8 = undefined;
    const dock = state.projectTerminalDock(project_index, dock_id) orelse return false;
    return fuzzyScore(dock.activeProcessLabel(&title_buf), query) != null;
}

fn agentTuiSearchLabel(provider: AgentProvider) []const u8 {
    return switch (provider) {
        .codex => "Codex TUI",
        .claude => "Claude TUI",
        .opencode => "OpenCode TUI",
        .cursor => "Cursor TUI",
        .grok => "Grok TUI",
        .amp => "Amp TUI",
        .other => "Agent TUI",
    };
}

/// Case-insensitive scoring: exact substring ranks far above subsequence
/// matches; both prefer earlier/tighter hits. Returns null on no match.
fn fuzzyScore(haystack: []const u8, needle: []const u8) ?i32 {
    if (needle.len == 0 or haystack.len == 0) return null;
    if (asciiIndexOfIgnoreCase(haystack, needle)) |pos| {
        return 1000 - @as(i32, @intCast(@min(pos, 400)));
    }
    // Subsequence walk: every needle byte must appear in order; gaps cost.
    var hi: usize = 0;
    var gaps: i32 = 0;
    var last_hit: usize = 0;
    for (needle) |nb| {
        const nl = std.ascii.toLower(nb);
        var found = false;
        while (hi < haystack.len) : (hi += 1) {
            if (std.ascii.toLower(haystack[hi]) == nl) {
                if (last_hit != 0) gaps += @intCast(@min(hi - last_hit, 20));
                last_hit = hi + 1;
                hi += 1;
                found = true;
                break;
            }
        }
        if (!found) return null;
    }
    return 500 - gaps;
}

fn asciiIndexOfIgnoreCase(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0 or haystack.len < needle.len) return null;
    var i: usize = 0;
    const end = haystack.len - needle.len;
    outer: while (i <= end) : (i += 1) {
        for (needle, 0..) |nb, j| {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(nb)) continue :outer;
        }
        return i;
    }
    return null;
}

/// Wall-clock seconds; `std.time.timestamp` was removed in the Zig 0.16 std
/// reorganization, so this mirrors `state.zig`'s libc-based helper.
fn unixTimestampSeconds() i64 {
    return @divTrunc(platform_runtime.unixTimestampMs(), std.time.ms_per_s);
}

fn maxOptional(a: ?i32, b: ?i32) ?i32 {
    if (a == null) return b;
    if (b == null) return a;
    return @max(a.?, b.?);
}

fn scopeEq(a: ?usize, b: ?usize) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return a.? == b.?;
}

// ---------------------------------------------------------------------------
// Selection + action submenu
// ---------------------------------------------------------------------------

fn isSelectable(index: usize) bool {
    return index < result_count and results[index].ref != .header;
}

fn firstSelectable() ?usize {
    var i: usize = 0;
    while (i < result_count) : (i += 1) {
        if (isSelectable(i)) return i;
    }
    return null;
}

fn clampSelection(state: *runtime.AppState) void {
    if (isSelectable(state.command_controller.selected)) return;
    state.command_controller.selected = firstSelectable() orelse 0;
}

/// Moves the selected row by `delta`, skipping section headers.
fn moveSelection(state: *runtime.AppState, delta: i32) void {
    if (result_count == 0) return;
    var index: i64 = @intCast(state.command_controller.selected);
    const count: i64 = @intCast(result_count);
    var remaining: usize = result_count;
    while (remaining > 0) : (remaining -= 1) {
        index += delta;
        if (index < 0) index = count - 1;
        if (index >= count) index = 0;
        if (isSelectable(@intCast(index))) {
            state.command_controller.selected = @intCast(index);
            state.command_controller.action_menu_open = false;
            state.markDirty();
            return;
        }
    }
}

fn moveActionSelection(state: *runtime.AppState, delta: i32) void {
    if (action_count == 0) return;
    var index: i64 = @intCast(state.command_controller.action_selected);
    const count: i64 = @intCast(action_count);
    index += delta;
    if (index < 0) index = count - 1;
    if (index >= count) index = 0;
    state.command_controller.action_selected = @intCast(index);
    state.markDirty();
}

/// Tab on a thread row opens the secondary action submenu; non-thread rows
/// have a single behavior so Tab is a no-op for them.
fn toggleActionMenu(state: *runtime.AppState) void {
    if (state.command_controller.action_menu_open) {
        state.command_controller.action_menu_open = false;
        state.markDirty();
        return;
    }
    const selected = state.command_controller.selected;
    if (selected >= result_count) return;
    if (results[selected].ref != .thread) return;
    state.command_controller.action_menu_open = true;
    state.command_controller.action_selected = 0;
    state.markDirty();
}

/// Rebuilds the action submenu rows + geometry for the selected thread row.
fn computeActionMenuLayout(state: *runtime.AppState) void {
    action_count = 0;
    if (!state.command_controller.action_menu_open) return;
    const selected = state.command_controller.selected;
    if (selected >= result_count) {
        state.command_controller.action_menu_open = false;
        return;
    }
    const tr = switch (results[selected].ref) {
        .thread => |t| t,
        else => {
            state.command_controller.action_menu_open = false;
            return;
        },
    };
    if (tr.project >= state.project_controller.projects.items.len) return;
    const project = &state.project_controller.projects.items[tr.project];
    if (tr.thread >= project.threads.items.len) return;
    const thread = &project.threads.items[tr.thread];
    const pending = thread.isSendPendingForUi();
    const can_sync = thread.provider_thread_id != null and !pending;
    const in_tui = state.threadIsOpenInTui(tr.project, tr.thread);

    appendAction(.open, "Open", true);
    appendAction(.open_split, "Open in New Pane", true);
    appendAction(.open_tui, if (in_tui) "Open as Chat" else "Open in TUI", in_tui or can_sync);
    appendAction(.sync, "Sync Thread", can_sync);
    appendAction(.handoff, "Handoff to Another Agent", !pending);
    appendAction(.archive, "Archive Thread", !pending);

    const row_h = theme.scaledUi(32.0);
    const menu_w = theme.scaledUi(220.0);
    const menu_pad = theme.scaledUi(6.0);
    const menu_h = menu_pad * 2.0 + row_h * @as(f32, @floatFromInt(action_count));
    const anchor = row_rects[selected];
    var menu_x = anchor.x + anchor.w - menu_w - theme.scaledUi(8.0);
    var menu_y = anchor.y + anchor.h - theme.scaledUi(2.0);
    menu_x = theme.clampf(menu_x, modal_rect.x + theme.scaledUi(8.0), modal_rect.x + modal_rect.w - menu_w - theme.scaledUi(8.0));
    if (menu_y + menu_h > modal_rect.y + modal_rect.h) menu_y = anchor.y - menu_h + theme.scaledUi(2.0);
    action_menu_rect = .{ .x = menu_x, .y = menu_y, .w = menu_w, .h = menu_h };
    var i: usize = 0;
    while (i < action_count) : (i += 1) {
        action_rects[i] = .{
            .x = menu_x + theme.scaledUi(4.0),
            .y = menu_y + menu_pad + row_h * @as(f32, @floatFromInt(i)),
            .w = menu_w - theme.scaledUi(8.0),
            .h = row_h,
        };
    }
}

fn appendAction(kind: ThreadAction, label: []const u8, enabled: bool) void {
    if (action_count >= MAX_ACTIONS) return;
    action_kinds[action_count] = kind;
    action_labels[action_count] = label;
    action_enabled[action_count] = enabled;
    action_count += 1;
}

/// Keeps the keyboard selection inside the list viewport by nudging scroll.
fn ensureSelectedVisible(state: *runtime.AppState) void {
    const selected = state.command_controller.selected;
    if (selected >= result_count) return;
    const row = row_rects[selected];
    const top = list_rect.y;
    const bottom = list_rect.y + list_rect.h;
    if (row.y < top) {
        scroll_y = @max(scroll_y - (top - row.y), 0.0);
    } else if (row.y + row.h > bottom) {
        scroll_y = @min(scroll_y + (row.y + row.h - bottom), max_scroll_y);
    }
}

// ---------------------------------------------------------------------------
// Thread helpers
// ---------------------------------------------------------------------------

/// Pane id of the chat pane currently showing `thread_index`, if any.
fn threadOpenPaneId(project: *const native_state.Project, thread_index: usize) ?runtime.WorkspacePaneId {
    for (project.workspace_layout.panes.items) |*pane| {
        switch (pane.ref) {
            .chat => |ref| if (ref.thread_index == thread_index) return pane.id,
            else => {},
        }
    }
    return null;
}

/// Enter semantics for a thread result: focus its pane when already open,
/// otherwise reuse a visible chat pane (replace). `split` forces a new pane.
fn openThread(state: *runtime.AppState, tr: ThreadRef, split: bool) void {
    if (tr.project >= state.project_controller.projects.items.len) return;
    if (split) {
        state.openThreadInWorkspaceSplit(tr.project, tr.thread);
        return;
    }
    const project = &state.project_controller.projects.items[tr.project];
    if (threadOpenPaneId(project, tr.thread)) |pane_id| {
        state.focusWorkspaceOpenPane(tr.project, pane_id);
        state.markDirty();
        return;
    }
    state.selectThreadForProject(tr.project, tr.thread);
}

fn openAgentTuiHistoryEntry(state: *runtime.AppState, tui: AgentTuiRef) void {
    _ = state.openWorkspaceAgentTuiHistory(tui.project, tui.dock);
}

// ---------------------------------------------------------------------------
// Command run/enabled fns (thin wrappers over AppState)
// ---------------------------------------------------------------------------

fn alwaysEnabled(_: *runtime.AppState) bool {
    return true;
}

fn hasProjects(state: *runtime.AppState) bool {
    return state.project_controller.projects.items.len > 0;
}

fn hasCustomScrollingColumnWidth(state: *runtime.AppState) bool {
    if (state.project_controller.selected_index >= state.project_controller.projects.items.len) return false;
    return state.project_controller.projects.items[state.project_controller.selected_index].workspace_layout.scroll_pane_extent_override != null;
}

fn adjacentPaneForCommand(state: *runtime.AppState, previous: bool) ?runtime.WorkspacePaneId {
    if (state.project_controller.selected_index >= state.project_controller.projects.items.len) return null;
    const layout = &state.project_controller.projects.items[state.project_controller.selected_index].workspace_layout;
    const focused_pane_id = layout.focused_pane_id orelse return null;
    return layout.adjacentTiledPaneIdInSidebarOrder(
        focused_pane_id,
        paneTraversalDirection(state.app_config.workspace_scroll_direction, previous),
    );
}

fn canFocusPreviousPane(state: *runtime.AppState) bool {
    return adjacentPaneForCommand(state, true) != null;
}

fn canFocusNextPane(state: *runtime.AppState) bool {
    return adjacentPaneForCommand(state, false) != null;
}

fn hasProjectsAndGrok(state: *runtime.AppState) bool {
    return hasProjects(state) and native_state.AppState.grokTuiInstalled();
}

fn grokSetupNeeded(_: *runtime.AppState) bool {
    return !native_state.AppState.grokTuiInstalled();
}

fn hasQuickPane(state: *runtime.AppState) bool {
    return state.currentProjectQuickPane() != null;
}

fn hasFocusedGuiChat(state: *runtime.AppState) bool {
    return focusedGuiThreadIndex(state) != null;
}

fn workspaceNotBusy(state: *runtime.AppState) bool {
    if (state.project_controller.selected_index >= state.project_controller.projects.items.len) return false;
    for (state.project_controller.projects.items[state.project_controller.selected_index].threads.items) |*thread| {
        if (thread.isSendPendingForUi()) return false;
    }
    return true;
}

fn hasClosedWorkspaces(state: *runtime.AppState) bool {
    return state.project_controller.archived_projects.items.len > 0;
}

fn hasBrowserPane(state: *runtime.AppState) bool {
    return state.currentProjectVisibleBrowserPaneId() != null;
}

fn hasBrowserTab(state: *runtime.AppState) bool {
    return hasBrowserPane(state) and state.browserTabCount() > 0;
}

fn canMoveBrowserTabLeft(state: *runtime.AppState) bool {
    return hasBrowserTab(state) and state.activeBrowserTabIndex() > 0;
}

fn canMoveBrowserTabRight(state: *runtime.AppState) bool {
    return hasBrowserTab(state) and state.activeBrowserTabIndex() + 1 < state.browserTabCount();
}

fn currentWorkspaceHerdrLinked(state: *runtime.AppState) bool {
    return state.project_controller.selected_index < state.project_controller.projects.items.len and
        state.project_controller.projects.items[state.project_controller.selected_index].herdr_link != null;
}

fn currentWorkspaceHasHerdrAttachTerminal(state: *runtime.AppState) bool {
    if (!currentWorkspaceHerdrLinked(state)) return false;
    const link = state.project_controller.projects.items[state.project_controller.selected_index].herdr_link.?;
    return link.attach_dock_id != null;
}

fn currentThreadNotPending(state: *runtime.AppState) bool {
    if (state.project_controller.selected_index >= state.project_controller.projects.items.len) return false;
    const project = &state.project_controller.projects.items[state.project_controller.selected_index];
    if (project.selected_thread_index >= project.threads.items.len) return false;
    const thread = &project.threads.items[project.selected_thread_index];
    return thread.committed and !thread.isSendPendingForUi();
}

fn currentThreadCommitted(state: *runtime.AppState) bool {
    if (state.project_controller.selected_index >= state.project_controller.projects.items.len) return false;
    const project = &state.project_controller.projects.items[state.project_controller.selected_index];
    if (project.selected_thread_index >= project.threads.items.len) return false;
    return project.threads.items[project.selected_thread_index].committed;
}

fn canRegenerateChatTitle(state: *runtime.AppState) bool {
    return state.canRegenerateCurrentThreadTitle();
}

fn canSyncCurrentThread(state: *runtime.AppState) bool {
    if (state.project_controller.selected_index >= state.project_controller.projects.items.len) return false;
    const thread_index = focusedGuiThreadIndex(state) orelse return false;
    const project = &state.project_controller.projects.items[state.project_controller.selected_index];
    if (thread_index >= project.threads.items.len) return false;
    const thread = &project.threads.items[thread_index];
    return thread.provider_thread_id != null and !thread.isSendPendingForUi();
}

fn canOpenFocusedThreadInTui(state: *runtime.AppState) bool {
    if (state.project_controller.selected_index >= state.project_controller.projects.items.len) return false;
    const thread_index = focusedGuiThreadIndex(state) orelse return false;
    const project = &state.project_controller.projects.items[state.project_controller.selected_index];
    if (thread_index >= project.threads.items.len) return false;
    const thread = &project.threads.items[thread_index];
    return thread.provider_thread_id != null;
}

fn canOpenFocusedCodexThreadInTui(state: *runtime.AppState) bool {
    return canOpenFocusedThreadInTui(state) and focusedGuiThreadProvider(state) == .codex;
}

fn canOpenFocusedNonCodexThreadInTui(state: *runtime.AppState) bool {
    const provider = focusedGuiThreadProvider(state) orelse return false;
    return provider != .codex and canOpenFocusedThreadInTui(state);
}

fn canHandoffFocusedPane(state: *runtime.AppState) bool {
    if (state.project_controller.selected_index >= state.project_controller.projects.items.len) return false;
    const project = &state.project_controller.projects.items[state.project_controller.selected_index];
    const pane_id = project.workspace_layout.focused_pane_id orelse return false;
    return switch (state.workspacePaneKindById(pane_id) orelse return false) {
        .chat => blk: {
            const thread_index = state.workspaceChatThreadIndexByPane(pane_id) orelse break :blk false;
            break :blk thread_index < project.threads.items.len and !project.threads.items[thread_index].isSendPendingForUi();
        },
        .terminal => blk: {
            const dock_id = state.workspaceTerminalDockIdByPane(pane_id) orelse break :blk false;
            break :blk state.projectTerminalSurface(state.project_controller.selected_index, dock_id) != null;
        },
        .browser => false,
    };
}

fn disabledNoticeForCommand(state: *runtime.AppState, id: []const u8) []const u8 {
    if (std.mem.eql(u8, id, "thread.open_current_codex_tui") or std.mem.eql(u8, id, "thread.open_current_tui")) {
        const thread_index = focusedGuiThreadIndex(state) orelse return "Focus a GUI chat pane before opening a thread in TUI.";
        if (state.project_controller.selected_index >= state.project_controller.projects.items.len) return "No workspace selected.";
        const project = &state.project_controller.projects.items[state.project_controller.selected_index];
        if (thread_index >= project.threads.items.len) return "Focused chat thread is unavailable.";
        const thread = &project.threads.items[thread_index];
        if (thread.provider_thread_id == null) return "Thread has no provider session id yet.";
    }
    if (std.mem.eql(u8, id, "workspace.reopen")) return "No closed workspaces to reopen.";
    if (std.mem.eql(u8, id, "workspace.grok_tui")) return "Grok Build is not installed. Run “Set Up Grok Build” first.";
    if (std.mem.eql(u8, id, "app.grok_setup")) return "Grok Build is already installed.";
    if (std.mem.eql(u8, id, "workspace.herdr_focus_terminal")) return "Current workspace is not linked to Herdr.";
    if (std.mem.eql(u8, id, "workspace.herdr_unlink")) return "Current workspace is already running locally.";
    return "Command is unavailable right now.";
}

fn focusedGuiThreadIndex(state: *runtime.AppState) ?usize {
    const pane_id = state.focusedWorkspaceChatPaneId() orelse return null;
    return state.workspaceChatThreadIndexByPane(pane_id);
}

fn focusedGuiThreadProvider(state: *runtime.AppState) ?Provider {
    if (state.project_controller.selected_index >= state.project_controller.projects.items.len) return null;
    const thread_index = focusedGuiThreadIndex(state) orelse return null;
    const project = &state.project_controller.projects.items[state.project_controller.selected_index];
    if (thread_index >= project.threads.items.len) return null;
    return project.threads.items[thread_index].provider;
}

fn runNewChat(state: *runtime.AppState) void {
    if (state.project_controller.projects.items.len == 0) return;
    state.createThreadForProject(@min(state.project_controller.selected_index, state.project_controller.projects.items.len - 1));
}

fn runChooseChatModel(state: *runtime.AppState) void {
    state.openPaletteModelPicker();
}

fn runChatRunConfig(state: *runtime.AppState) void {
    state.openRunConfigPopover();
}

fn runSyncCurrentThread(state: *runtime.AppState) void {
    const thread_index = focusedGuiThreadIndex(state) orelse return;
    state.syncThreadFromProvider(state.project_controller.selected_index, thread_index);
}

fn runHandoffCurrent(state: *runtime.AppState) void {
    state.beginHandoffFromFocusedPane();
}

fn runOpenCurrentThreadInTui(state: *runtime.AppState) void {
    const thread_index = focusedGuiThreadIndex(state) orelse return;
    state.openThreadInTui(state.project_controller.selected_index, thread_index);
}

fn runArchiveCurrentThread(state: *runtime.AppState) void {
    const project = &state.project_controller.projects.items[state.project_controller.selected_index];
    state.archiveThreadAtIndex(state.project_controller.selected_index, project.selected_thread_index);
}

fn runImportCodex(state: *runtime.AppState) void {
    state.beginThreadImport(state.project_controller.selected_index, .codex);
}

fn runImportOpencode(state: *runtime.AppState) void {
    state.beginThreadImport(state.project_controller.selected_index, .opencode);
}

fn runImportClaude(state: *runtime.AppState) void {
    state.beginThreadImport(state.project_controller.selected_index, .claude);
}

fn runSplitChatRight(state: *runtime.AppState) void {
    _ = state.splitFocusedWorkspacePaneWithChatAxis(.vertical);
}

fn runSplitChatDown(state: *runtime.AppState) void {
    _ = state.splitFocusedWorkspacePaneWithChatAxis(.horizontal);
}

fn runSplitTerminalRight(state: *runtime.AppState) void {
    _ = state.splitFocusedWorkspacePaneWithTerminalAxis(.vertical);
}

fn runSplitTerminalDown(state: *runtime.AppState) void {
    _ = state.splitFocusedWorkspacePaneWithTerminalAxis(.horizontal);
}

fn runOpenTerminal(state: *runtime.AppState) void {
    _ = state.openTerminalPaneForProjectIndex(state.project_controller.selected_index);
}

fn runToggleBrowser(state: *runtime.AppState) void {
    state.toggleBrowser();
}

fn runNewBrowserTab(state: *runtime.AppState) void {
    state.createBrowserTab();
}

fn runDuplicateBrowserTab(state: *runtime.AppState) void {
    state.duplicateBrowserTab(state.activeBrowserTabIndex());
}

fn runToggleBrowserTabPinned(state: *runtime.AppState) void {
    state.toggleBrowserTabPinned(state.activeBrowserTabIndex());
}

fn runMoveBrowserTabLeft(state: *runtime.AppState) void {
    const active = state.activeBrowserTabIndex();
    if (active > 0) state.moveBrowserTab(active, active - 1);
}

fn runMoveBrowserTabRight(state: *runtime.AppState) void {
    const active = state.activeBrowserTabIndex();
    if (active + 1 < state.browserTabCount()) state.moveBrowserTab(active, active + 1);
}

fn runCloseBrowserTab(state: *runtime.AppState) void {
    state.closeBrowserTab(state.activeBrowserTabIndex());
}

fn runClosePane(state: *runtime.AppState) void {
    _ = state.closeFocusedWorkspacePane();
}

fn runZoomPane(state: *runtime.AppState) void {
    _ = state.toggleFocusedWorkspacePaneMaximized();
}

fn runPreviousPane(state: *runtime.AppState) void {
    focusAdjacentPane(state, true);
}

fn runNextPane(state: *runtime.AppState) void {
    focusAdjacentPane(state, false);
}

fn focusAdjacentPane(state: *runtime.AppState, previous: bool) void {
    const pane_id = adjacentPaneForCommand(state, previous) orelse return;
    _ = state.focusCurrentProjectWorkspacePane(pane_id);
}

fn paneTraversalDirection(scroll_direction: app_config.WorkspaceScrollDirection, previous: bool) runtime.WorkspacePaneDirection {
    return switch (scroll_direction) {
        .horizontal => if (previous) .left else .right,
        .vertical => if (previous) .up else .down,
    };
}

fn runFloatPane(state: *runtime.AppState) void {
    _ = state.floatFocusedWorkspacePane();
}

fn runToggleQuickPane(state: *runtime.AppState) void {
    _ = state.toggleCurrentProjectQuickPane();
}

fn runMaximizeQuickPane(state: *runtime.AppState) void {
    _ = state.toggleCurrentProjectQuickPaneMaximized();
}

fn runMinimizeQuickPane(state: *runtime.AppState) void {
    _ = state.minimizeCurrentProjectQuickPane();
}

fn runPinQuickPane(state: *runtime.AppState) void {
    _ = state.toggleCurrentProjectQuickPanePinned();
}

fn runTileQuickPane(state: *runtime.AppState) void {
    _ = state.returnCurrentProjectQuickPaneToTile();
}

fn runScrollingAutomatic(state: *runtime.AppState) void {
    state.setWorkspaceScrollMode(.automatic);
}

fn runScrollingAlways(state: *runtime.AppState) void {
    state.setWorkspaceScrollMode(.always);
}

fn runScrollingDisabled(state: *runtime.AppState) void {
    state.setWorkspaceScrollMode(.disabled);
}

fn runScrollingUseGlobal(state: *runtime.AppState) void {
    state.setWorkspaceScrollMode(null);
}

fn runResetScrollingColumnWidth(state: *runtime.AppState) void {
    if (state.project_controller.selected_index >= state.project_controller.projects.items.len) return;
    state.project_controller.projects.items[state.project_controller.selected_index].workspace_layout.scroll_pane_extent_override = null;
    state.setSidebarNotice("Scrolling column width reset to Panes per view.");
    state.markDirty();
}

fn runAddWorkspace(state: *runtime.AppState) void {
    state.project_controller.show_creator = true;
    state.setSidebarCollapsed(false);
    state.clearImportPath();
    state.project_import_cursor = 0;
    state.palette_modal_text_focus = .project_import;
    state.setSidebarNotice("");
    state.markDirty();
}

fn runRenameWorkspace(state: *runtime.AppState) void {
    state.beginProjectRename(state.project_controller.selected_index);
}

fn runRenameCurrentChat(state: *runtime.AppState) void {
    state.beginCurrentThreadRename();
}

fn runRegenerateChatTitle(state: *runtime.AppState) void {
    state.regenerateCurrentThreadTitle();
}

fn runCloseWorkspace(state: *runtime.AppState) void {
    state.closeProjectAtIndex(state.project_controller.selected_index);
}

fn runReopenWorkspace(state: *runtime.AppState) void {
    _ = state.reopenLastClosedProject();
}

fn runOpenCodexTui(state: *runtime.AppState) void {
    runOpenAgentTui(state, .codex);
}

fn runOpenClaudeTui(state: *runtime.AppState) void {
    runOpenAgentTui(state, .claude);
}

fn runOpenOpencodeTui(state: *runtime.AppState) void {
    runOpenAgentTui(state, .opencode);
}

fn runOpenCursorTui(state: *runtime.AppState) void {
    runOpenAgentTui(state, .cursor);
}

fn runOpenGrokTui(state: *runtime.AppState) void {
    runOpenAgentTui(state, .grok);
}

fn runGrokSetup(state: *runtime.AppState) void {
    state.openGrokSetupGuide();
}

fn runOpenAmpTui(state: *runtime.AppState) void {
    runOpenAgentTui(state, .amp);
}

fn runHerdrHandoffWorkspace(state: *runtime.AppState) void {
    state.handoffProjectToLocalHerdrFromUi(state.project_controller.selected_index);
}

fn runHerdrRemoteHandoffWorkspace(state: *runtime.AppState) void {
    state.beginHerdrProfilePicker(state.project_controller.selected_index);
}

fn runFocusHerdrTerminal(state: *runtime.AppState) void {
    _ = state.focusProjectHerdrAttachTerminal(state.project_controller.selected_index);
}

fn runUnlinkHerdrWorkspace(state: *runtime.AppState) void {
    state.unlinkProjectHerdrFromUi(state.project_controller.selected_index);
}

fn runOpenAgentTui(state: *runtime.AppState, provider: AgentProvider) void {
    if (workspace_panes.gridNewPanePlacement(state)) |placement| {
        _ = state.openAgentTuiAtPlacement(state.project_controller.selected_index, provider, placement.pane_id, placement.axis, placement.new_after) catch false;
        return;
    }
    _ = state.openAgentTuiAtPlacement(state.project_controller.selected_index, provider, null, .horizontal, true) catch false;
}

fn runHistoryThisWorkspace(state: *runtime.AppState) void {
    state.command_controller.scope_project = state.project_controller.selected_index;
    state.command_controller.query_storage[0] = 0;
    state.command_controller.cursor = 0;
    state.command_controller.selected = 0;
    state.command_controller.action_menu_open = false;
    state.markDirty();
}

fn runSettings(state: *runtime.AppState) void {
    state.openSettingsModal();
}

fn runToggleSidebar(state: *runtime.AppState) void {
    state.toggleSidebarCollapsed();
}

// ---------------------------------------------------------------------------
// Rendering
// ---------------------------------------------------------------------------

/// Search field with selection highlight + caret, matching the metrics
/// `layout.zig` uses for modal text hit-testing (font 14, +10px text inset).
fn renderSearchField(state: *runtime.AppState) void {
    const focused = state.palette_modal_text_focus == .command_palette;
    const value = state.commandPaletteQuery();
    const border = if (focused) theme.COLOR_GREEN else theme.COLOR_PANEL_MUTED;
    // Recessed field: darker than the (opaque) panel so it reads as an input,
    // matching the sidebar's selected-workspace card treatment.
    queueRoundedRect(state, input_rect, paletteColor(theme.background()), theme.scaledUi(7.0));
    queueBorder(state, input_rect, paletteColor(border), theme.scaledUi(7.0), theme.scaledUi(1.0));

    const font_size = theme.scaledUi(14.0);
    const line_height = font_size * 1.25;
    const text_x = input_rect.x + theme.scaledUi(10.0);
    const text_y = input_rect.y + (input_rect.h - line_height) * 0.5;
    const text_w = input_rect.w - theme.scaledUi(20.0);

    if (focused) {
        state.modal_text_input_rect = input_rect;
        state.modal_text_input_font_size = font_size;
        if (state.modal_text_selection_anchor) |anchor| {
            const cursor = @min(state.command_controller.cursor, value.len);
            const a = @min(anchor, value.len);
            if (a != cursor) {
                const start = @min(a, cursor);
                const end = @max(a, cursor);
                const x0 = text_x + runtime.paletteUiTextPrefixWidth(value, font_size, start);
                const x1 = text_x + runtime.paletteUiTextPrefixWidth(value, font_size, end);
                const clamped_x0 = @max(x0, text_x);
                const clamped_x1 = @min(x1, text_x + text_w);
                if (clamped_x1 > clamped_x0) {
                    queueRect(state, .{ .x = clamped_x0, .y = text_y, .w = clamped_x1 - clamped_x0, .h = line_height }, paletteColor(theme.withAlpha(theme.selection(), 200)));
                }
            }
        }
    }

    const shown = if (value.len > 0) value else "Search threads and commands...";
    const color = if (value.len > 0) theme.COLOR_WHITE else theme.COLOR_TEXT_SUBTLE;
    queueRoleText(state, .{ .x = text_x, .y = text_y, .w = text_w, .h = line_height }, shown, paletteColor(color), font_size, input_rect);

    if (focused) {
        const clamped_cursor = @min(state.command_controller.cursor, value.len);
        const cursor_x = text_x + runtime.paletteUiTextPrefixWidth(value, font_size, clamped_cursor);
        queueRect(state, .{ .x = cursor_x, .y = text_y, .w = theme.scaledUi(1.0), .h = line_height }, paletteColor(theme.COLOR_WHITE));
    }
}

/// Scope/status line between the search field and the results.
fn renderScopeLine(state: *runtime.AppState) void {
    var buf: [128]u8 = undefined;
    const label = blk: {
        if (state.command_controller.scope_project) |pi| {
            if (pi < state.project_controller.projects.items.len) {
                break :blk std.fmt.bufPrint(&buf, "{s} - history  (Ctrl+Shift+P for all)", .{state.project_controller.projects.items[pi].label}) catch "history";
            }
        }
        break :blk "All workspaces";
    };
    queueText(state, .{
        .x = input_rect.x + theme.scaledUi(2.0),
        .y = input_rect.y + input_rect.h + theme.scaledUi(4.0),
        .w = input_rect.w - theme.scaledUi(4.0),
        .h = theme.scaledUi(16.0),
    }, label, paletteColor(theme.COLOR_TEXT_SUBTLE), theme.scaledUi(12.0), modal_rect);
}

/// Result rows: section headers, command rows with keybind hints, thread rows
/// with provider glyph + workspace + open badge + relative time.
fn renderRows(state: *runtime.AppState) void {
    if (result_count == 0) {
        queueText(state, .{
            .x = list_rect.x + theme.scaledUi(8.0),
            .y = list_rect.y + theme.scaledUi(12.0),
            .w = list_rect.w - theme.scaledUi(16.0),
            .h = theme.scaledUi(20.0),
        }, "No matches.", paletteColor(theme.COLOR_TEXT_SUBTLE), theme.scaledUi(13.0), list_rect);
        return;
    }

    var i: usize = 0;
    while (i < result_count) : (i += 1) {
        const rect = row_rects[i];
        if (!rowVisible(rect)) continue;
        // Partially-scrolled rows must clip to the list viewport so they
        // never paint over the scope line above or the footer hints below.
        const row_clip = intersectRects(rect, list_rect);
        if (row_clip.w <= 0.0 or row_clip.h <= 0.0) continue;
        switch (results[i].ref) {
            .header => |label| {
                queueText(state, .{
                    .x = rect.x + theme.scaledUi(4.0),
                    .y = rect.y + rect.h - theme.scaledUi(18.0),
                    .w = rect.w - theme.scaledUi(8.0),
                    .h = theme.scaledUi(16.0),
                }, label, paletteColor(theme.COLOR_TEXT_MUTED), theme.scaledUi(11.0), row_clip);
            },
            .command => |ci| renderCommandRow(state, i, ci, rect, row_clip),
            .thread => |tr| renderThreadRow(state, i, tr, rect, row_clip),
            .agent_tui => |tui| renderAgentTuiRow(state, i, tui, rect, row_clip),
            .workspace => |pi| renderWorkspaceRow(state, i, pi, rect, row_clip),
            .closed_workspace => |ai| renderClosedWorkspaceRow(state, i, ai, rect, row_clip),
        }
    }
}

fn renderRowBackground(state: *runtime.AppState, row_index: usize, rect: palette.Rect, row_clip: palette.Rect) void {
    const selected = state.command_controller.selected == row_index;
    const hovered = hovered_row != null and hovered_row.? == row_index;
    // Clamp the highlight to the viewport so a half-scrolled row's card
    // doesn't poke into the input/footer chrome.
    const bg_rect = intersectRects(rect, row_clip);
    if (bg_rect.w <= 0.0 or bg_rect.h <= 0.0) return;
    if (selected) {
        // Accent tint rather than a lighter-gray card: on the dark panel a
        // translucent accent keeps the active row distinct and on-brand, and
        // stays independent of the theme-derived (possibly light) panel tokens.
        // Slightly stronger when also hovered for feedback.
        const bg = theme.withAlpha(theme.COLOR_GREEN, if (hovered) 76 else 56);
        queueRoundedRect(state, bg_rect, paletteColor(bg), theme.scaledUi(7.0));
    } else if (hovered) {
        // Neutral light wash over the dark panel; theme-independent so hover
        // never collapses into the surface on light color0/color8 themes.
        queueRoundedRect(state, bg_rect, paletteColor(theme.withAlpha(theme.COLOR_WHITE, 20)), theme.scaledUi(7.0));
    }
}

fn renderCommandRow(state: *runtime.AppState, row_index: usize, command_index: usize, rect: palette.Rect, row_clip: palette.Rect) void {
    renderRowBackground(state, row_index, rect, row_clip);
    const command = STATIC_COMMANDS[command_index];
    const emphasis = state.command_controller.selected == row_index;
    const font_size = theme.scaledUi(13.5);
    const text_y = rect.y + (rect.h - font_size * 1.3) * 0.5;

    // ">" glyph marks action rows apart from thread rows at a glance.
    queueText(state, .{ .x = rect.x + theme.scaledUi(12.0), .y = text_y, .w = theme.scaledUi(16.0), .h = font_size * 1.3 }, ">", paletteColor(theme.COLOR_GREEN), font_size, row_clip);

    const hint = keybindHintFor(state, command.keybind);
    const hint_w = if (hint.len > 0) theme.scaledUi(110.0) else theme.scaledUi(0.0);
    queueText(state, .{
        .x = rect.x + theme.scaledUi(34.0),
        .y = text_y,
        .w = rect.w - theme.scaledUi(34.0) - hint_w - theme.scaledUi(12.0),
        .h = font_size * 1.3,
    }, command.title, paletteColor(if (emphasis) theme.COLOR_WHITE else theme.COLOR_TEXT_MUTED), font_size, row_clip);
    if (hint.len > 0) {
        queueText(state, .{
            .x = rect.x + rect.w - hint_w - theme.scaledUi(10.0),
            .y = text_y,
            .w = hint_w,
            .h = font_size * 1.3,
        }, hint, paletteColor(theme.COLOR_TEXT_SUBTLE), theme.scaledUi(12.0), row_clip);
    }
}

fn renderThreadRow(state: *runtime.AppState, row_index: usize, tr: ThreadRef, rect: palette.Rect, row_clip: palette.Rect) void {
    renderRowBackground(state, row_index, rect, row_clip);
    if (tr.project >= state.project_controller.projects.items.len) return;
    const project = &state.project_controller.projects.items[tr.project];
    if (tr.thread >= project.threads.items.len) return;
    const thread = &project.threads.items[tr.thread];
    const emphasis = state.command_controller.selected == row_index;
    const font_size = theme.scaledUi(13.5);
    const text_y = rect.y + (rect.h - font_size * 1.3) * 0.5;

    sidebar.queuePaletteProviderGlyph(state, thread.provider, rect.x + theme.scaledUi(10.0), rect.y + rect.h * 0.5, row_clip);

    const is_open = threadOpenPaneId(project, tr.thread) != null;
    const time_w = theme.scaledUi(56.0);
    const open_w = if (is_open) theme.scaledUi(42.0) else 0.0;
    // Show the owning workspace when results span workspaces (global scope).
    const show_workspace = state.command_controller.scope_project == null;
    const workspace_w = if (show_workspace) theme.scaledUi(96.0) else 0.0;
    const title_x = rect.x + theme.scaledUi(42.0);
    queueText(state, .{
        .x = title_x,
        .y = text_y,
        .w = rect.w - (title_x - rect.x) - workspace_w - open_w - time_w - theme.scaledUi(16.0),
        .h = font_size * 1.3,
    }, thread.title, paletteColor(if (emphasis) theme.COLOR_WHITE else theme.COLOR_TEXT_MUTED), font_size, row_clip);

    var right = rect.x + rect.w - theme.scaledUi(8.0);
    var time_buf: [24]u8 = undefined;
    const relative_time = sidebar.formatRelativeTime(&time_buf, thread.last_activity_at);
    right -= time_w;
    queueText(state, .{ .x = right, .y = text_y, .w = time_w, .h = font_size * 1.3 }, relative_time, paletteColor(theme.COLOR_TEXT_SUBTLE), theme.scaledUi(12.0), row_clip);
    if (is_open) {
        right -= open_w;
        queueText(state, .{ .x = right, .y = text_y, .w = open_w, .h = font_size * 1.3 }, "open", paletteColor(theme.COLOR_GREEN), theme.scaledUi(12.0), row_clip);
    }
    if (show_workspace) {
        right -= workspace_w;
        queueText(state, .{ .x = right, .y = text_y, .w = workspace_w - theme.scaledUi(8.0), .h = font_size * 1.3 }, project.label, paletteColor(theme.COLOR_TEXT_SUBTLE), theme.scaledUi(12.0), row_clip);
    }
}

// History row for a saved agent TUI terminal session.
fn renderAgentTuiRow(state: *runtime.AppState, row_index: usize, tui: AgentTuiRef, rect: palette.Rect, row_clip: palette.Rect) void {
    renderRowBackground(state, row_index, rect, row_clip);
    if (tui.project >= state.project_controller.projects.items.len) return;
    const project = &state.project_controller.projects.items[tui.project];
    const provider = state.workspaceAgentTuiProvider(tui.project, tui.dock) orelse return;
    const emphasis = state.command_controller.selected == row_index;
    const font_size = theme.scaledUi(13.5);
    const text_y = rect.y + (rect.h - font_size * 1.3) * 0.5;
    sidebar.queuePaletteAgentTuiProviderGlyph(state, provider, rect.x + theme.scaledUi(10.0), rect.y + rect.h * 0.5, row_clip);

    var title_buf: [96]u8 = undefined;
    const title = if (state.projectTerminalDock(tui.project, tui.dock)) |dock|
        dock.activeProcessLabel(&title_buf)
    else
        agentTuiSearchLabel(provider);
    var is_open = false;
    for (project.workspace_layout.panes.items) |pane| {
        switch (pane.ref) {
            .terminal => |ref| if (ref.dock_id == tui.dock) {
                is_open = true;
                break;
            },
            else => {},
        }
    }
    const status_w = theme.scaledUi(52.0);
    const time_w = theme.scaledUi(56.0);
    const workspace_w = if (state.command_controller.scope_project == null) theme.scaledUi(96.0) else 0.0;
    const title_x = rect.x + theme.scaledUi(54.0);
    queueText(state, .{
        .x = title_x,
        .y = text_y,
        .w = rect.w - (title_x - rect.x) - workspace_w - status_w - time_w - theme.scaledUi(16.0),
        .h = font_size * 1.3,
    }, title, paletteColor(if (emphasis) theme.COLOR_WHITE else theme.COLOR_TEXT_MUTED), font_size, row_clip);

    var right = rect.x + rect.w - theme.scaledUi(8.0);
    var time_buf: [24]u8 = undefined;
    const activity_at = @divTrunc(state.workspaceAgentTuiHistoryAt(tui.project, tui.dock), std.time.ms_per_s);
    const relative_time = sidebar.formatRelativeTime(&time_buf, activity_at);
    right -= time_w;
    queueText(state, .{ .x = right, .y = text_y, .w = time_w, .h = font_size * 1.3 }, relative_time, paletteColor(theme.COLOR_TEXT_SUBTLE), theme.scaledUi(12.0), row_clip);
    right -= status_w;
    queueText(state, .{ .x = right, .y = text_y, .w = status_w, .h = font_size * 1.3 }, if (is_open) "open" else "saved", paletteColor(if (is_open) theme.COLOR_GREEN else theme.COLOR_TEXT_SUBTLE), theme.scaledUi(12.0), row_clip);
    if (state.command_controller.scope_project == null) {
        right -= workspace_w;
        queueText(state, .{ .x = right, .y = text_y, .w = workspace_w - theme.scaledUi(8.0), .h = font_size * 1.3 }, project.label, paletteColor(theme.COLOR_TEXT_SUBTLE), theme.scaledUi(12.0), row_clip);
    }
}

fn renderWorkspaceRow(state: *runtime.AppState, row_index: usize, project_index: usize, rect: palette.Rect, row_clip: palette.Rect) void {
    renderRowBackground(state, row_index, rect, row_clip);
    if (project_index >= state.project_controller.projects.items.len) return;
    const emphasis = state.command_controller.selected == row_index;
    const font_size = theme.scaledUi(13.5);
    const text_y = rect.y + (rect.h - font_size * 1.3) * 0.5;
    var buf: [96]u8 = undefined;
    const label = std.fmt.bufPrint(&buf, "Switch to {s}", .{state.project_controller.projects.items[project_index].label}) catch "Switch workspace";
    queueText(state, .{ .x = rect.x + theme.scaledUi(12.0), .y = text_y, .w = theme.scaledUi(16.0), .h = font_size * 1.3 }, ">", paletteColor(theme.COLOR_GREEN), font_size, row_clip);
    const hint_w = theme.scaledUi(64.0);
    queueText(state, .{
        .x = rect.x + theme.scaledUi(34.0),
        .y = text_y,
        .w = rect.w - theme.scaledUi(34.0) - hint_w - theme.scaledUi(12.0),
        .h = font_size * 1.3,
    }, label, paletteColor(if (emphasis) theme.COLOR_WHITE else theme.COLOR_TEXT_MUTED), font_size, row_clip);
    // Alt+N hint mirrors the workspace_select ordinal bindings.
    var ordinal_hint_buf: [12]u8 = undefined;
    if (project_index < 9) {
        const hint = std.fmt.bufPrint(&ordinal_hint_buf, "Alt+{d}", .{project_index + 1}) catch "";
        queueText(state, .{
            .x = rect.x + rect.w - hint_w - theme.scaledUi(10.0),
            .y = text_y,
            .w = hint_w,
            .h = font_size * 1.3,
        }, hint, paletteColor(theme.COLOR_TEXT_SUBTLE), theme.scaledUi(12.0), row_clip);
    }
}

fn renderClosedWorkspaceRow(state: *runtime.AppState, row_index: usize, archived_index: usize, rect: palette.Rect, row_clip: palette.Rect) void {
    renderRowBackground(state, row_index, rect, row_clip);
    if (archived_index >= state.project_controller.archived_projects.items.len) return;
    const emphasis = state.command_controller.selected == row_index;
    const font_size = theme.scaledUi(13.5);
    const text_y = rect.y + (rect.h - font_size * 1.3) * 0.5;
    var buf: [96]u8 = undefined;
    const label = std.fmt.bufPrint(&buf, "Reopen {s}", .{state.project_controller.archived_projects.items[archived_index].label}) catch "Reopen workspace";
    queueText(state, .{ .x = rect.x + theme.scaledUi(12.0), .y = text_y, .w = theme.scaledUi(16.0), .h = font_size * 1.3 }, ">", paletteColor(theme.COLOR_GREEN), font_size, row_clip);
    queueText(state, .{
        .x = rect.x + theme.scaledUi(34.0),
        .y = text_y,
        .w = rect.w - theme.scaledUi(34.0) - theme.scaledUi(96.0),
        .h = font_size * 1.3,
    }, label, paletteColor(if (emphasis) theme.COLOR_WHITE else theme.COLOR_TEXT_MUTED), font_size, row_clip);
    queueText(state, .{
        .x = rect.x + rect.w - theme.scaledUi(88.0),
        .y = text_y,
        .w = theme.scaledUi(78.0),
        .h = font_size * 1.3,
    }, "closed", paletteColor(theme.COLOR_TEXT_SUBTLE), theme.scaledUi(12.0), row_clip);
}

fn renderActionMenu(state: *runtime.AppState) void {
    if (action_count == 0) return;
    // Lightened from the dark background (a bit more than the modal panel's
    // 0.04) so the submenu reads as a layer above it. Derived from background
    // rather than COLOR_PANEL_ALT for the same readability reason as the modal.
    queueRoundedRect(state, action_menu_rect, paletteColor(theme.lighten(theme.background(), 0.07)), theme.scaledUi(10.0));
    queueBorder(state, action_menu_rect, paletteColor(theme.COLOR_PANEL_MUTED), theme.scaledUi(10.0), theme.scaledUi(1.0));
    const font_size = theme.scaledUi(13.0);
    var i: usize = 0;
    while (i < action_count) : (i += 1) {
        const rect = action_rects[i];
        const selected = state.command_controller.action_selected == i;
        if (selected and action_enabled[i]) {
            queueRoundedRect(state, rect, paletteColor(theme.withAlpha(theme.COLOR_GREEN, 56)), theme.scaledUi(7.0));
        }
        const color = if (!action_enabled[i])
            theme.COLOR_TEXT_SUBTLE
        else if (selected)
            theme.COLOR_WHITE
        else
            theme.COLOR_TEXT_MUTED;
        queueText(state, .{
            .x = rect.x + theme.scaledUi(10.0),
            .y = rect.y + (rect.h - font_size * 1.3) * 0.5,
            .w = rect.w - theme.scaledUi(16.0),
            .h = font_size * 1.3,
        }, action_labels[i], paletteColor(color), font_size, action_menu_rect);
    }
}

fn renderFooter(state: *runtime.AppState) void {
    const font_size = theme.scaledUi(11.5);
    const y = modal_rect.y + modal_rect.h - theme.scaledUi(FOOTER_H_CSS) + theme.scaledUi(6.0);
    queueRect(state, .{
        .x = modal_rect.x + theme.scaledUi(1.0),
        .y = modal_rect.y + modal_rect.h - theme.scaledUi(FOOTER_H_CSS),
        .w = modal_rect.w - theme.scaledUi(2.0),
        .h = theme.scaledUi(1.0),
    }, paletteColor(theme.borderMuted()));
    queueText(state, .{
        .x = modal_rect.x + theme.scaledUi(PAD_CSS),
        .y = y,
        .w = modal_rect.w - theme.scaledUi(PAD_CSS) * 2.0,
        .h = font_size * 1.4,
    }, "Enter Open    Ctrl+Enter New Pane    Tab Actions    Esc Close", paletteColor(theme.COLOR_TEXT_SUBTLE), font_size, modal_rect);
}

// ---------------------------------------------------------------------------
// Keybind hints
// ---------------------------------------------------------------------------

var hint_buf: [32]u8 = undefined;

/// Formats the first loaded accelerator for a command's keybind reference, so
/// hints track user rebinds. Returns "" when unbound.
fn keybindHintFor(state: *runtime.AppState, ref: ?KeybindRef) []const u8 {
    const keybind_ref = ref orelse return "";
    const config = state.command_controller.keyboard_config orelse return "";
    const bindings = switch (keybind_ref) {
        .new_thread => config.new_thread,
        .chat_model_picker => config.chat_model_picker,
        .chat_run_config => config.chat_run_config,
        .toggle_sidebar => config.toggle_sidebar,
        .toggle_browser => config.toggle_browser,
        .toggle_terminal => config.toggle_terminal,
        .workspace_close => config.workspace_close,
        .workspace_toggle_maximize => config.workspace_toggle_maximize,
        .workspace_toggle_quick_pane => config.workspace_toggle_quick_pane,
        .workspace_split_chat_vertical => config.workspace_split_chat_vertical,
        .workspace_split_chat_horizontal => config.workspace_split_chat_horizontal,
        .workspace_split_terminal_vertical => config.workspace_split_terminal_vertical,
        .workspace_split_terminal_horizontal => config.workspace_split_terminal_horizontal,
        .workspace_previous_pane => switch (state.app_config.workspace_scroll_direction) {
            .horizontal => config.workspace_focus_left,
            .vertical => config.workspace_focus_up,
        },
        .workspace_next_pane => switch (state.app_config.workspace_scroll_direction) {
            .horizontal => config.workspace_focus_right,
            .vertical => config.workspace_focus_down,
        },
    };
    if (bindings.len == 0) return "";
    return formatKeybind(&hint_buf, bindings[0]);
}

/// Formats the first loaded command-palette accelerator for UI hints (the
/// sidebar's search-trigger badge), so the label tracks user rebinds instead
/// of hardcoding the default. Returns "" when unbound.
pub fn commandPaletteShortcutHint(state: *runtime.AppState) []const u8 {
    const config = state.command_controller.keyboard_config orelse return "";
    if (config.command_palette.len == 0) return "";
    return formatKeybind(&hint_buf, config.command_palette[0]);
}

fn formatKeybind(buf: []u8, keybind: keybinds.Keybind) []const u8 {
    var n: usize = 0;
    if (keybind.primary or keybind.ctrl) n += copyInto(buf[n..], "Ctrl+");
    if (keybind.meta) n += copyInto(buf[n..], "Meta+");
    if (keybind.alt) n += copyInto(buf[n..], "Alt+");
    if (keybind.shift) n += copyInto(buf[n..], "Shift+");
    const key_name = keycodeLabel(keybind.key);
    n += copyInto(buf[n..], key_name);
    // Single-letter keys read better uppercased ("Ctrl+Shift+P", not "Ctrl+Shift+p").
    if (key_name.len == 1 and n > 0) buf[n - 1] = std.ascii.toUpper(buf[n - 1]);
    return buf[0..n];
}

fn keycodeLabel(key: sdl.Keycode) []const u8 {
    return switch (key) {
        .@"return" => "Enter",
        .left => "Left",
        .right => "Right",
        .up => "Up",
        .down => "Down",
        else => @tagName(key),
    };
}

fn copyInto(dest: []u8, src: []const u8) usize {
    const n = @min(dest.len, src.len);
    @memcpy(dest[0..n], src[0..n]);
    return n;
}

// ---------------------------------------------------------------------------
// Palette batch helpers (module-local mirrors of layout.zig's queue fns)
// ---------------------------------------------------------------------------

fn rowVisible(rect: palette.Rect) bool {
    return rect.y + rect.h >= list_rect.y and rect.y <= list_rect.y + list_rect.h;
}

fn rectContainsPoint(rect: palette.Rect, x: f32, y: f32) bool {
    return x >= rect.x and y >= rect.y and x <= rect.x + rect.w and y <= rect.y + rect.h;
}

fn paletteColor(value: [4]f32) palette.Color {
    return .{ .r = value[0], .g = value[1], .b = value[2], .a = value[3] };
}

fn keymodBits(modifier_state: sdl.Keymod) u16 {
    return @as(*const u16, @ptrCast(&modifier_state)).*;
}

fn queueRect(state: *runtime.AppState, rect: palette.Rect, color: palette.Color) void {
    state.palette_overlay_batch.rect(state.allocator, rect, color) catch |err| {
        log.warn("failed to queue palette rect: {s}", .{@errorName(err)});
    };
}

fn queueRoundedRect(state: *runtime.AppState, rect: palette.Rect, color: palette.Color, radius: f32) void {
    state.palette_overlay_batch.roundedRect(state.allocator, rect, color, radius) catch |err| {
        log.warn("failed to queue palette rounded rect: {s}", .{@errorName(err)});
    };
}

fn queueBorder(state: *runtime.AppState, rect: palette.Rect, color: palette.Color, radius: f32, width: f32) void {
    state.palette_overlay_batch.rectBorder(state.allocator, rect, color, radius, width) catch |err| {
        log.warn("failed to queue palette border: {s}", .{@errorName(err)});
    };
}

fn stableText(state: *runtime.AppState, value: []const u8) ?[]const u8 {
    return state.palette_frame_text_arena.allocator().dupe(u8, value) catch |err| {
        log.warn("failed to retain palette text: {s}", .{@errorName(err)});
        return null;
    };
}

fn intersectRects(a: palette.Rect, b: palette.Rect) palette.Rect {
    const x0 = @max(a.x, b.x);
    const y0 = @max(a.y, b.y);
    const x1 = @min(a.x + a.w, b.x + b.w);
    const y1 = @min(a.y + a.h, b.y + b.h);
    return .{ .x = x0, .y = y0, .w = @max(x1 - x0, 0.0), .h = @max(y1 - y0, 0.0) };
}

fn queueText(state: *runtime.AppState, rect: palette.Rect, value: []const u8, color: palette.Color, font_size: f32, clip: ?palette.Rect) void {
    const stable_value = stableText(state, value) orelse return;
    // Clip to the text rect horizontally so long values truncate instead of
    // running under neighboring columns, but keep the caller's vertical clip
    // (descenders need more height than the tight text-line rect).
    const base = clip orelse rect;
    const effective_clip = intersectRects(.{ .x = rect.x, .y = base.y, .w = rect.w, .h = base.h }, base);
    if (effective_clip.w <= 0.0 or effective_clip.h <= 0.0) return;
    state.palette_overlay_batch.fixedText(
        state.allocator,
        rect,
        stable_value,
        color,
        font_size,
        effective_clip,
        .{},
        font_size * 0.55,
        font_size * 1.25,
        false,
    ) catch |err| {
        log.warn("failed to queue palette text: {s}", .{@errorName(err)});
    };
}

fn queueRoleText(state: *runtime.AppState, rect: palette.Rect, value: []const u8, color: palette.Color, font_size: f32, clip: ?palette.Rect) void {
    const stable_value = stableText(state, value) orelse return;
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
        log.warn("failed to queue palette role text: {s}", .{@errorName(err)});
    };
}

test "static commands expose scrolling layout controls" {
    const expected_ids = [_][]const u8{
        "pane.previous",
        "pane.next",
        "workspace.scrolling_use_global",
        "workspace.scrolling_automatic",
        "workspace.scrolling_always",
        "workspace.scrolling_disabled",
        "workspace.scrolling_reset_column_width",
    };
    for (expected_ids) |expected_id| {
        var found = false;
        for (STATIC_COMMANDS) |command| {
            if (std.mem.eql(u8, command.id, expected_id)) {
                found = true;
                break;
            }
        }
        try std.testing.expect(found);
    }
}

test "pane traversal commands follow the configured scrolling axis" {
    try std.testing.expectEqual(runtime.WorkspacePaneDirection.left, paneTraversalDirection(.horizontal, true));
    try std.testing.expectEqual(runtime.WorkspacePaneDirection.right, paneTraversalDirection(.horizontal, false));
    try std.testing.expectEqual(runtime.WorkspacePaneDirection.up, paneTraversalDirection(.vertical, true));
    try std.testing.expectEqual(runtime.WorkspacePaneDirection.down, paneTraversalDirection(.vertical, false));
}

test "fuzzyScore ranks substring above subsequence and rejects non-matches" {
    const substring = fuzzyScore("Split Chat Right", "chat").?;
    const subsequence = fuzzyScore("Split Chat Right", "scr").?;
    try std.testing.expect(substring > subsequence);
    try std.testing.expect(fuzzyScore("Split Chat Right", "browser") == null);
    // Earlier substring hits outrank later ones.
    const early = fuzzyScore("chat about chat", "chat").?;
    const late = fuzzyScore("talk about chat", "chat").?;
    try std.testing.expect(early > late);
}

test "asciiIndexOfIgnoreCase finds case-insensitive needles" {
    try std.testing.expectEqual(@as(?usize, 6), asciiIndexOfIgnoreCase("Split CHAT Right", "chat"));
    try std.testing.expectEqual(@as(?usize, null), asciiIndexOfIgnoreCase("Split", "chat"));
    try std.testing.expectEqual(@as(?usize, 0), asciiIndexOfIgnoreCase("chat", "chat"));
}

test "formatKeybind renders modifiers and uppercases single letters" {
    var buf: [32]u8 = undefined;
    const rendered = formatKeybind(&buf, .{ .primary = true, .shift = true, .key = .p });
    try std.testing.expectEqualStrings("Ctrl+Shift+P", rendered);
    const plain = formatKeybind(&buf, .{ .alt = true, .key = .left });
    try std.testing.expectEqualStrings("Alt+Left", plain);
}
