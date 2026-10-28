//! First-run dialogs: "Connect an AI provider" (with its inline setup
//! terminal) and "Make Verde work better with your agents" (MCP).
//!
//! One layout pass per dialog feeds the pointer hits, the Tab stops, and the
//! positioned selectable text lines, so clicking, keyboard focus, drawing,
//! highlighting, and copy cannot drift apart. `layout.zig` calls in at its
//! modal hooks; `main.zig` routes pointer input and cursors here first.

const std = @import("std");
const palette = @import("palette");
const runtime = @import("runtime.zig");
const theme = @import("theme.zig");
const text_measure = @import("text_measure.zig");
const context_menu = @import("context_menu.zig");
const terminal_panel = @import("terminal_panel.zig");

const provider_setup = runtime.provider_setup;
const Provider = runtime.Provider;
const Readiness = runtime.ProviderReadiness;
const Snapshot = runtime.ProviderReadinessSnapshot;
const Action = runtime.PaletteModalAction;
const MissingRequirement = @import("../state/provider_controller.zig").MissingRequirement;

pub const QueueHit = *const fn (*runtime.AppState, palette.Rect, Action, usize) void;

/// Provider dialog rows in display order: every provider with an installer
/// and sign-in command (the welcome screen lists the same set).
pub const PROVIDERS = [_]Provider{ .codex, .opencode, .claude, .cursor, .pi, .fx, .grok, .muse };

/// Providers disabled in Settings are hidden from the model picker and new
/// chats, so the dialog leaves their rows out too. Action indices stay
/// `PROVIDERS` indices; only the row position skips hidden providers.
fn rowShown(state: *runtime.AppState, provider: Provider) bool {
    return state.chatProviderEnabled(provider);
}

fn shownRowCount(state: *runtime.AppState) usize {
    var count: usize = 0;
    for (PROVIDERS) |provider| {
        if (rowShown(state, provider)) count += 1;
    }
    return count;
}

/// Visual position of `PROVIDERS[index]` among the shown rows; null when hidden.
fn rowSlot(state: *runtime.AppState, index: usize) ?usize {
    if (index >= PROVIDERS.len or !rowShown(state, PROVIDERS[index])) return null;
    var slot: usize = 0;
    for (PROVIDERS[0..index]) |provider| {
        if (rowShown(state, provider)) slot += 1;
    }
    return slot;
}

// ---- visibility ---------------------------------------------------------

fn providerVisible(state: *const runtime.AppState) bool {
    return state.settings_controller.provider_onboarding_visible;
}

fn mcpVisible(state: *const runtime.AppState) bool {
    return state.settings_controller.mcp_onboarding_visible and !state.settings_controller.provider_onboarding_visible;
}

/// Modals drawn above the onboarding dialogs (see `layout.renderRoot`).
fn coveredByHigherModal(state: *runtime.AppState) bool {
    return state.settings_controller.modal_visible or
        state.workspaceSettingsOpen() or
        state.runtime_connections.wizard_open or
        state.command_controller.open or
        state.folder_browser.open or
        state.custom_agent_form.open or
        state.runtimeCredentialModalOpen() or
        state.runtimeTrustProposal() != null;
}

/// True when an onboarding dialog is the topmost layer, so it owns keys,
/// pointer input, and the cursor.
pub fn onTop(state: *runtime.AppState) bool {
    return (providerVisible(state) or mcpVisible(state)) and !coveredByHigherModal(state);
}

// ---- provider dialog geometry ------------------------------------------

const PAD_UI: f32 = 22.0;
const BUTTON_H_UI: f32 = 36.0;
const BUTTON_GAP_UI: f32 = 10.0;
const CLOSE_W_UI: f32 = 104.0;
const GUIDE_W_UI: f32 = 156.0;
const CHECK_W_UI: f32 = 126.0;
const BACK_W_UI: f32 = 104.0;
const ROW_H_UI: f32 = 82.0;
const ROW_GAP_UI: f32 = 8.0;
const ROW_RADIUS_UI: f32 = 9.0;
const TEXT_INSET_UI: f32 = 34.0;
const COMMAND_SIZE_UI: f32 = 11.5;
const COPY_W_UI: f32 = 60.0;
const ACTION_W_UI: f32 = 92.0;
const ACTION_H_UI: f32 = 30.0;
/// Dialog text face: the prose-bold face v0.1.127 drew this dialog with (the
/// renderer's default for role-less text, as in the rest of the app's
/// modals). The `.ui` role is the Cal Sans display face, whose tight
/// tracking collapses spaces at these small sizes ("CLInot found").
const TEXT_ROLE: palette.FontRole = .prose_bold;
/// Setup view: title line, then up to two status lines, then the terminal.
const SETUP_TERMINAL_TOP_UI: f32 = 62.0;

fn providerRect(width: f32, height: f32) palette.Rect {
    const modal_w = theme.clampf(width * 0.54, theme.scaledUi(540.0), theme.scaledUi(720.0));
    const modal_h = theme.clampf(height * 0.78, theme.scaledUi(500.0), theme.scaledUi(620.0));
    return .{ .x = (width - modal_w) * 0.5, .y = (height - modal_h) * 0.5, .w = modal_w, .h = modal_h };
}

const ProviderLayout = struct {
    modal: palette.Rect,
    /// Visible band for the provider rows; rows scroll inside it.
    list: palette.Rect,
    row_h: f32,
    row_gap: f32,
    max_scroll_y: f32,
    button_y: f32,
    button_h: f32,
};

// Fixed-height rows in a clipped, scrollable band between the intro and the
// buttons, so a short window never draws rows behind them.
/// While the setup terminal shows, the dialog grows to most of the window so
/// the command's output (device codes, QR codes) is readable; it never
/// exceeds the window less a margin.
fn setupRect(width: f32, height: f32) palette.Rect {
    const margin = theme.scaledUi(16.0);
    const max_w = @max(width - margin * 2.0, 0.0);
    const max_h = @max(height - margin * 2.0, 0.0);
    const modal_w = @min(@max(width * 0.85, @min(theme.scaledUi(540.0), max_w)), max_w);
    const modal_h = @min(@max(height * 0.85, @min(theme.scaledUi(500.0), max_h)), max_h);
    return .{ .x = (width - modal_w) * 0.5, .y = (height - modal_h) * 0.5, .w = modal_w, .h = modal_h };
}

/// The provider dialog's layout for its current view (list or setup).
fn providerLayoutFor(state: *runtime.AppState, width: f32, height: f32) ProviderLayout {
    const row_count = shownRowCount(state);
    if (state.settings_controller.provider_setup.visible()) return providerLayoutIn(setupRect(width, height), row_count);
    return providerLayout(width, height, row_count);
}

fn providerLayout(width: f32, height: f32, row_count: usize) ProviderLayout {
    return providerLayoutIn(providerRect(width, height), row_count);
}

fn providerLayoutIn(modal: palette.Rect, row_count: usize) ProviderLayout {
    const pad = theme.scaledUi(PAD_UI);
    const button_h = theme.scaledUi(BUTTON_H_UI);
    const button_y = modal.y + modal.h - pad - button_h;
    const list_top = modal.y + pad + theme.scaledUi(34.0) + theme.scaledUi(52.0);
    const list_bottom = button_y - theme.scaledUi(14.0);
    const row_h = theme.scaledUi(ROW_H_UI);
    const row_gap = theme.scaledUi(ROW_GAP_UI);
    const count: f32 = @floatFromInt(row_count);
    const content_h = @max(row_h * count + row_gap * (count - 1.0), 0.0);
    const list: palette.Rect = .{ .x = modal.x + pad, .y = list_top, .w = modal.w - pad * 2.0, .h = @max(list_bottom - list_top, 0.0) };
    return .{
        .modal = modal,
        .list = list,
        .row_h = row_h,
        .row_gap = row_gap,
        .max_scroll_y = @max(content_h - list.h, 0.0),
        .button_y = button_y,
        .button_h = button_h,
    };
}

fn rowRect(layout: ProviderLayout, slot: usize, scroll_y: f32) palette.Rect {
    const offset = @as(f32, @floatFromInt(slot)) * (layout.row_h + layout.row_gap);
    return .{ .x = layout.list.x, .y = layout.list.y - scroll_y + offset, .w = layout.list.w, .h = layout.row_h };
}

const Footer = struct {
    close: palette.Rect,
    guide: palette.Rect,
    check: palette.Rect,
    /// Setup view only. Right-aligned beside Check again, never where Not
    /// now was, so a double-click on Sign in cannot land on it and the
    /// next one dismiss the dialog.
    back: palette.Rect,
};

fn providerFooter(layout: ProviderLayout) Footer {
    const pad = theme.scaledUi(PAD_UI);
    const gap = theme.scaledUi(BUTTON_GAP_UI);
    const check_w = theme.scaledUi(CHECK_W_UI);
    const check: palette.Rect = .{ .x = layout.modal.x + layout.modal.w - pad - check_w, .y = layout.button_y, .w = check_w, .h = layout.button_h };
    const guide_w = theme.scaledUi(GUIDE_W_UI);
    const back_w = theme.scaledUi(BACK_W_UI);
    return .{
        .close = .{ .x = layout.modal.x + pad, .y = layout.button_y, .w = theme.scaledUi(CLOSE_W_UI), .h = layout.button_h },
        .guide = .{ .x = check.x - gap - guide_w, .y = layout.button_y, .w = guide_w, .h = layout.button_h },
        .check = check,
        .back = .{ .x = check.x - gap - back_w, .y = layout.button_y, .w = back_w, .h = layout.button_h },
    };
}

/// Setup-view footer: the primary sized to its label (it can read "Sign in
/// to Claude Code"), the secondary right beside it.
fn setupFooter(layout: ProviderLayout, primary_label: ?[]const u8) Footer {
    var footer = providerFooter(layout);
    const label = primary_label orelse {
        // No primary: the secondary takes its place at the right edge.
        footer.back.x = footer.check.x + footer.check.w - footer.back.w;
        footer.check.w = 0.0;
        return footer;
    };
    const want_w = text_measure.textWidth(TEXT_ROLE, theme.scaledUi(14.0), label) + theme.scaledUi(32.0);
    const right = footer.check.x + footer.check.w;
    const max_w = @max(right - layout.modal.x - theme.scaledUi(PAD_UI) - footer.back.w - theme.scaledUi(BUTTON_GAP_UI), theme.scaledUi(CHECK_W_UI));
    const check_w = theme.clampf(want_w, theme.scaledUi(CHECK_W_UI), max_w);
    footer.check.x = right - check_w;
    footer.check.w = check_w;
    footer.back.x = footer.check.x - theme.scaledUi(BUTTON_GAP_UI) - footer.back.w;
    return footer;
}

/// Label for the setup view's primary action; null when it has none.
fn setupPrimaryLabel(state: *runtime.AppState, buf: []u8) ?[]const u8 {
    const setup = &state.settings_controller.provider_setup;
    return switch (provider_setup.primaryAction(state)) {
        .none => null,
        .done => "Done",
        .copy_code => "Copy code & open GitHub",
        .sign_in_next => std.fmt.bufPrint(buf, "Sign in to {s}", .{setup.subjectName()}) catch "Sign in",
        .check_again => if (state.settings_controller.provider_recheck_generation != 0 or setup.checking_until_ms != 0) "Checking..." else "Check again",
    };
}

