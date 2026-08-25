//! Keyboard shortcut loading and matching for the native Verde shell.

const std = @import("std");
const builtin = @import("builtin");
const sdl = @import("zsdl3");
const shared_config = @import("config.zig");

const log = std.log.scoped(.native_keybinds);

pub const NativeKeyboardAction = enum {
    refresh,
    open_default,
    open_editor,
    new_thread,
    command_palette,
    companion,
    toggle_sidebar,
    toggle_sidebar_hidden,
    toggle_browser,
    toggle_terminal,
    chat_up,
    chat_down,
    chat_page_up,
    chat_page_down,
    workspace_previous,
    workspace_next,
    workspace_active_previous,
    workspace_active_next,
    workspace_pane_previous,
    workspace_pane_next,
    workspace_split_chat_vertical,
    workspace_split_chat_horizontal,
    workspace_split_terminal_vertical,
    workspace_split_terminal_horizontal,
    workspace_toggle_maximize,
    workspace_toggle_quick_pane,
    workspace_close,
    workspace_close_current,
    workspace_focus_left,
    workspace_focus_right,
    workspace_focus_up,
    workspace_focus_down,
    workspace_move_left,
    workspace_move_right,
    workspace_move_up,
    workspace_move_down,
    workspace_grow_left,
    workspace_grow_right,
    workspace_grow_up,
    workspace_grow_down,
};

pub const NativeTerminalAction = enum {
    new_tab,
    close_active,
    rename_tab,
    tab_previous,
    tab_next,
    split_up,
    split_down,
    split_left,
    split_right,
    focus_up,
    focus_down,
    focus_left,
    focus_right,
};

pub const NativeChatAction = enum {
    model_picker,
    run_config,
};

/// What a prefix chord resolves to. Mirrors every dispatch surface the direct
/// keybind tables reach so `prefix + key` can trigger any built-in command,
/// plus user-authored shell scripts.
pub const PrefixTarget = union(enum) {
    app: NativeKeyboardAction,
    terminal: NativeTerminalAction,
    chat: NativeChatAction,
    focus_prompt,
    /// Opens the keybind cheat sheet and keeps the prefix armed.
    show_keybinds,
    /// Opens the workspace action menu (herdr `prefix w`).
    navigate,
    split_default_vertical,
    split_default_horizontal,
    split_alternate_vertical,
    split_alternate_horizontal,
    workspace_select: usize,
    pane_select: usize,
    active_select: usize,
    /// Owned shell script, run through `sh -lc` in the current project.
    command: []u8,

    fn deinit(self: PrefixTarget, allocator: std.mem.Allocator) void {
        switch (self) {
            .command => |script| allocator.free(script),
            else => {},
        }
    }
};

pub const PrefixBinding = struct {
    key: Keybind,
    target: PrefixTarget,
};

pub const DEFAULT_PREFIX_ACCELERATOR = "Ctrl+B";

/// tmux-style prefix mode. Pressing any `keys` chord arms the next keypress,
/// which then resolves against `bindings` instead of the direct tables.
/// Disabled by default so existing direct shortcuts keep working unchanged.
pub const PrefixConfig = struct {
    enabled: bool = false,
    keys: []Keybind,
    bindings: std.ArrayList(PrefixBinding),
    /// Second table used while navigate mode is active.
    navigate: std.ArrayList(PrefixBinding),

    pub fn deinit(self: *PrefixConfig, allocator: std.mem.Allocator) void {
        allocator.free(self.keys);
        for (self.bindings.items) |binding| binding.target.deinit(allocator);
        self.bindings.deinit(allocator);
        for (self.navigate.items) |binding| binding.target.deinit(allocator);
        self.navigate.deinit(allocator);
    }
};

pub const Keybind = struct {
    alt: bool = false,
    ctrl: bool = false,
    meta: bool = false,
    primary: bool = false,
    shift: bool = false,
    key: sdl.Keycode,

    fn eql(self: Keybind, other: Keybind) bool {
        return self.alt == other.alt and
            self.ctrl == other.ctrl and
            self.meta == other.meta and
            self.primary == other.primary and
            self.shift == other.shift and
            self.key == other.key;
    }

    fn matches(self: Keybind, event: *const sdl.KeyboardEvent) bool {
        if (!event.down or event.repeat or event.key != self.key) {
            return false;
        }

        return self.matchesWithRepeatPolicy(event, false);
    }

    fn matchesAllowRepeat(self: Keybind, event: *const sdl.KeyboardEvent) bool {
        return self.matchesWithRepeatPolicy(event, true);
    }

    fn matchesWithRepeatPolicy(self: Keybind, event: *const sdl.KeyboardEvent, allow_repeat: bool) bool {
        if (!event.down or event.key != self.key) {
            return false;
        }
        if (!allow_repeat and event.repeat) {
            return false;
        }

        const primary_uses_meta = builtin.os.tag == .macos;
        const expected_ctrl = self.ctrl or (self.primary and !primary_uses_meta);
        const expected_meta = self.meta or (self.primary and primary_uses_meta);

        return expected_ctrl == hasModifier(event.mod, sdl.Keymod.ctrl) and
            expected_meta == hasModifier(event.mod, sdl.Keymod.gui) and
            self.alt == hasModifier(event.mod, sdl.Keymod.alt) and
            self.shift == hasModifier(event.mod, sdl.Keymod.shift);
    }
};

/// Matches the conventional page reload chord reserved for focused browser panes.
pub fn isBrowserReloadEvent(event: *const sdl.KeyboardEvent) bool {
    const binding: Keybind = .{ .primary = true, .key = .r };
    return binding.matches(event);
}

