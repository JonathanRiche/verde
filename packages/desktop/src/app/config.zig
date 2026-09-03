//! Shared user config loading for the native Verde shell.

const std = @import("std");
const platform_paths = @import("platform_paths");
const provider_models = @import("../state/provider_models.zig");
const theme = @import("../ui/theme.zig");

const log = std.log.scoped(.native_config);
pub const MIN_FONT_SIZE: f32 = 10.0;
pub const MAX_FONT_SIZE: f32 = 32.0;
pub const DEFAULT_TERMINAL_FONT_SIZE: f32 = 18.0;
pub const MIN_TERMINAL_FONT_SIZE: f32 = 13.5;
pub const MAX_TERMINAL_FONT_SIZE: f32 = 60.0;
pub const DEFAULT_WORKSPACE_PANE_GAP: f32 = 12.0;
pub const MIN_WORKSPACE_PANE_GAP: f32 = 0.0;
pub const MAX_WORKSPACE_PANE_GAP: f32 = 64.0;
pub const DEFAULT_WORKSPACE_PANES_PER_VIEW: u8 = 2;
pub const MIN_WORKSPACE_PANES_PER_VIEW: u8 = 1;
pub const MAX_WORKSPACE_PANES_PER_VIEW: u8 = 6;
pub const DEFAULT_WORKSPACE_SCROLL_THRESHOLD: u8 = 2;
pub const MIN_WORKSPACE_SCROLL_THRESHOLD: u8 = 1;
pub const MAX_WORKSPACE_SCROLL_THRESHOLD: u8 = 64;
pub const DEFAULT_BROWSER_SCROLL_SPEED: f32 = 2.5;
pub const MIN_BROWSER_SCROLL_SPEED: f32 = 1.0;
pub const MAX_BROWSER_SCROLL_SPEED: f32 = 5.0;
pub const BROWSER_SCROLL_SPEED_STEP: f32 = 0.25;
pub const DEFAULT_CHAT_TITLE_MODEL = "gpt-5.6-luna";

pub const ChatProvider = enum {
    codex,
    claude,
    cursor,
    opencode,
    pi,
    fx,
    grok,

    pub fn parse(value: []const u8) ?ChatProvider {
        inline for (std.meta.fields(ChatProvider)) |field| {
            if (std.mem.eql(u8, value, field.name)) return @enumFromInt(field.value);
        }
        return null;
    }
};

pub const ChatReasoning = enum {
    provider_default,
    low,
    medium,
    high,
    xhigh,
    max,

    pub fn parse(value: []const u8) ?ChatReasoning {
        if (std.mem.eql(u8, value, "default")) return .provider_default;
        inline for (std.meta.fields(ChatReasoning)) |field| {
            if (std.mem.eql(u8, value, field.name)) return @enumFromInt(field.value);
        }
        return null;
    }

    pub fn configValue(self: ChatReasoning) []const u8 {
        return if (self == .provider_default) "default" else @tagName(self);
    }
};

pub const FavoriteModel = struct {
    provider: ChatProvider,
    model: []u8,

    pub fn deinit(self: *FavoriteModel, allocator: std.mem.Allocator) void {
        allocator.free(self.model);
    }
};

pub const ChatTitleProvider = enum {
    codex,
    claude,
    cursor,
    opencode,

    pub fn parse(value: []const u8) ?ChatTitleProvider {
        if (std.mem.eql(u8, value, "codex")) return .codex;
        if (std.mem.eql(u8, value, "claude")) return .claude;
        if (std.mem.eql(u8, value, "cursor")) return .cursor;
        if (std.mem.eql(u8, value, "opencode")) return .opencode;
        return null;
    }
};

pub const CompanionCharacter = enum {
    sprout,
    moss,
    vireo,

    pub fn parse(value: []const u8) ?CompanionCharacter {
        if (std.ascii.eqlIgnoreCase(value, "sprout")) return .sprout;
        if (std.ascii.eqlIgnoreCase(value, "moss")) return .moss;
        if (std.ascii.eqlIgnoreCase(value, "vireo")) return .vireo;
        return null;
    }
};

pub const CustomOpenAction = struct {
    label: []u8,
    action: []u8,

    pub fn clone(self: CustomOpenAction, allocator: std.mem.Allocator) !CustomOpenAction {
        return .{
            .label = try allocator.dupe(u8, self.label),
            .action = try allocator.dupe(u8, self.action),
        };
    }

    pub fn deinit(self: *CustomOpenAction, allocator: std.mem.Allocator) void {
        allocator.free(self.label);
        allocator.free(self.action);
    }
};

pub const DefaultOpenAction = union(enum) {
    folder,
    editor,
    cursor,
    vscode,
    zed,
    custom: CustomOpenAction,

    pub fn clone(self: DefaultOpenAction, allocator: std.mem.Allocator) !DefaultOpenAction {
        return switch (self) {
            .folder => .folder,
            .editor => .editor,
            .cursor => .cursor,
            .vscode => .vscode,
            .zed => .zed,
            .custom => |custom| .{ .custom = try custom.clone(allocator) },
        };
    }

    pub fn deinit(self: *DefaultOpenAction, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .custom => |*custom| custom.deinit(allocator),
            else => {},
        }
    }
};

pub const LinkOpenTarget = enum {
    verde_browser,
    system_browser,
};

pub const LinkOpenOverride = enum {
    global,
    verde_browser,
    system_browser,

    pub fn resolve(self: LinkOpenOverride, global: LinkOpenTarget) LinkOpenTarget {
        return switch (self) {
            .global => global,
            .verde_browser => .verde_browser,
            .system_browser => .system_browser,
        };
    }
};

pub const ToolCallGroupPreference = enum {
    collapsed,
    expanded,
    remember_last,
};

pub const DiffLayoutPreference = enum {
    stacked,
    split,
};

pub const NewChatPaneBehavior = enum {
    new_pane,
    replace_pane,
};

pub const WorkspaceSplitDefaultPane = enum {
    chat,
    terminal,

    pub fn parse(value: []const u8) ?WorkspaceSplitDefaultPane {
        if (std.ascii.eqlIgnoreCase(value, "chat")) return .chat;
        if (std.ascii.eqlIgnoreCase(value, "terminal")) return .terminal;
        return null;
    }
};

pub const WorkspaceScrollDirection = enum {
    horizontal,
    vertical,

    pub fn parse(value: []const u8) ?WorkspaceScrollDirection {
        if (std.ascii.eqlIgnoreCase(value, "horizontal")) return .horizontal;
        if (std.ascii.eqlIgnoreCase(value, "vertical")) return .vertical;
        return null;
    }
};

/// Where the top-of-pane tab strip (one tab per workspace tile, see
/// `state/workspace_tabs.zig`) appears: `automatic` only when the sidebar is
/// collapsed or hidden, `always` alongside the expanded sidebar too,
/// `disabled` never.
pub const WorkspaceTabsMode = enum {
    automatic,
    always,
    disabled,

    pub fn parse(value: []const u8) ?WorkspaceTabsMode {
        if (std.ascii.eqlIgnoreCase(value, "automatic")) return .automatic;
        if (std.ascii.eqlIgnoreCase(value, "always")) return .always;
        if (std.ascii.eqlIgnoreCase(value, "disabled")) return .disabled;
        return null;
    }
};

pub const WorkspaceScrollMode = enum {
    automatic,
    always,
    disabled,

    pub fn parse(value: []const u8) ?WorkspaceScrollMode {
        if (std.ascii.eqlIgnoreCase(value, "automatic")) return .automatic;
        if (std.ascii.eqlIgnoreCase(value, "always")) return .always;
        if (std.ascii.eqlIgnoreCase(value, "disabled")) return .disabled;
        return null;
    }
};

pub const TerminalLaunchProfileConfig = struct {
    label: []u8,
    command: []const []u8,

    pub fn deinit(self: *TerminalLaunchProfileConfig, allocator: std.mem.Allocator) void {
        allocator.free(self.label);
        for (self.command) |arg| allocator.free(arg);
        allocator.free(self.command);
    }
};

pub const InstalledTheme = struct {
    name: []u8,
    theme_config: theme.ThemeConfig,
    font_size: ?f32 = null,
    terminal_font_size: ?f32 = null,

    pub fn deinit(self: *InstalledTheme, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        self.* = undefined;
    }

    pub fn apply(self: InstalledTheme, config: *AppConfig) void {
        config.theme_config = self.theme_config;
        if (self.font_size) |value| config.font_size = value;
        if (self.terminal_font_size) |value| config.terminal_font_size = value;
    }
};

