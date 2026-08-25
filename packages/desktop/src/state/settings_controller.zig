//! Settings, onboarding, hook, MCP, and updater controller state.

const std = @import("std");

const updater = @import("../app/updater.zig");
const update_installer = @import("../app/update_installer.zig");
const app_config = @import("../app/config.zig");
const chat_threads = @import("../chat/threads.zig");
const provider_hooks = @import("../providers/hooks.zig");
const provider_mcp = @import("../providers/mcp.zig");
const profiler = @import("../runtime/profiler.zig");
const runtime_log = @import("../runtime/log.zig");
const theme = @import("../ui/theme.zig");
const utils = @import("../utils.zig");
const provider_models = @import("provider_models.zig");

const ModelOption = provider_models.ModelOption;
const Provider = provider_models.Provider;
const log = std.log.scoped(.native_shell);

const CHAT_TITLE_PROVIDER_OPTIONS = [_]app_config.ChatTitleProvider{
    .codex,
    .claude,
    .cursor,
    .opencode,
};
const NEW_CHAT_PROVIDER_OPTIONS = [_]app_config.ChatProvider{ .codex, .claude, .cursor, .opencode, .pi, .fx, .grok };
const NEW_CHAT_REASONING_OPTIONS = [_]app_config.ChatReasoning{ .provider_default, .low, .medium, .high, .xhigh, .max };

fn monotonicMs() i64 {
    return @intCast(@divTrunc(profiler.nowNs(), std.time.ns_per_ms));
}

fn dbProviderForChatTitleProvider(provider: app_config.ChatTitleProvider) Provider {
    return switch (provider) {
        .codex => .codex,
        .claude => .claude,
        .cursor => .cursor,
        .opencode => .opencode,
    };
}

fn dbProviderForChatProvider(provider: app_config.ChatProvider) Provider {
    return switch (provider) {
        .codex => .codex,
        .claude => .claude,
        .cursor => .cursor,
        .opencode => .opencode,
        .pi => .pi,
        .fx => .fx,
        .grok => .grok,
    };
}

pub const OpenAction = enum {
    folder,
    editor,
    cursor,
    vscode,
    zed,
    custom,
};

pub const Draft = struct {
    font_size: f32 = theme.DEFAULT_FONT_SIZE,
    terminal_font_size: f32 = app_config.DEFAULT_TERMINAL_FONT_SIZE,
    workspace_pane_gap: f32 = app_config.DEFAULT_WORKSPACE_PANE_GAP,
    workspace_panes_per_view: u8 = app_config.DEFAULT_WORKSPACE_PANES_PER_VIEW,
    workspace_split_default_pane: app_config.WorkspaceSplitDefaultPane = .chat,
    workspace_scroll_direction: app_config.WorkspaceScrollDirection = .horizontal,
    workspace_scroll_override_enabled: bool = false,
    workspace_scroll_mode: app_config.WorkspaceScrollMode = .automatic,
    workspace_scroll_threshold: u8 = app_config.DEFAULT_WORKSPACE_SCROLL_THRESHOLD,
    unzoom_on_pane_navigation: bool = false,
    reduced_motion: bool = false,
    companion_enabled: bool = false,
    companion_character: app_config.CompanionCharacter = .sprout,
    theme_source: theme.ThemeSource = .omarchy,
    theme_choice: usize = 1,
    open_action: OpenAction = .folder,
    link_open_target: app_config.LinkOpenTarget = .system_browser,
    chat_link_open_override: app_config.LinkOpenOverride = .global,
    terminal_link_open_override: app_config.LinkOpenOverride = .global,
    browser_scroll_speed: f32 = app_config.DEFAULT_BROWSER_SCROLL_SPEED,
    file_links_in_neovim_pane: bool = false,
    tool_call_group_preference: app_config.ToolCallGroupPreference = .collapsed,
    diff_layout_preference: app_config.DiffLayoutPreference = .stacked,
    automatic_chat_titles_enabled: bool = true,
    chat_title_provider: app_config.ChatTitleProvider = .codex,
    new_chat_provider: app_config.ChatProvider = .codex,
    new_chat_reasoning: app_config.ChatReasoning = .low,
    new_chat_pane_behavior: app_config.NewChatPaneBehavior = .new_pane,
    check_for_updates_automatically: bool = true,
    notifications_enabled: bool = true,
};

pub const UpdateInstallerTerminalStatus = enum {
    running,
    succeeded,
    failed,
};

pub const UpdateInstallerTerminal = struct {
    project_index: usize,
    dock_id: u32,
    status: UpdateInstallerTerminalStatus = .running,
};

pub const HookKind = enum {
    claude,
    codex,
    cursor,
    grok,
    amp,
    opencode,
};

pub fn hookDisplayName(kind: HookKind) []const u8 {
    return switch (kind) {
        .claude => "Claude",
        .codex => "Codex",
        .cursor => "Cursor",
        .grok => "Grok",
        .amp => "Amp",
        .opencode => "OpenCode",
    };
}

pub fn hookFailureNotice(kind: HookKind, installing: bool) []const u8 {
    return switch (kind) {
        .claude => if (installing) "Could not install Claude hooks." else "Could not remove Claude hooks.",
        .codex => if (installing) "Could not install Codex hooks." else "Could not remove Codex hooks.",
        .cursor => if (installing) "Could not install Cursor hooks." else "Could not remove Cursor hooks.",
        .grok => if (installing) "Could not install Grok hooks." else "Could not remove Grok hooks.",
        .amp => if (installing) "Could not install Amp hooks." else "Could not remove Amp hooks.",
        .opencode => if (installing) "Could not install OpenCode hooks." else "Could not remove OpenCode hooks.",
    };
}

pub fn hookSuccessNotice(kind: HookKind, installed: bool) []const u8 {
    return switch (kind) {
        .claude => if (installed) "Enabled global Claude status hooks." else "Disabled global Claude status hooks.",
        .codex => if (installed) "Enabled global Codex status hooks." else "Disabled global Codex status hooks.",
        .cursor => if (installed) "Enabled global Cursor status hooks." else "Disabled global Cursor status hooks.",
        .grok => if (installed) "Enabled global Grok status hooks." else "Disabled global Grok status hooks.",
        .amp => if (installed) "Enabled global Amp status hooks." else "Disabled global Amp status hooks.",
        .opencode => if (installed) "Enabled global OpenCode status hooks." else "Disabled global OpenCode status hooks.",
    };
}

pub const State = struct {
    mcp_onboarding_visible: bool = false,
    provider_onboarding_visible: bool = false,
    provider_onboarding_dismissed: bool = false,
    modal_visible: bool = false,
    modal_anim_progress: f32 = 0.0,
    modal_anim_last_ms: i64 = 0,
    modal_closing: bool = false,
    draft: Draft = .{},
    chat_title_model: ?[]u8 = null,
    new_chat_model: ?[]u8 = null,
    hook_claude_installed: bool = false,
    hook_codex_installed: bool = false,
    hook_cursor_installed: bool = false,
    hook_grok_installed: bool = false,
    hook_amp_installed: bool = false,
    hook_opencode_installed: bool = false,
    mcp_summary: provider_mcp.Summary = .{},
    scroll_y: f32 = 0.0,
    hover_control: ?u8 = null,
    browser_scroll_speed_drag_active: bool = false,
    browser_scroll_speed_drag_x: f32 = 0.0,
    browser_scroll_speed_drag_w: f32 = 0.0,
    close_hovered: bool = false,
    companion_character_dropdown_open: bool = false,
    companion_character_hover_index: ?usize = null,
    theme_dropdown_open: bool = false,
    theme_hover_index: ?usize = null,
    theme_menu_scroll: usize = 0,
    title_provider_dropdown_open: bool = false,
    title_model_dropdown_open: bool = false,
    title_menu_hover_index: ?usize = null,
    title_model_menu_scroll: usize = 0,
    new_chat_provider_dropdown_open: bool = false,
    new_chat_model_dropdown_open: bool = false,
    new_chat_reasoning_dropdown_open: bool = false,
    new_chat_menu_hover_index: ?usize = null,
    new_chat_model_menu_scroll: usize = 0,
    update_notes_expanded: bool = false,
    update: updater.State = .{},
    update_installer_started: bool = false,
    update_installer_terminal: ?UpdateInstallerTerminal = null,
    update_exit_requested: bool = false,
};