pub const NativeKeyboardConfig = struct {
    allocator: std.mem.Allocator,
    refresh: []Keybind,
    open_default: []Keybind,
    open_editor: []Keybind,
    new_thread: []Keybind,
    command_palette: []Keybind,
    companion: []Keybind,
    toggle_sidebar: []Keybind,
    toggle_sidebar_hidden: []Keybind,
    toggle_browser: []Keybind,
    toggle_terminal: []Keybind,
    chat_up: []Keybind,
    chat_down: []Keybind,
    chat_page_up: []Keybind,
    chat_page_down: []Keybind,
    chat_model_picker: []Keybind,
    chat_run_config: []Keybind,
    workspace_previous: []Keybind,
    workspace_next: []Keybind,
    workspace_active_previous: []Keybind,
    workspace_active_next: []Keybind,
    workspace_pane_previous: []Keybind,
    workspace_pane_next: []Keybind,
    terminal_new_tab: []Keybind,
    terminal_close_active: []Keybind,
    terminal_rename_tab: []Keybind,
    terminal_tab_previous: []Keybind,
    terminal_tab_next: []Keybind,
    terminal_split_up: []Keybind,
    terminal_split_down: []Keybind,
    terminal_split_left: []Keybind,
    terminal_split_right: []Keybind,
    terminal_focus_up: []Keybind,
    terminal_focus_down: []Keybind,
    terminal_focus_left: []Keybind,
    terminal_focus_right: []Keybind,
    workspace_split_chat_vertical: []Keybind,
    workspace_split_chat_horizontal: []Keybind,
    workspace_split_terminal_vertical: []Keybind,
    workspace_split_terminal_horizontal: []Keybind,
    workspace_toggle_maximize: []Keybind,
    workspace_toggle_quick_pane: []Keybind,
    workspace_close: []Keybind,
    workspace_close_current: []Keybind,
    workspace_focus_left: []Keybind,
    workspace_focus_right: []Keybind,
    workspace_focus_up: []Keybind,
    workspace_focus_down: []Keybind,
    workspace_focus_prompt: []Keybind,
    workspace_active_select: []Keybind,
    workspace_pane_select: []Keybind,
    workspace_move_left: []Keybind,
    workspace_move_right: []Keybind,
    workspace_move_up: []Keybind,
    workspace_move_down: []Keybind,
    workspace_grow_left: []Keybind,
    workspace_grow_right: []Keybind,
    workspace_grow_up: []Keybind,
    workspace_grow_down: []Keybind,
    workspace_select: []Keybind,
    prefix: PrefixConfig,

    pub fn load(allocator: std.mem.Allocator) !NativeKeyboardConfig {
        var config: NativeKeyboardConfig = .{
            .allocator = allocator,
            .refresh = try cloneDefaultKeybinds(allocator),
            .open_default = try cloneDefaultOpenKeybinds(allocator),
            .open_editor = try cloneDefaultOpenEditorKeybinds(allocator),
            .new_thread = try cloneDefaultNewThreadKeybinds(allocator),
            .command_palette = try cloneDefaultCommandPaletteKeybinds(allocator),
            .companion = try cloneDefaultCompanionKeybinds(allocator),
            .toggle_sidebar = try cloneDefaultSidebarKeybinds(allocator),
            .toggle_sidebar_hidden = try cloneDefaultSidebarHiddenKeybinds(allocator),
            .toggle_browser = try cloneDefaultBrowserKeybinds(allocator),
            .toggle_terminal = try cloneDefaultTerminalKeybinds(allocator),
            .chat_up = try cloneDefaultChatUpKeybinds(allocator),
            .chat_down = try cloneDefaultChatDownKeybinds(allocator),
            .chat_page_up = try cloneDefaultChatPageUpKeybinds(allocator),
            .chat_page_down = try cloneDefaultChatPageDownKeybinds(allocator),
            .chat_model_picker = try cloneDefaultChatModelPickerKeybinds(allocator),
            .chat_run_config = try cloneDefaultChatRunConfigKeybinds(allocator),
            .workspace_previous = try cloneDefaultWorkspacePreviousKeybinds(allocator),
            .workspace_next = try cloneDefaultWorkspaceNextKeybinds(allocator),
            .workspace_active_previous = try cloneDefaultWorkspaceActivePreviousKeybinds(allocator),
            .workspace_active_next = try cloneDefaultWorkspaceActiveNextKeybinds(allocator),
            .workspace_pane_previous = try cloneDefaultWorkspacePanePreviousKeybinds(allocator),
            .workspace_pane_next = try cloneDefaultWorkspacePaneNextKeybinds(allocator),
            .terminal_new_tab = try cloneDefaultTerminalNewTabKeybinds(allocator),
            .terminal_close_active = try cloneDefaultTerminalCloseActiveKeybinds(allocator),
            .terminal_rename_tab = try cloneDefaultTerminalRenameTabKeybinds(allocator),
            .terminal_tab_previous = try cloneDefaultTerminalTabPreviousKeybinds(allocator),
            .terminal_tab_next = try cloneDefaultTerminalTabNextKeybinds(allocator),
            .terminal_split_up = try cloneDefaultTerminalSplitUpKeybinds(allocator),
            .terminal_split_down = try cloneDefaultTerminalSplitDownKeybinds(allocator),
            .terminal_split_left = try cloneDefaultTerminalSplitLeftKeybinds(allocator),
            .terminal_split_right = try cloneDefaultTerminalSplitRightKeybinds(allocator),
            .terminal_focus_up = try cloneDefaultTerminalFocusUpKeybinds(allocator),
            .terminal_focus_down = try cloneDefaultTerminalFocusDownKeybinds(allocator),
            .terminal_focus_left = try cloneDefaultTerminalFocusLeftKeybinds(allocator),
            .terminal_focus_right = try cloneDefaultTerminalFocusRightKeybinds(allocator),
            .workspace_split_chat_vertical = try cloneEmptyKeybinds(allocator),
            .workspace_split_chat_horizontal = try cloneEmptyKeybinds(allocator),
            .workspace_split_terminal_vertical = try cloneEmptyKeybinds(allocator),
            .workspace_split_terminal_horizontal = try cloneDefaultWorkspaceSplitTerminalHorizontalKeybinds(allocator),
            .workspace_toggle_maximize = try cloneDefaultWorkspaceToggleMaximizeKeybinds(allocator),
            .workspace_toggle_quick_pane = try cloneDefaultWorkspaceToggleQuickPaneKeybinds(allocator),
            .workspace_close = try cloneDefaultWorkspaceCloseKeybinds(allocator),
            .workspace_close_current = try cloneDefaultWorkspaceCloseCurrentKeybinds(allocator),
            .workspace_focus_left = try cloneDefaultWorkspaceFocusLeftKeybinds(allocator),
            .workspace_focus_right = try cloneDefaultWorkspaceFocusRightKeybinds(allocator),
            .workspace_focus_up = try cloneDefaultWorkspaceFocusUpKeybinds(allocator),
            .workspace_focus_down = try cloneDefaultWorkspaceFocusDownKeybinds(allocator),
            .workspace_focus_prompt = try cloneDefaultWorkspaceFocusPromptKeybinds(allocator),
            .workspace_active_select = try cloneDefaultWorkspaceActiveSelectKeybinds(allocator),
            .workspace_pane_select = try cloneDefaultWorkspacePaneSelectKeybinds(allocator),
            .workspace_move_left = try cloneDefaultWorkspaceMoveLeftKeybinds(allocator),
            .workspace_move_right = try cloneDefaultWorkspaceMoveRightKeybinds(allocator),
            .workspace_move_up = try cloneDefaultWorkspaceMoveUpKeybinds(allocator),
            .workspace_move_down = try cloneDefaultWorkspaceMoveDownKeybinds(allocator),
            .workspace_grow_left = try cloneDefaultWorkspaceGrowLeftKeybinds(allocator),
            .workspace_grow_right = try cloneDefaultWorkspaceGrowRightKeybinds(allocator),
            .workspace_grow_up = try cloneDefaultWorkspaceGrowUpKeybinds(allocator),
            .workspace_grow_down = try cloneDefaultWorkspaceGrowDownKeybinds(allocator),
            .workspace_select = try cloneDefaultWorkspaceSelectKeybinds(allocator),
            .prefix = try cloneDefaultPrefixConfig(allocator),
        };

        var parsed = shared_config.readRootValue(allocator) catch |err| {
            log.warn("failed to read verde config: {s}", .{@errorName(err)});
            return config;
        };
        if (parsed == null) return config;
        defer parsed.?.deinit();

        config.applyOverrides(parsed.?.value);
        log.info("loaded keybinds from verde config", .{});
        return config;
    }

    pub fn deinit(self: *NativeKeyboardConfig) void {
        self.allocator.free(self.refresh);
        self.allocator.free(self.open_default);
        self.allocator.free(self.open_editor);
        self.allocator.free(self.new_thread);
        self.allocator.free(self.command_palette);
        self.allocator.free(self.companion);
        self.allocator.free(self.toggle_sidebar);
        self.allocator.free(self.toggle_sidebar_hidden);
        self.allocator.free(self.toggle_browser);
        self.allocator.free(self.toggle_terminal);
        self.allocator.free(self.chat_up);
        self.allocator.free(self.chat_down);
        self.allocator.free(self.chat_page_up);
        self.allocator.free(self.chat_page_down);
        self.allocator.free(self.chat_model_picker);
        self.allocator.free(self.chat_run_config);
        self.allocator.free(self.workspace_previous);
        self.allocator.free(self.workspace_next);
        self.allocator.free(self.workspace_active_previous);
        self.allocator.free(self.workspace_active_next);
        self.allocator.free(self.workspace_pane_previous);
        self.allocator.free(self.workspace_pane_next);
        self.allocator.free(self.terminal_new_tab);
        self.allocator.free(self.terminal_close_active);
        self.allocator.free(self.terminal_rename_tab);
        self.allocator.free(self.terminal_tab_previous);
        self.allocator.free(self.terminal_tab_next);
        self.allocator.free(self.terminal_split_up);
        self.allocator.free(self.terminal_split_down);
        self.allocator.free(self.terminal_split_left);
        self.allocator.free(self.terminal_split_right);
        self.allocator.free(self.terminal_focus_up);
        self.allocator.free(self.terminal_focus_down);
        self.allocator.free(self.terminal_focus_left);
        self.allocator.free(self.terminal_focus_right);
        self.allocator.free(self.workspace_split_chat_vertical);
        self.allocator.free(self.workspace_split_chat_horizontal);
        self.allocator.free(self.workspace_split_terminal_vertical);
        self.allocator.free(self.workspace_split_terminal_horizontal);
        self.allocator.free(self.workspace_toggle_maximize);
        self.allocator.free(self.workspace_toggle_quick_pane);
        self.allocator.free(self.workspace_close);
        self.allocator.free(self.workspace_close_current);
        self.allocator.free(self.workspace_focus_left);
        self.allocator.free(self.workspace_focus_right);
        self.allocator.free(self.workspace_focus_up);
        self.allocator.free(self.workspace_focus_down);
        self.allocator.free(self.workspace_focus_prompt);
        self.allocator.free(self.workspace_active_select);
        self.allocator.free(self.workspace_pane_select);
        self.allocator.free(self.workspace_move_left);
        self.allocator.free(self.workspace_move_right);
        self.allocator.free(self.workspace_move_up);
        self.allocator.free(self.workspace_move_down);
        self.allocator.free(self.workspace_grow_left);
        self.allocator.free(self.workspace_grow_right);
        self.allocator.free(self.workspace_grow_up);
        self.allocator.free(self.workspace_grow_down);
        self.allocator.free(self.workspace_select);
        self.prefix.deinit(self.allocator);
    }

    pub fn actionForEvent(self: *const NativeKeyboardConfig, event: *const sdl.KeyboardEvent) ?NativeKeyboardAction {
        if (matchesAny(self.refresh, event)) {
            return .refresh;
        }
        if (matchesAny(self.open_default, event)) {
            return .open_default;
        }
        if (matchesAny(self.open_editor, event)) {
            return .open_editor;
        }
        if (matchesAny(self.new_thread, event)) {
            return .new_thread;
        }
        if (matchesAny(self.command_palette, event)) {
            return .command_palette;
        }
        if (matchesAny(self.companion, event)) {
            return .companion;
        }
        if (matchesAny(self.toggle_sidebar, event)) {
            return .toggle_sidebar;
        }
        if (matchesAny(self.toggle_sidebar_hidden, event)) {
            return .toggle_sidebar_hidden;
        }
        if (matchesAny(self.toggle_browser, event)) {
            return .toggle_browser;
        }
        if (matchesAny(self.toggle_terminal, event)) {
            return .toggle_terminal;
        }
        if (matchesAny(self.chat_up, event)) {
            return .chat_up;
        }
        if (matchesAny(self.chat_down, event)) {
            return .chat_down;
        }
        if (matchesAny(self.chat_page_up, event)) {
            return .chat_page_up;
        }
        if (matchesAny(self.chat_page_down, event)) {
            return .chat_page_down;
        }
        if (matchesAny(self.workspace_previous, event)) {
            return .workspace_previous;
        }
        if (matchesAny(self.workspace_next, event)) {
            return .workspace_next;
        }
        if (matchesAny(self.workspace_active_previous, event)) {
            return .workspace_active_previous;
        }
        if (matchesAny(self.workspace_active_next, event)) {
            return .workspace_active_next;
        }
        if (matchesAny(self.workspace_pane_previous, event)) {
            return .workspace_pane_previous;
        }
        if (matchesAny(self.workspace_pane_next, event)) {
            return .workspace_pane_next;
        }
        if (matchesAny(self.workspace_split_chat_vertical, event)) {
            return .workspace_split_chat_vertical;
        }
        if (matchesAny(self.workspace_split_chat_horizontal, event)) {
            return .workspace_split_chat_horizontal;
        }
        if (matchesAny(self.workspace_split_terminal_vertical, event)) {
            return .workspace_split_terminal_vertical;
        }
        if (matchesAny(self.workspace_split_terminal_horizontal, event)) {
            return .workspace_split_terminal_horizontal;
        }
        if (matchesAny(self.workspace_toggle_maximize, event)) {
            return .workspace_toggle_maximize;
        }
        if (matchesAny(self.workspace_toggle_quick_pane, event)) {
            return .workspace_toggle_quick_pane;
        }
        if (matchesAny(self.workspace_close, event)) {
            return .workspace_close;
        }
        if (matchesAny(self.workspace_close_current, event)) {
            return .workspace_close_current;
        }
        if (matchesAny(self.workspace_focus_left, event)) {
            return .workspace_focus_left;
        }
        if (matchesAny(self.workspace_focus_right, event)) {
            return .workspace_focus_right;
        }
        if (matchesAny(self.workspace_focus_up, event)) {
            return .workspace_focus_up;
        }
        if (matchesAny(self.workspace_focus_down, event)) {
            return .workspace_focus_down;
        }
        if (matchesAny(self.workspace_move_left, event)) {
            return .workspace_move_left;
        }
        if (matchesAny(self.workspace_move_right, event)) {
            return .workspace_move_right;
        }
        if (matchesAny(self.workspace_move_up, event)) {
            return .workspace_move_up;
        }
        if (matchesAny(self.workspace_move_down, event)) {
            return .workspace_move_down;
        }
        if (matchesAny(self.workspace_grow_left, event)) {
            return .workspace_grow_left;
        }
        if (matchesAny(self.workspace_grow_right, event)) {
            return .workspace_grow_right;
        }
        if (matchesAny(self.workspace_grow_up, event)) {
            return .workspace_grow_up;
        }
        if (matchesAny(self.workspace_grow_down, event)) {
            return .workspace_grow_down;
        }

        return null;
    }

    /// True when prefix mode is enabled and this key-down is the arming chord.
    pub fn isPrefixKeyEvent(self: *const NativeKeyboardConfig, event: *const sdl.KeyboardEvent) bool {
        return self.prefix.enabled and matchesAny(self.prefix.keys, event);
    }

    /// Resolves the keypress that follows an armed prefix chord.
    pub fn prefixTargetForEvent(self: *const NativeKeyboardConfig, event: *const sdl.KeyboardEvent) ?PrefixTarget {
        return targetInTable(self.prefix.bindings.items, event);
    }

    /// Resolves a keypress while navigate mode is active. Repeats are allowed
    /// so holding an arrow walks workspaces like herdr.
    pub fn navigateTargetForEvent(self: *const NativeKeyboardConfig, event: *const sdl.KeyboardEvent) ?PrefixTarget {
        for (self.prefix.navigate.items) |binding| {
            if (binding.key.matchesAllowRepeat(event)) return binding.target;
        }
        return null;
    }

    fn targetInTable(table: []const PrefixBinding, event: *const sdl.KeyboardEvent) ?PrefixTarget {
        for (table) |binding| {
            if (binding.key.matches(event)) return binding.target;
        }
        return null;
    }

    pub fn workspaceFocusPromptForEvent(self: *const NativeKeyboardConfig, event: *const sdl.KeyboardEvent) bool {
        return matchesAny(self.workspace_focus_prompt, event);
    }

    pub fn chatActionForEvent(self: *const NativeKeyboardConfig, event: *const sdl.KeyboardEvent) ?NativeChatAction {
        if (matchesAny(self.chat_model_picker, event)) return .model_picker;
        if (matchesAny(self.chat_run_config, event)) return .run_config;
        return null;
    }

    pub fn workspaceSelectIndexForEvent(self: *const NativeKeyboardConfig, event: *const sdl.KeyboardEvent) ?usize {
        for (self.workspace_select, 0..) |binding, index| {
            if (binding.matches(event)) {
                return index;
            }
        }
        return null;
    }

    pub fn workspacePaneSelectIndexForEvent(self: *const NativeKeyboardConfig, event: *const sdl.KeyboardEvent) ?usize {
        for (self.workspace_pane_select, 0..) |binding, index| {
            if (binding.matches(event)) {
                return index;
            }
        }
        return null;
    }

    pub fn workspaceActiveSelectIndexForEvent(self: *const NativeKeyboardConfig, event: *const sdl.KeyboardEvent) ?usize {
        for (self.workspace_active_select, 0..) |binding, index| {
            if (binding.matches(event)) return index;
        }
        return null;
    }

    pub fn transcriptScrollActionForEvent(self: *const NativeKeyboardConfig, event: *const sdl.KeyboardEvent) ?NativeKeyboardAction {
        if (matchesAnyAllowRepeat(self.chat_up, event)) {
            return .chat_up;
        }
        if (matchesAnyAllowRepeat(self.chat_down, event)) {
            return .chat_down;
        }
        if (matchesAnyAllowRepeat(self.chat_page_up, event)) {
            return .chat_page_up;
        }
        if (matchesAnyAllowRepeat(self.chat_page_down, event)) {
            return .chat_page_down;
        }

        return null;
    }

    pub fn terminalActionForEvent(self: *const NativeKeyboardConfig, event: *const sdl.KeyboardEvent) ?NativeTerminalAction {
        if (matchesAny(self.terminal_new_tab, event)) {
            return .new_tab;
        }
        if (matchesAny(self.terminal_close_active, event)) {
            return .close_active;
        }
        if (matchesAny(self.terminal_rename_tab, event)) {
            return .rename_tab;
        }
        if (matchesAny(self.terminal_tab_previous, event)) {
            return .tab_previous;
        }
        if (matchesAny(self.terminal_tab_next, event)) {
            return .tab_next;
        }
        if (matchesAny(self.terminal_split_up, event)) {
            return .split_up;
        }
        if (matchesAny(self.terminal_split_down, event)) {
            return .split_down;
        }
        if (matchesAny(self.terminal_split_left, event)) {
            return .split_left;
        }
        if (matchesAny(self.terminal_split_right, event)) {
            return .split_right;
        }
        if (matchesAny(self.terminal_focus_up, event)) {
            return .focus_up;
        }
        if (matchesAny(self.terminal_focus_down, event)) {
            return .focus_down;
        }
        if (matchesAny(self.terminal_focus_left, event)) {
            return .focus_left;
        }
        if (matchesAny(self.terminal_focus_right, event)) {
            return .focus_right;
        }

        return null;
    }

    fn applyOverrides(self: *NativeKeyboardConfig, root: std.json.Value) void {
        if (root != .object) {
            log.warn("verde config must be a JSON object when present", .{});
            return;
        }

        const keybinds_value = root.object.get("keybinds") orelse return;
        if (keybinds_value != .object) {
            log.warn("keybinds must be an object when provided", .{});
            return;
        }

        if (keybinds_value.object.get("refresh")) |refresh_value| {
            if (self.parseOverrideValue(refresh_value, "refresh")) |bindings| {
                self.allocator.free(self.refresh);
                self.refresh = bindings;
            }
        }
        if (keybinds_value.object.get("open")) |open_value| {
            if (self.parseOverrideValue(open_value, "open")) |bindings| {
                self.allocator.free(self.open_default);
                self.open_default = bindings;
            }
        }
        if (keybinds_value.object.get("open_editor")) |open_editor_value| {
            if (self.parseOverrideValue(open_editor_value, "open_editor")) |bindings| {
                self.allocator.free(self.open_editor);
                self.open_editor = bindings;
            }
        }
        if (keybinds_value.object.get("new_thread")) |new_thread_value| {
            if (self.parseOverrideValue(new_thread_value, "new_thread")) |bindings| {
                self.allocator.free(self.new_thread);
                self.new_thread = bindings;
            }
        }
        if (keybinds_value.object.get("command_palette")) |palette_value| {
            if (self.parseOverrideValue(palette_value, "command_palette")) |bindings| {
                self.allocator.free(self.command_palette);
                self.command_palette = bindings;
            }
        }
        if (keybinds_value.object.get("companion")) |companion_value| {
            if (self.parseOverrideValue(companion_value, "companion")) |bindings| {
                self.allocator.free(self.companion);
                self.companion = bindings;
            }
        }
        if (keybinds_value.object.get("sidebar")) |sidebar_value| {
            if (self.parseOverrideValue(sidebar_value, "sidebar")) |bindings| {
                self.allocator.free(self.toggle_sidebar);
                self.toggle_sidebar = bindings;
            }
        }
        if (keybinds_value.object.get("sidebar_hidden")) |sidebar_hidden_value| {
            if (self.parseOverrideValue(sidebar_hidden_value, "sidebar_hidden")) |bindings| {
                self.allocator.free(self.toggle_sidebar_hidden);
                self.toggle_sidebar_hidden = bindings;
            }
        }
        if (keybinds_value.object.get("browser")) |browser_value| {
            if (self.parseOverrideValue(browser_value, "browser")) |bindings| {
                self.allocator.free(self.toggle_browser);
                self.toggle_browser = bindings;
            }
        }
        if (keybinds_value.object.get("terminal")) |terminal_value| {
            if (terminal_value == .object) {
                self.applyTerminalOverrides(terminal_value);
            } else if (self.parseOverrideValue(terminal_value, "terminal")) |bindings| {
                self.allocator.free(self.toggle_terminal);
                self.toggle_terminal = bindings;
            }
        }
        if (keybinds_value.object.get("chat")) |chat_value| {
            self.applyChatOverrides(chat_value);
        }
        if (keybinds_value.object.get("workspace")) |workspace_value| {
            self.applyWorkspaceOverrides(workspace_value);
        }
        if (keybinds_value.object.get("prefix")) |prefix_value| {
            self.applyPrefixOverrides(prefix_value);
        }
        if (keybinds_value.object.get("chat_up")) |chat_up_value| {
            if (self.parseOverrideValue(chat_up_value, "chat_up")) |bindings| {
                self.allocator.free(self.chat_up);
                self.chat_up = bindings;
            }
        }
        if (keybinds_value.object.get("chat_down")) |chat_down_value| {
            if (self.parseOverrideValue(chat_down_value, "chat_down")) |bindings| {
                self.allocator.free(self.chat_down);
                self.chat_down = bindings;
            }
        }
        if (keybinds_value.object.get("chat_page_up")) |chat_page_up_value| {
            if (self.parseOverrideValue(chat_page_up_value, "chat_page_up")) |bindings| {
                self.allocator.free(self.chat_page_up);
                self.chat_page_up = bindings;
            }
        }
        if (keybinds_value.object.get("chat_page_down")) |chat_page_down_value| {
            if (self.parseOverrideValue(chat_page_down_value, "chat_page_down")) |bindings| {
                self.allocator.free(self.chat_page_down);
                self.chat_page_down = bindings;
            }
        }
    }

    fn applyChatOverrides(self: *NativeKeyboardConfig, chat_value: std.json.Value) void {
        if (chat_value != .object) {
            log.warn("keybinds.chat must be an object when provided", .{});
            return;
        }
        if (chat_value.object.get("model_picker")) |value| {
            if (self.parseOverrideValue(value, "chat.model_picker")) |bindings| {
                self.allocator.free(self.chat_model_picker);
                self.chat_model_picker = bindings;
            }
        }
        if (chat_value.object.get("run_config")) |value| {
            if (self.parseOverrideValue(value, "chat.run_config")) |bindings| {
                self.allocator.free(self.chat_run_config);
                self.chat_run_config = bindings;
            }
        }
    }

    fn applyTerminalOverrides(self: *NativeKeyboardConfig, terminal_value: std.json.Value) void {
        if (terminal_value != .object) {
            log.warn("keybinds.terminal must be an object when provided", .{});
            return;
        }

        if (terminal_value.object.get("toggle")) |value| {
            if (self.parseOverrideValue(value, "terminal.toggle")) |bindings| {
                self.allocator.free(self.toggle_terminal);
                self.toggle_terminal = bindings;
            }
        }
        if (terminal_value.object.get("new_tab")) |value| {
            if (self.parseOverrideValue(value, "terminal.new_tab")) |bindings| {
                self.allocator.free(self.terminal_new_tab);
                self.terminal_new_tab = bindings;
            }
        }
        if (terminal_value.object.get("close")) |value| {
            if (self.parseOverrideValue(value, "terminal.close")) |bindings| {
                self.allocator.free(self.terminal_close_active);
                self.terminal_close_active = bindings;
            }
        }
        if (terminal_value.object.get("rename_tab")) |value| {
            if (self.parseOverrideValue(value, "terminal.rename_tab")) |bindings| {
                self.allocator.free(self.terminal_rename_tab);
                self.terminal_rename_tab = bindings;
            }
        }
        if (terminal_value.object.get("tab_previous")) |value| {
            if (self.parseOverrideValue(value, "terminal.tab_previous")) |bindings| {
                self.allocator.free(self.terminal_tab_previous);
                self.terminal_tab_previous = bindings;
            }
        }
        if (terminal_value.object.get("tab_next")) |value| {
            if (self.parseOverrideValue(value, "terminal.tab_next")) |bindings| {
                self.allocator.free(self.terminal_tab_next);
                self.terminal_tab_next = bindings;
            }
        }
        if (terminal_value.object.get("split_up")) |value| {
            if (self.parseOverrideValue(value, "terminal.split_up")) |bindings| {
                self.allocator.free(self.terminal_split_up);
                self.terminal_split_up = bindings;
            }
        }
        if (terminal_value.object.get("split_down")) |value| {
            if (self.parseOverrideValue(value, "terminal.split_down")) |bindings| {
                self.allocator.free(self.terminal_split_down);
                self.terminal_split_down = bindings;
            }
        }
        if (terminal_value.object.get("split_left")) |value| {
            if (self.parseOverrideValue(value, "terminal.split_left")) |bindings| {
                self.allocator.free(self.terminal_split_left);
                self.terminal_split_left = bindings;
            }
        }
        if (terminal_value.object.get("split_right")) |value| {
            if (self.parseOverrideValue(value, "terminal.split_right")) |bindings| {
                self.allocator.free(self.terminal_split_right);
                self.terminal_split_right = bindings;
            }
        }
        if (terminal_value.object.get("focus_up")) |value| {
            if (self.parseOverrideValue(value, "terminal.focus_up")) |bindings| {
                self.allocator.free(self.terminal_focus_up);
                self.terminal_focus_up = bindings;
            }
        }
        if (terminal_value.object.get("focus_down")) |value| {
            if (self.parseOverrideValue(value, "terminal.focus_down")) |bindings| {
                self.allocator.free(self.terminal_focus_down);
                self.terminal_focus_down = bindings;
            }
        }
        if (terminal_value.object.get("focus_left")) |value| {
            if (self.parseOverrideValue(value, "terminal.focus_left")) |bindings| {
                self.allocator.free(self.terminal_focus_left);
                self.terminal_focus_left = bindings;
            }
        }
        if (terminal_value.object.get("focus_right")) |value| {
            if (self.parseOverrideValue(value, "terminal.focus_right")) |bindings| {
                self.allocator.free(self.terminal_focus_right);
                self.terminal_focus_right = bindings;
            }
        }
    }

    fn applyWorkspaceOverrides(self: *NativeKeyboardConfig, workspace_value: std.json.Value) void {
        if (workspace_value != .object) {
            log.warn("keybinds.workspace must be an object when provided", .{});
            return;
        }
        if (workspace_value.object.get("split_chat_vertical")) |value| {
            if (self.parseOverrideValue(value, "workspace.split_chat_vertical")) |bindings| {
                self.allocator.free(self.workspace_split_chat_vertical);
                self.workspace_split_chat_vertical = bindings;
            }
        }
        if (workspace_value.object.get("split_chat_horizontal")) |value| {
            if (self.parseOverrideValue(value, "workspace.split_chat_horizontal")) |bindings| {
                self.allocator.free(self.workspace_split_chat_horizontal);
                self.workspace_split_chat_horizontal = bindings;
            }
        }
        if (workspace_value.object.get("split_terminal_vertical")) |value| {
            if (self.parseOverrideValue(value, "workspace.split_terminal_vertical")) |bindings| {
                self.allocator.free(self.workspace_split_terminal_vertical);
                self.workspace_split_terminal_vertical = bindings;
            }
        }
        if (workspace_value.object.get("split_terminal_horizontal")) |value| {
            if (self.parseOverrideValue(value, "workspace.split_terminal_horizontal")) |bindings| {
                self.allocator.free(self.workspace_split_terminal_horizontal);
                self.workspace_split_terminal_horizontal = bindings;
            }
        }
        if (workspace_value.object.get("toggle_maximize")) |value| {
            if (self.parseOverrideValue(value, "workspace.toggle_maximize")) |bindings| {
                self.allocator.free(self.workspace_toggle_maximize);
                self.workspace_toggle_maximize = bindings;
            }
        }
        if (workspace_value.object.get("toggle_quick_pane")) |value| {
            if (self.parseOverrideValue(value, "workspace.toggle_quick_pane")) |bindings| {
                self.allocator.free(self.workspace_toggle_quick_pane);
                self.workspace_toggle_quick_pane = bindings;
            }
        }
        if (workspace_value.object.get("close")) |value| {
            if (self.parseOverrideValue(value, "workspace.close")) |bindings| {
                self.allocator.free(self.workspace_close);
                self.workspace_close = bindings;
            }
        }
        if (workspace_value.object.get("close_current")) |value| {
            if (self.parseOverrideValue(value, "workspace.close_current")) |bindings| {
                self.allocator.free(self.workspace_close_current);
                self.workspace_close_current = bindings;
            }
        }
        if (workspace_value.object.get("focus_left")) |value| {
            if (self.parseOverrideValue(value, "workspace.focus_left")) |bindings| {
                self.allocator.free(self.workspace_focus_left);
                self.workspace_focus_left = bindings;
            }
        }
        if (workspace_value.object.get("focus_right")) |value| {
            if (self.parseOverrideValue(value, "workspace.focus_right")) |bindings| {
                self.allocator.free(self.workspace_focus_right);
                self.workspace_focus_right = bindings;
            }
        }
        if (workspace_value.object.get("focus_up")) |value| {
            if (self.parseOverrideValue(value, "workspace.focus_up")) |bindings| {
                self.allocator.free(self.workspace_focus_up);
                self.workspace_focus_up = bindings;
            }
        }
        if (workspace_value.object.get("focus_down")) |value| {
            if (self.parseOverrideValue(value, "workspace.focus_down")) |bindings| {
                self.allocator.free(self.workspace_focus_down);
                self.workspace_focus_down = bindings;
            }
        }
        if (workspace_value.object.get("focus_prompt")) |value| {
            if (self.parseOverrideValue(value, "workspace.focus_prompt")) |bindings| {
                self.allocator.free(self.workspace_focus_prompt);
                self.workspace_focus_prompt = bindings;
            }
        }
        if (workspace_value.object.get("active_select")) |value| {
            if (self.parseOverrideValue(value, "workspace.active_select")) |bindings| {
                self.allocator.free(self.workspace_active_select);
                self.workspace_active_select = bindings;
            }
        }
        if (workspace_value.object.get("pane_select")) |value| {
            if (self.parseOverrideValue(value, "workspace.pane_select")) |bindings| {
                self.allocator.free(self.workspace_pane_select);
                self.workspace_pane_select = bindings;
            }
        }
        if (workspace_value.object.get("move_left")) |value| {
            if (self.parseOverrideValue(value, "workspace.move_left")) |bindings| {
                self.allocator.free(self.workspace_move_left);
                self.workspace_move_left = bindings;
            }
        }
        if (workspace_value.object.get("move_right")) |value| {
            if (self.parseOverrideValue(value, "workspace.move_right")) |bindings| {
                self.allocator.free(self.workspace_move_right);
                self.workspace_move_right = bindings;
            }
        }
        if (workspace_value.object.get("move_up")) |value| {
            if (self.parseOverrideValue(value, "workspace.move_up")) |bindings| {
                self.allocator.free(self.workspace_move_up);
                self.workspace_move_up = bindings;
            }
        }
        if (workspace_value.object.get("move_down")) |value| {
            if (self.parseOverrideValue(value, "workspace.move_down")) |bindings| {
                self.allocator.free(self.workspace_move_down);
                self.workspace_move_down = bindings;
            }
        }
        if (workspace_value.object.get("grow_left")) |value| {
            if (self.parseOverrideValue(value, "workspace.grow_left")) |bindings| {
                self.allocator.free(self.workspace_grow_left);
                self.workspace_grow_left = bindings;
            }
        }
        if (workspace_value.object.get("grow_right")) |value| {
            if (self.parseOverrideValue(value, "workspace.grow_right")) |bindings| {
                self.allocator.free(self.workspace_grow_right);
                self.workspace_grow_right = bindings;
            }
        }
        if (workspace_value.object.get("grow_up")) |value| {
            if (self.parseOverrideValue(value, "workspace.grow_up")) |bindings| {
                self.allocator.free(self.workspace_grow_up);
                self.workspace_grow_up = bindings;
            }
        }
        if (workspace_value.object.get("grow_down")) |value| {
            if (self.parseOverrideValue(value, "workspace.grow_down")) |bindings| {
                self.allocator.free(self.workspace_grow_down);
                self.workspace_grow_down = bindings;
            }
        }
        if (workspace_value.object.get("select")) |value| {
            if (self.parseOverrideValue(value, "workspace.select")) |bindings| {
                self.allocator.free(self.workspace_select);
                self.workspace_select = bindings;
            }
        }
        if (workspace_value.object.get("previous")) |value| {
            if (self.parseOverrideValue(value, "workspace.previous")) |bindings| {
                self.allocator.free(self.workspace_previous);
                self.workspace_previous = bindings;
            }
        }
        if (workspace_value.object.get("next")) |value| {
            if (self.parseOverrideValue(value, "workspace.next")) |bindings| {
                self.allocator.free(self.workspace_next);
                self.workspace_next = bindings;
            }
        }
        if (workspace_value.object.get("active_previous")) |value| {
            if (self.parseOverrideValue(value, "workspace.active_previous")) |bindings| {
                self.allocator.free(self.workspace_active_previous);
                self.workspace_active_previous = bindings;
            }
        }
        if (workspace_value.object.get("active_next")) |value| {
            if (self.parseOverrideValue(value, "workspace.active_next")) |bindings| {
                self.allocator.free(self.workspace_active_next);
                self.workspace_active_next = bindings;
            }
        }
        if (workspace_value.object.get("pane_previous")) |value| {
            if (self.parseOverrideValue(value, "workspace.pane_previous")) |bindings| {
                self.allocator.free(self.workspace_pane_previous);
                self.workspace_pane_previous = bindings;
            }
        }
        if (workspace_value.object.get("pane_next")) |value| {
            if (self.parseOverrideValue(value, "workspace.pane_next")) |bindings| {
                self.allocator.free(self.workspace_pane_next);
                self.workspace_pane_next = bindings;
            }
        }
    }

    /// `keybinds.prefix` accepts `true`/`false` (toggle with defaults), a bare
    /// accelerator string (enable with that chord), or an object with
    /// `enabled`, `key`, `defaults`, and `bindings`.
    fn applyPrefixOverrides(self: *NativeKeyboardConfig, value: std.json.Value) void {
        switch (value) {
            .bool => |enabled| {
                self.prefix.enabled = enabled;
                return;
            },
            .string => {
                if (self.parseOverrideValue(value, "prefix")) |keys| {
                    self.allocator.free(self.prefix.keys);
                    self.prefix.keys = keys;
                }
                self.prefix.enabled = self.prefix.keys.len > 0;
                return;
            },
            .object => {},
            else => {
                log.warn("keybinds.prefix must be a bool, accelerator string, or object when provided", .{});
                return;
            },
        }

        const object = value.object;
        if (object.get("enabled")) |enabled_value| {
            if (enabled_value == .bool) {
                self.prefix.enabled = enabled_value.bool;
            } else {
                log.warn("keybinds.prefix.enabled must be a bool", .{});
            }
        }
        if (object.get("key")) |key_value| {
            if (self.parseOverrideValue(key_value, "prefix.key")) |keys| {
                self.allocator.free(self.prefix.keys);
                self.prefix.keys = keys;
            }
        }
        if (object.get("defaults")) |defaults_value| {
            if (defaults_value == .bool) {
                if (!defaults_value.bool) {
                    self.clearPrefixTable(&self.prefix.bindings);
                    self.clearPrefixTable(&self.prefix.navigate);
                }
            } else {
                log.warn("keybinds.prefix.defaults must be a bool", .{});
            }
        }
        if (object.get("bindings")) |bindings_value| {
            self.applyPrefixBindingOverrides(&self.prefix.bindings, bindings_value, "bindings");
        }
        if (object.get("navigate")) |navigate_value| {
            self.applyPrefixBindingOverrides(&self.prefix.navigate, navigate_value, "navigate");
        }
        if (self.prefix.enabled and self.prefix.keys.len == 0) {
            log.warn("keybinds.prefix.enabled is true but prefix.key is empty; prefix mode stays off", .{});
            self.prefix.enabled = false;
        }
    }

    fn clearPrefixTable(self: *NativeKeyboardConfig, table: *std.ArrayList(PrefixBinding)) void {
        for (table.items) |binding| binding.target.deinit(self.allocator);
        table.clearRetainingCapacity();
    }

    /// Entries are keyed by accelerator. A user entry replaces the default on
    /// the same chord; `null`/empty removes it; unknown chords are added.
    fn applyPrefixBindingOverrides(
        self: *NativeKeyboardConfig,
        table: *std.ArrayList(PrefixBinding),
        bindings_value: std.json.Value,
        comptime table_name: []const u8,
    ) void {
        if (bindings_value != .object) {
            log.warn("keybinds.prefix.{s} must be an object when provided", .{table_name});
            return;
        }

        var it = bindings_value.object.iterator();
        while (it.next()) |entry| {
            const raw_key = entry.key_ptr.*;
            const key = parseAccelerator(raw_key) orelse {
                log.warn("ignoring invalid prefix binding key value_len={d}", .{raw_key.len});
                continue;
            };
            self.removePrefixBinding(table, key);
            const target = self.parsePrefixTargetValue(entry.value_ptr.*, raw_key) orelse continue;
            table.append(self.allocator, .{ .key = key, .target = target }) catch {
                target.deinit(self.allocator);
                log.warn("failed to store prefix binding", .{});
            };
        }
    }

    fn removePrefixBinding(self: *NativeKeyboardConfig, table: *std.ArrayList(PrefixBinding), key: Keybind) void {
        var index: usize = 0;
        while (index < table.items.len) {
            if (table.items[index].key.eql(key)) {
                table.items[index].target.deinit(self.allocator);
                _ = table.swapRemove(index);
                continue;
            }
            index += 1;
        }
    }

    fn parsePrefixTargetValue(self: *const NativeKeyboardConfig, value: std.json.Value, key_label: []const u8) ?PrefixTarget {
        switch (value) {
            .null => return null,
            .string => |name| {
                const trimmed = std.mem.trim(u8, name, &std.ascii.whitespace);
                if (trimmed.len == 0) return null;
                return parsePrefixActionName(trimmed) orelse {
                    log.warn("unknown prefix action for {s}: {s}", .{ key_label, trimmed });
                    return null;
                };
            },
            .object => |object| {
                if (object.get("command")) |command_value| {
                    if (command_value != .string) {
                        log.warn("prefix binding {s}: command must be a string", .{key_label});
                        return null;
                    }
                    const script = std.mem.trim(u8, command_value.string, &std.ascii.whitespace);
                    if (script.len == 0) {
                        log.warn("prefix binding {s}: command must not be empty", .{key_label});
                        return null;
                    }
                    const owned = self.allocator.dupe(u8, script) catch return null;
                    return .{ .command = owned };
                }
                if (object.get("action")) |action_value| {
                    return self.parsePrefixTargetValue(action_value, key_label);
                }
                log.warn("prefix binding {s}: object needs an action or command", .{key_label});
                return null;
            },
            else => {
                log.warn("prefix binding {s} must be an action name, object, or null", .{key_label});
                return null;
            },
        }
    }

    fn parseOverrideValue(self: *const NativeKeyboardConfig, value: std.json.Value, comptime field_name: []const u8) ?[]Keybind {
        return switch (value) {
            .null => self.allocator.alloc(Keybind, 0) catch null,
            .string => |binding| self.parseSingleBinding(binding, field_name),
            .array => |items| self.parseBindingArray(items.items, field_name),
            else => blk: {
                log.warn("keybinds.{s} must be a string, string array, null, or omitted", .{field_name});
                break :blk null;
            },
        };
    }

    fn parseSingleBinding(self: *const NativeKeyboardConfig, binding: []const u8, comptime field_name: []const u8) ?[]Keybind {
        const trimmed = std.mem.trim(u8, binding, &std.ascii.whitespace);
        if (trimmed.len == 0) {
            return self.allocator.alloc(Keybind, 0) catch null;
        }

        const parsed = parseAccelerator(trimmed) orelse {
            log.warn("ignoring invalid keybind for {s} value_len={d}", .{ field_name, trimmed.len });
            return self.allocator.alloc(Keybind, 0) catch null;
        };

        const bindings = self.allocator.alloc(Keybind, 1) catch return null;
        bindings[0] = parsed;
        return bindings;
    }

    fn parseBindingArray(self: *const NativeKeyboardConfig, values: []const std.json.Value, comptime field_name: []const u8) ?[]Keybind {
        if (values.len == 0) {
            return self.allocator.alloc(Keybind, 0) catch null;
        }

        var parsed: std.ArrayList(Keybind) = .empty;
        defer parsed.deinit(self.allocator);

        for (values) |value| {
            if (value != .string) {
                log.warn("ignoring non-string keybind entry for {s}", .{field_name});
                continue;
            }

            const trimmed = std.mem.trim(u8, value.string, &std.ascii.whitespace);
            if (trimmed.len == 0) {
                continue;
            }

            const binding = parseAccelerator(trimmed) orelse {
                log.warn("ignoring invalid keybind for {s} value_len={d}", .{ field_name, trimmed.len });
                continue;
            };

            if (containsKeybind(parsed.items, binding)) {
                continue;
            }

            parsed.append(self.allocator, binding) catch return null;
        }

        if (parsed.items.len == 0) {
            log.warn("keybinds.{s} did not contain any valid accelerators", .{field_name});
        }

        return parsed.toOwnedSlice(self.allocator) catch null;
    }
};