fn setupSecondaryLabel(state: *runtime.AppState) []const u8 {
    return if (provider_setup.primaryAction(state) == .sign_in_next) "Not now" else "Back";
}

fn setupTerminalRect(layout: ProviderLayout) palette.Rect {
    const top = layout.list.y + theme.scaledUi(SETUP_TERMINAL_TOP_UI);
    return .{ .x = layout.list.x, .y = top, .w = layout.list.w, .h = @max(layout.list.y + layout.list.h - top, theme.scaledUi(80.0)) };
}

fn commandPrefixWidth(size: f32) f32 {
    return text_measure.textWidth(.mono, size, "$ ");
}

/// Pill holding a row's setup command; sized to the measured command and
/// capped short of the action button so Copy sits right after the text.
fn commandRect(row: palette.Rect, command: []const u8) palette.Rect {
    const action = actionRect(row);
    const size = theme.scaledUi(COMMAND_SIZE_UI);
    const text_w = commandPrefixWidth(size) + text_measure.textWidth(.mono, size, command);
    const x = row.x + theme.scaledUi(TEXT_INSET_UI);
    const want_w = theme.scaledUi(10.0) + text_w + theme.scaledUi(12.0) + theme.scaledUi(COPY_W_UI) + theme.scaledUi(3.0);
    const max_w = @max(action.x - theme.scaledUi(12.0) - x, theme.scaledUi(80.0));
    return .{ .x = x, .y = row.y + theme.scaledUi(50.0), .w = @min(want_w, max_w), .h = theme.scaledUi(24.0) };
}

/// Copy control inset at the right end of the command pill.
fn copyRect(row: palette.Rect, command: []const u8) palette.Rect {
    const pill = commandRect(row, command);
    const inset = theme.scaledUi(3.0);
    const w = theme.scaledUi(COPY_W_UI);
    return .{ .x = pill.x + pill.w - inset - w, .y = pill.y + inset, .w = w, .h = pill.h - inset * 2.0 };
}

fn actionRect(row: palette.Rect) palette.Rect {
    const w = theme.scaledUi(ACTION_W_UI);
    const h = theme.scaledUi(ACTION_H_UI);
    return .{ .x = row.x + row.w - w - theme.scaledUi(12.0), .y = row.y + (row.h - h) * 0.5, .w = w, .h = h };
}

/// Same verbs as Settings > Providers: a missing CLI installs, an installed
/// but signed-out (or unverifiable) one signs in. A CLI that only lacks a
/// runtime (Node.js) gets a link to that runtime's download page instead.
fn actionLabel(readiness: Readiness, requirement: ?MissingRequirement) ?[]const u8 {
    if (requirement) |missing| return switch (missing) {
        .node => "Get Node.js",
    };
    return switch (readiness) {
        .missing => "Install",
        .signed_out, .unavailable => "Sign in",
        .ready, .checking => null,
    };
}

fn rowCommand(state: *runtime.AppState, provider: Provider, readiness: Readiness, requirement: ?MissingRequirement) ?[]const u8 {
    if (requirement != null or actionLabel(readiness, requirement) == null) return null;
    return provider_setup.commandFor(state, provider, readiness == .missing);
}

/// Codex registers Verde's tools as auto-approved (providers/mcp.zig); the
/// MCP dialog says so when Codex is installed.
fn codexDetected(state: *runtime.AppState) bool {
    const snapshot = state.providerReadinessSnapshot();
    return snapshot.installedForProvider(.codex);
}

const MCP_CODEX_NOTE = "In Codex, Verde's tools are set to auto-approve (no prompt per call).";
/// Extra dialog height for the Codex line.
const MCP_CODEX_NOTE_H_UI: f32 = 20.0;

fn mcpRect(state: *runtime.AppState, width: f32, height: f32) palette.Rect {
    const extra = if (codexDetected(state)) theme.scaledUi(MCP_CODEX_NOTE_H_UI) else 0.0;
    const modal_w = theme.clampf(width * 0.5, theme.scaledUi(520.0), theme.scaledUi(680.0));
    const modal_h = theme.clampf(height * 0.56, theme.scaledUi(400.0), theme.scaledUi(440.0)) + extra;
    return .{ .x = (width - modal_w) * 0.5, .y = (height - modal_h) * 0.5, .w = modal_w, .h = modal_h };
}

const McpFooter = struct { not_now: palette.Rect, enable: palette.Rect };

fn mcpFooter(modal: palette.Rect) McpFooter {
    const pad = theme.scaledUi(PAD_UI);
    const button_h = theme.scaledUi(BUTTON_H_UI);
    const button_y = modal.y + modal.h - pad - button_h;
    const enable_w = theme.scaledUi(176.0);
    return .{
        .not_now = .{ .x = modal.x + pad, .y = button_y, .w = theme.scaledUi(104.0), .h = button_h },
        .enable = .{ .x = modal.x + modal.w - pad - enable_w, .y = button_y, .w = enable_w, .h = button_h },
    };
}

// ---- hits and Tab stops ---------------------------------------------------

/// The dialog box itself, from the last layout pass.
var active_modal: palette.Rect = .{};
var frame_w: f32 = 0.0;
var frame_h: f32 = 0.0;

fn noQueue(_: *runtime.AppState, _: palette.Rect, _: Action, _: usize) void {}

/// Registers pointer hits for whichever onboarding dialog is showing and
/// rebuilds its Tab order from the same pass.
pub fn registerHits(state: *runtime.AppState, width: f32, height: f32, queue_hit: QueueHit) void {
    layoutPass(state, width, height, queue_hit);
}

fn layoutPass(state: *runtime.AppState, width: f32, height: f32, queue_hit: QueueHit) void {
    focus_stop_count = 0;
    frame_w = width;
    frame_h = height;
    if (!state.settings_controller.provider_setup.visible()) terminal_panel.resetStandaloneInput();
    if (providerVisible(state)) {
        registerProviderHits(state, width, height, queue_hit);
    } else if (mcpVisible(state)) {
        registerMcpHits(state, width, height, queue_hit);
    } else {
        resetInput();
        return;
    }
    if (keyboard_focus != null and focusedStopIndex() == null) {
        keyboard_focus = null;
        focus_ring_visible = false;
    }
}

fn registerChromeHits(state: *runtime.AppState, width: f32, height: f32, modal: palette.Rect, dismissible: bool, queue_hit: QueueHit) void {
    queue_hit(state, .{ .x = 0.0, .y = 0.0, .w = width, .h = height }, if (dismissible) .modal_dismiss else .modal_block, 0);
    queue_hit(state, modal, .modal_block, 0);
}

fn registerProviderHits(state: *runtime.AppState, width: f32, height: f32, queue_hit: QueueHit) void {
    const sc = &state.settings_controller;
    const setup = &sc.provider_setup;
    const layout = providerLayoutFor(state, width, height);
    active_modal = layout.modal;
    // Clicking outside closes the dialog, except while a sign-in/install
    // command runs, where a stray click would kill the login midway.
    const running = setup.visible() and setup.status == .running;
    registerChromeHits(state, width, height, layout.modal, !running, queue_hit);
    const footer = providerFooter(layout);
    if (setup.visible()) {
        var label_buf: [96]u8 = undefined;
        const setup_footer = setupFooter(layout, setupPrimaryLabel(state, &label_buf));
        queue_hit(state, setup_footer.back, .provider_setup_back, 0);
        if (setup_footer.check.w > 0.0) queue_hit(state, setup_footer.check, .provider_onboarding_recheck, 0);
        // While the command runs, keys (Tab included) belong to it.
        if (!running) {
            recordStop(.provider_setup_back, 0, setup_footer.back, null);
            if (setup_footer.check.w > 0.0) recordStop(.provider_onboarding_recheck, 0, setup_footer.check, null);
        }
        return;
    }
    scrollToHighlight(state, layout);
    const scroll_y = theme.clampf(sc.provider_onboarding_scroll_y, 0.0, layout.max_scroll_y);
    sc.provider_onboarding_scroll_y = scroll_y;
    sc.provider_onboarding_max_scroll_y = layout.max_scroll_y;
    const snapshot = provider_setup.readinessSnapshot(state);
    queue_hit(state, footer.close, .provider_onboarding_close, 0);
    for (PROVIDERS, 0..) |provider, index| {
        const slot = rowSlot(state, index) orelse continue;
        const row = rowRect(layout, slot, scroll_y);
        const readiness = snapshot.forProvider(provider);
        const requirement = snapshot.requirementForProvider(provider);
        // Hits are clipped to the list band so a half-hidden control can't
        // be clicked through the intro or the footer; Tab stops keep the
        // full rect so focus can scroll them into view.
        if (rowCommand(state, provider, readiness, requirement)) |command| {
            const copy = copyRect(row, command);
            const visible = rectIntersection(copy, layout.list);
            if (visible.h > 0.0) queue_hit(state, visible, .provider_onboarding_copy, index);
            recordStop(.provider_onboarding_copy, index, copy, layout.list);
        }
        if (actionLabel(readiness, requirement) != null) {
            const action = actionRect(row);
            const visible = rectIntersection(action, layout.list);
            if (visible.h > 0.0) queue_hit(state, visible, .provider_onboarding_action, index);
            recordStop(.provider_onboarding_action, index, action, layout.list);
        }
    }
    queue_hit(state, footer.check, .provider_onboarding_recheck, 0);
    queue_hit(state, footer.guide, .provider_onboarding_open_guide, 0);
    recordStop(.provider_onboarding_close, 0, footer.close, null);
    recordStop(.provider_onboarding_open_guide, 0, footer.guide, null);
    recordStop(.provider_onboarding_recheck, 0, footer.check, null);
}

fn registerMcpHits(state: *runtime.AppState, width: f32, height: f32, queue_hit: QueueHit) void {
    const modal = mcpRect(state, width, height);
    active_modal = modal;
    registerChromeHits(state, width, height, modal, false, queue_hit);
    const footer = mcpFooter(modal);
    queue_hit(state, footer.not_now, .mcp_onboarding_not_now, 0);
    queue_hit(state, footer.enable, .mcp_onboarding_enable, 0);
    recordStop(.mcp_onboarding_not_now, 0, footer.not_now, null);
    recordStop(.mcp_onboarding_enable, 0, footer.enable, null);
}

/// One-shot scroll that brings the highlighted row (a model picked from an
/// unconnected provider, or a Settings action) into view, and moves focus
/// to its Install / Sign in without showing the ring.
fn scrollToHighlight(state: *runtime.AppState, layout: ProviderLayout) void {
    const sc = &state.settings_controller;
    if (!sc.provider_onboarding_scroll_to_highlight) return;
    sc.provider_onboarding_scroll_to_highlight = false;
    const provider = sc.provider_onboarding_highlight orelse return;
    const index = std.mem.indexOfScalar(Provider, &PROVIDERS, provider) orelse return;
    const slot = rowSlot(state, index) orelse return;
    const top = @as(f32, @floatFromInt(slot)) * (layout.row_h + layout.row_gap);
    sc.provider_onboarding_scroll_y = theme.clampf(top - (layout.list.h - layout.row_h) * 0.5, 0.0, layout.max_scroll_y);
    keyboard_focus = .{ .action = .provider_onboarding_action, .index = index };
    focus_ring_visible = false;
}