/// Installs or removes the global Claude notify hooks and refreshes the
/// settings toggle state. Acts immediately (filesystem side effect).
pub fn toggleClaudeGlobalHooks(self: anytype) void {
    self.toggleProviderGlobalHooks(.claude, &self.settings_controller.hook_claude_installed);
}

/// Installs or removes the global Codex notify hooks and refreshes the
/// settings toggle state. Merges into ~/.codex/hooks.json, preserving any
/// user-owned hooks. Acts immediately (filesystem side effect).
pub fn toggleCodexGlobalHooks(self: anytype) void {
    self.toggleProviderGlobalHooks(.codex, &self.settings_controller.hook_codex_installed);
}

/// Installs or removes Cursor's user-scoped hooks. Cursor consumes the same
/// hook file in its terminal agent and desktop Agent UI.
pub fn toggleCursorGlobalHooks(self: anytype) void {
    self.toggleProviderGlobalHooks(.cursor, &self.settings_controller.hook_cursor_installed);
}

/// Installs or removes Grok's user-scoped status hook.
pub fn toggleGrokGlobalHooks(self: anytype) void {
    self.toggleProviderGlobalHooks(.grok, &self.settings_controller.hook_grok_installed);
}

/// Installs or removes the global Amp notify plugin and refreshes the
/// settings toggle state. Acts immediately (filesystem side effect), like
/// the Claude/Codex toggles.
pub fn toggleAmpGlobalHooks(self: anytype) void {
    self.toggleProviderGlobalHooks(.amp, &self.settings_controller.hook_amp_installed);
}

/// Installs or removes the global OpenCode lifecycle plugin.
pub fn toggleOpencodeGlobalHooks(self: anytype) void {
    self.toggleProviderGlobalHooks(.opencode, &self.settings_controller.hook_opencode_installed);
}

pub fn toggleProviderGlobalHooks(self: anytype, provider: HookKind, installed: *bool) void {
    const changing_to_installed = !installed.*;
    const result = if (changing_to_installed)
        switch (provider) {
            .claude => provider_hooks.ensureClaudeGlobalHooks(self.allocator),
            .codex => provider_hooks.ensureCodexGlobalHooks(self.allocator),
            .cursor => provider_hooks.ensureCursorGlobalHooks(self.allocator),
            .grok => provider_hooks.ensureGrokGlobalHooks(self.allocator),
            .amp => provider_hooks.ensureAmpGlobalHooks(self.allocator),
            .opencode => provider_hooks.ensureOpencodeGlobalHooks(self.allocator),
        }
    else switch (provider) {
        .claude => provider_hooks.removeClaudeGlobalHooks(self.allocator),
        .codex => provider_hooks.removeCodexGlobalHooks(self.allocator),
        .cursor => provider_hooks.removeCursorGlobalHooks(self.allocator),
        .grok => provider_hooks.removeGrokGlobalHooks(self.allocator),
        .amp => provider_hooks.removeAmpGlobalHooks(self.allocator),
        .opencode => provider_hooks.removeOpencodeGlobalHooks(self.allocator),
    };
    result catch |err| {
        log.warn("failed to {s} global {s} hooks: {s}", .{
            if (changing_to_installed) "install" else "remove",
            hookDisplayName(provider),
            @errorName(err),
        });
        self.setSidebarNotice(hookFailureNotice(provider, changing_to_installed));
        self.markDirty();
        return;
    };
    installed.* = changing_to_installed;
    self.setSidebarNotice(hookSuccessNotice(provider, changing_to_installed));
    self.markDirty();
}

pub fn replaceAppConfig(self: anytype, next_config: app_config.AppConfig) void {
    self.app_config.deinit(self.allocator);
    self.app_config = next_config;
    self.composer_controller.model_picker.invalidateItems();
    self.reconcileCompanionAvailability();
}

fn syncCompanionCharacterDraft(settings: *State, config: *const app_config.AppConfig) void {
    settings.draft.companion_character = config.companion_character;
}

fn isCompanionCharacterDraftDirty(settings: *const State, config: *const app_config.AppConfig) bool {
    return settings.draft.companion_character != config.companion_character;
}

fn applyCompanionCharacterDraft(settings: *const State, config: *app_config.AppConfig) void {
    config.companion_character = settings.draft.companion_character;
}

pub fn syncSettingsDraftFromConfig(self: anytype) void {
    var workspace_scroll_override_enabled = false;
    var workspace_scroll_mode = self.app_config.workspace_scroll_mode;
    var workspace_scroll_threshold = self.app_config.workspace_scroll_threshold;
    if (self.project_controller.selected_index < self.project_controller.projects.items.len) {
        const layout = &self.project_controller.projects.items[self.project_controller.selected_index].workspace_layout;
        workspace_scroll_override_enabled = layout.hasScrollOverride();
        workspace_scroll_mode = layout.effectiveScrollMode(workspace_scroll_mode);
        workspace_scroll_threshold = layout.effectiveScrollThreshold(workspace_scroll_threshold);
    }
    self.settings_controller.draft = .{
        .font_size = self.app_config.font_size,
        .terminal_font_size = self.app_config.terminal_font_size,
        .workspace_pane_gap = self.app_config.workspace_pane_gap,
        .workspace_panes_per_view = self.app_config.workspace_panes_per_view,
        .workspace_split_default_pane = self.app_config.workspace_split_default_pane,
        .workspace_scroll_direction = self.app_config.workspace_scroll_direction,
        .workspace_scroll_override_enabled = workspace_scroll_override_enabled,
        .workspace_scroll_mode = workspace_scroll_mode,
        .workspace_scroll_threshold = workspace_scroll_threshold,
        .unzoom_on_pane_navigation = self.app_config.unzoom_on_pane_navigation,
        .reduced_motion = self.app_config.reduced_motion,
        .companion_enabled = self.app_config.companion_enabled,
        .theme_source = self.app_config.theme_config.source,
        .theme_choice = self.app_config.themeChoiceIndex(),
        .open_action = settingsOpenActionFromConfig(self.app_config.default_open_action),
        .link_open_target = self.app_config.link_open_target,
        .chat_link_open_override = self.app_config.chat_link_open_override,
        .terminal_link_open_override = self.app_config.terminal_link_open_override,
        .browser_scroll_speed = self.app_config.browser_scroll_speed,
        .file_links_in_neovim_pane = self.app_config.file_links_in_neovim_pane,
        .tool_call_group_preference = self.app_config.tool_call_group_preference,
        .diff_layout_preference = self.app_config.diff_layout_preference,
        .automatic_chat_titles_enabled = self.app_config.automatic_chat_titles_enabled,
        .chat_title_provider = self.app_config.chat_title_provider,
        .new_chat_provider = self.app_config.new_chat_provider,
        .new_chat_reasoning = self.app_config.new_chat_reasoning,
        .new_chat_pane_behavior = self.app_config.new_chat_pane_behavior,
        .check_for_updates_automatically = self.app_config.check_for_updates_automatically,
        .notifications_enabled = self.app_config.notifications_enabled,
    };
    syncCompanionCharacterDraft(&self.settings_controller, &self.app_config);
    replaceSettingsChatTitleModel(self, self.app_config.chatTitleModel()) catch {
        if (self.settings_controller.chat_title_model) |model| self.allocator.free(model);
        self.settings_controller.chat_title_model = null;
    };
    const new_chat_model = self.app_config.new_chat_model orelse defaultNewChatModelRef(self, self.app_config.new_chat_provider);
    replaceSettingsNewChatModel(self, new_chat_model) catch {
        if (self.settings_controller.new_chat_model) |model| self.allocator.free(model);
        self.settings_controller.new_chat_model = null;
    };
}

