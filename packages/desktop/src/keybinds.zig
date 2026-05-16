//! Keyboard shortcut loading and matching for the native Verde shell.

const std = @import("std");
const builtin = @import("builtin");
const sdl = @import("zsdl3");
const shared_config = @import("config.zig");

const log = std.log.scoped(.native_keybinds);

pub const NativeKeyboardAction = enum {
    refresh,
    open_default,
    new_thread,
    toggle_sidebar,
    toggle_sidebar_hidden,
    toggle_browser,
    toggle_terminal,
    chat_up,
    chat_down,
    chat_page_up,
    chat_page_down,
    workspace_split_chat_vertical,
    workspace_split_chat_horizontal,
    workspace_split_terminal_vertical,
    workspace_split_terminal_horizontal,
    workspace_toggle_maximize,
    workspace_minimize,
    workspace_close,
    workspace_focus_left,
    workspace_focus_right,
    workspace_focus_up,
    workspace_focus_down,
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

pub const NativeKeyboardConfig = struct {
    allocator: std.mem.Allocator,
    refresh: []Keybind,
    open_default: []Keybind,
    new_thread: []Keybind,
    toggle_sidebar: []Keybind,
    toggle_sidebar_hidden: []Keybind,
    toggle_browser: []Keybind,
    toggle_terminal: []Keybind,
    chat_up: []Keybind,
    chat_down: []Keybind,
    chat_page_up: []Keybind,
    chat_page_down: []Keybind,
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
    workspace_minimize: []Keybind,
    workspace_close: []Keybind,
    workspace_focus_left: []Keybind,
    workspace_focus_right: []Keybind,
    workspace_focus_up: []Keybind,
    workspace_focus_down: []Keybind,
    workspace_grow_left: []Keybind,
    workspace_grow_right: []Keybind,
    workspace_grow_up: []Keybind,
    workspace_grow_down: []Keybind,

    pub fn load(allocator: std.mem.Allocator) !NativeKeyboardConfig {
        var config: NativeKeyboardConfig = .{
            .allocator = allocator,
            .refresh = try cloneDefaultKeybinds(allocator),
            .open_default = try cloneDefaultOpenKeybinds(allocator),
            .new_thread = try cloneDefaultNewThreadKeybinds(allocator),
            .toggle_sidebar = try cloneDefaultSidebarKeybinds(allocator),
            .toggle_sidebar_hidden = try cloneDefaultSidebarHiddenKeybinds(allocator),
            .toggle_browser = try cloneDefaultBrowserKeybinds(allocator),
            .toggle_terminal = try cloneDefaultTerminalKeybinds(allocator),
            .chat_up = try cloneDefaultChatUpKeybinds(allocator),
            .chat_down = try cloneDefaultChatDownKeybinds(allocator),
            .chat_page_up = try cloneDefaultChatPageUpKeybinds(allocator),
            .chat_page_down = try cloneDefaultChatPageDownKeybinds(allocator),
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
            .workspace_minimize = try cloneEmptyKeybinds(allocator),
            .workspace_close = try cloneDefaultWorkspaceCloseKeybinds(allocator),
            .workspace_focus_left = try cloneDefaultWorkspaceFocusLeftKeybinds(allocator),
            .workspace_focus_right = try cloneDefaultWorkspaceFocusRightKeybinds(allocator),
            .workspace_focus_up = try cloneDefaultWorkspaceFocusUpKeybinds(allocator),
            .workspace_focus_down = try cloneDefaultWorkspaceFocusDownKeybinds(allocator),
            .workspace_grow_left = try cloneDefaultWorkspaceGrowLeftKeybinds(allocator),
            .workspace_grow_right = try cloneDefaultWorkspaceGrowRightKeybinds(allocator),
            .workspace_grow_up = try cloneDefaultWorkspaceGrowUpKeybinds(allocator),
            .workspace_grow_down = try cloneDefaultWorkspaceGrowDownKeybinds(allocator),
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
        self.allocator.free(self.new_thread);
        self.allocator.free(self.toggle_sidebar);
        self.allocator.free(self.toggle_sidebar_hidden);
        self.allocator.free(self.toggle_browser);
        self.allocator.free(self.toggle_terminal);
        self.allocator.free(self.chat_up);
        self.allocator.free(self.chat_down);
        self.allocator.free(self.chat_page_up);
        self.allocator.free(self.chat_page_down);
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
        self.allocator.free(self.workspace_minimize);
        self.allocator.free(self.workspace_close);
        self.allocator.free(self.workspace_focus_left);
        self.allocator.free(self.workspace_focus_right);
        self.allocator.free(self.workspace_focus_up);
        self.allocator.free(self.workspace_focus_down);
        self.allocator.free(self.workspace_grow_left);
        self.allocator.free(self.workspace_grow_right);
        self.allocator.free(self.workspace_grow_up);
        self.allocator.free(self.workspace_grow_down);
    }

    pub fn actionForEvent(self: *const NativeKeyboardConfig, event: *const sdl.KeyboardEvent) ?NativeKeyboardAction {
        if (matchesAny(self.refresh, event)) {
            return .refresh;
        }
        if (matchesAny(self.open_default, event)) {
            return .open_default;
        }
        if (matchesAny(self.new_thread, event)) {
            return .new_thread;
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
        if (matchesAny(self.workspace_minimize, event)) {
            return .workspace_minimize;
        }
        if (matchesAny(self.workspace_close, event)) {
            return .workspace_close;
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
        if (keybinds_value.object.get("new_thread")) |new_thread_value| {
            if (self.parseOverrideValue(new_thread_value, "new_thread")) |bindings| {
                self.allocator.free(self.new_thread);
                self.new_thread = bindings;
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
        if (keybinds_value.object.get("workspace")) |workspace_value| {
            self.applyWorkspaceOverrides(workspace_value);
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
        if (workspace_value.object.get("minimize")) |value| {
            if (self.parseOverrideValue(value, "workspace.minimize")) |bindings| {
                self.allocator.free(self.workspace_minimize);
                self.workspace_minimize = bindings;
            }
        }
        if (workspace_value.object.get("close")) |value| {
            if (self.parseOverrideValue(value, "workspace.close")) |bindings| {
                self.allocator.free(self.workspace_close);
                self.workspace_close = bindings;
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
            log.warn("ignoring invalid keybind for {s}: {s}", .{ field_name, trimmed });
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
                log.warn("ignoring invalid keybind for {s}: {s}", .{ field_name, trimmed });
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

fn cloneDefaultKeybinds(allocator: std.mem.Allocator) ![]Keybind {
    return allocator.dupe(Keybind, &.{
        try parseDefaultAccelerator("CommandOrControl+R"),
        try parseDefaultAccelerator("CommandOrControl+Shift+R"),
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

fn cloneDefaultNewThreadKeybinds(allocator: std.mem.Allocator) ![]Keybind {
    return allocator.dupe(Keybind, &.{
        try parseDefaultAccelerator("CommandOrControl+T"),
    });
}

fn cloneDefaultWorkspaceCloseKeybinds(allocator: std.mem.Allocator) ![]Keybind {
    return allocator.dupe(Keybind, &.{
        try parseDefaultAccelerator("CommandOrControl+W"),
    });
}

fn cloneDefaultSidebarKeybinds(allocator: std.mem.Allocator) ![]Keybind {
    return allocator.dupe(Keybind, &.{
        try parseDefaultAccelerator("CommandOrControl+S"),
    });
}

fn cloneDefaultSidebarHiddenKeybinds(allocator: std.mem.Allocator) ![]Keybind {
    return allocator.dupe(Keybind, &.{
        try parseDefaultAccelerator("Alt+B"),
    });
}

fn cloneDefaultTerminalKeybinds(allocator: std.mem.Allocator) ![]Keybind {
    return allocator.dupe(Keybind, &.{
        try parseDefaultAccelerator("CommandOrControl+J"),
    });
}

fn cloneDefaultBrowserKeybinds(allocator: std.mem.Allocator) ![]Keybind {
    return allocator.dupe(Keybind, &.{
        try parseDefaultAccelerator("Ctrl+B"),
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
    return allocator.dupe(Keybind, &.{
        try parseDefaultAccelerator("CommandOrControl+Shift+Up"),
    });
}

fn cloneDefaultTerminalSplitDownKeybinds(allocator: std.mem.Allocator) ![]Keybind {
    return allocator.dupe(Keybind, &.{
        try parseDefaultAccelerator("CommandOrControl+Shift+E"),
        try parseDefaultAccelerator("CommandOrControl+Shift+Down"),
    });
}

fn cloneDefaultTerminalSplitLeftKeybinds(allocator: std.mem.Allocator) ![]Keybind {
    return allocator.dupe(Keybind, &.{
        try parseDefaultAccelerator("CommandOrControl+Shift+Left"),
    });
}

fn cloneDefaultTerminalSplitRightKeybinds(allocator: std.mem.Allocator) ![]Keybind {
    return allocator.dupe(Keybind, &.{
        try parseDefaultAccelerator("CommandOrControl+Shift+O"),
        try parseDefaultAccelerator("CommandOrControl+Shift+Right"),
    });
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
        try parseDefaultAccelerator("Alt+Left"),
    });
}

fn cloneDefaultWorkspaceFocusRightKeybinds(allocator: std.mem.Allocator) ![]Keybind {
    return allocator.dupe(Keybind, &.{
        try parseDefaultAccelerator("Alt+Right"),
    });
}

fn cloneDefaultWorkspaceFocusUpKeybinds(allocator: std.mem.Allocator) ![]Keybind {
    return allocator.dupe(Keybind, &.{
        try parseDefaultAccelerator("Alt+Up"),
    });
}

fn cloneDefaultWorkspaceFocusDownKeybinds(allocator: std.mem.Allocator) ![]Keybind {
    return allocator.dupe(Keybind, &.{
        try parseDefaultAccelerator("Alt+Down"),
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

    return null;
}

test "parse accelerator matches desktop-style refresh binding" {
    const binding = parseAccelerator("CommandOrControl+R") orelse return error.TestUnexpectedResult;

    try std.testing.expect(binding.primary);
    try std.testing.expectEqual(false, binding.shift);
    try std.testing.expectEqual(sdl.Keycode.r, binding.key);
}

test "array parsing deduplicates repeated bindings" {
    var config = try NativeKeyboardConfig.load(std.testing.allocator);
    defer config.deinit();

    const root: std.json.Value = .{
        .object = blk: {
            var object = std.json.ObjectMap.init(std.testing.allocator);
            errdefer object.deinit();

            var keybinds = std.json.ObjectMap.init(std.testing.allocator);
            errdefer keybinds.deinit();

            var bindings = std.json.Array.init(std.testing.allocator);
            errdefer bindings.deinit();
            try bindings.append(.{ .string = "F5" });
            try bindings.append(.{ .string = "f5" });

            try keybinds.put("refresh", .{ .array = bindings });
            try object.put("keybinds", .{ .object = keybinds });
            break :blk object;
        },
    };
    defer root.object.deinit();

    config.applyOverrides(root);

    try std.testing.expectEqual(@as(usize, 1), config.refresh.len);
    try std.testing.expectEqual(sdl.Keycode.f5, config.refresh[0].key);
}

test "open keybind override accepts a single accelerator" {
    var config = try NativeKeyboardConfig.load(std.testing.allocator);
    defer config.deinit();

    const root: std.json.Value = .{
        .object = blk: {
            var object = std.json.ObjectMap.init(std.testing.allocator);
            errdefer object.deinit();

            var keybinds = std.json.ObjectMap.init(std.testing.allocator);
            errdefer keybinds.deinit();

            try keybinds.put("open", .{ .string = "Ctrl+Shift+O" });
            try object.put("keybinds", .{ .object = keybinds });
            break :blk object;
        },
    };
    defer root.object.deinit();

    config.applyOverrides(root);

    try std.testing.expectEqual(@as(usize, 1), config.open_default.len);
    try std.testing.expect(config.open_default[0].ctrl);
    try std.testing.expect(config.open_default[0].shift);
    try std.testing.expectEqual(sdl.Keycode.o, config.open_default[0].key);
}

test "browser keybind override accepts a single accelerator" {
    var config = try NativeKeyboardConfig.load(std.testing.allocator);
    defer config.deinit();

    const root: std.json.Value = .{
        .object = blk: {
            var object = std.json.ObjectMap.init(std.testing.allocator);
            errdefer object.deinit();

            var keybinds = std.json.ObjectMap.init(std.testing.allocator);
            errdefer keybinds.deinit();

            try keybinds.put("browser", .{ .string = "Alt+Shift+B" });
            try object.put("keybinds", .{ .object = keybinds });
            break :blk object;
        },
    };
    defer root.object.deinit();

    config.applyOverrides(root);

    try std.testing.expectEqual(@as(usize, 1), config.toggle_browser.len);
    try std.testing.expect(config.toggle_browser[0].alt);
    try std.testing.expect(config.toggle_browser[0].shift);
    try std.testing.expectEqual(sdl.Keycode.b, config.toggle_browser[0].key);
}

test "new thread keybind override accepts a single accelerator" {
    var config = try NativeKeyboardConfig.load(std.testing.allocator);
    defer config.deinit();

    const root: std.json.Value = .{
        .object = blk: {
            var object = std.json.ObjectMap.init(std.testing.allocator);
            errdefer object.deinit();

            var keybinds = std.json.ObjectMap.init(std.testing.allocator);
            errdefer keybinds.deinit();

            try keybinds.put("new_thread", .{ .string = "Alt+Shift+T" });
            try object.put("keybinds", .{ .object = keybinds });
            break :blk object;
        },
    };
    defer root.object.deinit();

    config.applyOverrides(root);

    try std.testing.expectEqual(@as(usize, 1), config.new_thread.len);
    try std.testing.expect(config.new_thread[0].alt);
    try std.testing.expect(config.new_thread[0].shift);
    try std.testing.expectEqual(sdl.Keycode.t, config.new_thread[0].key);
}

test "sidebar keybind override accepts a single accelerator" {
    var config = try NativeKeyboardConfig.load(std.testing.allocator);
    defer config.deinit();

    const root: std.json.Value = .{
        .object = blk: {
            var object = std.json.ObjectMap.init(std.testing.allocator);
            errdefer object.deinit();

            var keybinds = std.json.ObjectMap.init(std.testing.allocator);
            errdefer keybinds.deinit();

            try keybinds.put("sidebar", .{ .string = "Ctrl+Shift+M" });
            try object.put("keybinds", .{ .object = keybinds });
            break :blk object;
        },
    };
    defer root.object.deinit();

    config.applyOverrides(root);

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

test "default browser keybind uses ctrl plus b" {
    var config = try NativeKeyboardConfig.load(std.testing.allocator);
    defer config.deinit();

    try std.testing.expectEqual(@as(usize, 1), config.toggle_browser.len);
    try std.testing.expect(!config.toggle_browser[0].alt);
    try std.testing.expect(config.toggle_browser[0].ctrl);
    try std.testing.expect(!config.toggle_browser[0].meta);
    try std.testing.expect(!config.toggle_browser[0].primary);
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

test "default hidden sidebar keybind uses alt plus b" {
    var config = try NativeKeyboardConfig.load(std.testing.allocator);
    defer config.deinit();

    try std.testing.expectEqual(@as(usize, 1), config.toggle_sidebar_hidden.len);
    try std.testing.expect(config.toggle_sidebar_hidden[0].alt);
    try std.testing.expect(!config.toggle_sidebar_hidden[0].ctrl);
    try std.testing.expect(!config.toggle_sidebar_hidden[0].meta);
    try std.testing.expect(!config.toggle_sidebar_hidden[0].primary);
    try std.testing.expectEqual(sdl.Keycode.b, config.toggle_sidebar_hidden[0].key);
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

test "chat page down keybind override accepts a single accelerator" {
    var config = try NativeKeyboardConfig.load(std.testing.allocator);
    defer config.deinit();

    const root: std.json.Value = .{
        .object = blk: {
            var object = std.json.ObjectMap.init(std.testing.allocator);
            errdefer object.deinit();

            var keybinds = std.json.ObjectMap.init(std.testing.allocator);
            errdefer keybinds.deinit();

            try keybinds.put("chat_page_down", .{ .string = "Shift+J" });
            try object.put("keybinds", .{ .object = keybinds });
            break :blk object;
        },
    };
    defer root.object.deinit();

    config.applyOverrides(root);

    try std.testing.expectEqual(@as(usize, 1), config.chat_page_down.len);
    try std.testing.expect(config.chat_page_down[0].shift);
    try std.testing.expectEqual(sdl.Keycode.j, config.chat_page_down[0].key);
}

test "terminal nested keybind overrides accept workspace actions" {
    var config = try NativeKeyboardConfig.load(std.testing.allocator);
    defer config.deinit();

    const root: std.json.Value = .{
        .object = blk: {
            var object = std.json.ObjectMap.init(std.testing.allocator);
            errdefer object.deinit();

            var keybinds = std.json.ObjectMap.init(std.testing.allocator);
            errdefer keybinds.deinit();

            var terminal = std.json.ObjectMap.init(std.testing.allocator);
            errdefer terminal.deinit();

            try terminal.put("toggle", .{ .string = "Alt+J" });
            try terminal.put("new_tab", .{ .string = "Ctrl+Alt+T" });
            try terminal.put("split_right", .{ .string = "Ctrl+Alt+L" });
            try terminal.put("focus_right", .{ .string = "Alt+Shift+L" });
            try keybinds.put("terminal", .{ .object = terminal });
            try object.put("keybinds", .{ .object = keybinds });
            break :blk object;
        },
    };
    defer root.object.deinit();

    config.applyOverrides(root);

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

    const root: std.json.Value = .{
        .object = blk: {
            var object = std.json.ObjectMap.init(std.testing.allocator);
            errdefer object.deinit();

            var keybinds = std.json.ObjectMap.init(std.testing.allocator);
            errdefer keybinds.deinit();

            try keybinds.put("terminal", .{ .string = "Ctrl+Alt+J" });
            try object.put("keybinds", .{ .object = keybinds });
            break :blk object;
        },
    };
    defer root.object.deinit();

    config.applyOverrides(root);

    try std.testing.expectEqual(@as(usize, 1), config.toggle_terminal.len);
    try std.testing.expect(config.toggle_terminal[0].ctrl);
    try std.testing.expect(config.toggle_terminal[0].alt);
    try std.testing.expectEqual(sdl.Keycode.j, config.toggle_terminal[0].key);
}