/// Actions the onboarding dialogs register; `layout.zig` routes their
/// clicks to `clickHit`.
pub fn ownsAction(action: Action) bool {
    return switch (action) {
        .mcp_onboarding_not_now,
        .mcp_onboarding_enable,
        .provider_onboarding_close,
        .provider_onboarding_recheck,
        .provider_onboarding_open_guide,
        .provider_onboarding_action,
        .provider_onboarding_copy,
        .provider_setup_back,
        => true,
        else => false,
    };
}

/// A click on one of this dialog's controls: focus moves there without the
/// ring, then the control runs.
pub fn clickHit(state: *runtime.AppState, action: Action, index: usize) void {
    focus_ring_visible = false;
    if (stopIndexFor(action, index) != null) keyboard_focus = .{ .action = action, .index = index };
    closeTextMenu();
    activate(state, action, index);
}

fn activate(state: *runtime.AppState, action: Action, index: usize) void {
    switch (action) {
        .mcp_onboarding_not_now => state.completeMcpOnboarding(false),
        .mcp_onboarding_enable => state.completeMcpOnboarding(true),
        .provider_onboarding_close => state.dismissProviderOnboarding(),
        .provider_onboarding_recheck => if (!state.settings_controller.provider_setup.visible()) state.recheckProviderReadiness() else switch (provider_setup.primaryAction(state)) {
            .none => {},
            .done => provider_setup.finishFlow(state),
            .sign_in_next => provider_setup.signInNext(state),
            .copy_code => provider_setup.copyCodeAndOpenGithub(state),
            .check_again => {
                provider_setup.refreshGithubProbe(state);
                state.recheckProviderReadiness();
            },
        },
        .provider_onboarding_open_guide => state.openProviderSetupGuide(),
        .provider_onboarding_action => if (index < PROVIDERS.len) {
            const provider = PROVIDERS[index];
            if (provider_setup.readinessSnapshot(state).requirementForProvider(provider) != null) {
                state.openNodeDownloadPage();
            } else {
                state.runProviderOnboardingAction(provider);
            }
        },
        .provider_onboarding_copy => if (index < PROVIDERS.len) provider_setup.copyCommand(state, PROVIDERS[index]),
        .provider_setup_back => provider_setup.back(state),
        else => {},
    }
    state.markDirty();
}

// ---- keyboard focus ---------------------------------------------------------
//
// Same model as the settings modal: stops are rebuilt by every layout pass in
// visual order (row Copy and Install / Sign in, then the footer), tracked by
// identity, and the ring shows only after keyboard input.

const FocusStop = struct {
    action: Action,
    index: usize,
    /// Unclipped, so focus can scroll a row into view.
    rect: palette.Rect,
    /// The scrolling list band for row controls; null for the footer.
    clip: ?palette.Rect,
};

const FocusRef = struct { action: Action, index: usize };

const MAX_FOCUS_STOPS: usize = PROVIDERS.len * 2 + 4;

var focus_stops: [MAX_FOCUS_STOPS]FocusStop = undefined;
var focus_stop_count: usize = 0;
var keyboard_focus: ?FocusRef = null;
var focus_ring_visible: bool = false;

fn recordStop(action: Action, index: usize, rect: palette.Rect, clip: ?palette.Rect) void {
    if (focus_stop_count >= MAX_FOCUS_STOPS) return;
    focus_stops[focus_stop_count] = .{ .action = action, .index = index, .rect = rect, .clip = clip };
    focus_stop_count += 1;
}

fn stopIndexFor(action: Action, index: usize) ?usize {
    for (focus_stops[0..focus_stop_count], 0..) |stop, i| {
        if (stop.action == action and stop.index == index) return i;
    }
    return null;
}

fn focusedStopIndex() ?usize {
    const focus = keyboard_focus orelse return null;
    return stopIndexFor(focus.action, focus.index);
}

fn setFocus(state: *runtime.AppState, stop_index: usize) void {
    const stop = focus_stops[stop_index];
    keyboard_focus = .{ .action = stop.action, .index = stop.index };
    focus_ring_visible = true;
    if (stop.clip) |clip| {
        // Scroll just enough to reveal the control plus a small margin.
        const sc = &state.settings_controller;
        const margin = theme.scaledUi(12.0);
        if (stop.rect.y < clip.y) {
            sc.provider_onboarding_scroll_y = @max(0.0, sc.provider_onboarding_scroll_y - (clip.y - stop.rect.y + margin));
        } else if (stop.rect.y + stop.rect.h > clip.y + clip.h) {
            sc.provider_onboarding_scroll_y = @min(sc.provider_onboarding_max_scroll_y, sc.provider_onboarding_scroll_y + stop.rect.y + stop.rect.h - (clip.y + clip.h) + margin);
        }
    }
    state.markDirty();
}

/// Tab / Shift+Tab, wrapping at either end.
fn moveFocus(state: *runtime.AppState, forward: bool) void {
    const n = focus_stop_count;
    if (n == 0) return;
    const current = focusedStopIndex() orelse {
        setFocus(state, if (forward) 0 else n - 1);
        return;
    };
    setFocus(state, if (forward) (current + 1) % n else (current + n - 1) % n);
}

/// Up/Down move between provider rows, keeping the same control (Copy or
/// Install / Sign in) when the next row has it.
fn moveFocusRow(state: *runtime.AppState, current: usize, forward: bool) void {
    const row = focus_stops[current].index;
    var i = current;
    var target_row: ?usize = null;
    var fallback: ?usize = null;
    while (if (forward) i + 1 < focus_stop_count else i > 0) {
        i = if (forward) i + 1 else i - 1;
        const stop = focus_stops[i];
        if (stop.clip == null) break;
        if (stop.index == row) continue;
        if (target_row == null) target_row = stop.index;
        if (stop.index != target_row.?) break;
        if (fallback == null or !forward) fallback = i;
        if (stop.action == focus_stops[current].action) {
            setFocus(state, i);
            return;
        }
    }
    if (fallback) |index| setFocus(state, index);
}

fn handleFocusKeyDown(state: *runtime.AppState, event: *const palette.event.KeyEvent) bool {
    const current = focusedStopIndex();
    switch (event.key) {
        .@"return", .kp_enter, .space => {
            if (current) |index| {
                focus_ring_visible = true;
                const stop = focus_stops[index];
                activate(state, stop.action, stop.index);
                return true;
            }
            if (event.key == .space) return false;
            // Nothing focused: Enter checks again / enables, as before.
            if (providerVisible(state)) state.recheckProviderReadiness() else state.completeMcpOnboarding(true);
            return true;
        },
        .up, .down => {
            const index = current orelse return false;
            if (focus_stops[index].clip == null) return false;
            moveFocusRow(state, index, event.key == .down);
            return true;
        },
        .left, .right => {
            const index = current orelse return false;
            const next = if (event.key == .right) index + 1 else index -% 1;
            if (next < focus_stop_count) setFocus(state, next);
            return true;
        },
        else => return false,
    }
}

// Arrow/Page/Home/End/Space scroll the provider list when no row control
// has focus, bounded by the max scroll from the last layout pass.
fn handleScrollKeyDown(state: *runtime.AppState, event: *const palette.event.KeyEvent) bool {
    const step = theme.scaledUi(48.0);
    const page = theme.scaledUi(240.0);
    const sc = &state.settings_controller;
    const delta: f32 = switch (event.key) {
        .down => step,
        .up => -step,
        .pagedown, .space => page,
        .pageup => -page,
        .end => sc.provider_onboarding_max_scroll_y,
        .home => -sc.provider_onboarding_scroll_y,
        else => return false,
    };
    sc.provider_onboarding_scroll_y = theme.clampf(sc.provider_onboarding_scroll_y + delta, 0.0, sc.provider_onboarding_max_scroll_y);
    state.markDirty();
    return true;
}

/// Keys for the topmost onboarding dialog. While a setup command runs its
/// terminal gets them (Escape and Tab included; sign-in TUIs use both).
/// Otherwise every key is consumed so nothing types into the obscured
/// composer or terminal.
pub fn handleKeyDown(state: *runtime.AppState, event: *const palette.event.KeyEvent) bool {
    if (!onTop(state)) return false;
    const setup = &state.settings_controller.provider_setup;
    const primary = event.mod.primary();
    // Dialog text selection outranks the terminal: Ctrl+C must copy it, not
    // interrupt the sign-in.
    if (primary and event.key == .c and selectionRange() != null) {
        copySelection(state);
        return true;
    }
    if (providerVisible(state) and setup.visible() and setup.status == .running) {
        return provider_setup.handleKeyDown(state, state.command_controller.keyboard_config, event);
    }
    if (primary) {
        if (event.key == .a and text_surface_clicked) selectAllText(state);
        return true;
    }
    switch (event.key) {
        .escape => {
            if (text_menu != null) {
                closeTextMenu();
            } else if (selectionRange() != null) {
                clearTextSelection();
            } else if (providerVisible(state) and setup.visible()) {
                provider_setup.back(state);
            } else if (providerVisible(state)) {
                state.dismissProviderOnboarding();
            } else {
                state.completeMcpOnboarding(false);
            }
            state.markDirty();
            return true;
        },
        .tab => {
            closeTextMenu();
            moveFocus(state, !event.mod.shift);
            return true;
        },
        else => {},
    }
    if (handleFocusKeyDown(state, event)) return true;
    if (providerVisible(state) and !setup.visible()) _ = handleScrollKeyDown(state, event);
    return true;
}

/// Text typed while a dialog is on top: the running setup command gets it;
/// otherwise it is swallowed.
pub fn handleTextInput(state: *runtime.AppState, text: []const u8) bool {
    if (!onTop(state)) return false;
    if (providerVisible(state) and state.settings_controller.provider_setup.visible()) {
        return provider_setup.handleTextInput(state, text);
    }
    return true;
}

// Focus ring: accent outline offset outside the focused control, clipped to
// the list band for row controls.
fn drawFocusRing(state: *runtime.AppState) void {
    if (!focus_ring_visible) return;
    const index = focusedStopIndex() orelse return;
    const stop = focus_stops[index];
    const ring_w = crispStroke(2.0);
    const gap = ring_w;
    const ring = snapRect(.{ .x = stop.rect.x - gap, .y = stop.rect.y - gap, .w = stop.rect.w + gap * 2.0, .h = stop.rect.h + gap * 2.0 });
    // An accent ring around an accent-filled button reads as part of its
    // fill; those get a white ring instead.
    const color = paletteColor(if (stopIsAccentFilled(state, stop)) theme.COLOR_WHITE else theme.accent());
    const radius = theme.scaledUi(7.0) + gap;
    if (stop.clip) |clip| {
        state.palette_overlay_batch.rectBorderClipped(state.allocator, ring, color, radius, ring_w, clip) catch {};
    } else {
        state.palette_overlay_batch.rectBorder(state.allocator, ring, color, radius, ring_w) catch {};
    }
}