const PrefixActionName = struct { name: []const u8, target: PrefixTarget };

/// Action names accepted under `keybinds.prefix.bindings`. They mirror the
/// direct-keybind config keys so one vocabulary covers both tables.
const PREFIX_ACTION_NAMES = [_]PrefixActionName{
    .{ .name = "refresh", .target = .{ .app = .refresh } },
    .{ .name = "open", .target = .{ .app = .open_default } },
    .{ .name = "open_default", .target = .{ .app = .open_default } },
    .{ .name = "open_editor", .target = .{ .app = .open_editor } },
    .{ .name = "new_thread", .target = .{ .app = .new_thread } },
    .{ .name = "command_palette", .target = .{ .app = .command_palette } },
    .{ .name = "companion", .target = .{ .app = .companion } },
    .{ .name = "sidebar", .target = .{ .app = .toggle_sidebar } },
    .{ .name = "sidebar_hidden", .target = .{ .app = .toggle_sidebar_hidden } },
    .{ .name = "browser", .target = .{ .app = .toggle_browser } },
    .{ .name = "chat_up", .target = .{ .app = .chat_up } },
    .{ .name = "chat_down", .target = .{ .app = .chat_down } },
    .{ .name = "chat_page_up", .target = .{ .app = .chat_page_up } },
    .{ .name = "chat_page_down", .target = .{ .app = .chat_page_down } },
    .{ .name = "chat.model_picker", .target = .{ .chat = .model_picker } },
    .{ .name = "chat.run_config", .target = .{ .chat = .run_config } },
    .{ .name = "terminal.toggle", .target = .{ .app = .toggle_terminal } },
    .{ .name = "terminal.new_tab", .target = .{ .terminal = .new_tab } },
    .{ .name = "terminal.close", .target = .{ .terminal = .close_active } },
    .{ .name = "terminal.rename_tab", .target = .{ .terminal = .rename_tab } },
    .{ .name = "terminal.tab_previous", .target = .{ .terminal = .tab_previous } },
    .{ .name = "terminal.tab_next", .target = .{ .terminal = .tab_next } },
    .{ .name = "terminal.split_up", .target = .{ .terminal = .split_up } },
    .{ .name = "terminal.split_down", .target = .{ .terminal = .split_down } },
    .{ .name = "terminal.split_left", .target = .{ .terminal = .split_left } },
    .{ .name = "terminal.split_right", .target = .{ .terminal = .split_right } },
    .{ .name = "terminal.focus_up", .target = .{ .terminal = .focus_up } },
    .{ .name = "terminal.focus_down", .target = .{ .terminal = .focus_down } },
    .{ .name = "terminal.focus_left", .target = .{ .terminal = .focus_left } },
    .{ .name = "terminal.focus_right", .target = .{ .terminal = .focus_right } },
    .{ .name = "workspace.split_default_vertical", .target = .split_default_vertical },
    .{ .name = "workspace.split_default_horizontal", .target = .split_default_horizontal },
    .{ .name = "workspace.split_alternate_vertical", .target = .split_alternate_vertical },
    .{ .name = "workspace.split_alternate_horizontal", .target = .split_alternate_horizontal },
    .{ .name = "workspace.split_chat_vertical", .target = .{ .app = .workspace_split_chat_vertical } },
    .{ .name = "workspace.split_chat_horizontal", .target = .{ .app = .workspace_split_chat_horizontal } },
    .{ .name = "workspace.split_terminal_vertical", .target = .{ .app = .workspace_split_terminal_vertical } },
    .{ .name = "workspace.split_terminal_horizontal", .target = .{ .app = .workspace_split_terminal_horizontal } },
    .{ .name = "workspace.toggle_maximize", .target = .{ .app = .workspace_toggle_maximize } },
    .{ .name = "workspace.toggle_quick_pane", .target = .{ .app = .workspace_toggle_quick_pane } },
    .{ .name = "workspace.close", .target = .{ .app = .workspace_close } },
    .{ .name = "workspace.close_current", .target = .{ .app = .workspace_close_current } },
    .{ .name = "workspace.focus_left", .target = .{ .app = .workspace_focus_left } },
    .{ .name = "workspace.focus_right", .target = .{ .app = .workspace_focus_right } },
    .{ .name = "workspace.focus_up", .target = .{ .app = .workspace_focus_up } },
    .{ .name = "workspace.focus_down", .target = .{ .app = .workspace_focus_down } },
    .{ .name = "workspace.focus_prompt", .target = .focus_prompt },
    .{ .name = "prefix.keybinds", .target = .show_keybinds },
    .{ .name = "prefix.navigate", .target = .navigate },
    .{ .name = "workspace.previous", .target = .{ .app = .workspace_previous } },
    .{ .name = "workspace.next", .target = .{ .app = .workspace_next } },
    .{ .name = "workspace.active_previous", .target = .{ .app = .workspace_active_previous } },
    .{ .name = "workspace.active_next", .target = .{ .app = .workspace_active_next } },
    .{ .name = "workspace.pane_previous", .target = .{ .app = .workspace_pane_previous } },
    .{ .name = "workspace.pane_next", .target = .{ .app = .workspace_pane_next } },
    .{ .name = "workspace.move_left", .target = .{ .app = .workspace_move_left } },
    .{ .name = "workspace.move_right", .target = .{ .app = .workspace_move_right } },
    .{ .name = "workspace.move_up", .target = .{ .app = .workspace_move_up } },
    .{ .name = "workspace.move_down", .target = .{ .app = .workspace_move_down } },
    .{ .name = "workspace.grow_left", .target = .{ .app = .workspace_grow_left } },
    .{ .name = "workspace.grow_right", .target = .{ .app = .workspace_grow_right } },
    .{ .name = "workspace.grow_up", .target = .{ .app = .workspace_grow_up } },
    .{ .name = "workspace.grow_down", .target = .{ .app = .workspace_grow_down } },
};