pub const AppConfig = struct {
    font_size: f32 = theme.DEFAULT_FONT_SIZE,
    terminal_font_size: f32 = DEFAULT_TERMINAL_FONT_SIZE,
    workspace_pane_gap: f32 = DEFAULT_WORKSPACE_PANE_GAP,
    workspace_panes_per_view: u8 = DEFAULT_WORKSPACE_PANES_PER_VIEW,
    workspace_split_default_pane: WorkspaceSplitDefaultPane = .chat,
    workspace_scroll_direction: WorkspaceScrollDirection = .horizontal,
    workspace_scroll_mode: WorkspaceScrollMode = .automatic,
    workspace_scroll_threshold: u8 = DEFAULT_WORKSPACE_SCROLL_THRESHOLD,
    unzoom_on_pane_navigation: bool = false,
    reduced_motion: bool = false,
    workspace_tabs: WorkspaceTabsMode = .automatic,
    /// Pane kind the tab strip's "+" opens as a new tab.
    workspace_new_tab_pane: WorkspaceSplitDefaultPane = .chat,
    companion_enabled: bool = false,
    companion_character: CompanionCharacter = .sprout,
    theme_config: theme.ThemeConfig = .{},
    active_theme: ?[]u8 = null,
    installed_themes: []InstalledTheme = &.{},
    default_open_action: DefaultOpenAction = .folder,
    link_open_target: LinkOpenTarget = .system_browser,
    chat_link_open_override: LinkOpenOverride = .global,
    terminal_link_open_override: LinkOpenOverride = .global,
    browser_scroll_speed: f32 = DEFAULT_BROWSER_SCROLL_SPEED,
    file_links_in_neovim_pane: bool = false,
    terminal_launch_profiles: []TerminalLaunchProfileConfig = &.{},
    tool_call_group_preference: ToolCallGroupPreference = .collapsed,
    tool_call_groups_last_expanded: bool = false,
    diff_layout_preference: DiffLayoutPreference = .stacked,
    automatic_chat_titles_enabled: bool = true,
    chat_title_provider: ChatTitleProvider = .codex,
    chat_title_model: ?[]u8 = null,
    new_chat_provider: ChatProvider = .codex,
    new_chat_model: ?[]u8 = null,
    new_chat_reasoning: ChatReasoning = .low,
    favorite_models: []FavoriteModel = &.{},
    new_chat_pane_behavior: NewChatPaneBehavior = .new_pane,
    check_for_updates_automatically: bool = true,
    // User-scoped provider registration is opt-in because it updates each
    // detected agent's global configuration outside Verde's own config dir.
    mcp_integration_enabled: bool = false,
    mcp_onboarding_completed: bool = false,
    // Fire a desktop notification when an agent surface finishes (transitions
    // to `.done`). Defaults on so the feature works without first opening
    // Settings; users can disable it from the Settings cog / verde.json.
    notifications_enabled: bool = true,

    pub fn deinit(self: *AppConfig, allocator: std.mem.Allocator) void {
        if (self.active_theme) |name| allocator.free(name);
        if (self.chat_title_model) |model| allocator.free(model);
        if (self.new_chat_model) |model| allocator.free(model);
        for (self.favorite_models) |*favorite| favorite.deinit(allocator);
        allocator.free(self.favorite_models);
        for (self.installed_themes) |*installed| installed.deinit(allocator);
        allocator.free(self.installed_themes);
        self.default_open_action.deinit(allocator);
        for (self.terminal_launch_profiles) |*profile| profile.deinit(allocator);
        allocator.free(self.terminal_launch_profiles);
    }

    pub fn chatTitleModel(self: AppConfig) []const u8 {
        return self.chat_title_model orelse switch (self.chat_title_provider) {
            .codex => DEFAULT_CHAT_TITLE_MODEL,
            .claude => provider_models.DEFAULT_CLAUDE_MODEL,
            .cursor => "composer-2",
            .opencode => "opencode/gpt-5.4",
        };
    }

    pub fn setChatTitleModel(self: *AppConfig, allocator: std.mem.Allocator, model: []const u8) !void {
        const owned_model = try allocator.dupe(u8, model);
        if (self.chat_title_model) |previous| allocator.free(previous);
        self.chat_title_model = owned_model;
    }

    pub fn setNewChatModel(self: *AppConfig, allocator: std.mem.Allocator, model: []const u8) !void {
        const owned_model = try allocator.dupe(u8, model);
        if (self.new_chat_model) |previous| allocator.free(previous);
        self.new_chat_model = owned_model;
    }

    pub fn isFavoriteModel(self: AppConfig, provider: ChatProvider, model: []const u8) bool {
        for (self.favorite_models) |favorite| {
            if (favorite.provider == provider and std.mem.eql(u8, favorite.model, model)) return true;
        }
        return false;
    }

    pub fn toggleFavoriteModel(self: *AppConfig, allocator: std.mem.Allocator, provider: ChatProvider, model: []const u8) !bool {
        for (self.favorite_models, 0..) |favorite, index| {
            if (favorite.provider != provider or !std.mem.eql(u8, favorite.model, model)) continue;
            const next = try allocator.alloc(FavoriteModel, self.favorite_models.len - 1);
            @memcpy(next[0..index], self.favorite_models[0..index]);
            @memcpy(next[index..], self.favorite_models[index + 1 ..]);
            allocator.free(self.favorite_models[index].model);
            allocator.free(self.favorite_models);
            self.favorite_models = next;
            return false;
        }
        const owned_model = try allocator.dupe(u8, model);
        errdefer allocator.free(owned_model);
        const next = try allocator.alloc(FavoriteModel, self.favorite_models.len + 1);
        @memcpy(next[0..self.favorite_models.len], self.favorite_models);
        next[self.favorite_models.len] = .{ .provider = provider, .model = owned_model };
        allocator.free(self.favorite_models);
        self.favorite_models = next;
        return true;
    }

    pub fn activeThemeIndex(self: AppConfig) ?usize {
        const active_name = self.active_theme orelse return null;
        for (self.installed_themes, 0..) |installed, index| {
            if (std.ascii.eqlIgnoreCase(active_name, installed.name)) return index;
        }
        return null;
    }

    pub fn themeChoiceIndex(self: AppConfig) usize {
        if (self.activeThemeIndex()) |index| return index + 2;
        return if (self.theme_config.source == .omarchy) 1 else 0;
    }

    pub fn installTheme(
        self: *AppConfig,
        allocator: std.mem.Allocator,
        name: []const u8,
        theme_config: theme.ThemeConfig,
        font_size: ?f32,
        terminal_font_size: ?f32,
    ) !usize {
        for (self.installed_themes, 0..) |*installed, index| {
            if (!std.ascii.eqlIgnoreCase(name, installed.name)) continue;
            const owned_name = try allocator.dupe(u8, name);
            installed.deinit(allocator);
            installed.* = .{
                .name = owned_name,
                .theme_config = theme_config,
                .font_size = font_size,
                .terminal_font_size = terminal_font_size,
            };
            return index;
        }

        const owned_name = try allocator.dupe(u8, name);
        errdefer allocator.free(owned_name);
        const next = try allocator.alloc(InstalledTheme, self.installed_themes.len + 1);
        @memcpy(next[0..self.installed_themes.len], self.installed_themes);
        next[self.installed_themes.len] = .{
            .name = owned_name,
            .theme_config = theme_config,
            .font_size = font_size,
            .terminal_font_size = terminal_font_size,
        };
        const index = self.installed_themes.len;
        allocator.free(self.installed_themes);
        self.installed_themes = next;
        return index;
    }

    pub fn selectThemeChoice(self: *AppConfig, allocator: std.mem.Allocator, choice_index: usize) !void {
        if (choice_index >= self.installed_themes.len + 2) return error.InvalidThemeChoice;
        if (self.active_theme) |name| allocator.free(name);
        self.active_theme = null;

        if (choice_index == 0) {
            self.theme_config = .{ .source = .default };
            return;
        }
        if (choice_index == 1) {
            self.theme_config = .{ .source = .omarchy };
            return;
        }

        const installed = self.installed_themes[choice_index - 2];
        const active_name = try allocator.dupe(u8, installed.name);
        installed.apply(self);
        self.active_theme = active_name;
    }
};

pub fn loadAppConfig(allocator: std.mem.Allocator) !AppConfig {
    var config: AppConfig = .{};

    const parsed = readRootValue(allocator) catch |err| switch (err) {
        error.FileNotFound => return config,
        else => return err,
    };
    if (parsed == null) return config;

    var root = parsed.?;
    defer root.deinit();
    applyAppOverrides(allocator, &config, root.value);
    return config;
}

pub fn readRootValue(allocator: std.mem.Allocator) !?std.json.Parsed(std.json.Value) {
    const config_path = try resolveConfigPath(allocator);
    defer allocator.free(config_path);

    const raw_bytes = readConfigFile(allocator, config_path) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer allocator.free(raw_bytes);

    return try std.json.parseFromSlice(std.json.Value, allocator, raw_bytes, .{
        .allocate = .alloc_always,
    });
}

pub fn configFileMtime(allocator: std.mem.Allocator) !i128 {
    const config_path = try resolveConfigPath(allocator);
    defer allocator.free(config_path);

    var threaded = std.Io.Threaded.init_single_threaded;

    const stat = blk: {
        var file = std.Io.Dir.cwd().openFile(threaded.io(), config_path, .{}) catch |err| switch (err) {
            error.FileNotFound => return -1,
            else => return err,
        };
        defer file.close(threaded.io());
        break :blk try file.stat(threaded.io());
    };
    return @intCast(stat.mtime.toNanoseconds());
}

pub fn saveAppConfig(allocator: std.mem.Allocator, config: *const AppConfig) !void {
    const config_path = try resolveConfigPath(allocator);
    defer allocator.free(config_path);

    var fallback_arena = std.heap.ArenaAllocator.init(allocator);
    defer fallback_arena.deinit();

    var parsed = try readRootValue(allocator);
    defer if (parsed) |*value| value.deinit();

    const tree_allocator = if (parsed) |*value| value.arena.allocator() else fallback_arena.allocator();
    var root: std.json.Value = if (parsed) |*value| value.value else .{ .object = .empty };

    if (root != .object) {
        root = .{ .object = .empty };
    }

    try writeUiSection(tree_allocator, &root.object, config);
    try writeThemeSection(tree_allocator, &root.object, config);
    try writeInstalledThemesSection(tree_allocator, &root.object, config);
    try writeOpenSection(tree_allocator, &root.object, config);
    try writeBrowserSection(tree_allocator, &root.object, config);
    try writeTerminalSection(tree_allocator, &root.object, config);
    try writeTranscriptSection(tree_allocator, &root.object, config);
    try writeChatSection(tree_allocator, &root.object, config);
    try writeUpdatesSection(tree_allocator, &root.object, config);
    try writeNotificationsSection(tree_allocator, &root.object, config);
    try writeIntegrationsSection(tree_allocator, &root.object, config);

    const encoded = try std.json.Stringify.valueAlloc(allocator, root, .{ .whitespace = .indent_2 });
    defer allocator.free(encoded);

    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();

    if (std.fs.path.dirname(config_path)) |parent| {
        try std.Io.Dir.cwd().createDirPath(io, parent);
    }

    const tmp_path = try std.fmt.allocPrint(allocator, "{s}.tmp", .{config_path});
    defer allocator.free(tmp_path);

    {
        var file = try std.Io.Dir.cwd().createFile(io, tmp_path, .{});
        defer file.close(io);
        var write_buffer: [4096]u8 = undefined;
        var writer = file.writer(io, &write_buffer);
        try writer.interface.writeAll(encoded);
        try writer.interface.flush();
    }

    const cwd = std.Io.Dir.cwd();
    try cwd.rename(tmp_path, cwd, config_path, io);
}

fn objectSection(allocator: std.mem.Allocator, object: *std.json.ObjectMap, key: []const u8) !*std.json.ObjectMap {
    const entry = try object.getOrPut(allocator, key);
    if (!entry.found_existing or entry.value_ptr.* != .object) {
        entry.value_ptr.* = .{ .object = .empty };
    }
    return &entry.value_ptr.object;
}

fn writeUiSection(allocator: std.mem.Allocator, object: *std.json.ObjectMap, config: *const AppConfig) !void {
    const ui_object = try objectSection(allocator, object, "ui");
    try ui_object.put(allocator, "font_size", .{ .float = config.font_size });
    try ui_object.put(allocator, "workspace_pane_gap", .{ .float = config.workspace_pane_gap });
    try ui_object.put(allocator, "workspace_panes_per_view", .{ .integer = config.workspace_panes_per_view });
    try ui_object.put(allocator, "workspace_split_default_pane", .{ .string = @tagName(config.workspace_split_default_pane) });
    try ui_object.put(allocator, "workspace_scroll_direction", .{ .string = @tagName(config.workspace_scroll_direction) });
    try ui_object.put(allocator, "workspace_scroll_mode", .{ .string = @tagName(config.workspace_scroll_mode) });
    try ui_object.put(allocator, "workspace_scroll_threshold", .{ .integer = config.workspace_scroll_threshold });
    try ui_object.put(allocator, "unzoom_on_pane_navigation", .{ .bool = config.unzoom_on_pane_navigation });
    try ui_object.put(allocator, "reduced_motion", .{ .bool = config.reduced_motion });
    try ui_object.put(allocator, "workspace_tabs", .{ .string = @tagName(config.workspace_tabs) });
    try ui_object.put(allocator, "workspace_new_tab_pane", .{ .string = @tagName(config.workspace_new_tab_pane) });
    try ui_object.put(allocator, "companion_enabled", .{ .bool = config.companion_enabled });
    try ui_object.put(allocator, "companion_character", .{ .string = @tagName(config.companion_character) });
}