pub fn isSettingsDraftDirty(self: anytype) bool {
    const draft = self.settings_controller.draft;
    if (draft.font_size != self.app_config.font_size) return true;
    if (draft.terminal_font_size != self.app_config.terminal_font_size) return true;
    if (draft.workspace_pane_gap != self.app_config.workspace_pane_gap) return true;
    if (draft.workspace_panes_per_view != self.app_config.workspace_panes_per_view) return true;
    if (draft.workspace_split_default_pane != self.app_config.workspace_split_default_pane) return true;
    if (draft.workspace_scroll_direction != self.app_config.workspace_scroll_direction) return true;
    var workspace_scroll_override_enabled = false;
    var workspace_scroll_mode = self.app_config.workspace_scroll_mode;
    var workspace_scroll_threshold = self.app_config.workspace_scroll_threshold;
    if (self.project_controller.selected_index < self.project_controller.projects.items.len) {
        const layout = &self.project_controller.projects.items[self.project_controller.selected_index].workspace_layout;
        workspace_scroll_override_enabled = layout.hasScrollOverride();
        workspace_scroll_mode = layout.effectiveScrollMode(workspace_scroll_mode);
        workspace_scroll_threshold = layout.effectiveScrollThreshold(workspace_scroll_threshold);
    }
    if (draft.workspace_scroll_override_enabled != workspace_scroll_override_enabled) return true;
    if (draft.workspace_scroll_mode != workspace_scroll_mode) return true;
    if (draft.workspace_scroll_threshold != workspace_scroll_threshold) return true;
    if (draft.unzoom_on_pane_navigation != self.app_config.unzoom_on_pane_navigation) return true;
    if (draft.reduced_motion != self.app_config.reduced_motion) return true;
    if (draft.companion_enabled != self.app_config.companion_enabled) return true;
    if (isCompanionCharacterDraftDirty(&self.settings_controller, &self.app_config)) return true;
    if (draft.theme_choice != self.app_config.themeChoiceIndex()) return true;
    if (draft.link_open_target != self.app_config.link_open_target) return true;
    if (draft.chat_link_open_override != self.app_config.chat_link_open_override) return true;
    if (draft.terminal_link_open_override != self.app_config.terminal_link_open_override) return true;
    if (draft.browser_scroll_speed != self.app_config.browser_scroll_speed) return true;
    if (draft.file_links_in_neovim_pane != self.app_config.file_links_in_neovim_pane) return true;
    if (draft.tool_call_group_preference != self.app_config.tool_call_group_preference) return true;
    if (draft.diff_layout_preference != self.app_config.diff_layout_preference) return true;
    if (draft.automatic_chat_titles_enabled != self.app_config.automatic_chat_titles_enabled) return true;
    if (draft.chat_title_provider != self.app_config.chat_title_provider) return true;
    if (draft.new_chat_provider != self.app_config.new_chat_provider) return true;
    if (draft.new_chat_reasoning != self.app_config.new_chat_reasoning) return true;
    const configured_new_chat_model = self.app_config.new_chat_model orelse defaultNewChatModelRef(self, self.app_config.new_chat_provider);
    if (!std.mem.eql(u8, self.settingsNewChatModelRef(), configured_new_chat_model)) return true;
    if (draft.new_chat_pane_behavior != self.app_config.new_chat_pane_behavior) return true;
    if (!std.mem.eql(u8, self.settingsChatTitleModelRef(), self.app_config.chatTitleModel())) return true;
    if (draft.check_for_updates_automatically != self.app_config.check_for_updates_automatically) return true;
    if (draft.notifications_enabled != self.app_config.notifications_enabled) return true;
    return draft.open_action != settingsOpenActionFromConfig(self.app_config.default_open_action);
}

pub fn openSettingsModal(self: anytype) void {
    self.closeSidebarContextMenu();
    self.workspace_header_open_menu_open = false;
    self.workspace_header_open_menu_pane_id = null;
    self.browser_controller.inspector_menu_open = false;
    self.syncSettingsDraftFromConfig();
    self.settings_controller.hook_claude_installed = provider_hooks.claudeGlobalHooksInstalled(self.allocator);
    self.settings_controller.hook_codex_installed = provider_hooks.codexGlobalHooksInstalled(self.allocator);
    self.settings_controller.hook_cursor_installed = provider_hooks.cursorGlobalHooksInstalled(self.allocator);
    self.settings_controller.hook_grok_installed = provider_hooks.grokGlobalHooksInstalled(self.allocator);
    self.settings_controller.hook_amp_installed = provider_hooks.ampGlobalHooksInstalled(self.allocator);
    self.settings_controller.hook_opencode_installed = provider_hooks.opencodeGlobalHooksInstalled(self.allocator);
    self.settings_controller.mcp_summary = provider_mcp.inspect(self.allocator);
    self.settings_controller.scroll_y = 0.0;
    self.settings_controller.hover_control = null;
    self.settings_controller.browser_scroll_speed_drag_active = false;
    self.settings_controller.close_hovered = false;
    self.settings_controller.companion_character_dropdown_open = false;
    self.settings_controller.companion_character_hover_index = null;
    self.settings_controller.theme_dropdown_open = false;
    self.settings_controller.theme_hover_index = null;
    self.settings_controller.theme_menu_scroll = 0;
    self.settings_controller.title_provider_dropdown_open = false;
    self.settings_controller.title_model_dropdown_open = false;
    self.settings_controller.title_menu_hover_index = null;
    self.settings_controller.title_model_menu_scroll = 0;
    self.settings_controller.new_chat_provider_dropdown_open = false;
    self.settings_controller.new_chat_model_dropdown_open = false;
    self.settings_controller.new_chat_reasoning_dropdown_open = false;
    self.settings_controller.new_chat_menu_hover_index = null;
    self.settings_controller.new_chat_model_menu_scroll = 0;
    self.settings_controller.update_notes_expanded = false;
    self.settings_controller.modal_closing = false;
    self.settings_controller.modal_anim_progress = 0.0;
    self.settings_controller.modal_anim_last_ms = 0;
    self.settings_controller.modal_visible = true;
    if (self.app_config.check_for_updates_automatically and self.settings_controller.update.status == .idle) {
        self.settings_controller.update.start();
    }
    self.palette_modal_text_focus = .none;
    self.blurPaletteComposer();
    self.noteInteraction();
    self.markDirty();
}

