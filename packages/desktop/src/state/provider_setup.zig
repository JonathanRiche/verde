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
const provider_controller = @import("provider_controller.zig");
const remote_terminal = @import("remote_setup_terminal.zig");
const auth_probe = @import("remote_auth_probe.zig");
pub const remote_github = @import("remote_github.zig");
const runtime_manager = @import("../runtime/manager.zig");
const runtime_connections_controller = @import("runtime_connections_controller.zig");

const log = std.log.scoped(.provider_setup);
const Provider = provider_models.Provider;
const ProviderReadiness = provider_controller.ProviderReadiness;
const ProviderReadinessSnapshot = provider_controller.ProviderReadinessSnapshot;

/// Session id namespace for the setup terminal, far above per-workspace
/// terminal dock ids so daemon sessions never collide with a real dock. The
/// terminal panel also uses it to route pointer input to this dock.
pub const SETUP_DOCK_ID: u32 = 0x7fff_0001;
/// While the dialog is open, readiness re-runs at this cadence so a login
/// finished anywhere (our terminal or the user's own) flips the row to Ready.
pub const RECHECK_INTERVAL_MS: i64 = 6_000;
/// How long a row says "Copied"; matches code-block copy in threads.
pub const COPIED_FEEDBACK_MS: i64 = 1_200;
/// "Check again" reads "Checking..." at least this long, even when the check
/// itself finishes in a few milliseconds (nothing installed).
pub const MIN_CHECKING_VISIBLE_MS: i64 = 600;
/// Grid the setup terminal keeps visible (font shrinks to fit, never above
/// the user's terminal font size): room for a CLI's QR code plus the URL
/// and code lines below it.
pub const SETUP_TERMINAL_MIN_COLS: u16 = 110;
pub const SETUP_TERMINAL_MIN_ROWS: u16 = 48;
/// Retry delays for a remote `providers.status` that could not start: the
/// runtime's general RPC slot was busy, or the runtime was unreachable.
const REMOTE_STATUS_BUSY_RETRY_MS: i64 = 250;
const REMOTE_STATUS_FAILURE_RETRY_MS: i64 = 2_000;
/// Setup commands run here rather than in $HOME, so a CLI that asks to trust
/// its working folder (Pi) asks about an empty Verde folder, not the whole
/// home directory. Installers and logins write to $HOME paths, not the cwd.
pub const SETUP_DIR_NAME = "provider-setup";

/// Where "Get Node.js" points; the LTS installers and package-manager notes.
pub const NODE_DOWNLOAD_URL = "https://nodejs.org/en/download";
/// One wording for a CLI that is installed but lacks Node.js, shared by the
/// provider dialog (row, setup view) and Settings > Providers.
pub const NEEDS_NODE_STATUS = "Needs Node.js";
pub const NEEDS_NODE_GUIDANCE = "Installed, but Verde runs it with Node.js 18+. Get Node.js (nodejs.org or your package manager), then Check again.";

pub const Status = enum { idle, running, succeeded, failed };

/// What the setup terminal runs. Update only comes from Settings.
pub const Mode = enum { install, sign_in, update };

/// Per-provider progress line shown in its dialog row.
pub const RowNote = enum {
    none,
    /// The command exited 0; waiting for a readiness check that started
    /// after it (`Setup.awaited_generation`).
    install_finished,
    sign_in_finished,
    failed,
    copied,
    // Resolved from the post-command readiness check.
    installed_sign_in_next,
    still_signed_out,
    not_on_path,
    /// Present, but a runtime it needs (Node.js for Claude) is not.
    needs_node,
    unverified,
    /// A remote sign-in exited 0 on a runtime that cannot verify accounts
    /// (`authentication: "unknown"`); Verde trusts it for this app session.
    signed_in_unverified,

    pub fn awaitingCheck(self: RowNote) bool {
        return self == .install_finished or self == .sign_in_finished;
    }
};

/// Runtime tools set up from Settings > Connections with the same dialog and
/// terminal as providers (see `remote_github.zig`); never a dialog row.
pub const Tool = enum {
    github,

    pub fn displayName(self: Tool) []const u8 {
        return switch (self) {
            .github => "GitHub",
        };
    }
};

/// Dialog names, shared by its rows, its notices, and the welcome screen.
pub fn displayName(provider: Provider) []const u8 {
    return switch (provider) {
        .codex => "Codex",
        .opencode => "OpenCode",
        .claude => "Claude Code",
        .cursor => "Cursor",
        .pi => "Pi",
        .fx => "FX",
        .grok => "Grok",
        .muse => "Muse",
        .custom_acp => "Custom ACP agents",
    };
}