/// True for the buttons `drawButton` fills with the accent: the primary footer
/// actions and a row's Sign in (an Install button is muted).
fn stopIsAccentFilled(state: *runtime.AppState, stop: FocusStop) bool {
    return switch (stop.action) {
        .provider_onboarding_recheck, .mcp_onboarding_enable => true,
        .provider_onboarding_action => stop.index < PROVIDERS.len and actionAccented(provider_setup.readinessSnapshot(state), PROVIDERS[stop.index]),
        else => false,
    };
}

// ---- selectable text ------------------------------------------------------
//
// Descriptions, row notes, commands, and setup status are content: drag,
// double-click word, triple-click block, Ctrl+C, Ctrl+A, right-click Copy /
// Select all, Escape to clear. Every drawn line is recorded with its
// position so hit-testing, highlight, and copy read the same layout.

const TextBlock = enum(u8) {
    intro = 1,
    setup_title,
    setup_status,
    row_step,
    row_command,
    mcp_description,
    mcp_benefit_title,
    mcp_benefit_detail,
    mcp_note,
};

fn blockId(kind: TextBlock, index: usize) u32 {
    return (@as(u32, @intFromEnum(kind)) << 8) | @as(u32, @intCast(index & 0xff));
}

const MAX_TEXT_LINES: usize = 48;
const MAX_LINE_BYTES: usize = 224;
const MAX_WRAP_LINES: usize = 3;

const TextLine = struct {
    /// `block << 8 | line number`; stable across frames.
    id: u32,
    block: u32,
    x: f32,
    y: f32,
    h: f32,
    font: f32,
    role: palette.FontRole,
    clip: palette.Rect,
    len: usize,
    bytes: [MAX_LINE_BYTES]u8,

    fn text(self: *const TextLine) []const u8 {
        return self.bytes[0..self.len];
    }

    /// Where glyphs are actually drawn (the I-beam region), clipped.
    fn box(self: *const TextLine) palette.Rect {
        const w = text_measure.textWidth(self.role, self.font, self.text());
        return rectIntersection(.{ .x = self.x, .y = self.y, .w = w + self.font * 0.35, .h = self.h }, self.clip);
    }
};

const TextPoint = struct { id: u32, offset: usize };

const TextRange = struct { start_line: usize, start: usize, end_line: usize, end: usize };

var text_lines: [MAX_TEXT_LINES]TextLine = undefined;
var text_line_count: usize = 0;
var sel_anchor: ?TextPoint = null;
var sel_focus: ?TextPoint = null;
var sel_dragging: bool = false;
/// Ctrl+A selects all only after the dialog body was clicked.
var text_surface_clicked: bool = false;
/// Right-click Copy / Select all menu origin.
var text_menu: ?palette.draw.Vec2 = null;
/// List band of the last provider list draw, for drag auto-scroll.
var last_list_rect: ?palette.Rect = null;

fn resetInput() void {
    clearTextSelection();
    text_surface_clicked = false;
    text_menu = null;
    keyboard_focus = null;
    focus_ring_visible = false;
}

fn clearTextSelection() void {
    sel_anchor = null;
    sel_focus = null;
    sel_dragging = false;
}

fn closeTextMenu() void {
    text_menu = null;
}

fn lineIndexFor(id: u32) ?usize {
    for (text_lines[0..text_line_count], 0..) |*line, index| {
        if (line.id == id) return index;
    }
    return null;
}

fn selectionRange() ?TextRange {
    const anchor = sel_anchor orelse return null;
    const focus = sel_focus orelse return null;
    const a = lineIndexFor(anchor.id) orelse return null;
    const f = lineIndexFor(focus.id) orelse return null;
    const a_off = @min(anchor.offset, text_lines[a].len);
    const f_off = @min(focus.offset, text_lines[f].len);
    if (a == f and a_off == f_off) return null;
    if (a < f or (a == f and a_off < f_off)) return .{ .start_line = a, .start = a_off, .end_line = f, .end = f_off };
    return .{ .start_line = f, .start = f_off, .end_line = a, .end = a_off };
}

/// Greedy word wrap into at most `max_lines` sub-slices of `value`; a line
/// keeps its trailing space so joined lines reproduce the source. The last
/// line takes the remainder (clipped when drawn, whole when copied).
fn wrapLines(value: []const u8, max_w: f32, font: f32, role: palette.FontRole, max_lines: usize, out: *[MAX_WRAP_LINES][]const u8) usize {
    var count: usize = 0;
    var start: usize = 0;
    const limit = @min(max_lines, MAX_WRAP_LINES);
    while (start < value.len and count < limit) {
        const rest = value[start..];
        if (count + 1 == limit or text_measure.textWidth(role, font, rest) <= max_w) {
            out[count] = rest;
            count += 1;
            break;
        }
        var end: usize = 0;
        for (rest, 0..) |byte, index| {
            if (byte != ' ') continue;
            if (text_measure.textPrefixWidth(role, rest, font, index) > max_w) break;
            end = index + 1;
        }
        if (end == 0) {
            out[count] = rest;
            count += 1;
            break;
        }
        out[count] = rest[0..end];
        count += 1;
        start += end;
    }
    return count;
}

/// Draws `value` as selectable text starting at `rect`'s top-left, wrapped
/// to `rect.w` over at most `max_lines` lines. Returns the height used.
fn drawSelectable(
    state: *runtime.AppState,
    kind: TextBlock,
    index: usize,
    rect: palette.Rect,
    value: []const u8,
    color: [4]f32,
    font: f32,
    role: palette.FontRole,
    clip: palette.Rect,
    max_lines: usize,
) f32 {
    const line_h = font * 1.25;
    var lines: [MAX_WRAP_LINES][]const u8 = undefined;
    const count = wrapLines(value, @max(rect.w, 1.0), font, role, max_lines, &lines);
    const block = blockId(kind, index);
    const line_clip = rectIntersection(.{ .x = rect.x, .y = rect.y, .w = rect.w, .h = line_h * @as(f32, @floatFromInt(@max(count, 1))) }, clip);
    for (lines[0..count], 0..) |line, n| {
        const y = rect.y + @as(f32, @floatFromInt(n)) * line_h;
        // An overflowing last line is cut at a glyph boundary and ends in an
        // ellipsis instead of a mid-glyph clip. The record keeps the whole
        // line, so copy and select-all still yield the full text, while its
        // clip limits hit-testing and highlight to the visible part.
        var visible_clip = line_clip;
        if (n + 1 == count and text_measure.textWidth(role, font, line) > rect.w) {
            const ellipsis_w = text_measure.textWidth(role, font, ELLIPSIS);
            const keep_w = text_measure.textPrefixWidth(role, line, font, fittingPrefixLen(line, rect.w - ellipsis_w, font, role));
            visible_clip = rectIntersection(.{ .x = rect.x, .y = y, .w = keep_w, .h = line_h }, line_clip);
            queueRoleText(state, .{ .x = rect.x + keep_w, .y = y, .w = ellipsis_w + font * 0.35, .h = line_h }, ELLIPSIS, color, font, role, line_clip);
        }
        queueRoleText(state, .{ .x = rect.x, .y = y, .w = rect.w, .h = line_h }, line, color, font, role, visible_clip);
        if (text_line_count >= MAX_TEXT_LINES) continue;
        const entry = &text_lines[text_line_count];
        entry.* = .{
            .id = (block << 8) | @as(u32, @intCast(n)),
            .block = block,
            .x = rect.x,
            .y = y,
            .h = line_h,
            .font = font,
            .role = role,
            .clip = visible_clip,
            .len = @min(line.len, MAX_LINE_BYTES),
            .bytes = undefined,
        };
        @memcpy(entry.bytes[0..entry.len], line[0..entry.len]);
        text_line_count += 1;
    }
    return line_h * @as(f32, @floatFromInt(count));
}

const ELLIPSIS = "…";

/// Longest UTF-8-boundary prefix of `value` whose measured width fits `max_w`.
fn fittingPrefixLen(value: []const u8, max_w: f32, font: f32, role: palette.FontRole) usize {
    var fit: usize = 0;
    var index: usize = 0;
    while (index < value.len) {
        const step = std.unicode.utf8ByteSequenceLength(value[index]) catch 1;
        index = @min(index + step, value.len);
        if (text_measure.textPrefixWidth(role, value, font, index) > max_w) break;
        fit = index;
    }
    return fit;
}

/// Byte offset in `line` nearest to x, snapped to a UTF-8 boundary.
fn lineByteAtX(line: *const TextLine, x: f32) usize {
    const value = line.text();
    if (x <= line.x) return 0;
    var previous_boundary: usize = 0;
    var previous_w: f32 = 0.0;
    var index: usize = 0;
    while (index < value.len) {
        const step = std.unicode.utf8ByteSequenceLength(value[index]) catch 1;
        index = @min(index + step, value.len);
        const w = text_measure.textPrefixWidth(line.role, value, line.font, index);
        if (line.x + (previous_w + w) * 0.5 >= x) return previous_boundary;
        previous_boundary = index;
        previous_w = w;
    }
    return value.len;
}

fn textLineAt(x: f32, y: f32) ?usize {
    for (text_lines[0..text_line_count], 0..) |*line, index| {
        if (pointInRect(x, y, line.box())) return index;
    }
    return null;
}

/// Caret under the pointer, clamped to the nearest visible line while
/// dragging past text edges.
fn textPointNear(x: f32, y: f32) ?TextPoint {
    var best: ?usize = null;
    var best_distance: f32 = std.math.inf(f32);
    for (text_lines[0..text_line_count], 0..) |*line, index| {
        if (line.clip.h <= 0.0 or line.clip.w <= 0.0) continue;
        const top = @max(line.y, line.clip.y);
        const bottom = @min(line.y + line.h, line.clip.y + line.clip.h);
        const distance = if (y < top) top - y else if (y >= bottom) y - bottom else 0.0;
        if (distance < best_distance) {
            best_distance = distance;
            best = index;
        }
    }
    const index = best orelse return null;
    const line = &text_lines[index];
    const top = @max(line.y, line.clip.y);
    const bottom = @min(line.y + line.h, line.clip.y + line.clip.h);
    // Above the first line of a stack selects from its start; below the
    // last selects to its end, like a text editor.
    const offset = if (y < top and best_distance > 0.0 and isFirstLineAbove(index, y))
        0
    else if (y >= bottom and best_distance > 0.0 and isLastLineBelow(index, y))
        line.len
    else
        lineByteAtX(line, x);
    return .{ .id = line.id, .offset = offset };
}

fn isFirstLineAbove(index: usize, y: f32) bool {
    for (text_lines[0..text_line_count], 0..) |*line, other| {
        if (other != index and line.y < text_lines[index].y and line.y + line.h > y) return false;
    }
    return true;
}

fn isLastLineBelow(index: usize, y: f32) bool {
    for (text_lines[0..text_line_count], 0..) |*line, other| {
        if (other != index and line.y > text_lines[index].y and line.y < y) return false;
    }
    return true;
}

fn isWordByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '-' or byte >= 0x80;
}