/// Installs or removes Verde's user-scoped MCP registration across all
/// detected providers. Existing non-Verde entries are never overwritten.
pub fn toggleGlobalMcpIntegration(self: anytype) void {
    if (self.app_config.mcp_integration_enabled or self.settings_controller.mcp_summary.installedCount() > 0) {
        self.settings_controller.mcp_summary = provider_mcp.uninstall(self.allocator) catch |err| {
            log.warn("failed to remove provider MCP registrations: {s}", .{@errorName(err)});
            self.setSidebarNotice("Could not remove all Verde MCP registrations.");
            self.markDirty();
            return;
        };
        self.app_config.mcp_integration_enabled = self.settings_controller.mcp_summary.installedCount() > 0 or self.settings_controller.mcp_summary.failedCount() > 0;
        if (self.settings_controller.mcp_summary.failedCount() > 0) {
            self.setSidebarNotice("Removed Verde MCP where possible; some provider configs could not be updated.");
        } else {
            self.setSidebarNotice("Disabled Verde MCP tools in agent providers.");
        }
    } else {
        const summary = provider_mcp.install(self.allocator) catch |err| {
            log.warn("failed to install provider MCP registrations: {s}", .{@errorName(err)});
            self.setSidebarNotice("Could not enable Verde MCP tools.");
            self.markDirty();
            return;
        };
        self.settings_controller.mcp_summary = summary;
        if (summary.detectedCount() == 0) {
            self.setSidebarNotice("No supported agent providers were detected.");
            self.markDirty();
            return;
        }
        self.app_config.mcp_integration_enabled = summary.installedCount() > 0;
        if (summary.failedCount() > 0) {
            self.setSidebarNotice("Enabled Verde MCP where possible; some provider configs could not be updated.");
        } else if (summary.conflictCount() > 0) {
            self.setSidebarNotice("Enabled Verde MCP where possible; existing entries were preserved.");
        } else {
            self.setSidebarNotice("Enabled Verde MCP tools in detected providers.");
        }
    }
    self.app_config.mcp_onboarding_completed = true;
    app_config.saveAppConfig(self.allocator, &self.app_config) catch |err| {
        log.warn("failed to persist MCP integration preference: {s}", .{@errorName(err)});
        self.setSidebarNotice("MCP change applied, but could not save Verde settings.");
    };
    self.markDirty();
}

pub fn cancelSettingsModal(self: anytype) void {
    if (self.settings_controller.modal_closing) return;
    beginSettingsModalClose(self);
    self.settings_controller.hover_control = null;
    self.settings_controller.close_hovered = false;
    self.settings_controller.companion_character_dropdown_open = false;
    self.settings_controller.companion_character_hover_index = null;
    self.settings_controller.theme_dropdown_open = false;
    self.settings_controller.theme_hover_index = null;
    self.settings_controller.title_provider_dropdown_open = false;
    self.settings_controller.title_model_dropdown_open = false;
    self.settings_controller.title_menu_hover_index = null;
    self.settings_controller.new_chat_provider_dropdown_open = false;
    self.settings_controller.new_chat_model_dropdown_open = false;
    self.settings_controller.new_chat_reasoning_dropdown_open = false;
    self.settings_controller.new_chat_menu_hover_index = null;
    self.syncSettingsDraftFromConfig();
    self.palette_modal_text_focus = .none;
    self.markDirty();
}

pub fn saveSettingsModal(self: anytype) !void {
    runtime_log.diagnostic("settings save begin theme={s} font={d:.2} terminal_font={d:.2}", .{
        @tagName(self.settings_controller.draft.theme_source),
        self.settings_controller.draft.font_size,
        self.settings_controller.draft.terminal_font_size,
    });
    try self.app_config.selectThemeChoice(self.allocator, self.settings_controller.draft.theme_choice);
    self.app_config.font_size = theme.clampf(self.settings_controller.draft.font_size, app_config.MIN_FONT_SIZE, app_config.MAX_FONT_SIZE);
    self.app_config.terminal_font_size = theme.clampf(self.settings_controller.draft.terminal_font_size, app_config.MIN_TERMINAL_FONT_SIZE, app_config.MAX_TERMINAL_FONT_SIZE);
    self.app_config.workspace_pane_gap = theme.clampf(self.settings_controller.draft.workspace_pane_gap, app_config.MIN_WORKSPACE_PANE_GAP, app_config.MAX_WORKSPACE_PANE_GAP);
    const next_panes_per_view = std.math.clamp(self.settings_controller.draft.workspace_panes_per_view, app_config.MIN_WORKSPACE_PANES_PER_VIEW, app_config.MAX_WORKSPACE_PANES_PER_VIEW);
    const panes_per_view_changed = next_panes_per_view != self.app_config.workspace_panes_per_view;
    self.app_config.workspace_panes_per_view = next_panes_per_view;
    self.app_config.workspace_split_default_pane = self.settings_controller.draft.workspace_split_default_pane;
    self.app_config.workspace_scroll_direction = self.settings_controller.draft.workspace_scroll_direction;
    self.app_config.unzoom_on_pane_navigation = self.settings_controller.draft.unzoom_on_pane_navigation;
    self.app_config.reduced_motion = self.settings_controller.draft.reduced_motion;
    self.app_config.companion_enabled = self.settings_controller.draft.companion_enabled;
    self.reconcileCompanionAvailability();
    applyCompanionCharacterDraft(&self.settings_controller, &self.app_config);
    const has_selected_workspace = self.project_controller.selected_index < self.project_controller.projects.items.len;
    const use_workspace_scroll_override = self.settings_controller.draft.workspace_scroll_override_enabled and has_selected_workspace;
    const workspace_scroll_threshold = std.math.clamp(self.settings_controller.draft.workspace_scroll_threshold, app_config.MIN_WORKSPACE_SCROLL_THRESHOLD, app_config.MAX_WORKSPACE_SCROLL_THRESHOLD);
    if (!use_workspace_scroll_override) {
        self.app_config.workspace_scroll_mode = self.settings_controller.draft.workspace_scroll_mode;
        self.app_config.workspace_scroll_threshold = workspace_scroll_threshold;
    }
    self.app_config.link_open_target = self.settings_controller.draft.link_open_target;
    self.app_config.chat_link_open_override = self.settings_controller.draft.chat_link_open_override;
    self.app_config.terminal_link_open_override = self.settings_controller.draft.terminal_link_open_override;
    self.app_config.browser_scroll_speed = theme.clampf(self.settings_controller.draft.browser_scroll_speed, app_config.MIN_BROWSER_SCROLL_SPEED, app_config.MAX_BROWSER_SCROLL_SPEED);
    self.app_config.file_links_in_neovim_pane = self.settings_controller.draft.file_links_in_neovim_pane;
    self.app_config.tool_call_group_preference = self.settings_controller.draft.tool_call_group_preference;
    self.app_config.diff_layout_preference = self.settings_controller.draft.diff_layout_preference;
    self.app_config.automatic_chat_titles_enabled = self.settings_controller.draft.automatic_chat_titles_enabled;
    self.app_config.chat_title_provider = self.settings_controller.draft.chat_title_provider;
    self.app_config.new_chat_provider = self.settings_controller.draft.new_chat_provider;
    self.app_config.new_chat_reasoning = self.settings_controller.draft.new_chat_reasoning;
    self.app_config.new_chat_pane_behavior = self.settings_controller.draft.new_chat_pane_behavior;
    try self.app_config.setChatTitleModel(self.allocator, self.settingsChatTitleModelRef());
    try self.app_config.setNewChatModel(self.allocator, self.settingsNewChatModelRef());
    const previous_auto_update_check = self.app_config.check_for_updates_automatically;
    errdefer self.app_config.check_for_updates_automatically = previous_auto_update_check;
    self.app_config.check_for_updates_automatically = self.settings_controller.draft.check_for_updates_automatically;
    self.app_config.notifications_enabled = self.settings_controller.draft.notifications_enabled;
    try applySettingsDraftOpenAction(self);

    try app_config.saveAppConfig(self.allocator, &self.app_config);
    self.app_config_file_mtime = app_config.configFileMtime(self.allocator) catch self.app_config_file_mtime;
    if (has_selected_workspace) {
        const layout = &self.project_controller.projects.items[self.project_controller.selected_index].workspace_layout;
        if (use_workspace_scroll_override) {
            layout.scroll_mode_override = self.settings_controller.draft.workspace_scroll_mode;
            layout.scroll_threshold_override = workspace_scroll_threshold;
        } else {
            layout.scroll_mode_override = null;
            layout.scroll_threshold_override = null;
        }
    }
    if (panes_per_view_changed) {
        // Editing the global density is an explicit request for that width;
        // stale manual pane widths must not keep silently overriding it, and
        // the setting has no per-workspace override, so clear every workspace.
        for (self.project_controller.projects.items) |*project| {
            project.workspace_layout.clearScrollPaneExtents();
        }
    }
    self.applyTerminalFontSizesFromConfig();
    self.app_config_runtime_sync_pending = true;
    beginSettingsModalClose(self);
    self.settings_controller.hover_control = null;
    self.settings_controller.close_hovered = false;
    self.settings_controller.companion_character_dropdown_open = false;
    self.settings_controller.companion_character_hover_index = null;
    self.settings_controller.theme_dropdown_open = false;
    self.settings_controller.theme_hover_index = null;
    self.settings_controller.title_provider_dropdown_open = false;
    self.settings_controller.title_model_dropdown_open = false;
    self.settings_controller.title_menu_hover_index = null;
    self.palette_modal_text_focus = .none;
    self.markDirty();
    runtime_log.diagnostic("settings save done", .{});
}