fn writeThemeSection(allocator: std.mem.Allocator, object: *std.json.ObjectMap, config: *const AppConfig) !void {
    const theme_object = try objectSection(allocator, object, "theme");

    const source_name = switch (config.theme_config.source) {
        .omarchy => "omarchy",
        .default => "default",
    };
    try theme_object.put(allocator, "theme", .{ .string = source_name });
    if (config.active_theme) |active_name| {
        try theme_object.put(allocator, "active", .{ .string = active_name });
    } else {
        _ = theme_object.orderedRemove("active");
    }

    var has_color_override = false;
    inline for (std.meta.fields(theme.ThemeColorOverrides)) |field| {
        if (@field(config.theme_config.colors, field.name) != null) has_color_override = true;
    }

    if (has_color_override) {
        var colors_object: std.json.ObjectMap = .empty;
        inline for (std.meta.fields(theme.ThemeColorOverrides)) |field| {
            if (@field(config.theme_config.colors, field.name)) |value| {
                const hex = try colorToHex(allocator, value);
                try colors_object.put(allocator, field.name, .{ .string = hex });
            }
        }
        try theme_object.put(allocator, "colors", .{ .object = colors_object });
    } else {
        // Import/reset replaces the complete theme. Remove persisted overrides
        // so stale colors cannot survive a package that intentionally has none.
        _ = theme_object.orderedRemove("colors");
    }
}

fn writeInstalledThemesSection(allocator: std.mem.Allocator, object: *std.json.ObjectMap, config: *const AppConfig) !void {
    var installed_values = std.json.Array.init(allocator);
    for (config.installed_themes) |installed| {
        var installed_object: std.json.ObjectMap = .empty;
        try installed_object.put(allocator, "name", .{ .string = installed.name });

        var package_theme: std.json.ObjectMap = .empty;
        const source_name = if (installed.theme_config.source == .omarchy) "omarchy" else "default";
        try package_theme.put(allocator, "theme", .{ .string = source_name });
        var colors_object: std.json.ObjectMap = .empty;
        var has_colors = false;
        inline for (std.meta.fields(theme.ThemeColorOverrides)) |field| {
            if (@field(installed.theme_config.colors, field.name)) |value| {
                const hex = try colorToHex(allocator, value);
                try colors_object.put(allocator, field.name, .{ .string = hex });
                has_colors = true;
            }
        }
        if (has_colors) try package_theme.put(allocator, "colors", .{ .object = colors_object });
        try installed_object.put(allocator, "theme", .{ .object = package_theme });
        if (installed.font_size) |value| try installed_object.put(allocator, "ui_font_size", .{ .float = value });
        if (installed.terminal_font_size) |value| try installed_object.put(allocator, "terminal_font_size", .{ .float = value });
        try installed_values.append(.{ .object = installed_object });
    }
    try object.put(allocator, "installed_themes", .{ .array = installed_values });
}

fn writeOpenSection(allocator: std.mem.Allocator, object: *std.json.ObjectMap, config: *const AppConfig) !void {
    const open_object = try objectSection(allocator, object, "open");

    const default_value: std.json.Value = switch (config.default_open_action) {
        .folder => .{ .string = "folder" },
        .editor => .{ .string = "editor" },
        .cursor => .{ .string = "cursor" },
        .vscode => .{ .string = "vscode" },
        .zed => .{ .string = "zed" },
        .custom => |custom| blk: {
            var custom_object: std.json.ObjectMap = .empty;
            try custom_object.put(allocator, "label", .{ .string = custom.label });
            try custom_object.put(allocator, "action", .{ .string = custom.action });
            break :blk .{ .object = custom_object };
        },
    };

    try open_object.put(allocator, "default", default_value);
    const links_value: std.json.Value = .{ .string = switch (config.link_open_target) {
        .verde_browser => "verde_browser",
        .system_browser => "system_browser",
    } };
    try open_object.put(allocator, "links", links_value);
    try open_object.put(allocator, "chat_links", .{ .string = @tagName(config.chat_link_open_override) });
    try open_object.put(allocator, "terminal_links", .{ .string = @tagName(config.terminal_link_open_override) });
    try open_object.put(allocator, "file_links_in_neovim_pane", .{ .bool = config.file_links_in_neovim_pane });
}

fn writeBrowserSection(allocator: std.mem.Allocator, object: *std.json.ObjectMap, config: *const AppConfig) !void {
    const browser_object = try objectSection(allocator, object, "browser");
    try browser_object.put(allocator, "scroll_speed", .{ .float = config.browser_scroll_speed });
}

fn writeTerminalSection(allocator: std.mem.Allocator, object: *std.json.ObjectMap, config: *const AppConfig) !void {
    const terminal_object = try objectSection(allocator, object, "terminal");

    try terminal_object.put(allocator, "font_size", .{ .float = config.terminal_font_size });

    var profiles = std.json.Array.init(allocator);
    for (config.terminal_launch_profiles) |profile| {
        var command = std.json.Array.init(allocator);
        for (profile.command) |arg| {
            try command.append(.{ .string = arg });
        }
        var profile_object: std.json.ObjectMap = .empty;
        try profile_object.put(allocator, "label", .{ .string = profile.label });
        try profile_object.put(allocator, "command", .{ .array = command });
        try profiles.append(.{ .object = profile_object });
    }

    try terminal_object.put(allocator, "profiles", .{ .array = profiles });
}

fn writeTranscriptSection(allocator: std.mem.Allocator, object: *std.json.ObjectMap, config: *const AppConfig) !void {
    const transcript_object = try objectSection(allocator, object, "transcript");
    const preference: []const u8 = switch (config.tool_call_group_preference) {
        .collapsed => "collapsed",
        .expanded => "expanded",
        .remember_last => "remember_last",
    };
    try transcript_object.put(allocator, "tool_call_groups", .{ .string = preference });
    try transcript_object.put(allocator, "tool_call_groups_last_expanded", .{ .bool = config.tool_call_groups_last_expanded });
    try transcript_object.put(allocator, "diff_layout", .{ .string = @tagName(config.diff_layout_preference) });
}

fn writeChatSection(allocator: std.mem.Allocator, object: *std.json.ObjectMap, config: *const AppConfig) !void {
    const chat_object = try objectSection(allocator, object, "chat");
    try chat_object.put(allocator, "automatic_titles", .{ .bool = config.automatic_chat_titles_enabled });
    try chat_object.put(allocator, "title_provider", .{ .string = @tagName(config.chat_title_provider) });
    try chat_object.put(allocator, "title_model", .{ .string = config.chatTitleModel() });
    try chat_object.put(allocator, "default_provider", .{ .string = @tagName(config.new_chat_provider) });
    if (config.new_chat_model) |model| {
        try chat_object.put(allocator, "default_model", .{ .string = model });
    } else {
        _ = chat_object.swapRemove("default_model");
    }
    try chat_object.put(allocator, "default_reasoning", .{ .string = config.new_chat_reasoning.configValue() });
    var favorites = std.json.Array.init(allocator);
    for (config.favorite_models) |favorite| {
        var favorite_object: std.json.ObjectMap = .empty;
        try favorite_object.put(allocator, "provider", .{ .string = @tagName(favorite.provider) });
        try favorite_object.put(allocator, "model", .{ .string = favorite.model });
        try favorites.append(.{ .object = favorite_object });
    }
    try chat_object.put(allocator, "favorite_models", .{ .array = favorites });
    try chat_object.put(allocator, "new_pane_behavior", .{ .string = @tagName(config.new_chat_pane_behavior) });
}

fn writeUpdatesSection(allocator: std.mem.Allocator, object: *std.json.ObjectMap, config: *const AppConfig) !void {
    const updates_object = try objectSection(allocator, object, "updates");
    try updates_object.put(allocator, "check_automatically", .{ .bool = config.check_for_updates_automatically });
}

fn writeNotificationsSection(allocator: std.mem.Allocator, object: *std.json.ObjectMap, config: *const AppConfig) !void {
    const notifications_object = try objectSection(allocator, object, "notifications");
    try notifications_object.put(allocator, "enabled", .{ .bool = config.notifications_enabled });
}

fn writeIntegrationsSection(allocator: std.mem.Allocator, object: *std.json.ObjectMap, config: *const AppConfig) !void {
    const integrations_object = try objectSection(allocator, object, "integrations");
    try integrations_object.put(allocator, "mcp_enabled", .{ .bool = config.mcp_integration_enabled });
    try integrations_object.put(allocator, "mcp_onboarding_completed", .{ .bool = config.mcp_onboarding_completed });
}

fn colorToHex(allocator: std.mem.Allocator, color: [4]f32) ![]u8 {
    const r: u8 = @intFromFloat(@round(theme.clampf(color[0], 0.0, 1.0) * 255.0));
    const g: u8 = @intFromFloat(@round(theme.clampf(color[1], 0.0, 1.0) * 255.0));
    const b: u8 = @intFromFloat(@round(theme.clampf(color[2], 0.0, 1.0) * 255.0));
    const a: u8 = @intFromFloat(@round(theme.clampf(color[3], 0.0, 1.0) * 255.0));
    if (a == 255) return std.fmt.allocPrint(allocator, "#{x:0>2}{x:0>2}{x:0>2}", .{ r, g, b });
    return std.fmt.allocPrint(allocator, "#{x:0>2}{x:0>2}{x:0>2}{x:0>2}", .{ r, g, b, a });
}

pub fn resolveConfigPath(allocator: std.mem.Allocator) ![]u8 {
    return platform_paths.configPath(allocator);
}

fn readConfigFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var threaded = std.Io.Threaded.init_single_threaded;

    return std.Io.Dir.cwd().readFileAlloc(threaded.io(), path, allocator, .limited(1024 * 128)) catch |err| switch (err) {
        error.FileNotFound => return error.FileNotFound,
        else => return err,
    };
}

fn applyAppOverrides(allocator: std.mem.Allocator, config: *AppConfig, root: std.json.Value) void {
    if (root != .object) {
        log.warn("verde config must be a JSON object when present", .{});
        return;
    }

    if (root.object.get("ui")) |ui_value| {
        applyUiOverrides(config, ui_value);
    }
    if (root.object.get("theme")) |theme_value| {
        applyThemeOverrides(allocator, config, theme_value);
    }
    if (root.object.get("open")) |open_value| {
        applyOpenOverrides(allocator, config, open_value);
    }
    if (root.object.get("browser")) |browser_value| {
        applyBrowserOverrides(config, browser_value);
    }
    if (root.object.get("terminal")) |terminal_value| {
        applyTerminalOverrides(allocator, config, terminal_value);
    }
    if (root.object.get("transcript")) |transcript_value| {
        applyTranscriptOverrides(config, transcript_value);
    }
    if (root.object.get("chat")) |chat_value| {
        applyChatOverrides(allocator, config, chat_value);
    }
    if (root.object.get("installed_themes")) |installed_value| {
        applyInstalledThemeOverrides(allocator, config, installed_value);
    }
    validateActiveTheme(allocator, config);
    if (root.object.get("updates")) |updates_value| {
        applyUpdatesOverrides(config, updates_value);
    }
    if (root.object.get("notifications")) |notifications_value| {
        applyNotificationsOverrides(config, notifications_value);
    }
    if (root.object.get("integrations")) |integrations_value| {
        applyIntegrationsOverrides(config, integrations_value);
    }
}