/// Resolves a prefix action name. Positional actions take a 1-based ordinal
/// suffix: `workspace.select.3`, `workspace.pane_select.1`,
/// `workspace.active_select.2`.
pub fn parsePrefixActionName(raw: []const u8) ?PrefixTarget {
    const name = std.mem.trim(u8, raw, &std.ascii.whitespace);
    for (PREFIX_ACTION_NAMES) |entry| {
        if (std.ascii.eqlIgnoreCase(entry.name, name)) return entry.target;
    }
    if (parseOrdinalSuffix(name, "workspace.select.")) |index| return .{ .workspace_select = index };
    if (parseOrdinalSuffix(name, "workspace.pane_select.")) |index| return .{ .pane_select = index };
    if (parseOrdinalSuffix(name, "workspace.active_select.")) |index| return .{ .active_select = index };
    return null;
}

/// Short human label for the which-key overlay. Scripts show their text so a
/// user can recognise their own bindings without a label field.
pub fn prefixTargetLabel(buf: []u8, target: PrefixTarget) []const u8 {
    return switch (target) {
        .app => |action| switch (action) {
            .refresh => "Reload app",
            .open_default => "Open project",
            .open_editor => "Open in editor",
            .new_thread => "New thread",
            .command_palette => "Command palette",
            .companion => "Companion",
            .toggle_sidebar => "Sidebar",
            .toggle_sidebar_hidden => "Hide sidebar",
            .toggle_browser => "Browser",
            .toggle_terminal => "Terminal",
            .chat_up => "Scroll up",
            .chat_down => "Scroll down",
            .chat_page_up => "Page up",
            .chat_page_down => "Page down",
            .workspace_previous => "Prev workspace",
            .workspace_next => "Next workspace",
            .workspace_active_previous => "Prev active",
            .workspace_active_next => "Next active",
            .workspace_pane_previous => "Prev pane",
            .workspace_pane_next => "Next pane",
            .workspace_split_chat_vertical => "Chat split |",
            .workspace_split_chat_horizontal => "Chat split -",
            .workspace_split_terminal_vertical => "Term split |",
            .workspace_split_terminal_horizontal => "Term split -",
            .workspace_toggle_maximize => "Zoom pane",
            .workspace_toggle_quick_pane => "Quick pane",
            .workspace_close => "Close pane",
            .workspace_close_current => "Close workspace",
            .workspace_focus_left => "Focus left",
            .workspace_focus_right => "Focus right",
            .workspace_focus_up => "Focus up",
            .workspace_focus_down => "Focus down",
            .workspace_move_left => "Move left",
            .workspace_move_right => "Move right",
            .workspace_move_up => "Move up",
            .workspace_move_down => "Move down",
            .workspace_grow_left => "Grow left",
            .workspace_grow_right => "Grow right",
            .workspace_grow_up => "Grow up",
            .workspace_grow_down => "Grow down",
        },
        .terminal => |action| switch (action) {
            .new_tab => "Term: new tab",
            .close_active => "Term: close",
            .rename_tab => "Term: rename tab",
            .tab_previous => "Term: prev tab",
            .tab_next => "Term: next tab",
            .split_up => "Term: split up",
            .split_down => "Term: split down",
            .split_left => "Term: split left",
            .split_right => "Term: split right",
            .focus_up => "Term: focus up",
            .focus_down => "Term: focus down",
            .focus_left => "Term: focus left",
            .focus_right => "Term: focus right",
        },
        .split_default_vertical => "Default split |",
        .split_default_horizontal => "Default split -",
        .split_alternate_vertical => "Alternate split |",
        .split_alternate_horizontal => "Alternate split -",
        .chat => |action| switch (action) {
            .model_picker => "Model picker",
            .run_config => "Run settings",
        },
        .focus_prompt => "Focus prompt",
        .show_keybinds => "Keybinds",
        .navigate => "Workspace nav",
        .workspace_select => |index| std.fmt.bufPrint(buf, "Workspace {d}", .{index + 1}) catch "Workspace",
        .pane_select => |index| std.fmt.bufPrint(buf, "Pane {d}", .{index + 1}) catch "Pane",
        .active_select => |index| std.fmt.bufPrint(buf, "Active row {d}", .{index + 1}) catch "Active row",
        .command => |script| std.fmt.bufPrint(buf, "$ {s}", .{script}) catch "$ script",
    };
}

fn parseOrdinalSuffix(name: []const u8, comptime head: []const u8) ?usize {
    if (!std.ascii.startsWithIgnoreCase(name, head)) return null;
    const ordinal = std.fmt.parseUnsigned(usize, name[head.len..], 10) catch return null;
    if (ordinal == 0) return null;
    return ordinal - 1;
}

const DefaultPrefixEntry = struct { accelerator: []const u8, target: []const u8 };

/// Default prefix table. Every built-in command has a seat here so enabling
/// prefix mode alone exposes the whole command surface. Letters follow tmux
/// where a tmux habit exists (`x` close, `z` zoom, `,` rename, `[`/`]`
/// traversal, digits select); Shift flips a command to its sibling and Ctrl
/// to its resize/positional variant.
const DEFAULT_PREFIX_TABLE = [_]DefaultPrefixEntry{
    // Help / modes
    .{ .accelerator = "Shift+Slash", .target = "prefix.keybinds" },
    .{ .accelerator = "W", .target = "prefix.navigate" },
    // App
    .{ .accelerator = "P", .target = "command_palette" },
    .{ .accelerator = "T", .target = "new_thread" },
    .{ .accelerator = "R", .target = "refresh" },
    .{ .accelerator = "O", .target = "open" },
    .{ .accelerator = "E", .target = "open_editor" },
    .{ .accelerator = "Space", .target = "companion" },
    .{ .accelerator = "S", .target = "sidebar" },
    .{ .accelerator = "Shift+S", .target = "sidebar_hidden" },
    .{ .accelerator = "B", .target = "browser" },
    .{ .accelerator = "Grave", .target = "terminal.toggle" },
    .{ .accelerator = "Q", .target = "workspace.toggle_quick_pane" },
    // Panes
    .{ .accelerator = "X", .target = "workspace.close" },
    .{ .accelerator = "Shift+X", .target = "workspace.close_current" },
    .{ .accelerator = "Z", .target = "workspace.toggle_maximize" },
    .{ .accelerator = "I", .target = "workspace.focus_prompt" },
    .{ .accelerator = "C", .target = "workspace.split_chat_vertical" },
    .{ .accelerator = "Shift+C", .target = "workspace.split_chat_horizontal" },
    .{ .accelerator = "V", .target = "workspace.split_default_vertical" },
    .{ .accelerator = "Minus", .target = "workspace.split_default_horizontal" },
    .{ .accelerator = "Shift+V", .target = "workspace.split_alternate_vertical" },
    .{ .accelerator = "Shift+Minus", .target = "workspace.split_alternate_horizontal" },
    .{ .accelerator = "H", .target = "workspace.focus_left" },
    .{ .accelerator = "J", .target = "workspace.focus_down" },
    .{ .accelerator = "K", .target = "workspace.focus_up" },
    .{ .accelerator = "L", .target = "workspace.focus_right" },
    .{ .accelerator = "Left", .target = "workspace.focus_left" },
    .{ .accelerator = "Down", .target = "workspace.focus_down" },
    .{ .accelerator = "Up", .target = "workspace.focus_up" },
    .{ .accelerator = "Right", .target = "workspace.focus_right" },
    .{ .accelerator = "Shift+H", .target = "workspace.move_left" },
    .{ .accelerator = "Shift+J", .target = "workspace.move_down" },
    .{ .accelerator = "Shift+K", .target = "workspace.move_up" },
    .{ .accelerator = "Shift+L", .target = "workspace.move_right" },
    .{ .accelerator = "Ctrl+H", .target = "workspace.grow_left" },
    .{ .accelerator = "Ctrl+J", .target = "workspace.grow_down" },
    .{ .accelerator = "Ctrl+K", .target = "workspace.grow_up" },
    .{ .accelerator = "Ctrl+L", .target = "workspace.grow_right" },
    .{ .accelerator = "Ctrl+Left", .target = "workspace.grow_left" },
    .{ .accelerator = "Ctrl+Down", .target = "workspace.grow_down" },
    .{ .accelerator = "Ctrl+Up", .target = "workspace.grow_up" },
    .{ .accelerator = "Ctrl+Right", .target = "workspace.grow_right" },
    .{ .accelerator = "N", .target = "workspace.pane_next" },
    .{ .accelerator = "Shift+N", .target = "workspace.pane_previous" },
    .{ .accelerator = "LeftBracket", .target = "workspace.previous" },
    .{ .accelerator = "RightBracket", .target = "workspace.next" },
    .{ .accelerator = "Shift+LeftBracket", .target = "workspace.active_previous" },
    .{ .accelerator = "Shift+RightBracket", .target = "workspace.active_next" },
    .{ .accelerator = "1", .target = "workspace.pane_select.1" },
    .{ .accelerator = "2", .target = "workspace.pane_select.2" },
    .{ .accelerator = "3", .target = "workspace.pane_select.3" },
    .{ .accelerator = "4", .target = "workspace.pane_select.4" },
    .{ .accelerator = "5", .target = "workspace.pane_select.5" },
    .{ .accelerator = "6", .target = "workspace.pane_select.6" },
    .{ .accelerator = "7", .target = "workspace.pane_select.7" },
    .{ .accelerator = "8", .target = "workspace.pane_select.8" },
    .{ .accelerator = "9", .target = "workspace.pane_select.9" },
    .{ .accelerator = "0", .target = "workspace.pane_select.10" },
    .{ .accelerator = "Shift+1", .target = "workspace.select.1" },
    .{ .accelerator = "Shift+2", .target = "workspace.select.2" },
    .{ .accelerator = "Shift+3", .target = "workspace.select.3" },
    .{ .accelerator = "Shift+4", .target = "workspace.select.4" },
    .{ .accelerator = "Shift+5", .target = "workspace.select.5" },
    .{ .accelerator = "Shift+6", .target = "workspace.select.6" },
    .{ .accelerator = "Shift+7", .target = "workspace.select.7" },
    .{ .accelerator = "Shift+8", .target = "workspace.select.8" },
    .{ .accelerator = "Shift+9", .target = "workspace.select.9" },
    .{ .accelerator = "Shift+0", .target = "workspace.select.10" },
    .{ .accelerator = "Ctrl+1", .target = "workspace.active_select.1" },
    .{ .accelerator = "Ctrl+2", .target = "workspace.active_select.2" },
    .{ .accelerator = "Ctrl+3", .target = "workspace.active_select.3" },
    .{ .accelerator = "Ctrl+4", .target = "workspace.active_select.4" },
    .{ .accelerator = "Ctrl+5", .target = "workspace.active_select.5" },
    .{ .accelerator = "Ctrl+6", .target = "workspace.active_select.6" },
    .{ .accelerator = "Ctrl+7", .target = "workspace.active_select.7" },
    .{ .accelerator = "Ctrl+8", .target = "workspace.active_select.8" },
    .{ .accelerator = "Ctrl+9", .target = "workspace.active_select.9" },
    .{ .accelerator = "Ctrl+0", .target = "workspace.active_select.10" },
    // Chat
    .{ .accelerator = "Shift+Up", .target = "chat_up" },
    .{ .accelerator = "Shift+Down", .target = "chat_down" },
    .{ .accelerator = "PageUp", .target = "chat_page_up" },
    .{ .accelerator = "PageDown", .target = "chat_page_down" },
    .{ .accelerator = "M", .target = "chat.model_picker" },
    .{ .accelerator = "Shift+M", .target = "chat.run_config" },
    // Terminal (only while a terminal pane is focused)
    .{ .accelerator = "Ctrl+T", .target = "terminal.new_tab" },
    .{ .accelerator = "Shift+W", .target = "terminal.close" },
    .{ .accelerator = "Comma", .target = "terminal.rename_tab" },
    .{ .accelerator = "Ctrl+PageUp", .target = "terminal.tab_previous" },
    .{ .accelerator = "Ctrl+PageDown", .target = "terminal.tab_next" },
    .{ .accelerator = "Alt+Up", .target = "terminal.split_up" },
    .{ .accelerator = "Alt+Down", .target = "terminal.split_down" },
    .{ .accelerator = "Alt+Left", .target = "terminal.split_left" },
    .{ .accelerator = "Alt+Right", .target = "terminal.split_right" },
    .{ .accelerator = "Alt+Shift+Up", .target = "terminal.focus_up" },
    .{ .accelerator = "Alt+Shift+Down", .target = "terminal.focus_down" },
    .{ .accelerator = "Alt+Shift+Left", .target = "terminal.focus_left" },
    .{ .accelerator = "Alt+Shift+Right", .target = "terminal.focus_right" },
};

/// Navigate-mode table (herdr `prefix w`). Kept short: the status bar lists
/// every entry as a hint, so this is the muscle-memory subset, not the full
/// command surface (`?` still shows everything).
const DEFAULT_NAVIGATE_TABLE = [_]DefaultPrefixEntry{
    .{ .accelerator = "Up", .target = "workspace.previous" },
    .{ .accelerator = "Down", .target = "workspace.next" },
    .{ .accelerator = "Tab", .target = "workspace.pane_next" },
    .{ .accelerator = "Shift+Tab", .target = "workspace.pane_previous" },
    .{ .accelerator = "H", .target = "workspace.focus_left" },
    .{ .accelerator = "J", .target = "workspace.focus_down" },
    .{ .accelerator = "K", .target = "workspace.focus_up" },
    .{ .accelerator = "L", .target = "workspace.focus_right" },
    .{ .accelerator = "C", .target = "new_thread" },
    .{ .accelerator = "V", .target = "workspace.split_default_vertical" },
    .{ .accelerator = "Minus", .target = "workspace.split_default_horizontal" },
    .{ .accelerator = "Shift+V", .target = "workspace.split_alternate_vertical" },
    .{ .accelerator = "Shift+Minus", .target = "workspace.split_alternate_horizontal" },
    .{ .accelerator = "X", .target = "workspace.close" },
    .{ .accelerator = "Z", .target = "workspace.toggle_maximize" },
    .{ .accelerator = "P", .target = "command_palette" },
    .{ .accelerator = "Shift+Slash", .target = "prefix.keybinds" },
    .{ .accelerator = "1", .target = "workspace.select.1" },
    .{ .accelerator = "2", .target = "workspace.select.2" },
    .{ .accelerator = "3", .target = "workspace.select.3" },
    .{ .accelerator = "4", .target = "workspace.select.4" },
    .{ .accelerator = "5", .target = "workspace.select.5" },
    .{ .accelerator = "6", .target = "workspace.select.6" },
    .{ .accelerator = "7", .target = "workspace.select.7" },
    .{ .accelerator = "8", .target = "workspace.select.8" },
    .{ .accelerator = "9", .target = "workspace.select.9" },
    .{ .accelerator = "0", .target = "workspace.select.10" },
};