fn beginTextSelection(line_index: usize, x: f32, clicks: u8) void {
    const line = &text_lines[line_index];
    const offset = lineByteAtX(line, x);
    if (clicks >= 3) {
        // Whole block: every line of this paragraph, row note, or command.
        var first = line_index;
        while (first > 0 and text_lines[first - 1].block == line.block) first -= 1;
        var last = line_index;
        while (last + 1 < text_line_count and text_lines[last + 1].block == line.block) last += 1;
        sel_anchor = .{ .id = text_lines[first].id, .offset = 0 };
        sel_focus = .{ .id = text_lines[last].id, .offset = text_lines[last].len };
        sel_dragging = false;
    } else if (clicks == 2) {
        const value = line.text();
        var start = @min(offset, value.len);
        var end = start;
        while (start > 0 and isWordByte(value[start - 1])) start -= 1;
        while (end < value.len and isWordByte(value[end])) end += 1;
        sel_anchor = .{ .id = line.id, .offset = start };
        sel_focus = .{ .id = line.id, .offset = end };
        sel_dragging = false;
    } else {
        sel_anchor = .{ .id = line.id, .offset = offset };
        sel_focus = sel_anchor;
        sel_dragging = true;
    }
}

fn selectAllText(state: *runtime.AppState) void {
    if (text_line_count == 0) return;
    const last = &text_lines[text_line_count - 1];
    sel_anchor = .{ .id = text_lines[0].id, .offset = 0 };
    sel_focus = .{ .id = last.id, .offset = last.len };
    sel_dragging = false;
    state.markDirty();
}

/// Selected text: lines of one block join as drawn (wrapping kept their
/// spaces); separate blocks join with a newline.
fn selectedTextAlloc(allocator: std.mem.Allocator) !?[]u8 {
    const range = selectionRange() orelse return null;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var index = range.start_line;
    while (index <= range.end_line) : (index += 1) {
        const line = &text_lines[index];
        const from = if (index == range.start_line) range.start else 0;
        const to = if (index == range.end_line) range.end else line.len;
        if (index > range.start_line and line.block != text_lines[index - 1].block) try out.append(allocator, '\n');
        if (to > from) try out.appendSlice(allocator, line.text()[from..to]);
    }
    if (out.items.len == 0) {
        out.deinit(allocator);
        return null;
    }
    return try out.toOwnedSlice(allocator);
}

fn copySelection(state: *runtime.AppState) void {
    const text = (selectedTextAlloc(state.allocator) catch {
        state.setSidebarNotice("Failed to copy selection.");
        return;
    }) orelse return;
    defer state.allocator.free(text);
    state.setSidebarNotice(if (state.setClipboardText(text)) "Copied selection." else "Failed to copy selection.");
    state.markDirty();
}

// Selection highlight: one rect per selected span, clipped to its line.
fn drawTextSelection(state: *runtime.AppState) void {
    const range = selectionRange() orelse return;
    const fill = paletteColor(theme.withAlpha(theme.selection(), 90));
    var index = range.start_line;
    while (index <= range.end_line) : (index += 1) {
        const line = &text_lines[index];
        const from = if (index == range.start_line) range.start else 0;
        const to = if (index == range.end_line) range.end else line.len;
        const x0 = line.x + text_measure.textPrefixWidth(line.role, line.text(), line.font, from);
        var x1 = line.x + text_measure.textPrefixWidth(line.role, line.text(), line.font, to);
        // A selection running on past this line also covers its line break.
        if (index < range.end_line) x1 += line.font * 0.35;
        if (x1 <= x0) continue;
        state.palette_overlay_batch.roundedRectClipped(state.allocator, .{ .x = x0, .y = line.y, .w = x1 - x0, .h = line.h }, fill, theme.scaledUi(2.0), line.clip) catch {};
    }
}

const TEXT_MENU_ROWS = [_][]const u8{ "Copy", "Select all" };

const TextMenuLayout = struct { menu: palette.Rect, rows: [TEXT_MENU_ROWS.len]palette.Rect };

fn textMenuLayout(origin: palette.draw.Vec2) TextMenuLayout {
    const pad = theme.scaledUi(context_menu.PAD_UI);
    const row_h = theme.scaledUi(context_menu.ROW_HEIGHT_UI);
    const w = theme.scaledUi(150.0);
    const h = pad * 2.0 + row_h * @as(f32, @floatFromInt(TEXT_MENU_ROWS.len));
    const x = theme.clampf(origin.x, 0.0, @max(frame_w - w, 0.0));
    const y = theme.clampf(origin.y, 0.0, @max(frame_h - h, 0.0));
    var layout: TextMenuLayout = .{ .menu = .{ .x = x, .y = y, .w = w, .h = h }, .rows = undefined };
    for (&layout.rows, 0..) |*row, index| row.* = .{ .x = x + pad, .y = y + pad + row_h * @as(f32, @floatFromInt(index)), .w = w - pad * 2.0, .h = row_h };
    return layout;
}

fn drawTextMenu(state: *runtime.AppState) void {
    const origin = text_menu orelse return;
    const layout = textMenuLayout(origin);
    const panel = context_menu.queuePanel(state, layout.menu);
    const has_selection = selectionRange() != null;
    const mx = state.transcript_controller.palette_mouse_x;
    const my = state.transcript_controller.palette_mouse_y;
    for (TEXT_MENU_ROWS, layout.rows, 0..) |label, rect, index| {
        const enabled = index != 0 or has_selection;
        const hovered = enabled and pointInRect(mx, my, rect);
        if (hovered) context_menu.queueRowHighlight(state, rect);
        context_menu.queueLabel(state, rect, label, context_menu.labelColor(enabled, hovered), 0.0, 0.0, panel);
    }
}

// ---- pointer routing --------------------------------------------------------

/// True when (x, y) is on one of this dialog's controls (buttons, Copy).
fn controlAt(state: *const runtime.AppState, x: f32, y: f32) bool {
    for (state.palette_modal_hits.items) |hit| {
        if (ownsAction(hit.action) and pointInRect(x, y, hit.rect)) return true;
    }
    return false;
}

/// Pointer buttons for the topmost onboarding dialog, ahead of the shared
/// modal hit routing: the text menu, the setup terminal, and text selection.
/// Returns false to let the shared routing handle the controls and scrim.
pub fn handleMouseButton(state: *runtime.AppState, x: f32, y: f32, button: u8, down: bool, clicks: u8) bool {
    if (!onTop(state)) return false;
    if (text_menu) |origin| {
        if (!down) return true;
        const layout = textMenuLayout(origin);
        text_menu = null;
        if (button == 1 and pointInRect(x, y, layout.menu)) {
            if (pointInRect(x, y, layout.rows[0])) {
                copySelection(state);
            } else if (pointInRect(x, y, layout.rows[1])) {
                selectAllText(state);
            }
        }
        state.markDirty();
        return true;
    }
    const setup = &state.settings_controller.provider_setup;
    if (providerVisible(state) and setup.visible() and terminal_panel.handleStandaloneMouseButton(state, x, y, button, down)) {
        if (down) clearTextSelection();
        state.markDirty();
        return true;
    }
    switch (button) {
        1 => {
            if (!down) {
                if (!sel_dragging) return false;
                sel_dragging = false;
                if (textPointNear(x, y)) |point| sel_focus = point;
                state.markDirty();
                return true;
            }
            if (controlAt(state, x, y)) return false;
            if (pointInRect(x, y, active_modal)) text_surface_clicked = true;
            if (textLineAt(x, y)) |index| {
                beginTextSelection(index, x, clicks);
                state.markDirty();
                return true;
            }
            if (sel_anchor != null) {
                clearTextSelection();
                state.markDirty();
            }
            return false;
        },
        3 => {
            if (!pointInRect(x, y, active_modal)) return false;
            if (down) {
                text_surface_clicked = true;
                text_menu = .{ .x = x, .y = y };
                state.markDirty();
            }
            return true;
        },
        else => return false,
    }
}

/// Pointer motion: selection drag (auto-scrolling the provider list past its
/// edges) and the setup terminal (mouse-aware TUIs, its own drag select).
pub fn handleMouseMotion(state: *runtime.AppState, x: f32, y: f32, buttons: palette.event.ButtonState) bool {
    if (!onTop(state)) return false;
    if (sel_dragging) {
        if (!buttons.left) {
            sel_dragging = false;
            return false;
        }
        const sc = &state.settings_controller;
        if (last_list_rect) |list| {
            const step = theme.scaledUi(18.0);
            if (y < list.y) {
                sc.provider_onboarding_scroll_y = @max(sc.provider_onboarding_scroll_y - step, 0.0);
            } else if (y > list.y + list.h) {
                sc.provider_onboarding_scroll_y = @min(sc.provider_onboarding_scroll_y + step, sc.provider_onboarding_max_scroll_y);
            }
        }
        if (textPointNear(x, y)) |point| sel_focus = point;
        state.markDirty();
        return true;
    }
    if (providerVisible(state) and state.settings_controller.provider_setup.visible() and terminal_panel.handleStandaloneMouseMotion(state, x, y, buttons)) {
        state.markDirty();
        return true;
    }
    return false;
}

/// Wheel: the setup terminal's scrollback under the pointer, else the
/// provider list. The dialog swallows the wheel everywhere.
pub fn handleWheel(state: *runtime.AppState, width: f32, height: f32, x: f32, y: f32, wheel_y: f32) bool {
    if (!providerVisible(state) or coveredByHigherModal(state)) return false;
    closeTextMenu();
    if (state.settings_controller.provider_setup.visible()) {
        if (terminal_panel.handleStandaloneWheel(state, x, y, wheel_y)) state.markDirty();
        return true;
    }
    const layout = providerLayoutFor(state, width, height);
    state.settings_controller.provider_onboarding_scroll_y = theme.clampf(
        state.settings_controller.provider_onboarding_scroll_y - wheel_y * theme.scaledUi(48.0),
        0.0,
        layout.max_scroll_y,
    );
    state.markDirty();
    return true;
}

/// OS cursor over the topmost onboarding dialog; null when none is on top.
pub fn systemCursorAt(state: *runtime.AppState, x: f32, y: f32) ?palette.platform.CursorShape {
    if (!onTop(state)) return null;
    if (sel_dragging) return .text;
    if (text_menu) |origin| {
        const layout = textMenuLayout(origin);
        if (pointInRect(x, y, layout.menu)) return if (pointInRect(x, y, layout.rows[0]) and selectionRange() == null) .default else .pointer;
    }
    if (providerVisible(state) and state.settings_controller.provider_setup.visible()) {
        if (terminal_panel.standaloneCursorAt(state, x, y)) |cursor| return cursor;
    }
    if (controlAt(state, x, y)) return .pointer;
    if (textLineAt(x, y) != null) return .text;
    return .default;
}

// ---- rendering --------------------------------------------------------------

/// Draws whichever onboarding dialog is showing. Hits and Tab stops are
/// rebuilt from the same layout first, so the focus ring matches this frame
/// even after a key moved the list.
pub fn render(state: *runtime.AppState, width: f32, height: f32) void {
    text_line_count = 0;
    last_list_rect = null;
    if (!providerVisible(state) and !mcpVisible(state)) return;
    layoutPass(state, width, height, noQueue);
    if (providerVisible(state)) renderProvider(state, width, height) else renderMcp(state, width, height);
    drawTextSelection(state);
    drawFocusRing(state);
    drawTextMenu(state);
}