fn applyBrowserOverrides(config: *AppConfig, browser_value: std.json.Value) void {
    if (browser_value != .object) {
        log.warn("browser must be an object when provided", .{});
        return;
    }
    if (browser_value.object.get("fast_scrolling")) |enabled_value| {
        if (enabled_value == .bool) {
            config.browser_scroll_speed = if (enabled_value.bool) DEFAULT_BROWSER_SCROLL_SPEED else MIN_BROWSER_SCROLL_SPEED;
        } else {
            log.warn("browser.fast_scrolling must be a boolean when provided", .{});
        }
    }
    if (browser_value.object.get("scroll_speed")) |speed_value| {
        switch (speed_value) {
            .integer => |value| applyBrowserScrollSpeed(config, @floatFromInt(value)),
            .float => |value| applyBrowserScrollSpeed(config, @floatCast(value)),
            else => log.warn("browser.scroll_speed must be a number when provided", .{}),
        }
    }
}

fn applyBrowserScrollSpeed(config: *AppConfig, value: f32) void {
    if (!std.math.isFinite(value) or value < MIN_BROWSER_SCROLL_SPEED or value > MAX_BROWSER_SCROLL_SPEED) {
        log.warn("ignoring browser.scroll_speed outside supported range {d:.2}-{d:.2}", .{ MIN_BROWSER_SCROLL_SPEED, MAX_BROWSER_SCROLL_SPEED });
        return;
    }
    config.browser_scroll_speed = value;
}

fn applyTranscriptOverrides(config: *AppConfig, transcript_value: std.json.Value) void {
    if (transcript_value != .object) {
        log.warn("transcript must be an object when provided", .{});
        return;
    }
    if (transcript_value.object.get("tool_call_groups")) |preference_value| {
        if (preference_value == .string) {
            config.tool_call_group_preference = if (std.mem.eql(u8, preference_value.string, "expanded"))
                .expanded
            else if (std.mem.eql(u8, preference_value.string, "remember_last"))
                .remember_last
            else
                .collapsed;
        } else {
            log.warn("transcript.tool_call_groups must be a string when provided", .{});
        }
    }
    if (transcript_value.object.get("tool_call_groups_last_expanded")) |last_value| {
        if (last_value == .bool) {
            config.tool_call_groups_last_expanded = last_value.bool;
        } else {
            log.warn("transcript.tool_call_groups_last_expanded must be a boolean when provided", .{});
        }
    }
    if (transcript_value.object.get("diff_layout")) |layout_value| {
        if (layout_value == .string) {
            if (std.mem.eql(u8, layout_value.string, "split")) {
                config.diff_layout_preference = .split;
            } else if (std.mem.eql(u8, layout_value.string, "stacked")) {
                config.diff_layout_preference = .stacked;
            } else {
                log.warn("transcript.diff_layout must be stacked or split", .{});
            }
        } else {
            log.warn("transcript.diff_layout must be a string when provided", .{});
        }
    }
}

fn applyChatOverrides(allocator: std.mem.Allocator, config: *AppConfig, chat_value: std.json.Value) void {
    if (chat_value != .object) {
        log.warn("chat must be an object when provided", .{});
        return;
    }
    if (chat_value.object.get("automatic_titles")) |enabled_value| {
        if (enabled_value == .bool) {
            config.automatic_chat_titles_enabled = enabled_value.bool;
        } else {
            log.warn("chat.automatic_titles must be a boolean when provided", .{});
        }
    }
    if (chat_value.object.get("title_provider")) |provider_value| {
        if (provider_value == .string) {
            if (ChatTitleProvider.parse(provider_value.string)) |provider| {
                config.chat_title_provider = provider;
            } else {
                log.warn("chat.title_provider must be codex, claude, cursor, or opencode", .{});
            }
        } else {
            log.warn("chat.title_provider must be a string when provided", .{});
        }
    }
    if (chat_value.object.get("title_model")) |model_value| {
        if (model_value == .string and model_value.string.len > 0) {
            config.setChatTitleModel(allocator, model_value.string) catch {
                log.warn("could not allocate chat.title_model", .{});
            };
        } else {
            log.warn("chat.title_model must be a non-empty string when provided", .{});
        }
    }
    if (chat_value.object.get("default_provider")) |provider_value| {
        if (provider_value == .string) {
            if (ChatProvider.parse(provider_value.string)) |provider| {
                config.new_chat_provider = provider;
            } else {
                log.warn("chat.default_provider must be codex, claude, cursor, or opencode", .{});
            }
        } else {
            log.warn("chat.default_provider must be a string when provided", .{});
        }
    }
    if (chat_value.object.get("default_model")) |model_value| {
        if (model_value == .string and model_value.string.len > 0) {
            config.setNewChatModel(allocator, model_value.string) catch {
                log.warn("could not allocate chat.default_model", .{});
            };
        } else {
            log.warn("chat.default_model must be a non-empty string when provided", .{});
        }
    }
    if (chat_value.object.get("default_reasoning")) |reasoning_value| {
        if (reasoning_value == .string) {
            if (ChatReasoning.parse(reasoning_value.string)) |reasoning| {
                config.new_chat_reasoning = reasoning;
            } else {
                log.warn("chat.default_reasoning must be default, low, medium, high, xhigh, or max", .{});
            }
        } else {
            log.warn("chat.default_reasoning must be a string when provided", .{});
        }
    }
    if (chat_value.object.get("favorite_models")) |favorites_value| {
        applyFavoriteModelOverrides(allocator, config, favorites_value);
    }
    if (chat_value.object.get("new_pane_behavior")) |behavior_value| {
        if (behavior_value == .string) {
            if (std.mem.eql(u8, behavior_value.string, "new_pane")) {
                config.new_chat_pane_behavior = .new_pane;
            } else if (std.mem.eql(u8, behavior_value.string, "replace_pane")) {
                config.new_chat_pane_behavior = .replace_pane;
            } else {
                log.warn("chat.new_pane_behavior must be new_pane or replace_pane", .{});
            }
        } else {
            log.warn("chat.new_pane_behavior must be a string when provided", .{});
        }
    }
}

fn applyFavoriteModelOverrides(allocator: std.mem.Allocator, config: *AppConfig, value: std.json.Value) void {
    if (value != .array) {
        log.warn("chat.favorite_models must be an array when provided", .{});
        return;
    }
    var favorites: std.ArrayList(FavoriteModel) = .empty;
    defer favorites.deinit(allocator);
    for (value.array.items) |entry| {
        if (entry != .object) continue;
        const provider_value = entry.object.get("provider") orelse continue;
        const model_value = entry.object.get("model") orelse continue;
        if (provider_value != .string or model_value != .string or model_value.string.len == 0) continue;
        const provider = ChatProvider.parse(provider_value.string) orelse continue;
        var duplicate = false;
        for (favorites.items) |favorite| {
            if (favorite.provider == provider and std.mem.eql(u8, favorite.model, model_value.string)) {
                duplicate = true;
                break;
            }
        }
        if (duplicate) continue;
        const model = allocator.dupe(u8, model_value.string) catch break;
        favorites.append(allocator, .{ .provider = provider, .model = model }) catch {
            allocator.free(model);
            break;
        };
    }
    const owned = favorites.toOwnedSlice(allocator) catch {
        for (favorites.items) |*favorite| favorite.deinit(allocator);
        return;
    };
    for (config.favorite_models) |*favorite| favorite.deinit(allocator);
    allocator.free(config.favorite_models);
    config.favorite_models = owned;
}

fn applyUpdatesOverrides(config: *AppConfig, updates_value: std.json.Value) void {
    if (updates_value != .object) {
        log.warn("updates must be an object when provided", .{});
        return;
    }
    if (updates_value.object.get("check_automatically")) |enabled_value| {
        if (enabled_value == .bool) {
            config.check_for_updates_automatically = enabled_value.bool;
        } else {
            log.warn("updates.check_automatically must be a boolean when provided", .{});
        }
    }
}

fn applyNotificationsOverrides(config: *AppConfig, notifications_value: std.json.Value) void {
    if (notifications_value != .object) {
        log.warn("notifications must be an object when provided", .{});
        return;
    }
    if (notifications_value.object.get("enabled")) |enabled_value| {
        if (enabled_value == .bool) {
            config.notifications_enabled = enabled_value.bool;
        } else {
            log.warn("notifications.enabled must be a boolean when provided", .{});
        }
    }
}

fn applyIntegrationsOverrides(config: *AppConfig, integrations_value: std.json.Value) void {
    if (integrations_value != .object) {
        log.warn("integrations must be an object when provided", .{});
        return;
    }
    if (integrations_value.object.get("mcp_enabled")) |enabled_value| {
        if (enabled_value == .bool) {
            config.mcp_integration_enabled = enabled_value.bool;
        } else {
            log.warn("integrations.mcp_enabled must be a boolean when provided", .{});
        }
    }
    if (integrations_value.object.get("mcp_onboarding_completed")) |completed_value| {
        if (completed_value == .bool) {
            config.mcp_onboarding_completed = completed_value.bool;
        } else {
            log.warn("integrations.mcp_onboarding_completed must be a boolean when provided", .{});
        }
    }
}

fn applyThemeOverrides(allocator: std.mem.Allocator, config: *AppConfig, theme_value: std.json.Value) void {
    if (theme_value != .object) {
        log.warn("theme must be an object when provided", .{});
        return;
    }

    if (theme_value.object.get("active")) |active_value| {
        if (active_value != .string) {
            log.warn("theme.active must be a string when provided", .{});
        } else {
            const active_name = std.mem.trim(u8, active_value.string, &std.ascii.whitespace);
            if (active_name.len > 0) {
                config.active_theme = allocator.dupe(u8, active_name) catch null;
            }
        }
    }

    applyThemeConfigOverrides(&config.theme_config, theme_value);
}

fn applyThemeConfigOverrides(theme_config: *theme.ThemeConfig, theme_value: std.json.Value) void {
    if (theme_value.object.get("theme")) |source_value| {
        if (source_value != .string) {
            log.warn("theme.theme must be a string when provided", .{});
        } else if (parseThemeSource(source_value.string)) |source| {
            theme_config.source = source;
        }
    }

    const colors_value = theme_value.object.get("colors") orelse return;
    if (colors_value != .object) {
        log.warn("theme.colors must be an object when provided", .{});
        return;
    }
    applyThemeColorOverrides(theme_config, colors_value.object);
}

fn parseThemeSource(raw: []const u8) ?theme.ThemeSource {
    const value = std.mem.trim(u8, raw, &std.ascii.whitespace);
    if (std.ascii.eqlIgnoreCase(value, "omarchy") or std.ascii.eqlIgnoreCase(value, "auto")) return .omarchy;
    if (std.ascii.eqlIgnoreCase(value, "default") or std.ascii.eqlIgnoreCase(value, "verde")) return .default;
    log.warn("ignoring unsupported theme.theme value_len={d}", .{value.len});
    return null;
}

fn applyThemeColorOverrides(theme_config: *theme.ThemeConfig, object: std.json.ObjectMap) void {
    inline for (std.meta.fields(theme.ThemeColorOverrides)) |field| {
        if (object.get(field.name)) |value| {
            if (parseConfigColor(value)) |parsed| {
                @field(theme_config.colors, field.name) = parsed;
            } else {
                log.warn("theme.colors.{s} must be a hex string or RGB/RGBA number array", .{field.name});
            }
        }
    }
}