fn cloneDefaultPrefixTable(allocator: std.mem.Allocator, table: []const DefaultPrefixEntry) !std.ArrayList(PrefixBinding) {
    var bindings: std.ArrayList(PrefixBinding) = .empty;
    errdefer bindings.deinit(allocator);
    for (table) |entry| {
        try bindings.append(allocator, .{
            .key = try parseDefaultAccelerator(entry.accelerator),
            .target = parsePrefixActionName(entry.target) orelse return error.InvalidDefaultPrefixTarget,
        });
    }
    return bindings;
}

fn cloneDefaultPrefixConfig(allocator: std.mem.Allocator) !PrefixConfig {
    const keys = try allocator.alloc(Keybind, 1);
    errdefer allocator.free(keys);
    keys[0] = try parseDefaultAccelerator(DEFAULT_PREFIX_ACCELERATOR);

    var bindings = try cloneDefaultPrefixTable(allocator, &DEFAULT_PREFIX_TABLE);
    errdefer bindings.deinit(allocator);
    const navigate = try cloneDefaultPrefixTable(allocator, &DEFAULT_NAVIGATE_TABLE);

    return .{ .enabled = false, .keys = keys, .bindings = bindings, .navigate = navigate };
}

fn cloneDefaultKeybinds(allocator: std.mem.Allocator) ![]Keybind {
    return allocator.dupe(Keybind, &.{
        try parseDefaultAccelerator("CommandOrControl+Shift+R"),
        try parseDefaultAccelerator("Ctrl+Shift+R"),
        try parseDefaultAccelerator("F5"),
    });
}

fn cloneEmptyKeybinds(allocator: std.mem.Allocator) ![]Keybind {
    return allocator.alloc(Keybind, 0);
}

fn cloneDefaultOpenKeybinds(allocator: std.mem.Allocator) ![]Keybind {
    return allocator.dupe(Keybind, &.{
        try parseDefaultAccelerator("Alt+O"),
    });
}

fn cloneDefaultOpenEditorKeybinds(allocator: std.mem.Allocator) ![]Keybind {
    return allocator.dupe(Keybind, &.{
        try parseDefaultAccelerator("Ctrl+Shift+O"),
    });
}

fn cloneDefaultNewThreadKeybinds(allocator: std.mem.Allocator) ![]Keybind {
    return allocator.dupe(Keybind, &.{
        try parseDefaultAccelerator("CommandOrControl+T"),
    });
}

fn cloneDefaultWorkspaceCloseKeybinds(allocator: std.mem.Allocator) ![]Keybind {
    return allocator.dupe(Keybind, &.{
        try parseDefaultAccelerator("CommandOrControl+W"),
        try parseDefaultAccelerator("Alt+X"),
    });
}

fn cloneDefaultWorkspaceCloseCurrentKeybinds(allocator: std.mem.Allocator) ![]Keybind {
    return allocator.dupe(Keybind, &.{
        try parseDefaultAccelerator("Ctrl+Shift+W"),
    });
}

fn cloneDefaultCommandPaletteKeybinds(allocator: std.mem.Allocator) ![]Keybind {
    return allocator.dupe(Keybind, &.{
        try parseDefaultAccelerator("CommandOrControl+Shift+P"),
    });
}

fn cloneDefaultCompanionKeybinds(allocator: std.mem.Allocator) ![]Keybind {
    return allocator.dupe(Keybind, &.{
        try parseDefaultAccelerator("Ctrl+Shift+Space"),
    });
}

fn cloneDefaultSidebarKeybinds(allocator: std.mem.Allocator) ![]Keybind {
    return allocator.dupe(Keybind, &.{
        try parseDefaultAccelerator("CommandOrControl+S"),
    });
}

fn cloneDefaultSidebarHiddenKeybinds(allocator: std.mem.Allocator) ![]Keybind {
    return allocator.dupe(Keybind, &.{
        try parseDefaultAccelerator("Ctrl+Shift+S"),
    });
}

fn cloneDefaultTerminalKeybinds(allocator: std.mem.Allocator) ![]Keybind {
    return cloneEmptyKeybinds(allocator);
}

fn cloneDefaultBrowserKeybinds(allocator: std.mem.Allocator) ![]Keybind {
    return allocator.dupe(Keybind, &.{
        try parseDefaultAccelerator("Ctrl+Shift+B"),
    });
}

fn cloneDefaultChatUpKeybinds(allocator: std.mem.Allocator) ![]Keybind {
    return allocator.dupe(Keybind, &.{
        try parseDefaultAccelerator("Up"),
    });
}

fn cloneDefaultChatDownKeybinds(allocator: std.mem.Allocator) ![]Keybind {
    return allocator.dupe(Keybind, &.{
        try parseDefaultAccelerator("Down"),
    });
}

fn cloneDefaultChatPageUpKeybinds(allocator: std.mem.Allocator) ![]Keybind {
    return allocator.dupe(Keybind, &.{
        try parseDefaultAccelerator("PageUp"),
    });
}

fn cloneDefaultChatPageDownKeybinds(allocator: std.mem.Allocator) ![]Keybind {
    return allocator.dupe(Keybind, &.{
        try parseDefaultAccelerator("PageDown"),
    });
}

fn cloneDefaultChatModelPickerKeybinds(allocator: std.mem.Allocator) ![]Keybind {
    return allocator.dupe(Keybind, &.{
        try parseDefaultAccelerator("Alt+M"),
    });
}

fn cloneDefaultChatRunConfigKeybinds(allocator: std.mem.Allocator) ![]Keybind {
    return allocator.dupe(Keybind, &.{
        try parseDefaultAccelerator("Alt+R"),
    });
}

fn cloneDefaultTerminalNewTabKeybinds(allocator: std.mem.Allocator) ![]Keybind {
    return allocator.dupe(Keybind, &.{
        try parseDefaultAccelerator("CommandOrControl+Alt+T"),
    });
}

fn cloneDefaultWorkspaceSplitTerminalHorizontalKeybinds(allocator: std.mem.Allocator) ![]Keybind {
    return allocator.dupe(Keybind, &.{
        try parseDefaultAccelerator("CommandOrControl+Shift+T"),
    });
}

fn cloneDefaultTerminalCloseActiveKeybinds(allocator: std.mem.Allocator) ![]Keybind {
    return allocator.dupe(Keybind, &.{
        try parseDefaultAccelerator("CommandOrControl+Shift+W"),
    });
}

fn cloneDefaultTerminalRenameTabKeybinds(allocator: std.mem.Allocator) ![]Keybind {
    return allocator.dupe(Keybind, &.{
        try parseDefaultAccelerator("CommandOrControl+Shift+R"),
    });
}

fn cloneDefaultTerminalTabPreviousKeybinds(allocator: std.mem.Allocator) ![]Keybind {
    return allocator.dupe(Keybind, &.{
        try parseDefaultAccelerator("CommandOrControl+Shift+PageUp"),
    });
}

fn cloneDefaultTerminalTabNextKeybinds(allocator: std.mem.Allocator) ![]Keybind {
    return allocator.dupe(Keybind, &.{
        try parseDefaultAccelerator("CommandOrControl+Shift+PageDown"),
    });
}

fn cloneDefaultTerminalSplitUpKeybinds(allocator: std.mem.Allocator) ![]Keybind {
    return cloneEmptyKeybinds(allocator);
}

fn cloneDefaultTerminalSplitDownKeybinds(allocator: std.mem.Allocator) ![]Keybind {
    return cloneEmptyKeybinds(allocator);
}

fn cloneDefaultTerminalSplitLeftKeybinds(allocator: std.mem.Allocator) ![]Keybind {
    return cloneEmptyKeybinds(allocator);
}

fn cloneDefaultTerminalSplitRightKeybinds(allocator: std.mem.Allocator) ![]Keybind {
    return cloneEmptyKeybinds(allocator);
}

fn cloneDefaultTerminalFocusUpKeybinds(allocator: std.mem.Allocator) ![]Keybind {
    return allocator.dupe(Keybind, &.{
        try parseDefaultAccelerator("CommandOrControl+Alt+Up"),
    });
}

fn cloneDefaultTerminalFocusDownKeybinds(allocator: std.mem.Allocator) ![]Keybind {
    return allocator.dupe(Keybind, &.{
        try parseDefaultAccelerator("CommandOrControl+Alt+Down"),
    });
}

fn cloneDefaultTerminalFocusLeftKeybinds(allocator: std.mem.Allocator) ![]Keybind {
    return allocator.dupe(Keybind, &.{
        try parseDefaultAccelerator("CommandOrControl+Alt+Left"),
    });
}

fn cloneDefaultTerminalFocusRightKeybinds(allocator: std.mem.Allocator) ![]Keybind {
    return allocator.dupe(Keybind, &.{
        try parseDefaultAccelerator("CommandOrControl+Alt+Right"),
    });
}

fn cloneDefaultWorkspaceFocusLeftKeybinds(allocator: std.mem.Allocator) ![]Keybind {
    return allocator.dupe(Keybind, &.{
        try parseDefaultAccelerator("Ctrl+Left"),
    });
}

fn cloneDefaultWorkspaceFocusRightKeybinds(allocator: std.mem.Allocator) ![]Keybind {
    return allocator.dupe(Keybind, &.{
        try parseDefaultAccelerator("Ctrl+Right"),
    });
}

fn cloneDefaultWorkspaceFocusUpKeybinds(allocator: std.mem.Allocator) ![]Keybind {
    return allocator.dupe(Keybind, &.{
        try parseDefaultAccelerator("Ctrl+Up"),
    });
}

fn cloneDefaultWorkspaceFocusDownKeybinds(allocator: std.mem.Allocator) ![]Keybind {
    return allocator.dupe(Keybind, &.{
        try parseDefaultAccelerator("Ctrl+Down"),
    });
}

fn cloneDefaultWorkspacePreviousKeybinds(allocator: std.mem.Allocator) ![]Keybind {
    return allocator.dupe(Keybind, &.{
        try parseDefaultAccelerator("Alt+Up"),
    });
}

fn cloneDefaultWorkspaceNextKeybinds(allocator: std.mem.Allocator) ![]Keybind {
    return allocator.dupe(Keybind, &.{
        try parseDefaultAccelerator("Alt+Down"),
    });
}

fn cloneDefaultWorkspaceActivePreviousKeybinds(allocator: std.mem.Allocator) ![]Keybind {
    return allocator.dupe(Keybind, &.{
        try parseDefaultAccelerator("Ctrl+Shift+Left"),
    });
}

fn cloneDefaultWorkspaceActiveNextKeybinds(allocator: std.mem.Allocator) ![]Keybind {
    return allocator.dupe(Keybind, &.{
        try parseDefaultAccelerator("Ctrl+Shift+Right"),
    });
}

fn cloneDefaultWorkspacePanePreviousKeybinds(allocator: std.mem.Allocator) ![]Keybind {
    return allocator.dupe(Keybind, &.{
        try parseDefaultAccelerator("Ctrl+Shift+Tab"),
    });
}

fn cloneDefaultWorkspacePaneNextKeybinds(allocator: std.mem.Allocator) ![]Keybind {
    return allocator.dupe(Keybind, &.{
        try parseDefaultAccelerator("Ctrl+Tab"),
    });
}

fn cloneDefaultWorkspaceFocusPromptKeybinds(allocator: std.mem.Allocator) ![]Keybind {
    return allocator.dupe(Keybind, &.{
        try parseDefaultAccelerator("Tab"),
    });
}

fn cloneDefaultWorkspacePaneSelectKeybinds(allocator: std.mem.Allocator) ![]Keybind {
    return allocator.dupe(Keybind, &.{
        try parseDefaultAccelerator("Ctrl+1"),
        try parseDefaultAccelerator("Ctrl+2"),
        try parseDefaultAccelerator("Ctrl+3"),
        try parseDefaultAccelerator("Ctrl+4"),
        try parseDefaultAccelerator("Ctrl+5"),
        try parseDefaultAccelerator("Ctrl+6"),
        try parseDefaultAccelerator("Ctrl+7"),
        try parseDefaultAccelerator("Ctrl+8"),
        try parseDefaultAccelerator("Ctrl+9"),
        try parseDefaultAccelerator("Ctrl+0"),
    });
}

fn cloneDefaultWorkspaceActiveSelectKeybinds(allocator: std.mem.Allocator) ![]Keybind {
    return allocator.dupe(Keybind, &.{
        try parseDefaultAccelerator("Ctrl+Shift+1"),
        try parseDefaultAccelerator("Ctrl+Shift+2"),
        try parseDefaultAccelerator("Ctrl+Shift+3"),
        try parseDefaultAccelerator("Ctrl+Shift+4"),
        try parseDefaultAccelerator("Ctrl+Shift+5"),
        try parseDefaultAccelerator("Ctrl+Shift+6"),
        try parseDefaultAccelerator("Ctrl+Shift+7"),
        try parseDefaultAccelerator("Ctrl+Shift+8"),
        try parseDefaultAccelerator("Ctrl+Shift+9"),
        try parseDefaultAccelerator("Ctrl+Shift+0"),
    });
}

fn cloneDefaultWorkspaceMoveLeftKeybinds(allocator: std.mem.Allocator) ![]Keybind {
    return allocator.dupe(Keybind, &.{
        try parseDefaultAccelerator("Ctrl+Shift+H"),
    });
}

fn cloneDefaultWorkspaceMoveRightKeybinds(allocator: std.mem.Allocator) ![]Keybind {
    return allocator.dupe(Keybind, &.{
        try parseDefaultAccelerator("Ctrl+Shift+L"),
    });
}

fn cloneDefaultWorkspaceMoveUpKeybinds(allocator: std.mem.Allocator) ![]Keybind {
    return allocator.dupe(Keybind, &.{
        try parseDefaultAccelerator("Ctrl+Shift+K"),
    });
}

fn cloneDefaultWorkspaceMoveDownKeybinds(allocator: std.mem.Allocator) ![]Keybind {
    return allocator.dupe(Keybind, &.{
        try parseDefaultAccelerator("Ctrl+Shift+J"),
    });
}

fn cloneDefaultWorkspaceGrowLeftKeybinds(allocator: std.mem.Allocator) ![]Keybind {
    return allocator.dupe(Keybind, &.{
        try parseDefaultAccelerator("Alt+Shift+Left"),
    });
}

fn cloneDefaultWorkspaceGrowRightKeybinds(allocator: std.mem.Allocator) ![]Keybind {
    return allocator.dupe(Keybind, &.{
        try parseDefaultAccelerator("Alt+Shift+Right"),
    });
}

fn cloneDefaultWorkspaceGrowUpKeybinds(allocator: std.mem.Allocator) ![]Keybind {
    return allocator.dupe(Keybind, &.{
        try parseDefaultAccelerator("Alt+Shift+Up"),
    });
}

fn cloneDefaultWorkspaceGrowDownKeybinds(allocator: std.mem.Allocator) ![]Keybind {
    return allocator.dupe(Keybind, &.{
        try parseDefaultAccelerator("Alt+Shift+Down"),
    });
}

fn cloneDefaultWorkspaceToggleMaximizeKeybinds(allocator: std.mem.Allocator) ![]Keybind {
    return allocator.dupe(Keybind, &.{
        try parseDefaultAccelerator("Alt+Z"),
    });
}

fn cloneDefaultWorkspaceToggleQuickPaneKeybinds(allocator: std.mem.Allocator) ![]Keybind {
    return allocator.dupe(Keybind, &.{
        try parseDefaultAccelerator("Ctrl+Alt+T"),
    });
}

fn cloneDefaultWorkspaceSelectKeybinds(allocator: std.mem.Allocator) ![]Keybind {
    return allocator.dupe(Keybind, &.{
        try parseDefaultAccelerator("Alt+1"),
        try parseDefaultAccelerator("Alt+2"),
        try parseDefaultAccelerator("Alt+3"),
        try parseDefaultAccelerator("Alt+4"),
        try parseDefaultAccelerator("Alt+5"),
        try parseDefaultAccelerator("Alt+6"),
        try parseDefaultAccelerator("Alt+7"),
        try parseDefaultAccelerator("Alt+8"),
        try parseDefaultAccelerator("Alt+9"),
        try parseDefaultAccelerator("Alt+0"),
    });
}

/// Formats the first loaded binding for UI hints. The caller owns `buf`, so
/// separate controls can render hints in the same frame without shared state.
pub fn formatFirstKeybind(buf: []u8, bindings: []const Keybind) []const u8 {
    if (bindings.len == 0) return "";
    return formatKeybind(buf, bindings[0]);
}

/// Formats the key portion of the first plain Alt binding. Commands rebound
/// away from Alt stay out of Alt-reveal mode instead of showing a stale tip.
pub fn formatAltKeyTip(buf: []u8, bindings: []const Keybind) []const u8 {
    for (bindings) |binding| {
        if (!binding.alt or binding.primary or binding.ctrl or binding.meta or binding.shift) continue;
        const name = keycodeLabel(binding.key);
        const count = @min(buf.len, name.len);
        @memcpy(buf[0..count], name[0..count]);
        for (buf[0..count]) |*byte| byte.* = std.ascii.toUpper(byte.*);
        return buf[0..count];
    }
    return "";
}

/// Formats the key portion of an indexed plain Alt binding. Workspace rows
/// use the binding's configured order rather than assuming 1…0.
pub fn formatAltKeyTipAt(buf: []u8, bindings: []const Keybind, index: usize) []const u8 {
    if (index >= bindings.len) return "";
    const binding = bindings[index];
    if (!binding.alt or binding.primary or binding.ctrl or binding.meta or binding.shift) return "";
    const name = keycodeLabel(binding.key);
    const count = @min(buf.len, name.len);
    @memcpy(buf[0..count], name[0..count]);
    for (buf[0..count]) |*byte| byte.* = std.ascii.toUpper(byte.*);
    return buf[0..count];
}