// Renders the provider checklist (or its setup terminal view).
fn renderProvider(state: *runtime.AppState, width: f32, height: f32) void {
    const sc = &state.settings_controller;
    const layout = providerLayoutFor(state, width, height);
    const modal = layout.modal;
    drawChrome(state, width, height, modal);
    const pad = theme.scaledUi(PAD_UI);
    const content_w = modal.w - pad * 2.0;
    var y = modal.y + pad;

    // A remote target says where the rows and commands apply.
    const runtime_label = provider_setup.targetLabel(state);
    const tool = if (sc.provider_setup.visible()) sc.provider_setup.tool else null;
    var heading_buf: [160]u8 = undefined;
    const heading = if (tool) |value|
        std.fmt.bufPrint(&heading_buf, "Connect {s} on {s}", .{ value.displayName(), runtime_label orelse "the runtime" }) catch "Connect a tool on the runtime"
    else if (runtime_label) |label| std.fmt.bufPrint(&heading_buf, "Connect an AI provider on {s}", .{label}) catch "Connect an AI provider on the runtime" else "Connect an AI provider";
    queueRoleText(state, .{ .x = modal.x + pad, .y = y, .w = content_w, .h = theme.scaledUi(28.0) }, heading, theme.COLOR_WHITE, theme.scaledUi(22.0), TEXT_ROLE, modal);
    y += theme.scaledUi(34.0);
    const intro_size = theme.scaledUi(13.5);
    var intro_buf: [200]u8 = undefined;
    const intro = if (runtime_label) |label| std.fmt.bufPrint(&intro_buf, "These checks and commands run on {s}, not this computer.", .{label}) catch "These checks and commands run on the remote runtime." else "Verde uses coding-agent accounts already installed on this computer.";
    _ = drawSelectable(state, .intro, 0, .{ .x = modal.x + pad, .y = y, .w = content_w, .h = 0.0 }, intro, theme.COLOR_TEXT_SUBTLE, intro_size, TEXT_ROLE, modal, 1);
    const intro_second: []const u8 = if (tool != null)
        "Agents on this runtime use the GitHub CLI (gh) and git to push branches and open pull requests."
    else
        "Set up any one provider to start chatting. No Verde subscription needed.";
    _ = drawSelectable(state, .intro, 1, .{ .x = modal.x + pad, .y = y + theme.scaledUi(20.0), .w = content_w, .h = 0.0 }, intro_second, theme.COLOR_TEXT_SUBTLE, intro_size, TEXT_ROLE, modal, 1);

    const snapshot = provider_setup.readinessSnapshot(state);
    const footer = providerFooter(layout);
    const checking = sc.provider_recheck_generation != 0 or sc.provider_setup.checking_until_ms != 0 or allChecking(state, snapshot);
    const check_label: []const u8 = if (checking) "Checking..." else "Check again";
    if (sc.provider_setup.visible()) {
        renderSetup(state, layout);
        // After an install the primary continues to sign-in; after success
        // it is Done (a confirmed sign-in also returns on its own shortly).
        var label_buf: [96]u8 = undefined;
        const primary_label = setupPrimaryLabel(state, &label_buf);
        const setup_footer = setupFooter(layout, primary_label);
        drawButton(state, setup_footer.back, setupSecondaryLabel(state), theme.COLOR_PANEL_ALT, null);
        if (primary_label) |label| drawButton(state, setup_footer.check, label, theme.accent(), null);
        return;
    }
    const scroll_y = theme.clampf(sc.provider_onboarding_scroll_y, 0.0, layout.max_scroll_y);
    last_list_rect = layout.list;
    for (PROVIDERS, 0..) |provider, index| {
        const slot = rowSlot(state, index) orelse continue;
        const row = rowRect(layout, slot, scroll_y);
        if (row.y + row.h <= layout.list.y or row.y >= layout.list.y + layout.list.h) continue;
        renderRow(state, row, index, provider, snapshot, layout.list);
    }
    if (layout.max_scroll_y > 0.0) renderScrollbar(state, layout, scroll_y);

    drawButton(state, footer.close, "Not now", theme.COLOR_PANEL_ALT, null);
    drawButton(state, footer.guide, "Open setup guide", theme.COLOR_PANEL_MUTED, null);
    drawButton(state, footer.check, check_label, theme.accent(), null);
}

fn allChecking(state: *runtime.AppState, snapshot: Snapshot) bool {
    for (PROVIDERS) |provider| {
        if (!rowShown(state, provider)) continue;
        if (snapshot.forProvider(provider) != .checking) return false;
    }
    return true;
}

// Inline sign-in / install terminal shown in place of the provider list.
fn renderSetup(state: *runtime.AppState, layout: ProviderLayout) void {
    const setup = &state.settings_controller.provider_setup;
    const dock = setup.dock orelse return;
    const name = setup.subjectName();
    // A tool's readiness is its own probe on the target runtime.
    const readiness = provider_setup.subjectReadiness(state);
    var title_buf: [96]u8 = undefined;
    const verb: []const u8 = switch (setup.mode) {
        .install => "install",
        .sign_in => "sign-in",
        .update => "update",
    };
    var title_buf_wide: [192]u8 = undefined;
    const title = if (provider_setup.targetLabel(state)) |label|
        std.fmt.bufPrint(&title_buf_wide, "{s} {s} on {s}", .{ name, verb, label }) catch name
    else
        std.fmt.bufPrint(&title_buf, "{s} {s}", .{ name, verb }) catch name;
    var status_buf: [240]u8 = undefined;
    const updating = setup.mode == .update and setup.status == .running;
    const status: []const u8, const status_color = if (readiness == .ready and !updating)
        .{ std.fmt.bufPrint(&status_buf, "{s} is ready.", .{name}) catch "Ready.", theme.success() }
    else switch (setup.status) {
        .running => if (setup.tool != null and setup.mode == .sign_in) blk: {
            // The code is the one thing the user must carry to GitHub, so it
            // leads the header rather than hiding in the terminal.
            const code = setup.deviceCode() orelse break :blk .{ "Starting GitHub sign-in. Your one-time code appears here in a moment.", theme.COLOR_TEXT_MUTED };
            break :blk .{ std.fmt.bufPrint(&status_buf, "Your one-time code: {s}  ·  Copy code & open GitHub, paste it at github.com/login/device, and approve. This finishes on its own.", .{code}) catch code, theme.COLOR_WHITE };
        } else .{ "Follow the steps in the terminal. Click a link to open it, or drag to select and copy it.", theme.COLOR_TEXT_MUTED },
        .succeeded, .failed => blk: {
            const row_note = setup.currentNote();
            if (setup.status == .succeeded and setup.mode == .install and row_note == .installed_sign_in_next) {
                const installed = if (setup.tool) |tool| tool.installedName() else name;
                break :blk .{ std.fmt.bufPrint(&status_buf, "{s} installed. Sign in to {s} to finish setting it up.", .{ installed, name }) catch "Installed. Sign in next.", theme.success() };
            }
            if (row_note == .signed_in_unverified) if (provider_setup.targetLabel(state)) |label| {
                break :blk .{ std.fmt.bufPrint(&status_buf, "Signed in on {s}. This runtime version can't confirm accounts, so Verde trusts the sign-in.", .{label}) catch "Signed in.", theme.success() };
            };
            const text = noteText(row_note, true) orelse "Finished.";
            break :blk .{ text, noteColor(row_note) };
        },
        .idle => .{ "", theme.COLOR_TEXT_MUTED },
    };
    const header_y = layout.list.y;
    _ = drawSelectable(state, .setup_title, 0, .{ .x = layout.list.x, .y = header_y, .w = layout.list.w, .h = 0.0 }, title, theme.COLOR_WHITE, theme.scaledUi(14.5), TEXT_ROLE, layout.modal, 1);
    _ = drawSelectable(state, .setup_status, 0, .{ .x = layout.list.x, .y = header_y + theme.scaledUi(22.0), .w = layout.list.w, .h = 0.0 }, status, status_color, theme.scaledUi(12.5), TEXT_ROLE, layout.modal, 2);
    const term_rect = setupTerminalRect(layout);
    // Fit the font so a QR code and the lines after it fit; the panel then
    // resizes the session (and the remote PTY) to the new grid. The slack
    // covers the panel's edge padding.
    if (dock.fitFontToArea(term_rect.w - theme.scaledUi(24.0), term_rect.h - theme.scaledUi(8.0), provider_setup.SETUP_TERMINAL_MIN_COLS, provider_setup.SETUP_TERMINAL_MIN_ROWS, state.app_config.terminal_font_size)) state.markDirty();
    terminal_panel.renderStandaloneDock(state, term_rect, dock);
    const stroke = crispStroke(1.0);
    state.palette_overlay_batch.rectBorder(state.allocator, snapRect(term_rect), paletteColor(if (setup.status == .running) theme.accent() else theme.COLOR_PANEL_MUTED), theme.scaledUi(8.0), stroke) catch {};
}

/// Row-note text: `long` for the setup view header, short for a row.
fn noteText(row_note: provider_setup.RowNote, long: bool) ?[]const u8 {
    return switch (row_note) {
        .none => null,
        .install_finished, .sign_in_finished => "Finished. Checking your account…",
        .failed => if (long) "The command did not finish. Go back to try again, or copy the command and run it yourself." else "That did not finish. Try again, or run it yourself.",
        .copied => "Copied. Run it in any terminal; this row updates itself.",
        .installed_sign_in_next => if (long) "Installed. Go back and choose Sign in next." else "Installed. Sign in next.",
        .still_signed_out => if (long) "Still not signed in. Go back and try Sign in again, or run the command yourself." else "Still not signed in. Try Sign in again.",
        .not_on_path => if (long) "Installed, but not found on PATH. Open a new shell or restart Verde, or see the setup guide." else "Not on PATH yet. Open a new shell or see the guide.",
        // Same guidance as a row found needing Node.js on launch.
        .needs_node => provider_setup.NEEDS_NODE_GUIDANCE,
        .unverified => if (long) "Finished, but sign-in could not be confirmed. Check again, or try Sign in again." else "Sign-in could not be confirmed. Check again.",
        .signed_in_unverified => if (long) "Signed in. This runtime version can't confirm accounts, so Verde trusts the sign-in." else "Signed in this session. The runtime can't confirm accounts.",
    };
}

fn noteWarns(row_note: provider_setup.RowNote) bool {
    return switch (row_note) {
        .failed, .still_signed_out, .not_on_path, .needs_node, .unverified => true,
        else => false,
    };
}

fn noteColor(row_note: provider_setup.RowNote) [4]f32 {
    if (row_note == .signed_in_unverified) return theme.success();
    return if (noteWarns(row_note)) theme.COLOR_YELLOW else theme.COLOR_TEXT_MUTED;
}

/// Status words shared with the welcome screen; Settings uses its own.
fn statusText(readiness: Readiness, requirement: ?MissingRequirement) []const u8 {
    if (requirement) |missing| return switch (missing) {
        .node => provider_setup.NEEDS_NODE_STATUS,
    };
    return switch (readiness) {
        .checking => "Checking...",
        .missing => "CLI not found",
        .signed_out => "Sign-in needed",
        .ready => "Ready",
        .unavailable => "Could not verify",
    };
}

