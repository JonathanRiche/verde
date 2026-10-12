//! Provider sign-in / install from the "Connect an AI provider" dialog.
//!
//! The dialog runs the provider's own command in a setup terminal it owns and
//! draws inline, so it works before any workspace exists (workspace terminal
//! panes need a project). Rows report progress in place, the dialog rechecks
//! readiness on a timer while open, and every row offers its command to copy.

const std = @import("std");
const builtin = @import("builtin");
const headless = @import("headless");
const platform_paths = @import("platform_paths");
const app_config = @import("../app/config.zig");
const keybinds = @import("../app/keybinds.zig");
const palette = @import("palette");
const platform_runtime = @import("platform_runtime");
const terminal = @import("../terminal/terminal.zig");
const provider_models = @import("provider_models.zig");

const log = std.log.scoped(.provider_setup);
const Provider = provider_models.Provider;

/// Session id namespace for the setup terminal, far above per-workspace
/// terminal dock ids so daemon sessions never collide with a real dock.
const SETUP_DOCK_ID: u32 = 0x7fff_0001;
/// While the dialog is open, readiness re-runs at this cadence so a login
/// finished anywhere (our terminal or the user's own) flips the row to Ready.
pub const RECHECK_INTERVAL_MS: i64 = 6_000;
/// How long a row says "Copied"; matches code-block copy in threads.
pub const COPIED_FEEDBACK_MS: i64 = 1_200;

pub const Status = enum { idle, running, succeeded, failed };

/// Per-provider progress line shown in its dialog row.
pub const RowNote = enum { none, finished, failed, copied };

pub const Setup = struct {
    /// Heap-owned so its address is stable for the terminal session.
    dock: ?*terminal.Dock = null,
    provider: Provider = .codex,
    login: bool = false,
    status: Status = .idle,
    /// Setup terminals whose command was still running when closed; kept
    /// until their session ends so the process is never orphaned mid-teardown.
    closing: std.ArrayList(*terminal.Dock) = .empty,
    notes: [std.meta.fields(Provider).len]RowNote = @splat(.none),
    /// When the current "Copied" note clears; 0 when none is showing.
    copied_until_ms: i64 = 0,
    last_recheck_ms: i64 = 0,

    pub fn visible(self: *const Setup) bool {
        return self.dock != null;
    }

    pub fn note(self: *const Setup, provider: Provider) RowNote {
        return self.notes[@intFromEnum(provider)];
    }

    pub fn deinit(self: *Setup, allocator: std.mem.Allocator) void {
        if (self.dock) |dock| destroyDock(allocator, dock);
        self.dock = null;
        for (self.closing.items) |dock| destroyDock(allocator, dock);
        self.closing.deinit(allocator);
    }
};

fn destroyDock(allocator: std.mem.Allocator, dock: *terminal.Dock) void {
    dock.deinit(allocator);
    allocator.destroy(dock);
}

/// The command a row offers: install when the CLI is missing, else sign in.
/// Null when this OS has no installer for the provider.
pub fn command(provider: Provider, missing: bool) ?[]const u8 {
    const protocol = protocolProvider(provider);
    if (!missing) return headless.provider_install.loginShell(protocol);
    if (builtin.os.tag == .windows) return headless.provider_install.installShellWindows(protocol);
    return headless.provider_install.installShell(protocol);
}

fn protocolProvider(provider: Provider) headless.provider_types.Provider {
    return switch (provider) {
        .codex => .codex,
        .claude => .claude,
        .cursor => .cursor,
        .opencode => .opencode,
        .pi => .pi,
        .fx => .fx,
        .grok => .grok,
        .muse => .muse,
        .custom_acp => .custom_acp,
    };
}

/// Opens the setup terminal for `provider` inside the dialog, in the home
/// directory, running its install or sign-in command.
pub fn start(self: anytype, provider: Provider) void {
    const setup = &self.settings_controller.provider_setup;
    const readiness = self.providerReadinessSnapshot().forProvider(provider);
    const missing = readiness == .missing;
    const shell = command(provider, missing) orelse {
        self.setSidebarNotice("This provider has no installer for this system yet. See the setup guide.");
        self.markDirty();
        return;
    };
    close(self);

    const allocator = self.allocator;
    const home = platform_paths.userHome(allocator) catch allocator.dupe(u8, "/") catch return;
    defer allocator.free(home);
    const dock = allocator.create(terminal.Dock) catch return;
    dock.* = terminal.Dock.init(allocator) catch {
        allocator.destroy(dock);
        return;
    };
    dock.setDefaultFontSize(self.app_config.terminal_font_size);
    // Windows: -ExecutionPolicy Bypass lets the upstream `irm … | iex`
    // installers run on a default-policy machine, scoped to this process.
    const argv: []const []const u8 = if (builtin.os.tag == .windows)
        &.{ "powershell.exe", "-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", shell }
    else
        &.{ "bash", "-lc", shell };
    dock.restartWithProfilePersistent(allocator, home, .{
        .kind = .custom,
        .label = if (missing) "Install" else "Sign in",
        .command = argv,
    }, self.storage.pref_path, SETUP_DOCK_ID) catch |err| {
        log.warn("failed to start provider setup terminal: {s}", .{@errorName(err)});
        destroyDock(allocator, dock);
        self.setSidebarNotice("Could not open a terminal for provider setup.");
        self.markDirty();
        return;
    };
    // One-shot command: never revive it after it exits.
    if (dock.activePane()) |leaf| leaf.revive_policy = .attach_only;

    setup.dock = dock;
    setup.provider = provider;
    setup.login = !missing;
    setup.status = .running;
    setup.notes[@intFromEnum(provider)] = .none;
    // Typing goes to the setup terminal, not any field behind the dialog.
    self.palette_modal_text_focus = .none;
    self.markDirty();
}