/// Formats the key portion of an indexed plain Ctrl binding. Sidebar pane
/// hints use the same ordering as `workspacePaneSelectIndexForEvent`.
pub fn formatCtrlKeyTipAt(buf: []u8, bindings: []const Keybind, index: usize) []const u8 {
    if (index >= bindings.len) return "";
    const binding = bindings[index];
    const primary_is_ctrl = binding.primary and builtin.os.tag != .macos;
    if ((!binding.ctrl and !primary_is_ctrl) or binding.alt or binding.meta or binding.shift) return "";
    const name = keycodeLabel(binding.key);
    const count = @min(buf.len, name.len);
    @memcpy(buf[0..count], name[0..count]);
    for (buf[0..count]) |*byte| byte.* = std.ascii.toUpper(byte.*);
    return buf[0..count];
}

/// Formats the key portion of the first Ctrl+Shift binding. Commands rebound
/// away from Ctrl+Shift stay out of Ctrl+Shift reveal mode.
pub fn formatCtrlShiftKeyTip(buf: []u8, bindings: []const Keybind) []const u8 {
    for (bindings) |binding| {
        const primary_is_ctrl = binding.primary and builtin.os.tag != .macos;
        if ((!binding.ctrl and !primary_is_ctrl) or binding.alt or binding.meta or !binding.shift) continue;
        const name = keycodeLabel(binding.key);
        const count = @min(buf.len, name.len);
        @memcpy(buf[0..count], name[0..count]);
        for (buf[0..count]) |*byte| byte.* = std.ascii.toUpper(byte.*);
        return buf[0..count];
    }
    return "";
}

/// Formats the key portion of an indexed Ctrl+Shift binding used by ACTIVE rows.
pub fn formatCtrlShiftKeyTipAt(buf: []u8, bindings: []const Keybind, index: usize) []const u8 {
    if (index >= bindings.len) return "";
    const binding = bindings[index];
    const primary_is_ctrl = binding.primary and builtin.os.tag != .macos;
    if ((!binding.ctrl and !primary_is_ctrl) or binding.alt or binding.meta or !binding.shift) return "";
    const name = keycodeLabel(binding.key);
    const count = @min(buf.len, name.len);
    @memcpy(buf[0..count], name[0..count]);
    for (buf[0..count]) |*byte| byte.* = std.ascii.toUpper(byte.*);
    return buf[0..count];
}

/// Formats a keybind for compact UI shortcut hints.
pub fn formatKeybind(buf: []u8, binding: Keybind) []const u8 {
    var count: usize = 0;
    if (binding.primary or binding.ctrl) count += copyInto(buf[count..], "Ctrl+");
    if (binding.meta) count += copyInto(buf[count..], "Meta+");
    if (binding.alt) count += copyInto(buf[count..], "Alt+");
    if (binding.shift) count += copyInto(buf[count..], "Shift+");
    const name = keycodeLabel(binding.key);
    count += copyInto(buf[count..], name);
    if (name.len == 1 and count > 0) buf[count - 1] = std.ascii.toUpper(buf[count - 1]);
    return buf[0..count];
}

fn keycodeLabel(key: sdl.Keycode) []const u8 {
    return switch (key) {
        .@"return" => "Enter",
        .left => "Left",
        .right => "Right",
        .up => "Up",
        .down => "Down",
        .grave => "`",
        .leftbracket => "[",
        .rightbracket => "]",
        .backslash => "\\",
        .semicolon => ";",
        .apostrophe => "'",
        .comma => ",",
        .period => ".",
        .slash => "/",
        .minus => "-",
        .equals => "=",
        .space => "Space",
        .pageup => "PageUp",
        .pagedown => "PageDown",
        else => @tagName(key),
    };
}

fn copyInto(dest: []u8, src: []const u8) usize {
    const count = @min(dest.len, src.len);
    @memcpy(dest[0..count], src[0..count]);
    return count;
}

fn parseDefaultAccelerator(binding: []const u8) !Keybind {
    return parseAccelerator(binding) orelse error.InvalidDefaultKeybind;
}

fn matchesAny(bindings: []const Keybind, event: *const sdl.KeyboardEvent) bool {
    for (bindings) |binding| {
        if (binding.matches(event)) {
            return true;
        }
    }

    return false;
}

fn matchesAnyAllowRepeat(bindings: []const Keybind, event: *const sdl.KeyboardEvent) bool {
    for (bindings) |binding| {
        if (binding.matchesAllowRepeat(event)) {
            return true;
        }
    }

    return false;
}

fn containsKeybind(bindings: []const Keybind, needle: Keybind) bool {
    for (bindings) |binding| {
        if (binding.eql(needle)) {
            return true;
        }
    }

    return false;
}

fn hasModifier(modifier_state: sdl.Keymod, modifier_mask: u16) bool {
    const state_bits = @as(*const u16, @ptrCast(&modifier_state)).*;
    return (state_bits & modifier_mask) != 0;
}

fn parseAccelerator(binding: []const u8) ?Keybind {
    var parsed: Keybind = .{ .key = .unknown };
    var tokens = std.mem.tokenizeScalar(u8, binding, '+');

    while (tokens.next()) |token| {
        const trimmed = std.mem.trim(u8, token, &std.ascii.whitespace);
        if (trimmed.len == 0) {
            return null;
        }

        if (parseModifier(trimmed, &parsed)) {
            continue;
        }

        if (parsed.key != .unknown) {
            return null;
        }

        parsed.key = parseKeycode(trimmed) orelse return null;
    }

    if (parsed.key == .unknown) {
        return null;
    }

    return parsed;
}

fn parseModifier(token: []const u8, binding: *Keybind) bool {
    if (std.ascii.eqlIgnoreCase(token, "CommandOrControl") or std.ascii.eqlIgnoreCase(token, "CmdOrCtrl")) {
        binding.primary = true;
        return true;
    }
    if (std.ascii.eqlIgnoreCase(token, "Control") or std.ascii.eqlIgnoreCase(token, "Ctrl")) {
        binding.ctrl = true;
        return true;
    }
    if (std.ascii.eqlIgnoreCase(token, "Command") or std.ascii.eqlIgnoreCase(token, "Cmd")) {
        binding.meta = true;
        return true;
    }
    if (std.ascii.eqlIgnoreCase(token, "Super") or std.ascii.eqlIgnoreCase(token, "Meta") or std.ascii.eqlIgnoreCase(token, "Win")) {
        binding.meta = true;
        return true;
    }
    if (std.ascii.eqlIgnoreCase(token, "Alt") or std.ascii.eqlIgnoreCase(token, "Option")) {
        binding.alt = true;
        return true;
    }
    if (std.ascii.eqlIgnoreCase(token, "Shift")) {
        binding.shift = true;
        return true;
    }

    return false;
}

fn parseKeycode(token: []const u8) ?sdl.Keycode {
    if (token.len == 1) {
        return switch (std.ascii.toLower(token[0])) {
            'a' => .a,
            'b' => .b,
            'c' => .c,
            'd' => .d,
            'e' => .e,
            'f' => .f,
            'g' => .g,
            'h' => .h,
            'i' => .i,
            'j' => .j,
            'k' => .k,
            'l' => .l,
            'm' => .m,
            'n' => .n,
            'o' => .o,
            'p' => .p,
            'q' => .q,
            'r' => .r,
            's' => .s,
            't' => .t,
            'u' => .u,
            'v' => .v,
            'w' => .w,
            'x' => .x,
            'y' => .y,
            'z' => .z,
            '0' => .@"0",
            '1' => .@"1",
            '2' => .@"2",
            '3' => .@"3",
            '4' => .@"4",
            '5' => .@"5",
            '6' => .@"6",
            '7' => .@"7",
            '8' => .@"8",
            '9' => .@"9",
            '-' => .minus,
            '=' => .equals,
            '`' => .grave,
            '[' => .leftbracket,
            ']' => .rightbracket,
            '\\' => .backslash,
            ';' => .semicolon,
            '\'' => .apostrophe,
            ',' => .comma,
            '.' => .period,
            '/' => .slash,
            else => null,
        };
    }

    if (token.len >= 2 and (token[0] == 'F' or token[0] == 'f')) {
        const number = std.fmt.parseUnsigned(u8, token[1..], 10) catch return null;
        return switch (number) {
            1 => .f1,
            2 => .f2,
            3 => .f3,
            4 => .f4,
            5 => .f5,
            6 => .f6,
            7 => .f7,
            8 => .f8,
            9 => .f9,
            10 => .f10,
            11 => .f11,
            12 => .f12,
            13 => .f13,
            14 => .f14,
            15 => .f15,
            16 => .f16,
            17 => .f17,
            18 => .f18,
            19 => .f19,
            20 => .f20,
            21 => .f21,
            22 => .f22,
            23 => .f23,
            24 => .f24,
            else => null,
        };
    }

    if (std.ascii.eqlIgnoreCase(token, "Minus")) return .minus;
    if (std.ascii.eqlIgnoreCase(token, "Plus")) return .equals;
    if (std.ascii.eqlIgnoreCase(token, "Equal")) return .equals;
    if (std.ascii.eqlIgnoreCase(token, "Equals")) return .equals;
    if (std.ascii.eqlIgnoreCase(token, "Enter")) return .@"return";
    if (std.ascii.eqlIgnoreCase(token, "Return")) return .@"return";
    if (std.ascii.eqlIgnoreCase(token, "Escape")) return .escape;
    if (std.ascii.eqlIgnoreCase(token, "Esc")) return .escape;
    if (std.ascii.eqlIgnoreCase(token, "Space")) return .space;
    if (std.ascii.eqlIgnoreCase(token, "Spacebar")) return .space;
    if (std.ascii.eqlIgnoreCase(token, "Tab")) return .tab;
    if (std.ascii.eqlIgnoreCase(token, "Backspace")) return .backspace;
    if (std.ascii.eqlIgnoreCase(token, "Delete")) return .delete;
    if (std.ascii.eqlIgnoreCase(token, "Insert")) return .insert;
    if (std.ascii.eqlIgnoreCase(token, "Home")) return .home;
    if (std.ascii.eqlIgnoreCase(token, "End")) return .end;
    if (std.ascii.eqlIgnoreCase(token, "PageUp")) return .pageup;
    if (std.ascii.eqlIgnoreCase(token, "PgUp")) return .pageup;
    if (std.ascii.eqlIgnoreCase(token, "PageDown")) return .pagedown;
    if (std.ascii.eqlIgnoreCase(token, "PgDn")) return .pagedown;
    if (std.ascii.eqlIgnoreCase(token, "Up")) return .up;
    if (std.ascii.eqlIgnoreCase(token, "Down")) return .down;
    if (std.ascii.eqlIgnoreCase(token, "Left")) return .left;
    if (std.ascii.eqlIgnoreCase(token, "Right")) return .right;
    if (std.ascii.eqlIgnoreCase(token, "Grave") or std.ascii.eqlIgnoreCase(token, "Backquote")) return .grave;
    if (std.ascii.eqlIgnoreCase(token, "LeftBracket") or std.ascii.eqlIgnoreCase(token, "BracketLeft")) return .leftbracket;
    if (std.ascii.eqlIgnoreCase(token, "RightBracket") or std.ascii.eqlIgnoreCase(token, "BracketRight")) return .rightbracket;
    if (std.ascii.eqlIgnoreCase(token, "Backslash")) return .backslash;
    if (std.ascii.eqlIgnoreCase(token, "Semicolon")) return .semicolon;
    if (std.ascii.eqlIgnoreCase(token, "Apostrophe") or std.ascii.eqlIgnoreCase(token, "Quote")) return .apostrophe;
    if (std.ascii.eqlIgnoreCase(token, "Comma")) return .comma;
    if (std.ascii.eqlIgnoreCase(token, "Period")) return .period;
    if (std.ascii.eqlIgnoreCase(token, "Slash")) return .slash;

    return null;
}

test "parse accelerator matches desktop-style refresh binding" {
    const binding = parseAccelerator("CommandOrControl+R") orelse return error.TestUnexpectedResult;

    try std.testing.expect(binding.primary);
    try std.testing.expectEqual(false, binding.shift);
    try std.testing.expectEqual(sdl.Keycode.r, binding.key);
}

test "ctrl shift key tip follows the first matching configured binding" {
    const bindings: [2]Keybind = .{
        .{ .alt = true, .shift = true, .key = .x },
        .{ .ctrl = true, .shift = true, .key = .o },
    };
    var buf: [16]u8 = undefined;

    try std.testing.expectEqualStrings("O", formatCtrlShiftKeyTip(&buf, &bindings));
}

test "array parsing deduplicates repeated bindings" {
    var config = try NativeKeyboardConfig.load(std.testing.allocator);
    defer config.deinit();

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator,
        \\{"keybinds": {"refresh": ["F5", "f5"]}}
    , .{});
    defer parsed.deinit();

    config.applyOverrides(parsed.value);

    try std.testing.expectEqual(@as(usize, 1), config.refresh.len);
    try std.testing.expectEqual(sdl.Keycode.f5, config.refresh[0].key);
}

test "Companion keybind defaults overrides disables and deduplicates" {
    var config = try NativeKeyboardConfig.load(std.testing.allocator);
    defer config.deinit();

    try std.testing.expectEqual(@as(usize, 1), config.companion.len);
    try std.testing.expect(config.companion[0].ctrl);
    try std.testing.expect(config.companion[0].shift);
    try std.testing.expectEqual(sdl.Keycode.space, config.companion[0].key);

    var overridden = try std.json.parseFromSlice(std.json.Value, std.testing.allocator,
        \\{"keybinds": {"companion": ["Alt+C", "alt+c"]}}
    , .{});
    defer overridden.deinit();
    config.applyOverrides(overridden.value);
    try std.testing.expectEqual(@as(usize, 1), config.companion.len);
    try std.testing.expect(config.companion[0].alt);
    try std.testing.expectEqual(sdl.Keycode.c, config.companion[0].key);

    var disabled = try std.json.parseFromSlice(std.json.Value, std.testing.allocator,
        \\{"keybinds": {"companion": null}}
    , .{});
    defer disabled.deinit();
    config.applyOverrides(disabled.value);
    try std.testing.expectEqual(@as(usize, 0), config.companion.len);
}

test "open keybind override accepts a single accelerator" {
    var config = try NativeKeyboardConfig.load(std.testing.allocator);
    defer config.deinit();

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator,
        \\{"keybinds": {"open": "Ctrl+Shift+O"}}
    , .{});
    defer parsed.deinit();

    config.applyOverrides(parsed.value);

    try std.testing.expectEqual(@as(usize, 1), config.open_default.len);
    try std.testing.expect(config.open_default[0].ctrl);
    try std.testing.expect(config.open_default[0].shift);
    try std.testing.expectEqual(sdl.Keycode.o, config.open_default[0].key);
}

test "browser keybind override accepts a single accelerator" {
    var config = try NativeKeyboardConfig.load(std.testing.allocator);
    defer config.deinit();

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator,
        \\{"keybinds": {"browser": "Alt+Shift+B"}}
    , .{});
    defer parsed.deinit();

    config.applyOverrides(parsed.value);

    try std.testing.expectEqual(@as(usize, 1), config.toggle_browser.len);
    try std.testing.expect(config.toggle_browser[0].alt);
    try std.testing.expect(config.toggle_browser[0].shift);
    try std.testing.expectEqual(sdl.Keycode.b, config.toggle_browser[0].key);
}

test "workspace select defaults map alt number order" {
    var config = try NativeKeyboardConfig.load(std.testing.allocator);
    defer config.deinit();

    try std.testing.expectEqual(@as(usize, 10), config.workspace_select.len);
    try std.testing.expect(config.workspace_select[0].alt);
    try std.testing.expectEqual(sdl.Keycode.@"1", config.workspace_select[0].key);
    try std.testing.expect(config.workspace_select[9].alt);
    try std.testing.expectEqual(sdl.Keycode.@"0", config.workspace_select[9].key);
}

test "workspace select override accepts ordered accelerator array" {
    var config = try NativeKeyboardConfig.load(std.testing.allocator);
    defer config.deinit();

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator,
        \\{"keybinds": {"workspace": {"select": ["Ctrl+1", "Ctrl+2"]}}}
    , .{});
    defer parsed.deinit();

    config.applyOverrides(parsed.value);

    try std.testing.expectEqual(@as(usize, 2), config.workspace_select.len);
    try std.testing.expect(config.workspace_select[0].ctrl);
    try std.testing.expectEqual(sdl.Keycode.@"1", config.workspace_select[0].key);
    try std.testing.expect(config.workspace_select[1].ctrl);
    try std.testing.expectEqual(sdl.Keycode.@"2", config.workspace_select[1].key);
}

test "workspace pane select defaults map ctrl number order" {
    var config = try NativeKeyboardConfig.load(std.testing.allocator);
    defer config.deinit();

    try std.testing.expectEqual(@as(usize, 10), config.workspace_pane_select.len);
    try std.testing.expect(config.workspace_pane_select[0].ctrl);
    try std.testing.expectEqual(sdl.Keycode.@"1", config.workspace_pane_select[0].key);
    try std.testing.expect(config.workspace_pane_select[9].ctrl);
    try std.testing.expectEqual(sdl.Keycode.@"0", config.workspace_pane_select[9].key);
}

test "workspace active select defaults map ctrl shift number order" {
    var config = try NativeKeyboardConfig.load(std.testing.allocator);
    defer config.deinit();

    try std.testing.expectEqual(@as(usize, 10), config.workspace_active_select.len);
    try std.testing.expect(config.workspace_active_select[0].ctrl);
    try std.testing.expect(config.workspace_active_select[0].shift);
    try std.testing.expectEqual(sdl.Keycode.@"1", config.workspace_active_select[0].key);
    try std.testing.expect(config.workspace_active_select[9].ctrl);
    try std.testing.expect(config.workspace_active_select[9].shift);
    try std.testing.expectEqual(sdl.Keycode.@"0", config.workspace_active_select[9].key);
}