pub fn setWorkspaceScrollMode(self: anytype, mode: ?app_config.WorkspaceScrollMode) void {
    if (self.project_controller.selected_index >= self.project_controller.projects.items.len) return;
    const layout = &self.project_controller.projects.items[self.project_controller.selected_index].workspace_layout;
    layout.scroll_mode_override = mode;
    if (mode == null) {
        layout.scroll_threshold_override = null;
    } else if (layout.scroll_threshold_override == null) {
        layout.scroll_threshold_override = self.app_config.workspace_scroll_threshold;
    }
    self.settings_controller.draft.workspace_scroll_override_enabled = mode != null;
    self.settings_controller.draft.workspace_scroll_mode = mode orelse self.app_config.workspace_scroll_mode;
    self.settings_controller.draft.workspace_scroll_threshold = layout.effectiveScrollThreshold(self.app_config.workspace_scroll_threshold);
    self.setSidebarNotice(if (mode) |workspace_mode| switch (workspace_mode) {
        .automatic => "Workspace scrolling set to Automatic.",
        .always => "Workspace scrolling pinned on.",
        .disabled => "Workspace scrolling disabled; using tiled panes.",
    } else "Workspace scrolling now uses the global settings.");
    self.markDirty();
}

pub fn applyTerminalFontSizesFromConfig(self: anytype) void {
    for (self.project_controller.projects.items) |*project| {
        project.applyDefaultTerminalFontSize(self.app_config.terminal_font_size);
    }
}

pub fn reloadAppConfigFromDisk(self: anytype) !void {
    const next_config = try app_config.loadAppConfig(self.allocator);
    self.replaceAppConfig(next_config);
    self.applyTerminalFontSizesFromConfig();
    if (self.settings_controller.modal_visible) self.syncSettingsDraftFromConfig();
}

/// Starts the settings modal fade-out; the modal stays visible (input
/// blocked) until the fade completes in `tickSettingsModalAnimation`.
fn beginSettingsModalClose(self: anytype) void {
    if (!self.settings_controller.modal_visible) return;
    self.settings_controller.browser_scroll_speed_drag_active = false;
    self.settings_controller.modal_closing = true;
    self.settings_controller.modal_anim_last_ms = 0;
}

/// Advances the settings modal fade toward shown/hidden; called once per
/// rendered frame while the modal is visible.
pub fn tickSettingsModalAnimation(self: anytype) void {
    if (!self.settings_controller.modal_visible) return;
    const now = monotonicMs();
    const last = self.settings_controller.modal_anim_last_ms;
    self.settings_controller.modal_anim_last_ms = now;
    // First tick after open/close starts the clock without jumping.
    if (last == 0 or now <= last) return;
    // Clamp so a stalled frame advances the fade instead of skipping it.
    const elapsed: f32 = @floatFromInt(@min(now - last, 100));
    const duration_ms = theme.motionDurationMs(self.app_config.reduced_motion, theme.MOTION_BASE_MS);
    const step = elapsed / @as(f32, @floatFromInt(duration_ms));
    if (self.settings_controller.modal_closing) {
        self.settings_controller.modal_anim_progress -= step;
        if (self.settings_controller.modal_anim_progress <= 0.0) {
            self.settings_controller.modal_anim_progress = 0.0;
            self.settings_controller.modal_closing = false;
            self.settings_controller.modal_visible = false;
        }
    } else if (self.settings_controller.modal_anim_progress < 1.0) {
        self.settings_controller.modal_anim_progress = @min(self.settings_controller.modal_anim_progress + step, 1.0);
    }
}

/// True while the settings modal fade needs frames pumped.
pub fn settingsModalAnimating(self: anytype) bool {
    return self.settings_controller.modal_visible and (self.settings_controller.modal_closing or self.settings_controller.modal_anim_progress < 1.0);
}

pub fn settingsThemeChoiceCount(self: anytype) usize {
    return self.app_config.installed_themes.len + 2;
}

pub fn settingsThemeChoiceLabel(self: anytype, choice_index: usize) []const u8 {
    if (choice_index == 0) return "Verde";
    if (choice_index == 1) return "Omarchy";
    const installed_index = choice_index - 2;
    if (installed_index >= self.app_config.installed_themes.len) return "Unknown theme";
    return self.app_config.installed_themes[installed_index].name;
}

pub fn selectSettingsThemeChoice(self: anytype, choice_index: usize) void {
    if (choice_index >= self.settingsThemeChoiceCount()) return;
    if (choice_index == self.settings_controller.draft.theme_choice) {
        self.settings_controller.theme_dropdown_open = false;
        self.settings_controller.theme_hover_index = null;
        self.markDirty();
        return;
    }
    self.settings_controller.draft.theme_choice = choice_index;
    if (choice_index == 0) {
        self.settings_controller.draft.theme_source = .default;
    } else if (choice_index == 1) {
        self.settings_controller.draft.theme_source = .omarchy;
    } else {
        const installed = self.app_config.installed_themes[choice_index - 2];
        self.settings_controller.draft.theme_source = installed.theme_config.source;
        if (installed.font_size) |value| self.settings_controller.draft.font_size = value;
        if (installed.terminal_font_size) |value| self.settings_controller.draft.terminal_font_size = value;
    }
    self.settings_controller.theme_dropdown_open = false;
    self.settings_controller.theme_hover_index = null;
    self.markDirty();
}

pub fn settingsChatTitleProviderCount(self: anytype) usize {
    _ = self;
    return CHAT_TITLE_PROVIDER_OPTIONS.len;
}

pub fn settingsChatTitleProviderSelectedIndex(self: anytype) usize {
    for (CHAT_TITLE_PROVIDER_OPTIONS, 0..) |provider, index| {
        if (provider == self.settings_controller.draft.chat_title_provider) return index;
    }
    return 0;
}

pub fn settingsChatTitleProviderLabel(self: anytype, option_index: usize) []const u8 {
    _ = self;
    if (option_index >= CHAT_TITLE_PROVIDER_OPTIONS.len) return "Unknown provider";
    return switch (CHAT_TITLE_PROVIDER_OPTIONS[option_index]) {
        .codex => "Codex / ChatGPT",
        .claude => "Claude",
        .cursor => "Cursor",
        .opencode => "OpenCode",
    };
}

pub fn settingsChatTitleModelCount(self: anytype) usize {
    return settingsChatTitleModelOptions(self).len;
}