fn applyInstalledThemeOverrides(allocator: std.mem.Allocator, config: *AppConfig, value: std.json.Value) void {
    if (value != .array) {
        log.warn("installed_themes must be an array when provided", .{});
        return;
    }
    for (value.array.items) |item| {
        if (item != .object) {
            log.warn("installed theme entries must be objects", .{});
            continue;
        }
        const name_value = item.object.get("name") orelse continue;
        const theme_value = item.object.get("theme") orelse continue;
        if (name_value != .string or theme_value != .object) {
            log.warn("installed theme name/theme fields are invalid", .{});
            continue;
        }
        const name = std.mem.trim(u8, name_value.string, &std.ascii.whitespace);
        if (name.len == 0 or name.len > 128) {
            log.warn("installed theme name is empty or too long", .{});
            continue;
        }

        var theme_config: theme.ThemeConfig = .{ .source = .default };
        applyThemeConfigOverrides(&theme_config, theme_value);
        const font_size = parseInstalledFontSize(item.object.get("ui_font_size"), MIN_FONT_SIZE, MAX_FONT_SIZE);
        const terminal_font_size = parseInstalledFontSize(item.object.get("terminal_font_size"), MIN_TERMINAL_FONT_SIZE, MAX_TERMINAL_FONT_SIZE);
        _ = config.installTheme(allocator, name, theme_config, font_size, terminal_font_size) catch |err| {
            log.warn("failed to load installed theme: {s}", .{@errorName(err)});
            continue;
        };
    }
}

fn parseInstalledFontSize(value: ?std.json.Value, min: f32, max: f32) ?f32 {
    const present = value orelse return null;
    const number: f32 = switch (present) {
        .integer => |integer| @floatFromInt(integer),
        .float => |float| @floatCast(float),
        else => return null,
    };
    if (!std.math.isFinite(number) or number < min or number > max) return null;
    return number;
}

fn validateActiveTheme(allocator: std.mem.Allocator, config: *AppConfig) void {
    if (config.active_theme == null or config.activeThemeIndex() != null) return;
    allocator.free(config.active_theme.?);
    config.active_theme = null;
}

fn parseConfigColor(value: std.json.Value) ?[4]f32 {
    return switch (value) {
        .string => |raw| parseHexConfigColor(raw),
        .array => |array| parseArrayConfigColor(array),
        else => null,
    };
}

fn parseHexConfigColor(raw: []const u8) ?[4]f32 {
    var value = std.mem.trim(u8, raw, &std.ascii.whitespace);
    if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') value = value[1 .. value.len - 1];
    if ((value.len != 7 and value.len != 9) or value[0] != '#') return null;
    const alpha: u8 = if (value.len == 9)
        std.fmt.parseInt(u8, value[7..9], 16) catch return null
    else
        255;
    return .{
        @as(f32, @floatFromInt(std.fmt.parseInt(u8, value[1..3], 16) catch return null)) / 255.0,
        @as(f32, @floatFromInt(std.fmt.parseInt(u8, value[3..5], 16) catch return null)) / 255.0,
        @as(f32, @floatFromInt(std.fmt.parseInt(u8, value[5..7], 16) catch return null)) / 255.0,
        @as(f32, @floatFromInt(alpha)) / 255.0,
    };
}

fn parseArrayConfigColor(array: std.json.Array) ?[4]f32 {
    if (array.items.len != 3 and array.items.len != 4) return null;
    var result = [4]f32{ 0.0, 0.0, 0.0, 1.0 };
    for (array.items, 0..) |item, index| {
        result[index] = switch (item) {
            .integer => |value| colorChannelFromNumber(@floatFromInt(value)),
            .float => |value| colorChannelFromNumber(@floatCast(value)),
            else => return null,
        } orelse return null;
    }
    return result;
}

fn colorChannelFromNumber(value: f32) ?f32 {
    if (!std.math.isFinite(value)) return null;
    if (value >= 0.0 and value <= 1.0) return value;
    if (value >= 0.0 and value <= 255.0) return value / 255.0;
    return null;
}

fn applyUiOverrides(config: *AppConfig, ui_value: std.json.Value) void {
    if (ui_value != .object) {
        log.warn("ui must be an object when provided", .{});
        return;
    }

    if (ui_value.object.get("font_size")) |font_size_value| {
        switch (font_size_value) {
            .integer => |value| applyFontSize(config, @floatFromInt(value)),
            .float => |value| applyFontSize(config, @floatCast(value)),
            else => log.warn("ui.font_size must be a number when provided", .{}),
        }
    }
    if (ui_value.object.get("workspace_pane_gap")) |gap_value| {
        switch (gap_value) {
            .integer => |value| applyWorkspacePaneGap(config, @floatFromInt(value)),
            .float => |value| applyWorkspacePaneGap(config, @floatCast(value)),
            else => log.warn("ui.workspace_pane_gap must be a number when provided", .{}),
        }
    }
    if (ui_value.object.get("workspace_panes_per_view")) |count_value| {
        switch (count_value) {
            .integer => |value| applyWorkspacePanesPerView(config, value),
            else => log.warn("ui.workspace_panes_per_view must be an integer when provided", .{}),
        }
    }
    if (ui_value.object.get("workspace_split_default_pane")) |pane_value| {
        if (pane_value != .string) {
            log.warn("ui.workspace_split_default_pane must be a string when provided", .{});
        } else if (WorkspaceSplitDefaultPane.parse(pane_value.string)) |pane_kind| {
            config.workspace_split_default_pane = pane_kind;
        } else {
            log.warn("ui.workspace_split_default_pane must be chat or terminal", .{});
        }
    }
    if (ui_value.object.get("workspace_scroll_direction")) |direction_value| {
        if (direction_value != .string) {
            log.warn("ui.workspace_scroll_direction must be a string when provided", .{});
        } else if (WorkspaceScrollDirection.parse(direction_value.string)) |direction| {
            config.workspace_scroll_direction = direction;
        } else {
            log.warn("ignoring unsupported ui.workspace_scroll_direction", .{});
        }
    }
    if (ui_value.object.get("workspace_scroll_mode")) |mode_value| {
        if (mode_value != .string) {
            log.warn("ui.workspace_scroll_mode must be a string when provided", .{});
        } else if (WorkspaceScrollMode.parse(mode_value.string)) |mode| {
            config.workspace_scroll_mode = mode;
        } else {
            log.warn("ignoring unsupported ui.workspace_scroll_mode", .{});
        }
    }
    if (ui_value.object.get("workspace_scroll_threshold")) |threshold_value| {
        switch (threshold_value) {
            .integer => |value| applyWorkspaceScrollThreshold(config, value),
            else => log.warn("ui.workspace_scroll_threshold must be an integer when provided", .{}),
        }
    }
    if (ui_value.object.get("unzoom_on_pane_navigation")) |unzoom_value| {
        if (unzoom_value == .bool) {
            config.unzoom_on_pane_navigation = unzoom_value.bool;
        } else {
            log.warn("ui.unzoom_on_pane_navigation must be a boolean when provided", .{});
        }
    }
    if (ui_value.object.get("reduced_motion")) |reduced_motion_value| {
        if (reduced_motion_value == .bool) {
            config.reduced_motion = reduced_motion_value.bool;
        } else {
            log.warn("ui.reduced_motion must be a boolean when provided", .{});
        }
    }
    if (ui_value.object.get("workspace_tabs")) |tabs_value| {
        if (tabs_value != .string) {
            log.warn("ui.workspace_tabs must be a string when provided", .{});
        } else if (WorkspaceTabsMode.parse(tabs_value.string)) |mode| {
            config.workspace_tabs = mode;
        } else {
            log.warn("ignoring unsupported ui.workspace_tabs", .{});
        }
    }
    if (ui_value.object.get("workspace_new_tab_pane")) |pane_value| {
        if (pane_value != .string) {
            log.warn("ui.workspace_new_tab_pane must be a string when provided", .{});
        } else if (WorkspaceSplitDefaultPane.parse(pane_value.string)) |pane_kind| {
            config.workspace_new_tab_pane = pane_kind;
        } else {
            log.warn("ui.workspace_new_tab_pane must be chat or terminal", .{});
        }
    }
    if (ui_value.object.get("companion_enabled")) |enabled_value| {
        if (enabled_value == .bool) {
            config.companion_enabled = enabled_value.bool;
        } else {
            config.companion_enabled = false;
            log.warn("ui.companion_enabled must be a boolean when provided", .{});
        }
    }
    if (ui_value.object.get("companion_character")) |character_value| {
        if (character_value != .string) {
            config.companion_character = .sprout;
            log.warn("ui.companion_character must be a string when provided", .{});
        } else if (CompanionCharacter.parse(character_value.string)) |character| {
            config.companion_character = character;
        } else {
            config.companion_character = .sprout;
            log.warn("ui.companion_character must be sprout, moss, or vireo", .{});
        }
    }
}

fn applyOpenOverrides(allocator: std.mem.Allocator, config: *AppConfig, open_value: std.json.Value) void {
    if (open_value != .object) {
        log.warn("open must be an object when provided", .{});
        return;
    }

    if (open_value.object.get("default")) |default_value| {
        const parsed = parseDefaultOpenAction(allocator, default_value) orelse return;
        config.default_open_action.deinit(allocator);
        config.default_open_action = parsed;
    }

    if (open_value.object.get("links")) |links_value| {
        if (parseLinkOpenTarget(links_value)) |target| {
            config.link_open_target = target;
        }
    }
    if (open_value.object.get("chat_links")) |links_value| {
        if (parseLinkOpenOverride("open.chat_links", links_value)) |target| {
            config.chat_link_open_override = target;
        }
    }
    if (open_value.object.get("terminal_links")) |links_value| {
        if (parseLinkOpenOverride("open.terminal_links", links_value)) |target| {
            config.terminal_link_open_override = target;
        }
    }
    if (open_value.object.get("file_links_in_neovim_pane")) |pane_value| {
        if (pane_value == .bool) {
            config.file_links_in_neovim_pane = pane_value.bool;
        } else {
            log.warn("open.file_links_in_neovim_pane must be a boolean when provided", .{});
        }
    }
}

fn parseLinkOpenTarget(value: std.json.Value) ?LinkOpenTarget {
    if (value != .string) {
        log.warn("open.links must be a string when provided", .{});
        return null;
    }
    const trimmed = std.mem.trim(u8, value.string, &std.ascii.whitespace);
    if (std.ascii.eqlIgnoreCase(trimmed, "verde_browser") or
        std.ascii.eqlIgnoreCase(trimmed, "verde") or
        std.ascii.eqlIgnoreCase(trimmed, "browser")) return .verde_browser;
    if (std.ascii.eqlIgnoreCase(trimmed, "system_browser") or
        std.ascii.eqlIgnoreCase(trimmed, "system") or
        std.ascii.eqlIgnoreCase(trimmed, "default_browser") or
        std.ascii.eqlIgnoreCase(trimmed, "default")) return .system_browser;

    log.warn("ignoring unsupported open.links value_len={d}", .{trimmed.len});
    return null;
}