fn readinessStep(readiness: Readiness, requirement: ?MissingRequirement) []const u8 {
    if (requirement) |missing| return switch (missing) {
        .node => provider_setup.NEEDS_NODE_GUIDANCE,
    };
    return switch (readiness) {
        .ready => "Installed and signed in. Pick it from the model menu in any chat.",
        .checking => "Checking the local CLI and account session...",
        .missing => "Not installed. Install runs the official installer below.",
        .signed_out => "Installed, not signed in. Sign in opens the login right here.",
        .unavailable => "Installed, but sign-in could not be confirmed. Sign in to fix it.",
    };
}

// One provider row: status, next step, and its command. Everything is
// clipped to the scrolling list band, so a partly scrolled row keeps its
// card and only loses the part outside the band.
fn renderRow(state: *runtime.AppState, rect: palette.Rect, index: usize, provider: Provider, snapshot: Snapshot, clip: palette.Rect) void {
    const readiness = snapshot.forProvider(provider);
    const requirement = snapshot.requirementForProvider(provider);
    const highlighted = state.settings_controller.provider_onboarding_highlight == provider;
    const stroke = crispStroke(1.0);
    const border = if (highlighted) theme.accent() else theme.withAlpha(theme.COLOR_PANEL_MUTED, 190);
    state.palette_overlay_batch.panelClipped(state.allocator, snapRect(rect), paletteColor(theme.sink(theme.COLOR_PANEL_ALT, 0.025)), paletteColor(border), theme.scaledUi(ROW_RADIUS_UI), stroke, clip) catch {};

    // A runtime that cannot verify accounts is not a warning: installed
    // rows read neutral, and a sign-in that exited 0 here reads signed in.
    const remote_state = provider_setup.remoteRowState(state, provider);
    const status_color = if (requirement != null) theme.COLOR_YELLOW else switch (remote_state) {
        .signed_in_this_session => theme.success(),
        .unverified => theme.COLOR_TEXT_MUTED,
        .none => switch (readiness) {
            .ready => theme.success(),
            .signed_out, .unavailable => theme.COLOR_YELLOW,
            .missing => theme.COLOR_DIFF_REMOVE,
            .checking => theme.COLOR_TEXT_MUTED,
        },
    };
    const row_note = state.settings_controller.provider_setup.note(provider);
    // Ready and checking rows say so; otherwise the latest setup outcome
    // (resolved from the post-command check) replaces the generic step.
    const shown_note: provider_setup.RowNote = if (readiness == .ready or readiness == .checking) .none else row_note;
    var remote_step_buf: [200]u8 = undefined;
    const remote_step: ?[]const u8 = switch (remote_state) {
        .none => null,
        .unverified => std.fmt.bufPrint(&remote_step_buf, "Installed on {s}, which can't report sign-in. Sign in runs the login there.", .{provider_setup.targetLabel(state) orelse "the runtime"}) catch "Installed. This runtime can't report sign-in.",
        .signed_in_this_session => std.fmt.bufPrint(&remote_step_buf, "Signed in on {s} this session. The runtime can't confirm accounts.", .{provider_setup.targetLabel(state) orelse "the runtime"}) catch "Signed in this session.",
    };
    const step = noteText(shown_note, false) orelse remote_step orelse readinessStep(readiness, requirement);
    const step_color = if (noteWarns(shown_note)) theme.COLOR_YELLOW else if (shown_note == .signed_in_unverified) theme.success() else theme.COLOR_TEXT_SUBTLE;
    const command = rowCommand(state, provider, readiness, requirement);
    // Rows without a command line give the step two lines (the Node.js
    // guidance needs them) and center the text block vertically.
    const step_lines: usize = if (command != null) 1 else 2;
    const step_size = theme.scaledUi(12.0);
    const text_h = theme.scaledUi(21.0) + step_size * 1.25 * @as(f32, @floatFromInt(step_lines));
    const top = if (command != null) theme.scaledUi(10.0) else (rect.h - text_h) * 0.5;

    const dot = theme.scaledUi(8.0);
    const dot_rect: palette.Rect = .{ .x = rect.x + theme.scaledUi(14.0), .y = rect.y + top + (theme.scaledUi(20.0) - dot) * 0.5, .w = dot, .h = dot };
    state.palette_overlay_batch.roundedRectClipped(state.allocator, dot_rect, paletteColor(status_color), dot * 0.5, clip) catch {};

    const text_x = rect.x + theme.scaledUi(TEXT_INSET_UI);
    const label = actionLabel(readiness, requirement);
    const action_rect = actionRect(rect);
    // Text stops short of the action button when one shows.
    const right_edge = if (label != null) action_rect.x - theme.scaledUi(12.0) else rect.x + rect.w - theme.scaledUi(12.0);
    const text_clip = rectIntersection(.{ .x = text_x, .y = rect.y, .w = @max(right_edge - text_x, 0.0), .h = rect.h }, clip);
    // Status sits right after the title so every row reads "Name · status".
    const title = provider_setup.displayName(provider);
    const title_size = theme.scaledUi(14.5);
    const title_w = text_measure.textWidth(TEXT_ROLE, title_size, title);
    queueRoleText(state, .{ .x = text_x, .y = rect.y + top, .w = title_w + theme.scaledUi(2.0), .h = title_size * 1.25 }, title, theme.COLOR_WHITE, title_size, TEXT_ROLE, text_clip);
    const status = switch (remote_state) {
        .none => statusText(readiness, requirement),
        .unverified => "Installed",
        .signed_in_this_session => "Signed in",
    };
    const status_size = theme.scaledUi(12.0);
    const status_x = text_x + title_w + theme.scaledUi(10.0);
    queueRoleText(state, .{ .x = status_x, .y = rect.y + top + theme.scaledUi(1.5), .w = @max(right_edge - status_x, 0.0), .h = status_size * 1.25 }, status, status_color, status_size, TEXT_ROLE, text_clip);
    _ = drawSelectable(state, .row_step, index, .{ .x = text_x, .y = rect.y + top + theme.scaledUi(21.0), .w = @max(right_edge - text_x, 0.0), .h = 0.0 }, step, step_color, step_size, TEXT_ROLE, clip, step_lines);

    // The exact command in a pill with an inline Copy control, so it can be
    // run anywhere.
    if (command) |cmd| {
        const pill = commandRect(rect, cmd);
        const copy_rect = copyRect(rect, cmd);
        state.palette_overlay_batch.panelClipped(state.allocator, snapRect(pill), paletteColor(theme.sink(theme.COLOR_PANEL_ALT, 0.06)), paletteColor(theme.withAlpha(theme.COLOR_PANEL_MUTED, 160)), theme.scaledUi(6.0), stroke, clip) catch {};
        const size = theme.scaledUi(COMMAND_SIZE_UI);
        const line_h = size * 1.25;
        const text_rect: palette.Rect = .{ .x = pill.x + theme.scaledUi(10.0), .y = pill.y + (pill.h - line_h) * 0.5, .w = @max(copy_rect.x - theme.scaledUi(8.0) - pill.x - theme.scaledUi(10.0), 0.0), .h = line_h };
        const command_clip = rectIntersection(text_rect, clip);
        queueRoleText(state, text_rect, "$ ", theme.COLOR_TEXT_SUBTLE, size, .mono, command_clip);
        const prefix_w = commandPrefixWidth(size);
        _ = drawSelectable(state, .row_command, index, .{ .x = text_rect.x + prefix_w, .y = text_rect.y, .w = @max(text_rect.w - prefix_w, 0.0), .h = 0.0 }, cmd, theme.COLOR_TEXT_MUTED, size, .mono, command_clip, 1);

        const hovered = pointInRect(state.transcript_controller.palette_mouse_x, state.transcript_controller.palette_mouse_y, rectIntersection(copy_rect, clip));
        // The copied row's control turns accent so it's obvious which
        // command is on the clipboard.
        const copied = row_note == .copied;
        const fill = if (copied) theme.withAlpha(theme.accent(), 60) else theme.raise(theme.COLOR_PANEL_ALT, if (hovered) 0.12 else 0.05);
        const copy_border = if (copied) theme.accent() else theme.COLOR_PANEL_MUTED;
        state.palette_overlay_batch.panelClipped(state.allocator, snapRect(copy_rect), paletteColor(fill), paletteColor(copy_border), theme.scaledUi(4.0), stroke, clip) catch {};
        const copy_label: []const u8 = if (copied) "✓ Copied" else "Copy";
        const copy_w = text_measure.textWidth(TEXT_ROLE, size, copy_label);
        const copy_color = if (copied) theme.accent() else if (hovered) theme.COLOR_WHITE else theme.COLOR_TEXT_MUTED;
        queueRoleText(state, .{ .x = copy_rect.x + (copy_rect.w - copy_w) * 0.5, .y = copy_rect.y + (copy_rect.h - line_h) * 0.5, .w = copy_w + theme.scaledUi(2.0), .h = line_h }, copy_label, copy_color, size, TEXT_ROLE, rectIntersection(copy_rect, clip));
    }
    if (label) |text| drawButton(state, action_rect, text, if (actionAccented(snapshot, provider)) theme.accent() else theme.COLOR_PANEL_MUTED, clip);
}

/// Sign in and Get Node.js are a row's next step (accent fill); Install is muted.
fn actionAccented(snapshot: Snapshot, provider: Provider) bool {
    return snapshot.forProvider(provider) != .missing or snapshot.requirementForProvider(provider) != null;
}

// Thin thumb on the list's right edge so it reads as scrollable.
fn renderScrollbar(state: *runtime.AppState, layout: ProviderLayout, scroll_y: f32) void {
    const track_h = layout.list.h;
    const content_h = track_h + layout.max_scroll_y;
    const thumb_h = @max(track_h * track_h / content_h, theme.scaledUi(24.0));
    const thumb_y = layout.list.y + (track_h - thumb_h) * (scroll_y / layout.max_scroll_y);
    const w = theme.scaledUi(4.0);
    state.palette_overlay_batch.roundedRect(state.allocator, .{ .x = layout.list.x + layout.list.w + theme.scaledUi(7.0), .y = thumb_y, .w = w, .h = thumb_h }, paletteColor(theme.withAlpha(theme.COLOR_TEXT_SUBTLE, 120)), w * 0.5) catch {};
}