pub fn settingsChatTitleModelLabel(self: anytype, option_index: usize) []const u8 {
    const options = settingsChatTitleModelOptions(self);
    if (option_index >= options.len) return "Unknown model";
    if (self.settings_controller.draft.chat_title_provider == .codex) {
        if (options[option_index].value) |value| {
            if (std.mem.eql(u8, value, app_config.DEFAULT_CHAT_TITLE_MODEL)) return "GPT-5.6 Luna (default)";
        }
    }
    return options[option_index].label;
}

pub fn settingsChatTitleModelSelectedIndex(self: anytype) ?usize {
    const selected = self.settingsChatTitleModelRef();
    for (settingsChatTitleModelOptions(self), 0..) |option, index| {
        const value = option.value orelse continue;
        if (std.mem.eql(u8, value, selected)) return index;
    }
    return null;
}

pub fn settingsChatTitleModelSelectedLabel(self: anytype) []const u8 {
    if (self.settingsChatTitleModelSelectedIndex()) |index| return self.settingsChatTitleModelLabel(index);
    return self.settingsChatTitleModelRef();
}

pub fn selectSettingsChatTitleProvider(self: anytype, option_index: usize) void {
    if (option_index >= CHAT_TITLE_PROVIDER_OPTIONS.len) return;
    const provider = CHAT_TITLE_PROVIDER_OPTIONS[option_index];
    if (provider != self.settings_controller.draft.chat_title_provider) {
        const model_ref = defaultChatTitleModelRef(self, provider);
        replaceSettingsChatTitleModel(self, model_ref) catch return;
        self.settings_controller.draft.chat_title_provider = provider;
        switch (provider) {
            .codex => {},
            .claude => self.startClaudeModelOptionsRefresh(),
            .cursor => self.startCursorModelOptionsRefresh(),
            .opencode => self.startOpencodeModelOptionsRefresh(),
        }
    }
    self.settings_controller.title_provider_dropdown_open = false;
    self.settings_controller.title_menu_hover_index = null;
    self.settings_controller.title_model_menu_scroll = 0;
    self.markDirty();
}

pub fn selectSettingsChatTitleModel(self: anytype, option_index: usize) void {
    const options = settingsChatTitleModelOptions(self);
    if (option_index >= options.len) return;
    const model_ref = options[option_index].value orelse return;
    replaceSettingsChatTitleModel(self, model_ref) catch return;
    self.settings_controller.title_model_dropdown_open = false;
    self.settings_controller.title_menu_hover_index = null;
    self.markDirty();
}

pub fn settingsChatTitleModelRef(self: anytype) []const u8 {
    return self.settings_controller.chat_title_model orelse defaultChatTitleModelRef(self, self.settings_controller.draft.chat_title_provider);
}

fn settingsChatTitleModelOptions(self: anytype) []const ModelOption {
    return chat_threads.modelOptions(
        ModelOption,
        dbProviderForChatTitleProvider(self.settings_controller.draft.chat_title_provider),
        self.opencodeModelOptionsSnapshot(),
        provider_models.CODEX_MODEL_OPTIONS[0..],
        self.claudeModelOptionsSnapshot(),
        self.cursorModelOptionsSnapshot(),
        self.piModelOptionsSnapshot(),
        self.fxModelOptionsSnapshot(),
        self.grokModelOptionsSnapshot(),
    );
}

fn defaultChatTitleModelRef(self: anytype, provider: app_config.ChatTitleProvider) []const u8 {
    if (provider == .codex) return app_config.DEFAULT_CHAT_TITLE_MODEL;
    return switch (dbProviderForChatTitleProvider(provider)) {
        // ChatTitleProvider deliberately excludes pi, fx, and grok.
        .codex, .pi, .fx, .grok => unreachable,
        .opencode => self.cachedDefaultModelRefForProvider(.opencode),
        .claude => provider_models.DEFAULT_CLAUDE_MODEL,
        .cursor => provider_models.DEFAULT_CURSOR_MODEL,
    };
}

fn replaceSettingsChatTitleModel(self: anytype, model_ref: []const u8) !void {
    const owned_model = try self.allocator.dupe(u8, model_ref);
    if (self.settings_controller.chat_title_model) |previous| self.allocator.free(previous);
    self.settings_controller.chat_title_model = owned_model;
}

pub fn settingsNewChatProviderCount(self: anytype) usize {
    _ = self;
    return NEW_CHAT_PROVIDER_OPTIONS.len;
}

pub fn settingsNewChatProviderSelectedIndex(self: anytype) usize {
    for (NEW_CHAT_PROVIDER_OPTIONS, 0..) |provider, index| {
        if (provider == self.settings_controller.draft.new_chat_provider) return index;
    }
    return 0;
}

pub fn settingsNewChatProviderLabel(self: anytype, option_index: usize) []const u8 {
    _ = self;
    if (option_index >= NEW_CHAT_PROVIDER_OPTIONS.len) return "Unknown provider";
    return switch (NEW_CHAT_PROVIDER_OPTIONS[option_index]) {
        .codex => "Codex / ChatGPT",
        .claude => "Claude",
        .cursor => "Cursor",
        .opencode => "OpenCode",
        .pi => "Pi",
        .fx => "FX",
        .grok => "Grok",
    };
}

fn settingsNewChatModelOptions(self: anytype) []const ModelOption {
    return chat_threads.modelOptions(
        ModelOption,
        dbProviderForChatProvider(self.settings_controller.draft.new_chat_provider),
        self.opencodeModelOptionsSnapshot(),
        provider_models.CODEX_MODEL_OPTIONS[0..],
        self.claudeModelOptionsSnapshot(),
        self.cursorModelOptionsSnapshot(),
        self.piModelOptionsSnapshot(),
        self.fxModelOptionsSnapshot(),
        self.grokModelOptionsSnapshot(),
    );
}

fn defaultNewChatModelRef(self: anytype, provider: app_config.ChatProvider) []const u8 {
    return switch (dbProviderForChatProvider(provider)) {
        .codex => provider_models.DEFAULT_CODEX_MODEL,
        .opencode => self.cachedDefaultModelRefForProvider(.opencode),
        .claude => provider_models.DEFAULT_CLAUDE_MODEL,
        .cursor => provider_models.DEFAULT_CURSOR_MODEL,
        .pi => provider_models.DEFAULT_PI_MODEL,
        .fx => provider_models.DEFAULT_FX_MODEL,
        .grok => provider_models.DEFAULT_GROK_MODEL,
    };
}

pub fn settingsNewChatModelRef(self: anytype) []const u8 {
    return self.settings_controller.new_chat_model orelse defaultNewChatModelRef(self, self.settings_controller.draft.new_chat_provider);
}

pub fn settingsNewChatModelCount(self: anytype) usize {
    return settingsNewChatModelOptions(self).len;
}

pub fn settingsNewChatModelLabel(self: anytype, option_index: usize) []const u8 {
    const options = settingsNewChatModelOptions(self);
    if (option_index >= options.len) return "Unknown model";
    return options[option_index].label;
}

pub fn settingsNewChatModelSelectedIndex(self: anytype) ?usize {
    const selected = self.settingsNewChatModelRef();
    for (settingsNewChatModelOptions(self), 0..) |option, index| {
        const value = option.value orelse continue;
        if (std.mem.eql(u8, value, selected)) return index;
    }
    return null;
}

pub fn settingsNewChatModelSelectedLabel(self: anytype) []const u8 {
    if (self.settingsNewChatModelSelectedIndex()) |index| return self.settingsNewChatModelLabel(index);
    return self.settingsNewChatModelRef();
}

fn replaceSettingsNewChatModel(self: anytype, model_ref: []const u8) !void {
    const owned_model = try self.allocator.dupe(u8, model_ref);
    if (self.settings_controller.new_chat_model) |previous| self.allocator.free(previous);
    self.settings_controller.new_chat_model = owned_model;
}