fn parseLinkOpenOverride(field_name: []const u8, value: std.json.Value) ?LinkOpenOverride {
    if (value != .string) {
        log.warn("{s} must be a string when provided", .{field_name});
        return null;
    }
    const trimmed = std.mem.trim(u8, value.string, &std.ascii.whitespace);
    if (std.ascii.eqlIgnoreCase(trimmed, "global") or std.ascii.eqlIgnoreCase(trimmed, "inherit")) return .global;
    if (std.ascii.eqlIgnoreCase(trimmed, "verde_browser") or std.ascii.eqlIgnoreCase(trimmed, "verde") or std.ascii.eqlIgnoreCase(trimmed, "browser")) return .verde_browser;
    if (std.ascii.eqlIgnoreCase(trimmed, "system_browser") or std.ascii.eqlIgnoreCase(trimmed, "system") or std.ascii.eqlIgnoreCase(trimmed, "default_browser") or std.ascii.eqlIgnoreCase(trimmed, "default")) return .system_browser;

    log.warn("ignoring unsupported {s} value_len={d}", .{ field_name, trimmed.len });
    return null;
}

fn parseDefaultOpenAction(allocator: std.mem.Allocator, value: std.json.Value) ?DefaultOpenAction {
    return switch (value) {
        .string => |name| parseNamedOpenAction(name),
        .object => parseCustomOpenAction(allocator, value.object),
        else => blk: {
            log.warn("open.default must be a string or object when provided", .{});
            break :blk null;
        },
    };
}

fn parseNamedOpenAction(name: []const u8) ?DefaultOpenAction {
    const trimmed = std.mem.trim(u8, name, &std.ascii.whitespace);
    if (trimmed.len == 0) {
        log.warn("open.default cannot be an empty string", .{});
        return null;
    }

    if (std.ascii.eqlIgnoreCase(trimmed, "folder") or std.ascii.eqlIgnoreCase(trimmed, "files")) return .folder;
    if (std.ascii.eqlIgnoreCase(trimmed, "editor") or std.ascii.eqlIgnoreCase(trimmed, "configured")) return .editor;
    if (std.ascii.eqlIgnoreCase(trimmed, "cursor")) return .cursor;
    if (std.ascii.eqlIgnoreCase(trimmed, "vscode") or std.ascii.eqlIgnoreCase(trimmed, "code")) return .vscode;
    if (std.ascii.eqlIgnoreCase(trimmed, "zed")) return .zed;

    log.warn("ignoring unsupported open.default value_len={d}", .{trimmed.len});
    return null;
}

fn parseCustomOpenAction(allocator: std.mem.Allocator, object: std.json.ObjectMap) ?DefaultOpenAction {
    const label_value = object.get("label") orelse {
        log.warn("open.default.label is required for custom actions", .{});
        return null;
    };
    const action_value = object.get("action") orelse {
        log.warn("open.default.action is required for custom actions", .{});
        return null;
    };
    if (label_value != .string or action_value != .string) {
        log.warn("open.default.label and open.default.action must be strings", .{});
        return null;
    }

    const label = std.mem.trim(u8, label_value.string, &std.ascii.whitespace);
    const action = std.mem.trim(u8, action_value.string, &std.ascii.whitespace);
    if (label.len == 0 or action.len == 0) {
        log.warn("open.default custom action requires non-empty label and action", .{});
        return null;
    }

    const owned_label = allocator.dupe(u8, label) catch return null;
    errdefer allocator.free(owned_label);
    const owned_action = allocator.dupe(u8, action) catch return null;

    return .{
        .custom = .{
            .label = owned_label,
            .action = owned_action,
        },
    };
}

fn applyTerminalOverrides(allocator: std.mem.Allocator, config: *AppConfig, terminal_value: std.json.Value) void {
    if (terminal_value != .object) {
        log.warn("terminal must be an object when provided", .{});
        return;
    }

    if (terminal_value.object.get("font_size")) |font_size_value| {
        switch (font_size_value) {
            .integer => |value| applyTerminalFontSize(config, @floatFromInt(value)),
            .float => |value| applyTerminalFontSize(config, @floatCast(value)),
            else => log.warn("terminal.font_size must be a number when provided", .{}),
        }
    }

    const profiles_value = terminal_value.object.get("profiles") orelse return;
    if (profiles_value != .array) {
        log.warn("terminal.profiles must be an array when provided", .{});
        return;
    }

    var profiles: std.ArrayList(TerminalLaunchProfileConfig) = .empty;
    errdefer {
        for (profiles.items) |*profile| profile.deinit(allocator);
        profiles.deinit(allocator);
    }
    for (profiles_value.array.items) |profile_value| {
        if (parseTerminalLaunchProfile(allocator, profile_value)) |profile| {
            profiles.append(allocator, profile) catch |err| {
                var owned = profile;
                owned.deinit(allocator);
                log.warn("failed to append terminal profile: {s}", .{@errorName(err)});
            };
        }
    }

    for (config.terminal_launch_profiles) |*profile| profile.deinit(allocator);
    allocator.free(config.terminal_launch_profiles);
    config.terminal_launch_profiles = profiles.toOwnedSlice(allocator) catch &.{};
}

fn applyTerminalFontSize(config: *AppConfig, value: f32) void {
    config.terminal_font_size = theme.clampf(value, MIN_TERMINAL_FONT_SIZE, MAX_TERMINAL_FONT_SIZE);
}

fn parseTerminalLaunchProfile(allocator: std.mem.Allocator, value: std.json.Value) ?TerminalLaunchProfileConfig {
    if (value != .object) {
        log.warn("terminal profile entries must be objects", .{});
        return null;
    }
    const label_value = value.object.get("label") orelse {
        log.warn("terminal profile label is required", .{});
        return null;
    };
    const command_value = value.object.get("command") orelse {
        log.warn("terminal profile command is required", .{});
        return null;
    };
    if (label_value != .string or command_value != .array) {
        log.warn("terminal profile label must be a string and command must be a string array", .{});
        return null;
    }
    const label = std.mem.trim(u8, label_value.string, &std.ascii.whitespace);
    if (label.len == 0 or command_value.array.items.len == 0) {
        log.warn("terminal profile requires non-empty label and command", .{});
        return null;
    }

    const owned_label = allocator.dupe(u8, label) catch return null;
    errdefer allocator.free(owned_label);
    var command = allocator.alloc([]u8, command_value.array.items.len) catch return null;
    var initialized: usize = 0;
    errdefer {
        for (command[0..initialized]) |arg| allocator.free(arg);
        allocator.free(command);
    }
    for (command_value.array.items, 0..) |arg_value, index| {
        if (arg_value != .string) {
            log.warn("terminal profile command entries must be strings", .{});
            return null;
        }
        const arg = std.mem.trim(u8, arg_value.string, &std.ascii.whitespace);
        if (arg.len == 0) {
            log.warn("terminal profile command entries cannot be empty", .{});
            return null;
        }
        command[index] = allocator.dupe(u8, arg) catch return null;
        initialized += 1;
    }

    return .{ .label = owned_label, .command = command };
}

fn applyFontSize(config: *AppConfig, value: f32) void {
    if (!std.math.isFinite(value)) {
        log.warn("ignoring non-finite ui.font_size override", .{});
        return;
    }
    if (value < MIN_FONT_SIZE or value > MAX_FONT_SIZE) {
        log.warn("ignoring ui.font_size outside supported range {d:.1}-{d:.1}", .{ MIN_FONT_SIZE, MAX_FONT_SIZE });
        return;
    }

    config.font_size = value;
}

fn applyWorkspacePaneGap(config: *AppConfig, value: f32) void {
    if (!std.math.isFinite(value)) {
        log.warn("ignoring non-finite ui.workspace_pane_gap override", .{});
        return;
    }
    if (value < MIN_WORKSPACE_PANE_GAP or value > MAX_WORKSPACE_PANE_GAP) {
        log.warn("ignoring ui.workspace_pane_gap outside supported range {d:.1}-{d:.1}", .{ MIN_WORKSPACE_PANE_GAP, MAX_WORKSPACE_PANE_GAP });
        return;
    }

    config.workspace_pane_gap = value;
}

fn applyWorkspacePanesPerView(config: *AppConfig, value: i64) void {
    if (value < MIN_WORKSPACE_PANES_PER_VIEW or value > MAX_WORKSPACE_PANES_PER_VIEW) {
        log.warn("ignoring ui.workspace_panes_per_view outside supported range {d}-{d}", .{ MIN_WORKSPACE_PANES_PER_VIEW, MAX_WORKSPACE_PANES_PER_VIEW });
        return;
    }
    config.workspace_panes_per_view = @intCast(value);
}

fn applyWorkspaceScrollThreshold(config: *AppConfig, value: i64) void {
    if (value < MIN_WORKSPACE_SCROLL_THRESHOLD or value > MAX_WORKSPACE_SCROLL_THRESHOLD) {
        log.warn("ignoring ui.workspace_scroll_threshold outside supported range {d}-{d}", .{ MIN_WORKSPACE_SCROLL_THRESHOLD, MAX_WORKSPACE_SCROLL_THRESHOLD });
        return;
    }
    config.workspace_scroll_threshold = @intCast(value);
}

test "app config accepts ui.font_size override" {
    var root = try parseTestRoot("{\"ui\":{\"font_size\":22}}");
    defer root.deinit();

    var config: AppConfig = .{};
    defer config.deinit(std.testing.allocator);
    applyAppOverrides(std.testing.allocator, &config, root.value);

    try std.testing.expectEqual(@as(f32, 22.0), config.font_size);
}

test "app config ignores out-of-range ui.font_size" {
    var root = try parseTestRoot("{\"ui\":{\"font_size\":64}}");
    defer root.deinit();

    var config: AppConfig = .{};
    defer config.deinit(std.testing.allocator);
    applyAppOverrides(std.testing.allocator, &config, root.value);

    try std.testing.expectEqual(theme.DEFAULT_FONT_SIZE, config.font_size);
}

test "app config accepts ui.workspace_pane_gap override" {
    var root = try parseTestRoot("{\"ui\":{\"workspace_pane_gap\":24}}");
    defer root.deinit();

    var config: AppConfig = .{};
    defer config.deinit(std.testing.allocator);
    applyAppOverrides(std.testing.allocator, &config, root.value);

    try std.testing.expectEqual(@as(f32, 24.0), config.workspace_pane_gap);
}

test "app config ignores out-of-range ui.workspace_pane_gap" {
    var root = try parseTestRoot("{\"ui\":{\"workspace_pane_gap\":65}}");
    defer root.deinit();

    var config: AppConfig = .{};
    defer config.deinit(std.testing.allocator);
    applyAppOverrides(std.testing.allocator, &config, root.value);

    try std.testing.expectEqual(DEFAULT_WORKSPACE_PANE_GAP, config.workspace_pane_gap);
}

test "app config accepts ui.workspace_panes_per_view override" {
    var root = try parseTestRoot("{\"ui\":{\"workspace_panes_per_view\":3}}");
    defer root.deinit();

    var config: AppConfig = .{};
    defer config.deinit(std.testing.allocator);
    applyAppOverrides(std.testing.allocator, &config, root.value);

    try std.testing.expectEqual(@as(u8, 3), config.workspace_panes_per_view);
}

test "app config pane navigation keeps zoom by default and accepts unzoom override" {
    var root = try parseTestRoot("{\"ui\":{\"unzoom_on_pane_navigation\":true}}");
    defer root.deinit();

    var config: AppConfig = .{};
    defer config.deinit(std.testing.allocator);
    try std.testing.expect(!config.unzoom_on_pane_navigation);

    applyAppOverrides(std.testing.allocator, &config, root.value);
    try std.testing.expect(config.unzoom_on_pane_navigation);
}