/// Returns to the provider list. A command still running is stopped.
pub fn close(self: anytype) void {
    const setup = &self.settings_controller.provider_setup;
    const dock = setup.dock orelse return;
    setup.dock = null;
    setup.status = .idle;
    if (dock.hasRunningSession()) {
        _ = dock.terminateActiveSession();
        setup.closing.append(self.allocator, dock) catch destroyDock(self.allocator, dock);
    } else {
        destroyDock(self.allocator, dock);
    }
    self.markDirty();
}

/// Copies a provider's command so it can be run in any terminal.
pub fn copyCommand(self: anytype, provider: Provider) void {
    const missing = self.providerReadinessSnapshot().forProvider(provider) == .missing;
    const shell = command(provider, missing) orelse return;
    if (self.setClipboardText(shell)) {
        // The clipboard holds one command, so only the latest row says Copied.
        clearCopiedNotes(&self.settings_controller.provider_setup);
        self.settings_controller.provider_setup.notes[@intFromEnum(provider)] = .copied;
        self.settings_controller.provider_setup.copied_until_ms = platform_runtime.unixTimestampMs() + COPIED_FEEDBACK_MS;
    }
    self.markDirty();
}

fn clearCopiedNotes(setup: *Setup) void {
    for (&setup.notes) |*row_note| {
        if (row_note.* == .copied) row_note.* = .none;
    }
}

/// Frame-loop upkeep: drains terminal output, notices the command exiting
/// (then rechecks readiness), reaps stopped terminals, and rechecks on a
/// timer while the dialog is open.
pub fn poll(self: anytype, now_ms: i64) void {
    const setup = &self.settings_controller.provider_setup;
    if (setup.copied_until_ms != 0 and now_ms >= setup.copied_until_ms) {
        setup.copied_until_ms = 0;
        clearCopiedNotes(setup);
        self.markDirty();
    }
    if (setup.dock) |dock| {
        if (dock.poll(self.allocator) catch false) self.markDirty();
        if (setup.status == .running) {
            if (dock.activeSessionSnapshot()) |snapshot| {
                if (!snapshot.running and (snapshot.exit_code != null or snapshot.signal != null)) {
                    const ok = snapshot.exit_code != null and snapshot.exit_code.? == 0;
                    setup.status = if (ok) .succeeded else .failed;
                    setup.notes[@intFromEnum(setup.provider)] = if (ok) .finished else .failed;
                    self.startProviderReadinessCheck();
                    self.markDirty();
                }
            }
        }
    }
    var index: usize = 0;
    while (index < setup.closing.items.len) {
        const dock = setup.closing.items[index];
        _ = dock.poll(self.allocator) catch {};
        if (dock.hasRunningSession()) {
            index += 1;
            continue;
        }
        destroyDock(self.allocator, dock);
        _ = setup.closing.swapRemove(index);
    }
    // Unit tests drive the dialog without a daemon; never start real probes.
    if (!builtin.is_test and self.settings_controller.provider_onboarding_visible and now_ms - setup.last_recheck_ms >= RECHECK_INTERVAL_MS) {
        setup.last_recheck_ms = now_ms;
        self.startProviderReadinessCheck();
    }
}

/// Routes keys to the setup terminal while it is shown. Escape returns to
/// the list once the command has exited; while it runs, Escape belongs to
/// the command (sign-in TUIs use it).
pub fn handleKeyDown(self: anytype, keyboard: ?*const keybinds.NativeKeyboardConfig, event: *const palette.event.KeyEvent) bool {
    const setup = &self.settings_controller.provider_setup;
    const dock = setup.dock orelse return false;
    if (setup.status != .running) {
        if (event.key == .escape) {
            close(self);
            return true;
        }
        return true;
    }
    const config = keyboard orelse return true;
    _ = dock.handleKeyDown(self.allocator, config, event);
    self.markDirty();
    return true;
}

pub fn handleTextInput(self: anytype, text: []const u8) bool {
    const setup = &self.settings_controller.provider_setup;
    const dock = setup.dock orelse return false;
    if (setup.status == .running) _ = dock.handleTextInput(text);
    self.markDirty();
    return true;
}

/// Pastes clipboard text into the running setup terminal (device codes).
pub fn paste(self: anytype, text: []const u8) bool {
    const setup = &self.settings_controller.provider_setup;
    const dock = setup.dock orelse return false;
    if (setup.status != .running) return true;
    _ = dock.pasteTextToActivePane(self.allocator, text) catch false;
    self.markDirty();
    return true;
}