// Renders the MCP opt-in: what Verde's tools add, and the choice.
fn renderMcp(state: *runtime.AppState, width: f32, height: f32) void {
    const modal = mcpRect(state, width, height);
    drawChrome(state, width, height, modal);
    const pad = theme.scaledUi(PAD_UI);
    const content_w = modal.w - pad * 2.0;
    var y = modal.y + pad;

    queueRoleText(state, .{ .x = modal.x + pad, .y = y, .w = content_w, .h = theme.scaledUi(28.0) }, "Make Verde work better with your agents", theme.COLOR_WHITE, theme.scaledUi(22.0), TEXT_ROLE, modal);
    y += theme.scaledUi(36.0);
    _ = drawSelectable(state, .mcp_description, 0, .{ .x = modal.x + pad, .y = y, .w = content_w, .h = 0.0 }, "Enable Verde's MCP tools for agents you start in terminal panes or use through Verde.", theme.COLOR_TEXT_SUBTLE, theme.scaledUi(13.5), TEXT_ROLE, modal, 2);
    y += theme.scaledUi(54.0);

    const benefits = [_][2][]const u8{
        .{ "Test apps", "Inspect and interact with Verde's embedded browser." },
        .{ "Work with processes", "Start configured services and read their logs." },
        .{ "Understand the workspace", "Use the current Verde workspace and its panes automatically." },
    };
    const benefit_h = theme.scaledUi(52.0);
    const benefit_gap = theme.scaledUi(7.0);
    for (benefits, 0..) |benefit, index| {
        renderBenefitRow(state, .{ .x = modal.x + pad, .y = y, .w = content_w, .h = benefit_h }, index, benefit[0], benefit[1], modal);
        y += benefit_h + benefit_gap;
    }
    y += theme.scaledUi(16.0) - benefit_gap;
    y += drawSelectable(state, .mcp_note, 0, .{ .x = modal.x + pad, .y = y, .w = content_w, .h = 0.0 }, "Updates detected providers' user settings and preserves existing servers. Remove it any time in Settings.", theme.COLOR_TEXT_SUBTLE, theme.scaledUi(12.0), TEXT_ROLE, modal, 2);
    if (codexDetected(state)) {
        _ = drawSelectable(state, .mcp_note, 1, .{ .x = modal.x + pad, .y = y + theme.scaledUi(4.0), .w = content_w, .h = 0.0 }, MCP_CODEX_NOTE, theme.COLOR_TEXT_SUBTLE, theme.scaledUi(12.0), TEXT_ROLE, modal, 1);
    }

    const footer = mcpFooter(modal);
    drawButton(state, footer.not_now, "Not now", theme.COLOR_PANEL_ALT, null);
    drawButton(state, footer.enable, "Enable Verde tools", theme.accent(), null);
}

// One capability included with Verde's MCP server: a plain bulleted line
// pair, no card, so it reads as information rather than a control.
fn renderBenefitRow(state: *runtime.AppState, rect: palette.Rect, index: usize, title: []const u8, detail: []const u8, clip: palette.Rect) void {
    const dot = theme.scaledUi(6.0);
    const title_size = theme.scaledUi(13.5);
    const dot_rect: palette.Rect = .{ .x = rect.x + theme.scaledUi(4.0), .y = rect.y + theme.scaledUi(7.0) + (title_size * 1.25 - dot) * 0.5, .w = dot, .h = dot };
    state.palette_overlay_batch.roundedRect(state.allocator, dot_rect, paletteColor(theme.accent()), dot * 0.5) catch {};
    const text_x = rect.x + theme.scaledUi(20.0);
    const text_w = rect.w - theme.scaledUi(20.0);
    _ = drawSelectable(state, .mcp_benefit_title, index, .{ .x = text_x, .y = rect.y + theme.scaledUi(7.0), .w = text_w, .h = 0.0 }, title, theme.COLOR_WHITE, title_size, TEXT_ROLE, clip, 1);
    _ = drawSelectable(state, .mcp_benefit_detail, index, .{ .x = text_x, .y = rect.y + theme.scaledUi(27.0), .w = text_w, .h = 0.0 }, detail, theme.raise(theme.COLOR_TEXT_SUBTLE, 0.1), theme.scaledUi(12.5), TEXT_ROLE, clip, 1);
}

// ---- drawing helpers ----------------------------------------------------------

fn drawChrome(state: *runtime.AppState, width: f32, height: f32, modal: palette.Rect) void {
    state.palette_overlay_batch.roundedRect(state.allocator, .{ .x = 0.0, .y = 0.0, .w = width, .h = height }, paletteColor(theme.scrim(0.68)), 0.0) catch {};
    state.palette_overlay_batch.panel(state.allocator, snapRect(modal), paletteColor(theme.COLOR_PANEL), paletteColor(theme.withAlpha(theme.borderMuted(), 110)), theme.scaledUi(12.0), crispStroke(1.0)) catch {};
}

/// Dialog button: one panel command (fill + border) and a measured label,
/// optionally clipped to the scrolling list band.
fn drawButton(state: *runtime.AppState, rect: palette.Rect, label: []const u8, color: [4]f32, clip: ?palette.Rect) void {
    const visible = if (clip) |band| rectIntersection(rect, band) else rect;
    if (visible.w <= 0.0 or visible.h <= 0.0) return;
    const hovered = pointInRect(state.transcript_controller.palette_mouse_x, state.transcript_controller.palette_mouse_y, visible);
    const fill = if (hovered) theme.raise(color, 0.055) else color;
    const border = if (hovered) theme.raise(color, 0.14) else theme.raise(color, 0.06);
    const radius = theme.scaledUi(7.0);
    if (clip) |band| {
        state.palette_overlay_batch.panelClipped(state.allocator, snapRect(rect), paletteColor(fill), paletteColor(border), radius, crispStroke(1.0), band) catch {};
    } else {
        state.palette_overlay_batch.panel(state.allocator, snapRect(rect), paletteColor(fill), paletteColor(border), radius, crispStroke(1.0)) catch {};
    }
    const font_size = theme.scaledUi(14.0);
    const text_w = @min(text_measure.textWidth(TEXT_ROLE, font_size, label), rect.w - theme.scaledUi(8.0));
    queueRoleText(state, .{
        .x = rect.x + (rect.w - text_w) * 0.5,
        .y = rect.y + (rect.h - font_size * 1.25) * 0.5,
        .w = text_w + theme.scaledUi(2.0),
        .h = font_size * 1.25,
    }, label, theme.foregroundOn(fill), font_size, TEXT_ROLE, visible);
}

fn queueRoleText(state: *runtime.AppState, rect: palette.Rect, value: []const u8, color: [4]f32, font_size: f32, role: palette.FontRole, clip: ?palette.Rect) void {
    const stable = state.palette_frame_text_arena.allocator().dupe(u8, value) catch return;
    state.palette_overlay_batch.fixedRoleText(
        state.allocator,
        rect,
        stable,
        paletteColor(color),
        font_size,
        role,
        null,
        clip,
        .{},
        // No fixed glyph cell: a positive width makes `.mono` text draw on a
        // `font_size * 0.55` grid wider than the face's real advances, so it
        // overran the measured command pill. Natural advances match
        // `text_measure`, which every layout, hit test, and highlight uses.
        0.0,
        font_size * 1.25,
        false,
    ) catch |err| {
        runtime.log.warn("failed to queue onboarding text: {s}", .{@errorName(err)});
    };
}

/// Whole-device-pixel stroke for crisp chrome (Palette rules).
fn crispStroke(width_ui: f32) f32 {
    return @max(@round(theme.scaledUi(width_ui)), 1.0);
}

fn snapRect(rect: palette.Rect) palette.Rect {
    const left = @round(rect.x);
    const top = @round(rect.y);
    return .{ .x = left, .y = top, .w = @round(rect.x + rect.w) - left, .h = @round(rect.y + rect.h) - top };
}

fn rectIntersection(a: palette.Rect, b: palette.Rect) palette.Rect {
    const x0 = @max(a.x, b.x);
    const y0 = @max(a.y, b.y);
    const x1 = @min(a.x + a.w, b.x + b.w);
    const y1 = @min(a.y + a.h, b.y + b.h);
    return .{ .x = x0, .y = y0, .w = @max(x1 - x0, 0.0), .h = @max(y1 - y0, 0.0) };
}

fn pointInRect(x: f32, y: f32, rect: palette.Rect) bool {
    return rect.w > 0.0 and rect.h > 0.0 and x >= rect.x and y >= rect.y and x <= rect.x + rect.w and y <= rect.y + rect.h;
}

fn paletteColor(value: [4]f32) palette.Color {
    return .{ .r = value[0], .g = value[1], .b = value[2], .a = value[3] };
}

// ---- tests ------------------------------------------------------------------

test "provider rows cover every provider with an installer, Muse included" {
    for (PROVIDERS) |provider| {
        try std.testing.expect(provider_setup.command(provider, false) != null);
    }
    try std.testing.expect(std.mem.indexOfScalar(Provider, &PROVIDERS, .muse) != null);
    try std.testing.expect(std.mem.indexOfScalar(Provider, &PROVIDERS, .fx) != null);
}

test "Back never sits where Not now was" {
    theme.applyTheme(1.0);
    const layout = providerLayout(1280.0, 900.0, PROVIDERS.len);
    const footer = providerFooter(layout);
    try std.testing.expect(footer.back.x > footer.close.x + footer.close.w);
    try std.testing.expect(footer.back.x + footer.back.w < footer.check.x);
}

test "Tab order follows rows, then the footer, and wraps" {
    resetInput();
    focus_stop_count = 0;
    recordStop(.provider_onboarding_copy, 0, .{ .x = 0, .y = 0, .w = 10, .h = 10 }, .{ .x = 0, .y = 0, .w = 100, .h = 100 });
    recordStop(.provider_onboarding_action, 0, .{ .x = 20, .y = 0, .w = 10, .h = 10 }, .{ .x = 0, .y = 0, .w = 100, .h = 100 });
    recordStop(.provider_onboarding_action, 1, .{ .x = 20, .y = 20, .w = 10, .h = 10 }, .{ .x = 0, .y = 0, .w = 100, .h = 100 });
    recordStop(.provider_onboarding_close, 0, .{ .x = 0, .y = 120, .w = 10, .h = 10 }, null);
    try std.testing.expect(focusedStopIndex() == null);
    keyboard_focus = .{ .action = .provider_onboarding_action, .index = 1 };
    try std.testing.expectEqual(@as(?usize, 2), focusedStopIndex());
    keyboard_focus = .{ .action = .provider_onboarding_close, .index = 0 };
    // Identity survives the list changing between frames.
    focus_stop_count = 0;
    recordStop(.provider_onboarding_close, 0, .{ .x = 0, .y = 120, .w = 10, .h = 10 }, null);
    try std.testing.expectEqual(@as(?usize, 0), focusedStopIndex());
    resetInput();
    focus_stop_count = 0;
}

test "selection copies across lines, joining wrapped lines and splitting blocks" {
    resetInput();
    text_line_count = 0;
    const lines = [_]struct { block: u32, text: []const u8 }{
        .{ .block = blockId(.mcp_description, 0), .text = "Enable Verde's MCP " },
        .{ .block = blockId(.mcp_description, 0), .text = "tools." },
        .{ .block = blockId(.mcp_note, 0), .text = "Remove it any time." },
    };
    for (lines, 0..) |line, n| {
        const entry = &text_lines[text_line_count];
        entry.* = .{ .id = (line.block << 8) | @as(u32, @intCast(n)), .block = line.block, .x = 0, .y = @floatFromInt(n * 20), .h = 18, .font = 12, .role = .ui, .clip = .{ .x = 0, .y = 0, .w = 500, .h = 500 }, .len = line.text.len, .bytes = undefined };
        @memcpy(entry.bytes[0..line.text.len], line.text);
        text_line_count += 1;
    }
    sel_anchor = .{ .id = text_lines[0].id, .offset = 7 };
    sel_focus = .{ .id = text_lines[2].id, .offset = 6 };
    const copied = (try selectedTextAlloc(std.testing.allocator)).?;
    defer std.testing.allocator.free(copied);
    try std.testing.expectEqualStrings("Verde's MCP tools.\nRemove", copied);
    // A collapsed caret is not a selection.
    sel_focus = sel_anchor;
    try std.testing.expect(selectionRange() == null);
    resetInput();
    text_line_count = 0;
}