test "app config reduced motion round trips explicit values" {
    for ([_]bool{ true, false }) |enabled| {
        var root = try parseTestRoot("{\"plugin_owned\":true,\"ui\":{\"plugin_value\":\"keep\"}}");
        defer root.deinit();

        const config: AppConfig = .{ .reduced_motion = enabled };
        try writeUiSection(root.arena.allocator(), &root.value.object, &config);
        const encoded = try std.json.Stringify.valueAlloc(std.testing.allocator, root.value, .{});
        defer std.testing.allocator.free(encoded);

        var saved = try parseTestRoot(encoded);
        defer saved.deinit();
        try std.testing.expect(saved.value.object.get("plugin_owned").?.bool);
        const saved_ui = saved.value.object.get("ui").?.object;
        try std.testing.expectEqualStrings("keep", saved_ui.get("plugin_value").?.string);
        try std.testing.expectEqual(enabled, saved_ui.get("reduced_motion").?.bool);

        var loaded: AppConfig = .{};
        defer loaded.deinit(std.testing.allocator);
        applyAppOverrides(std.testing.allocator, &loaded, saved.value);
        try std.testing.expectEqual(enabled, loaded.reduced_motion);
    }
}

test "app config workspace tabs mode round trips and rejects unknown values" {
    for ([_]WorkspaceTabsMode{ .automatic, .always, .disabled }) |mode| {
        var root = try parseTestRoot("{}");
        defer root.deinit();
        const config: AppConfig = .{ .workspace_tabs = mode };
        try writeUiSection(root.arena.allocator(), &root.value.object, &config);
        const encoded = try std.json.Stringify.valueAlloc(std.testing.allocator, root.value, .{});
        defer std.testing.allocator.free(encoded);

        var saved = try parseTestRoot(encoded);
        defer saved.deinit();
        var loaded: AppConfig = .{};
        defer loaded.deinit(std.testing.allocator);
        applyAppOverrides(std.testing.allocator, &loaded, saved.value);
        try std.testing.expectEqual(mode, loaded.workspace_tabs);
    }

    var bad = try parseTestRoot("{\"ui\":{\"workspace_tabs\":\"sometimes\"}}");
    defer bad.deinit();
    var loaded: AppConfig = .{};
    defer loaded.deinit(std.testing.allocator);
    applyAppOverrides(std.testing.allocator, &loaded, bad.value);
    try std.testing.expectEqual(WorkspaceTabsMode.automatic, loaded.workspace_tabs);
}

test "app config ignores out-of-range ui.workspace_panes_per_view" {
    var root = try parseTestRoot("{\"ui\":{\"workspace_panes_per_view\":7}}");
    defer root.deinit();

    var config: AppConfig = .{};
    defer config.deinit(std.testing.allocator);
    applyAppOverrides(std.testing.allocator, &config, root.value);

    try std.testing.expectEqual(DEFAULT_WORKSPACE_PANES_PER_VIEW, config.workspace_panes_per_view);
}

test "app config accepts ui.workspace_scroll_direction override" {
    var root = try parseTestRoot("{\"ui\":{\"workspace_scroll_direction\":\"vertical\"}}");
    defer root.deinit();

    var config: AppConfig = .{};
    defer config.deinit(std.testing.allocator);
    applyAppOverrides(std.testing.allocator, &config, root.value);

    try std.testing.expectEqual(WorkspaceScrollDirection.vertical, config.workspace_scroll_direction);
}

test "app config defaults prefix splits to chat and accepts terminal override" {
    var config: AppConfig = .{};
    defer config.deinit(std.testing.allocator);
    try std.testing.expectEqual(WorkspaceSplitDefaultPane.chat, config.workspace_split_default_pane);

    var root = try parseTestRoot("{\"ui\":{\"workspace_split_default_pane\":\"terminal\"}}");
    defer root.deinit();
    applyAppOverrides(std.testing.allocator, &config, root.value);

    try std.testing.expectEqual(WorkspaceSplitDefaultPane.terminal, config.workspace_split_default_pane);
}

test "app config defaults new workspace tabs to chat and accepts terminal override" {
    var config: AppConfig = .{};
    defer config.deinit(std.testing.allocator);
    try std.testing.expectEqual(WorkspaceSplitDefaultPane.chat, config.workspace_new_tab_pane);

    var root = try parseTestRoot("{\"ui\":{\"workspace_new_tab_pane\":\"terminal\"}}");
    defer root.deinit();
    applyAppOverrides(std.testing.allocator, &config, root.value);

    try std.testing.expectEqual(WorkspaceSplitDefaultPane.terminal, config.workspace_new_tab_pane);
}

test "app config ignores unsupported ui.workspace_scroll_direction" {
    var root = try parseTestRoot("{\"ui\":{\"workspace_scroll_direction\":\"diagonal\"}}");
    defer root.deinit();

    var config: AppConfig = .{};
    defer config.deinit(std.testing.allocator);
    applyAppOverrides(std.testing.allocator, &config, root.value);

    try std.testing.expectEqual(WorkspaceScrollDirection.horizontal, config.workspace_scroll_direction);
}

test "app config accepts workspace scrolling policy overrides" {
    var root = try parseTestRoot("{\"ui\":{\"workspace_scroll_mode\":\"always\",\"workspace_scroll_threshold\":8}}");
    defer root.deinit();

    var config: AppConfig = .{};
    defer config.deinit(std.testing.allocator);
    applyAppOverrides(std.testing.allocator, &config, root.value);

    try std.testing.expectEqual(WorkspaceScrollMode.always, config.workspace_scroll_mode);
    try std.testing.expectEqual(@as(u8, 8), config.workspace_scroll_threshold);
}

test "app config ignores unsupported workspace scrolling policy overrides" {
    var root = try parseTestRoot("{\"ui\":{\"workspace_scroll_mode\":\"sometimes\",\"workspace_scroll_threshold\":0}}");
    defer root.deinit();

    var config: AppConfig = .{};
    defer config.deinit(std.testing.allocator);
    applyAppOverrides(std.testing.allocator, &config, root.value);

    try std.testing.expectEqual(WorkspaceScrollMode.automatic, config.workspace_scroll_mode);
    try std.testing.expectEqual(DEFAULT_WORKSPACE_SCROLL_THRESHOLD, config.workspace_scroll_threshold);
}

test "app config defaults missing companion character to Sprout" {
    var root = try parseTestRoot("{\"ui\":{\"font_size\":22}}");
    defer root.deinit();

    var config: AppConfig = .{};
    defer config.deinit(std.testing.allocator);
    applyAppOverrides(std.testing.allocator, &config, root.value);

    try std.testing.expectEqual(CompanionCharacter.sprout, config.companion_character);
}

test "app config defaults missing or invalid Companion availability to disabled" {
    var missing = try parseTestRoot("{\"ui\":{\"font_size\":22}}");
    defer missing.deinit();
    var invalid = try parseTestRoot("{\"ui\":{\"companion_enabled\":\"yes\"}}");
    defer invalid.deinit();

    var missing_config: AppConfig = .{};
    defer missing_config.deinit(std.testing.allocator);
    applyAppOverrides(std.testing.allocator, &missing_config, missing.value);
    try std.testing.expect(!missing_config.companion_enabled);

    var invalid_config: AppConfig = .{ .companion_enabled = true };
    defer invalid_config.deinit(std.testing.allocator);
    applyAppOverrides(std.testing.allocator, &invalid_config, invalid.value);
    try std.testing.expect(!invalid_config.companion_enabled);
}

test "app config Companion availability round trips both explicit values" {
    for ([_]bool{ true, false }) |enabled| {
        var root = try parseTestRoot("{\"plugin_owned\":true,\"ui\":{\"plugin_value\":\"keep\"}}");
        defer root.deinit();

        const config: AppConfig = .{ .companion_enabled = enabled };
        try writeUiSection(root.arena.allocator(), &root.value.object, &config);
        const encoded = try std.json.Stringify.valueAlloc(std.testing.allocator, root.value, .{});
        defer std.testing.allocator.free(encoded);

        var saved = try parseTestRoot(encoded);
        defer saved.deinit();
        try std.testing.expect(saved.value.object.get("plugin_owned").?.bool);
        const saved_ui = saved.value.object.get("ui").?.object;
        try std.testing.expectEqualStrings("keep", saved_ui.get("plugin_value").?.string);
        try std.testing.expectEqual(enabled, saved_ui.get("companion_enabled").?.bool);

        var loaded: AppConfig = .{};
        defer loaded.deinit(std.testing.allocator);
        applyAppOverrides(std.testing.allocator, &loaded, saved.value);
        try std.testing.expectEqual(enabled, loaded.companion_enabled);
    }
}

test "app config accepts every companion character" {
    const cases = [_]struct {
        json: []const u8,
        expected: CompanionCharacter,
    }{
        .{ .json = "{\"ui\":{\"companion_character\":\"sprout\"}}", .expected = .sprout },
        .{ .json = "{\"ui\":{\"companion_character\":\"moss\"}}", .expected = .moss },
        .{ .json = "{\"ui\":{\"companion_character\":\"vireo\"}}", .expected = .vireo },
        .{ .json = "{\"ui\":{\"companion_character\":\"MoSs\"}}", .expected = .moss },
    };

    for (cases) |case| {
        var root = try parseTestRoot(case.json);
        defer root.deinit();
        var config: AppConfig = .{};
        defer config.deinit(std.testing.allocator);
        applyAppOverrides(std.testing.allocator, &config, root.value);
        try std.testing.expectEqual(case.expected, config.companion_character);
    }
}

test "app config falls back to Sprout for invalid companion characters" {
    var invalid_string = try parseTestRoot("{\"ui\":{\"companion_character\":\"fern\"}}");
    defer invalid_string.deinit();
    var invalid_type = try parseTestRoot("{\"ui\":{\"companion_character\":7}}");
    defer invalid_type.deinit();

    var config: AppConfig = .{ .companion_character = .moss };
    defer config.deinit(std.testing.allocator);
    applyAppOverrides(std.testing.allocator, &config, invalid_string.value);
    try std.testing.expectEqual(CompanionCharacter.sprout, config.companion_character);

    config.companion_character = .vireo;
    applyAppOverrides(std.testing.allocator, &config, invalid_type.value);
    try std.testing.expectEqual(CompanionCharacter.sprout, config.companion_character);
}

test "app config companion character save round trip preserves unknown keys" {
    var root = try parseTestRoot(
        \\{
        \\  "plugin_owned": { "keep": true },
        \\  "ui": { "plugin_value": "keep", "companion_character": "sprout" }
        \\}
    );
    defer root.deinit();

    const config: AppConfig = .{ .companion_character = .vireo };
    try writeUiSection(root.arena.allocator(), &root.value.object, &config);
    const encoded = try std.json.Stringify.valueAlloc(std.testing.allocator, root.value, .{});
    defer std.testing.allocator.free(encoded);

    var saved = try parseTestRoot(encoded);
    defer saved.deinit();
    try std.testing.expect(saved.value.object.get("plugin_owned").?.object.get("keep").?.bool);
    const saved_ui = saved.value.object.get("ui").?.object;
    try std.testing.expectEqualStrings("keep", saved_ui.get("plugin_value").?.string);
    try std.testing.expectEqualStrings("vireo", saved_ui.get("companion_character").?.string);

    var loaded: AppConfig = .{};
    defer loaded.deinit(std.testing.allocator);
    applyAppOverrides(std.testing.allocator, &loaded, saved.value);
    try std.testing.expectEqual(CompanionCharacter.vireo, loaded.companion_character);
}