fn selectedNewChatModelOption(self: anytype) ?ModelOption {
    const index = self.settingsNewChatModelSelectedIndex() orelse return null;
    const options = settingsNewChatModelOptions(self);
    if (index >= options.len) return null;
    return options[index];
}

fn reasoningValueMatches(value: []const u8, reasoning: app_config.ChatReasoning) bool {
    if (reasoning == .provider_default) return false;
    if (std.mem.eql(u8, value, reasoning.configValue())) return true;
    return reasoning == .xhigh and std.mem.eql(u8, value, "extra-high");
}

fn settingsNewChatReasoningSupported(self: anytype, reasoning: app_config.ChatReasoning) bool {
    if (reasoning == .provider_default) return true;
    const provider = self.settings_controller.draft.new_chat_provider;
    const option = selectedNewChatModelOption(self) orelse return false;
    return switch (provider) {
        .codex => blk: {
            const effort = provider_models.parseReasoningEffort(reasoning.configValue()) orelse break :blk false;
            for (provider_models.codexReasoningOptions(option.value)) |candidate| {
                if (candidate.value != null and candidate.value.? == effort) break :blk true;
            }
            break :blk false;
        },
        .claude => blk: {
            if (!option.reasoning_supported) break :blk false;
            const values = option.claude_effort_values orelse provider_models.CLAUDE_STANDARD_EFFORT_VALUES[0..];
            for (values) |value| if (reasoningValueMatches(value, reasoning)) break :blk true;
            break :blk false;
        },
        .cursor => blk: {
            const values = option.cursor_reasoning_values orelse break :blk false;
            for (values) |value| if (reasoningValueMatches(value, reasoning)) break :blk true;
            break :blk false;
        },
        // Pi accepts every Verde effort tag as a thinking level.
        .pi => provider_models.parseReasoningEffort(reasoning.configValue()) != null,
        // fx exposes no reasoning-effort control.
        .fx => false,
        // grok accepts Verde effort tags up to xhigh (no max tier).
        .grok => reasoning.configValue().len > 0 and provider_models.parseReasoningEffort(reasoning.configValue()) != null and provider_models.parseReasoningEffort(reasoning.configValue()) != .max,
        .opencode => blk: {
            if (!option.reasoning_supported) break :blk false;
            const values = option.reasoning_variant_keys orelse break :blk false;
            for (values) |value| if (reasoningValueMatches(value, reasoning)) break :blk true;
            break :blk false;
        },
    };
}

fn settingsNewChatReasoningOptionAt(self: anytype, option_index: usize) ?app_config.ChatReasoning {
    var visible_index: usize = 0;
    for (NEW_CHAT_REASONING_OPTIONS) |reasoning| {
        if (!settingsNewChatReasoningSupported(self, reasoning)) continue;
        if (visible_index == option_index) return reasoning;
        visible_index += 1;
    }
    return null;
}

pub fn settingsNewChatReasoningCount(self: anytype) usize {
    var count: usize = 0;
    for (NEW_CHAT_REASONING_OPTIONS) |reasoning| if (settingsNewChatReasoningSupported(self, reasoning)) {
        count += 1;
    };
    return count;
}

pub fn settingsNewChatReasoningLabel(self: anytype, option_index: usize) []const u8 {
    const reasoning = settingsNewChatReasoningOptionAt(self, option_index) orelse return "Unknown";
    return switch (reasoning) {
        .provider_default => "Default",
        .low => "Low",
        .medium => "Medium",
        .high => "High",
        .xhigh => "Xhigh",
        .max => "Max",
    };
}

pub fn settingsNewChatReasoningSelectedIndex(self: anytype) usize {
    const selected = self.settings_controller.draft.new_chat_reasoning;
    var visible_index: usize = 0;
    for (NEW_CHAT_REASONING_OPTIONS) |reasoning| {
        if (!settingsNewChatReasoningSupported(self, reasoning)) continue;
        if (reasoning == selected) return visible_index;
        visible_index += 1;
    }
    return 0;
}

pub fn settingsNewChatReasoningSelectedLabel(self: anytype) []const u8 {
    return self.settingsNewChatReasoningLabel(self.settingsNewChatReasoningSelectedIndex());
}

pub fn selectSettingsNewChatProvider(self: anytype, option_index: usize) void {
    if (option_index >= NEW_CHAT_PROVIDER_OPTIONS.len) return;
    const provider = NEW_CHAT_PROVIDER_OPTIONS[option_index];
    if (provider != self.settings_controller.draft.new_chat_provider) {
        replaceSettingsNewChatModel(self, defaultNewChatModelRef(self, provider)) catch return;
        self.settings_controller.draft.new_chat_provider = provider;
        self.settings_controller.draft.new_chat_reasoning = .provider_default;
        switch (provider) {
            .codex => {},
            .pi => self.startPiModelOptionsRefresh(),
            .fx => self.startFxModelOptionsRefresh(),
            .grok => self.startGrokModelOptionsRefresh(),
            .claude => self.startClaudeModelOptionsRefresh(),
            .cursor => self.startCursorModelOptionsRefresh(),
            .opencode => self.startOpencodeModelOptionsRefresh(),
        }
    }
    self.settings_controller.new_chat_provider_dropdown_open = false;
    self.settings_controller.new_chat_menu_hover_index = null;
    self.settings_controller.new_chat_model_menu_scroll = 0;
    self.markDirty();
}

pub fn selectSettingsNewChatModel(self: anytype, option_index: usize) void {
    const options = settingsNewChatModelOptions(self);
    if (option_index >= options.len) return;
    const model_ref = options[option_index].value orelse return;
    replaceSettingsNewChatModel(self, model_ref) catch return;
    if (!settingsNewChatReasoningSupported(self, self.settings_controller.draft.new_chat_reasoning)) {
        self.settings_controller.draft.new_chat_reasoning = .provider_default;
    }
    self.settings_controller.new_chat_model_dropdown_open = false;
    self.settings_controller.new_chat_menu_hover_index = null;
    self.markDirty();
}

pub fn selectSettingsNewChatReasoning(self: anytype, option_index: usize) void {
    const reasoning = settingsNewChatReasoningOptionAt(self, option_index) orelse return;
    self.settings_controller.draft.new_chat_reasoning = reasoning;
    self.settings_controller.new_chat_reasoning_dropdown_open = false;
    self.settings_controller.new_chat_menu_hover_index = null;
    self.markDirty();
}

pub fn startUpdateCheck(self: anytype) void {
    self.settings_controller.update.start();
    self.markDirty();
}

pub fn startAutomaticUpdateCheck(self: anytype) void {
    if (self.app_config.check_for_updates_automatically) self.startUpdateCheck();
}

pub fn pollUpdateCheck(self: anytype) void {
    const previous = self.settings_controller.update.status;
    self.settings_controller.update.poll();
    if (self.settings_controller.update.status != previous) self.markDirty();
}