test "workspace active select override accepts ordered accelerator array" {
    var config = try NativeKeyboardConfig.load(std.testing.allocator);
    defer config.deinit();

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator,
        \\{"keybinds": {"workspace": {"active_select": ["Alt+Shift+1", "Alt+Shift+2"]}}}
    , .{});
    defer parsed.deinit();
    config.applyOverrides(parsed.value);

    try std.testing.expectEqual(@as(usize, 2), config.workspace_active_select.len);
    try std.testing.expect(config.workspace_active_select[0].alt);
    try std.testing.expect(config.workspace_active_select[0].shift);
    try std.testing.expectEqual(sdl.Keycode.@"1", config.workspace_active_select[0].key);
    try std.testing.expectEqual(sdl.Keycode.@"2", config.workspace_active_select[1].key);
}

test "workspace pane select override accepts ordered accelerator array" {
    var config = try NativeKeyboardConfig.load(std.testing.allocator);
    defer config.deinit();

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator,
        \\{"keybinds": {"workspace": {"pane_select": ["Alt+1", "Alt+2"]}}}
    , .{});
    defer parsed.deinit();

    config.applyOverrides(parsed.value);

    try std.testing.expectEqual(@as(usize, 2), config.workspace_pane_select.len);
    try std.testing.expect(config.workspace_pane_select[0].alt);
    try std.testing.expectEqual(sdl.Keycode.@"1", config.workspace_pane_select[0].key);
    try std.testing.expect(config.workspace_pane_select[1].alt);
    try std.testing.expectEqual(sdl.Keycode.@"2", config.workspace_pane_select[1].key);
}

test "new thread keybind override accepts a single accelerator" {
    var config = try NativeKeyboardConfig.load(std.testing.allocator);
    defer config.deinit();

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator,
        \\{"keybinds": {"new_thread": "Alt+Shift+T"}}
    , .{});
    defer parsed.deinit();

    config.applyOverrides(parsed.value);

    try std.testing.expectEqual(@as(usize, 1), config.new_thread.len);
    try std.testing.expect(config.new_thread[0].alt);
    try std.testing.expect(config.new_thread[0].shift);
    try std.testing.expectEqual(sdl.Keycode.t, config.new_thread[0].key);
}

test "sidebar keybind override accepts a single accelerator" {
    var config = try NativeKeyboardConfig.load(std.testing.allocator);
    defer config.deinit();

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator,
        \\{"keybinds": {"sidebar": "Ctrl+Shift+M"}}
    , .{});
    defer parsed.deinit();

    config.applyOverrides(parsed.value);

    try std.testing.expectEqual(@as(usize, 1), config.toggle_sidebar.len);
    try std.testing.expect(config.toggle_sidebar[0].ctrl);
    try std.testing.expect(config.toggle_sidebar[0].shift);
    try std.testing.expectEqual(sdl.Keycode.m, config.toggle_sidebar[0].key);
}

test "default open keybind uses alt plus o" {
    var config = try NativeKeyboardConfig.load(std.testing.allocator);
    defer config.deinit();

    try std.testing.expectEqual(@as(usize, 1), config.open_default.len);
    try std.testing.expect(config.open_default[0].alt);
    try std.testing.expect(!config.open_default[0].ctrl);
    try std.testing.expect(!config.open_default[0].meta);
    try std.testing.expect(!config.open_default[0].primary);
    try std.testing.expectEqual(sdl.Keycode.o, config.open_default[0].key);
}

test "default open editor keybind uses ctrl shift o" {
    var config = try NativeKeyboardConfig.load(std.testing.allocator);
    defer config.deinit();

    try std.testing.expectEqual(@as(usize, 1), config.open_editor.len);
    try std.testing.expect(!config.open_editor[0].alt);
    try std.testing.expect(config.open_editor[0].ctrl);
    try std.testing.expect(!config.open_editor[0].meta);
    try std.testing.expect(!config.open_editor[0].primary);
    try std.testing.expect(config.open_editor[0].shift);
    try std.testing.expectEqual(sdl.Keycode.o, config.open_editor[0].key);
}

test "default browser keybind uses ctrl shift b" {
    var config = try NativeKeyboardConfig.load(std.testing.allocator);
    defer config.deinit();

    try std.testing.expectEqual(@as(usize, 1), config.toggle_browser.len);
    try std.testing.expect(!config.toggle_browser[0].alt);
    try std.testing.expect(config.toggle_browser[0].ctrl);
    try std.testing.expect(!config.toggle_browser[0].meta);
    try std.testing.expect(!config.toggle_browser[0].primary);
    try std.testing.expect(config.toggle_browser[0].shift);
    try std.testing.expectEqual(sdl.Keycode.b, config.toggle_browser[0].key);
}

test "default new thread keybind uses primary plus t" {
    var config = try NativeKeyboardConfig.load(std.testing.allocator);
    defer config.deinit();

    try std.testing.expectEqual(@as(usize, 1), config.new_thread.len);
    try std.testing.expect(!config.new_thread[0].alt);
    try std.testing.expect(!config.new_thread[0].ctrl);
    try std.testing.expect(!config.new_thread[0].meta);
    try std.testing.expect(config.new_thread[0].primary);
    try std.testing.expectEqual(sdl.Keycode.t, config.new_thread[0].key);
}

test "default terminal pane keybind uses primary shift t" {
    var config = try NativeKeyboardConfig.load(std.testing.allocator);
    defer config.deinit();

    try std.testing.expectEqual(@as(usize, 1), config.workspace_split_terminal_horizontal.len);
    try std.testing.expect(!config.workspace_split_terminal_horizontal[0].alt);
    try std.testing.expect(!config.workspace_split_terminal_horizontal[0].ctrl);
    try std.testing.expect(!config.workspace_split_terminal_horizontal[0].meta);
    try std.testing.expect(config.workspace_split_terminal_horizontal[0].primary);
    try std.testing.expect(config.workspace_split_terminal_horizontal[0].shift);
    try std.testing.expectEqual(sdl.Keycode.t, config.workspace_split_terminal_horizontal[0].key);
}

test "default terminal tab keybind uses primary alt t" {
    var config = try NativeKeyboardConfig.load(std.testing.allocator);
    defer config.deinit();

    try std.testing.expectEqual(@as(usize, 1), config.terminal_new_tab.len);
    try std.testing.expect(config.terminal_new_tab[0].alt);
    try std.testing.expect(!config.terminal_new_tab[0].ctrl);
    try std.testing.expect(!config.terminal_new_tab[0].meta);
    try std.testing.expect(config.terminal_new_tab[0].primary);
    try std.testing.expect(!config.terminal_new_tab[0].shift);
    try std.testing.expectEqual(sdl.Keycode.t, config.terminal_new_tab[0].key);
}

test "default terminal toggle has no keybind" {
    var config = try NativeKeyboardConfig.load(std.testing.allocator);
    defer config.deinit();

    try std.testing.expectEqual(@as(usize, 0), config.toggle_terminal.len);
}

test "default terminal internal split keybinds are disabled" {
    var config = try NativeKeyboardConfig.load(std.testing.allocator);
    defer config.deinit();

    try std.testing.expectEqual(@as(usize, 0), config.terminal_split_up.len);
    try std.testing.expectEqual(@as(usize, 0), config.terminal_split_down.len);
    try std.testing.expectEqual(@as(usize, 0), config.terminal_split_left.len);
    try std.testing.expectEqual(@as(usize, 0), config.terminal_split_right.len);
}

test "default workspace close supports primary w and alt x" {
    var config = try NativeKeyboardConfig.load(std.testing.allocator);
    defer config.deinit();

    try std.testing.expectEqual(@as(usize, 2), config.workspace_close.len);
    try std.testing.expect(config.workspace_close[0].primary);
    try std.testing.expectEqual(sdl.Keycode.w, config.workspace_close[0].key);
    try std.testing.expect(config.workspace_close[1].alt);
    try std.testing.expectEqual(sdl.Keycode.x, config.workspace_close[1].key);
}

test "default workspace close current uses ctrl shift w" {
    var config = try NativeKeyboardConfig.load(std.testing.allocator);
    defer config.deinit();

    try std.testing.expectEqual(@as(usize, 1), config.workspace_close_current.len);
    try std.testing.expect(config.workspace_close_current[0].ctrl);
    try std.testing.expect(config.workspace_close_current[0].shift);
    try std.testing.expectEqual(sdl.Keycode.w, config.workspace_close_current[0].key);
}

test "default workspace focus uses ctrl arrows without hjkl" {
    var config = try NativeKeyboardConfig.load(std.testing.allocator);
    defer config.deinit();

    const defaults = [_]struct {
        bindings: []const Keybind,
        key: sdl.Keycode,
    }{
        .{ .bindings = config.workspace_focus_left, .key = .left },
        .{ .bindings = config.workspace_focus_down, .key = .down },
        .{ .bindings = config.workspace_focus_up, .key = .up },
        .{ .bindings = config.workspace_focus_right, .key = .right },
    };
    for (defaults) |entry| {
        try std.testing.expectEqual(@as(usize, 1), entry.bindings.len);
        try std.testing.expect(entry.bindings[0].ctrl);
        try std.testing.expectEqual(entry.key, entry.bindings[0].key);
    }
}

test "workspace focus ctrl hjkl chords remain configurable" {
    var config = try NativeKeyboardConfig.load(std.testing.allocator);
    defer config.deinit();

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator,
        \\{"keybinds": {"workspace": {
        \\  "focus_left": "Ctrl+H", "focus_right": "Ctrl+L",
        \\  "focus_up": "Ctrl+K", "focus_down": "Ctrl+J"
        \\}}}
    , .{});
    defer parsed.deinit();

    config.applyOverrides(parsed.value);

    const configured = [_]struct {
        bindings: []const Keybind,
        key: sdl.Keycode,
    }{
        .{ .bindings = config.workspace_focus_left, .key = .h },
        .{ .bindings = config.workspace_focus_down, .key = .j },
        .{ .bindings = config.workspace_focus_up, .key = .k },
        .{ .bindings = config.workspace_focus_right, .key = .l },
    };
    for (configured) |entry| {
        try std.testing.expectEqual(@as(usize, 1), entry.bindings.len);
        try std.testing.expect(entry.bindings[0].ctrl);
        try std.testing.expectEqual(entry.key, entry.bindings[0].key);
    }
}

test "default workspace traversal uses alt up and down" {
    var config = try NativeKeyboardConfig.load(std.testing.allocator);
    defer config.deinit();

    try std.testing.expectEqual(@as(usize, 1), config.workspace_previous.len);
    try std.testing.expect(config.workspace_previous[0].alt);
    try std.testing.expectEqual(sdl.Keycode.up, config.workspace_previous[0].key);

    try std.testing.expectEqual(@as(usize, 1), config.workspace_next.len);
    try std.testing.expect(config.workspace_next[0].alt);
    try std.testing.expectEqual(sdl.Keycode.down, config.workspace_next[0].key);
}

test "default ACTIVE pane cycling uses ctrl shift left and right" {
    var config = try NativeKeyboardConfig.load(std.testing.allocator);
    defer config.deinit();

    try std.testing.expectEqual(@as(usize, 1), config.workspace_active_previous.len);
    try std.testing.expect(config.workspace_active_previous[0].ctrl);
    try std.testing.expect(config.workspace_active_previous[0].shift);
    try std.testing.expectEqual(sdl.Keycode.left, config.workspace_active_previous[0].key);

    try std.testing.expectEqual(@as(usize, 1), config.workspace_active_next.len);
    try std.testing.expect(config.workspace_active_next[0].ctrl);
    try std.testing.expect(config.workspace_active_next[0].shift);
    try std.testing.expectEqual(sdl.Keycode.right, config.workspace_active_next[0].key);
}

test "default pane cycling uses ctrl tab in both directions" {
    var config = try NativeKeyboardConfig.load(std.testing.allocator);
    defer config.deinit();

    try std.testing.expectEqual(@as(usize, 1), config.workspace_pane_next.len);
    try std.testing.expect(config.workspace_pane_next[0].ctrl);
    try std.testing.expect(!config.workspace_pane_next[0].shift);
    try std.testing.expectEqual(sdl.Keycode.tab, config.workspace_pane_next[0].key);

    try std.testing.expectEqual(@as(usize, 1), config.workspace_pane_previous.len);
    try std.testing.expect(config.workspace_pane_previous[0].ctrl);
    try std.testing.expect(config.workspace_pane_previous[0].shift);
    try std.testing.expectEqual(sdl.Keycode.tab, config.workspace_pane_previous[0].key);
}

test "workspace pane cycling keybinds are configurable" {
    var config = try NativeKeyboardConfig.load(std.testing.allocator);
    defer config.deinit();

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator,
        \\{"keybinds": {"workspace": {
        \\  "pane_previous": "Alt+P",
        \\  "pane_next": "Alt+N"
        \\}}}
    , .{});
    defer parsed.deinit();

    config.applyOverrides(parsed.value);

    try std.testing.expectEqual(@as(usize, 1), config.workspace_pane_previous.len);
    try std.testing.expect(config.workspace_pane_previous[0].alt);
    try std.testing.expectEqual(sdl.Keycode.p, config.workspace_pane_previous[0].key);
    try std.testing.expectEqual(@as(usize, 1), config.workspace_pane_next.len);
    try std.testing.expect(config.workspace_pane_next[0].alt);
    try std.testing.expectEqual(sdl.Keycode.n, config.workspace_pane_next[0].key);
}

test "ACTIVE pane cycling keybinds are configurable" {
    var config = try NativeKeyboardConfig.load(std.testing.allocator);
    defer config.deinit();

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator,
        \\{"keybinds": {"workspace": {
        \\  "active_previous": "Alt+P",
        \\  "active_next": "Alt+N"
        \\}}}
    , .{});
    defer parsed.deinit();

    config.applyOverrides(parsed.value);

    try std.testing.expectEqual(@as(usize, 1), config.workspace_active_previous.len);
    try std.testing.expect(config.workspace_active_previous[0].alt);
    try std.testing.expectEqual(sdl.Keycode.p, config.workspace_active_previous[0].key);
    try std.testing.expectEqual(@as(usize, 1), config.workspace_active_next.len);
    try std.testing.expect(config.workspace_active_next[0].alt);
    try std.testing.expectEqual(sdl.Keycode.n, config.workspace_active_next[0].key);
}

test "scrolling workspace keybinds are configurable" {
    var config = try NativeKeyboardConfig.load(std.testing.allocator);
    defer config.deinit();

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator,
        \\{"keybinds": {"workspace": {
        \\  "focus_left": "Alt+H", "focus_right": "Alt+L",
        \\  "focus_up": "Alt+K", "focus_down": "Alt+J",
        \\  "move_left": "Alt+Shift+H", "move_right": "Alt+Shift+L",
        \\  "move_up": "Alt+Shift+K", "move_down": "Alt+Shift+J",
        \\  "pane_previous": "Alt+P", "pane_next": "Alt+N",
        \\  "pane_select": ["Alt+1", "Alt+2"]
        \\}}}
    , .{});
    defer parsed.deinit();

    config.applyOverrides(parsed.value);

    const overridden = [_][]const Keybind{
        config.workspace_focus_left,
        config.workspace_focus_right,
        config.workspace_focus_up,
        config.workspace_focus_down,
        config.workspace_move_left,
        config.workspace_move_right,
        config.workspace_move_up,
        config.workspace_move_down,
        config.workspace_pane_previous,
        config.workspace_pane_next,
    };
    for (overridden) |bindings| {
        try std.testing.expectEqual(@as(usize, 1), bindings.len);
        try std.testing.expect(bindings[0].alt);
        try std.testing.expect(!bindings[0].ctrl);
    }
    try std.testing.expectEqual(sdl.Keycode.h, config.workspace_focus_left[0].key);
    try std.testing.expectEqual(sdl.Keycode.l, config.workspace_focus_right[0].key);
    try std.testing.expectEqual(sdl.Keycode.k, config.workspace_focus_up[0].key);
    try std.testing.expectEqual(sdl.Keycode.j, config.workspace_focus_down[0].key);
    try std.testing.expect(config.workspace_move_left[0].shift);
    try std.testing.expectEqual(sdl.Keycode.h, config.workspace_move_left[0].key);
    try std.testing.expectEqual(sdl.Keycode.l, config.workspace_move_right[0].key);
    try std.testing.expectEqual(sdl.Keycode.k, config.workspace_move_up[0].key);
    try std.testing.expectEqual(sdl.Keycode.j, config.workspace_move_down[0].key);
    try std.testing.expectEqual(sdl.Keycode.p, config.workspace_pane_previous[0].key);
    try std.testing.expectEqual(sdl.Keycode.n, config.workspace_pane_next[0].key);
    try std.testing.expectEqual(@as(usize, 2), config.workspace_pane_select.len);
    try std.testing.expect(config.workspace_pane_select[0].alt);
    try std.testing.expect(!config.workspace_pane_select[0].ctrl);
    try std.testing.expectEqual(sdl.Keycode.@"1", config.workspace_pane_select[0].key);
    try std.testing.expectEqual(sdl.Keycode.@"2", config.workspace_pane_select[1].key);
}