test "app config accepts theme source and color overrides" {
    var root = try parseTestRoot(
        \\{
        \\  "theme": {
        \\    "theme": "default",
        \\    "colors": {
        \\      "background": "#101820",
        \\      "accent": [80, 200, 120]
        \\    }
        \\  }
        \\}
    );
    defer root.deinit();

    var config: AppConfig = .{};
    defer config.deinit(std.testing.allocator);
    applyAppOverrides(std.testing.allocator, &config, root.value);

    try std.testing.expectEqual(theme.ThemeSource.default, config.theme_config.source);
    try std.testing.expectEqual(@as(f32, 0x10) / 255.0, config.theme_config.colors.background.?[0]);
    try std.testing.expectEqual(@as(f32, 80) / 255.0, config.theme_config.colors.accent.?[0]);
}

test "app config loads and selects installed themes" {
    var root = try parseTestRoot(
        \\{
        \\  "theme": { "theme": "default", "active": "Forest" },
        \\  "installed_themes": [{
        \\    "name": "Forest",
        \\    "theme": { "theme": "default", "colors": { "background": "#101820" } },
        \\    "ui_font_size": 22,
        \\    "terminal_font_size": 19
        \\  }]
        \\}
    );
    defer root.deinit();

    var config: AppConfig = .{};
    defer config.deinit(std.testing.allocator);
    applyAppOverrides(std.testing.allocator, &config, root.value);

    try std.testing.expectEqual(@as(usize, 1), config.installed_themes.len);
    try std.testing.expectEqualStrings("Forest", config.installed_themes[0].name);
    try std.testing.expectEqual(@as(usize, 2), config.themeChoiceIndex());
    try std.testing.expectEqual(@as(?f32, 22), config.installed_themes[0].font_size);

    try config.selectThemeChoice(std.testing.allocator, 2);
    try std.testing.expectEqualStrings("Forest", config.active_theme.?);
    try std.testing.expectEqual(@as(f32, 0x10) / 255.0, config.theme_config.colors.background.?[0]);
    try std.testing.expectEqual(@as(f32, 19), config.terminal_font_size);

    try config.selectThemeChoice(std.testing.allocator, 1);
    try std.testing.expect(config.active_theme == null);
    try std.testing.expectEqual(theme.ThemeSource.omarchy, config.theme_config.source);
    try std.testing.expect(config.theme_config.colors.background == null);
}

test "app config accepts named open default" {
    var root = try parseTestRoot("{\"open\":{\"default\":\"cursor\"}}");
    defer root.deinit();

    var config: AppConfig = .{};
    defer config.deinit(std.testing.allocator);
    applyAppOverrides(std.testing.allocator, &config, root.value);

    try std.testing.expect(config.default_open_action == .cursor);
}

test "app config accepts link open target" {
    var root = try parseTestRoot("{\"open\":{\"links\":\"system_browser\",\"chat_links\":\"verde_browser\",\"terminal_links\":\"global\"}}");
    defer root.deinit();

    var config: AppConfig = .{};
    defer config.deinit(std.testing.allocator);
    applyAppOverrides(std.testing.allocator, &config, root.value);

    try std.testing.expectEqual(LinkOpenTarget.system_browser, config.link_open_target);
    try std.testing.expectEqual(LinkOpenOverride.verde_browser, config.chat_link_open_override);
    try std.testing.expectEqual(LinkOpenOverride.global, config.terminal_link_open_override);
}

test "link overrides resolve against the global target" {
    try std.testing.expectEqual(LinkOpenTarget.system_browser, LinkOpenOverride.global.resolve(.system_browser));
    try std.testing.expectEqual(LinkOpenTarget.verde_browser, LinkOpenOverride.verde_browser.resolve(.system_browser));
    try std.testing.expectEqual(LinkOpenTarget.system_browser, LinkOpenOverride.system_browser.resolve(.verde_browser));
}

test "web links default to the system browser" {
    const config: AppConfig = .{};
    try std.testing.expectEqual(LinkOpenTarget.system_browser, config.link_open_target);
    try std.testing.expectEqual(LinkOpenTarget.system_browser, config.chat_link_open_override.resolve(config.link_open_target));
    try std.testing.expectEqual(LinkOpenTarget.system_browser, config.terminal_link_open_override.resolve(config.link_open_target));
}

test "app config accepts browser scroll speed and legacy fast scrolling" {
    var root = try parseTestRoot("{\"browser\":{\"fast_scrolling\":false,\"scroll_speed\":4.25}}");
    defer root.deinit();

    var config: AppConfig = .{};
    defer config.deinit(std.testing.allocator);
    try std.testing.expectEqual(DEFAULT_BROWSER_SCROLL_SPEED, config.browser_scroll_speed);
    applyAppOverrides(std.testing.allocator, &config, root.value);

    try std.testing.expectEqual(@as(f32, 4.25), config.browser_scroll_speed);

    var legacy_root = try parseTestRoot("{\"browser\":{\"fast_scrolling\":false}}");
    defer legacy_root.deinit();
    applyAppOverrides(std.testing.allocator, &config, legacy_root.value);
    try std.testing.expectEqual(MIN_BROWSER_SCROLL_SPEED, config.browser_scroll_speed);
}

test "app config accepts workspace Neovim file link preference" {
    var root = try parseTestRoot("{\"open\":{\"file_links_in_neovim_pane\":true}}");
    defer root.deinit();

    var config: AppConfig = .{};
    defer config.deinit(std.testing.allocator);
    try std.testing.expect(!config.file_links_in_neovim_pane);
    applyAppOverrides(std.testing.allocator, &config, root.value);

    try std.testing.expect(config.file_links_in_neovim_pane);
}

test "app config accepts automatic update check preference" {
    var root = try parseTestRoot("{\"updates\":{\"check_automatically\":false}}");
    defer root.deinit();

    var config: AppConfig = .{};
    defer config.deinit(std.testing.allocator);
    applyAppOverrides(std.testing.allocator, &config, root.value);

    try std.testing.expect(!config.check_for_updates_automatically);
}

test "app config accepts automatic chat title preference" {
    var root = try parseTestRoot("{\"chat\":{\"automatic_titles\":false}}");
    defer root.deinit();

    var config: AppConfig = .{};
    defer config.deinit(std.testing.allocator);
    applyAppOverrides(std.testing.allocator, &config, root.value);

    try std.testing.expect(!config.automatic_chat_titles_enabled);
}

test "app config accepts chat title provider and model" {
    var root = try parseTestRoot("{\"chat\":{\"title_provider\":\"claude\",\"title_model\":\"haiku\"}}");
    defer root.deinit();

    var config: AppConfig = .{};
    defer config.deinit(std.testing.allocator);
    applyAppOverrides(std.testing.allocator, &config, root.value);

    try std.testing.expectEqual(ChatTitleProvider.claude, config.chat_title_provider);
    try std.testing.expectEqualStrings("haiku", config.chatTitleModel());
}

test "app config accepts new chat defaults and favorite models" {
    var root = try parseTestRoot(
        "{\"chat\":{\"default_provider\":\"claude\",\"default_model\":\"sonnet\",\"default_reasoning\":\"high\",\"favorite_models\":[{\"provider\":\"codex\",\"model\":\"gpt-5.6-sol\"},{\"provider\":\"claude\",\"model\":\"sonnet\"}]}}",
    );
    defer root.deinit();

    var config: AppConfig = .{};
    defer config.deinit(std.testing.allocator);
    applyAppOverrides(std.testing.allocator, &config, root.value);

    try std.testing.expectEqual(ChatProvider.claude, config.new_chat_provider);
    try std.testing.expectEqualStrings("sonnet", config.new_chat_model.?);
    try std.testing.expectEqual(ChatReasoning.high, config.new_chat_reasoning);
    try std.testing.expect(config.isFavoriteModel(.codex, "gpt-5.6-sol"));
    try std.testing.expect(config.isFavoriteModel(.claude, "sonnet"));
    try std.testing.expectEqual(@as(usize, 2), config.favorite_models.len);
}

test "favorite model toggle adds and removes one provider model" {
    var config: AppConfig = .{};
    defer config.deinit(std.testing.allocator);

    try std.testing.expect(try config.toggleFavoriteModel(std.testing.allocator, .codex, "gpt-5.6-sol"));
    try std.testing.expect(config.isFavoriteModel(.codex, "gpt-5.6-sol"));
    try std.testing.expect(!(try config.toggleFavoriteModel(std.testing.allocator, .codex, "gpt-5.6-sol")));
    try std.testing.expect(!config.isFavoriteModel(.codex, "gpt-5.6-sol"));
}

test "app config defaults new chats to new panes and accepts replacement preference" {
    var config: AppConfig = .{};
    defer config.deinit(std.testing.allocator);
    try std.testing.expectEqual(NewChatPaneBehavior.new_pane, config.new_chat_pane_behavior);

    var root = try parseTestRoot("{\"chat\":{\"new_pane_behavior\":\"replace_pane\"}}");
    defer root.deinit();
    applyAppOverrides(std.testing.allocator, &config, root.value);

    try std.testing.expectEqual(NewChatPaneBehavior.replace_pane, config.new_chat_pane_behavior);
}

test "app config accepts tool call group preference" {
    var root = try parseTestRoot("{\"transcript\":{\"tool_call_groups\":\"remember_last\",\"tool_call_groups_last_expanded\":true}}");
    defer root.deinit();

    var config: AppConfig = .{};
    defer config.deinit(std.testing.allocator);
    applyAppOverrides(std.testing.allocator, &config, root.value);

    try std.testing.expectEqual(ToolCallGroupPreference.remember_last, config.tool_call_group_preference);
    try std.testing.expect(config.tool_call_groups_last_expanded);
}

test "app config accepts diff layout preference" {
    var root = try parseTestRoot("{\"transcript\":{\"diff_layout\":\"split\"}}");
    defer root.deinit();

    var config: AppConfig = .{};
    defer config.deinit(std.testing.allocator);
    applyAppOverrides(std.testing.allocator, &config, root.value);

    try std.testing.expectEqual(DiffLayoutPreference.split, config.diff_layout_preference);
}

test "app config accepts custom open default" {
    var root = try parseTestRoot("{\"open\":{\"default\":{\"label\":\"Workbench\",\"action\":\"cursor .\"}}}");
    defer root.deinit();

    var config: AppConfig = .{};
    defer config.deinit(std.testing.allocator);
    applyAppOverrides(std.testing.allocator, &config, root.value);

    try std.testing.expect(config.default_open_action == .custom);
    try std.testing.expectEqualStrings("Workbench", config.default_open_action.custom.label);
    try std.testing.expectEqualStrings("cursor .", config.default_open_action.custom.action);
}

fn parseTestRoot(raw: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, std.testing.allocator, raw, .{
        .allocate = .alloc_always,
    });
}