pub fn installAvailableUpdate(self: anytype) void {
    if (self.settings_controller.update_installer_started) {
        _ = focusUpdateInstallerTerminal(self);
        return;
    }
    const launch = update_installer.launch(self.allocator) catch |err| {
        log.warn("failed to launch update installer: {s}", .{@errorName(err)});
        const url = self.settings_controller.update.downloadUrl() orelse updater.State.releasesUrl();
        utils.openUrlInDefaultBrowser(self.allocator, url) catch {
            self.setSidebarNotice("Could not start the installer or open the release download.");
            return;
        };
        self.setSidebarNotice("Could not start the installer; opened the release download instead.");
        return;
    };
    if (launch == .aur_helper_missing) {
        self.setSidebarNotice("Verde is AUR-managed, but yay or paru was not found.");
        self.markDirty();
        return;
    }
    if (update_installer.aurCommand(launch) != null) {
        startAurUpdateTerminal(self, launch) catch |err| {
            log.warn("failed to open AUR update terminal: {s}", .{@errorName(err)});
            self.setSidebarNotice("Could not open the AUR updater terminal.");
            self.markDirty();
        };
        return;
    }
    self.settings_controller.update_installer_started = true;
    self.settings_controller.update_exit_requested = launch == .started_and_exit_required;
    self.setSidebarNotice(if (self.settings_controller.update_exit_requested)
        "Restarting to install the Verde update…"
    else
        "Verde update installer started. Restart Verde when it completes.");
    self.markDirty();
}

pub fn updateInstallerButtonEnabled(self: anytype) bool {
    if (self.settings_controller.update.status != .update_available) return false;
    return !self.settings_controller.update_installer_started or self.settings_controller.update_installer_terminal != null;
}

pub fn updateInstallerButtonLabel(self: anytype) []const u8 {
    if (self.settings_controller.update_installer_terminal) |update_terminal| {
        return switch (update_terminal.status) {
            .running => "Updating — view terminal",
            .succeeded => "Installed — restart Verde",
            .failed => "Update failed — view terminal",
        };
    }
    if (self.settings_controller.update_installer_started) return "Installer started";
    if (self.settings_controller.update.status == .update_available) return "Install update";
    return "No update available";
}

fn startAurUpdateTerminal(self: anytype, launch: update_installer.Launch) !void {
    const command = update_installer.aurCommand(launch) orelse return error.InvalidAurLaunch;
    if (self.project_controller.projects.items.len == 0) return error.NoProjectSelected;
    self.ensureCurrentProjectWorkspace();

    const project_index = self.project_controller.selected_index;
    const dock_id = try self.createProjectTerminalDock(project_index);
    errdefer _ = self.project_controller.projects.items[project_index].removeTerminalDockById(self.allocator, dock_id);
    var dock = self.projectTerminalDockMutable(project_index, dock_id) orelse return error.NoProjectSelected;
    const project_path = self.project_controller.projects.items[project_index].path;
    try dock.restartWithProfilePersistent(self.allocator, project_path, .{
        .kind = .custom,
        .label = "Update Verde",
        .command = command,
    }, self.storage.pref_path, dock_id);

    var layout = &self.project_controller.projects.items[project_index].workspace_layout;
    const pane_id = try layout.ensureTerminalPane(self.allocator, dock_id);
    const pane = layout.paneByIdMutable(pane_id) orelse return error.TerminalPaneUnavailable;
    switch (pane.ref) {
        .terminal => |*terminal_ref| terminal_ref.purpose = .editor,
        else => return error.TerminalPaneUnavailable,
    }
    layout.focusCreatedPane(pane_id);
    dock = self.projectTerminalDockMutable(project_index, dock_id) orelse return error.NoProjectSelected;
    dock.visible = false;

    self.settings_controller.update_installer_started = true;
    self.settings_controller.update_installer_terminal = .{
        .project_index = project_index,
        .dock_id = dock_id,
    };
    self.cancelSettingsModal();
    self.requestTerminalDockFocus(dock_id);
    self.setSidebarNotice("AUR updater opened in a terminal. Complete any password prompt there.");
    self.noteTerminalInputActivity();
    self.markDirty();
}

fn focusUpdateInstallerTerminal(self: anytype) bool {
    const update_terminal = self.settings_controller.update_installer_terminal orelse return false;
    if (update_terminal.project_index >= self.project_controller.projects.items.len) return false;
    if (self.projectTerminalDock(update_terminal.project_index, update_terminal.dock_id) == null) return false;
    self.project_controller.selected_index = update_terminal.project_index;
    self.ensureCurrentProjectWorkspace();
    var layout = &self.project_controller.projects.items[update_terminal.project_index].workspace_layout;
    _ = layout.ensureTerminalPane(self.allocator, update_terminal.dock_id) catch return false;
    layout.maximized_pane_id = null;
    self.cancelSettingsModal();
    self.requestTerminalDockFocus(update_terminal.dock_id);
    self.markDirty();
    return true;
}

pub fn pollUpdateInstallerTerminal(self: anytype) bool {
    const update_terminal = self.settings_controller.update_installer_terminal orelse return false;
    if (update_terminal.status != .running) return false;
    const dock = self.projectTerminalDock(update_terminal.project_index, update_terminal.dock_id) orelse {
        self.settings_controller.update_installer_terminal.?.status = .failed;
        self.setSidebarNotice("The AUR updater terminal was closed before it finished.");
        self.markDirty();
        return true;
    };
    const snapshot = dock.activeSessionSnapshot() orelse return false;
    if (snapshot.running) return false;
    if (snapshot.exit_code == null and snapshot.signal == null) return false;
    const succeeded = snapshot.exit_code != null and snapshot.exit_code.? == 0;
    self.settings_controller.update_installer_terminal.?.status = if (succeeded) .succeeded else .failed;
    self.setSidebarNotice(if (succeeded)
        "Verde was updated. Restart Verde to use the new version."
    else
        "The AUR update failed. Review the updater terminal for details.");
    self.markDirty();
    return true;
}

pub fn isUpdateInstallerTerminal(self: anytype, project_index: usize, dock_id: u32) bool {
    const update_terminal = self.settings_controller.update_installer_terminal orelse return false;
    return update_terminal.project_index == project_index and update_terminal.dock_id == dock_id;
}

pub fn consumeUpdateExitRequest(self: anytype) bool {
    if (!self.settings_controller.update_exit_requested) return false;
    self.settings_controller.update_exit_requested = false;
    return true;
}

fn applySettingsDraftOpenAction(self: anytype) !void {
    if (self.settings_controller.draft.open_action == .custom) return;

    const next: app_config.DefaultOpenAction = switch (self.settings_controller.draft.open_action) {
        .folder => .folder,
        .editor => .editor,
        .cursor => .cursor,
        .vscode => .vscode,
        .zed => .zed,
        .custom => unreachable,
    };
    const next_tag = std.meta.activeTag(next);
    if (std.meta.activeTag(self.app_config.default_open_action) == next_tag) return;
    self.app_config.default_open_action.deinit(self.allocator);
    self.app_config.default_open_action = next;
}

fn settingsOpenActionFromConfig(action: app_config.DefaultOpenAction) OpenAction {
    return switch (action) {
        .folder => .folder,
        .editor => .editor,
        .cursor => .cursor,
        .vscode => .vscode,
        .zed => .zed,
        .custom => .custom,
    };
}

test "companion character draft sync dirty and save semantics" {
    var settings: State = .{};
    var config: app_config.AppConfig = .{};
    defer config.deinit(std.testing.allocator);

    try std.testing.expectEqual(app_config.CompanionCharacter.sprout, settings.draft.companion_character);
    try std.testing.expect(!settings.companion_character_dropdown_open);
    try std.testing.expect(settings.companion_character_hover_index == null);

    config.companion_character = .moss;
    syncCompanionCharacterDraft(&settings, &config);
    try std.testing.expectEqual(app_config.CompanionCharacter.moss, settings.draft.companion_character);
    try std.testing.expect(!isCompanionCharacterDraftDirty(&settings, &config));

    settings.draft.companion_character = .vireo;
    try std.testing.expect(isCompanionCharacterDraftDirty(&settings, &config));
    applyCompanionCharacterDraft(&settings, &config);
    try std.testing.expectEqual(app_config.CompanionCharacter.vireo, config.companion_character);
    try std.testing.expect(!isCompanionCharacterDraftDirty(&settings, &config));
}