pub const Setup = struct {
    /// Heap-owned so its address is stable for the terminal session.
    dock: ?*terminal.Dock = null,
    provider: Provider = .codex,
    mode: Mode = .sign_in,
    status: Status = .idle,
    /// Readiness generation whose completion resolves "Checking your
    /// account…" notes; 0 when none is awaited.
    awaited_generation: u32 = 0,
    /// Setup terminals whose command was still running when closed; kept
    /// until their session ends so the process is never orphaned mid-teardown.
    closing: std.ArrayList(*terminal.Dock) = .empty,
    notes: [std.meta.fields(Provider).len]RowNote = @splat(.none),
    /// When the current "Copied" note clears; 0 when none is showing.
    copied_until_ms: i64 = 0,
    last_recheck_ms: i64 = 0,
    /// "Check again" keeps reading "Checking..." until this time; 0 when idle.
    checking_until_ms: i64 = 0,
    /// Remote runtime profile the rows, commands, and terminal target; null
    /// is this computer. Re-resolved each poll while no command is open.
    target_profile_id: ?[]u8 = null,
    /// Bumped on every target change so stale remote status is discarded.
    target_generation: u32 = 0,
    pin: Pin = .auto,
    /// The runtime Settings > Connections opened the dialog for (`.runtime`).
    pinned_profile_id: ?[]u8 = null,
    /// Carries `dock`'s command when it runs on `target_profile_id`.
    remote: ?*remote_terminal.Pump = null,
    /// Stopped remote commands still delivering their `session.kill`.
    remote_closing: std.ArrayList(*remote_terminal.Pump) = .empty,
    remote_readiness: RemoteReadiness = .{},
    /// Remote sign-ins that exited 0 this app session, per runtime profile.
    /// Shown as signed in where the runtime cannot verify accounts.
    remote_sign_ins: std.ArrayList(RemoteSignIn) = .empty,
    /// Account status probes per runtime profile and provider (see
    /// `remote_auth_probe.zig`); at most one runs at a time.
    auth_probes: std.ArrayList(auth_probe.Entry) = .empty,
    active_probe: ?ActiveProbe = null,
    /// The running command was launched from Settings > Connections, so a
    /// successful finish returns there.
    origin_settings: bool = false,
    /// When a successful remote sign-in returns to where it started; 0 when
    /// none is pending.
    complete_at_ms: i64 = 0,
    /// The open command sets up this tool rather than `provider`.
    tool: ?Tool = null,
    /// `notes` counterpart for the open tool command.
    tool_note: RowNote = .none,
    /// GitHub CLI status probes per runtime profile.
    github_probes: std.ArrayList(remote_github.Entry) = .empty,

    pub fn visible(self: *const Setup) bool {
        return self.dock != null;
    }

    pub fn note(self: *const Setup, provider: Provider) RowNote {
        return self.notes[@intFromEnum(provider)];
    }

    /// The open command's note: its tool's, else its provider row's.
    pub fn currentNote(self: *const Setup) RowNote {
        return if (self.tool != null) self.tool_note else self.note(self.provider);
    }

    fn setCurrentNote(self: *Setup, value: RowNote) void {
        if (self.tool != null) self.tool_note = value else self.notes[@intFromEnum(self.provider)] = value;
    }

    /// Name the setup view uses for the open command's subject.
    pub fn subjectName(self: *const Setup) []const u8 {
        return if (self.tool) |tool| tool.displayName() else displayName(self.provider);
    }

    pub fn deinit(self: *Setup, allocator: std.mem.Allocator) void {
        if (self.dock) |dock| destroyDock(allocator, dock);
        self.dock = null;
        for (self.closing.items) |dock| destroyDock(allocator, dock);
        self.closing.deinit(allocator);
        // Shutdown: the runtime service may already be gone, so in-flight
        // terminal tickets are left to the runtime manager's own teardown.
        var no_lane: NoLane = .{};
        if (self.remote) |pump| pump.destroy(allocator, &no_lane);
        self.remote = null;
        for (self.remote_closing.items) |pump| pump.destroy(allocator, &no_lane);
        self.remote_closing.deinit(allocator);
        if (self.target_profile_id) |value| allocator.free(value);
        self.target_profile_id = null;
        if (self.pinned_profile_id) |value| allocator.free(value);
        self.pinned_profile_id = null;
        for (self.remote_sign_ins.items) |entry| allocator.free(entry.profile_id);
        self.remote_sign_ins.deinit(allocator);
        if (self.active_probe) |*probe| {
            std.crypto.secureZero(u8, probe.output.items);
            probe.output.deinit(allocator);
            probe.pump.capture = null;
            probe.pump.destroy(allocator, &no_lane);
        }
        self.active_probe = null;
        for (self.auth_probes.items) |entry| allocator.free(entry.profile_id);
        self.auth_probes.deinit(allocator);
        for (self.github_probes.items) |entry| allocator.free(entry.profile_id);
        self.github_probes.deinit(allocator);
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

/// Opens the setup terminal for `provider` inside the dialog, in Verde's
/// setup folder (`setupDirAlloc`), running its install or sign-in command.
pub fn start(self: anytype, provider: Provider) void {
    const missing = readinessSnapshot(self).forProvider(provider) == .missing;
    const shell = commandFor(self, provider, missing) orelse {
        self.setSidebarNotice("This provider has no installer for this system yet. See the setup guide.");
        self.markDirty();
        return;
    };
    startCommand(self, provider, if (missing) .install else .sign_in, shell);
}

/// Runs `shell` for `provider` in the dialog's setup terminal. Settings uses
/// this directly for updates, whose command comes from the package manager.
pub fn startCommand(self: anytype, provider: Provider, mode: Mode, shell: []const u8) void {
    const setup = &self.settings_controller.provider_setup;
    close(self);
    if (setup.target_profile_id) |profile_id| return startRemoteCommand(self, profile_id, provider, null, mode, shell);

    const allocator = self.allocator;
    const cwd = setupDirAlloc(allocator, self.storage.pref_path) catch return;
    defer allocator.free(cwd);
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
    dock.restartWithProfilePersistent(allocator, cwd, .{
        .kind = .custom,
        .label = switch (mode) {
            .install => "Install",
            .sign_in => "Sign in",
            .update => "Update",
        },
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
    setup.tool = null;
    setup.mode = mode;
    setup.status = .running;
    setup.notes[@intFromEnum(provider)] = .none;
    // Typing goes to the setup terminal, not any field behind the dialog.
    self.palette_modal_text_focus = .none;
    self.markDirty();
}

/// An empty Verde-owned folder under the data directory for setup commands,
/// created on demand; falls back to $HOME (then `/`) when it cannot be made.
fn setupDirAlloc(allocator: std.mem.Allocator, pref_path: []const u8) ![]u8 {
    if (pref_path.len > 0) {
        if (std.fs.path.join(allocator, &.{ pref_path, SETUP_DIR_NAME })) |dir| {
            var threaded: std.Io.Threaded = .init(allocator, .{});
            defer threaded.deinit();
            if (std.Io.Dir.cwd().createDirPath(threaded.io(), dir)) |_| return dir else |err| {
                log.warn("failed to create provider setup folder: {s}", .{@errorName(err)});
                allocator.free(dir);
            }
        } else |_| {}
    }
    return platform_paths.userHome(allocator) catch allocator.dupe(u8, "/");
}

/// Returns to the provider list. A command still running is stopped.
pub fn close(self: anytype) void {
    const setup = &self.settings_controller.provider_setup;
    const dock = setup.dock orelse return;
    setup.dock = null;
    setup.status = .idle;
    setup.complete_at_ms = 0;
    setup.origin_settings = false;
    setup.tool = null;
    if (setup.remote) |pump| {
        // The remote process is stopped by `session.kill`, delivered by the
        // pump after the view is gone.
        setup.remote = null;
        destroyDock(self.allocator, dock);
        pump.requestKill(platform_runtime.unixTimestampMs());
        if (pump.finished()) {
            destroyPump(self, pump);
        } else {
            setup.remote_closing.append(self.allocator, pump) catch destroyPump(self, pump);
        }
    } else if (dock.hasRunningSession()) {
        _ = dock.terminateActiveSession();
        setup.closing.append(self.allocator, dock) catch destroyDock(self.allocator, dock);
    } else {
        destroyDock(self.allocator, dock);
    }
    self.markDirty();
}

/// Copies a provider's command so it can be run in any terminal.
pub fn copyCommand(self: anytype, provider: Provider) void {
    const missing = readinessSnapshot(self).forProvider(provider) == .missing;
    const shell = commandFor(self, provider, missing) orelse return;
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
    if (setup.checking_until_ms != 0 and now_ms >= setup.checking_until_ms) {
        setup.checking_until_ms = 0;
        self.markDirty();
    }
    syncTarget(self);
    pollRemoteCommand(self, now_ms);
    pollAuthProbes(self, now_ms);
    pollFinish(self, now_ms);
    if (setup.dock) |dock| {
        if (dock.poll(self.allocator) catch false) self.markDirty();
        if (setup.status == .running) {
            if (dock.activeSessionSnapshot()) |snapshot| {
                if (!snapshot.running and (snapshot.exit_code != null or snapshot.signal != null)) {
                    const ok = snapshot.exit_code != null and snapshot.exit_code.? == 0;
                    setup.status = if (ok) .succeeded else .failed;
                    setup.setCurrentNote(if (!ok) .failed else switch (setup.mode) {
                        .install, .update => .install_finished,
                        .sign_in => .sign_in_finished,
                    });
                    if (setup.tool != null) {
                        // A tool's state comes from its own probe, not readiness.
                        if (setup.remote) |pump| requestGithubProbe(self, pump.profile_id);
                    } else {
                        // A check already in flight may predate the command, so
                        // the note resolves from the next one to start.
                        setup.awaited_generation = if (setup.remote != null)
                            requestRemoteRecheck(setup)
                        else
                            self.requestFreshProviderReadinessCheck();
                    }
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
    pollRemoteReadiness(self, now_ms);
}

/// Turns a row's "Checking your account…" into what the post-command
/// readiness check found. Other notes pass through.
pub fn resolvedNote(row_note: RowNote, readiness: ProviderReadiness, requirement: ?provider_controller.MissingRequirement) RowNote {
    if (!row_note.awaitingCheck()) return row_note;
    return switch (readiness) {
        .checking => row_note,
        .ready => .none,
        .missing => if (requirement) |missing| switch (missing) {
            .node => .needs_node,
        } else .not_on_path,
        .signed_out => if (row_note == .install_finished) .installed_sign_in_next else .still_signed_out,
        .unavailable => .unverified,
    };
}

/// Called with each completed readiness check: once the check that started
/// after the setup command exited is in, its notes say what happened.
pub fn noteReadinessCompleted(setup: *Setup, snapshot: ProviderReadinessSnapshot, generation: u32) void {
    // A remote target's notes resolve from its own `providers.status`.
    if (setup.target_profile_id != null) return;
    resolveNotes(setup, snapshot, generation);
}

fn resolveNotes(setup: *Setup, snapshot: ProviderReadinessSnapshot, generation: u32) void {
    if (setup.awaited_generation == 0 or generation < setup.awaited_generation) return;
    setup.awaited_generation = 0;
    for (std.enums.values(Provider)) |provider| {
        const index = @intFromEnum(provider);
        setup.notes[index] = resolvedNote(setup.notes[index], snapshot.forProvider(provider), snapshot.requirementForProvider(provider));
    }
}

/// Routes keys to the setup terminal while its command runs; Escape belongs
/// to the command then (sign-in TUIs use it). Once it exits the dialog owns
/// keys (Tab focus, Escape returns to the list), so this returns false.
pub fn handleKeyDown(self: anytype, keyboard: ?*const keybinds.NativeKeyboardConfig, event: *const palette.event.KeyEvent) bool {
    const setup = &self.settings_controller.provider_setup;
    const dock = setup.dock orelse return false;
    if (setup.status != .running) return false;
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

// ---- remote runtime target ------------------------------------------------

/// Which machine the dialog was explicitly opened for. `.auto` follows the
/// active chat's runtime, else the workspace default.
pub const Pin = enum { auto, local, runtime };

/// The target runtime's `providers.status`, mapped to dialog readiness.
pub const RemoteReadiness = struct {
    snapshot: ProviderReadinessSnapshot = .{},
    /// In flight on the runtime's general RPC slot. Always drained, even
    /// after the dialog closes, so that slot never holds an unread result.
    ticket: ?runtime_manager.RpcTicket = null,
    ticket_seq: u32 = 0,
    ticket_target_generation: u32 = 0,
    /// Sequence of the last fetch started. After a remote command exits,
    /// `Setup.awaited_generation` is the first sequence started after it.
    started_seq: u32 = 0,
    next_fetch_ms: i64 = 0,
};

const NoLane = struct {
    pub fn abandonTerminalRpc(_: *NoLane, _: remote_terminal.RpcTicket) void {}
};

fn destroyPump(self: anytype, pump: *remote_terminal.Pump) void {
    if (self.runtime_service) |service| {
        pump.destroy(self.allocator, service);
    } else {
        var no_lane: NoLane = .{};
        pump.destroy(self.allocator, &no_lane);
    }
}

/// Readiness the dialog rows show: the target runtime's, else this computer's.
pub fn readinessSnapshot(self: anytype) ProviderReadinessSnapshot {
    const setup = &self.settings_controller.provider_setup;
    if (setup.target_profile_id != null) return effectiveRemoteSnapshot(setup);
    return self.providerReadinessSnapshot();
}

/// The command a row offers on the dialog's current target.
pub fn commandFor(self: anytype, provider: Provider, missing: bool) ?[]const u8 {
    if (self.settings_controller.provider_setup.target_profile_id == null) return command(provider, missing);
    return remoteCommand(provider, missing);
}

/// Install or sign-in command for a remote runtime: always the POSIX
/// installer, whatever OS this desktop runs.
pub fn remoteCommand(provider: Provider, missing: bool) []const u8 {
    const protocol = protocolProvider(provider);
    if (missing) return headless.provider_install.installShell(protocol);
    return switch (provider) {
        // The browser login's localhost callback cannot reach a remote host;
        // device auth prints a code instead. CLIs without it fall back.
        .codex => "codex login --device-auth || codex login",
        else => headless.provider_install.loginShell(protocol),
    };
}

/// Name of the targeted runtime; null when the target is this computer.
pub fn targetLabel(self: anytype) ?[]const u8 {
    const id = self.settings_controller.provider_setup.target_profile_id orelse return null;
    const service = self.runtime_service orelse return "remote runtime";
    const live = service.snapshot(id) orelse return "remote runtime";
    return live.label;
}

/// Dialog readiness for one runtime-reported provider. Daemons that cannot
/// verify an account report `authentication: "unknown"` (unverified).
pub fn remoteReadiness(installed: ?bool, state: []const u8, authentication: []const u8) ProviderReadiness {
    if ((installed != null and !installed.?) or std.mem.eql(u8, state, "missing")) return .missing;
    if (std.mem.eql(u8, state, "ready") or oneOf(authentication, &.{ "authenticated", "signed_in", "logged_in", "ready" })) return .ready;
    if (std.mem.eql(u8, state, "signed_out") or oneOf(authentication, &.{ "unauthenticated", "signed_out", "logged_out", "required" })) return .signed_out;
    return .unavailable;
}

fn oneOf(value: []const u8, candidates: []const []const u8) bool {
    for (candidates) |candidate| {
        if (std.mem.eql(u8, value, candidate)) return true;
    }
    return false;
}

/// Settings > Connections: opens the dialog on runtime `profile_id` and runs
/// `provider`'s install (when `missing`) or sign-in there.
pub fn openForRuntime(self: anytype, profile_id: []const u8, provider: Provider, missing: bool) void {
    const sc = &self.settings_controller;
    // The dialog draws below Settings; close Settings so it is on top.
    if (sc.modal_visible) self.cancelSettingsModal();
    sc.provider_onboarding_highlight = provider;
    sc.provider_onboarding_scroll_to_highlight = true;
    sc.provider_onboarding_pinned = true;
    sc.provider_onboarding_visible = true;
    sc.provider_onboarding_dismissed = false;
    close(self);
    setPin(self, .runtime, profile_id);
    setTarget(self, profile_id);
    startCommand(self, provider, if (missing) .install else .sign_in, remoteCommand(provider, missing));
    if (!sc.provider_setup.visible()) sc.provider_setup.notes[@intFromEnum(provider)] = .failed;
    sc.provider_setup.origin_settings = sc.provider_setup.visible();
    self.markDirty();
}

/// Settings > Connections: opens the dialog on runtime `profile_id` and runs
/// the GitHub CLI's install (when `missing`) or sign-in there. Finishing,
/// Done, and Back return to Settings.
pub fn openGithubForRuntime(self: anytype, profile_id: []const u8, missing: bool) void {
    const sc = &self.settings_controller;
    if (sc.modal_visible) self.cancelSettingsModal();
    sc.provider_onboarding_highlight = null;
    sc.provider_onboarding_pinned = true;
    sc.provider_onboarding_visible = true;
    sc.provider_onboarding_dismissed = false;
    close(self);
    setPin(self, .runtime, profile_id);
    setTarget(self, profile_id);
    const mode: Mode = if (missing) .install else .sign_in;
    startRemoteCommand(self, profile_id, sc.provider_setup.provider, .github, mode, if (missing) remote_github.INSTALL_SHELL else remote_github.SIGN_IN_SHELL);
    sc.provider_setup.origin_settings = sc.provider_setup.visible();
    // Nothing to show without the terminal; stay in Settings.
    if (!sc.provider_setup.visible()) {
        self.dismissProviderOnboarding();
        self.openSettingsToCategory(.connections);
    }
    self.markDirty();
}

/// Back / Escape from the setup view: a tool command returns to Settings
/// (it has no dialog row); a provider command returns to the provider list.
pub fn back(self: anytype) void {
    if (self.settings_controller.provider_setup.tool != null) return finishFlow(self);
    close(self);
}

/// Settings > Providers manages this computer's CLIs, whatever runtime the
/// active chat uses: its commands always run locally.
pub fn pinLocal(self: anytype) void {
    close(self);
    setPin(self, .local, null);
    setTarget(self, null);
}

/// "Check again" on a remote target asks the runtime right away.
pub fn requestRemoteRefresh(setup: *Setup) void {
    setup.remote_readiness.next_fetch_ms = 0;
}

fn setPin(self: anytype, pin: Pin, profile_id: ?[]const u8) void {
    const setup = &self.settings_controller.provider_setup;
    if (setup.pinned_profile_id) |value| self.allocator.free(value);
    setup.pinned_profile_id = null;
    setup.pin = pin;
    if (profile_id) |id| {
        setup.pinned_profile_id = self.allocator.dupe(u8, id) catch {
            setup.pin = .auto;
            return;
        };
    }
}

/// Re-resolves the target while no command is open: an explicit pin, else
/// the active chat's runtime (or the workspace default) when that is a
/// remote runtime ready to execute. A closed dialog targets this computer.
fn syncTarget(self: anytype) void {
    const sc = &self.settings_controller;
    const setup = &sc.provider_setup;
    // A command keeps the machine it started on.
    if (setup.dock != null) return;
    if (!sc.provider_onboarding_visible) {
        if (setup.pin != .auto) setPin(self, .auto, null);
        setTarget(self, null);
        return;
    }
    const wanted: ?[]const u8 = switch (setup.pin) {
        .local => null,
        .runtime => setup.pinned_profile_id,
        .auto => activeRemoteProfile(self),
    };
    setTarget(self, wanted);
}

fn setTarget(self: anytype, profile_id: ?[]const u8) void {
    const setup = &self.settings_controller.provider_setup;
    if (setup.target_profile_id == null and profile_id == null) return;
    if (setup.target_profile_id != null and profile_id != null and std.mem.eql(u8, setup.target_profile_id.?, profile_id.?)) return;
    const owned: ?[]u8 = if (profile_id) |id| self.allocator.dupe(u8, id) catch return else null;
    if (setup.target_profile_id) |value| self.allocator.free(value);
    setup.target_profile_id = owned;
    setup.target_generation +%= 1;
    setup.remote_readiness.snapshot = .{};
    setup.remote_readiness.next_fetch_ms = 0;
    // Row notes described the previous machine.
    setup.notes = @splat(.none);
    setup.awaited_generation = 0;
    self.markDirty();
}

fn activeRemoteProfile(self: anytype) ?[]const u8 {
    const projects = &self.project_controller;
    if (projects.selected_index >= projects.projects.items.len) return null;
    const project = &projects.projects.items[projects.selected_index];
    const profile_id = if (project.threads.items.len > 0)
        project.currentThread().selectedRuntimeRoute().profile_id
    else
        self.workspaceRuntimeDefaultProfile(project.id);
    if (std.mem.eql(u8, profile_id, "local")) return null;
    const service = self.runtime_service orelse return null;
    const live = service.snapshot(profile_id) orelse return null;
    return if (live.execution_ready) profile_id else null;
}

fn modeLabel(mode: Mode) []const u8 {
    return switch (mode) {
        .install => "Install",
        .sign_in => "Sign in",
        .update => "Update",
    };
}

/// Runs `shell` on runtime `profile_id` in a remote-backed setup terminal,
/// for `tool` when set, else for `provider`.
fn startRemoteCommand(self: anytype, profile_id: []const u8, provider: Provider, tool: ?Tool, mode: Mode, shell: []const u8) void {
    const setup = &self.settings_controller.provider_setup;
    const allocator = self.allocator;
    const service = self.runtime_service orelse return failRemoteStart(self, "Remote runtimes are unavailable right now.");
    const live = service.snapshot(profile_id) orelse return failRemoteStart(self, "That runtime is no longer configured.");
    if (!live.execution_ready) return failRemoteStart(self, "Connect this runtime in Settings > Connections, then try again.");
    const label = modeLabel(mode);
    const now_ms = platform_runtime.unixTimestampMs();
    var id_buf: [96]u8 = undefined;
    const subject = if (tool) |value| @tagName(value) else @tagName(provider);
    const session_id = std.fmt.bufPrint(&id_buf, "verde-provider-setup-{s}-{d}", .{ subject, now_ms }) catch return;
    // The remote daemon's own working directory is arbitrary; installers and
    // logins expect the runtime user's home.
    const remote_shell = std.fmt.allocPrint(allocator, "cd \"$HOME\" 2>/dev/null; {s}", .{shell}) catch return;
    defer allocator.free(remote_shell);
    const pump = remote_terminal.Pump.create(allocator, profile_id, session_id, remote_shell, label, now_ms) catch return;
    const dock = allocator.create(terminal.Dock) catch {
        destroyPump(self, pump);
        return;
    };
    dock.* = terminal.Dock.init(allocator) catch {
        allocator.destroy(dock);
        destroyPump(self, pump);
        return;
    };
    dock.setDefaultFontSize(self.app_config.terminal_font_size);
    dock.remote_backend = true;
    dock.session_dock_id = SETUP_DOCK_ID;
    dock.restartWithProfile(allocator, "~", .{ .kind = .custom, .label = label, .command = &.{ "bash", "-lc", shell } }) catch |err| {
        log.warn("failed to start remote provider setup terminal: {s}", .{@errorName(err)});
        destroyDock(allocator, dock);
        destroyPump(self, pump);
        return failRemoteStart(self, "Could not open a terminal for provider setup.");
    };
    if (dock.activePane()) |leaf| leaf.revive_policy = .attach_only;

    setup.dock = dock;
    setup.remote = pump;
    setup.provider = provider;
    setup.tool = tool;
    setup.mode = mode;
    setup.status = .running;
    setup.setCurrentNote(.none);
    // Typing goes to the setup terminal, not any field behind the dialog.
    self.palette_modal_text_focus = .none;
    self.markDirty();
}

fn failRemoteStart(self: anytype, notice: []const u8) void {
    self.setSidebarNotice(notice);
    self.markDirty();
}

/// Steps the remote command and stopped commands still delivering a kill.
pub const RemoteSignIn = struct { profile_id: []u8, provider: Provider };

/// How a remote row reads when the runtime cannot verify its account.
pub const RemoteRowState = enum {
    /// Not a remote row, or the runtime reported a definite state.
    none,
    /// Installed; the runtime reports sign-in as unknown.
    unverified,
    /// As `unverified`, but a sign-in exited 0 here this app session.
    signed_in_this_session,
};

fn rememberSignIn(self: anytype, profile_id: []const u8, provider: Provider) void {
    const setup = &self.settings_controller.provider_setup;
    if (signedInThisSession(setup, profile_id, provider)) return;
    const owned = self.allocator.dupe(u8, profile_id) catch return;
    setup.remote_sign_ins.append(self.allocator, .{ .profile_id = owned, .provider = provider }) catch self.allocator.free(owned);
}

/// Whether a sign-in for `provider` on runtime `profile_id` exited 0 in this
/// app session (Settings > Connections shows the same fact).
pub fn signedInThisSession(setup: *const Setup, profile_id: []const u8, provider: Provider) bool {
    for (setup.remote_sign_ins.items) |entry| {
        if (entry.provider == provider and std.mem.eql(u8, entry.profile_id, profile_id)) return true;
    }
    return false;
}

/// Presentation for a dialog row on a remote target whose account state the
/// runtime cannot report.
pub fn remoteRowState(self: anytype, provider: Provider) RemoteRowState {
    const setup = &self.settings_controller.provider_setup;
    const profile_id = setup.target_profile_id orelse return .none;
    if (effectiveRemoteSnapshot(setup).forProvider(provider) != .unavailable) return .none;
    return if (signedInThisSession(setup, profile_id, provider)) .signed_in_this_session else .unverified;
}

/// Remote counterpart of `resolveNotes`: a runtime that cannot verify
/// accounts turns a 0-exit sign-in into a trusted success, not a warning.
fn resolveRemoteNotes(setup: *Setup, snapshot: ProviderReadinessSnapshot, generation: u32) void {
    if (setup.awaited_generation == 0 or generation < setup.awaited_generation) return;
    for (std.enums.values(Provider)) |provider| {
        const index = @intFromEnum(provider);
        if (snapshot.forProvider(provider) != .unavailable) continue;
        setup.notes[index] = switch (setup.notes[index]) {
            .sign_in_finished => .signed_in_unverified,
            .install_finished => .installed_sign_in_next,
            else => |row_note| row_note,
        };
    }
    resolveNotes(setup, snapshot, generation);
}

fn pollRemoteCommand(self: anytype, now_ms: i64) void {
    const setup = &self.settings_controller.provider_setup;
    if (setup.remote) |pump| {
        if (self.runtime_service) |service| {
            if (pump.step(self.allocator, service, setup.dock, now_ms)) self.markDirty();
        }
        if (setup.status == .running and setup.mode == .sign_in and setup.tool == null and pump.phase == .exited and pump.exit_status != null and pump.exit_status.? == 0) {
            rememberSignIn(self, pump.profile_id, setup.provider);
            requestProbe(self, pump.profile_id, setup.provider);
        }
        if (setup.status == .running) switch (pump.phase) {
            .failed => {
                setup.status = .failed;
                setup.setCurrentNote(.failed);
                if (pump.failure) |message| self.setSidebarNotice(message);
                self.markDirty();
            },
            // Exited without a reported status: the readiness check says
            // what actually happened.
            .exited => if (pump.exit_status == null) {
                setup.status = .succeeded;
                setup.setCurrentNote(switch (setup.mode) {
                    .install, .update => .install_finished,
                    .sign_in => .sign_in_finished,
                });
                if (setup.tool != null) {
                    requestGithubProbe(self, pump.profile_id);
                } else {
                    setup.awaited_generation = requestRemoteRecheck(setup);
                }
                self.markDirty();
            },
            .creating, .running, .done => {},
        };
    }
    var index: usize = 0;
    while (index < setup.remote_closing.items.len) {
        const pump = setup.remote_closing.items[index];
        if (self.runtime_service) |service| {
            _ = pump.step(self.allocator, service, null, now_ms);
            if (!pump.finished()) {
                index += 1;
                continue;
            }
        }
        destroyPump(self, pump);
        _ = setup.remote_closing.swapRemove(index);
    }
}

/// Asks for a fresh `providers.status` and returns the fetch sequence whose
/// completion resolves the notes: the first one started after this call.
fn requestRemoteRecheck(setup: *Setup) u32 {
    setup.remote_readiness.next_fetch_ms = 0;
    const next = setup.remote_readiness.started_seq +% 1;
    return if (next == 0) 1 else next;
}

/// Drains the target runtime's `providers.status` and starts the next one on
/// the recheck timer while the dialog is open (Settings need not be).
fn pollRemoteReadiness(self: anytype, now_ms: i64) void {
    const sc = &self.settings_controller;
    const setup = &sc.provider_setup;
    const rr = &setup.remote_readiness;
    const service = self.runtime_service orelse return;
    if (rr.ticket) |ticket| {
        const taken = service.takeRpcResult(ticket) catch |err| blk: {
            log.warn("remote provider status result lost: {s}", .{@errorName(err)});
            rr.ticket = null;
            break :blk null;
        };
        if (taken) |value| {
            var result = value;
            defer result.deinit();
            rr.ticket = null;
            if (setup.target_profile_id) |profile_id| if (rr.ticket_target_generation == setup.target_generation) {
                switch (result) {
                    .response => |response| rr.snapshot = parseRemoteStatus(self.allocator, response.json) catch unverifiedSnapshot(),
                    // Unreachable this round; the timer tries again.
                    .failed, .canceled => {},
                }
                const after_command = setup.awaited_generation != 0 and rr.ticket_seq >= setup.awaited_generation;
                resolveRemoteNotes(setup, effectiveRemoteSnapshot(setup), rr.ticket_seq);
                // Settings > Connections lists the same runtime's providers.
                if (after_command) runtime_connections_controller.invalidateReadiness(self, profile_id);
                self.markDirty();
            };
        }
        if (rr.ticket != null) return;
    }
    const profile_id = setup.target_profile_id orelse return;
    if (!sc.provider_onboarding_visible or now_ms < rr.next_fetch_ms) return;
    const ticket = service.beginRpc(
        profile_id,
        headless.providers_protocol.METHOD_PROVIDERS_STATUS,
        headless.providers_protocol.StatusRequest{},
    ) catch |err| {
        rr.next_fetch_ms = now_ms +| switch (err) {
            error.RuntimeRpcBusy, error.RuntimeRpcResultPending => REMOTE_STATUS_BUSY_RETRY_MS,
            else => REMOTE_STATUS_FAILURE_RETRY_MS,
        };
        return;
    };
    rr.started_seq +%= 1;
    if (rr.started_seq == 0) rr.started_seq = 1;
    rr.ticket = ticket;
    rr.ticket_seq = rr.started_seq;
    rr.ticket_target_generation = setup.target_generation;
    rr.next_fetch_ms = now_ms +| RECHECK_INTERVAL_MS;
}

fn unverifiedSnapshot() ProviderReadinessSnapshot {
    var snapshot: ProviderReadinessSnapshot = .{};
    for (std.enums.values(Provider)) |provider| snapshot.setForProvider(provider, .unavailable);
    return snapshot;
}

/// Maps a `providers.status` JSON-RPC response to dialog readiness. Providers
/// the runtime did not report, or an error answer, read as unverified.
pub fn parseRemoteStatus(allocator: std.mem.Allocator, json: []const u8) !ProviderReadinessSnapshot {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();
    var snapshot = unverifiedSnapshot();
    if (parsed.value != .object) return error.InvalidDaemonResponse;
    const result = parsed.value.object.get("result") orelse return snapshot;
    if (result != .object) return error.InvalidDaemonResponse;
    const providers = result.object.get("providers") orelse return error.InvalidDaemonResponse;
    if (providers != .array) return error.InvalidDaemonResponse;
    for (providers.array.items) |item| {
        if (item != .object) continue;
        const id = jsonString(item, "provider") orelse continue;
        const provider = std.meta.stringToEnum(Provider, id) orelse continue;
        const installed: ?bool = if (item.object.get("installed")) |value| switch (value) {
            .bool => |flag| flag,
            else => null,
        } else null;
        snapshot.setForProvider(provider, remoteReadiness(
            installed,
            jsonString(item, "state") orelse "unknown",
            jsonString(item, "authentication") orelse "unknown",
        ));
    }
    return snapshot;
}

fn jsonString(value: std.json.Value, key: []const u8) ?[]const u8 {
    const field = value.object.get(key) orelse return null;
    return if (field == .string) field.string else null;
}

// ---- finishing a remote sign-in ------------------------------------------------

/// How long a successful remote sign-in shows its result before returning.
pub const FINISH_DELAY_MS: i64 = 1_500;

/// A remote sign-in exited 0 and the runtime (or its probe) agrees, or
/// cannot tell: the flow completes itself.
fn remoteSignInSucceeded(self: anytype) bool {
    const setup = &self.settings_controller.provider_setup;
    if (setup.remote == null or !setup.visible() or setup.mode != .sign_in or setup.status != .succeeded) return false;
    if (setup.tool != null) {
        const profile_id = setup.target_profile_id orelse return false;
        return githubStatus(setup, profile_id) == .signed_in;
    }
    if (setup.note(setup.provider) == .signed_in_unverified) return true;
    return effectiveRemoteSnapshot(setup).forProvider(setup.provider) == .ready;
}

/// True while a successful sign-in waits to return; the dialog's primary
/// button reads "Done" and finishes immediately.
pub fn finishPending(self: anytype) bool {
    return self.settings_controller.provider_setup.complete_at_ms != 0;
}

fn pollFinish(self: anytype, now_ms: i64) void {
    const setup = &self.settings_controller.provider_setup;
    if (setup.complete_at_ms == 0) {
        if (remoteSignInSucceeded(self)) {
            setup.complete_at_ms = now_ms +| FINISH_DELAY_MS;
            self.markDirty();
        }
    } else if (now_ms >= setup.complete_at_ms) {
        finishFlow(self);
    }
}

/// Returns to where the sign-in started: the provider list, or Settings >
/// Connections (its runtime row stays expanded) when launched from there.
pub fn finishFlow(self: anytype) void {
    const setup = &self.settings_controller.provider_setup;
    setup.complete_at_ms = 0;
    if (!setup.origin_settings) return close(self);
    self.dismissProviderOnboarding();
    self.openSettingsToCategory(.connections);
}

// ---- remote account probes ---------------------------------------------------

const ActiveProbe = struct {
    pump: *remote_terminal.Pump,
    provider: Provider,
    /// A GitHub CLI probe (`remote_github.zig`); `provider` is unused.
    github: bool = false,
    deadline_ms: i64,
    /// Probe output; may hold account emails, so it is wiped, never logged.
    output: std.ArrayList(u8) = .empty,
};

const ProbeTarget = struct { profile_id: []const u8, provider: Provider = .codex, github: bool = false };

/// Latest probe outcome for `provider` on runtime `profile_id`.
pub fn probedAuth(setup: *const Setup, profile_id: []const u8, provider: Provider) auth_probe.Result {
    for (setup.auth_probes.items) |entry| {
        if (entry.provider == provider and std.mem.eql(u8, entry.profile_id, profile_id)) return entry.result;
    }
    return .unknown;
}

/// The target runtime's readiness with probe results applied where the
/// daemon itself reports sign-in as unknown.
fn effectiveRemoteSnapshot(setup: *const Setup) ProviderReadinessSnapshot {
    var snapshot = setup.remote_readiness.snapshot;
    const profile_id = setup.target_profile_id orelse return snapshot;
    for (std.enums.values(Provider)) |provider| {
        if (snapshot.forProvider(provider) != .unavailable) continue;
        switch (probedAuth(setup, profile_id, provider)) {
            .signed_in => snapshot.setForProvider(provider, .ready),
            .signed_out => snapshot.setForProvider(provider, .signed_out),
            .unknown => {},
        }
    }
    return snapshot;
}

fn probeEntry(self: anytype, profile_id: []const u8, provider: Provider) ?*auth_probe.Entry {
    const setup = &self.settings_controller.provider_setup;
    for (setup.auth_probes.items) |*entry| {
        if (entry.provider == provider and std.mem.eql(u8, entry.profile_id, profile_id)) return entry;
    }
    const owned = self.allocator.dupe(u8, profile_id) catch return null;
    setup.auth_probes.append(self.allocator, .{ .profile_id = owned, .provider = provider }) catch {
        self.allocator.free(owned);
        return null;
    };
    return &setup.auth_probes.items[setup.auth_probes.items.len - 1];
}

/// Makes `provider`'s probe on `profile_id` due now and forgets its last
/// result (a sign-in just changed it).
fn requestProbe(self: anytype, profile_id: []const u8, provider: Provider) void {
    if (auth_probe.command(provider) == null) return;
    const entry = probeEntry(self, profile_id, provider) orelse return;
    entry.probed_at_ms = 0;
    entry.result = .unknown;
}

fn probeDue(setup: *const Setup, profile_id: []const u8, provider: Provider, now_ms: i64) bool {
    for (setup.auth_probes.items) |entry| {
        if (entry.provider == provider and std.mem.eql(u8, entry.profile_id, profile_id)) {
            return entry.probed_at_ms == 0 or now_ms -| entry.probed_at_ms >= auth_probe.PROBE_INTERVAL_MS;
        }
    }
    return true;
}

/// The next due probe for a runtime the user is looking at: installed
/// providers on the remote provider dialog's target, or on the expanded
/// Settings > Connections row, then that row's GitHub CLI (or the dialog's,
/// while it runs a GitHub command).
fn nextProbe(self: anytype, now_ms: i64) ?ProbeTarget {
    const sc = &self.settings_controller;
    const setup = &sc.provider_setup;
    if (sc.provider_onboarding_visible) if (setup.target_profile_id) |profile_id| {
        if (setup.tool == .github) {
            if (githubProbeDue(setup, profile_id, now_ms)) return .{ .profile_id = profile_id, .github = true };
        }
        for (std.enums.values(Provider)) |provider| {
            if (auth_probe.command(provider) == null) continue;
            switch (setup.remote_readiness.snapshot.forProvider(provider)) {
                .missing, .checking => continue,
                .ready, .signed_out, .unavailable => {},
            }
            if (probeDue(setup, profile_id, provider, now_ms)) return .{ .profile_id = profile_id, .provider = provider };
        }
    };
    if (!sc.modal_visible) return null;
    const rc = &self.runtime_connections;
    const profile_id = rc.expanded_profile_id orelse return null;
    const providers_loaded = if (rc.readiness_profile_id) |loaded| std.mem.eql(u8, profile_id, loaded) and rc.providers_state == .loaded else false;
    if (providers_loaded) for (rc.providers.items) |row| {
        const id = row.provider orelse continue;
        const provider = std.meta.stringToEnum(Provider, id) orelse continue;
        if (auth_probe.command(provider) == null or std.mem.eql(u8, row.state, "missing")) continue;
        if (probeDue(setup, profile_id, provider, now_ms)) return .{ .profile_id = profile_id, .provider = provider };
    };
    // GitHub needs nothing from the daemon beyond a terminal.
    if (githubProbeDue(setup, profile_id, now_ms)) return .{ .profile_id = profile_id, .github = true };
    return null;
}

/// Runs account probes one at a time on the terminal lane, each bounded by
/// `PROBE_DEADLINE_MS`; a probe that overruns is killed and reads unknown.
fn pollAuthProbes(self: anytype, now_ms: i64) void {
    const setup = &self.settings_controller.provider_setup;
    const service = self.runtime_service orelse return;
    if (setup.active_probe) |*probe| {
        _ = probe.pump.step(self.allocator, service, null, now_ms);
        const done = probe.pump.finished();
        if (!done and now_ms < probe.deadline_ms) return;
        const exited = done and probe.pump.phase == .exited;
        if (probe.github) {
            const status: remote_github.Status = if (exited)
                remote_github.parseProbe(probe.output.items, auth_probe.exitCode(probe.pump.exit_status))
            else
                .unknown;
            if (githubEntry(self, probe.pump.profile_id)) |entry| {
                entry.status = status;
                entry.probed_at_ms = now_ms;
            }
            resolveToolNoteFor(setup, probe.pump.profile_id, status);
        } else {
            const result: auth_probe.Result = if (exited)
                auth_probe.parse(probe.provider, probe.output.items, auth_probe.exitCode(probe.pump.exit_status))
            else
                .unknown;
            if (probeEntry(self, probe.pump.profile_id, probe.provider)) |entry| {
                entry.result = result;
                entry.probed_at_ms = now_ms;
            }
        }
        std.crypto.secureZero(u8, probe.output.items);
        probe.output.deinit(self.allocator);
        const pump = probe.pump;
        setup.active_probe = null;
        pump.capture = null;
        if (done) {
            destroyPump(self, pump);
        } else {
            pump.requestKill(now_ms);
            setup.remote_closing.append(self.allocator, pump) catch destroyPump(self, pump);
        }
        self.markDirty();
        return;
    }
    // A running setup command owns the user's attention; its exit asks for
    // a fresh probe.
    if (setup.remote != null and setup.status == .running) return;
    const target = nextProbe(self, now_ms) orelse return;
    const live = service.snapshot(target.profile_id) orelse return;
    if (!live.execution_ready) return;
    const shell = if (target.github)
        self.allocator.dupe(u8, remote_github.PROBE_SHELL) catch return
    else
        (auth_probe.shellAlloc(self.allocator, target.provider) catch return) orelse return;
    defer self.allocator.free(shell);
    var id_buf: [64]u8 = undefined;
    // Stable per provider: the next probe's create replaces the finished
    // session instead of leaving one per probe on the runtime.
    const subject = if (target.github) "github" else @tagName(target.provider);
    const session_id = std.fmt.bufPrint(&id_buf, "verde-auth-probe-{s}", .{subject}) catch return;
    const pump = remote_terminal.Pump.create(self.allocator, target.profile_id, session_id, shell, "Account status", now_ms) catch return;
    const deadline = if (target.github) auth_probe.PROBE_DEADLINE_MS else auth_probe.deadlineMs(target.provider);
    setup.active_probe = .{ .pump = pump, .provider = target.provider, .github = target.github, .deadline_ms = now_ms +| deadline };
    pump.capture = &setup.active_probe.?.output;
}

// ---- GitHub CLI on a runtime ---------------------------------------------------

/// Latest GitHub CLI status on runtime `profile_id`; null until a probe has
/// finished (Settings shows "checking").
pub fn githubStatus(setup: *const Setup, profile_id: []const u8) ?remote_github.Status {
    for (setup.github_probes.items) |entry| {
        if (std.mem.eql(u8, entry.profile_id, profile_id)) return entry.status;
    }
    return null;
}

/// "Check again" while a GitHub command is open: probe now, keeping the last
/// result on screen until the new one lands.
pub fn refreshGithubProbe(self: anytype) void {
    const setup = &self.settings_controller.provider_setup;
    if (setup.tool != .github) return;
    const profile_id = setup.target_profile_id orelse return;
    if (githubEntry(self, profile_id)) |entry| entry.probed_at_ms = 0;
}

fn githubEntry(self: anytype, profile_id: []const u8) ?*remote_github.Entry {
    const setup = &self.settings_controller.provider_setup;
    for (setup.github_probes.items) |*entry| {
        if (std.mem.eql(u8, entry.profile_id, profile_id)) return entry;
    }
    const owned = self.allocator.dupe(u8, profile_id) catch return null;
    setup.github_probes.append(self.allocator, .{ .profile_id = owned }) catch {
        self.allocator.free(owned);
        return null;
    };
    return &setup.github_probes.items[setup.github_probes.items.len - 1];
}

/// Probes GitHub on `profile_id` next and forgets the last result (an
/// install or sign-in just changed it).
fn requestGithubProbe(self: anytype, profile_id: []const u8) void {
    const entry = githubEntry(self, profile_id) orelse return;
    entry.probed_at_ms = 0;
    entry.status = null;
}

fn githubProbeDue(setup: *const Setup, profile_id: []const u8, now_ms: i64) bool {
    for (setup.github_probes.items) |entry| {
        if (std.mem.eql(u8, entry.profile_id, profile_id)) {
            return entry.probed_at_ms == 0 or now_ms -| entry.probed_at_ms >= auth_probe.PROBE_INTERVAL_MS;
        }
    }
    return true;
}

/// Setup readiness for a GitHub command's header: "ready" once signed in.
pub fn githubReadiness(status: ?remote_github.Status) ProviderReadiness {
    const value = status orelse return .checking;
    return switch (value) {
        .signed_in => .ready,
        .signed_out => .signed_out,
        .missing => .missing,
        .unknown => .unavailable,
    };
}

/// What a finished GitHub install / sign-in turned into, once its probe is in.
pub fn resolvedToolNote(row_note: RowNote, status: remote_github.Status) RowNote {
    if (!row_note.awaitingCheck()) return row_note;
    return switch (status) {
        .signed_in => .none,
        .signed_out => if (row_note == .install_finished) .installed_sign_in_next else .still_signed_out,
        .missing => .not_on_path,
        .unknown => .unverified,
    };
}

fn resolveToolNoteFor(setup: *Setup, profile_id: []const u8, status: remote_github.Status) void {
    if (setup.tool != .github) return;
    const target = setup.target_profile_id orelse return;
    if (!std.mem.eql(u8, target, profile_id)) return;
    setup.tool_note = resolvedToolNote(setup.tool_note, status);
}

test "GitHub notes and readiness follow the probe" {
    try std.testing.expectEqual(RowNote.installed_sign_in_next, resolvedToolNote(.install_finished, .signed_out));
    try std.testing.expectEqual(RowNote.still_signed_out, resolvedToolNote(.sign_in_finished, .signed_out));
    try std.testing.expectEqual(RowNote.none, resolvedToolNote(.sign_in_finished, .signed_in));
    try std.testing.expectEqual(RowNote.not_on_path, resolvedToolNote(.install_finished, .missing));
    try std.testing.expectEqual(RowNote.unverified, resolvedToolNote(.sign_in_finished, .unknown));
    try std.testing.expectEqual(RowNote.failed, resolvedToolNote(.failed, .signed_in));
    try std.testing.expectEqual(ProviderReadiness.checking, githubReadiness(null));
    try std.testing.expectEqual(ProviderReadiness.ready, githubReadiness(.signed_in));
    try std.testing.expectEqual(ProviderReadiness.missing, githubReadiness(.missing));

    var setup: Setup = .{};
    var entries = [_]remote_github.Entry{
        .{ .profile_id = @constCast("cloud"), .probed_at_ms = 5, .status = .signed_out },
    };
    setup.github_probes = .{ .items = &entries, .capacity = entries.len };
    defer setup.github_probes = .empty;
    try std.testing.expectEqual(@as(?remote_github.Status, .signed_out), githubStatus(&setup, "cloud"));
    try std.testing.expectEqual(@as(?remote_github.Status, null), githubStatus(&setup, "other"));
    try std.testing.expect(!githubProbeDue(&setup, "cloud", 5 + auth_probe.PROBE_INTERVAL_MS - 1));
    try std.testing.expect(githubProbeDue(&setup, "cloud", 5 + auth_probe.PROBE_INTERVAL_MS));
    try std.testing.expect(githubProbeDue(&setup, "other", 0));

    // Only the open GitHub command on the probed runtime takes the result.
    setup.tool = .github;
    setup.target_profile_id = @constCast("cloud");
    defer setup.target_profile_id = null;
    setup.tool_note = .sign_in_finished;
    resolveToolNoteFor(&setup, "other", .signed_in);
    try std.testing.expectEqual(RowNote.sign_in_finished, setup.currentNote());
    resolveToolNoteFor(&setup, "cloud", .signed_in);
    try std.testing.expectEqual(RowNote.none, setup.currentNote());
    try std.testing.expectEqualStrings("GitHub", setup.subjectName());
}

test "probe results override unknown remote sign-in only" {
    var setup: Setup = .{};
    setup.target_profile_id = @constCast("cloud");
    defer setup.target_profile_id = null;
    setup.remote_readiness.snapshot = unverifiedSnapshot();
    setup.remote_readiness.snapshot.codex = .missing;
    var entries = [_]auth_probe.Entry{
        .{ .profile_id = @constCast("cloud"), .provider = .claude, .probed_at_ms = 5, .result = .signed_in },
        .{ .profile_id = @constCast("cloud"), .provider = .cursor, .probed_at_ms = 5, .result = .signed_out },
        .{ .profile_id = @constCast("other"), .provider = .opencode, .probed_at_ms = 5, .result = .signed_in },
        .{ .profile_id = @constCast("cloud"), .provider = .codex, .probed_at_ms = 5, .result = .signed_in },
    };
    setup.auth_probes = .{ .items = &entries, .capacity = entries.len };
    defer setup.auth_probes = .empty;
    const snapshot = effectiveRemoteSnapshot(&setup);
    try std.testing.expectEqual(ProviderReadiness.ready, snapshot.forProvider(.claude));
    try std.testing.expectEqual(ProviderReadiness.signed_out, snapshot.forProvider(.cursor));
    // Another runtime's probe never applies; a missing CLI stays missing.
    try std.testing.expectEqual(ProviderReadiness.unavailable, snapshot.forProvider(.opencode));
    try std.testing.expectEqual(ProviderReadiness.missing, snapshot.forProvider(.codex));
    try std.testing.expect(!probeDue(&setup, "cloud", .claude, 5 + auth_probe.PROBE_INTERVAL_MS - 1));
    try std.testing.expect(probeDue(&setup, "cloud", .claude, 5 + auth_probe.PROBE_INTERVAL_MS));
    try std.testing.expect(probeDue(&setup, "cloud", .grok, 0));
}

test "remote provider status maps to dialog readiness" {
    const json =
        \\{"jsonrpc":"2.0","id":7,"result":{"runtime_id":"r","instance_id":"i","probed_at_ms":1,"providers":[
        \\{"provider":"claude","label":"Claude","installed":true,"state":"unknown","authentication":"unknown"},
        \\{"provider":"codex","label":"Codex","installed":false,"state":"missing","authentication":"unknown"},
        \\{"provider":"cursor","label":"Cursor","installed":true,"state":"ready","authentication":"authenticated"},
        \\{"provider":"opencode","label":"OpenCode","installed":true,"state":"unknown","authentication":"unauthenticated"},
        \\{"provider":"amp","label":"Amp","installed":true,"state":"unknown","authentication":"unknown"}]}}
    ;
    const snapshot = try parseRemoteStatus(std.testing.allocator, json);
    try std.testing.expectEqual(ProviderReadiness.unavailable, snapshot.forProvider(.claude));
    try std.testing.expectEqual(ProviderReadiness.missing, snapshot.forProvider(.codex));
    try std.testing.expectEqual(ProviderReadiness.ready, snapshot.forProvider(.cursor));
    try std.testing.expectEqual(ProviderReadiness.signed_out, snapshot.forProvider(.opencode));
    // Not reported: unverified, never "checking" forever.
    try std.testing.expectEqual(ProviderReadiness.unavailable, snapshot.forProvider(.grok));
    const rejected = try parseRemoteStatus(std.testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":7,\"error\":{\"code\":\"capability_unavailable\",\"message\":\"no\"}}");
    try std.testing.expectEqual(ProviderReadiness.unavailable, rejected.forProvider(.claude));
}

test "remote commands are POSIX and remote notes wait for the remote check" {
    try std.testing.expectEqualStrings(headless.provider_install.installShell(.claude), remoteCommand(.claude, true));
    try std.testing.expectEqualStrings("claude auth login", remoteCommand(.claude, false));
    try std.testing.expect(std.mem.indexOf(u8, remoteCommand(.codex, false), "--device-auth") != null);

    var setup: Setup = .{};
    setup.target_profile_id = @constCast("cloud");
    defer setup.target_profile_id = null;
    setup.notes[@intFromEnum(Provider.claude)] = .sign_in_finished;
    setup.awaited_generation = requestRemoteRecheck(&setup);
    var local: ProviderReadinessSnapshot = .{};
    local.claude = .ready;
    // This computer's check never resolves a remote command's note.
    noteReadinessCompleted(&setup, local, 99);
    try std.testing.expectEqual(RowNote.sign_in_finished, setup.note(.claude));
    var remote = unverifiedSnapshot();
    remote.claude = .unavailable;
    resolveRemoteNotes(&setup, remote, setup.awaited_generation);
    // The runtime cannot verify accounts: a 0-exit sign-in reads as success.
    try std.testing.expectEqual(RowNote.signed_in_unverified, setup.note(.claude));
    try std.testing.expect(!signedInThisSession(&setup, "cloud", .claude));
}

test "post-command readiness resolves the row note" {
    try std.testing.expectEqual(RowNote.installed_sign_in_next, resolvedNote(.install_finished, .signed_out, null));
    try std.testing.expectEqual(RowNote.still_signed_out, resolvedNote(.sign_in_finished, .signed_out, null));
    try std.testing.expectEqual(RowNote.not_on_path, resolvedNote(.install_finished, .missing, null));
    try std.testing.expectEqual(RowNote.needs_node, resolvedNote(.install_finished, .missing, .node));
    try std.testing.expectEqual(RowNote.unverified, resolvedNote(.sign_in_finished, .unavailable, null));
    try std.testing.expectEqual(RowNote.none, resolvedNote(.install_finished, .ready, null));
    try std.testing.expectEqual(RowNote.install_finished, resolvedNote(.install_finished, .checking, null));
    try std.testing.expectEqual(RowNote.copied, resolvedNote(.copied, .signed_out, null));
}

test "notes wait for the readiness check that started after the command" {
    var setup: Setup = .{};
    setup.notes[@intFromEnum(Provider.codex)] = .install_finished;
    setup.awaited_generation = 4;
    var snapshot: ProviderReadinessSnapshot = .{};
    snapshot.codex = .signed_out;
    // A check that was already in flight when the command exited.
    noteReadinessCompleted(&setup, snapshot, 3);
    try std.testing.expectEqual(RowNote.install_finished, setup.note(.codex));
    noteReadinessCompleted(&setup, snapshot, 4);
    try std.testing.expectEqual(RowNote.installed_sign_in_next, setup.note(.codex));
    try std.testing.expectEqual(@as(u32, 0), setup.awaited_generation);
}

test "setup rank prefers ready, then installed, then missing" {
    var snapshot: ProviderReadinessSnapshot = .{};
    snapshot.codex = .missing;
    snapshot.pi = .signed_out;
    snapshot.claude = .missing;
    snapshot.requirements[@intFromEnum(Provider.claude)] = .node;
    snapshot.cursor = .ready;
    try std.testing.expectEqual(@as(u8, 0), snapshot.setupRank(.cursor));
    try std.testing.expectEqual(@as(u8, 1), snapshot.setupRank(.pi));
    try std.testing.expectEqual(@as(u8, 2), snapshot.setupRank(.claude));
    try std.testing.expectEqual(@as(u8, 3), snapshot.setupRank(.codex));
    try std.testing.expect(snapshot.installedForProvider(.claude));
    try std.testing.expect(!snapshot.installedForProvider(.codex));
    // Still-checking providers are neither ranked down nor counted installed.
    try std.testing.expectEqual(@as(u8, 0), snapshot.setupRank(.opencode));
    try std.testing.expect(!snapshot.installedForProvider(.opencode));
}