test "default workspace prompt and move keybinds are configurable actions" {
    var config = try NativeKeyboardConfig.load(std.testing.allocator);
    defer config.deinit();

    try std.testing.expectEqual(@as(usize, 1), config.workspace_focus_prompt.len);
    try std.testing.expectEqual(sdl.Keycode.tab, config.workspace_focus_prompt[0].key);

    try std.testing.expectEqual(@as(usize, 1), config.workspace_move_left.len);
    try std.testing.expect(config.workspace_move_left[0].ctrl);
    try std.testing.expect(config.workspace_move_left[0].shift);
    try std.testing.expectEqual(sdl.Keycode.h, config.workspace_move_left[0].key);

    try std.testing.expectEqual(@as(usize, 1), config.workspace_move_down.len);
    try std.testing.expect(config.workspace_move_down[0].ctrl);
    try std.testing.expect(config.workspace_move_down[0].shift);
    try std.testing.expectEqual(sdl.Keycode.j, config.workspace_move_down[0].key);

    try std.testing.expectEqual(@as(usize, 1), config.workspace_move_up.len);
    try std.testing.expect(config.workspace_move_up[0].ctrl);
    try std.testing.expect(config.workspace_move_up[0].shift);
    try std.testing.expectEqual(sdl.Keycode.k, config.workspace_move_up[0].key);

    try std.testing.expectEqual(@as(usize, 1), config.workspace_move_right.len);
    try std.testing.expect(config.workspace_move_right[0].ctrl);
    try std.testing.expect(config.workspace_move_right[0].shift);
    try std.testing.expectEqual(sdl.Keycode.l, config.workspace_move_right[0].key);
}

test "default sidebar keybind uses primary plus s" {
    var config = try NativeKeyboardConfig.load(std.testing.allocator);
    defer config.deinit();

    try std.testing.expectEqual(@as(usize, 1), config.toggle_sidebar.len);
    try std.testing.expect(!config.toggle_sidebar[0].alt);
    try std.testing.expect(!config.toggle_sidebar[0].ctrl);
    try std.testing.expect(!config.toggle_sidebar[0].meta);
    try std.testing.expect(config.toggle_sidebar[0].primary);
    try std.testing.expectEqual(sdl.Keycode.s, config.toggle_sidebar[0].key);
}

test "default hidden sidebar keybind uses ctrl shift plus s" {
    var config = try NativeKeyboardConfig.load(std.testing.allocator);
    defer config.deinit();

    try std.testing.expectEqual(@as(usize, 1), config.toggle_sidebar_hidden.len);
    try std.testing.expect(!config.toggle_sidebar_hidden[0].alt);
    try std.testing.expect(config.toggle_sidebar_hidden[0].ctrl);
    try std.testing.expect(!config.toggle_sidebar_hidden[0].meta);
    try std.testing.expect(!config.toggle_sidebar_hidden[0].primary);
    try std.testing.expect(config.toggle_sidebar_hidden[0].shift);
    try std.testing.expectEqual(sdl.Keycode.s, config.toggle_sidebar_hidden[0].key);
}

test "default chat scroll keybinds use arrows and paging keys" {
    var config = try NativeKeyboardConfig.load(std.testing.allocator);
    defer config.deinit();

    try std.testing.expectEqual(@as(usize, 1), config.chat_up.len);
    try std.testing.expectEqual(@as(usize, 1), config.chat_down.len);
    try std.testing.expectEqual(@as(usize, 1), config.chat_page_up.len);
    try std.testing.expectEqual(@as(usize, 1), config.chat_page_down.len);
    try std.testing.expectEqual(sdl.Keycode.up, config.chat_up[0].key);
    try std.testing.expectEqual(sdl.Keycode.down, config.chat_down[0].key);
    try std.testing.expectEqual(sdl.Keycode.pageup, config.chat_page_up[0].key);
    try std.testing.expectEqual(sdl.Keycode.pagedown, config.chat_page_down[0].key);
}

test "default GUI chat composer keybinds use alt mnemonics" {
    var config = try NativeKeyboardConfig.load(std.testing.allocator);
    defer config.deinit();

    try std.testing.expectEqual(@as(usize, 1), config.chat_model_picker.len);
    try std.testing.expect(config.chat_model_picker[0].alt);
    try std.testing.expectEqual(sdl.Keycode.m, config.chat_model_picker[0].key);
    try std.testing.expectEqual(@as(usize, 1), config.chat_run_config.len);
    try std.testing.expect(config.chat_run_config[0].alt);
    try std.testing.expectEqual(sdl.Keycode.r, config.chat_run_config[0].key);
}

test "GUI chat composer keybinds are configurable and disableable" {
    var config = try NativeKeyboardConfig.load(std.testing.allocator);
    defer config.deinit();

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator,
        \\{"keybinds": {"chat": {
        \\  "model_picker": "Ctrl+Shift+M",
        \\  "run_config": null
        \\}}}
    , .{});
    defer parsed.deinit();

    config.applyOverrides(parsed.value);

    try std.testing.expectEqual(@as(usize, 1), config.chat_model_picker.len);
    try std.testing.expect(config.chat_model_picker[0].ctrl);
    try std.testing.expect(config.chat_model_picker[0].shift);
    try std.testing.expectEqual(sdl.Keycode.m, config.chat_model_picker[0].key);
    try std.testing.expectEqual(@as(usize, 0), config.chat_run_config.len);
}

test "chat page down keybind override accepts a single accelerator" {
    var config = try NativeKeyboardConfig.load(std.testing.allocator);
    defer config.deinit();

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator,
        \\{"keybinds": {"chat_page_down": "Shift+J"}}
    , .{});
    defer parsed.deinit();

    config.applyOverrides(parsed.value);

    try std.testing.expectEqual(@as(usize, 1), config.chat_page_down.len);
    try std.testing.expect(config.chat_page_down[0].shift);
    try std.testing.expectEqual(sdl.Keycode.j, config.chat_page_down[0].key);
}

test "terminal nested keybind overrides accept workspace actions" {
    var config = try NativeKeyboardConfig.load(std.testing.allocator);
    defer config.deinit();

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator,
        \\{"keybinds": {"terminal": {
        \\  "toggle": "Alt+J",
        \\  "new_tab": "Ctrl+Alt+T",
        \\  "split_right": "Ctrl+Alt+L",
        \\  "focus_right": "Alt+Shift+L"
        \\}}}
    , .{});
    defer parsed.deinit();

    config.applyOverrides(parsed.value);

    try std.testing.expectEqual(@as(usize, 1), config.toggle_terminal.len);
    try std.testing.expect(config.toggle_terminal[0].alt);
    try std.testing.expectEqual(sdl.Keycode.j, config.toggle_terminal[0].key);

    try std.testing.expectEqual(@as(usize, 1), config.terminal_new_tab.len);
    try std.testing.expect(config.terminal_new_tab[0].ctrl);
    try std.testing.expect(config.terminal_new_tab[0].alt);
    try std.testing.expectEqual(sdl.Keycode.t, config.terminal_new_tab[0].key);

    try std.testing.expectEqual(@as(usize, 1), config.terminal_split_right.len);
    try std.testing.expect(config.terminal_split_right[0].ctrl);
    try std.testing.expect(config.terminal_split_right[0].alt);
    try std.testing.expectEqual(sdl.Keycode.l, config.terminal_split_right[0].key);

    try std.testing.expectEqual(@as(usize, 1), config.terminal_focus_right.len);
    try std.testing.expect(config.terminal_focus_right[0].alt);
    try std.testing.expect(config.terminal_focus_right[0].shift);
    try std.testing.expectEqual(sdl.Keycode.l, config.terminal_focus_right[0].key);
}

test "legacy terminal keybind override still maps to terminal toggle" {
    var config = try NativeKeyboardConfig.load(std.testing.allocator);
    defer config.deinit();

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator,
        \\{"keybinds": {"terminal": "Ctrl+Alt+J"}}
    , .{});
    defer parsed.deinit();

    config.applyOverrides(parsed.value);

    try std.testing.expectEqual(@as(usize, 1), config.toggle_terminal.len);
    try std.testing.expect(config.toggle_terminal[0].ctrl);
    try std.testing.expect(config.toggle_terminal[0].alt);
    try std.testing.expectEqual(sdl.Keycode.j, config.toggle_terminal[0].key);
}

test "prefix mode is off by default and arms on ctrl b" {
    // Built-in defaults only: `load` merges the developer's real verde.json,
    // which may legitimately enable prefix mode.
    var prefix = try cloneDefaultPrefixConfig(std.testing.allocator);
    defer prefix.deinit(std.testing.allocator);

    try std.testing.expect(!prefix.enabled);
    try std.testing.expectEqual(@as(usize, 1), prefix.keys.len);
    try std.testing.expect(prefix.keys[0].ctrl);
    try std.testing.expectEqual(sdl.Keycode.b, prefix.keys[0].key);
    try std.testing.expectEqual(DEFAULT_PREFIX_TABLE.len, prefix.bindings.items.len);
}

test "default prefix table covers every app terminal and chat action" {
    var config = try NativeKeyboardConfig.load(std.testing.allocator);
    defer config.deinit();

    inline for (std.meta.fields(NativeKeyboardAction)) |field| {
        const wanted: NativeKeyboardAction = @enumFromInt(field.value);
        var found = switch (wanted) {
            .workspace_split_chat_vertical,
            .workspace_split_chat_horizontal,
            .workspace_split_terminal_vertical,
            .workspace_split_terminal_horizontal,
            => true,
            else => false,
        };
        for (config.prefix.bindings.items) |binding| {
            if (binding.target == .app and binding.target.app == wanted) found = true;
        }
        try std.testing.expect(found);
    }
    inline for (std.meta.fields(NativeTerminalAction)) |field| {
        const wanted: NativeTerminalAction = @enumFromInt(field.value);
        var found = false;
        for (config.prefix.bindings.items) |binding| {
            if (binding.target == .terminal and binding.target.terminal == wanted) found = true;
        }
        try std.testing.expect(found);
    }
    inline for (std.meta.fields(NativeChatAction)) |field| {
        const wanted: NativeChatAction = @enumFromInt(field.value);
        var found = false;
        for (config.prefix.bindings.items) |binding| {
            if (binding.target == .chat and binding.target.chat == wanted) found = true;
        }
        try std.testing.expect(found);
    }
}

test "default prefix table has no duplicate chords" {
    var config = try NativeKeyboardConfig.load(std.testing.allocator);
    defer config.deinit();

    const items = config.prefix.bindings.items;
    for (items, 0..) |binding, index| {
        for (items[index + 1 ..]) |other| {
            try std.testing.expect(!binding.key.eql(other.key));
        }
    }
}

test "default prefix pane tile chords use default and shifted alternate actions" {
    var config = try NativeKeyboardConfig.load(std.testing.allocator);
    defer config.deinit();

    var default_vertical = false;
    var default_horizontal = false;
    var alternate_vertical = false;
    var alternate_horizontal = false;
    for (config.prefix.bindings.items) |binding| {
        if (binding.key.eql(.{ .key = .v })) {
            default_vertical = binding.target == .split_default_vertical;
        }
        if (binding.key.eql(.{ .key = .minus })) {
            default_horizontal = binding.target == .split_default_horizontal;
        }
        if (binding.key.eql(.{ .shift = true, .key = .v })) {
            alternate_vertical = binding.target == .split_alternate_vertical;
        }
        if (binding.key.eql(.{ .shift = true, .key = .minus })) {
            alternate_horizontal = binding.target == .split_alternate_horizontal;
        }
    }
    try std.testing.expect(default_vertical and default_horizontal and alternate_vertical and alternate_horizontal);

    var navigate_default_vertical = false;
    var navigate_default_horizontal = false;
    var navigate_alternate_vertical = false;
    var navigate_alternate_horizontal = false;
    for (config.prefix.navigate.items) |binding| {
        if (binding.key.eql(.{ .key = .v })) navigate_default_vertical = binding.target == .split_default_vertical;
        if (binding.key.eql(.{ .key = .minus })) navigate_default_horizontal = binding.target == .split_default_horizontal;
        if (binding.key.eql(.{ .shift = true, .key = .v })) navigate_alternate_vertical = binding.target == .split_alternate_vertical;
        if (binding.key.eql(.{ .shift = true, .key = .minus })) navigate_alternate_horizontal = binding.target == .split_alternate_horizontal;
    }
    try std.testing.expect(navigate_default_vertical and navigate_default_horizontal and navigate_alternate_vertical and navigate_alternate_horizontal);
}

test "prefix shorthand bool and string overrides" {
    var config = try NativeKeyboardConfig.load(std.testing.allocator);
    defer config.deinit();

    var enabled = try std.json.parseFromSlice(std.json.Value, std.testing.allocator,
        \\{"keybinds": {"prefix": true}}
    , .{});
    defer enabled.deinit();
    config.applyOverrides(enabled.value);
    try std.testing.expect(config.prefix.enabled);

    var rekeyed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator,
        \\{"keybinds": {"prefix": "Ctrl+A"}}
    , .{});
    defer rekeyed.deinit();
    config.applyOverrides(rekeyed.value);
    try std.testing.expect(config.prefix.enabled);
    try std.testing.expectEqual(@as(usize, 1), config.prefix.keys.len);
    try std.testing.expectEqual(sdl.Keycode.a, config.prefix.keys[0].key);
}

test "prefix object override changes key and merges bindings" {
    var config = try NativeKeyboardConfig.load(std.testing.allocator);
    defer config.deinit();
    const default_count = config.prefix.bindings.items.len;

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator,
        \\{"keybinds": {"prefix": {
        \\  "enabled": true,
        \\  "key": ["Ctrl+Space", "Ctrl+B"],
        \\  "bindings": {
        \\    "x": "workspace.close_current",
        \\    "z": null,
        \\    "g": { "command": "lazygit" },
        \\    "Shift+3": { "action": "workspace.select.3" },
        \\    "bogus": "not.an.action"
        \\  }
        \\}}}
    , .{});
    defer parsed.deinit();
    config.applyOverrides(parsed.value);

    try std.testing.expect(config.prefix.enabled);
    try std.testing.expectEqual(@as(usize, 2), config.prefix.keys.len);
    try std.testing.expectEqual(sdl.Keycode.space, config.prefix.keys[0].key);
    // x replaced, z removed, g added, Shift+3 replaced, bogus ignored.
    try std.testing.expectEqual(default_count, config.prefix.bindings.items.len);

    var saw_x = false;
    var saw_g = false;
    var saw_three = false;
    for (config.prefix.bindings.items) |binding| {
        if (binding.key.eql(.{ .key = .x })) {
            saw_x = true;
            try std.testing.expectEqual(NativeKeyboardAction.workspace_close_current, binding.target.app);
        }
        if (binding.key.eql(.{ .key = .z })) return error.TestUnexpectedResult;
        if (binding.key.eql(.{ .key = .g })) {
            saw_g = true;
            try std.testing.expectEqualStrings("lazygit", binding.target.command);
        }
        if (binding.key.eql(.{ .shift = true, .key = .@"3" })) {
            saw_three = true;
            try std.testing.expectEqual(@as(usize, 2), binding.target.workspace_select);
        }
    }
    try std.testing.expect(saw_x and saw_g and saw_three);
}

test "prefix defaults false drops the built-in table" {
    var config = try NativeKeyboardConfig.load(std.testing.allocator);
    defer config.deinit();

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator,
        \\{"keybinds": {"prefix": {"defaults": false, "bindings": {"c": "new_thread"}}}}
    , .{});
    defer parsed.deinit();
    config.applyOverrides(parsed.value);

    try std.testing.expectEqual(@as(usize, 1), config.prefix.bindings.items.len);
    try std.testing.expectEqual(NativeKeyboardAction.new_thread, config.prefix.bindings.items[0].target.app);
}

test "prefix action names resolve positional ordinals" {
    try std.testing.expectEqual(@as(usize, 0), parsePrefixActionName("workspace.pane_select.1").?.pane_select);
    try std.testing.expectEqual(@as(usize, 9), parsePrefixActionName("Workspace.Active_Select.10").?.active_select);
    try std.testing.expect(parsePrefixActionName("workspace.select.0") == null);
    try std.testing.expect(parsePrefixActionName("workspace.select.x") == null);
    try std.testing.expect(parsePrefixActionName("workspace.focus_prompt").? == .focus_prompt);
}

test "punctuation accelerators parse and format" {
    try std.testing.expectEqual(sdl.Keycode.grave, parseAccelerator("`").?.key);
    try std.testing.expectEqual(sdl.Keycode.backslash, parseAccelerator("Shift+Backslash").?.key);
    try std.testing.expectEqual(sdl.Keycode.leftbracket, parseAccelerator("[").?.key);
    try std.testing.expectEqual(sdl.Keycode.comma, parseAccelerator("Comma").?.key);
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("Shift+[", formatKeybind(&buf, .{ .shift = true, .key = .leftbracket }));
}

test "prefix target labels cover positional and script targets" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("Pane 3", prefixTargetLabel(&buf, .{ .pane_select = 2 }));
    try std.testing.expectEqualStrings("Command palette", prefixTargetLabel(&buf, .{ .app = .command_palette }));
    var script = [_]u8{ 'l', 's' };
    try std.testing.expectEqualStrings("$ ls", prefixTargetLabel(&buf, .{ .command = &script }));
}

test "navigate table overrides merge like the prefix table" {
    var config = try NativeKeyboardConfig.load(std.testing.allocator);
    defer config.deinit();

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator,
        \\{"keybinds": {"prefix": {"navigate": {"Up": null, "g": { "command": "lazygit" }}}}}
    , .{});
    defer parsed.deinit();
    config.applyOverrides(parsed.value);

    var saw_g = false;
    for (config.prefix.navigate.items) |binding| {
        if (binding.key.eql(.{ .key = .up })) return error.TestUnexpectedResult;
        if (binding.key.eql(.{ .key = .g })) saw_g = true;
    }
    try std.testing.expect(saw_g);
    try std.testing.expect(parsePrefixActionName("prefix.navigate").? == .navigate);
}
