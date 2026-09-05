const std = @import("std");
const builtin = @import("builtin");
const sdl = @import("zsdl3");
const ghostty_vt = @import("engine.zig");
pub const RenderState = ghostty_vt.RenderState;
const keybinds = @import("../app/keybinds.zig");
const process_env = @import("../platform/env.zig");
const platform_runtime = @import("platform_runtime");
const daemon_client = @import("../daemon/client.zig");
const session_protocol = @import("headless").session_protocol;
const stb_image = @import("../media/stb_image.zig");
const theme = @import("../ui/theme.zig");
const runtime_log = @import("../runtime/log.zig");

const log = std.log.scoped(.native_terminal);

pub const DEFAULT_DOCK_HEIGHT: f32 = 136.0;
pub const MIN_DOCK_HEIGHT: f32 = 96.0;
pub const MAX_DOCK_HEIGHT: f32 = 900.0;
/// Shared persisted/runtime pane-coordinate bound; matches daemon validation.
pub const MAX_PANE_ID: u32 = 65_535;
/// Detach is best-effort teardown after terminal identity has already been
/// persisted; an unhealthy daemon must not hold the process open indefinitely.
const SESSION_DETACH_TIMEOUT_MS: u32 = 750;

pub const TerminalKey = enum {
    enter,
    escape,
    tab,
    up,
    down,
    left,
    right,
    home,
    end,
    pageup,
    pagedown,
    backspace,
    delete,
    space,
    f1,
    f2,
    f3,
    f4,
    f5,
    f6,
    f7,
    f8,
    f9,
    f10,
    f11,
    f12,
    a,
    b,
    c,
    d,
    e,
    f,
    g,
    h,
    i,
    j,
    k,
    l,
    m,
    n,
    o,
    p,
    q,
    r,
    s,
    t,
    u,
    v,
    w,
    x,
    y,
    z,
    @"0",
    @"1",
    @"2",
    @"3",
    @"4",
    @"5",
    @"6",
    @"7",
    @"8",
    @"9",

    pub fn parse(value: []const u8) ?TerminalKey {
        inline for (std.meta.fields(TerminalKey)) |field| {
            if (std.ascii.eqlIgnoreCase(value, field.name)) return @enumFromInt(field.value);
        }
        return null;
    }

    pub fn text(self: TerminalKey) []const u8 {
        return @tagName(self);
    }
};

pub const TerminalKeyModifiers = packed struct(u4) {
    ctrl: bool = false,
    alt: bool = false,
    shift: bool = false,
    super: bool = false,
};

pub const TerminalKeyChord = struct {
    key: TerminalKey,
    modifiers: TerminalKeyModifiers = .{},

    pub const ParseError = error{
        EmptyChord,
        EmptyComponent,
        DuplicateModifier,
        MultipleKeys,
        MissingKey,
        UnsupportedKey,
    };

    pub fn parse(value: []const u8) ParseError!TerminalKeyChord {
        if (value.len == 0) return error.EmptyChord;
        var result: TerminalKeyChord = undefined;
        result.modifiers = .{};
        var parsed_key: ?TerminalKey = null;
        var parts = std.mem.splitScalar(u8, value, '+');
        while (parts.next()) |part| {
            if (part.len == 0) return error.EmptyComponent;
            if (std.ascii.eqlIgnoreCase(part, "ctrl") or std.ascii.eqlIgnoreCase(part, "control")) {
                if (result.modifiers.ctrl) return error.DuplicateModifier;
                result.modifiers.ctrl = true;
            } else if (std.ascii.eqlIgnoreCase(part, "alt") or std.ascii.eqlIgnoreCase(part, "option")) {
                if (result.modifiers.alt) return error.DuplicateModifier;
                result.modifiers.alt = true;
            } else if (std.ascii.eqlIgnoreCase(part, "shift")) {
                if (result.modifiers.shift) return error.DuplicateModifier;
                result.modifiers.shift = true;
            } else if (std.ascii.eqlIgnoreCase(part, "super") or
                std.ascii.eqlIgnoreCase(part, "cmd") or
                std.ascii.eqlIgnoreCase(part, "command"))
            {
                if (result.modifiers.super) return error.DuplicateModifier;
                result.modifiers.super = true;
            } else {
                if (parsed_key != null) return error.MultipleKeys;
                parsed_key = TerminalKey.parse(part) orelse return error.UnsupportedKey;
            }
        }
        result.key = parsed_key orelse return error.MissingKey;
        return result;
    }
};

const SESSION_SUPPORTED = builtin.os.tag == .linux or builtin.os.tag == .macos or builtin.os.tag == .windows;
const LOCAL_PTY_SUPPORTED = builtin.os.tag != .windows;
const LocalPtyFd = if (builtin.os.tag == .windows) c_int else std.posix.fd_t;
const LocalPtyPid = if (builtin.os.tag == .windows) c_int else std.posix.pid_t;
const INITIAL_COLS: u16 = 96;
const INITIAL_ROWS: u16 = 12;
const MIN_COLS: u16 = 24;
const MIN_ROWS: u16 = 4;
const MAX_COLS: u16 = 320;
const MAX_ROWS: u16 = 120;
pub const CELL_PIXEL_WIDTH: u32 = 9;
pub const CELL_PIXEL_HEIGHT: u32 = 18;
const DEFAULT_FONT_SCALE: f32 = 1.0;
const MIN_FONT_SCALE: f32 = 0.75;
const MAX_FONT_SCALE: f32 = 3.3333333;
const FONT_SCALE_STEP: f32 = 0.125;
const WHEEL_SCROLL_LINES: f32 = 3.0;
const KEY_SCROLL_LINES: isize = 3;
const OUTPUT_RING_CAPACITY: usize = 256 * 1024;
const DAEMON_REPLAY_MAX_BYTES: usize = 512 * 1024;
const DAEMON_ATTACH_REPLAY_MAX_BYTES: usize = 8 * 1024;
// JSON may encode one terminal byte as a six-byte \u00XX escape. Keep enough
// headroom for worst-case text plus the fixed session metadata.
const DAEMON_TAIL_RESPONSE_OVERHEAD_BYTES: usize = 64 * 1024;
// Match Ghostty's app default so normal high-resolution PNGs do not exceed
// libghostty-vt's intentionally conservative 10 MB embedder default.
const KITTY_IMAGE_STORAGE_LIMIT: usize = 320 * 1000 * 1000;

pub fn configureGhosttySystem() void {
    // The Zig consumer build intentionally leaves host-dependent services
    // unset. Kitty PNG transmission needs an embedder-provided decoder.
    ghostty_vt.sys.decode_png = decodeTerminalPng;
}

fn decodeTerminalPng(allocator: std.mem.Allocator, bytes: []const u8) ghostty_vt.sys.DecodeError!ghostty_vt.sys.Image {
    const loaded = stb_image.loadFromMemory(bytes) catch return error.InvalidData;
    defer loaded.deinit();
    if (loaded.width <= 0 or loaded.height <= 0) return error.InvalidData;
    const width: u32 = @intCast(loaded.width);
    const height: u32 = @intCast(loaded.height);
    const pixel_count = std.math.mul(usize, width, height) catch return error.InvalidData;
    const byte_len = std.math.mul(usize, pixel_count, 4) catch return error.InvalidData;
    return .{
        .width = width,
        .height = height,
        .data = try allocator.dupe(u8, loaded.pixels[0..byte_len]),
    };
}

// Consecutive tail failures tolerated before declaring the daemon gone.
// ~2 seconds at display rate; see daemon_poll_failures for why one miss
// must not trigger a revive.
const DAEMON_POLL_FAILURE_LIMIT: u32 = 120;
// Automatic recovery preserves the stopped VT model between attempts. A shell
// that keeps dying backs off exponentially; a healthy shell must stay alive
// long enough to prove the recovery before the failure streak is forgotten.
const AUTO_RESTART_BASE_DELAY_MS: i64 = 1_000;
const AUTO_RESTART_MAX_DELAY_MS: i64 = 30_000;
const AUTO_RESTART_HEALTHY_RESET_MS: i64 = 10_000;
const LOCAL_TERMINAL_VIEW_RESET = "\x1b[?1049l\x1b[?1047l\x1b[?47l\x1b[0m\x1b[2J\x1b[H";
const LOCAL_TERMINAL_SCREEN_CLEAR = "\x1b[0m\x1b[2J\x1b[H";
pub const DEFAULT_FONT_SIZE: f32 = @floatFromInt(CELL_PIXEL_HEIGHT);
// Darwin exposes the winsize setter under the BSD ioctl value, not std.c.T.IOCSWINSZ.
const TERMINAL_WINSIZE_IOCTL: c_int = switch (builtin.os.tag) {
    .macos => @bitCast(@as(u32, 0x80087467)),
    .windows => 0,
    else => @intCast(std.c.T.IOCSWINSZ),
};
const TERMINAL_GET_PGRP_IOCTL: ?c_int = switch (builtin.os.tag) {
    .linux => @intCast(std.c.T.IOCGPGRP),
    .macos => @bitCast(@as(u32, 0x40047477)),
    else => null,
};
const TerminalStream = @TypeOf((@as(*ghostty_vt.Terminal, undefined)).vtStream());
const TerminalHandler = @TypeOf((@as(*ghostty_vt.Terminal, undefined)).vtHandler());
// lib_vt does not re-export the clipboard module, so recover the OSC 52
// write types from the effect signature to keep the pin the single source.
const ClipboardWriteFn = @typeInfo(@typeInfo(@FieldType(@FieldType(TerminalHandler, "effects"), "clipboard_write")).optional.child).pointer.child;
const ClipboardWrite = @typeInfo(ClipboardWriteFn).@"fn".params[1].type.?;
const ClipboardWriteResult = @typeInfo(ClipboardWriteFn).@"fn".return_type.?;
const DeviceAttributes = @typeInfo(
    std.meta.Child(std.meta.Child(@TypeOf(TerminalHandler.Effects.readonly.device_attributes))),
).@"fn".return_type.?;
const ColorScheme = std.meta.Child(
    @typeInfo(
        std.meta.Child(std.meta.Child(@TypeOf(TerminalHandler.Effects.readonly.color_scheme))),
    ).@"fn".return_type.?,
);
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

const Session = if (SESSION_SUPPORTED) UnixSession else UnsupportedSession;
pub const MIN_SPLIT_RATIO: f32 = 0.12;

const DaemonTailBatchRequest = struct {
    id: []const u8,
    attach_id: []const u8,
    offset: usize,
    max_bytes: usize,
};

/// Coalesces same-frame daemon tails and reuses the request connection without
/// changing terminal poll cadence.
pub const DaemonPollBatch = struct {
    sessions: std.ArrayList(*Session) = .empty,
    requests: std.ArrayList(DaemonTailBatchRequest) = .empty,
    response_scratch: std.ArrayList(u8) = .empty,
    last_response: std.ArrayList(u8) = .empty,
    connection: daemon_client.ReusableRequestConnection = .{},

    pub fn deinit(self: *DaemonPollBatch, allocator: std.mem.Allocator) void {
        self.sessions.deinit(allocator);
        self.requests.deinit(allocator);
        self.response_scratch.deinit(allocator);
        self.last_response.deinit(allocator);
        self.connection.deinit();
    }

    pub fn reset(self: *DaemonPollBatch) void {
        self.sessions.clearRetainingCapacity();
        self.requests.clearRetainingCapacity();
    }

    pub fn prefetch(self: *DaemonPollBatch, allocator: std.mem.Allocator, pref_path: []const u8) !void {
        if (!SESSION_SUPPORTED or self.sessions.items.len == 0) return;

        self.requests.clearRetainingCapacity();
        try self.requests.ensureTotalCapacity(allocator, self.sessions.items.len);
        for (self.sessions.items) |session| {
            const initial_attach_replay = session.suppress_next_daemon_replay and session.remote_output_offset == 0;
            self.requests.appendAssumeCapacity(.{
                .id = session.session_id orelse continue,
                .attach_id = session.attach_id orelse "",
                .offset = session.remote_output_offset,
                .max_bytes = if (initial_attach_replay) DAEMON_ATTACH_REPLAY_MAX_BYTES else DAEMON_REPLAY_MAX_BYTES,
            });
        }
        if (self.requests.items.len == 0) return;

        try self.response_scratch.ensureTotalCapacity(allocator, daemon_client.MAX_RESPONSE_BYTES);
        self.response_scratch.items.len = daemon_client.MAX_RESPONSE_BYTES;
        const response = try self.connection.requestAllocUsingBuffer(
            allocator,
            pref_path,
            "session.tail.batch",
            .{ .requests = self.requests.items },
            1,
            self.response_scratch.items,
        );
        defer allocator.free(response);
        if (cachedDaemonResponseMatches(&self.last_response, response) and
            daemonSessionsCanReuseResponse(self.sessions.items[0..self.requests.items.len]))
        {
            for (self.sessions.items[0..self.requests.items.len]) |session| {
                session.daemon_poll_failures = 0;
                session.daemon_prefetched_changed = false;
                session.daemon_prefetched = true;
            }
            return;
        }
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, response, .{});
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidSessionResponse;
        if (parsed.value.object.get("error")) |error_value| {
            if (error_value == .object) {
                const code = jsonString(error_value.object.get("code") orelse .null) orelse "";
                if (std.mem.eql(u8, code, "method_not_found")) return error.UnsupportedDaemonBatch;
            }
            return error.InvalidSessionResponse;
        }
        const result = parsed.value.object.get("result") orelse return error.InvalidSessionResponse;
        if (result != .object) return error.InvalidSessionResponse;
        const responses = result.object.get("responses") orelse return error.InvalidSessionResponse;
        if (responses != .array or responses.array.items.len != self.requests.items.len) return error.InvalidSessionResponse;

        for (self.sessions.items[0..self.requests.items.len], responses.array.items) |session, item| {
            const initial_attach_replay = session.suppress_next_daemon_replay and session.remote_output_offset == 0;
            session.daemon_prefetched_changed = try session.applyDaemonTailResponseValue(allocator, item, initial_attach_replay);
            session.daemon_prefetched = true;
        }
        if (daemonSessionsCanReuseResponse(self.sessions.items[0..self.requests.items.len])) {
            rememberDaemonResponse(&self.last_response, allocator, response);
        } else {
            self.last_response.clearRetainingCapacity();
        }
    }
};

fn cachedDaemonResponseMatches(cached: *const std.ArrayList(u8), response: []const u8) bool {
    return cached.items.len > 0 and std.mem.eql(u8, cached.items, response);
}

fn rememberDaemonResponse(cached: *std.ArrayList(u8), allocator: std.mem.Allocator, response: []const u8) void {
    cached.clearRetainingCapacity();
    cached.appendSlice(allocator, response) catch cached.clearRetainingCapacity();
}

fn daemonSessionsCanReuseResponse(sessions: []const *Session) bool {
    for (sessions) |session| {
        if (session.daemon_state != .attached or session.suppress_next_daemon_replay) return false;
    }
    return true;
}

test "daemon response cache only reuses an identical successful payload" {
    var cached: std.ArrayList(u8) = .empty;
    defer cached.deinit(std.testing.allocator);

    try std.testing.expect(!cachedDaemonResponseMatches(&cached, "quiet"));
    rememberDaemonResponse(&cached, std.testing.allocator, "quiet");
    try std.testing.expect(cachedDaemonResponseMatches(&cached, "quiet"));
    try std.testing.expect(!cachedDaemonResponseMatches(&cached, "changed"));

    rememberDaemonResponse(&cached, std.testing.allocator, "changed");
    try std.testing.expectEqualStrings("changed", cached.items);
}

pub const SplitAxis = enum(u8) {
    horizontal,
    vertical,
};

pub const SplitDirection = enum(u8) {
    up,
    down,
    left,
    right,
};

pub const TerminalLaunchKind = enum(u8) {
    shell,
    claude,
    opencode,
    codex,
    cursor,
    custom,
};

pub const TerminalLaunchProfile = struct {
    kind: TerminalLaunchKind = .shell,
    label: []const u8 = "",
    command: []const []const u8 = &.{},
};

pub const TerminalRevivePolicy = session_protocol.RevivePolicy;

fn daemonSessionNeedsLaunchFallback(
    revive_policy: TerminalRevivePolicy,
    attached_existing_session: bool,
) bool {
    return !attached_existing_session and revive_policy == .attach_or_create;
}

test "daemon recreation requests launch fallback only for a missing persisted session" {
    try std.testing.expect(daemonSessionNeedsLaunchFallback(.attach_or_create, false));
    try std.testing.expect(!daemonSessionNeedsLaunchFallback(.attach_or_create, true));
    try std.testing.expect(!daemonSessionNeedsLaunchFallback(.restart, false));
    try std.testing.expect(!daemonSessionNeedsLaunchFallback(.attach_only, false));
}

pub const SessionSnapshot = struct {
    running: bool,
    confirmed_exit: bool = false,
    exit_code: ?u32 = null,
    signal: ?u32 = null,
};

pub const SessionLifecycleSnapshot = struct {
    session_id: []const u8,
    snapshot: SessionSnapshot,
};

pub const SessionTeardownReason = enum {
    tab_closed,
    pane_closed,
    restarted,
    tui_reopened,
    workspace_closed,

    pub fn description(self: SessionTeardownReason) []const u8 {
        return switch (self) {
            .tab_closed => "terminal tab closed",
            .pane_closed => "terminal pane closed",
            .restarted => "terminal restarted",
            .tui_reopened => "agent TUI reopened",
            .workspace_closed => "workspace closed",
        };
    }
};

pub const SessionTeardown = struct {
    session: *Session,
    persisted_session_id: ?[]u8,
    reason: SessionTeardownReason,
    cancellation_initiated: bool = false,

    pub fn sessionId(self: *const SessionTeardown) ?[]const u8 {
        return preferredTeardownSessionId(self.session.sessionId(), self.persisted_session_id);
    }

    pub fn poll(self: *SessionTeardown, allocator: std.mem.Allocator) !?SessionTeardownCompletion {
        var snapshot = self.session.snapshot();
        if (resolveSessionTeardown(snapshot, self.cancellation_initiated, self.reason)) |completion| return completion;
        if (self.session.teardownSessionMissing()) return .{
            .exit_code = null,
            .signal = null,
            .cancellation_reason = null,
        };
        _ = try self.session.poll(allocator);
        snapshot = self.session.snapshot();
        if (resolveSessionTeardown(snapshot, self.cancellation_initiated, self.reason)) |completion| return completion;
        // A daemon "missing" response is definitive for this detached
        // session. Keeping it pending cannot recover the terminal and would
        // tail the absent session every frame forever.
        if (self.session.teardownSessionMissing()) return .{
            .exit_code = null,
            .signal = null,
            .cancellation_reason = null,
        };
        if (!self.cancellation_initiated and sessionTeardownNeedsTermination(snapshot)) {
            self.cancellation_initiated = self.session.terminate();
            snapshot = self.session.snapshot();
        }
        return resolveSessionTeardown(snapshot, self.cancellation_initiated, self.reason);
    }

    pub fn deinit(self: *SessionTeardown, allocator: std.mem.Allocator) void {
        self.session.deinit(allocator);
        allocator.destroy(self.session);
        if (self.persisted_session_id) |session_id| allocator.free(session_id);
    }
};

pub const SessionTeardownCompletion = struct {
    exit_code: ?u32,
    signal: ?u32,
    cancellation_reason: ?[]const u8,
};

pub const RuntimeProcessSnapshot = struct {
    pid: ?u32 = null,
    process_group: ?u32 = null,
    started_at_ms: i64 = 0,
    running: bool,
    foreground: bool,
    launch_kind: TerminalLaunchKind,
};

fn shellOwnsForeground(shell_pid: ?usize, foreground_pid: ?usize) bool {
    const shell = shell_pid orelse return false;
    const foreground = foreground_pid orelse return false;
    return shell > 0 and foreground == shell;
}

test "agent exit requires confirmed shell foreground ownership" {
    try std.testing.expect(shellOwnsForeground(101, 101));
    try std.testing.expect(!shellOwnsForeground(101, 202));
    try std.testing.expect(!shellOwnsForeground(101, null));
    try std.testing.expect(!shellOwnsForeground(null, 101));
    try std.testing.expect(!shellOwnsForeground(0, 0));
}

pub const NotificationEvent = struct {
    session_id: []const u8,
    pane_id: u32,
    title: []const u8 = "",
    body: []const u8 = "",
    attention: bool = true,
};

pub const TerminalScrollbar = ghostty_vt.PageList.Scrollbar;

const SessionCreateOptions = struct {
    cwd: []const u8,
    cols: u16,
    rows: u16,
    profile: TerminalLaunchProfile = .{},
    restored_modes: ?PersistedTerminalModes = null,
    session_id: ?[]const u8 = null,
    pref_path: ?[]const u8 = null,
    project_id: []const u8 = "",
    project_path: []const u8 = "",
    dock_id: u32 = 0,
    pane_id: u32 = 0,
    revive_policy: TerminalRevivePolicy = .attach_or_create,
};

pub const PersistedWorkspace = struct {
    active_tab_index: usize = 0,
    font_scale: ?f32 = null,
    tabs: []const PersistedTab = &.{},
};

pub const PersistedTab = struct {
    title: ?[]const u8 = null,
    observed_title: ?[]const u8 = null,
    pinned_title: ?[]const u8 = null,
    pinned_provider: ?[]const u8 = null,
    agent_history_at: i64 = 0,
    active_pane_id: u32 = 0,
    root_node_id: u32 = 0,
    nodes: []const PersistedNode = &.{},
};

pub const PersistedNodeKind = enum(u8) {
    leaf,
    split,
};

pub const PersistedMouseEvent = enum(u8) {
    none,
    x10,
    normal,
    button,
    any,
};

pub const PersistedMouseFormat = enum(u8) {
    x10,
    utf8,
    sgr,
    urxvt,
    sgr_pixels,
};

pub const PersistedTerminalModes = struct {
    alternate_screen: bool = false,
    mouse_event: PersistedMouseEvent = .none,
    mouse_format: PersistedMouseFormat = .x10,
};

pub const PersistedNode = struct {
    node_id: u32,
    kind: PersistedNodeKind,
    pane_id: u32 = 0,
    session_id: ?[]const u8 = null,
    launch_kind: ?TerminalLaunchKind = null,
    launch_label: ?[]const u8 = null,
    launch_command: []const []const u8 = &.{},
    revive_policy: ?TerminalRevivePolicy = null,
    terminal_modes: ?PersistedTerminalModes = null,
    axis: ?SplitAxis = null,
    ratio: ?f32 = null,
    first_node_id: ?u32 = null,
    second_node_id: ?u32 = null,
};

const AutoRestartBackoff = struct {
    attempts: u8 = 0,
    retry_after_ms: i64 = 0,
    healthy_since_ms: ?i64 = null,
    stopped_since_ms: ?i64 = null,

    fn reserve(self: *AutoRestartBackoff, now_ms: i64) bool {
        if (now_ms < self.retry_after_ms) return false;
        self.attempts +|= 1;
        self.retry_after_ms = now_ms +| autoRestartDelayMs(self.attempts);
        self.healthy_since_ms = null;
        self.stopped_since_ms = null;
        return true;
    }

    /// Starts the retry delay after creation finishes. Some creation paths are
    /// explicit user actions and do not call `reserve`; without this arm, a
    /// short-lived shell can have its parsed exit output discarded immediately.
    fn armAfterCreate(self: *AutoRestartBackoff, now_ms: i64, running: bool) void {
        if (self.attempts == 0) self.attempts = 1;
        self.retry_after_ms = @max(
            self.retry_after_ms,
            now_ms +| autoRestartDelayMs(self.attempts),
        );
        self.healthy_since_ms = null;
        self.stopped_since_ms = if (running) null else now_ms;
    }

    fn observeHealth(self: *AutoRestartBackoff, now_ms: i64, running: bool) void {
        if (!running) {
            self.healthy_since_ms = null;
            if (self.stopped_since_ms == null) {
                self.stopped_since_ms = now_ms;
                self.retry_after_ms = @max(
                    self.retry_after_ms,
                    now_ms +| autoRestartDelayMs(@max(self.attempts, 1)),
                );
            }
            return;
        }
        self.stopped_since_ms = null;
        if (self.attempts == 0) return;

        const healthy_since_ms = self.healthy_since_ms orelse {
            self.healthy_since_ms = now_ms;
            return;
        };
        if (now_ms < healthy_since_ms or now_ms - healthy_since_ms < AUTO_RESTART_HEALTHY_RESET_MS) return;
        self.* = .{};
    }
};

pub const PaneLeaf = struct {
    id: u32,
    session: ?*Session = null,
    session_id: ?[]u8 = null,
    launch_kind: ?TerminalLaunchKind = null,
    launch_label: ?[]u8 = null,
    launch_command: []const []const u8 = &.{},
    revive_policy: TerminalRevivePolicy = .attach_or_create,
    restored_modes: ?PersistedTerminalModes = null,
};

pub const PaneSplit = struct {
    axis: SplitAxis,
    ratio: f32 = 0.5,
    first: *PaneNode,
    second: *PaneNode,
};

pub const PaneNode = union(enum) {
    leaf: PaneLeaf,
    split: PaneSplit,
};

const PaneRect = struct {
    pane_id: u32,
    min: [2]f32,
    max: [2]f32,
};

const PaneFocusCandidate = struct {
    pane_id: u32,
    overlap: f32,
    primary_distance: f32,
    secondary_distance: f32,
};

pub const Tab = struct {
    id: u32,
    title: ?[]u8 = null,
    /// Last non-empty OSC title observed for the active pane's program (e.g. an
    /// agent's session summary). Persisted so the label survives a Verde restart
    /// even before the program re-emits its title.
    observed_title: ?[]u8 = null,
    /// Externally-pinned title from a notify hook (e.g. Codex, which sets its
    /// OSC title to the folder name and has no session-summary field). Kept
    /// separate from `observed_title` so the live OSC stream can't overwrite it,
    /// and preferred over the OSC title when labeling the pane. Persisted.
    pinned_title: ?[]u8 = null,
    /// Provider tag name (e.g. "codex", "claude") of the agent last seen running
    /// in this tab, from a notify hook. Persisted so the sidebar can draw the
    /// provider logo after a restart, before the agent process is revived (its
    /// foreground process name isn't available until then).
    pinned_provider: ?[]u8 = null,
    /// Last user-submitted input in an explicitly tagged agent TUI. A nonzero
    /// value enrolls this tab in workspace history and survives restarts.
    agent_history_at: i64 = 0,
    root: *PaneNode,
    active_pane_id: u32,

    fn deinit(self: *Tab, allocator: std.mem.Allocator) void {
        if (self.title) |title| allocator.free(title);
        if (self.observed_title) |observed| allocator.free(observed);
        if (self.pinned_title) |pinned| allocator.free(pinned);
        if (self.pinned_provider) |pinned| allocator.free(pinned);
        deinitPaneNode(self.root, allocator);
    }
};

pub const Dock = struct {
    visible: bool = false,
    preferred_height: f32 = DEFAULT_DOCK_HEIGHT,
    font_scale: f32 = DEFAULT_FONT_SCALE,
    cwd: ?[]u8 = null,
    pref_path: ?[]u8 = null,
    session_dock_id: u32 = 0,
    tabs: std.ArrayList(Tab) = .empty,
    active_tab_index: usize = 0,
    next_tab_id: u32 = 1,
    next_pane_id: u32 = 1,
    rename_tab_id: ?u32 = null,
    rename_storage: [96:0]u8 = std.mem.zeroes([96:0]u8),
    workspace_changed: bool = false,
    focus_requested: bool = false,
    orphan_prune_done: bool = false,
    launch_profile: TerminalLaunchProfile = .{},
    auto_restart_backoff: AutoRestartBackoff = .{},
    pending_session_teardowns: std.ArrayList(SessionTeardown) = .empty,

    pub fn init(_: std.mem.Allocator) !Dock {
        return .{};
    }

    pub fn setDefaultFontSize(self: *Dock, font_size: f32) void {
        self.font_scale = fontScaleForFontSize(font_size);
    }

    pub fn deinit(self: *Dock, allocator: std.mem.Allocator) void {
        if (self.cwd) |cwd| {
            allocator.free(cwd);
            self.cwd = null;
        }
        if (self.pref_path) |pref_path| {
            allocator.free(pref_path);
            self.pref_path = null;
        }
        for (self.tabs.items) |*tab| {
            tab.deinit(allocator);
        }
        self.tabs.deinit(allocator);
        for (self.pending_session_teardowns.items) |*teardown| teardown.deinit(allocator);
        self.pending_session_teardowns.deinit(allocator);
    }

    /// Moves live emulator ownership into a freshly restored layout by stable
    /// daemon identity. Persisted tabs and pane geometry remain authoritative.
    pub fn transferRuntimeFrom(self: *Dock, current: *Dock) usize {
        var transferred: usize = 0;
        for (current.tabs.items) |*tab| {
            transferPaneNodeSessions(tab.root, self, &transferred);
        }
        if (transferred == 0 and current.pending_session_teardowns.items.len == 0) return 0;

        std.mem.swap(@TypeOf(self.cwd), &self.cwd, &current.cwd);
        std.mem.swap(@TypeOf(self.pref_path), &self.pref_path, &current.pref_path);
        std.mem.swap(u32, &self.session_dock_id, &current.session_dock_id);
        std.mem.swap(bool, &self.orphan_prune_done, &current.orphan_prune_done);
        std.mem.swap(AutoRestartBackoff, &self.auto_restart_backoff, &current.auto_restart_backoff);
        std.mem.swap(
            @TypeOf(self.pending_session_teardowns),
            &self.pending_session_teardowns,
            &current.pending_session_teardowns,
        );
        self.focus_requested = self.focus_requested or current.focus_requested;
        current.focus_requested = false;
        self.workspace_changed = self.workspace_changed or current.workspace_changed;
        current.workspace_changed = false;
        return transferred;
    }

    pub fn toggle(self: *Dock) bool {
        self.visible = !self.visible;
        if (self.visible) self.focus_requested = true;
        return self.visible;
    }

    pub fn statusText(self: *const Dock, buf: *[192]u8) []const u8 {
        if (!SESSION_SUPPORTED) {
            return "Native shell embedding is only enabled on Linux and macOS.";
        }
        if (self.activePaneConst()) |pane| {
            if (pane.session) |session| {
                return session.statusText(buf);
            }
        }
        return if (self.visible) "Starting shell..." else "Hidden until toggled.";
    }

    pub fn effectiveHeight(self: *const Dock, available_height: f32) f32 {
        return clampHeightForAvailable(self.preferred_height, available_height);
    }

    pub fn setPreferredHeight(self: *Dock, available_height: f32, requested_height: f32) bool {
        const next_height = clampHeightForAvailable(requested_height, available_height);
        if (@abs(self.preferred_height - next_height) < 0.5) return false;
        self.preferred_height = next_height;
        return true;
    }

    pub fn ensureSession(self: *Dock, allocator: std.mem.Allocator, project_path: []const u8) !void {
        try self.ensureSessionWithContext(allocator, project_path, null, self.session_dock_id);
    }

    pub fn ensureSessionPersistent(
        self: *Dock,
        allocator: std.mem.Allocator,
        project_path: []const u8,
        pref_path: []const u8,
        dock_id: u32,
    ) !void {
        try self.ensureSessionWithContext(allocator, project_path, pref_path, dock_id);
    }

    fn ensureSessionWithContext(
        self: *Dock,
        allocator: std.mem.Allocator,
        project_path: []const u8,
        pref_path: ?[]const u8,
        dock_id: u32,
    ) !void {
        const cwd_changed = if (self.cwd) |cwd|
            !std.mem.eql(u8, cwd, project_path)
        else
            true;

        if (cwd_changed) {
            if (self.cwd) |cwd| allocator.free(cwd);
            self.cwd = try allocator.dupe(u8, project_path);
        }

        if (cwd_changed or self.session_dock_id != dock_id) self.orphan_prune_done = false;
        self.session_dock_id = dock_id;
        if (pref_path) |path| {
            const pref_changed = if (self.pref_path) |existing|
                !std.mem.eql(u8, existing, path)
            else
                true;
            if (pref_changed) {
                if (self.pref_path) |existing| allocator.free(existing);
                self.pref_path = try allocator.dupe(u8, path);
                self.orphan_prune_done = false;
            }
        }

        try self.ensureWorkspace(allocator);
        self.pruneOrphanDaemonSessions(allocator) catch |err| {
            log.debug("failed to prune orphan daemon terminal sessions for dock {d}: {s}", .{ self.session_dock_id, @errorName(err) });
        };
    }

    pub fn restartWithProfile(self: *Dock, allocator: std.mem.Allocator, cwd: []const u8, profile: TerminalLaunchProfile) !void {
        try self.restartWithProfileContext(allocator, cwd, profile, null, self.session_dock_id);
    }

    pub fn restartWithProfilePersistent(
        self: *Dock,
        allocator: std.mem.Allocator,
        cwd: []const u8,
        profile: TerminalLaunchProfile,
        pref_path: []const u8,
        dock_id: u32,
    ) !void {
        try self.restartWithProfileContext(allocator, cwd, profile, pref_path, dock_id);
    }

    fn restartWithProfileContext(
        self: *Dock,
        allocator: std.mem.Allocator,
        cwd: []const u8,
        profile: TerminalLaunchProfile,
        pref_path: ?[]const u8,
        dock_id: u32,
    ) !void {
        if (self.cwd) |old_cwd| allocator.free(old_cwd);
        self.cwd = try allocator.dupe(u8, cwd);
        self.session_dock_id = dock_id;
        if (pref_path) |path| {
            const pref_changed = if (self.pref_path) |existing|
                !std.mem.eql(u8, existing, path)
            else
                true;
            if (pref_changed) {
                if (self.pref_path) |existing| allocator.free(existing);
                self.pref_path = try allocator.dupe(u8, path);
            }
        }
        for (self.tabs.items) |*tab| try self.queuePaneSessionTeardowns(allocator, tab.root, .restarted);
        self.clearTabs(allocator);

        const previous_profile = self.launch_profile;
        self.launch_profile = profile;
        defer self.launch_profile = previous_profile;

        try self.tabs.append(allocator, try self.buildSinglePaneTabWithRevivePolicy(allocator, .restart));
        self.active_tab_index = self.tabs.items.len - 1;
        self.visible = true;
        self.workspace_changed = true;
        self.focus_requested = true;
    }

    pub fn poll(self: *Dock, allocator: std.mem.Allocator) !bool {
        var changed = false;
        var terminal_modes_changed = false;
        for (self.tabs.items) |*tab| {
            changed = (try pollPaneNode(tab.root, allocator, &terminal_modes_changed)) or changed;
            if (self.captureTabObservedTitle(allocator, tab)) changed = true;
        }
        const now_ms: i64 = @intCast(@divTrunc(platform_runtime.monotonicTimestampNs(), std.time.ns_per_ms));
        self.auto_restart_backoff.observeHealth(now_ms, self.hasRunningSession());
        if (terminal_modes_changed) self.workspace_changed = true;
        return changed;
    }

    pub fn appendDaemonPollSessions(self: *Dock, allocator: std.mem.Allocator, batch: *DaemonPollBatch) !void {
        if (!SESSION_SUPPORTED) return;
        for (self.tabs.items) |*tab| try appendDaemonPollSessionsFromNode(tab.root, allocator, batch);
    }

    /// Records an externally-provided title (e.g. from a Codex notify hook,
    /// which sets its OSC title to the folder and has no session-summary field)
    /// as the active tab's pinned title. Kept separate from observed_title so
    /// the live OSC stream can't overwrite it; persisted so it survives a
    /// restart. No-op when the title is empty or unchanged.
    pub fn setActiveTabPinnedTitle(self: *Dock, allocator: std.mem.Allocator, title: []const u8) bool {
        if (title.len == 0) return false;
        const tab = self.activeTab() orelse return false;
        if (tab.pinned_title) |old| {
            if (std.mem.eql(u8, old, title)) return false;
        }
        const dup = allocator.dupe(u8, title) catch return false;
        if (tab.pinned_title) |old| allocator.free(old);
        tab.pinned_title = dup;
        self.workspace_changed = true;
        return true;
    }

    pub fn activeTabPinnedTitle(self: *const Dock) ?[]const u8 {
        const tab = self.activeTabConst() orelse return null;
        return tab.pinned_title;
    }

    /// Clears an externally pinned title so the provider's live OSC title is
    /// authoritative again.
    pub fn clearActiveTabPinnedTitle(self: *Dock, allocator: std.mem.Allocator) bool {
        const tab = self.activeTab() orelse return false;
        const old = tab.pinned_title orelse return false;
        allocator.free(old);
        tab.pinned_title = null;
        self.workspace_changed = true;
        return true;
    }

    /// Records the provider (tag name) of the agent running in the active tab so
    /// the sidebar can draw its logo after a restart, before the process revives.
    pub fn setActiveTabPinnedProvider(self: *Dock, allocator: std.mem.Allocator, provider: []const u8) bool {
        if (provider.len == 0) return false;
        const tab = self.activeTab() orelse return false;
        if (tab.pinned_provider) |old| {
            if (std.mem.eql(u8, old, provider)) return false;
        }
        const dup = allocator.dupe(u8, provider) catch return false;
        if (tab.pinned_provider) |old| allocator.free(old);
        tab.pinned_provider = dup;
        self.workspace_changed = true;
        return true;
    }

    /// The provider tag name pinned on the active tab, if any (for the sidebar
    /// logo fallback when no live surface/foreground process is available).
    pub fn activeTabPinnedProvider(self: *const Dock) ?[]const u8 {
        const tab = self.activeTabConst() orelse return null;
        return tab.pinned_provider;
    }

    pub fn noteActiveTabAgentHistory(self: *Dock, timestamp: i64) bool {
        const tab = self.activeTab() orelse return false;
        if (tab.agent_history_at == timestamp) return false;
        tab.agent_history_at = timestamp;
        self.workspace_changed = true;
        return true;
    }

    pub fn activeTabAgentHistoryAt(self: *const Dock) i64 {
        const tab = self.activeTabConst() orelse return 0;
        return tab.agent_history_at;
    }

    /// Remembers the active pane's live OSC title on its tab so it can be shown
    /// (and persisted) even after a restart, before the program re-emits it.
    fn captureTabObservedTitle(self: *Dock, allocator: std.mem.Allocator, tab: *Tab) bool {
        const pane = findPaneLeaf(tab.root, tab.active_pane_id) orelse findFirstPaneLeaf(tab.root) orelse return false;
        const session = pane.session orelse return false;
        var buf: [96]u8 = undefined;
        const live = session.liveOscTitle(&buf) orelse return false;
        if (tab.observed_title) |old| {
            if (std.mem.eql(u8, old, live)) return false;
        }
        const dup = allocator.dupe(u8, live) catch return false;
        if (tab.observed_title) |old| allocator.free(old);
        tab.observed_title = dup;
        self.workspace_changed = true;
        return true;
    }

    pub fn rethemeSessions(self: *Dock, allocator: std.mem.Allocator) !void {
        for (self.tabs.items) |*tab| {
            try rethemePaneNode(tab.root, allocator);
        }
    }

    pub fn resizePaneToFit(self: *Dock, allocator: std.mem.Allocator, pane_id: u32, width: f32, height: f32) !void {
        const pane = self.findPaneById(pane_id) orelse return;
        if (pane.session) |session| {
            const cols = columnsForWidth(width, self.font_scale);
            const rows = rowsForHeight(height, self.font_scale);
            if (cols == 0 or rows == 0) {
                log.warn("skipping terminal resize for invalid pane size width={d:.2} height={d:.2}", .{ width, height });
                return;
            }
            try session.resize(
                allocator,
                cols,
                rows,
                scaledCellPixelWidth(self.font_scale),
                scaledCellPixelHeight(self.font_scale),
            );
            if (terminalLayoutDiagnosticsEnabled()) {
                runtime_log.diagnostic(
                    "terminal resizePaneToFit pane={d} rect={d:.1}x{d:.1} cells={d}x{d} session={d}x{d}",
                    .{ pane_id, width, height, cols, rows, session.cols, session.rows },
                );
            }
        }
    }

    pub fn reassertPaneDaemonSize(self: *Dock, allocator: std.mem.Allocator, pane_id: u32) !void {
        const pane = self.findPaneById(pane_id) orelse return;
        if (pane.session) |session| try session.reassertDaemonSizeIfDrifted(allocator);
    }

    pub fn activeRenderState(self: *const Dock) ?*const ghostty_vt.RenderState {
        if (self.activePaneConst()) |pane| {
            if (pane.session) |session| return session.renderState();
        }
        return null;
    }

    pub fn renderStateForPane(self: *const Dock, pane_id: u32) ?*const ghostty_vt.RenderState {
        const pane = self.findPaneByIdConst(pane_id) orelse return null;
        if (pane.session) |session| return session.renderState();
        return null;
    }

    pub fn terminalForPane(self: *Dock, pane_id: u32) ?*ghostty_vt.Terminal {
        const pane = self.findPaneById(pane_id) orelse return null;
        if (pane.session) |session| return &session.terminal;
        return null;
    }

    pub fn paneWantsMouseInput(self: *const Dock, pane_id: u32) bool {
        const pane = self.findPaneByIdConst(pane_id) orelse return false;
        if (pane.session) |session| return session.terminal.flags.mouse_event != .none;
        return false;
    }

    pub fn mouseShapeForPane(self: *const Dock, pane_id: u32) ?ghostty_vt.MouseShape {
        const pane = self.findPaneByIdConst(pane_id) orelse return null;
        if (pane.session) |session| return session.terminal.mouse_shape;
        return null;
    }

    pub fn scrollbarForPane(self: *Dock, pane_id: u32) ?TerminalScrollbar {
        const pane = self.findPaneById(pane_id) orelse return null;
        if (pane.session) |session| return session.scrollbar();
        return null;
    }

    pub fn markPaneRendered(self: *Dock, pane_id: u32) void {
        const pane = self.findPaneById(pane_id) orelse return;
        if (pane.session) |session| session.markRendered();
    }

    pub fn hasRunningSession(self: *const Dock) bool {
        for (self.tabs.items) |*tab| {
            if (paneNodeHasRunningSession(tab.root)) return true;
        }
        return false;
    }

    pub fn hasRestorableSession(self: *const Dock) bool {
        for (self.tabs.items) |*tab| {
            if (paneNodeHasSessionId(tab.root)) return true;
        }
        return false;
    }

    /// Returns whether a persisted daemon identity had to be recreated. The
    /// workspace owner uses this one-shot signal to restore commands that were
    /// originally typed into a long-lived shell, such as an agent TUI resume.
    pub fn takeDaemonSessionRecreated(self: *Dock) bool {
        var recreated = false;
        for (self.tabs.items) |*tab| {
            recreated = takeDaemonSessionRecreatedInNode(tab.root) or recreated;
        }
        return recreated;
    }

    /// Reserves one automatic recovery attempt while preventing a shell that
    /// exits immediately from being recreated on every main-loop iteration.
    pub fn reserveAutoRestart(self: *Dock, now_ms: i64) bool {
        if (!self.auto_restart_backoff.reserve(now_ms)) return false;
        runtime_log.diagnostic(
            "terminal automatic restart reserved dock={d} pane={?d} attempt={d} delay_ms={d}",
            .{
                self.session_dock_id,
                if (self.activePaneConst()) |pane| pane.id else null,
                self.auto_restart_backoff.attempts,
                autoRestartDelayMs(self.auto_restart_backoff.attempts),
            },
        );
        return true;
    }

    pub fn takeFocusRequest(self: *Dock) bool {
        const requested = self.focus_requested;
        self.focus_requested = false;
        return requested;
    }

    pub fn consumeWorkspaceChange(self: *Dock) bool {
        const changed = self.workspace_changed;
        self.workspace_changed = false;
        return changed;
    }

    pub fn handleTextInput(self: *Dock, input_text: []const u8) bool {
        if (input_text.len == 0) return false;
        if (builtin.os.tag != .macos and isAsciiTerminalText(input_text)) return false;
        if (self.activePane()) |pane| {
            if (pane.session) |session| {
                return session.writeInput(input_text) catch |err| {
                    log.warn("terminal text input failed: {s}", .{@errorName(err)});
                    return false;
                };
            }
        }
        return false;
    }

    pub fn writeInputToActivePane(self: *Dock, bytes: []const u8) !bool {
        if (bytes.len == 0) return false;
        const pane = self.activePane() orelse return false;
        const session = pane.session orelse return false;
        return try session.writeInput(bytes);
    }

    /// Sends one validated atomic key chord to the active session in this dock.
    pub fn writeKeyToActivePane(self: *Dock, chord: TerminalKeyChord) !bool {
        const pane = self.activePane() orelse return false;
        const session = pane.session orelse return false;
        return try session.writeKey(chord);
    }

    /// Pastes host-provided text into the active pane's running session,
    /// honoring bracketed-paste so TUI inputs are filled without executing.
    pub fn pasteTextToActivePane(self: *Dock, allocator: std.mem.Allocator, text: []const u8) !bool {
        if (text.len == 0) return false;
        const pane = self.activePane() orelse return false;
        const session = pane.session orelse return false;
        return try session.pasteText(allocator, text);
    }

    pub fn terminateActiveSession(self: *Dock) bool {
        const pane = self.activePane() orelse return false;
        const session = pane.session orelse return false;
        return session.terminate();
    }

    pub fn activeSessionSnapshot(self: *const Dock) ?SessionSnapshot {
        const pane = self.activePaneConst() orelse return null;
        const session = pane.session orelse return null;
        return session.snapshot();
    }

    /// True only after a live shell is confirmed to own the PTY again.
    /// Missing/stale attach metadata must not retire a restored agent.
    pub fn activeSessionAtShellPrompt(self: *const Dock, status_changed_at_ms: i64) bool {
        if (comptime Session == UnsupportedSession) return false;
        const pane = self.activePaneConst() orelse return false;
        const session = pane.session orelse return false;
        if (!session.running or session.launch_kind != .shell) return false;
        return switch (session.backend) {
            .daemon => session.daemon_state == .attached and
                session.daemon_process_observed_at_ms > status_changed_at_ms +| 500 and
                shellOwnsForeground(session.daemon_shell_pid, session.daemon_foreground_process_group),
            .local => blk: {
                if (platform_runtime.unixTimestampMs() <= status_changed_at_ms +| 500) break :blk false;
                if (!LOCAL_PTY_SUPPORTED) break :blk false;
                const ioctl_value = TERMINAL_GET_PGRP_IOCTL orelse break :blk false;
                var foreground: c_int = 0;
                if (std.c.ioctl(session.master_fd, ioctl_value, &foreground) != 0) break :blk false;
                break :blk foreground > 0 and foreground == session.child_pid;
            },
        };
    }

    /// Returns the process identity already cached by terminal polling. Shell
    /// panes appear only while a foreground command is active; custom/agent
    /// profiles represent the launched process itself.
    pub fn activeRuntimeProcessSnapshot(self: *const Dock) ?RuntimeProcessSnapshot {
        const pane = self.activePaneConst() orelse return null;
        const session = pane.session orelse return null;
        const snapshot = session.runtimeProcessSnapshot();
        if (snapshot.launch_kind == .shell and !snapshot.foreground) return null;
        return snapshot;
    }

    pub fn activeOutputTailAlloc(self: *const Dock, allocator: std.mem.Allocator, max_bytes: usize) !?[]u8 {
        const pane = self.activePaneConst() orelse return null;
        const session = pane.session orelse return null;
        return try session.outputTailAlloc(allocator, max_bytes);
    }

    /// Inspect only the live footer, independent of the user's scrollback view.
    /// This bounded, allocation-free read never scans transcript history.
    pub fn activeClaudeBackgroundShells(self: *const Dock) bool {
        const pane = self.activePaneConst() orelse return false;
        const session = pane.session orelse return false;
        if (comptime Session == UnsupportedSession) return false;
        if (!session.running) return false;
        return claudeBackgroundShells(&session.terminal);
    }

    pub fn activeScreenTextAlloc(self: *const Dock, allocator: std.mem.Allocator) !?[]u8 {
        const pane = self.activePaneConst() orelse return null;
        const session = pane.session orelse return null;
        return try session.screenTextAlloc(allocator);
    }

    pub fn activeGridSize(self: *const Dock) ?struct { cols: u16, rows: u16 } {
        const pane = self.activePaneConst() orelse return null;
        const session = pane.session orelse return null;
        return .{ .cols = session.cols, .rows = session.rows };
    }

    pub fn handleKeyDown(
        self: *Dock,
        allocator: std.mem.Allocator,
        keyboard: *const keybinds.NativeKeyboardConfig,
        event: *const sdl.KeyboardEvent,
    ) bool {
        if (terminalZoomDelta(event)) |delta| {
            self.font_scale = clampf(self.font_scale + delta, MIN_FONT_SCALE, MAX_FONT_SCALE);
            self.workspace_changed = true;
            return true;
        }

        if (self.handleWorkspaceShortcut(allocator, keyboard, event) catch |err| {
            log.warn("terminal workspace shortcut failed: {s}", .{@errorName(err)});
            return false;
        }) {
            return true;
        }

        if (self.activePane()) |pane| {
            if (pane.session) |session| {
                if (self.handleTerminalShortcut(allocator, session, event)) return true;
                return session.handleKeyDown(event) catch |err| {
                    log.warn("terminal key input failed: {s}", .{@errorName(err)});
                    return false;
                };
            }
        }
        return false;
    }

    fn handleTerminalShortcut(_: *Dock, allocator: std.mem.Allocator, session: *Session, event: *const sdl.KeyboardEvent) bool {
        if (!event.down) return false;
        if (terminalScrollShortcut(event, session.visibleRows())) |scroll| {
            session.scrollViewport(allocator, scroll) catch |err| {
                log.warn("terminal keyboard scroll failed: {s}", .{@errorName(err)});
                return false;
            };
            return true;
        }
        if (event.repeat) return false;
        if (terminalPasteShortcut(event)) {
            return session.pasteClipboard(allocator) catch |err| {
                log.warn("terminal paste failed: {s}", .{@errorName(err)});
                return true;
            };
        }
        if (terminalCopyShortcut(event)) {
            return session.copyScreenToClipboard(allocator) catch |err| {
                log.warn("terminal copy failed: {s}", .{@errorName(err)});
                return true;
            };
        }
        return false;
    }

    pub fn handleWheel(self: *Dock, allocator: std.mem.Allocator, pane_id: u32, wheel_y: f32, local_x: f32, local_y: f32, width: f32, height: f32) bool {
        const pane = self.findPaneById(pane_id) orelse return false;
        if (pane.session) |session| {
            return session.handleWheel(allocator, wheel_y, local_x, local_y, width, height) catch |err| {
                log.warn("terminal wheel scroll failed: {s}", .{@errorName(err)});
                return false;
            };
        }
        return false;
    }

    pub fn handleMouseButton(self: *Dock, pane_id: u32, button: u8, down: bool, local_x: f32, local_y: f32, width: f32, height: f32) bool {
        const pane = self.findPaneById(pane_id) orelse return false;
        if (pane.session) |session| {
            return session.handleMouseButton(button, down, local_x, local_y, width, height) catch |err| {
                log.warn("terminal mouse button failed: {s}", .{@errorName(err)});
                return false;
            };
        }
        return false;
    }

    pub fn handleMouseMotion(self: *Dock, pane_id: u32, button: ?u8, local_x: f32, local_y: f32, width: f32, height: f32) bool {
        const pane = self.findPaneById(pane_id) orelse return false;
        if (pane.session) |session| {
            return session.handleMouseMotion(button, local_x, local_y, width, height) catch |err| {
                log.warn("terminal mouse motion failed: {s}", .{@errorName(err)});
                return false;
            };
        }
        return false;
    }

    pub fn activeTab(self: *Dock) ?*Tab {
        if (self.tabs.items.len == 0 or self.active_tab_index >= self.tabs.items.len) return null;
        return &self.tabs.items[self.active_tab_index];
    }

    pub fn activeTabConst(self: *const Dock) ?*const Tab {
        if (self.tabs.items.len == 0 or self.active_tab_index >= self.tabs.items.len) return null;
        return &self.tabs.items[self.active_tab_index];
    }

    pub fn activePane(self: *Dock) ?*PaneLeaf {
        const tab = self.activeTab() orelse return null;
        return findPaneLeaf(tab.root, tab.active_pane_id) orelse findFirstPaneLeaf(tab.root);
    }

    pub fn activePaneConst(self: *const Dock) ?*const PaneLeaf {
        const tab = self.activeTabConst() orelse return null;
        return findPaneLeafConst(tab.root, tab.active_pane_id) orelse findFirstPaneLeafConst(tab.root);
    }

    /// Coordinate seam for validated daemon snapshot materialization.
    pub fn paneById(self: *Dock, pane_id: u32) ?*PaneLeaf {
        return self.findPaneById(pane_id);
    }

    /// Append one validated daemon-owned pane without round-tripping the whole
    /// dock through JSON. The caller owns coordinate bounds and collision caps.
    pub fn appendDaemonSessionPane(
        self: *Dock,
        allocator: std.mem.Allocator,
        pane_id: u32,
        session_id: []const u8,
    ) !*PaneLeaf {
        std.debug.assert(pane_id != 0);
        std.debug.assert(self.findPaneById(pane_id) == null);
        const node = try allocator.create(PaneNode);
        errdefer allocator.destroy(node);
        const owned_session_id = try allocator.dupe(u8, session_id);
        errdefer allocator.free(owned_session_id);
        node.* = .{ .leaf = .{
            .id = pane_id,
            .session_id = owned_session_id,
            .revive_policy = .attach_or_create,
        } };
        try self.tabs.append(allocator, .{
            .id = self.allocateTabId(),
            .root = node,
            .active_pane_id = pane_id,
        });
        self.next_pane_id = @max(self.next_pane_id, pane_id +| 1);
        return &node.leaf;
    }

    pub fn activeSessionId(self: *const Dock) ?[]const u8 {
        const pane = self.activePaneConst() orelse return null;
        if (pane.session) |session| {
            return session.sessionId();
        }
        return pane.session_id;
    }

    pub fn sessionLifecycleSnapshotsAlloc(self: *const Dock, allocator: std.mem.Allocator) ![]const SessionLifecycleSnapshot {
        var snapshots: std.ArrayList(SessionLifecycleSnapshot) = .empty;
        errdefer snapshots.deinit(allocator);
        for (self.tabs.items) |*tab| try collectPaneSessionLifecycleSnapshots(allocator, tab.root, &snapshots);
        return try snapshots.toOwnedSlice(allocator);
    }

    pub fn takeSessionTeardown(self: *Dock) ?SessionTeardown {
        if (self.pending_session_teardowns.items.len == 0) return null;
        return self.pending_session_teardowns.orderedRemove(0);
    }

    pub fn pendingSessionTeardownCount(self: *const Dock) usize {
        return self.pending_session_teardowns.items.len;
    }

    pub fn queueAllSessionTeardowns(self: *Dock, allocator: std.mem.Allocator, reason: SessionTeardownReason) !void {
        var session_count: usize = 0;
        for (self.tabs.items) |*tab| session_count += countPaneNodeSessions(tab.root);
        try self.pending_session_teardowns.ensureUnusedCapacity(allocator, session_count);
        for (self.tabs.items) |*tab| detachPaneNodeSessions(self, tab.root, reason);
    }

    pub fn takeActiveNotification(self: *Dock) ?NotificationEvent {
        const pane = self.activePane() orelse return null;
        const session = pane.session orelse return null;
        return session.takeNotification(pane.id);
    }

    pub fn clearNotificationForSession(self: *Dock, session_id: []const u8) bool {
        var cleared = false;
        for (self.tabs.items) |*tab| {
            if (clearNotificationInNode(tab.root, session_id)) cleared = true;
        }
        return cleared;
    }

    pub fn focusPane(self: *Dock, pane_id: u32) void {
        const tab = self.activeTab() orelse return;
        if (findPaneLeaf(tab.root, pane_id) == null) return;
        tab.active_pane_id = pane_id;
        self.workspace_changed = true;
        self.focus_requested = true;
    }

    pub fn focusAdjacentPane(self: *Dock, allocator: std.mem.Allocator, direction: SplitDirection) !bool {
        const tab = self.activeTab() orelse return false;
        const next_pane_id = try findAdjacentPaneId(allocator, tab.root, tab.active_pane_id, direction) orelse return false;
        if (next_pane_id == tab.active_pane_id) return false;
        tab.active_pane_id = next_pane_id;
        self.workspace_changed = true;
        self.focus_requested = true;
        return true;
    }

    pub fn selectTab(self: *Dock, index: usize) void {
        if (index >= self.tabs.items.len) return;
        self.active_tab_index = index;
        self.workspace_changed = true;
        self.focus_requested = true;
    }

    pub fn createTab(self: *Dock, allocator: std.mem.Allocator) !void {
        try self.tabs.append(allocator, try self.buildSinglePaneTab(allocator));
        self.active_tab_index = self.tabs.items.len - 1;
        self.workspace_changed = true;
        self.focus_requested = true;
    }

    pub fn createTabWithProfile(self: *Dock, allocator: std.mem.Allocator, profile: TerminalLaunchProfile) !void {
        const previous_profile = self.launch_profile;
        self.launch_profile = profile;
        defer self.launch_profile = previous_profile;
        try self.createTab(allocator);
    }

    pub fn closeTab(self: *Dock, allocator: std.mem.Allocator, index: usize) !void {
        if (index >= self.tabs.items.len) return;
        try self.queuePaneSessionTeardowns(allocator, self.tabs.items[index].root, .tab_closed);
        var removed = self.tabs.orderedRemove(index);
        removed.deinit(allocator);
        if (self.tabs.items.len == 0) {
            try self.tabs.append(allocator, try self.buildSinglePaneTab(allocator));
            self.active_tab_index = 0;
        } else if (self.active_tab_index >= self.tabs.items.len) {
            self.active_tab_index = self.tabs.items.len - 1;
        } else if (index <= self.active_tab_index and self.active_tab_index > 0) {
            self.active_tab_index -= 1;
        }
        self.workspace_changed = true;
        self.focus_requested = true;
    }

    pub fn closeActiveTab(self: *Dock, allocator: std.mem.Allocator) !void {
        if (self.active_tab_index >= self.tabs.items.len) return;
        try self.closeTab(allocator, self.active_tab_index);
    }

    pub fn splitActivePane(self: *Dock, allocator: std.mem.Allocator, direction: SplitDirection) !void {
        const tab = self.activeTab() orelse return;
        tab.active_pane_id = try self.replacePaneWithSplit(allocator, tab.root, tab.active_pane_id, direction);
        self.workspace_changed = true;
        self.focus_requested = true;
    }

    pub fn closeActivePaneOrTab(self: *Dock, allocator: std.mem.Allocator) !void {
        const tab = self.activeTab() orelse return;
        if (isSinglePaneTree(tab.root)) {
            if (self.tabs.items.len > 1) try self.closeActiveTab(allocator);
            return;
        }
        try self.closeActivePane(allocator);
    }

    pub fn closeActivePane(self: *Dock, allocator: std.mem.Allocator) !void {
        const tab = self.activeTab() orelse return;
        if (isSinglePaneTree(tab.root)) return;
        if (findPaneLeaf(tab.root, tab.active_pane_id)) |leaf| {
            try self.queuePaneLeafSessionTeardown(allocator, leaf, .pane_closed);
        }
        try removePaneFromTree(allocator, &tab.root, tab.active_pane_id);
        if (findPaneLeaf(tab.root, tab.active_pane_id) == null) {
            if (findFirstPaneLeaf(tab.root)) |leaf| tab.active_pane_id = leaf.id;
        }
        self.workspace_changed = true;
        self.focus_requested = true;
    }

    pub fn tabTitle(self: *const Dock, index: usize, buffer: *[96]u8) []const u8 {
        if (index >= self.tabs.items.len) return "";
        const tab = &self.tabs.items[index];
        if (tab.title) |tab_title| return tab_title;
        if (findPaneLeafConst(tab.root, tab.active_pane_id) orelse findFirstPaneLeafConst(tab.root)) |pane| {
            if (pane.session) |session| return session.tabTitle(buffer);
        }
        if (self.cwd) |cwd| return pathLabel(cwd);
        return "Shell";
    }

    /// Like `tabTitle`, but prefers a live label for whatever program is running
    /// in the active pane — its OSC title (e.g. an agent's session summary) or
    /// process name — over the cwd fallback. Used for compact labels such as the
    /// sidebar's open-pane list.
    pub fn activeProcessLabel(self: *const Dock, buffer: *[96]u8) []const u8 {
        if (self.activeTabConst()) |tab| {
            const session: ?*Session = blk: {
                const pane = findPaneLeafConst(tab.root, tab.active_pane_id) orelse findFirstPaneLeafConst(tab.root) orelse break :blk null;
                break :blk pane.session;
            };
            // 0. externally-pinned title (e.g. Codex notify hook). Wins over the
            //    OSC title because Codex sets its OSC title to the folder name.
            if (tab.pinned_title) |pinned| {
                if (pinned.len > 0) return pinned;
            }
            // 1. live OSC title (the running program's session summary)
            if (session) |s| {
                if (s.liveOscTitle(buffer)) |osc| return osc;
            }
            // 2. last observed title, persisted across restarts (shown before the
            //    program re-emits its OSC title)
            if (tab.observed_title) |observed| {
                if (observed.len > 0) return observed;
            }
            // 3. foreground process name (e.g. `claude` before it sets a title)
            if (session) |s| {
                if (s.foregroundProcessName(buffer)) |name| return name;
            }
        }
        return self.tabTitle(self.active_tab_index, buffer);
    }

    /// The active pane's foreground process name (e.g. `claude`, `codex`) when a
    /// program other than the shell is running, else null. Used to pick a
    /// provider-aware icon in the sidebar.
    pub fn activeForegroundProcessName(self: *const Dock, buffer: *[96]u8) ?[]const u8 {
        if (self.activeTabConst()) |tab| {
            if (findPaneLeafConst(tab.root, tab.active_pane_id) orelse findFirstPaneLeafConst(tab.root)) |pane| {
                if (pane.session) |session| return session.foregroundProcessName(buffer);
            }
        }
        return null;
    }

    pub fn beginRenameTab(self: *Dock, tab_id: u32) void {
        self.rename_tab_id = tab_id;
        @memset(&self.rename_storage, 0);
        if (self.findTabIndexById(tab_id)) |index| {
            var title_buf: [96]u8 = undefined;
            const tab_label = self.tabTitle(index, &title_buf);
            const len = @min(tab_label.len, self.rename_storage.len - 1);
            @memcpy(self.rename_storage[0..len], tab_label[0..len]);
        }
    }

    pub fn cancelRenameTab(self: *Dock) void {
        self.rename_tab_id = null;
        self.rename_storage[0] = 0;
    }

    pub fn renameBuffer(self: *Dock) [:0]u8 {
        return self.rename_storage[0 .. self.rename_storage.len - 1 :0];
    }

    pub fn finishRenameTab(self: *Dock, allocator: std.mem.Allocator) !void {
        const tab_id = self.rename_tab_id orelse return;
        const index = self.findTabIndexById(tab_id) orelse {
            self.cancelRenameTab();
            return;
        };
        const trimmed = std.mem.trim(u8, std.mem.sliceTo(self.rename_storage[0..], 0), &std.ascii.whitespace);
        var tab = &self.tabs.items[index];
        if (tab.title) |tab_title| {
            allocator.free(tab_title);
            tab.title = null;
        }
        if (trimmed.len > 0) {
            tab.title = try allocator.dupe(u8, trimmed);
        }
        self.workspace_changed = true;
        self.cancelRenameTab();
    }

    pub fn persistedLayoutJson(self: *const Dock, allocator: std.mem.Allocator) !?[]u8 {
        return self.persistedLayoutJsonWithContext(allocator, null);
    }

    pub fn persistedLayoutJsonWithContext(
        self: *const Dock,
        allocator: std.mem.Allocator,
        context: ?session_protocol.LayoutContext,
    ) !?[]u8 {
        if (self.tabs.items.len == 0) return null;

        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const arena_allocator = arena.allocator();

        var persisted_tabs: std.ArrayList(PersistedTab) = .empty;
        defer persisted_tabs.deinit(arena_allocator);

        for (self.tabs.items) |tab| {
            var nodes: std.ArrayList(PersistedNode) = .empty;
            defer nodes.deinit(arena_allocator);
            var next_node_id: u32 = 1;
            const root_node_id = try serializePaneNode(arena_allocator, tab.root, &nodes, &next_node_id, context);
            try persisted_tabs.append(arena_allocator, .{
                .title = if (tab.title) |tab_title| try arena_allocator.dupe(u8, tab_title) else null,
                .observed_title = if (tab.observed_title) |observed| try arena_allocator.dupe(u8, observed) else null,
                .pinned_title = if (tab.pinned_title) |pinned| try arena_allocator.dupe(u8, pinned) else null,
                .pinned_provider = if (tab.pinned_provider) |pinned| try arena_allocator.dupe(u8, pinned) else null,
                .agent_history_at = tab.agent_history_at,
                .active_pane_id = tab.active_pane_id,
                .root_node_id = root_node_id,
                .nodes = try nodes.toOwnedSlice(arena_allocator),
            });
        }

        return try std.json.Stringify.valueAlloc(allocator, PersistedWorkspace{
            .active_tab_index = self.active_tab_index,
            .font_scale = self.font_scale,
            .tabs = try persisted_tabs.toOwnedSlice(arena_allocator),
        }, .{});
    }

    pub fn applyPersistedLayoutJson(self: *Dock, allocator: std.mem.Allocator, json: []const u8) !void {
        var parsed = try std.json.parseFromSlice(PersistedWorkspace, allocator, json, .{});
        defer parsed.deinit();

        // Validate before touching the live dock so corrupt coordinates leave
        // the previously loaded layout intact and can never introduce aliases.
        try validatePersistedPaneIds(allocator, parsed.value);

        if (parsed.value.font_scale) |font_scale| {
            self.font_scale = clampf(font_scale, MIN_FONT_SCALE, MAX_FONT_SCALE);
        }

        self.clearTabs(allocator);

        var max_pane_id: u32 = 0;
        for (parsed.value.tabs) |persisted_tab| {
            const root = try buildPaneNodeFromPersisted(allocator, persisted_tab.nodes, persisted_tab.root_node_id, &max_pane_id);
            var tab = Tab{
                .id = self.allocateTabId(),
                .title = if (persisted_tab.title) |tab_title| try allocator.dupe(u8, tab_title) else null,
                .observed_title = if (persisted_tab.observed_title) |observed| try allocator.dupe(u8, observed) else null,
                .pinned_title = if (persisted_tab.pinned_title) |pinned| try allocator.dupe(u8, pinned) else null,
                .pinned_provider = if (persisted_tab.pinned_provider) |pinned| try allocator.dupe(u8, pinned) else null,
                .agent_history_at = persisted_tab.agent_history_at,
                .root = root,
                .active_pane_id = persisted_tab.active_pane_id,
            };
            if (findPaneLeaf(root, tab.active_pane_id) == null) {
                if (findFirstPaneLeaf(root)) |leaf| tab.active_pane_id = leaf.id;
            }
            try self.tabs.append(allocator, tab);
        }

        if (self.tabs.items.len == 0) {
            try self.tabs.append(allocator, try self.buildSinglePaneTabWithoutSession(allocator));
        }

        self.active_tab_index = @min(parsed.value.active_tab_index, self.tabs.items.len - 1);
        self.next_pane_id = @max(self.next_pane_id, max_pane_id +| 1);
    }

    fn ensureWorkspace(self: *Dock, allocator: std.mem.Allocator) !void {
        if (self.tabs.items.len == 0) {
            try self.tabs.append(allocator, try self.buildSinglePaneTabWithoutSession(allocator));
        }
        for (self.tabs.items) |*tab| {
            try self.ensureSessionsInNode(allocator, tab.root);
            if (findPaneLeaf(tab.root, tab.active_pane_id) == null) {
                if (findFirstPaneLeaf(tab.root)) |leaf| tab.active_pane_id = leaf.id;
            }
        }
        if (self.active_tab_index >= self.tabs.items.len) {
            self.active_tab_index = self.tabs.items.len - 1;
        }
    }

    fn pruneOrphanDaemonSessions(self: *Dock, allocator: std.mem.Allocator) !void {
        if (self.orphan_prune_done) return;
        const pref_path = self.pref_path orelse return;
        const cwd = self.cwd orelse return;
        self.orphan_prune_done = true;

        var live_session_ids: std.ArrayList([]const u8) = .empty;
        defer live_session_ids.deinit(allocator);
        for (self.tabs.items) |*tab| try collectPaneSessionIds(allocator, tab.root, &live_session_ids);

        const list_response = try daemon_client.requestAlloc(allocator, pref_path, "session.list", .{}, 1);
        defer allocator.free(list_response);

        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, list_response, .{});
        defer parsed.deinit();
        if (parsed.value != .object) return;
        if (parsed.value.object.get("error")) |_| return;
        const result = parsed.value.object.get("result") orelse return;
        if (result != .object) return;
        const sessions = result.object.get("sessions") orelse return;
        if (sessions != .array) return;

        for (sessions.array.items) |session| {
            if (session != .object) continue;
            const session_id = jsonString(session.object.get("session_id") orelse session.object.get("id") orelse .null) orelse continue;
            const session_dock_id = jsonUsize(session.object.get("dock_id") orelse .null) orelse continue;
            if (session_dock_id != self.session_dock_id) continue;
            const session_project = jsonString(session.object.get("workspace_path") orelse .null) orelse
                jsonString(session.object.get("workspace_id") orelse .null) orelse
                jsonString(session.object.get("project_path") orelse .null) orelse
                jsonString(session.object.get("project_id") orelse .null) orelse "";
            if (!std.mem.eql(u8, session_project, cwd)) continue;
            if (containsSessionId(live_session_ids.items, session_id)) continue;
            const attached_clients = jsonUsize(session.object.get("attached_clients") orelse .null) orelse 0;
            if (attached_clients != 0) continue;

            const kill_response = daemon_client.requestAlloc(allocator, pref_path, "session.kill", .{ .id = session_id }, 1) catch |err| {
                log.debug("failed to kill orphan daemon terminal session id_len={d}: {s}", .{ session_id.len, @errorName(err) });
                continue;
            };
            allocator.free(kill_response);
            log.info("pruned orphan daemon terminal session id_len={d}", .{session_id.len});
        }
    }

    fn clearTabs(self: *Dock, allocator: std.mem.Allocator) void {
        for (self.tabs.items) |*tab| tab.deinit(allocator);
        self.tabs.clearRetainingCapacity();
        self.active_tab_index = 0;
        self.rename_tab_id = null;
    }

    fn queuePaneSessionTeardowns(
        self: *Dock,
        allocator: std.mem.Allocator,
        node: *PaneNode,
        reason: SessionTeardownReason,
    ) !void {
        try self.pending_session_teardowns.ensureUnusedCapacity(allocator, countPaneNodeSessions(node));
        detachPaneNodeSessions(self, node, reason);
    }

    fn queuePaneLeafSessionTeardown(
        self: *Dock,
        allocator: std.mem.Allocator,
        leaf: *PaneLeaf,
        reason: SessionTeardownReason,
    ) !void {
        if (leaf.session == null) return;
        try self.pending_session_teardowns.ensureUnusedCapacity(allocator, 1);
        detachPaneLeafSession(self, leaf, reason);
    }

    fn buildSinglePaneTab(self: *Dock, allocator: std.mem.Allocator) !Tab {
        const tab = try self.buildSinglePaneTabWithoutSession(allocator);
        try self.ensureSessionsInNode(allocator, tab.root);
        return tab;
    }

    fn buildSinglePaneTabWithRevivePolicy(self: *Dock, allocator: std.mem.Allocator, revive_policy: TerminalRevivePolicy) !Tab {
        const tab = try self.buildSinglePaneTabWithoutSession(allocator);
        setRevivePolicyInNode(tab.root, revive_policy);
        try self.ensureSessionsInNode(allocator, tab.root);
        return tab;
    }

    fn buildSinglePaneTabWithoutSession(self: *Dock, allocator: std.mem.Allocator) !Tab {
        const root = try self.createLeafNode(allocator, false);
        return .{
            .id = self.allocateTabId(),
            .title = null,
            .root = root,
            .active_pane_id = root.leaf.id,
        };
    }

    fn createLeafNode(self: *Dock, allocator: std.mem.Allocator, ensure_session: bool) !*PaneNode {
        const node = try allocator.create(PaneNode);
        errdefer allocator.destroy(node);
        node.* = .{ .leaf = .{ .id = try self.allocatePaneId(), .session = null } };
        if (ensure_session) {
            try self.ensureLeafSession(allocator, &node.leaf);
        }
        return node;
    }

    fn ensureLeafSession(self: *Dock, allocator: std.mem.Allocator, leaf: *PaneLeaf) !void {
        const cwd = self.cwd orelse return;
        // A non-null slot is not necessarily usable: sustained daemon loss can
        // leave the local session object present but definitively stopped. Drop
        // only that stopped object so the persisted identity below can attach
        // to a surviving daemon session or create its replacement. The Dock's
        // automatic-restart gate limits how often this destructive step runs.
        if (!prepareSessionSlotForCreate(Session, allocator, &leaf.session)) return;

        const profile = TerminalLaunchProfile{
            .kind = leaf.launch_kind orelse self.launch_profile.kind,
            .label = if (leaf.launch_label) |label| label else self.launch_profile.label,
            .command = if (leaf.launch_command.len > 0) leaf.launch_command else self.launch_profile.command,
        };
        if (leaf.launch_kind == null) leaf.launch_kind = profile.kind;
        if (leaf.launch_label == null and profile.label.len > 0) {
            leaf.launch_label = try allocator.dupe(u8, profile.label);
        }
        if (leaf.launch_command.len == 0 and profile.command.len > 0) {
            leaf.launch_command = try dupeStringSlice(allocator, profile.command);
        }
        if (self.pref_path != null and leaf.session_id == null) {
            leaf.session_id = try session_protocol.stableSessionId(
                allocator,
                cwd,
                self.session_dock_id,
                leaf.id,
            );
        }
        leaf.session = try Session.create(allocator, .{
            .cwd = cwd,
            .cols = INITIAL_COLS,
            .rows = INITIAL_ROWS,
            .profile = profile,
            .restored_modes = leaf.restored_modes,
            .session_id = leaf.session_id,
            .pref_path = self.pref_path,
            .project_id = cwd,
            .project_path = cwd,
            .dock_id = self.session_dock_id,
            .pane_id = leaf.id,
            .revive_policy = leaf.revive_policy,
        });
        const now_ms: i64 = @intCast(@divTrunc(platform_runtime.monotonicTimestampNs(), std.time.ns_per_ms));
        self.auto_restart_backoff.armAfterCreate(now_ms, leaf.session.?.isRunning());
        leaf.restored_modes = null;
        // Restart is a one-shot user action. Once the fresh daemon session is
        // created, future app launches should reattach like normal terminals.
        if (leaf.revive_policy == .restart) leaf.revive_policy = .attach_or_create;
    }

    fn ensureSessionsInNode(self: *Dock, allocator: std.mem.Allocator, node: *PaneNode) !void {
        switch (node.*) {
            .leaf => |*leaf| try self.ensureLeafSession(allocator, leaf),
            .split => |*split| {
                try self.ensureSessionsInNode(allocator, split.first);
                try self.ensureSessionsInNode(allocator, split.second);
            },
        }
    }

    fn allocateTabId(self: *Dock) u32 {
        const id = self.next_tab_id;
        self.next_tab_id += 1;
        return id;
    }

    fn allocatePaneId(self: *Dock) !u32 {
        return self.allocatePaneIdWithin(MAX_PANE_ID);
    }

    fn allocatePaneIdWithin(self: *Dock, limit: u32) !u32 {
        std.debug.assert(limit > 0 and limit <= MAX_PANE_ID);
        var occupied: std.bit_set.StaticBitSet(MAX_PANE_ID + 1) = .empty;
        for (self.tabs.items) |tab| markOccupiedPaneIds(tab.root, limit, &occupied);
        if (occupied.count() >= @as(usize, limit)) return error.PaneIdExhausted;

        var candidate = if (self.next_pane_id == 0 or self.next_pane_id > limit) @as(u32, 1) else self.next_pane_id;
        var attempts: u32 = 0;
        while (attempts < limit) : (attempts += 1) {
            if (!occupied.isSet(@intCast(candidate))) {
                self.next_pane_id = if (candidate == limit) 1 else candidate + 1;
                return candidate;
            }
            candidate = if (candidate == limit) 1 else candidate + 1;
        }
        return error.PaneIdExhausted;
    }

    fn findTabIndexById(self: *const Dock, tab_id: u32) ?usize {
        for (self.tabs.items, 0..) |tab, index| {
            if (tab.id == tab_id) return index;
        }
        return null;
    }

    fn findPaneById(self: *Dock, pane_id: u32) ?*PaneLeaf {
        for (self.tabs.items) |*tab| {
            if (findPaneLeaf(tab.root, pane_id)) |leaf| return leaf;
        }
        return null;
    }

    fn findPaneByIdConst(self: *const Dock, pane_id: u32) ?*const PaneLeaf {
        for (self.tabs.items) |*tab| {
            if (findPaneLeafConst(tab.root, pane_id)) |leaf| return leaf;
        }
        return null;
    }

    fn replacePaneWithSplit(self: *Dock, allocator: std.mem.Allocator, node: *PaneNode, target_pane_id: u32, direction: SplitDirection) !u32 {
        return switch (node.*) {
            .leaf => |leaf| blk: {
                if (leaf.id != target_pane_id) break :blk error.PaneNotFound;

                const existing_leaf_node = try allocator.create(PaneNode);
                errdefer allocator.destroy(existing_leaf_node);
                existing_leaf_node.* = .{ .leaf = leaf };
                const new_leaf_node = try self.createLeafNode(allocator, true);
                const new_pane_id = new_leaf_node.leaf.id;
                node.* = .{
                    .split = .{
                        .axis = axisForDirection(direction),
                        .ratio = 0.5,
                        .first = if (direction == .left or direction == .up) new_leaf_node else existing_leaf_node,
                        .second = if (direction == .left or direction == .up) existing_leaf_node else new_leaf_node,
                    },
                };
                break :blk new_pane_id;
            },
            .split => |*split| {
                if (paneNodeContains(split.first, target_pane_id)) {
                    return try self.replacePaneWithSplit(allocator, split.first, target_pane_id, direction);
                }
                if (paneNodeContains(split.second, target_pane_id)) {
                    return try self.replacePaneWithSplit(allocator, split.second, target_pane_id, direction);
                }
                return error.PaneNotFound;
            },
        };
    }

    fn handleWorkspaceShortcut(
        self: *Dock,
        allocator: std.mem.Allocator,
        keyboard: *const keybinds.NativeKeyboardConfig,
        event: *const sdl.KeyboardEvent,
    ) !bool {
        const action = keyboard.terminalActionForEvent(event) orelse return false;
        try self.performWorkspaceAction(allocator, action);
        return true;
    }

    /// Runs a resolved dock action. Direct shortcuts and prefix-mode chords
    /// both land here so the two tables cannot drift apart.
    pub fn performWorkspaceAction(self: *Dock, allocator: std.mem.Allocator, action: keybinds.NativeTerminalAction) !void {
        switch (action) {
            .new_tab => try self.createTab(allocator),
            .close_active => try self.closeActivePaneOrTab(allocator),
            .rename_tab => if (self.activeTab()) |tab| self.beginRenameTab(tab.id),
            .tab_previous => if (self.active_tab_index > 0) self.selectTab(self.active_tab_index - 1),
            .tab_next => if (self.active_tab_index + 1 < self.tabs.items.len) self.selectTab(self.active_tab_index + 1),
            .split_up => try self.splitActivePane(allocator, .up),
            .split_down => try self.splitActivePane(allocator, .down),
            .split_left => try self.splitActivePane(allocator, .left),
            .split_right => try self.splitActivePane(allocator, .right),
            .focus_up => _ = try self.focusAdjacentPane(allocator, .up),
            .focus_down => _ = try self.focusAdjacentPane(allocator, .down),
            .focus_left => _ = try self.focusAdjacentPane(allocator, .left),
            .focus_right => _ = try self.focusAdjacentPane(allocator, .right),
        }
    }
};

fn markOccupiedPaneIds(
    node: *const PaneNode,
    limit: u32,
    occupied: *std.bit_set.StaticBitSet(MAX_PANE_ID + 1),
) void {
    switch (node.*) {
        .leaf => |leaf| {
            if (leaf.id > 0 and leaf.id <= limit) occupied.set(@intCast(leaf.id));
        },
        .split => |split| {
            markOccupiedPaneIds(split.first, limit, occupied);
            markOccupiedPaneIds(split.second, limit, occupied);
        },
    }
}

fn deinitPaneNode(node: *PaneNode, allocator: std.mem.Allocator) void {
    switch (node.*) {
        .leaf => |*leaf| {
            deinitPaneLeaf(leaf, allocator);
            allocator.destroy(node);
        },
        .split => |*split| {
            deinitPaneNode(split.first, allocator);
            deinitPaneNode(split.second, allocator);
            allocator.destroy(node);
        },
    }
}

fn countPaneNodeSessions(node: *const PaneNode) usize {
    return switch (node.*) {
        .leaf => |leaf| @intFromBool(leaf.session != null),
        .split => |split| countPaneNodeSessions(split.first) + countPaneNodeSessions(split.second),
    };
}

fn detachPaneNodeSessions(dock: *Dock, node: *PaneNode, reason: SessionTeardownReason) void {
    switch (node.*) {
        .leaf => |*leaf| detachPaneLeafSession(dock, leaf, reason),
        .split => |*split| {
            detachPaneNodeSessions(dock, split.first, reason);
            detachPaneNodeSessions(dock, split.second, reason);
        },
    }
}

fn detachPaneLeafSession(dock: *Dock, leaf: *PaneLeaf, reason: SessionTeardownReason) void {
    const session = leaf.session orelse return;
    var teardown: SessionTeardown = .{
        .session = session,
        .persisted_session_id = leaf.session_id,
        .reason = reason,
    };
    const snapshot = session.snapshot();
    if (sessionTeardownNeedsTermination(snapshot)) {
        teardown.cancellation_initiated = session.terminate();
    }
    dock.pending_session_teardowns.appendAssumeCapacity(teardown);
    leaf.session = null;
    leaf.session_id = null;
}

pub fn preferredTeardownSessionId(live_session_id: ?[]const u8, persisted_session_id: ?[]const u8) ?[]const u8 {
    return live_session_id orelse persisted_session_id;
}

fn sessionTeardownNeedsTermination(snapshot: SessionSnapshot) bool {
    return snapshot.running and !snapshot.confirmed_exit;
}

fn resolveSessionTeardown(
    snapshot: SessionSnapshot,
    cancellation_initiated: bool,
    reason: SessionTeardownReason,
) ?SessionTeardownCompletion {
    if (!snapshot.confirmed_exit) return null;
    return .{
        .exit_code = snapshot.exit_code,
        .signal = snapshot.signal,
        .cancellation_reason = if (cancellation_initiated) reason.description() else null,
    };
}

pub const lifecycle_testing = if (builtin.is_test and SESSION_SUPPORTED) struct {
    pub fn assignActiveSessionId(dock: *Dock, allocator: std.mem.Allocator, session_id: []const u8) !void {
        const leaf = dock.activePane() orelse return error.MissingTerminalPane;
        const session = leaf.session orelse return error.MissingTerminalSession;
        if (session.session_id) |existing| allocator.free(existing);
        session.session_id = try allocator.dupe(u8, session_id);
        if (leaf.session_id) |existing| allocator.free(existing);
        leaf.session_id = try allocator.dupe(u8, session_id);
    }

    pub fn simulateActiveDaemonUnavailable(dock: *Dock, running: bool) !void {
        const leaf = dock.activePane() orelse return error.MissingTerminalPane;
        const session = leaf.session orelse return error.MissingTerminalSession;
        session.backend = .daemon;
        session.daemon_state = .unavailable;
        session.running = running;
    }

    pub fn restoreActiveLocal(dock: *Dock) void {
        const leaf = dock.activePane() orelse return;
        const session = leaf.session orelse return;
        session.backend = .local;
        session.daemon_state = .attached;
        session.test_daemon_kill_response = null;
        session.running = true;
    }

    pub fn simulateActiveDaemonKillResponse(dock: *Dock, response: []const u8) !void {
        const leaf = dock.activePane() orelse return error.MissingTerminalPane;
        const session = leaf.session orelse return error.MissingTerminalSession;
        session.backend = .daemon;
        session.daemon_state = .attached;
        session.running = true;
        session.test_daemon_kill_response = response;
    }

    pub fn signalTeardownForConfirmedExit(teardown: *SessionTeardown) void {
        teardown.session.backend = .local;
        teardown.session.daemon_state = .attached;
        teardown.session.test_daemon_kill_response = null;
        teardown.session.running = true;
        std.posix.kill(teardown.session.child_pid, std.posix.SIG.TERM) catch {};
    }

    pub fn pollTeardownSession(teardown: *SessionTeardown, allocator: std.mem.Allocator) !SessionSnapshot {
        _ = try teardown.session.poll(allocator);
        return teardown.session.snapshot();
    }

    pub fn restoreTeardownLocal(teardown: *SessionTeardown) void {
        teardown.session.backend = .local;
        teardown.session.daemon_state = .attached;
        teardown.session.test_daemon_kill_response = null;
        teardown.session.running = true;
    }
} else struct {};

fn collectPaneSessionIds(allocator: std.mem.Allocator, node: *PaneNode, session_ids: *std.ArrayList([]const u8)) !void {
    switch (node.*) {
        .leaf => |*leaf| {
            const session_id = preferredTeardownSessionId(
                if (leaf.session) |session| session.sessionId() else null,
                leaf.session_id,
            );
            if (session_id) |value| try session_ids.append(allocator, value);
        },
        .split => |*split| {
            try collectPaneSessionIds(allocator, split.first, session_ids);
            try collectPaneSessionIds(allocator, split.second, session_ids);
        },
    }
}

fn transferPaneNodeSessions(node: *PaneNode, replacement: *Dock, transferred: *usize) void {
    switch (node.*) {
        .leaf => |*leaf| {
            const session = leaf.session orelse return;
            const session_id = session.sessionId() orelse leaf.session_id orelse return;
            const target = findPaneLeafBySessionId(replacement, session_id) orelse return;
            if (target.session != null) return;
            target.session = session;
            leaf.session = null;
            transferred.* += 1;
        },
        .split => |*split| {
            transferPaneNodeSessions(split.first, replacement, transferred);
            transferPaneNodeSessions(split.second, replacement, transferred);
        },
    }
}

fn findPaneLeafBySessionId(dock: *Dock, session_id: []const u8) ?*PaneLeaf {
    for (dock.tabs.items) |*tab| {
        if (findPaneLeafBySessionIdInNode(tab.root, session_id)) |leaf| return leaf;
    }
    return null;
}

fn findPaneLeafBySessionIdInNode(node: *PaneNode, session_id: []const u8) ?*PaneLeaf {
    return switch (node.*) {
        .leaf => |*leaf| blk: {
            const candidate = if (leaf.session) |session| session.sessionId() orelse leaf.session_id else leaf.session_id;
            if (candidate) |value| {
                if (std.mem.eql(u8, value, session_id)) break :blk leaf;
            }
            break :blk null;
        },
        .split => |*split| findPaneLeafBySessionIdInNode(split.first, session_id) orelse
            findPaneLeafBySessionIdInNode(split.second, session_id),
    };
}

fn collectPaneSessionLifecycleSnapshots(
    allocator: std.mem.Allocator,
    node: *PaneNode,
    snapshots: *std.ArrayList(SessionLifecycleSnapshot),
) !void {
    switch (node.*) {
        .leaf => |*leaf| {
            const session = leaf.session orelse return;
            const session_id = session.sessionId() orelse leaf.session_id orelse return;
            try snapshots.append(allocator, .{ .session_id = session_id, .snapshot = session.snapshot() });
        },
        .split => |*split| {
            try collectPaneSessionLifecycleSnapshots(allocator, split.first, snapshots);
            try collectPaneSessionLifecycleSnapshots(allocator, split.second, snapshots);
        },
    }
}

fn containsSessionId(session_ids: []const []const u8, needle: []const u8) bool {
    for (session_ids) |session_id| {
        if (std.mem.eql(u8, session_id, needle)) return true;
    }
    return false;
}

fn setRevivePolicyInNode(node: *PaneNode, revive_policy: TerminalRevivePolicy) void {
    switch (node.*) {
        .leaf => |*leaf| leaf.revive_policy = revive_policy,
        .split => |*split| {
            setRevivePolicyInNode(split.first, revive_policy);
            setRevivePolicyInNode(split.second, revive_policy);
        },
    }
}

fn deinitPaneLeaf(leaf: *PaneLeaf, allocator: std.mem.Allocator) void {
    if (leaf.session) |session| {
        session.deinit(allocator);
        allocator.destroy(session);
        leaf.session = null;
    }
    if (leaf.session_id) |session_id| {
        allocator.free(session_id);
        leaf.session_id = null;
    }
    if (leaf.launch_label) |launch_label| {
        allocator.free(launch_label);
        leaf.launch_label = null;
    }
    freeStringSlice(allocator, leaf.launch_command);
    leaf.launch_command = &.{};
}

/// Leaves running sessions untouched while releasing a stopped session so its
/// persisted leaf can create a fresh local attachment on the next ensure pass.
fn prepareSessionSlotForCreate(comptime SessionType: type, allocator: std.mem.Allocator, slot: *?*SessionType) bool {
    const session = slot.* orelse return true;
    if (session.isRunning()) return false;
    session.deinit(allocator);
    allocator.destroy(session);
    slot.* = null;
    return true;
}

fn autoRestartDelayMs(attempts: u8) i64 {
    var delay_ms = AUTO_RESTART_BASE_DELAY_MS;
    var remaining = attempts;
    while (remaining > 1 and delay_ms < AUTO_RESTART_MAX_DELAY_MS) : (remaining -= 1) {
        delay_ms = @min(delay_ms * 2, AUTO_RESTART_MAX_DELAY_MS);
    }
    return delay_ms;
}

fn pollPaneNode(node: *PaneNode, allocator: std.mem.Allocator, terminal_modes_changed: *bool) !bool {
    switch (node.*) {
        .leaf => |*leaf| {
            if (leaf.session) |session| {
                const modes_before = session.persistedTerminalModes();
                const changed = try session.poll(allocator);
                if (!std.meta.eql(modes_before, session.persistedTerminalModes())) terminal_modes_changed.* = true;
                return changed;
            }
            return false;
        },
        .split => |*split| {
            const first_changed = try pollPaneNode(split.first, allocator, terminal_modes_changed);
            const second_changed = try pollPaneNode(split.second, allocator, terminal_modes_changed);
            return first_changed or second_changed;
        },
    }
}

fn appendDaemonPollSessionsFromNode(node: *PaneNode, allocator: std.mem.Allocator, batch: *DaemonPollBatch) !void {
    switch (node.*) {
        .leaf => |*leaf| {
            const session = leaf.session orelse return;
            if (session.backend != .daemon or session.defer_daemon_replay_until_resize or session.session_id == null) return;
            try batch.sessions.append(allocator, session);
        },
        .split => |*split| {
            try appendDaemonPollSessionsFromNode(split.first, allocator, batch);
            try appendDaemonPollSessionsFromNode(split.second, allocator, batch);
        },
    }
}

fn rethemePaneNode(node: *PaneNode, allocator: std.mem.Allocator) !void {
    switch (node.*) {
        .leaf => |*leaf| {
            if (leaf.session) |session| try session.retheme(allocator);
        },
        .split => |*split| {
            try rethemePaneNode(split.first, allocator);
            try rethemePaneNode(split.second, allocator);
        },
    }
}

fn paneNodeHasRunningSession(node: *const PaneNode) bool {
    return switch (node.*) {
        .leaf => |leaf| if (leaf.session) |session| session.isRunning() else false,
        .split => |split| paneNodeHasRunningSession(split.first) or paneNodeHasRunningSession(split.second),
    };
}

fn paneNodeHasSessionId(node: *const PaneNode) bool {
    return switch (node.*) {
        .leaf => |leaf| leaf.session_id != null,
        .split => |split| paneNodeHasSessionId(split.first) or paneNodeHasSessionId(split.second),
    };
}

fn takeDaemonSessionRecreatedInNode(node: *PaneNode) bool {
    return switch (node.*) {
        .leaf => |*leaf| if (leaf.session) |session| session.takeDaemonSessionRecreated() else false,
        .split => |*split| blk: {
            const first = takeDaemonSessionRecreatedInNode(split.first);
            const second = takeDaemonSessionRecreatedInNode(split.second);
            break :blk first or second;
        },
    };
}

fn findPaneLeaf(node: *PaneNode, pane_id: u32) ?*PaneLeaf {
    return switch (node.*) {
        .leaf => |*leaf| if (leaf.id == pane_id) leaf else null,
        .split => |*split| findPaneLeaf(split.first, pane_id) orelse findPaneLeaf(split.second, pane_id),
    };
}

fn findPaneLeafConst(node: *const PaneNode, pane_id: u32) ?*const PaneLeaf {
    return switch (node.*) {
        .leaf => |*leaf| if (leaf.id == pane_id) leaf else null,
        .split => |*split| findPaneLeafConst(split.first, pane_id) orelse findPaneLeafConst(split.second, pane_id),
    };
}

fn findFirstPaneLeaf(node: *PaneNode) ?*PaneLeaf {
    return switch (node.*) {
        .leaf => |*leaf| leaf,
        .split => |*split| findFirstPaneLeaf(split.first) orelse findFirstPaneLeaf(split.second),
    };
}

fn findFirstPaneLeafConst(node: *const PaneNode) ?*const PaneLeaf {
    return switch (node.*) {
        .leaf => |*leaf| leaf,
        .split => |*split| findFirstPaneLeafConst(split.first) orelse findFirstPaneLeafConst(split.second),
    };
}

fn clearNotificationInNode(node: *PaneNode, session_id: []const u8) bool {
    return switch (node.*) {
        .leaf => |*leaf| blk: {
            const session = leaf.session orelse break :blk false;
            const id = session.sessionId() orelse break :blk false;
            if (!std.mem.eql(u8, id, session_id)) break :blk false;
            session.clearNotification();
            break :blk true;
        },
        .split => |*split| clearNotificationInNode(split.first, session_id) or clearNotificationInNode(split.second, session_id),
    };
}

fn paneNodeContains(node: *PaneNode, pane_id: u32) bool {
    return findPaneLeaf(node, pane_id) != null;
}

fn isSinglePaneTree(node: *const PaneNode) bool {
    return switch (node.*) {
        .leaf => true,
        .split => false,
    };
}

fn removePaneFromTree(allocator: std.mem.Allocator, root: **PaneNode, pane_id: u32) !void {
    const node = root.*;
    switch (node.*) {
        .leaf => return,
        .split => |*split| {
            if (paneNodeContains(split.first, pane_id)) {
                if (split.first.* == .leaf and split.first.leaf.id == pane_id) {
                    deinitPaneNode(split.first, allocator);
                    const sibling = split.second;
                    allocator.destroy(node);
                    root.* = sibling;
                    return;
                }
                return removePaneFromTree(allocator, &split.first, pane_id);
            }
            if (paneNodeContains(split.second, pane_id)) {
                if (split.second.* == .leaf and split.second.leaf.id == pane_id) {
                    deinitPaneNode(split.second, allocator);
                    const sibling = split.first;
                    allocator.destroy(node);
                    root.* = sibling;
                    return;
                }
                return removePaneFromTree(allocator, &split.second, pane_id);
            }
        },
    }
}

fn findAdjacentPaneId(
    allocator: std.mem.Allocator,
    root: *const PaneNode,
    current_pane_id: u32,
    direction: SplitDirection,
) !?u32 {
    var pane_rects: std.ArrayList(PaneRect) = .empty;
    defer pane_rects.deinit(allocator);
    try collectPaneRects(allocator, root, .{ 0.0, 0.0 }, .{ 1.0, 1.0 }, &pane_rects);

    var current_rect: ?PaneRect = null;
    for (pane_rects.items) |pane_rect| {
        if (pane_rect.pane_id == current_pane_id) {
            current_rect = pane_rect;
            break;
        }
    }
    const current = current_rect orelse return null;

    var best: ?PaneFocusCandidate = null;
    for (pane_rects.items) |pane_rect| {
        if (pane_rect.pane_id == current_pane_id) continue;
        const candidate = paneFocusCandidate(current, pane_rect, direction) orelse continue;
        if (best == null or paneFocusCandidateBetter(candidate, best.?)) {
            best = candidate;
        }
    }
    return if (best) |candidate| candidate.pane_id else null;
}

fn collectPaneRects(
    allocator: std.mem.Allocator,
    node: *const PaneNode,
    min: [2]f32,
    max: [2]f32,
    pane_rects: *std.ArrayList(PaneRect),
) !void {
    switch (node.*) {
        .leaf => |leaf| try pane_rects.append(allocator, .{
            .pane_id = leaf.id,
            .min = min,
            .max = max,
        }),
        .split => |split| {
            if (split.axis == .vertical) {
                const split_x = min[0] + (max[0] - min[0]) * split.ratio;
                try collectPaneRects(allocator, split.first, min, .{ split_x, max[1] }, pane_rects);
                try collectPaneRects(allocator, split.second, .{ split_x, min[1] }, max, pane_rects);
            } else {
                const split_y = min[1] + (max[1] - min[1]) * split.ratio;
                try collectPaneRects(allocator, split.first, min, .{ max[0], split_y }, pane_rects);
                try collectPaneRects(allocator, split.second, .{ min[0], split_y }, max, pane_rects);
            }
        },
    }
}

fn paneFocusCandidate(current: PaneRect, candidate: PaneRect, direction: SplitDirection) ?PaneFocusCandidate {
    const epsilon = 0.0001;
    const current_center = .{
        (current.min[0] + current.max[0]) * 0.5,
        (current.min[1] + current.max[1]) * 0.5,
    };
    const candidate_center = .{
        (candidate.min[0] + candidate.max[0]) * 0.5,
        (candidate.min[1] + candidate.max[1]) * 0.5,
    };

    return switch (direction) {
        .left => blk: {
            if (candidate.max[0] > current.min[0] + epsilon) break :blk null;
            break :blk .{
                .pane_id = candidate.pane_id,
                .overlap = rectAxisOverlap(current.min[1], current.max[1], candidate.min[1], candidate.max[1]),
                .primary_distance = current.min[0] - candidate.max[0],
                .secondary_distance = @abs(current_center[1] - candidate_center[1]),
            };
        },
        .right => blk: {
            if (candidate.min[0] < current.max[0] - epsilon) break :blk null;
            break :blk .{
                .pane_id = candidate.pane_id,
                .overlap = rectAxisOverlap(current.min[1], current.max[1], candidate.min[1], candidate.max[1]),
                .primary_distance = candidate.min[0] - current.max[0],
                .secondary_distance = @abs(current_center[1] - candidate_center[1]),
            };
        },
        .up => blk: {
            if (candidate.max[1] > current.min[1] + epsilon) break :blk null;
            break :blk .{
                .pane_id = candidate.pane_id,
                .overlap = rectAxisOverlap(current.min[0], current.max[0], candidate.min[0], candidate.max[0]),
                .primary_distance = current.min[1] - candidate.max[1],
                .secondary_distance = @abs(current_center[0] - candidate_center[0]),
            };
        },
        .down => blk: {
            if (candidate.min[1] < current.max[1] - epsilon) break :blk null;
            break :blk .{
                .pane_id = candidate.pane_id,
                .overlap = rectAxisOverlap(current.min[0], current.max[0], candidate.min[0], candidate.max[0]),
                .primary_distance = candidate.min[1] - current.max[1],
                .secondary_distance = @abs(current_center[0] - candidate_center[0]),
            };
        },
    };
}

fn paneFocusCandidateBetter(candidate: PaneFocusCandidate, current_best: PaneFocusCandidate) bool {
    const epsilon = 0.0001;
    if (candidate.overlap > current_best.overlap + epsilon) return true;
    if (candidate.overlap + epsilon < current_best.overlap) return false;
    if (candidate.primary_distance + epsilon < current_best.primary_distance) return true;
    if (candidate.primary_distance > current_best.primary_distance + epsilon) return false;
    return candidate.secondary_distance + epsilon < current_best.secondary_distance;
}

fn rectAxisOverlap(a_min: f32, a_max: f32, b_min: f32, b_max: f32) f32 {
    return @max(0.0, @min(a_max, b_max) - @max(a_min, b_min));
}

fn axisForDirection(direction: SplitDirection) SplitAxis {
    return switch (direction) {
        .left, .right => .vertical,
        .up, .down => .horizontal,
    };
}

fn sanitizeSplitRatio(ratio: f32) f32 {
    return clampf(ratio, MIN_SPLIT_RATIO, 1.0 - MIN_SPLIT_RATIO);
}

fn serializePaneNode(
    allocator: std.mem.Allocator,
    node: *const PaneNode,
    nodes: *std.ArrayList(PersistedNode),
    next_node_id: *u32,
    context: ?session_protocol.LayoutContext,
) !u32 {
    const node_id = next_node_id.*;
    next_node_id.* += 1;

    switch (node.*) {
        .leaf => |leaf| {
            const session_id = try session_protocol.sessionIdForLeaf(allocator, context, leaf.id, leaf.session_id);
            const launch_kind: ?TerminalLaunchKind = leaf.launch_kind orelse if (leaf.session) |session| session.launch_kind else null;
            const launch_label: ?[]const u8 = if (leaf.launch_label) |label|
                try allocator.dupe(u8, label)
            else if (leaf.session) |session|
                try allocator.dupe(u8, session.launch_label)
            else
                null;
            try nodes.append(allocator, .{
                .node_id = node_id,
                .kind = .leaf,
                .pane_id = leaf.id,
                .session_id = session_id,
                .launch_kind = launch_kind,
                .launch_label = launch_label,
                .launch_command = try dupeStringSlice(allocator, leaf.launch_command),
                .revive_policy = persistedRevivePolicy(leaf.revive_policy),
                .terminal_modes = if (leaf.session) |session| session.persistedTerminalModes() else leaf.restored_modes,
            });
        },
        .split => |split| {
            const first_node_id = try serializePaneNode(allocator, split.first, nodes, next_node_id, context);
            const second_node_id = try serializePaneNode(allocator, split.second, nodes, next_node_id, context);
            try nodes.append(allocator, .{
                .node_id = node_id,
                .kind = .split,
                .axis = split.axis,
                .ratio = split.ratio,
                .first_node_id = first_node_id,
                .second_node_id = second_node_id,
            });
        },
    }

    return node_id;
}

fn persistedRevivePolicy(revive_policy: TerminalRevivePolicy) TerminalRevivePolicy {
    return switch (revive_policy) {
        // Restart deliberately kills the existing daemon PTY. It must not leak
        // into saved layout state or reopening Verde stops preserving terminals.
        .restart => .attach_or_create,
        else => revive_policy,
    };
}

fn validatePersistedPaneIds(allocator: std.mem.Allocator, persisted: PersistedWorkspace) !void {
    var seen_pane_ids: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer seen_pane_ids.deinit(allocator);
    for (persisted.tabs) |tab| {
        if (tab.active_pane_id > MAX_PANE_ID) return error.InvalidPersistedTerminalLayout;

        var node_indexes: std.AutoHashMapUnmanaged(u32, usize) = .empty;
        defer node_indexes.deinit(allocator);
        for (tab.nodes, 0..) |node, index| {
            const node_entry = try node_indexes.getOrPut(allocator, node.node_id);
            if (node_entry.found_existing) return error.InvalidPersistedTerminalLayout;
            node_entry.value_ptr.* = index;
            if (node.kind == .leaf) {
                if (node.pane_id == 0 or node.pane_id > MAX_PANE_ID) return error.InvalidPersistedTerminalLayout;
                const pane_entry = try seen_pane_ids.getOrPut(allocator, node.pane_id);
                if (pane_entry.found_existing) return error.InvalidPersistedTerminalLayout;
            }
        }

        var visited: std.AutoHashMapUnmanaged(u32, void) = .empty;
        defer visited.deinit(allocator);
        var pending: std.ArrayList(u32) = .empty;
        defer pending.deinit(allocator);
        try pending.append(allocator, tab.root_node_id);
        while (pending.pop()) |node_id| {
            const visited_entry = try visited.getOrPut(allocator, node_id);
            if (visited_entry.found_existing) return error.InvalidPersistedTerminalLayout;
            const node_index = node_indexes.get(node_id) orelse return error.InvalidPersistedTerminalLayout;
            const node = tab.nodes[node_index];
            if (node.kind == .split) {
                try pending.append(allocator, node.first_node_id orelse return error.InvalidPersistedTerminalLayout);
                try pending.append(allocator, node.second_node_id orelse return error.InvalidPersistedTerminalLayout);
            }
        }
        if (visited.count() != tab.nodes.len) return error.InvalidPersistedTerminalLayout;
    }
}

fn buildPaneNodeFromPersisted(
    allocator: std.mem.Allocator,
    nodes: []const PersistedNode,
    root_node_id: u32,
    max_pane_id: *u32,
) !*PaneNode {
    for (nodes) |persisted| {
        if (persisted.node_id != root_node_id) continue;

        const node = try allocator.create(PaneNode);
        switch (persisted.kind) {
            .leaf => {
                max_pane_id.* = @max(max_pane_id.*, persisted.pane_id);
                node.* = .{ .leaf = .{
                    .id = @max(persisted.pane_id, 1),
                    .session = null,
                    .session_id = if (persisted.session_id) |session_id| try allocator.dupe(u8, session_id) else null,
                    .launch_kind = persisted.launch_kind,
                    .launch_label = if (persisted.launch_label) |label| try allocator.dupe(u8, label) else null,
                    .launch_command = try dupeStringSlice(allocator, persisted.launch_command),
                    .revive_policy = persistedRevivePolicy(persisted.revive_policy orelse .attach_or_create),
                    .restored_modes = persisted.terminal_modes,
                } };
            },
            .split => {
                const first_id = persisted.first_node_id orelse return error.InvalidPersistedTerminalLayout;
                const second_id = persisted.second_node_id orelse return error.InvalidPersistedTerminalLayout;
                node.* = .{
                    .split = .{
                        .axis = persisted.axis orelse .vertical,
                        .ratio = sanitizeSplitRatio(persisted.ratio orelse 0.5),
                        .first = try buildPaneNodeFromPersisted(allocator, nodes, first_id, max_pane_id),
                        .second = try buildPaneNodeFromPersisted(allocator, nodes, second_id, max_pane_id),
                    },
                };
            },
        }
        return node;
    }

    return error.InvalidPersistedTerminalLayout;
}

pub fn clampPreferredHeight(height: f32) f32 {
    return clampf(height, MIN_DOCK_HEIGHT, MAX_DOCK_HEIGHT);
}

pub fn clampHeightForAvailable(height: f32, available_height: f32) f32 {
    const max_allowed = @min(MAX_DOCK_HEIGHT, available_height * 0.82);
    const max_height = @max(MIN_DOCK_HEIGHT, max_allowed);
    return clampf(height, MIN_DOCK_HEIGHT, max_height);
}

const UnsupportedSession = struct {
    pub fn create(_: std.mem.Allocator, _: SessionCreateOptions) !*UnsupportedSession {
        return error.UnsupportedOperatingSystem;
    }

    pub fn deinit(_: *UnsupportedSession, _: std.mem.Allocator) void {}

    pub fn poll(_: *UnsupportedSession, _: std.mem.Allocator) !bool {
        return false;
    }

    pub fn persistedTerminalModes(_: *const UnsupportedSession) PersistedTerminalModes {
        return .{};
    }

    pub fn resize(_: *UnsupportedSession, _: std.mem.Allocator, _: u16, _: u16, _: u32, _: u32) !void {}

    pub fn reassertDaemonSizeIfDrifted(_: *UnsupportedSession, _: std.mem.Allocator) !void {}

    pub fn retheme(_: *UnsupportedSession, _: std.mem.Allocator) !void {}

    pub fn displayText(_: *const UnsupportedSession) []const u8 {
        return "";
    }

    pub fn markRendered(_: *UnsupportedSession) void {}

    pub fn statusText(_: *const UnsupportedSession, _: *[192]u8) []const u8 {
        return "Native shell embedding is only enabled on Linux and macOS.";
    }

    pub fn tabTitle(_: *const UnsupportedSession, _: *[96]u8) []const u8 {
        return "Shell";
    }

    pub fn liveOscTitle(_: *const UnsupportedSession, _: *[96]u8) ?[]const u8 {
        return null;
    }

    pub fn foregroundProcessName(_: *const UnsupportedSession, _: *[96]u8) ?[]const u8 {
        return null;
    }

    pub fn isRunning(_: *const UnsupportedSession) bool {
        return false;
    }

    pub fn takeDaemonSessionRecreated(_: *UnsupportedSession) bool {
        return false;
    }

    pub fn sessionId(_: *const UnsupportedSession) ?[]const u8 {
        return null;
    }

    pub fn takeNotification(_: *UnsupportedSession, _: u32) ?NotificationEvent {
        return null;
    }

    pub fn clearNotification(_: *UnsupportedSession) void {}

    pub fn snapshot(_: *const UnsupportedSession) SessionSnapshot {
        return .{ .running = false };
    }

    fn teardownSessionMissing(_: *const UnsupportedSession) bool {
        return false;
    }

    pub fn runtimeProcessSnapshot(_: *const UnsupportedSession) RuntimeProcessSnapshot {
        return .{ .running = false, .foreground = false, .launch_kind = .shell };
    }

    pub fn writeInput(_: *UnsupportedSession, _: []const u8) !bool {
        return false;
    }

    pub fn writeKey(_: *UnsupportedSession, _: TerminalKeyChord) !bool {
        return false;
    }

    pub fn pasteText(_: *UnsupportedSession, _: std.mem.Allocator, _: []const u8) !bool {
        return false;
    }

    pub fn terminate(_: *UnsupportedSession) bool {
        return false;
    }

    pub fn outputTailAlloc(_: *const UnsupportedSession, allocator: std.mem.Allocator, _: usize) ![]u8 {
        return allocator.dupe(u8, "");
    }

    pub fn screenTextAlloc(_: *const UnsupportedSession, allocator: std.mem.Allocator) ![]u8 {
        return allocator.dupe(u8, "");
    }

    pub fn handleKeyDown(_: *UnsupportedSession, _: *const sdl.KeyboardEvent) !bool {
        return false;
    }

    pub fn handleWheel(_: *UnsupportedSession, _: std.mem.Allocator, _: f32, _: f32, _: f32, _: f32, _: f32) !bool {
        return false;
    }

    pub fn handleMouseButton(_: *UnsupportedSession, _: u8, _: bool, _: f32, _: f32, _: f32, _: f32) !bool {
        return false;
    }

    pub fn handleMouseMotion(_: *UnsupportedSession, _: ?u8, _: f32, _: f32, _: f32, _: f32) !bool {
        return false;
    }

    pub fn scrollViewport(_: *UnsupportedSession, _: std.mem.Allocator, _: TerminalScroll) !void {}

    pub fn scrollbar(_: *UnsupportedSession) TerminalScrollbar {
        return .zero;
    }

    pub fn pasteClipboard(_: *UnsupportedSession, _: std.mem.Allocator) !bool {
        return false;
    }

    pub fn copyScreenToClipboard(_: *UnsupportedSession, _: std.mem.Allocator) !bool {
        return false;
    }

    pub fn visibleRows(_: *const UnsupportedSession) u16 {
        return INITIAL_ROWS;
    }
};

const TerminalScroll = union(enum) {
    delta: isize,
    top,
    bottom,
};

const UnixSession = struct {
    backend: Backend = .local,
    master_fd: LocalPtyFd,
    child_pid: LocalPtyPid,
    terminal: ghostty_vt.Terminal,
    stream: TerminalStream,
    render_state: ghostty_vt.RenderState = .empty,
    cols: u16,
    rows: u16,
    cell_width: u32,
    cell_height: u32,
    running: bool = true,
    exit_status: ?u32 = null,
    daemon_exit_status: ?u32 = null,
    daemon_state: DaemonState = .attached,
    launch_kind: TerminalLaunchKind = .shell,
    launch_label: []u8,
    session_id: ?[]u8 = null,
    attach_id: ?[]u8 = null,
    pref_path: ?[]u8 = null,
    remote_output_offset: usize = 0,
    daemon_shell_pid: ?usize = null,
    daemon_foreground_process_group: ?usize = null,
    daemon_process_observed_at_ms: i64 = 0,
    created_at_ms: i64 = 0,
    suppress_next_daemon_replay: bool = false,
    suppress_pty_responses: bool = false,
    defer_daemon_replay_until_resize: bool = false,
    /// Consecutive daemon tail IPC failures. A single failed request must not
    /// flip the session to not-running: pollTerminals treats a dead session as
    /// restorable and silently revives it, and the revive's bounded attach
    /// replay cannot reconstruct a full TUI frame — the pane comes back as a
    /// garbled mix of partial frames. Only give up after a sustained outage.
    daemon_poll_failures: u32 = 0,
    /// Set only when attach-or-create found that a persisted daemon session no
    /// longer existed. Consumers use it to replay higher-level launch intent.
    daemon_session_recreated: bool = false,
    daemon_prefetched: bool = false,
    daemon_prefetched_changed: bool = false,
    /// PTY grid last reported by a daemon tail response. Another client (the
    /// web app) can resize the shared PTY underneath this session; when the
    /// reported grid disagrees with the local one, the stream being replayed
    /// was painted for a different size and renders wrapped/garbled until
    /// this client re-asserts its own grid (reassertDaemonSizeIfDrifted).
    daemon_reported_cols: ?u16 = null,
    daemon_reported_rows: ?u16 = null,
    last_daemon_tail_response: std.ArrayList(u8) = .empty,
    /// Set when this session attached to an already-running daemon PTY (app
    /// restart or revive). Cleared after the first sized resize kicks the
    /// foreground TUI to repaint, since the bounded replay alone cannot
    /// restore a coherent alt-screen frame.
    needs_attach_repaint_kick: bool = false,
    output_ring: std.ArrayList(u8) = .empty,
    /// Opt-in parser-boundary diagnostics, toggled by VERDE_TERMINAL_PARSER_LOG=1.
    /// When set, drainOutput logs the moments a chunk ends with an ESC near the
    /// boundary (likely mid-sequence) and the head of the next chunk — that's
    /// where a desync (visible SGR params like `5;174m`, stray `\e`) manifests.
    parser_log_enabled: bool = false,
    parser_log_prev_tail_had_esc: bool = false,
    test_daemon_kill_response: if (builtin.is_test) ?[]const u8 else void = if (builtin.is_test) null else {},
    pending_notification_attention: bool = false,
    pending_notification_title: [128]u8 = undefined,
    pending_notification_title_len: usize = 0,
    pending_notification_body: [512]u8 = undefined,
    pending_notification_body_len: usize = 0,

    const Backend = enum {
        local,
        daemon,
    };

    const DaemonState = enum {
        attached,
        missing,
        unavailable,
    };

    const SpawnResult = struct {
        master_fd: LocalPtyFd,
        child_pid: LocalPtyPid,
    };

    extern fn forkpty(
        amaster: *c_int,
        name: ?[*:0]u8,
        termp: ?*const anyopaque,
        winp: ?*const std.posix.winsize,
    ) c_int;

    pub fn create(allocator: std.mem.Allocator, options: SessionCreateOptions) !*UnixSession {
        const self = try allocator.create(UnixSession);
        errdefer allocator.destroy(self);

        // TinyIo is zero-sized and stateless, so a temporary is safe even
        // though Screen retains the std.Io interface it produces.
        var terminal = try ghostty_vt.Terminal.init((ghostty_vt.TinyIo.init).io(), allocator, .{
            .cols = options.cols,
            .rows = options.rows,
            // Ghostty's libterminal default is 10_000 *bytes* (~10 KB), which
            // caps scrollback at a few screenfuls. Match Ghostty's main-app
            // default of 10 MB so long sessions retain meaningful history.
            .max_scrollback_bytes = 10_000_000,
            .kitty_image_storage_limit = KITTY_IMAGE_STORAGE_LIMIT,
        });
        errdefer terminal.deinit(allocator);
        configureTerminalTheme(allocator, &terminal);
        try terminal.setPwd(options.cwd);

        const launch_label = try launchLabel(allocator, options.profile);
        errdefer allocator.free(launch_label);

        if (options.pref_path != null and options.session_id != null) {
            self.* = .{
                .backend = .daemon,
                .master_fd = -1,
                .child_pid = 0,
                .terminal = terminal,
                .stream = undefined,
                .render_state = .empty,
                .cols = options.cols,
                .rows = options.rows,
                .cell_width = CELL_PIXEL_WIDTH,
                .cell_height = CELL_PIXEL_HEIGHT,
                .launch_kind = options.profile.kind,
                .launch_label = launch_label,
                .session_id = try allocator.dupe(u8, options.session_id.?),
                .pref_path = try allocator.dupe(u8, options.pref_path.?),
                .created_at_ms = platform_runtime.unixTimestampMs(),
            };
            self.stream = self.terminal.vtStream();
            self.stream.handler.effects.write_pty = &UnixSession.streamWritePty;
            self.stream.handler.effects.clipboard_write = &UnixSession.streamClipboard;
            self.stream.handler.effects.device_attributes = &UnixSession.streamDeviceAttributes;
            self.stream.handler.effects.size = &UnixSession.streamSize;
            self.stream.handler.effects.xtversion = &UnixSession.streamXtVersion;
            self.stream.handler.effects.color_scheme = &UnixSession.streamColorScheme;
            errdefer self.stream.deinit();
            errdefer if (self.session_id) |session_id| allocator.free(session_id);
            errdefer if (self.attach_id) |attach_id| allocator.free(attach_id);
            errdefer if (self.pref_path) |pref_path| allocator.free(pref_path);

            try self.attachDaemonSession(allocator, options);
            self.parser_log_enabled = std.c.getenv("VERDE_TERMINAL_PARSER_LOG") != null;
            try self.refreshRenderState(allocator);
            return self;
        }

        // Windows terminals are daemon-owned ConPTY sessions. Keeping the
        // fallback local-PTY path Unix-only prevents fork/termios symbols from
        // leaking into Windows while retaining the existing Unix behavior.
        if (!LOCAL_PTY_SUPPORTED) return error.PersistentTerminalIdentityRequired;

        const child = try spawnCommand(allocator, options);
        errdefer {
            std.posix.kill(child.child_pid, std.posix.SIG.TERM) catch {};
            _ = std.c.close(child.master_fd);
        }

        self.* = .{
            .backend = .local,
            .master_fd = child.master_fd,
            .child_pid = child.child_pid,
            .terminal = terminal,
            .stream = undefined,
            .render_state = .empty,
            .cols = options.cols,
            .rows = options.rows,
            .cell_width = CELL_PIXEL_WIDTH,
            .cell_height = CELL_PIXEL_HEIGHT,
            .launch_kind = options.profile.kind,
            .launch_label = launch_label,
            .created_at_ms = platform_runtime.unixTimestampMs(),
        };
        self.stream = self.terminal.vtStream();
        self.stream.handler.effects.write_pty = &UnixSession.streamWritePty;
        self.stream.handler.effects.clipboard_write = &UnixSession.streamClipboard;
        self.stream.handler.effects.device_attributes = &UnixSession.streamDeviceAttributes;
        self.stream.handler.effects.size = &UnixSession.streamSize;
        self.stream.handler.effects.xtversion = &UnixSession.streamXtVersion;
        self.stream.handler.effects.color_scheme = &UnixSession.streamColorScheme;
        errdefer self.stream.deinit();

        self.parser_log_enabled = std.c.getenv("VERDE_TERMINAL_PARSER_LOG") != null;
        try self.refreshRenderState(allocator);
        return self;
    }

    pub fn deinit(self: *UnixSession, allocator: std.mem.Allocator) void {
        if (LOCAL_PTY_SUPPORTED) {
            if (self.backend == .local and self.running) {
                std.posix.kill(self.child_pid, std.posix.SIG.TERM) catch {};
            }
            if (self.backend == .local) _ = std.c.close(self.master_fd);
        }
        _ = self.captureExitStatus();
        if (self.backend == .daemon) self.detachDaemon(allocator);
        self.stream.deinit();
        self.render_state.deinit(allocator);
        self.terminal.deinit(allocator);
        allocator.free(self.launch_label);
        if (self.session_id) |session_id| allocator.free(session_id);
        if (self.attach_id) |attach_id| allocator.free(attach_id);
        if (self.pref_path) |pref_path| allocator.free(pref_path);
        self.output_ring.deinit(allocator);
        self.last_daemon_tail_response.deinit(allocator);
    }

    pub fn sessionId(self: *const UnixSession) ?[]const u8 {
        return self.session_id;
    }

    pub fn takeNotification(self: *UnixSession, pane_id: u32) ?NotificationEvent {
        if (!self.pending_notification_attention) return null;
        self.pending_notification_attention = false;
        return .{
            .session_id = self.session_id orelse return null,
            .pane_id = pane_id,
            .title = self.pending_notification_title[0..self.pending_notification_title_len],
            .body = self.pending_notification_body[0..self.pending_notification_body_len],
            .attention = true,
        };
    }

    pub fn clearNotification(self: *UnixSession) void {
        self.pending_notification_attention = false;
        self.pending_notification_title_len = 0;
        self.pending_notification_body_len = 0;
    }

    pub fn poll(self: *UnixSession, allocator: std.mem.Allocator) !bool {
        const changed = switch (self.backend) {
            .local => if (LOCAL_PTY_SUPPORTED) try self.drainOutput(allocator) else false,
            .daemon => if (self.daemon_prefetched) blk: {
                self.daemon_prefetched = false;
                break :blk self.daemon_prefetched_changed;
            } else try self.drainDaemonOutput(allocator),
        };
        const exited = self.captureExitStatus();
        if (changed or exited) {
            try self.refreshRenderState(allocator);
        }
        return changed or exited;
    }

    pub fn persistedTerminalModes(self: *const UnixSession) PersistedTerminalModes {
        return .{
            .alternate_screen = self.terminal.screens.active_key == .alternate,
            .mouse_event = switch (self.terminal.flags.mouse_event) {
                .none => .none,
                .x10 => .x10,
                .normal => .normal,
                .button => .button,
                .any => .any,
            },
            .mouse_format = switch (self.terminal.flags.mouse_format) {
                .x10 => .x10,
                .utf8 => .utf8,
                .sgr => .sgr,
                .urxvt => .urxvt,
                .sgr_pixels => .sgr_pixels,
            },
        };
    }

    /// Rebuilds protocol state that belongs to the surviving PTY but is older
    /// than the bounded output replay available to a newly-started UI client.
    fn applyRestoredTerminalModes(self: *UnixSession, modes: PersistedTerminalModes) void {
        if (modes.alternate_screen) self.stream.nextSlice("\x1b[?1049h");
        self.stream.nextSlice(switch (modes.mouse_event) {
            .none => "",
            .x10 => "\x1b[?9h",
            .normal => "\x1b[?1000h",
            .button => "\x1b[?1002h",
            .any => "\x1b[?1003h",
        });
        self.stream.nextSlice(switch (modes.mouse_format) {
            .x10 => "",
            .utf8 => "\x1b[?1005h",
            .sgr => "\x1b[?1006h",
            .urxvt => "\x1b[?1015h",
            .sgr_pixels => "\x1b[?1016h",
        });
    }

    pub fn resize(self: *UnixSession, allocator: std.mem.Allocator, cols: u16, rows: u16, cell_width: u32, cell_height: u32) !void {
        const next_cols = sanitizeCellCount(cols, MIN_COLS);
        const next_rows = sanitizeCellCount(rows, MIN_ROWS);
        const next_cell_width = @max(cell_width, 1);
        const next_cell_height = @max(cell_height, 1);
        const next_width_px = std.math.mul(u32, next_cols, next_cell_width) catch std.math.maxInt(u32);
        const next_height_px = std.math.mul(u32, next_rows, next_cell_height) catch std.math.maxInt(u32);
        const size_changed = self.cols != next_cols or self.rows != next_rows;
        const metrics_changed = self.cell_width != next_cell_width or self.cell_height != next_cell_height;
        if (!size_changed and !metrics_changed) {
            // The direct Zig Terminal.resize API only updates rows and columns;
            // Kitty placement sizing also requires the pixel dimensions that
            // Ghostty's C wrapper normally maintains for callers.
            self.terminal.width_px = next_width_px;
            self.terminal.height_px = next_height_px;
            if (self.backend == .daemon and self.defer_daemon_replay_until_resize) {
                try self.resizeDaemon(allocator);
                self.defer_daemon_replay_until_resize = false;
                _ = try self.drainDaemonOutput(allocator);
                self.kickAttachedTuiRepaint(allocator);
                try self.refreshRenderState(allocator);
                self.render_state.dirty = .full;
            }
            return;
        }
        const prev_cols = self.cols;
        const prev_rows = self.rows;
        const prev_cell_width = self.cell_width;
        const prev_cell_height = self.cell_height;
        self.cols = next_cols;
        self.rows = next_rows;
        self.cell_width = next_cell_width;
        self.cell_height = next_cell_height;
        // Roll back on any failure below: the new cell counts are only real
        // once the backend and the terminal model both accepted them. Without
        // this, one failed resize makes every later frame see "no size
        // change" and never retry, stranding the PTY/model at the old size.
        errdefer {
            self.cols = prev_cols;
            self.rows = prev_rows;
            self.cell_width = prev_cell_width;
            self.cell_height = prev_cell_height;
        }
        const needs_initial_replay = self.backend == .daemon and self.suppress_next_daemon_replay and self.remote_output_offset == 0;
        switch (self.backend) {
            .local => {
                if (LOCAL_PTY_SUPPORTED and size_changed) self.applyWinsize();
            },
            .daemon => {
                try self.resizeDaemon(allocator);
                self.defer_daemon_replay_until_resize = false;
            },
        }
        if (size_changed) {
            // Match Ghostty's ordering: notify the PTY/backend first, then
            // resize the terminal model. Verde must not add emulator-side clears
            // or synthetic redraw input around this resize; the app owns its
            // repaint behavior.
            try self.terminal.resize(allocator, .{
                .cols = next_cols,
                .rows = next_rows,
                .cell_size_px = .{ .width = self.cell_width, .height = self.cell_height },
            });
            self.terminal.modes.set(.synchronized_output, false);
            if (terminalLayoutDiagnosticsEnabled()) {
                // Capture the inputs that decide reflow behavior so we can
                // diagnose "zoom-then-scroll shows narrow ghost rows" without
                // re-instrumenting per repro. See Terminal.resize (Ghostty):
                // primary reflows iff `wraparound` is set; alternate never
                // reflows.
                log.info(
                    "resize-mode session_len={d} active_screen={s} wraparound={} old_cols={d} new_cols={d} old_rows={d} new_rows={d}",
                    .{
                        if (self.session_id) |session_id| session_id.len else 0,
                        @tagName(self.terminal.screens.active_key),
                        self.terminal.modes.get(.wraparound),
                        prev_cols,
                        next_cols,
                        prev_rows,
                        next_rows,
                    },
                );
            }
        }
        self.terminal.width_px = next_width_px;
        self.terminal.height_px = next_height_px;
        // Mode-2048 clients (nvim 0.10+) take their size exclusively from
        // in-band reports and ignore SIGWINCH/TIOCGWINSZ, so the report must
        // go out on EVERY change — cols-only and shrinks included. The old
        // growing-rows-only gate left nvim on the stale size for width-only
        // zooms and any shrink (the frozen/garbled pane-resize bug); the
        // synthetic Ctrl-L injection removed in 02a1933 had been masking it.
        switch (self.backend) {
            .local => {
                if (size_changed or metrics_changed) self.sendInBandSizeReportAfterResize();
            },
            .daemon => {
                if (needs_initial_replay) {
                    _ = try self.drainDaemonOutput(allocator);
                }
                if (size_changed or metrics_changed) self.sendInBandSizeReportAfterResize();
                _ = try self.drainDaemonOutput(allocator);
                // Even when this resize changed the client's size, the daemon
                // PTY may already have been at the target size (attach to a
                // surviving session), making the ioctl a no-op with no
                // SIGWINCH — so the kick must not be skipped on size_changed.
                self.kickAttachedTuiRepaint(allocator);
            },
        }
        try self.refreshRenderState(allocator);
        self.render_state.dirty = .full;
    }

    pub fn renderState(self: *const UnixSession) *const ghostty_vt.RenderState {
        return &self.render_state;
    }

    pub fn scrollbar(self: *UnixSession) TerminalScrollbar {
        return self.terminal.screens.active.pages.scrollbar();
    }

    pub fn retheme(self: *UnixSession, allocator: std.mem.Allocator) !void {
        configureTerminalTheme(allocator, &self.terminal);
        try self.refreshRenderState(allocator);
        self.render_state.dirty = .full;
    }

    pub fn markRendered(self: *UnixSession) void {
        self.render_state.dirty = .false;
        const row_data = self.render_state.row_data.slice();
        const row_dirties = row_data.items(.dirty);
        @memset(row_dirties, false);
    }

    pub fn statusText(self: *const UnixSession, buf: *[192]u8) []const u8 {
        if (self.running) {
            return std.fmt.bufPrint(buf, "{d}x{d} {s} attached", .{ self.cols, self.rows, self.launch_label }) catch "Terminal attached";
        }
        if (self.backend == .daemon) {
            switch (self.daemon_state) {
                .attached => {},
                .missing => return std.fmt.bufPrint(buf, "{s} session missing. Restart or attach another session.", .{self.launch_label}) catch "Terminal session missing.",
                .unavailable => return "Terminal session daemon unavailable. Session may still be running.",
            }
        }
        if (self.exit_status) |status| {
            if (builtin.os.tag == .windows) {
                return std.fmt.bufPrint(buf, "{s} exited with code {d}", .{ self.launch_label, status }) catch "Terminal exited";
            }
            if (std.c.W.IFEXITED(status)) {
                return std.fmt.bufPrint(buf, "{s} exited with code {d}", .{ self.launch_label, std.c.W.EXITSTATUS(status) }) catch "Terminal exited";
            }
            if (std.c.W.IFSIGNALED(status)) {
                return std.fmt.bufPrint(buf, "{s} terminated by signal {d}", .{ self.launch_label, std.c.W.TERMSIG(status) }) catch "Terminal exited";
            }
        }
        return std.fmt.bufPrint(buf, "{s} exited.", .{self.launch_label}) catch "Terminal exited.";
    }

    pub fn tabTitle(self: *const UnixSession, buffer: *[96]u8) []const u8 {
        if (self.launch_kind != .shell) return self.launch_label;
        if (self.backend == .local and builtin.os.tag == .linux) {
            var proc_path_buf: [64]u8 = undefined;
            const proc_path = std.fmt.bufPrint(&proc_path_buf, "/proc/{d}/cwd", .{self.child_pid}) catch "";
            if (proc_path.len > 0) {
                var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
                var threaded = std.Io.Threaded.init_single_threaded;
                if (std.Io.Dir.cwd().readLink(threaded.io(), proc_path, &cwd_buf)) |cwd_len| {
                    const label = pathLabel(cwd_buf[0..cwd_len]);
                    if (label.len > 0) {
                        const clipped = label[0..@min(label.len, buffer.len)];
                        return std.fmt.bufPrint(buffer, "{s}", .{clipped}) catch "Shell";
                    }
                } else |_| {}
            }
        }
        if (self.terminal.getPwd()) |pwd| {
            const label = pathLabel(pwd);
            if (label.len > 0) return label;
        }
        if (self.terminal.getTitle()) |title| {
            const trimmed = std.mem.trim(u8, title, &std.ascii.whitespace);
            if (trimmed.len > 0) {
                if (trimmed.len <= buffer.len) return trimmed;
                return std.fmt.bufPrint(buffer, "{s}", .{trimmed[0..buffer.len]}) catch "Shell";
            }
        }
        return "Shell";
    }

    pub fn isRunning(self: *const UnixSession) bool {
        return self.running;
    }

    pub fn takeDaemonSessionRecreated(self: *UnixSession) bool {
        const recreated = self.daemon_session_recreated;
        self.daemon_session_recreated = false;
        return recreated;
    }

    pub fn snapshot(self: *const UnixSession) SessionSnapshot {
        if (self.running) return .{ .running = true };
        const status = self.exit_status orelse self.daemon_exit_status orelse
            return .{ .running = false };
        if (builtin.os.tag == .windows) return .{ .running = false, .confirmed_exit = true, .exit_code = status };
        if (std.c.W.IFEXITED(status)) {
            return .{ .running = false, .confirmed_exit = true, .exit_code = @intCast(std.c.W.EXITSTATUS(status)) };
        }
        if (std.c.W.IFSIGNALED(status)) {
            return .{ .running = false, .confirmed_exit = true, .signal = @intFromEnum(std.c.W.TERMSIG(status)) };
        }
        return .{ .running = false, .confirmed_exit = true };
    }

    fn teardownSessionMissing(self: *const UnixSession) bool {
        return self.backend == .daemon and self.daemon_state == .missing;
    }

    pub fn runtimeProcessSnapshot(self: *const UnixSession) RuntimeProcessSnapshot {
        const process_group = self.foregroundProcessGroup();
        const root_pid: ?usize = switch (self.backend) {
            .local => if (self.child_pid > 0) @intCast(self.child_pid) else null,
            .daemon => self.daemon_shell_pid,
        };
        return .{
            .pid = if (process_group orelse root_pid) |value| std.math.cast(u32, value) else null,
            .process_group = if (process_group) |value| std.math.cast(u32, value) else null,
            .started_at_ms = self.created_at_ms,
            .running = self.running,
            .foreground = process_group != null,
            .launch_kind = self.launch_kind,
        };
    }

    pub fn writeInput(self: *UnixSession, bytes: []const u8) !bool {
        if (!self.running or bytes.len == 0) return false;
        return try self.writeRawInput(bytes);
    }

    pub fn writeKey(self: *UnixSession, chord: TerminalKeyChord) !bool {
        if (!self.running) return false;
        var buffer: [128]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buffer);
        try encodeTerminalKeyChord(
            &writer,
            chord,
            ghostty_vt.input.KeyEncodeOptions.fromTerminal(&self.terminal),
        );
        const encoded = writer.buffered();
        if (encoded.len == 0) return false;
        return try self.writeRawInput(encoded);
    }

    pub fn terminate(self: *UnixSession) bool {
        if (!self.running) return false;
        if (self.backend == .daemon) {
            self.killDaemon() catch return false;
            self.running = false;
            return true;
        }
        if (!LOCAL_PTY_SUPPORTED) return false;
        std.posix.kill(self.child_pid, std.posix.SIG.TERM) catch return false;
        self.running = false;
        _ = self.captureExitStatus();
        return true;
    }

    pub fn outputTailAlloc(self: *const UnixSession, allocator: std.mem.Allocator, max_bytes: usize) ![]u8 {
        const count = @min(max_bytes, self.output_ring.items.len);
        return allocator.dupe(u8, self.output_ring.items[self.output_ring.items.len - count ..]);
    }

    pub fn screenTextAlloc(self: *const UnixSession, allocator: std.mem.Allocator) ![]u8 {
        return copyableRenderStateText(allocator, &self.render_state);
    }

    pub fn handleKeyDown(self: *UnixSession, event: *const sdl.KeyboardEvent) !bool {
        if (!self.running or !event.down) return false;
        if (shouldUseTextInputForTerminalPrintableText(event)) return false;

        var utf8_buf: [8]u8 = undefined;
        const synthesized_utf8 = synthesizeTerminalUtf8(event, &utf8_buf);
        if (synthesized_utf8.len == 0 and shouldDeferToTextInput(event)) return false;

        const key = mapScancodeToGhostty(event.scancode) orelse return false;
        const key_event: ghostty_vt.input.KeyEvent = .{
            .action = if (event.repeat) .repeat else .press,
            .key = key,
            .mods = modsFromKeyboardEvent(event),
            .consumed_mods = consumedModsFromKeyboardEvent(event, synthesized_utf8),
            .utf8 = synthesized_utf8,
            .unshifted_codepoint = scancodeCodepoint(event.scancode) orelse 0,
        };

        var buffer: [128]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buffer);
        const options = ghostty_vt.input.KeyEncodeOptions.fromTerminal(&self.terminal);
        try ghostty_vt.input.encodeKey(&writer, key_event, options);
        const encoded = writer.buffered();
        if (encoded.len == 0) return true;
        return try self.writeRawInput(encoded);
    }

    pub fn handleWheel(self: *UnixSession, allocator: std.mem.Allocator, wheel_y: f32, local_x: f32, local_y: f32, width: f32, height: f32) !bool {
        if (wheel_y == 0.0) return false;
        const line_count_float = @max(@round(@abs(wheel_y) * WHEEL_SCROLL_LINES), 1.0);
        const line_count: isize = @intFromFloat(line_count_float);
        if (self.terminal.flags.mouse_event != .none) {
            try self.writeWheelMouseInput(local_x, local_y, width, height, wheel_y, line_count);
            return true;
        }
        if (self.terminal.screens.active_key == .alternate) {
            if (self.terminal.modes.get(.mouse_alternate_scroll)) {
                try self.writeAlternateScrollInput(wheel_y, line_count);
            }
            return true;
        }
        try self.scrollViewport(allocator, .{ .delta = if (wheel_y > 0.0) -line_count else line_count });
        return true;
    }

    pub fn handleMouseButton(self: *UnixSession, button: u8, down: bool, local_x: f32, local_y: f32, width: f32, height: f32) !bool {
        const mouse_button = terminalMouseButton(button) orelse return false;
        if (self.terminal.flags.mouse_event != .none) {
            try self.writeMouseInput(mouse_button, if (down) .press else .release, local_x, local_y, width, height);
            return true;
        }
        return false;
    }

    pub fn handleMouseMotion(self: *UnixSession, button: ?u8, local_x: f32, local_y: f32, width: f32, height: f32) !bool {
        if (self.terminal.flags.mouse_event == .none) return false;
        const mouse_button = if (button) |value| terminalMouseButton(value) else null;
        try self.writeMouseInput(mouse_button, .motion, local_x, local_y, width, height);
        return true;
    }

    fn sendInBandSizeReportAfterResize(self: *UnixSession) void {
        if (!self.terminal.modes.get(.in_band_size_reports)) return;
        var buffer: [128]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buffer);
        ghostty_vt.size_report.encode(&writer, .mode_2048, .{
            .rows = self.rows,
            .columns = self.cols,
            .cell_width = self.cell_width,
            .cell_height = self.cell_height,
        }) catch |err| {
            log.debug("failed to encode terminal size report after resize: {s}", .{@errorName(err)});
            return;
        };
        _ = self.writeRawInput(writer.buffered()) catch |err| {
            log.debug("failed to send terminal size report after resize: {s}", .{@errorName(err)});
        };
    }

    fn hasForegroundProcessAwayFromShell(self: *const UnixSession) bool {
        return self.foregroundProcessGroup() != null;
    }

    /// Returns the foreground process group id when a program other than the
    /// session's own shell is in the foreground (e.g. `nvim`, `htop`), else null.
    fn foregroundProcessGroup(self: *const UnixSession) ?usize {
        switch (self.backend) {
            .local => {
                if (!LOCAL_PTY_SUPPORTED) return null;
                const ioctl_value = TERMINAL_GET_PGRP_IOCTL orelse return null;
                var foreground_process_group: c_int = 0;
                if (std.c.ioctl(self.master_fd, ioctl_value, &foreground_process_group) != 0) return null;
                if (foreground_process_group <= 0 or foreground_process_group == self.child_pid) return null;
                return @intCast(foreground_process_group);
            },
            .daemon => {
                const shell_pid = self.daemon_shell_pid orelse return null;
                const foreground_process_group = self.daemon_foreground_process_group orelse return null;
                if (foreground_process_group == 0 or foreground_process_group == shell_pid) return null;
                return foreground_process_group;
            },
        }
    }

    /// The live OSC window title the running program set (OSC 0/1/2), trimmed.
    /// Agents like Claude Code / Codex use this to publish a session summary.
    fn oscTitle(self: *const UnixSession) ?[]const u8 {
        const title = self.terminal.getTitle() orelse return null;
        const trimmed = std.mem.trim(u8, title, &std.ascii.whitespace);
        return if (trimmed.len > 0) trimmed else null;
    }

    /// The live OSC title of the program running in this session (e.g. an
    /// agent's session summary), copied into `buffer`. Null at a bare shell
    /// prompt, so the caller can fall back to cwd / process name.
    pub fn liveOscTitle(self: *const UnixSession, buffer: *[96]u8) ?[]const u8 {
        const away = self.hasForegroundProcessAwayFromShell();
        if (!away and self.launch_kind == .shell) return null;
        const osc = self.oscTitle() orelse return null;
        const clipped = osc[0..@min(osc.len, buffer.len)];
        return std.fmt.bufPrint(buffer, "{s}", .{clipped}) catch clipped;
    }

    /// Linux-only: the foreground process group leader's command name from
    /// `/proc/<pgid>/comm`, so terminal labels can reflect the running program
    /// instead of just the working directory. Null at the shell prompt.
    pub fn foregroundProcessName(self: *const UnixSession, buffer: *[96]u8) ?[]const u8 {
        if (builtin.os.tag != .linux) return null;
        if (self.launch_kind != .shell) return null;
        const pgid = self.foregroundProcessGroup() orelse return null;
        var path_buf: [64]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "/proc/{d}/comm", .{pgid}) catch return null;
        const fd = std.posix.openat(std.posix.AT.FDCWD, path, .{ .ACCMODE = .RDONLY }, 0) catch return null;
        defer _ = std.c.close(fd);
        const n = std.posix.read(fd, buffer[0..]) catch return null;
        const trimmed = std.mem.trim(u8, buffer[0..n], &std.ascii.whitespace);
        if (trimmed.len == 0) return null;
        return trimmed;
    }

    fn writeWheelMouseInput(self: *UnixSession, local_x: f32, local_y: f32, width: f32, height: f32, wheel_y: f32, line_count: isize) !void {
        const button: ghostty_vt.input.MouseButton = if (wheel_y > 0.0) .four else .five;
        var i: isize = 0;
        while (i < line_count) : (i += 1) {
            try self.writeMouseInput(button, .press, local_x, local_y, width, height);
        }
    }

    fn writeMouseInput(self: *UnixSession, button: ?ghostty_vt.input.MouseButton, action: ghostty_vt.input.MouseAction, local_x: f32, local_y: f32, width: f32, height: f32) !void {
        const logical_cell_width = @max(self.cell_width, 1);
        const logical_cell_height = @max(self.cell_height, 1);
        const visible_rows = @min(
            @as(usize, @max(self.rows, 1)),
            @as(usize, @intFromFloat(@max(@ceil(height / @as(f32, @floatFromInt(logical_cell_height))), 1.0))),
        );
        const clipped_alt = self.terminal.screens.active_key == .alternate and visible_rows < self.rows;
        const screen_width: u32 = if (clipped_alt)
            @as(u32, @max(self.cols, 1)) * logical_cell_width
        else
            @intFromFloat(@max(@round(width), 1.0));
        const screen_height: u32 = if (clipped_alt)
            @as(u32, @max(self.rows, 1)) * logical_cell_height
        else
            @intFromFloat(@max(@round(height), 1.0));
        // Rendering keeps cells at these fixed scaled dimensions and leaves
        // any remainder at the pane edge. Redistributing that remainder over
        // all rows/columns makes mouse targets drift away from drawn cells.
        const cell_width = logical_cell_width;
        const cell_height = logical_cell_height;
        var options = ghostty_vt.input.MouseEncodeOptions.fromTerminal(&self.terminal, .{
            .screen = .{ .width = screen_width, .height = screen_height },
            .cell = .{ .width = cell_width, .height = cell_height },
            .padding = .{},
        });
        options.any_button_pressed = button != null;
        const row_offset = if (clipped_alt)
            @as(usize, self.rows) - visible_rows
        else
            0;
        // Primary-screen scrollback correction: rendering shows the scrolled
        // viewport, but mouse reports must be in live-screen coordinates. A
        // viewport stuck above the bottom (bounded attach replay, scrollbar
        // drag) otherwise skews every TUI click down by the scroll distance —
        // and because the TUI owns the wheel while mouse reporting is on, the
        // user cannot scroll the pane back to clear the skew. Alternate
        // screens have no scrollback, so this is zero there.
        const bar = self.terminal.screens.active.pages.scrollbar();
        const scrollback_rows = bar.total -| (bar.offset + bar.len);
        const scrollback_px = @as(f32, @floatFromInt(scrollback_rows)) * @as(f32, @floatFromInt(logical_cell_height));
        const adjusted_y = local_y + @as(f32, @floatFromInt(row_offset * @as(usize, logical_cell_height))) - scrollback_px;
        // Clicks on pure-history rows have no live-screen equivalent; a
        // negative y would encode a bogus cell, so drop the report instead.
        if (adjusted_y < 0.0) return;
        var buffer: [64]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buffer);
        try ghostty_vt.input.encodeMouse(&writer, .{
            .button = button,
            .action = action,
            .pos = .{ .x = local_x, .y = adjusted_y },
        }, options);
        const encoded = writer.buffered();
        if (encoded.len == 0) return;
        _ = try self.writeRawInput(encoded);
    }

    fn writeAlternateScrollInput(self: *UnixSession, wheel_y: f32, line_count: isize) !void {
        const sequence = if (self.terminal.modes.get(.cursor_keys))
            if (wheel_y > 0.0) "\x1bOA" else "\x1bOB"
        else if (wheel_y > 0.0) "\x1b[A" else "\x1b[B";
        var i: isize = 0;
        while (i < line_count) : (i += 1) {
            _ = try self.writeRawInput(sequence);
        }
    }

    pub fn scrollViewport(self: *UnixSession, allocator: std.mem.Allocator, scroll: TerminalScroll) !void {
        self.terminal.scrollViewport(switch (scroll) {
            .delta => |delta| .{ .delta = delta },
            .top => .top,
            .bottom => .bottom,
        });
        try self.refreshRenderState(allocator);
        // Forcing .full mirrors what `resize` / `retheme` do. Without it, the
        // per-pane draw cache in terminal_panel.zig keeps replaying the
        // pre-scroll frame (rows/cols/rect/font_scale all match), which is
        // what caused narrow-cell "ghost rows" to show through a wider pane
        // after a zoom-then-scroll. Render-state dimensions don't change here,
        // but the visible row contents do.
        self.render_state.dirty = .full;
    }

    pub fn pasteClipboard(self: *UnixSession, allocator: std.mem.Allocator) !bool {
        if (!self.running) return false;
        const clipboard_ptr = sdl.getClipboardText() catch return false;
        defer sdl.free(clipboard_ptr);
        const clipboard_text = std.mem.sliceTo(clipboard_ptr, 0);
        return try self.pasteText(allocator, clipboard_text);
    }

    /// Injects host-provided text as a paste (honoring bracketed-paste mode)
    /// so multi-line content fills the running TUI's input without executing.
    pub fn pasteText(self: *UnixSession, allocator: std.mem.Allocator, text: []const u8) !bool {
        if (!self.running or text.len == 0) return false;

        if (self.backend == .local) {
            if (!LOCAL_PTY_SUPPORTED) return false;
            try writeTerminalPaste(allocator, self.master_fd, text, self.terminal.modes.get(.bracketed_paste));
            return true;
        }
        const encoded = try terminalPasteBytesAlloc(allocator, text, self.terminal.modes.get(.bracketed_paste));
        defer allocator.free(encoded);
        return try self.writeRawInput(encoded);
    }

    pub fn copyScreenToClipboard(self: *UnixSession, allocator: std.mem.Allocator) !bool {
        const screen_text = try copyableRenderStateText(allocator, &self.render_state);
        defer allocator.free(screen_text);
        if (std.mem.trim(u8, screen_text, " \t\r\n").len == 0) return false;

        const clipboard_text = try allocator.dupeZ(u8, screen_text);
        defer allocator.free(clipboard_text);
        try sdl.setClipboardText(clipboard_text);
        return true;
    }

    pub fn visibleRows(self: *const UnixSession) u16 {
        return self.rows;
    }

    fn refreshRenderState(self: *UnixSession, allocator: std.mem.Allocator) !void {
        try self.render_state.update(allocator, &self.terminal);
        try self.logRenderStateSnapshot(allocator);
    }

    fn logRenderStateSnapshot(self: *UnixSession, allocator: std.mem.Allocator) !void {
        if (!terminalLayoutDiagnosticsEnabled()) return;
        const screen_text = try copyableRenderStateText(allocator, &self.render_state);
        defer allocator.free(screen_text);
        var lines = std.mem.splitScalar(u8, screen_text, '\n');
        const first = lines.next() orelse "";
        const second = lines.next() orelse "";
        const third = lines.next() orelse "";
        const first_trimmed = std.mem.trim(u8, first, " \r\t");
        const second_trimmed = std.mem.trim(u8, second, " \r\t");
        const third_trimmed = std.mem.trim(u8, third, " \r\t");
        runtime_log.diagnostic(
            "terminal render snapshot session_len={d} screen={s} cells={d}x{d} cursor_viewport=({?d},{?d}) row1_len={d} row2_len={d} row3_len={d}",
            .{
                if (self.session_id) |session_id| session_id.len else 0,
                @tagName(self.terminal.screens.active_key),
                self.cols,
                self.rows,
                if (self.render_state.cursor.viewport) |cursor| cursor.x else null,
                if (self.render_state.cursor.viewport) |cursor| cursor.y else null,
                first_trimmed.len,
                second_trimmed.len,
                third_trimmed.len,
            },
        );
    }

    fn drainOutput(self: *UnixSession, allocator: std.mem.Allocator) !bool {
        if (!LOCAL_PTY_SUPPORTED) return false;
        if (!self.running) return false;

        var changed = false;
        var buffer: [4096]u8 = undefined;
        while (true) {
            const read_len = std.posix.read(self.master_fd, &buffer) catch |err| switch (err) {
                error.WouldBlock => break,
                error.InputOutput => {
                    self.running = false;
                    break;
                },
                else => return err,
            };
            if (read_len == 0) {
                self.running = false;
                break;
            }

            try self.appendOutput(allocator, buffer[0..read_len]);
            if (self.parser_log_enabled) self.logParserBoundary(buffer[0..read_len]);
            self.stream.nextSlice(buffer[0..read_len]);
            try self.repairTerminalState(allocator);
            changed = true;
        }

        return changed;
    }

    /// Diagnostic: record suspicious chunk-boundary geometry so we can catch
    /// parser desync (e.g. visible `5;174m` leaks, stray `\e`) without
    /// persisting terminal content. Two cases:
    ///   1. The previous chunk ended with an ESC near its tail (potentially
    ///      mid-sequence). The continuation arrives at the head of THIS chunk
    ///      — log it, because that's where a desync becomes visible.
    ///   2. THIS chunk ends with an ESC near its tail. Remember it so we can
    ///      log case (1) on the next iteration, and dump the tail itself for
    ///      context.
    /// Only offsets and byte counts are logged; one line per event.
    fn logParserBoundary(self: *UnixSession, chunk: []const u8) void {
        if (chunk.len == 0) return;

        if (self.parser_log_prev_tail_had_esc) {
            const head_len = @min(chunk.len, 48);
            log.warn("parser-boundary: continuation chunk_len={d} inspected_head_len={d}", .{ chunk.len, head_len });
        }

        var last_esc: ?usize = null;
        var esc_count: usize = 0;
        for (chunk, 0..) |b, i| {
            if (b == 0x1b) {
                last_esc = i;
                esc_count += 1;
            }
        }

        if (last_esc) |pos| {
            const dist_from_end = chunk.len - pos;
            if (dist_from_end <= 32) {
                const tail = chunk[pos..];
                log.warn("parser-boundary: ESC near chunk end chunk_len={d} esc_count={d} last_esc_at={d} dist_from_end={d} tail_len={d}", .{
                    chunk.len, esc_count, pos, dist_from_end, tail.len,
                });
                self.parser_log_prev_tail_had_esc = true;
                return;
            }
        }
        self.parser_log_prev_tail_had_esc = false;
    }

    fn attachDaemonSession(self: *UnixSession, allocator: std.mem.Allocator, options: SessionCreateOptions) !void {
        const pref_path = self.pref_path orelse return error.MissingSessionPrefPath;
        const session_id = self.session_id orelse return error.MissingSessionId;
        const exe_path = try selfExePathAlloc(allocator);
        defer allocator.free(exe_path);
        try daemon_client.ensureDaemon(allocator, pref_path, exe_path);

        if (options.revive_policy == .restart) {
            const kill_response = daemon_client.requestAlloc(allocator, pref_path, "session.kill", .{ .id = session_id }, 1) catch null;
            if (kill_response) |response| allocator.free(response);
        }
        var attached_existing_session = false;
        if (options.revive_policy == .attach_only or options.revive_policy == .manual) {
            const inspect_response = try daemon_client.requestAlloc(allocator, pref_path, "session.inspect", .{ .id = session_id }, 1);
            defer allocator.free(inspect_response);
            try ensureSessionResponseOk(allocator, inspect_response);
            attached_existing_session = true;
        } else {
            const command = try daemonCommandForProfile(allocator, options.profile);
            defer allocator.free(command);
            const create_response = try daemon_client.requestAlloc(allocator, pref_path, "session.create", .{
                .id = session_id,
                .project_id = options.project_id,
                .project_path = options.project_path,
                .cwd = options.cwd,
                .label = self.launch_label,
                .command = command,
                .cols = options.cols,
                .rows = options.rows,
                .dock_id = options.dock_id,
                .pane_id = options.pane_id,
                .pref_path = pref_path,
            }, 1);
            defer allocator.free(create_response);
            try ensureSessionResponseOk(allocator, create_response);
            attached_existing_session = !(sessionResultBool(allocator, create_response, "created") catch true);
        }
        if (attached_existing_session) {
            if (options.restored_modes) |modes| self.applyRestoredTerminalModes(modes);
        }
        self.daemon_session_recreated = daemonSessionNeedsLaunchFallback(
            options.revive_policy,
            attached_existing_session,
        );
        self.suppress_next_daemon_replay = attached_existing_session;
        self.defer_daemon_replay_until_resize = attached_existing_session;
        self.needs_attach_repaint_kick = attached_existing_session;
        runtime_log.diagnostic(
            "terminal daemon attach dock={d} pane={d} session_len={d} existing={} revive_policy={s}",
            .{ options.dock_id, options.pane_id, session_id.len, attached_existing_session, @tagName(options.revive_policy) },
        );

        const attach_response = daemon_client.requestAlloc(allocator, pref_path, "session.attach", .{
            .id = session_id,
            .label = "verde-ui",
        }, 1) catch |err| blk: {
            log.debug("daemon terminal session id_len={d} does not support attach registration: {s}", .{ session_id.len, @errorName(err) });
            break :blk null;
        };
        if (attach_response) |response| {
            defer allocator.free(response);
            self.attach_id = sessionResultStringAlloc(allocator, response, "attach_id") catch |err| blk: {
                log.debug("daemon terminal session id_len={d} attach registration failed: {s}", .{ session_id.len, @errorName(err) });
                break :blk null;
            };
        }

        if (!attached_existing_session) {
            try self.resizeDaemon(allocator);
            _ = try self.drainDaemonOutput(allocator);
        }
    }

    fn drainDaemonOutput(self: *UnixSession, allocator: std.mem.Allocator) !bool {
        if (self.defer_daemon_replay_until_resize) return false;
        const pref_path = self.pref_path orelse return false;
        const session_id = self.session_id orelse return false;
        const initial_attach_replay = self.suppress_next_daemon_replay and self.remote_output_offset == 0;
        const max_replay_bytes = if (initial_attach_replay) DAEMON_ATTACH_REPLAY_MAX_BYTES else DAEMON_REPLAY_MAX_BYTES;
        const max_response_bytes = max_replay_bytes * 6 + DAEMON_TAIL_RESPONSE_OVERHEAD_BYTES;
        const response = daemon_client.requestAllocMaxResponse(
            allocator,
            pref_path,
            "session.tail",
            .{
                .id = session_id,
                .attach_id = self.attach_id orelse "",
                .offset = self.remote_output_offset,
                .max_bytes = max_replay_bytes,
            },
            1,
            max_response_bytes,
        ) catch |err| {
            // Tolerate transient IPC failures: flipping running=false makes
            // pollTerminals revive the session, and the revive's bounded
            // replay garbles TUI panes. ~120 consecutive misses ≈ a couple of
            // seconds of sustained daemon outage before giving up.
            self.daemon_poll_failures += 1;
            if (self.daemon_poll_failures == 1 or self.daemon_poll_failures == DAEMON_POLL_FAILURE_LIMIT) {
                runtime_log.diagnostic(
                    "terminal daemon tail failure session_len={d} count={d} err={s}",
                    .{ session_id.len, self.daemon_poll_failures, @errorName(err) },
                );
            }
            if (self.daemon_poll_failures < DAEMON_POLL_FAILURE_LIMIT) return false;
            self.daemon_state = .unavailable;
            self.running = false;
            return false;
        };
        defer allocator.free(response);

        if (!initial_attach_replay and
            self.daemon_state == .attached and
            cachedDaemonResponseMatches(&self.last_daemon_tail_response, response))
        {
            self.daemon_poll_failures = 0;
            return false;
        }

        var parsed = std.json.parseFromSlice(std.json.Value, allocator, response, .{}) catch |err| {
            // A malformed response (e.g. a ring slice that cuts a UTF-8
            // sequence) would otherwise recur identically every frame and
            // freeze the pane; surface it instead of erroring the poll loop.
            runtime_log.diagnostic(
                "terminal daemon tail parse failure session_len={d} err={s} response_len={d}",
                .{ session_id.len, @errorName(err), response.len },
            );
            return err;
        };
        defer parsed.deinit();
        const changed = try self.applyDaemonTailResponseValue(allocator, parsed.value, initial_attach_replay);
        if (!initial_attach_replay and self.daemon_state == .attached) {
            rememberDaemonResponse(&self.last_daemon_tail_response, allocator, response);
        } else {
            self.last_daemon_tail_response.clearRetainingCapacity();
        }
        return changed;
    }

    fn applyDaemonTailResponseValue(self: *UnixSession, allocator: std.mem.Allocator, response: std.json.Value, initial_attach_replay: bool) !bool {
        const session_id = self.session_id orelse return false;
        if (response != .object) return error.InvalidSessionResponse;
        if (response.object.get("error")) |_| {
            runtime_log.diagnostic("terminal daemon tail rejected session_len={d} marking missing", .{session_id.len});
            self.daemon_state = .missing;
            self.running = false;
            return false;
        }
        const result = response.object.get("result") orelse return error.InvalidSessionResponse;
        if (result != .object) return error.InvalidSessionResponse;
        const raw_text = jsonString(result.object.get("text") orelse .null) orelse "";
        const suppress_replay_responses = initial_attach_replay;
        const shell_pid = jsonUsize(result.object.get("pid") orelse .null);
        const foreground_process_group = jsonUsize(result.object.get("foreground_process_group") orelse .null);
        self.daemon_exit_status = if (jsonUsize(result.object.get("exit_status") orelse .null)) |status|
            std.math.cast(u32, status)
        else
            null;
        const response_offset = jsonUsize(result.object.get("offset") orelse .null) orelse self.remote_output_offset;
        const replay_skipped_output = response_offset > self.remote_output_offset;
        const text = if (replay_skipped_output) terminalReplayFromParserBoundary(raw_text) else raw_text;
        const next_offset = jsonUsize(result.object.get("next_offset") orelse .null) orelse self.remote_output_offset;
        if (jsonU16(result.object.get("cols") orelse .null)) |reported_cols| self.daemon_reported_cols = reported_cols;
        if (jsonU16(result.object.get("rows") orelse .null)) |reported_rows| self.daemon_reported_rows = reported_rows;
        self.daemon_shell_pid = shell_pid;
        self.daemon_foreground_process_group = foreground_process_group;
        self.daemon_process_observed_at_ms = platform_runtime.unixTimestampMs();
        const stale_alt_screen_replay = suppress_replay_responses and
            shell_pid != null and
            foreground_process_group != null and
            foreground_process_group.? == shell_pid.? and
            looksLikeStaleFullScreenReplay(raw_text);
        self.remote_output_offset = next_offset;
        self.suppress_next_daemon_replay = false;
        self.running = jsonBool(result.object.get("running") orelse .null) orelse self.running;
        self.daemon_state = .attached;
        self.daemon_poll_failures = 0;
        if (stale_alt_screen_replay) {
            self.resetLocalTerminalView(allocator) catch |err| {
                log.warn("failed to reset stale daemon terminal replay session_len={d}: {s}", .{ session_id.len, @errorName(err) });
            };
            return true;
        }
        if (text.len == 0) return false;
        try self.appendOutput(allocator, text);
        const previous_suppression = self.suppress_pty_responses;
        self.suppress_pty_responses = previous_suppression or suppress_replay_responses;
        defer self.suppress_pty_responses = previous_suppression;
        self.stream.nextSlice(text);
        try self.repairTerminalState(allocator);
        self.resetAlternateViewport();
        // Initial attach replay can leave the primary-screen viewport parked
        // above the bottom (the bounded replay ends mid-history). Snap it to
        // the live screen once so rendering and TUI mouse coordinates agree;
        // ordinary drains skip this to preserve intentional user scrollback.
        if (suppress_replay_responses and self.terminal.screens.active_key == .primary) {
            self.terminal.scrollViewport(.{ .bottom = {} });
        }
        return true;
    }

    fn resetLocalTerminalView(self: *UnixSession, allocator: std.mem.Allocator) !void {
        const previous_suppression = self.suppress_pty_responses;
        self.suppress_pty_responses = true;
        defer self.suppress_pty_responses = previous_suppression;
        self.stream.nextSlice(LOCAL_TERMINAL_VIEW_RESET);
        try self.repairTerminalState(allocator);
    }

    fn clearLocalTerminalScreen(self: *UnixSession, allocator: std.mem.Allocator) !void {
        const previous_suppression = self.suppress_pty_responses;
        self.suppress_pty_responses = true;
        defer self.suppress_pty_responses = previous_suppression;
        self.stream.nextSlice(LOCAL_TERMINAL_SCREEN_CLEAR);
        try self.repairTerminalState(allocator);
        self.resetAlternateViewport();
    }

    fn resetAlternateViewport(self: *UnixSession) void {
        if (self.terminal.screens.active_key == .alternate) {
            self.terminal.scrollViewport(.{ .top = {} });
            if (terminalLayoutDiagnosticsEnabled()) {
                runtime_log.diagnostic(
                    "terminal alternate viewport reset session_len={d} anchor=top cells={d}x{d}",
                    .{ if (self.session_id) |session_id| session_id.len else 0, self.cols, self.rows },
                );
            }
        }
    }

    /// After attaching to an already-running daemon PTY, the bounded replay
    /// cannot reconstruct a full-screen TUI frame, and the PTY size usually
    /// has not changed — so the program has no reason to repaint and the pane
    /// would stay a garbled mix of partial frames. Nudge it with a one-column
    /// winsize jiggle: two real TIOCSWINSZ transitions guarantee a SIGWINCH
    /// and a full repaint at the correct size (the same trick tmux uses on
    /// client attach). Skipped at a bare shell prompt, where the replay
    /// heuristics already produce a sane view.
    fn kickAttachedTuiRepaint(self: *UnixSession, allocator: std.mem.Allocator) void {
        if (!self.needs_attach_repaint_kick) return;
        self.needs_attach_repaint_kick = false;
        if (self.foregroundProcessGroup() == null) return;
        const cols = self.cols;
        if (cols <= MIN_COLS) return;
        self.cols = cols - 1;
        self.resizeDaemon(allocator) catch {};
        self.cols = cols;
        self.resizeDaemon(allocator) catch |err| {
            runtime_log.diagnostic(
                "terminal attach repaint kick failed session_len={d} err={s}",
                .{ if (self.session_id) |session_id| session_id.len else 0, @errorName(err) },
            );
            return;
        };
        // Mode-2048 clients ignore the SIGWINCH from the jiggle; tell them
        // in-band too (no-op unless the replayed model saw the mode set).
        self.sendInBandSizeReportAfterResize();
        runtime_log.diagnostic(
            "terminal attach repaint kick session_len={d} cells={d}x{d}",
            .{ if (self.session_id) |session_id| session_id.len else 0, cols, self.rows },
        );
    }

    fn resizeDaemon(self: *UnixSession, allocator: std.mem.Allocator) !void {
        const pref_path = self.pref_path orelse return;
        const session_id = self.session_id orelse return;
        const response = try daemon_client.requestAlloc(allocator, pref_path, "session.resize", .{
            .id = session_id,
            .attach_id = self.attach_id orelse "",
            .cols = self.cols,
            .rows = self.rows,
        }, 1);
        defer allocator.free(response);
        try ensureSessionResponseOk(allocator, response);

        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, response, .{});
        defer parsed.deinit();
        if (parsed.value != .object) return;
        const result = parsed.value.object.get("result") orelse return;
        if (result != .object) return;
        if (jsonUsize(result.object.get("pid") orelse .null)) |pid| {
            self.daemon_shell_pid = pid;
        }
        if (jsonUsize(result.object.get("foreground_process_group") orelse .null)) |pgrp| {
            self.daemon_foreground_process_group = pgrp;
        }
        // The daemon PTY now has this client's grid; record it so drift
        // detection does not immediately re-fire against a stale tail report.
        self.daemon_reported_cols = self.cols;
        self.daemon_reported_rows = self.rows;
        const text = jsonString(result.object.get("text") orelse .null) orelse "";
        const next_offset = jsonUsize(result.object.get("next_offset") orelse .null);
        log.info(
            "daemon-resize-response session_len={d} cols={d} rows={d} shell_pid={?d} pgrp={?d} text_len={d} next_offset={?d} active_screen={s}",
            .{
                session_id.len,
                self.cols,
                self.rows,
                self.daemon_shell_pid,
                self.daemon_foreground_process_group,
                text.len,
                next_offset,
                @tagName(self.terminal.screens.active_key),
            },
        );

        // Deliberately ignore the response's `text`/`next_offset`. The daemon
        // answers a resize with any redraw bytes the program emitted while the
        // request settled — for a TUI that is exactly its SIGWINCH repaint for
        // the NEW size. At this point the local terminal model still has the
        // OLD grid (resize() notifies the backend before resizing the model,
        // matching Ghostty), so applying that repaint here paints the top of
        // the old grid and the following shrink discards it (libghostty keeps
        // the BOTTOM rows on an alt-screen row shrink), leaving stale zoomed
        // content on screen (nvim unzoom bug). Leaving remote_output_offset
        // untouched lets the drainDaemonOutput call that every resizeDaemon
        // call site performs after the model resize replay those same bytes
        // into the correctly-sized grid instead.
    }

    /// Re-asserts this client's grid on the shared daemon PTY when a tail
    /// response reported that another client (the web app) resized it. The
    /// caller gates this on window input focus so the actively-used client
    /// wins ownership of the single PTY size and an idle desktop GUI does not
    /// stomp a phone/browser session's grid every poll.
    pub fn reassertDaemonSizeIfDrifted(self: *UnixSession, allocator: std.mem.Allocator) !void {
        if (self.backend != .daemon or self.daemon_state != .attached) return;
        const reported_cols = self.daemon_reported_cols orelse return;
        const reported_rows = self.daemon_reported_rows orelse return;
        if (reported_cols == self.cols and reported_rows == self.rows) return;
        // Clear before the fallible IPC: a failed re-assert must wait for the
        // next tail report instead of retrying every rendered frame.
        self.daemon_reported_cols = null;
        self.daemon_reported_rows = null;
        runtime_log.diagnostic(
            "terminal daemon size drift session_len={d} local={d}x{d} daemon={d}x{d} reasserting",
            .{ if (self.session_id) |session_id| session_id.len else 0, self.cols, self.rows, reported_cols, reported_rows },
        );
        try self.resizeDaemon(allocator);
        _ = try self.drainDaemonOutput(allocator);
        // The foreground TUI repainted for the other client's grid; kick it so
        // the pane recovers without waiting for user input.
        self.kickAttachedTuiRepaint(allocator);
        try self.refreshRenderState(allocator);
        self.render_state.dirty = .full;
    }

    fn killDaemon(self: *UnixSession) !void {
        if (comptime builtin.is_test) {
            if (self.test_daemon_kill_response) |response| {
                return ensureSessionKillSignaled(std.heap.smp_allocator, response);
            }
        }
        const pref_path = self.pref_path orelse return error.MissingSessionPrefPath;
        const session_id = self.session_id orelse return error.MissingSessionId;
        const response = try daemon_client.requestAlloc(std.heap.smp_allocator, pref_path, "session.kill", .{ .id = session_id }, 1);
        defer std.heap.smp_allocator.free(response);
        try ensureSessionKillSignaled(std.heap.smp_allocator, response);
    }

    fn writeRawInput(self: *UnixSession, bytes: []const u8) !bool {
        if (self.backend == .local) {
            if (!LOCAL_PTY_SUPPORTED) return false;
            try writeAll(self.master_fd, bytes);
            return true;
        }
        const pref_path = self.pref_path orelse return false;
        const session_id = self.session_id orelse return false;
        const response = try daemon_client.requestAlloc(std.heap.smp_allocator, pref_path, "session.write", .{
            .id = session_id,
            .attach_id = self.attach_id orelse "",
            .text = bytes,
        }, 1);
        defer std.heap.smp_allocator.free(response);
        try self.applyDaemonWriteResponse(response);
        return true;
    }

    fn applyDaemonWriteResponse(self: *UnixSession, response: []const u8) !void {
        var parsed = try std.json.parseFromSlice(std.json.Value, std.heap.smp_allocator, response, .{});
        defer parsed.deinit();
        if (parsed.value != .object) return;
        const result = parsed.value.object.get("result") orelse return;
        if (result != .object) return;
        if (jsonUsize(result.object.get("pid") orelse .null)) |pid| {
            self.daemon_shell_pid = pid;
        }
        if (jsonUsize(result.object.get("foreground_process_group") orelse .null)) |pgrp| {
            self.daemon_foreground_process_group = pgrp;
        }
        // Deliberately ignore the response's `text`/`next_offset` (mirrors
        // resizeDaemon). The daemon's write response only carries bytes
        // produced during that request's settle window, but its next_offset is
        // the ring's total. Jumping remote_output_offset to that total skips
        // any un-tailed bytes that landed between the last tail and this write
        // — e.g. nvim's SIGWINCH repaint right after an unzoom, where the
        // terminal model's own auto-response (DSR/color-query reply) triggers
        // a write and permanently swallows the repaint, freezing the pane on
        // the stale frame. All ring output must flow through session.tail in
        // drainDaemonOutput, strictly ordered by the tail cursor.
    }

    fn detachDaemon(self: *UnixSession, allocator: std.mem.Allocator) void {
        const pref_path = self.pref_path orelse return;
        const session_id = self.session_id orelse return;
        const attach_id = self.attach_id orelse return;
        const response = daemon_client.requestAllocWithTimeout(
            allocator,
            pref_path,
            "session.detach",
            .{
                .id = session_id,
                .attach_id = attach_id,
            },
            1,
            SESSION_DETACH_TIMEOUT_MS,
        ) catch return;
        allocator.free(response);
    }

    fn appendOutput(self: *UnixSession, allocator: std.mem.Allocator, bytes: []const u8) !void {
        self.scanNotifications(bytes);
        if (bytes.len >= OUTPUT_RING_CAPACITY) {
            self.output_ring.clearRetainingCapacity();
            try self.output_ring.appendSlice(allocator, bytes[bytes.len - OUTPUT_RING_CAPACITY ..]);
            return;
        }
        const overflow = if (self.output_ring.items.len + bytes.len > OUTPUT_RING_CAPACITY)
            self.output_ring.items.len + bytes.len - OUTPUT_RING_CAPACITY
        else
            0;
        if (overflow > 0) {
            std.mem.copyForwards(u8, self.output_ring.items[0 .. self.output_ring.items.len - overflow], self.output_ring.items[overflow..]);
            self.output_ring.shrinkRetainingCapacity(self.output_ring.items.len - overflow);
        }
        try self.output_ring.appendSlice(allocator, bytes);
    }

    fn scanNotifications(self: *UnixSession, bytes: []const u8) void {
        if (hasStandaloneBel(bytes)) {
            self.pending_notification_attention = true;
            self.pending_notification_title_len = 0;
            self.pending_notification_body_len = 0;
        }
        var search_start: usize = 0;
        while (std.mem.indexOfPos(u8, bytes, search_start, "\x1b]777;notify;")) |start| {
            const payload_start = start + "\x1b]777;notify;".len;
            const payload_end = std.mem.indexOfScalarPos(u8, bytes, payload_start, 0x07) orelse {
                search_start = payload_start;
                continue;
            };
            const payload = bytes[payload_start..payload_end];
            const split = std.mem.indexOfScalar(u8, payload, ';');
            const title = if (split) |index| payload[0..index] else payload;
            const body = if (split) |index| payload[index + 1 ..] else "";
            self.storeNotificationText(title, body);
            search_start = payload_end + 1;
        }
    }

    fn hasStandaloneBel(bytes: []const u8) bool {
        var index: usize = 0;
        while (index < bytes.len) : (index += 1) {
            if (bytes[index] == 0x1b and index + 1 < bytes.len and bytes[index + 1] == ']') {
                index += 2;
                while (index < bytes.len) : (index += 1) {
                    if (bytes[index] == 0x07) break;
                    if (bytes[index] == 0x1b and index + 1 < bytes.len and bytes[index + 1] == '\\') {
                        index += 1;
                        break;
                    }
                }
                continue;
            }
            if (bytes[index] == 0x07) return true;
        }
        return false;
    }

    fn storeNotificationText(self: *UnixSession, title: []const u8, body: []const u8) void {
        self.pending_notification_attention = true;
        self.pending_notification_title_len = @min(title.len, self.pending_notification_title.len);
        @memcpy(self.pending_notification_title[0..self.pending_notification_title_len], title[0..self.pending_notification_title_len]);
        self.pending_notification_body_len = @min(body.len, self.pending_notification_body.len);
        @memcpy(self.pending_notification_body[0..self.pending_notification_body_len], body[0..self.pending_notification_body_len]);
    }

    fn repairTerminalState(self: *UnixSession, allocator: std.mem.Allocator) !void {
        var repaired = false;
        const fallback_cols = sanitizeCellCount(self.cols, MIN_COLS);
        const fallback_rows = sanitizeCellCount(self.rows, MIN_ROWS);

        if (self.terminal.cols == 0 or self.terminal.rows == 0) {
            try self.terminal.resize(allocator, .{
                .cols = fallback_cols,
                .rows = fallback_rows,
                .cell_size_px = .{ .width = self.cell_width, .height = self.cell_height },
            });
            repaired = true;
        }

        const term_cols = sanitizeCellCount(self.terminal.cols, MIN_COLS);
        const term_rows = sanitizeCellCount(self.terminal.rows, MIN_ROWS);
        const max_col = term_cols - 1;
        const max_row = term_rows - 1;
        const region = self.terminal.scrolling_region;

        if (region.left > max_col or
            region.right > max_col or
            region.left >= region.right or
            region.top > max_row or
            region.bottom > max_row or
            region.top > region.bottom)
        {
            self.terminal.scrolling_region = .{
                .top = 0,
                .bottom = max_row,
                .left = 0,
                .right = max_col,
            };
            self.terminal.setCursorPos(1, 1);
            repaired = true;
        }

        if (repaired) {
            self.cols = term_cols;
            self.rows = term_rows;
            log.warn(
                "repaired terminal state cols={d} rows={d} region=({d},{d})-({d},{d})",
                .{
                    self.terminal.cols,
                    self.terminal.rows,
                    self.terminal.scrolling_region.left,
                    self.terminal.scrolling_region.top,
                    self.terminal.scrolling_region.right,
                    self.terminal.scrolling_region.bottom,
                },
            );
        }
    }

    fn streamWritePty(handler: *TerminalHandler, data: [:0]const u8) void {
        const session: *UnixSession = @fieldParentPtr("terminal", handler.terminal);
        if (session.suppress_pty_responses) return;
        _ = session.writeRawInput(std.mem.sliceTo(data, 0)) catch |err| {
            log.warn("failed to write terminal response to PTY: {s}", .{@errorName(err)});
        };
    }

    fn streamClipboard(handler: *TerminalHandler, write: ClipboardWrite) ClipboardWriteResult {
        // Contents arrive already base64-decoded and borrowed; read requests
        // are filtered upstream. An empty contents slice clears the clipboard.
        const allocator = handler.terminal.gpa();
        const text: []const u8 = for (write.contents) |content| {
            if (std.mem.startsWith(u8, content.mime, "text/")) break content.data;
        } else if (write.contents.len > 0) write.contents[0].data else "";
        const text_z = allocator.dupeZ(u8, text) catch return .io_error;
        defer allocator.free(text_z);
        sdl.setClipboardText(text_z) catch |err| {
            log.warn("failed to set OSC 52 clipboard text: {s}", .{@errorName(err)});
            return .io_error;
        };
        return .success;
    }

    fn streamDeviceAttributes(_: *TerminalHandler) DeviceAttributes {
        return .{};
    }

    fn streamSize(handler: *TerminalHandler) ?ghostty_vt.size_report.Size {
        const session: *UnixSession = @fieldParentPtr("terminal", handler.terminal);
        return .{
            .rows = session.rows,
            .columns = session.cols,
            .cell_width = session.cell_width,
            .cell_height = session.cell_height,
        };
    }

    fn streamXtVersion(_: *TerminalHandler) []const u8 {
        // Report a Ghostty-style identity so adaptive TUIs (Codex, etc.) that
        // match a known-terminal list enable their themed surfaces. This must
        // stay consistent with the TERM_PROGRAM/TERM_PROGRAM_VERSION env vars
        // set in childExec; reporting "verde" here left us unrecognized and the
        // apps fell back to a flat, surface-less theme.
        return "ghostty 1.1.0";
    }

    fn streamColorScheme(_: *TerminalHandler) ?ColorScheme {
        return .dark;
    }

    const TerminalTheme = struct {
        background: ghostty_vt.color.RGB,
        foreground: ghostty_vt.color.RGB,
        cursor: ghostty_vt.color.RGB,
        palette: [256]ghostty_vt.color.RGB,
    };

    fn configureTerminalTheme(allocator: std.mem.Allocator, terminal: *ghostty_vt.Terminal) void {
        var terminal_theme = defaultTerminalTheme();
        loadGhosttyTheme(allocator, &terminal_theme) catch |err| {
            log.debug("using built-in terminal theme fallback: {s}", .{@errorName(err)});
        };

        terminal.colors.background = ghostty_vt.color.DynamicRGB.init(terminal_theme.background);
        terminal.colors.foreground = ghostty_vt.color.DynamicRGB.init(terminal_theme.foreground);
        terminal.colors.cursor = ghostty_vt.color.DynamicRGB.init(terminal_theme.cursor);
        terminal.colors.palette.changeDefault(terminal_theme.palette);
    }

    fn defaultTerminalTheme() TerminalTheme {
        return .{
            .background = terminalRgbFromTheme(theme.background()),
            .foreground = terminalRgbFromTheme(theme.COLOR_WHITE),
            .cursor = terminalRgbFromTheme(theme.COLOR_TEXT_MUTED),
            .palette = defaultTerminalPalette(),
        };
    }

    fn defaultTerminalPalette() [256]ghostty_vt.color.RGB {
        var palette = ghostty_vt.color.default;
        const ansi = [_]ghostty_vt.color.RGB{
            terminalRgbFromTheme(theme.COLOR_TEXT_SUBTLE),
            terminalRgbFromTheme(theme.COLOR_DIFF_REMOVE),
            terminalRgbFromTheme(theme.COLOR_GREEN),
            terminalRgbFromTheme(theme.COLOR_YELLOW),
            terminalRgbFromTheme(theme.selection()),
            terminalRgbFromTheme(theme.COLOR_ACCENT_DIM),
            terminalRgbFromTheme(theme.COLOR_TEXT_MUTED),
            terminalRgbFromTheme(theme.COLOR_WHITE),
            terminalRgbFromTheme(theme.COLOR_TEXT_MUTED),
            terminalRgbFromTheme(theme.lighten(theme.COLOR_DIFF_REMOVE, 0.12)),
            terminalRgbFromTheme(theme.lighten(theme.COLOR_GREEN, 0.12)),
            terminalRgbFromTheme(theme.lighten(theme.COLOR_YELLOW, 0.12)),
            terminalRgbFromTheme(theme.lighten(theme.selection(), 0.12)),
            terminalRgbFromTheme(theme.lighten(theme.COLOR_ACCENT_DIM, 0.2)),
            terminalRgbFromTheme(theme.lighten(theme.COLOR_TEXT_MUTED, 0.14)),
            terminalRgbFromTheme(theme.lighten(theme.COLOR_WHITE, 0.04)),
        };
        @memcpy(palette[0..ansi.len], &ansi);
        return palette;
    }

    fn loadGhosttyTheme(allocator: std.mem.Allocator, terminal_theme: *TerminalTheme) !void {
        const home = std.c.getenv("HOME") orelse return error.HomeUnset;
        const home_slice = std.mem.span(home);
        const config_path = try std.fs.path.join(allocator, &.{ home_slice, ".config", "ghostty", "config" });
        defer allocator.free(config_path);

        try parseGhosttyThemeFile(allocator, config_path, terminal_theme, true);
    }

    fn parseGhosttyThemeFile(allocator: std.mem.Allocator, path: []const u8, terminal_theme: *TerminalTheme, follow_includes: bool) !void {
        var threaded = std.Io.Threaded.init_single_threaded;
        const content = try std.Io.Dir.cwd().readFileAlloc(threaded.io(), path, allocator, .limited(64 * 1024));
        defer allocator.free(content);

        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |raw_line| {
            const no_comment = if (std.mem.indexOfScalar(u8, raw_line, '#')) |index| raw_line[0..index] else raw_line;
            const line = std.mem.trim(u8, no_comment, " \t\r");
            if (line.len == 0) continue;
            const equals = std.mem.indexOfScalar(u8, line, '=') orelse continue;
            const key = std.mem.trim(u8, line[0..equals], " \t\r");
            const value = std.mem.trim(u8, line[equals + 1 ..], " \t\r");

            if (std.mem.eql(u8, key, "background")) {
                if (parseHexRgb(value)) |rgb| terminal_theme.background = rgb;
            } else if (std.mem.eql(u8, key, "foreground")) {
                if (parseHexRgb(value)) |rgb| terminal_theme.foreground = rgb;
            } else if (std.mem.eql(u8, key, "cursor-color")) {
                if (parseHexRgb(value)) |rgb| terminal_theme.cursor = rgb;
            } else if (std.mem.eql(u8, key, "palette")) {
                parseGhosttyPalette(value, terminal_theme);
            } else if (follow_includes and std.mem.eql(u8, key, "config-file")) {
                const include_path = try resolveGhosttyPath(allocator, path, value);
                defer allocator.free(include_path);
                parseGhosttyThemeFile(allocator, include_path, terminal_theme, false) catch |err| {
                    log.debug("failed to load ghostty theme include {s}: {s}", .{ include_path, @errorName(err) });
                };
            }
        }
    }

    fn parseGhosttyPalette(value: []const u8, terminal_theme: *TerminalTheme) void {
        const equals = std.mem.indexOfScalar(u8, value, '=') orelse return;
        const index_text = std.mem.trim(u8, value[0..equals], " \t\r");
        const color_text = std.mem.trim(u8, value[equals + 1 ..], " \t\r");
        const index = std.fmt.parseInt(usize, index_text, 10) catch return;
        if (index >= terminal_theme.palette.len) return;
        terminal_theme.palette[index] = parseHexRgb(color_text) orelse return;
    }

    fn resolveGhosttyPath(allocator: std.mem.Allocator, base_path: []const u8, raw_value: []const u8) ![]u8 {
        var value = std.mem.trim(u8, rawValueWithoutOptionalPrefix(raw_value), " \t\r");
        if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') value = value[1 .. value.len - 1];
        if (value.len >= 2 and value[0] == '\'' and value[value.len - 1] == '\'') value = value[1 .. value.len - 1];

        if (std.mem.startsWith(u8, value, "~/")) {
            const home = std.c.getenv("HOME") orelse return error.HomeUnset;
            return std.fs.path.join(allocator, &.{ std.mem.span(home), value[2..] });
        }
        if (std.fs.path.isAbsolute(value)) return allocator.dupe(u8, value);

        const base_dir = std.fs.path.dirname(base_path) orelse ".";
        return std.fs.path.join(allocator, &.{ base_dir, value });
    }

    fn rawValueWithoutOptionalPrefix(value: []const u8) []const u8 {
        const trimmed = std.mem.trim(u8, value, " \t\r");
        if (trimmed.len > 0 and trimmed[0] == '?') return std.mem.trim(u8, trimmed[1..], " \t\r");
        return trimmed;
    }

    fn parseHexRgb(raw_value: []const u8) ?ghostty_vt.color.RGB {
        var value = std.mem.trim(u8, raw_value, " \t\r");
        if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') value = value[1 .. value.len - 1];
        if (value.len != 7 or value[0] != '#') return null;
        return terminalRgb(
            std.fmt.parseInt(u8, value[1..3], 16) catch return null,
            std.fmt.parseInt(u8, value[3..5], 16) catch return null,
            std.fmt.parseInt(u8, value[5..7], 16) catch return null,
        );
    }

    fn terminalRgb(r: u8, g: u8, b: u8) ghostty_vt.color.RGB {
        return .{ .r = r, .g = g, .b = b };
    }

    fn terminalRgbFromTheme(color: [4]f32) ghostty_vt.color.RGB {
        return terminalRgb(floatChannelToU8(color[0]), floatChannelToU8(color[1]), floatChannelToU8(color[2]));
    }

    fn floatChannelToU8(value: f32) u8 {
        const clamped = @max(0.0, @min(value, 1.0));
        return @intFromFloat(@round(clamped * 255.0));
    }

    fn captureExitStatus(self: *UnixSession) bool {
        if (self.backend == .daemon) return false;
        if (!LOCAL_PTY_SUPPORTED) return false;
        if (self.exit_status != null) return false;

        var status: c_int = 0;
        const wait_result = std.c.waitpid(self.child_pid, &status, std.c.W.NOHANG);
        if (wait_result == 0) return false;

        self.running = false;
        self.exit_status = @intCast(status);
        return true;
    }

    fn applyWinsize(self: *UnixSession) void {
        if (!LOCAL_PTY_SUPPORTED) return;
        if (!self.running or self.backend == .daemon) return;

        var winsize = std.posix.winsize{
            .row = self.rows,
            .col = self.cols,
            .xpixel = @intCast(@min(@as(u32, std.math.maxInt(u16)), self.cell_width * self.cols)),
            .ypixel = @intCast(@min(@as(u32, std.math.maxInt(u16)), self.cell_height * self.rows)),
        };
        _ = std.c.ioctl(
            self.master_fd,
            TERMINAL_WINSIZE_IOCTL,
            &winsize,
        );
    }

    fn spawnCommand(allocator: std.mem.Allocator, options: SessionCreateOptions) !SpawnResult {
        if (!LOCAL_PTY_SUPPORTED) return error.UnsupportedPlatform;
        const cwd_z = try allocator.dupeZ(u8, options.cwd);
        defer allocator.free(cwd_z);
        const command = try commandForProfile(allocator, options.profile);
        defer freeCommand(allocator, command);
        const identity = try LocalIdentityEnv.init(allocator, options);
        defer identity.deinit(allocator);

        var master_fd: c_int = -1;
        const winsize = std.posix.winsize{
            .row = options.rows,
            .col = options.cols,
            .xpixel = 0,
            .ypixel = 0,
        };
        const fork_result = forkpty(&master_fd, null, null, &winsize);
        if (fork_result < 0) return error.ForkPtyFailed;

        if (fork_result == 0) {
            childExec(cwd_z, command, identity);
        }

        try setNonBlocking(@intCast(master_fd));
        return .{
            .master_fd = @intCast(master_fd),
            .child_pid = @intCast(fork_result),
        };
    }

    const LocalIdentityEnv = struct {
        session_id: ?[:0]const u8 = null,
        project_id: [:0]const u8,
        project_path: [:0]const u8,
        dock_id: [:0]const u8,
        pane_id: [:0]const u8,
        live_socket: ?[:0]const u8 = null,
        sessionizer_socket: ?[:0]const u8 = null,
        cli_path: [:0]const u8,
        mcp_token: ?[:0]const u8 = null,

        fn init(allocator: std.mem.Allocator, options: SessionCreateOptions) !LocalIdentityEnv {
            const project_id = try allocator.dupeZ(u8, options.project_id);
            errdefer allocator.free(project_id);
            const project_path = try allocator.dupeZ(u8, options.project_path);
            errdefer allocator.free(project_path);
            const dock_id_text = try std.fmt.allocPrint(allocator, "{d}", .{options.dock_id});
            defer allocator.free(dock_id_text);
            const dock_id = try allocator.dupeZ(u8, dock_id_text);
            errdefer allocator.free(dock_id);
            const pane_id_text = try std.fmt.allocPrint(allocator, "{d}", .{options.pane_id});
            defer allocator.free(pane_id_text);
            const pane_id = try allocator.dupeZ(u8, pane_id_text);
            errdefer allocator.free(pane_id);
            // Running executable path so provider hooks call this exact binary.
            const cli_path = blk: {
                const p = selfExePathAlloc(allocator) catch break :blk try allocator.dupeZ(u8, "verde");
                defer allocator.free(p);
                break :blk try allocator.dupeZ(u8, p);
            };
            errdefer allocator.free(cli_path);
            const mcp_token = if (options.pref_path) |pref_path|
                try daemon_client.mcpTokenZAlloc(allocator, pref_path)
            else
                null;
            errdefer if (mcp_token) |value| allocator.free(value);
            var session_id: ?[:0]u8 = null;
            if (options.session_id) |id| {
                session_id = try allocator.dupeZ(u8, id);
            }
            errdefer if (session_id) |value| allocator.free(value);
            var live_socket: ?[:0]u8 = null;
            var sessionizer_socket: ?[:0]u8 = null;
            if (options.pref_path) |pref_path| {
                const live_path = try std.fs.path.join(allocator, &.{ pref_path, daemon_client.LIVE_SOCKET_NAME });
                defer allocator.free(live_path);
                live_socket = try allocator.dupeZ(u8, live_path);
                errdefer if (live_socket) |value| allocator.free(value);
                const sessionizer_path = try daemon_client.socketPath(allocator, pref_path);
                defer allocator.free(sessionizer_path);
                sessionizer_socket = try allocator.dupeZ(u8, sessionizer_path);
            }
            return .{
                .session_id = session_id,
                .project_id = project_id,
                .project_path = project_path,
                .dock_id = dock_id,
                .pane_id = pane_id,
                .live_socket = live_socket,
                .sessionizer_socket = sessionizer_socket,
                .cli_path = cli_path,
                .mcp_token = mcp_token,
            };
        }

        fn deinit(self: LocalIdentityEnv, allocator: std.mem.Allocator) void {
            if (self.session_id) |value| allocator.free(value);
            allocator.free(self.project_id);
            allocator.free(self.project_path);
            allocator.free(self.dock_id);
            allocator.free(self.pane_id);
            if (self.live_socket) |value| allocator.free(value);
            if (self.sessionizer_socket) |value| allocator.free(value);
            allocator.free(self.cli_path);
            if (self.mcp_token) |value| allocator.free(value);
        }
    };

    fn childExec(cwd: [:0]const u8, command: []const [:0]u8, identity: LocalIdentityEnv) noreturn {
        if (std.c.chdir(cwd.ptr) != 0) {
            std.c._exit(127);
        }

        process_env.applyAugmentedPathToCurrentProcess(std.heap.page_allocator) catch {};
        const term = childTermEnvValue();
        _ = setenv("TERM", term.ptr, 1);
        _ = setenv("COLORTERM", "truecolor", 1);
        const term_program = childTermProgramEnvValue();
        _ = setenv("TERM_PROGRAM", term_program.ptr, 1);
        _ = setenv("TERM_PROGRAM_VERSION", "1.1.0", 1);
        _ = setenv("CLICOLOR", "1", 1);
        _ = setenv("CLICOLOR_FORCE", "1", 0);
        _ = setenv("FORCE_COLOR", "3", 0);
        _ = unsetenv("NO_COLOR");
        _ = setenv("VERDE", "1", 1);
        if (identity.session_id) |value| _ = setenv("VERDE_SESSION_ID", value.ptr, 1);
        _ = setenv("VERDE_WORKSPACE_ID", identity.project_id.ptr, 1);
        _ = setenv("VERDE_WORKSPACE_PATH", identity.project_path.ptr, 1);
        _ = setenv("VERDE_DOCK_ID", identity.dock_id.ptr, 1);
        _ = setenv("VERDE_PANE_ID", identity.pane_id.ptr, 1);
        if (identity.live_socket) |value| {
            _ = setenv("VERDE_SOCKET", value.ptr, 1);
            _ = setenv("VERDE_LIVE_SOCKET", value.ptr, 1);
        }
        if (identity.sessionizer_socket) |value| _ = setenv("VERDE_SESSIONIZER_SOCKET", value.ptr, 1);
        _ = setenv("VERDE_CLI", identity.cli_path.ptr, 1);
        if (identity.mcp_token) |value| _ = setenv("VERDE_MCP_TOKEN", value.ptr, 1);
        if (identity.sessionizer_socket) |socket_path| if (identity.session_id) |session_id| {
            _ = setenv("HERDR_SOCKET_PATH", socket_path.ptr, 1);
            _ = setenv("HERDR_PANE_ID", session_id.ptr, 1);
        };
        if (std.c.getenv("LANG") == null) {
            const lang = childLocaleEnvValue();
            _ = setenv("LANG", lang.ptr, 1);
        }

        var argv: [32:null]?[*:0]const u8 = [_:null]?[*:0]const u8{null} ** 32;
        const count = @min(command.len, argv.len - 1);
        for (command[0..count], 0..) |arg, index| {
            argv[index] = arg.ptr;
        }
        if (count > 0) {
            _ = std.c.execve(command[0].ptr, &argv, std.c.environ);
        }
        std.c._exit(127);
    }
};

fn setNonBlocking(fd: std.posix.fd_t) !void {
    const current = std.c.fcntl(fd, std.c.F.GETFL, @as(c_int, 0));
    if (current < 0) return error.FcntlFailed;
    const nonblock = @as(usize, 1) << @bitOffsetOf(std.posix.O, "NONBLOCK");
    if (std.c.fcntl(fd, std.c.F.SETFL, current | @as(c_int, @intCast(nonblock))) < 0) return error.FcntlFailed;
}

fn writeAll(fd: std.posix.fd_t, bytes: []const u8) !void {
    var remaining = bytes;
    while (remaining.len > 0) {
        const written_raw = std.c.write(fd, remaining.ptr, remaining.len);
        if (written_raw < 0) return error.WriteFailed;
        const written: usize = @intCast(written_raw);
        if (written == 0) return error.WriteFailed;
        remaining = remaining[written..];
    }
}

fn writeTerminalPaste(allocator: std.mem.Allocator, fd: std.posix.fd_t, text: []const u8, bracketed: bool) !void {
    const encoded = try terminalPasteBytesAlloc(allocator, text, bracketed);
    defer allocator.free(encoded);
    try writeAll(fd, encoded);
}

fn terminalPasteBytesAlloc(allocator: std.mem.Allocator, text: []const u8, bracketed: bool) ![]u8 {
    var encoded: std.ArrayList(u8) = .empty;
    errdefer encoded.deinit(allocator);

    if (bracketed) try encoded.appendSlice(allocator, "\x1b[200~");
    for (text) |byte| {
        try encoded.append(allocator, if (terminalPasteUnsafeByte(byte))
            ' '
        else if (!bracketed and byte == '\n')
            '\r'
        else
            byte);
    }
    if (bracketed) try encoded.appendSlice(allocator, "\x1b[201~");
    return try encoded.toOwnedSlice(allocator);
}

fn copyableRenderStateText(allocator: std.mem.Allocator, render_state: *const ghostty_vt.RenderState) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);

    const row_data = render_state.row_data.slice();
    const row_cells = row_data.items(.cells);
    for (row_cells, 0..) |cells, row_index| {
        const cells_slice = cells.slice();
        const raw_cells = cells_slice.items(.raw);
        const row_graphemes = cells_slice.items(.grapheme);

        var row: std.ArrayList(u8) = .empty;
        defer row.deinit(allocator);

        for (raw_cells, 0..) |raw_cell, cell_index| {
            if (raw_cell.wide == .spacer_tail) continue;
            if (!raw_cell.hasText()) {
                try row.append(allocator, ' ');
                continue;
            }

            var text_buf: [128]u8 = undefined;
            const text = terminalCellText(raw_cell, terminalGraphemesForCell(raw_cell, row_graphemes, cell_index), &text_buf) orelse " ";
            try row.appendSlice(allocator, text);
            if (raw_cell.wide == .wide) try row.append(allocator, ' ');
        }

        const trimmed = std.mem.trimEnd(u8, row.items, " \t");
        try output.appendSlice(allocator, trimmed);
        if (row_index + 1 < row_cells.len) try output.append(allocator, '\n');
    }

    return output.toOwnedSlice(allocator);
}

fn terminalGraphemesForCell(cell: ghostty_vt.Cell, graphemes: []const []const u21, index: usize) []const u21 {
    return if (cell.hasGrapheme()) graphemes[index] else &.{};
}

fn terminalCellText(raw_cell: ghostty_vt.Cell, graphemes: []const u21, buffer: []u8) ?[]const u8 {
    if (!raw_cell.hasText()) return null;
    var index: usize = 0;
    index += std.unicode.utf8Encode(raw_cell.codepoint(), buffer[index..]) catch return null;
    if (raw_cell.hasGrapheme()) {
        for (graphemes) |cp| {
            if (index >= buffer.len) break;
            index += std.unicode.utf8Encode(cp, buffer[index..]) catch break;
        }
    }
    return buffer[0..index];
}

fn terminalPasteUnsafeByte(byte: u8) bool {
    return switch (byte) {
        0x00, 0x08, 0x05, 0x04, 0x1B, 0x7F, 0x03, 0x1C, 0x15, 0x1A, 0x11, 0x13, 0x17, 0x16, 0x12, 0x0F => true,
        else => false,
    };
}

fn encodeTerminalKeyChord(
    writer: *std.Io.Writer,
    chord: TerminalKeyChord,
    options: ghostty_vt.input.KeyEncodeOptions,
) !void {
    var utf8_buffer: [1]u8 = undefined;
    const key_event = terminalKeyEvent(chord, &utf8_buffer);
    try ghostty_vt.input.encodeKey(writer, key_event, options);
}

/// Encode a validated key chord with default terminal protocol options.
/// Used by headless/daemon-direct MCP key delivery where no local VT model exists.
pub fn encodeKeyChordDefaultAlloc(allocator: std.mem.Allocator, chord: TerminalKeyChord) ![]u8 {
    var buffer: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try encodeTerminalKeyChord(&writer, chord, .default);
    return try allocator.dupe(u8, writer.buffered());
}

fn terminalKeyEvent(chord: TerminalKeyChord, utf8_buffer: *[1]u8) ghostty_vt.input.KeyEvent {
    const codepoint = terminalKeyCodepoint(chord.key);
    var utf8: []const u8 = "";
    if (codepoint) |value| {
        var byte: u8 = @intCast(value);
        if (chord.modifiers.shift and byte >= 'a' and byte <= 'z') byte = std.ascii.toUpper(byte);
        utf8_buffer[0] = byte;
        utf8 = utf8_buffer[0..1];
    }
    return .{
        .action = .press,
        .key = terminalKeyToGhostty(chord.key),
        .mods = .{
            .ctrl = chord.modifiers.ctrl,
            .alt = chord.modifiers.alt,
            .shift = chord.modifiers.shift,
            .super = chord.modifiers.super,
        },
        .consumed_mods = .{},
        .utf8 = utf8,
        .unshifted_codepoint = codepoint orelse 0,
    };
}

fn terminalKeyCodepoint(key: TerminalKey) ?u21 {
    return switch (key) {
        .space => ' ',
        .a => 'a',
        .b => 'b',
        .c => 'c',
        .d => 'd',
        .e => 'e',
        .f => 'f',
        .g => 'g',
        .h => 'h',
        .i => 'i',
        .j => 'j',
        .k => 'k',
        .l => 'l',
        .m => 'm',
        .n => 'n',
        .o => 'o',
        .p => 'p',
        .q => 'q',
        .r => 'r',
        .s => 's',
        .t => 't',
        .u => 'u',
        .v => 'v',
        .w => 'w',
        .x => 'x',
        .y => 'y',
        .z => 'z',
        .@"0" => '0',
        .@"1" => '1',
        .@"2" => '2',
        .@"3" => '3',
        .@"4" => '4',
        .@"5" => '5',
        .@"6" => '6',
        .@"7" => '7',
        .@"8" => '8',
        .@"9" => '9',
        else => null,
    };
}

fn terminalKeyToGhostty(key: TerminalKey) ghostty_vt.input.Key {
    return switch (key) {
        .enter => .enter,
        .escape => .escape,
        .tab => .tab,
        .up => .arrow_up,
        .down => .arrow_down,
        .left => .arrow_left,
        .right => .arrow_right,
        .home => .home,
        .end => .end,
        .pageup => .page_up,
        .pagedown => .page_down,
        .backspace => .backspace,
        .delete => .delete,
        .space => .space,
        .f1 => .f1,
        .f2 => .f2,
        .f3 => .f3,
        .f4 => .f4,
        .f5 => .f5,
        .f6 => .f6,
        .f7 => .f7,
        .f8 => .f8,
        .f9 => .f9,
        .f10 => .f10,
        .f11 => .f11,
        .f12 => .f12,
        .a => .key_a,
        .b => .key_b,
        .c => .key_c,
        .d => .key_d,
        .e => .key_e,
        .f => .key_f,
        .g => .key_g,
        .h => .key_h,
        .i => .key_i,
        .j => .key_j,
        .k => .key_k,
        .l => .key_l,
        .m => .key_m,
        .n => .key_n,
        .o => .key_o,
        .p => .key_p,
        .q => .key_q,
        .r => .key_r,
        .s => .key_s,
        .t => .key_t,
        .u => .key_u,
        .v => .key_v,
        .w => .key_w,
        .x => .key_x,
        .y => .key_y,
        .z => .key_z,
        .@"0" => .digit_0,
        .@"1" => .digit_1,
        .@"2" => .digit_2,
        .@"3" => .digit_3,
        .@"4" => .digit_4,
        .@"5" => .digit_5,
        .@"6" => .digit_6,
        .@"7" => .digit_7,
        .@"8" => .digit_8,
        .@"9" => .digit_9,
    };
}

fn daemonCommandForProfile(allocator: std.mem.Allocator, profile: TerminalLaunchProfile) ![][]const u8 {
    if (profile.command.len > 0) {
        const command = try allocator.alloc([]const u8, profile.command.len);
        @memcpy(command, profile.command);
        return command;
    }
    if (profile.kind == .shell) {
        // An empty daemon command asks the Windows backend to select the best
        // installed interactive shell (pwsh, Windows PowerShell, then cmd).
        if (builtin.os.tag == .windows) return allocator.alloc([]const u8, 0);
        const command = try allocator.alloc([]const u8, 2);
        command[0] = defaultInteractiveShell();
        command[1] = "-i";
        return command;
    }
    const args: []const []const u8 = switch (profile.kind) {
        .shell => unreachable,
        .claude => &.{"claude"},
        .opencode => &.{"opencode2"},
        .codex => &.{"codex"},
        .cursor => &.{"agent"},
        .custom => &.{},
    };
    const command = try allocator.alloc([]const u8, args.len);
    @memcpy(command, args);
    return command;
}

fn ensureSessionResponseOk(allocator: std.mem.Allocator, response: []const u8) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, response, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidSessionResponse;
    if (parsed.value.object.get("error")) |_| return error.SessionRequestFailed;
}

fn ensureSessionKillSignaled(allocator: std.mem.Allocator, response: []const u8) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, response, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidSessionResponse;
    if (parsed.value.object.get("error")) |_| return error.SessionRequestFailed;
    const result = parsed.value.object.get("result") orelse return error.InvalidSessionResponse;
    if (result != .object) return error.InvalidSessionResponse;
    const accepted = jsonBool(result.object.get("accepted") orelse .null) orelse false;
    const signaled = jsonBool(result.object.get("signaled") orelse .null) orelse false;
    if (!accepted or !signaled) return error.SessionTerminationNotSignaled;
}

fn sessionResultStringAlloc(allocator: std.mem.Allocator, response: []const u8, field: []const u8) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, response, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidSessionResponse;
    if (parsed.value.object.get("error")) |_| return error.SessionRequestFailed;
    const result = parsed.value.object.get("result") orelse return error.InvalidSessionResponse;
    if (result != .object) return error.InvalidSessionResponse;
    const text = jsonString(result.object.get(field) orelse .null) orelse return error.InvalidSessionResponse;
    return try allocator.dupe(u8, text);
}

fn sessionResultBool(allocator: std.mem.Allocator, response: []const u8, field: []const u8) !bool {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, response, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidSessionResponse;
    if (parsed.value.object.get("error")) |_| return error.SessionRequestFailed;
    const result = parsed.value.object.get("result") orelse return error.InvalidSessionResponse;
    if (result != .object) return error.InvalidSessionResponse;
    return jsonBool(result.object.get(field) orelse .null) orelse return error.InvalidSessionResponse;
}

fn jsonString(value: std.json.Value) ?[]const u8 {
    return switch (value) {
        .string => |text| text,
        else => null,
    };
}

fn jsonBool(value: std.json.Value) ?bool {
    return switch (value) {
        .bool => |flag| flag,
        else => null,
    };
}

fn jsonUsize(value: std.json.Value) ?usize {
    return switch (value) {
        .integer => |int| if (int >= 0) @intCast(int) else null,
        .number_string => |text| std.fmt.parseInt(usize, text, 10) catch null,
        else => null,
    };
}

fn jsonU16(value: std.json.Value) ?u16 {
    return switch (value) {
        .integer => |int| if (int >= 0 and int <= std.math.maxInt(u16)) @intCast(int) else null,
        .number_string => |text| std.fmt.parseInt(u16, text, 10) catch null,
        else => null,
    };
}

// A capped daemon tail may skip old bytes and begin halfway through an ANSI
// sequence. A fresh parser would print that orphaned suffix (for example
// `20m`) as terminal text. Resume at the first complete escape sequence; for
// the common SGR case, preserve any plain text immediately following its
// recognizable parameter suffix.
fn terminalReplayFromParserBoundary(bytes: []const u8) []const u8 {
    if (bytes.len == 0 or bytes[0] == 0x1b) return bytes;

    var index: usize = 0;
    while (index < bytes.len and isCsiParameterByte(bytes[index])) : (index += 1) {}
    if (index > 0 and index < bytes.len and bytes[index] == 'm') return bytes[index + 1 ..];

    const escape = std.mem.indexOfScalar(u8, bytes, 0x1b) orelse return bytes;
    return bytes[escape..];
}

fn isCsiParameterByte(byte: u8) bool {
    return byte >= 0x30 and byte <= 0x3f;
}

fn looksLikeStaleFullScreenReplay(bytes: []const u8) bool {
    if (hasUnclosedAlternateScreen(bytes)) return true;
    if (bytes.len < DAEMON_REPLAY_MAX_BYTES) return false;

    var csi_count: usize = 0;
    var newline_count: usize = 0;
    var index: usize = 0;
    while (index < bytes.len) : (index += 1) {
        if (bytes[index] == '\n') newline_count += 1;
        if (bytes[index] == 0x1b and index + 1 < bytes.len and bytes[index + 1] == '[') csi_count += 1;
    }
    return csi_count >= 256 and newline_count * 8 < csi_count;
}

fn hasUnclosedAlternateScreen(bytes: []const u8) bool {
    const enter = maxOptionalIndex(&.{
        lastIndexOf(bytes, "\x1b[?1049h"),
        lastIndexOf(bytes, "\x1b[?1047h"),
        lastIndexOf(bytes, "\x1b[?47h"),
    });
    const leave = maxOptionalIndex(&.{
        lastIndexOf(bytes, "\x1b[?1049l"),
        lastIndexOf(bytes, "\x1b[?1047l"),
        lastIndexOf(bytes, "\x1b[?47l"),
    });
    return if (enter) |enter_index| leave == null or enter_index > leave.? else false;
}

fn maxOptionalIndex(values: []const ?usize) ?usize {
    var result: ?usize = null;
    for (values) |value| {
        const index = value orelse continue;
        if (result == null or index > result.?) result = index;
    }
    return result;
}

fn lastIndexOf(haystack: []const u8, needle: []const u8) ?usize {
    var result: ?usize = null;
    var start: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, start, needle)) |index| {
        result = index;
        start = index + 1;
    }
    return result;
}

fn selfExePathAlloc(allocator: std.mem.Allocator) ![:0]u8 {
    return platform_runtime.executablePathAlloc(allocator);
}

fn shouldDeferToTextInput(event: *const sdl.KeyboardEvent) bool {
    if (modifierPressed(event.mod, sdl.Keymod.ctrl)) return false;
    if (modifierPressed(event.mod, sdl.Keymod.alt)) return false;
    if (modifierPressed(event.mod, sdl.Keymod.gui)) return false;

    return switch (event.scancode) {
        .a,
        .b,
        .c,
        .d,
        .e,
        .f,
        .g,
        .h,
        .i,
        .j,
        .k,
        .l,
        .m,
        .n,
        .o,
        .p,
        .q,
        .r,
        .s,
        .t,
        .u,
        .v,
        .w,
        .x,
        .y,
        .z,
        .@"0",
        .@"1",
        .@"2",
        .@"3",
        .@"4",
        .@"5",
        .@"6",
        .@"7",
        .@"8",
        .@"9",
        .space,
        .minus,
        .equals,
        .leftbracket,
        .rightbracket,
        .backslash,
        .semicolon,
        .apostrophe,
        .grave,
        .comma,
        .period,
        .slash,
        => true,
        else => false,
    };
}

fn shouldUseTextInputForTerminalPrintableText(event: *const sdl.KeyboardEvent) bool {
    if (builtin.os.tag != .macos) return false;
    // macOS can deliver duplicate-looking printable input when we synthesize
    // ASCII from key_down while SDL text input is active. Let SDL's composed
    // text event own printable characters on macOS; key_down still handles
    // control/navigation keys and modified terminal shortcuts.
    return shouldDeferToTextInput(event);
}

fn isAsciiTerminalText(input_text: []const u8) bool {
    if (input_text.len == 0) return false;
    for (input_text) |byte| {
        if (byte < 0x20 or byte > 0x7E) return false;
    }
    return true;
}

fn consumedModsFromKeyboardEvent(event: *const sdl.KeyboardEvent, utf8: []const u8) ghostty_vt.input.KeyMods {
    if (utf8.len == 0) return .{};
    return .{
        .shift = modifierPressed(event.mod, sdl.Keymod.shift),
    };
}

fn synthesizeTerminalUtf8(event: *const sdl.KeyboardEvent, buf: *[8]u8) []const u8 {
    if (modifierPressed(event.mod, sdl.Keymod.ctrl)) return "";
    if (modifierPressed(event.mod, sdl.Keymod.alt)) return "";
    if (modifierPressed(event.mod, sdl.Keymod.gui)) return "";

    const shift = modifierPressed(event.mod, sdl.Keymod.shift);
    const caps = modifierPressed(event.mod, sdl.Keymod.caps);
    const scancode_value = @intFromEnum(event.scancode);
    const a_value = @intFromEnum(sdl.Scancode.a);
    const z_value = @intFromEnum(sdl.Scancode.z);
    if (scancode_value >= a_value and scancode_value <= z_value) {
        const base = @as(u8, @intCast(scancode_value - a_value)) + 'a';
        const upper = shift != caps;
        buf[0] = if (upper) std.ascii.toUpper(base) else base;
        return buf[0..1];
    }

    const ch: u8 = switch (event.scancode) {
        .@"0" => if (shift) ')' else '0',
        .@"1" => if (shift) '!' else '1',
        .@"2" => if (shift) '@' else '2',
        .@"3" => if (shift) '#' else '3',
        .@"4" => if (shift) '$' else '4',
        .@"5" => if (shift) '%' else '5',
        .@"6" => if (shift) '^' else '6',
        .@"7" => if (shift) '&' else '7',
        .@"8" => if (shift) '*' else '8',
        .@"9" => if (shift) '(' else '9',
        .space => ' ',
        .minus => if (shift) '_' else '-',
        .equals => if (shift) '+' else '=',
        .leftbracket => if (shift) '{' else '[',
        .rightbracket => if (shift) '}' else ']',
        .backslash => if (shift) '|' else '\\',
        .semicolon => if (shift) ':' else ';',
        .apostrophe => if (shift) '"' else '\'',
        .grave => if (shift) '~' else '`',
        .comma => if (shift) '<' else ',',
        .period => if (shift) '>' else '.',
        .slash => if (shift) '?' else '/',
        else => return "",
    };
    buf[0] = ch;
    return buf[0..1];
}

fn modsFromKeyboardEvent(event: *const sdl.KeyboardEvent) ghostty_vt.input.KeyMods {
    return .{
        .shift = modifierPressed(event.mod, sdl.Keymod.shift),
        .ctrl = modifierPressed(event.mod, sdl.Keymod.ctrl),
        .alt = modifierPressed(event.mod, sdl.Keymod.alt),
        .super = modifierPressed(event.mod, sdl.Keymod.gui),
        .caps_lock = modifierPressed(event.mod, sdl.Keymod.caps),
        .num_lock = modifierPressed(event.mod, sdl.Keymod.num),
    };
}

fn terminalMouseButton(button: u8) ?ghostty_vt.input.MouseButton {
    return switch (button) {
        1 => .left,
        2 => .middle,
        3 => .right,
        4 => .four,
        5 => .five,
        6 => .six,
        7 => .seven,
        8 => .eight,
        9 => .nine,
        else => null,
    };
}

fn modifierPressed(state: sdl.Keymod, mask: u16) bool {
    const state_bits = @as(*const u16, @ptrCast(&state)).*;
    return (state_bits & mask) != 0;
}

fn terminalScrollShortcut(event: *const sdl.KeyboardEvent, rows: u16) ?TerminalScroll {
    if (modifierPressed(event.mod, sdl.Keymod.alt) or modifierPressed(event.mod, sdl.Keymod.gui)) return null;
    const shift = modifierPressed(event.mod, sdl.Keymod.shift);
    const ctrl = modifierPressed(event.mod, sdl.Keymod.ctrl);
    return switch (event.scancode) {
        .pageup => if (shift and !ctrl) .{ .delta = -terminalPageScrollLines(rows) } else null,
        .pagedown => if (shift and !ctrl) .{ .delta = terminalPageScrollLines(rows) } else null,
        .up => if (shift and ctrl) .{ .delta = -KEY_SCROLL_LINES } else null,
        .down => if (shift and ctrl) .{ .delta = KEY_SCROLL_LINES } else null,
        .home => if (shift and ctrl) .top else null,
        .end => if (shift and ctrl) .bottom else null,
        else => null,
    };
}

fn terminalPageScrollLines(rows: u16) isize {
    return @max(@as(isize, @intCast(rows)) - 1, KEY_SCROLL_LINES);
}

fn terminalPasteShortcut(event: *const sdl.KeyboardEvent) bool {
    if (event.scancode != .v) return false;
    if (modifierPressed(event.mod, sdl.Keymod.alt)) return false;
    const ctrl = modifierPressed(event.mod, sdl.Keymod.ctrl);
    const gui = modifierPressed(event.mod, sdl.Keymod.gui);
    // Ctrl+V, Ctrl+Shift+V, Super+V, Super+Shift+V. Note: this steals Ctrl+V
    // from TUIs that bind it (vim insert-mode literal char, etc.) — explicit
    // user request.
    return ctrl != gui;
}

fn terminalCopyShortcut(event: *const sdl.KeyboardEvent) bool {
    if (event.scancode != .c) return false;
    // Stricter than the panel-level copy: this path runs when no selection
    // is active and copies the whole screen, so we require shift to make it
    // an explicit gesture (Ctrl+Shift+C / Super+Shift+C). Bare Ctrl+C falls
    // through to the shell as SIGINT.
    if (modifierPressed(event.mod, sdl.Keymod.alt)) return false;
    if (!modifierPressed(event.mod, sdl.Keymod.shift)) return false;
    const ctrl = modifierPressed(event.mod, sdl.Keymod.ctrl);
    const gui = modifierPressed(event.mod, sdl.Keymod.gui);
    return ctrl != gui;
}

fn mapScancodeToGhostty(scancode: sdl.Scancode) ?ghostty_vt.input.Key {
    return switch (scancode) {
        .a => .key_a,
        .b => .key_b,
        .c => .key_c,
        .d => .key_d,
        .e => .key_e,
        .f => .key_f,
        .g => .key_g,
        .h => .key_h,
        .i => .key_i,
        .j => .key_j,
        .k => .key_k,
        .l => .key_l,
        .m => .key_m,
        .n => .key_n,
        .o => .key_o,
        .p => .key_p,
        .q => .key_q,
        .r => .key_r,
        .s => .key_s,
        .t => .key_t,
        .u => .key_u,
        .v => .key_v,
        .w => .key_w,
        .x => .key_x,
        .y => .key_y,
        .z => .key_z,
        .@"0" => .digit_0,
        .@"1" => .digit_1,
        .@"2" => .digit_2,
        .@"3" => .digit_3,
        .@"4" => .digit_4,
        .@"5" => .digit_5,
        .@"6" => .digit_6,
        .@"7" => .digit_7,
        .@"8" => .digit_8,
        .@"9" => .digit_9,
        .@"return" => .enter,
        .escape => .escape,
        .backspace => .backspace,
        .tab => .tab,
        .space => .space,
        .minus => .minus,
        .equals => .equal,
        .leftbracket => .bracket_left,
        .rightbracket => .bracket_right,
        .backslash => .backslash,
        .semicolon => .semicolon,
        .apostrophe => .quote,
        .grave => .backquote,
        .comma => .comma,
        .period => .period,
        .slash => .slash,
        .capslock => .caps_lock,
        .f1 => .f1,
        .f2 => .f2,
        .f3 => .f3,
        .f4 => .f4,
        .f5 => .f5,
        .f6 => .f6,
        .f7 => .f7,
        .f8 => .f8,
        .f9 => .f9,
        .f10 => .f10,
        .f11 => .f11,
        .f12 => .f12,
        .printscreen => .print_screen,
        .scrolllock => .scroll_lock,
        .pause => .pause,
        .insert => .insert,
        .home => .home,
        .pageup => .page_up,
        .delete => .delete,
        .end => .end,
        .pagedown => .page_down,
        .right => .arrow_right,
        .left => .arrow_left,
        .down => .arrow_down,
        .up => .arrow_up,
        .numlockclear => .num_lock,
        .kp_divide => .numpad_divide,
        .kp_multiply => .numpad_multiply,
        .kp_minus => .numpad_subtract,
        .kp_plus => .numpad_add,
        .kp_enter => .numpad_enter,
        .kp_0 => .numpad_0,
        .kp_1 => .numpad_1,
        .kp_2 => .numpad_2,
        .kp_3 => .numpad_3,
        .kp_4 => .numpad_4,
        .kp_5 => .numpad_5,
        .kp_6 => .numpad_6,
        .kp_7 => .numpad_7,
        .kp_8 => .numpad_8,
        .kp_9 => .numpad_9,
        .kp_period => .numpad_decimal,
        .kp_equals => .numpad_equal,
        .lctrl => .control_left,
        .lshift => .shift_left,
        .lalt => .alt_left,
        .lgui => .meta_left,
        .rctrl => .control_right,
        .rshift => .shift_right,
        .ralt => .alt_right,
        .rgui => .meta_right,
        else => null,
    };
}

fn scancodeCodepoint(scancode: sdl.Scancode) ?u21 {
    return switch (scancode) {
        .a => 'a',
        .b => 'b',
        .c => 'c',
        .d => 'd',
        .e => 'e',
        .f => 'f',
        .g => 'g',
        .h => 'h',
        .i => 'i',
        .j => 'j',
        .k => 'k',
        .l => 'l',
        .m => 'm',
        .n => 'n',
        .o => 'o',
        .p => 'p',
        .q => 'q',
        .r => 'r',
        .s => 's',
        .t => 't',
        .u => 'u',
        .v => 'v',
        .w => 'w',
        .x => 'x',
        .y => 'y',
        .z => 'z',
        .@"0" => '0',
        .@"1" => '1',
        .@"2" => '2',
        .@"3" => '3',
        .@"4" => '4',
        .@"5" => '5',
        .@"6" => '6',
        .@"7" => '7',
        .@"8" => '8',
        .@"9" => '9',
        .space => ' ',
        .minus => '-',
        .equals => '=',
        .leftbracket => '[',
        .rightbracket => ']',
        .backslash => '\\',
        .semicolon => ';',
        .apostrophe => '\'',
        .grave => '`',
        .comma => ',',
        .period => '.',
        .slash => '/',
        else => null,
    };
}

fn terminalZoomDelta(event: *const sdl.KeyboardEvent) ?f32 {
    if (!event.down or event.repeat) return null;
    if (!modifierPressed(event.mod, sdl.Keymod.ctrl)) return null;
    if (modifierPressed(event.mod, sdl.Keymod.alt) or modifierPressed(event.mod, sdl.Keymod.gui)) return null;

    return switch (event.scancode) {
        .minus, .kp_minus => -FONT_SCALE_STEP,
        .equals, .kp_plus, .kp_equals => FONT_SCALE_STEP,
        else => null,
    };
}

fn scaledCellPixelWidth(font_scale: f32) u32 {
    return scaledCellPixels(CELL_PIXEL_WIDTH, font_scale);
}

fn scaledCellPixelHeight(font_scale: f32) u32 {
    return scaledCellPixels(CELL_PIXEL_HEIGHT, font_scale);
}

fn fontScaleForFontSize(font_size: f32) f32 {
    return clampf(font_size / DEFAULT_FONT_SIZE, MIN_FONT_SCALE, MAX_FONT_SCALE);
}

fn scaledCellPixels(base: u32, font_scale: f32) u32 {
    const clamped = clampf(font_scale, MIN_FONT_SCALE, MAX_FONT_SCALE);
    return @max(1, @as(u32, @intFromFloat(@round(@as(f32, @floatFromInt(base)) * clamped))));
}

fn columnsForWidth(width: f32, font_scale: f32) u16 {
    const sanitized = sanitizeViewportDimension(width) orelse return INITIAL_COLS;
    return clampCellCount(
        @intFromFloat(sanitized / @as(f32, @floatFromInt(scaledCellPixelWidth(font_scale)))),
        MIN_COLS,
        MAX_COLS,
    );
}

fn rowsForHeight(height: f32, font_scale: f32) u16 {
    const sanitized = sanitizeViewportDimension(height) orelse return INITIAL_ROWS;
    return clampCellCount(
        @intFromFloat(sanitized / @as(f32, @floatFromInt(scaledCellPixelHeight(font_scale)))),
        MIN_ROWS,
        MAX_ROWS,
    );
}

fn clampCellCount(value: i32, min_value: u16, max_value: u16) u16 {
    return @intCast(@max(@as(i32, min_value), @min(value, @as(i32, max_value))));
}

fn sanitizeViewportDimension(value: f32) ?f32 {
    if (!std.math.isFinite(value)) return null;
    if (value <= 1.0) return null;
    return value;
}

fn terminalLayoutDiagnosticsEnabled() bool {
    const value_ptr = std.c.getenv("VERDE_TERMINAL_LAYOUT_LOG") orelse return false;
    const value = std.mem.span(value_ptr);
    return value.len > 0 and !std.mem.eql(u8, value, "0");
}

fn sanitizeCellCount(value: u16, min_value: u16) u16 {
    return @max(value, min_value);
}

fn pathLabel(path: []const u8) []const u8 {
    const trimmed = std.mem.trimEnd(u8, path, std.fs.path.sep_str);
    if (trimmed.len == 0) return std.fs.path.sep_str;
    const base = std.fs.path.basename(trimmed);
    return if (base.len > 0) base else trimmed;
}

fn launchLabel(allocator: std.mem.Allocator, profile: TerminalLaunchProfile) ![]u8 {
    const label = std.mem.trim(u8, profile.label, &std.ascii.whitespace);
    if (label.len > 0) return allocator.dupe(u8, label);
    const fallback = switch (profile.kind) {
        .shell => "Shell",
        .claude => "Claude",
        .opencode => "OpenCode",
        .codex => "Codex",
        .cursor => "Cursor",
        .custom => if (profile.command.len > 0) profile.command[0] else "Custom",
    };
    return allocator.dupe(u8, fallback);
}

fn commandForProfile(allocator: std.mem.Allocator, profile: TerminalLaunchProfile) ![][:0]u8 {
    return switch (profile.kind) {
        .shell => blk: {
            break :blk dupeCommand(allocator, &.{ defaultInteractiveShell(), "-i" });
        },
        .claude => dupeCommand(allocator, &.{"claude"}),
        .opencode => dupeCommand(allocator, &.{"opencode2"}),
        .codex => dupeCommand(allocator, &.{"codex"}),
        .cursor => dupeCommand(allocator, &.{"cursor"}),
        .custom => {
            if (profile.command.len == 0) return error.EmptyTerminalLaunchCommand;
            return dupeCommand(allocator, profile.command);
        },
    };
}

fn defaultInteractiveShell() []const u8 {
    if (std.c.getenv("SHELL")) |shell_ptr| {
        const shell = std.mem.span(shell_ptr);
        if (shell.len > 0) return shell;
    }
    return switch (builtin.os.tag) {
        .macos => "/bin/zsh",
        .windows => "cmd.exe",
        else => "/bin/bash",
    };
}

fn childTermEnvValue() [:0]const u8 {
    return switch (builtin.os.tag) {
        // macOS does not reliably have Ghostty's terminfo database available
        // to GUI-launched child shells. Use the system-provided entry so zle
        // and curses tools can clear/redraw autosuggestions correctly.
        .macos => "xterm-256color",
        else => "xterm-ghostty",
    };
}

fn childTermProgramEnvValue() [:0]const u8 {
    return switch (builtin.os.tag) {
        .macos => "verde",
        else => "ghostty",
    };
}

fn childLocaleEnvValue() [:0]const u8 {
    return switch (builtin.os.tag) {
        .macos => "en_US.UTF-8",
        else => "C.UTF-8",
    };
}

fn dupeCommand(allocator: std.mem.Allocator, args: []const []const u8) ![][:0]u8 {
    const command = try allocator.alloc([:0]u8, args.len);
    var initialized: usize = 0;
    errdefer {
        for (command[0..initialized]) |arg| allocator.free(arg);
        allocator.free(command);
    }
    for (args, 0..) |arg, index| {
        command[index] = try allocator.dupeZ(u8, arg);
        initialized += 1;
    }
    return command;
}

fn dupeStringSlice(allocator: std.mem.Allocator, values: []const []const u8) ![]const []const u8 {
    if (values.len == 0) return &.{};
    const owned = try allocator.alloc([]const u8, values.len);
    var initialized: usize = 0;
    errdefer {
        for (owned[0..initialized]) |value| allocator.free(value);
        allocator.free(owned);
    }
    for (values, 0..) |value, index| {
        owned[index] = try allocator.dupe(u8, value);
        initialized += 1;
    }
    return owned;
}

fn freeStringSlice(allocator: std.mem.Allocator, values: []const []const u8) void {
    for (values) |value| allocator.free(value);
    if (values.len > 0) allocator.free(values);
}

fn freeCommand(allocator: std.mem.Allocator, command: [][:0]u8) void {
    for (command) |arg| allocator.free(arg);
    allocator.free(command);
}

fn clampf(value: f32, min_value: f32, max_value: f32) f32 {
    return @max(min_value, @min(value, max_value));
}

test "terminal key chords validate the allowlisted vocabulary" {
    const submit = try TerminalKeyChord.parse("enter");
    try std.testing.expectEqual(TerminalKey.enter, submit.key);
    try std.testing.expectEqual(@as(u4, 0), @as(u4, @bitCast(submit.modifiers)));

    const reverse_tab = try TerminalKeyChord.parse("shift+tab");
    try std.testing.expectEqual(TerminalKey.tab, reverse_tab.key);
    try std.testing.expect(reverse_tab.modifiers.shift);

    const cancel = try TerminalKeyChord.parse("ctrl+c");
    try std.testing.expectEqual(TerminalKey.c, cancel.key);
    try std.testing.expect(cancel.modifiers.ctrl);

    const modified_function = try TerminalKeyChord.parse("super+alt+f12");
    try std.testing.expectEqual(TerminalKey.f12, modified_function.key);
    try std.testing.expect(modified_function.modifiers.super);
    try std.testing.expect(modified_function.modifiers.alt);

    try std.testing.expectError(error.UnsupportedKey, TerminalKeyChord.parse("ctrl+raw-sequence"));
    try std.testing.expectError(error.DuplicateModifier, TerminalKeyChord.parse("ctrl+ctrl+c"));
    try std.testing.expectError(error.MultipleKeys, TerminalKeyChord.parse("enter+tab"));
    try std.testing.expectError(error.MissingKey, TerminalKeyChord.parse("ctrl+alt"));
}

test "terminal key encoding uses terminal protocol options" {
    var buffer: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try encodeTerminalKeyChord(&writer, try TerminalKeyChord.parse("enter"), .default);
    try std.testing.expectEqualStrings("\r", writer.buffered());

    writer = std.Io.Writer.fixed(&buffer);
    try encodeTerminalKeyChord(&writer, try TerminalKeyChord.parse("shift+tab"), .default);
    try std.testing.expectEqualStrings("\x1b[Z", writer.buffered());

    writer = std.Io.Writer.fixed(&buffer);
    try encodeTerminalKeyChord(&writer, try TerminalKeyChord.parse("ctrl+c"), .default);
    try std.testing.expectEqualStrings("\x03", writer.buffered());

    writer = std.Io.Writer.fixed(&buffer);
    try encodeTerminalKeyChord(&writer, try TerminalKeyChord.parse("alt+enter"), .default);
    try std.testing.expectEqualStrings("\x1b\r", writer.buffered());
}

test "terminal key encoding follows negotiated terminal input modes" {
    const allocator = std.testing.allocator;
    var terminal = try ghostty_vt.Terminal.init((ghostty_vt.TinyIo.init).io(), allocator, .{
        .cols = 80,
        .rows = 24,
    });
    defer terminal.deinit(allocator);
    var stream = terminal.vtStream();
    defer stream.deinit();

    stream.nextSlice("\x1b[?1h");
    const application_cursor = ghostty_vt.input.KeyEncodeOptions.fromTerminal(&terminal);
    try std.testing.expect(application_cursor.cursor_key_application);

    var buffer: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try encodeTerminalKeyChord(&writer, try TerminalKeyChord.parse("up"), application_cursor);
    try std.testing.expectEqualStrings("\x1bOA", writer.buffered());

    writer = std.Io.Writer.fixed(&buffer);
    try encodeTerminalKeyChord(&writer, try TerminalKeyChord.parse("ctrl+f1"), application_cursor);
    try std.testing.expectEqualStrings("\x1b[1;5P", writer.buffered());

    writer = std.Io.Writer.fixed(&buffer);
    try encodeTerminalKeyChord(&writer, try TerminalKeyChord.parse("f5"), application_cursor);
    try std.testing.expectEqualStrings("\x1b[15~", writer.buffered());

    stream.nextSlice("\x1b[=1;1u");
    const kitty_disambiguate = ghostty_vt.input.KeyEncodeOptions.fromTerminal(&terminal);
    try std.testing.expect(kitty_disambiguate.kitty_flags.disambiguate);

    writer = std.Io.Writer.fixed(&buffer);
    try encodeTerminalKeyChord(&writer, try TerminalKeyChord.parse("shift+enter"), kitty_disambiguate);
    try std.testing.expectEqualStrings("\x1b[13;2u", writer.buffered());
}

test "focus adjacent pane uses split direction" {
    const allocator = std.testing.allocator;
    var dock = try Dock.init(allocator);
    defer dock.deinit(allocator);

    try dock.tabs.append(allocator, try dock.buildSinglePaneTabWithoutSession(allocator));
    const left_id = dock.activePaneConst().?.id;
    try dock.splitActivePane(allocator, .right);
    const right_id = dock.activePaneConst().?.id;

    try std.testing.expectEqual(right_id, dock.activePaneConst().?.id);
    try std.testing.expect(try dock.focusAdjacentPane(allocator, .left));
    try std.testing.expectEqual(left_id, dock.activePaneConst().?.id);
    try std.testing.expect(try dock.focusAdjacentPane(allocator, .right));
    try std.testing.expectEqual(right_id, dock.activePaneConst().?.id);
}

test "persisted layout accepts leaves without session metadata" {
    const allocator = std.testing.allocator;
    var dock = try Dock.init(allocator);
    defer dock.deinit(allocator);

    const old_layout_json =
        \\{
        \\  "active_tab_index": 0,
        \\  "tabs": [{
        \\    "title": "old",
        \\    "active_pane_id": 7,
        \\    "root_node_id": 1,
        \\    "nodes": [{
        \\      "node_id": 1,
        \\      "kind": "leaf",
        \\      "pane_id": 7,
        \\      "terminal_modes": {
        \\        "alternate_screen": true,
        \\        "mouse_event": "any",
        \\        "mouse_format": "sgr"
        \\      }
        \\    }]
        \\  }]
        \\}
    ;

    try dock.applyPersistedLayoutJson(allocator, old_layout_json);
    const pane = dock.activePaneConst().?;
    try std.testing.expectEqual(@as(u32, 7), pane.id);
    try std.testing.expectEqual(@as(?[]u8, null), pane.session_id);
    try std.testing.expectEqual(@as(?TerminalLaunchKind, null), pane.launch_kind);
    try std.testing.expectEqual(TerminalRevivePolicy.attach_or_create, pane.revive_policy);
    try std.testing.expectEqual(PersistedTerminalModes{
        .alternate_screen = true,
        .mouse_event = .any,
        .mouse_format = .sgr,
    }, pane.restored_modes.?);
    try std.testing.expectEqual(@as(i64, 0), dock.activeTabAgentHistoryAt());
    try std.testing.expect(dock.noteActiveTabAgentHistory(1_234));

    const round_trip_json = (try dock.persistedLayoutJson(allocator)).?;
    defer allocator.free(round_trip_json);
    var round_trip = try std.json.parseFromSlice(PersistedWorkspace, allocator, round_trip_json, .{});
    defer round_trip.deinit();
    try std.testing.expectEqual(@as(i64, 1_234), round_trip.value.tabs[0].agent_history_at);
    try std.testing.expectEqual(pane.restored_modes.?, round_trip.value.tabs[0].nodes[0].terminal_modes.?);
}

test "persisted layout rejects out-of-range pane id without replacing live layout" {
    const allocator = std.testing.allocator;
    var dock = try Dock.init(allocator);
    defer dock.deinit(allocator);
    try dock.tabs.append(allocator, try dock.buildSinglePaneTabWithoutSession(allocator));
    const live_pane_id = dock.activePaneConst().?.id;
    const invalid_layout_json =
        \\{
        \\  "active_tab_index": 0,
        \\  "tabs": [{
        \\    "active_pane_id": 4294967295,
        \\    "root_node_id": 1,
        \\    "nodes": [{
        \\      "node_id": 1,
        \\      "kind": "leaf",
        \\      "pane_id": 4294967295
        \\    }]
        \\  }]
        \\}
    ;

    try std.testing.expectError(
        error.InvalidPersistedTerminalLayout,
        dock.applyPersistedLayoutJson(allocator, invalid_layout_json),
    );
    try std.testing.expectEqual(@as(usize, 1), dock.tabs.items.len);
    try std.testing.expectEqual(live_pane_id, dock.activePaneConst().?.id);
}

test "persisted layout rejects shared child references without replacing live layout" {
    const allocator = std.testing.allocator;
    var dock = try Dock.init(allocator);
    defer dock.deinit(allocator);
    try dock.tabs.append(allocator, try dock.buildSinglePaneTabWithoutSession(allocator));
    const live_pane_id = dock.activePaneConst().?.id;
    const invalid_layout_json =
        \\{"tabs":[{
        \\  "active_pane_id":7,"root_node_id":1,"nodes":[
        \\    {"node_id":1,"kind":"split","first_node_id":2,"second_node_id":2},
        \\    {"node_id":2,"kind":"leaf","pane_id":7}
        \\  ]
        \\}]}
    ;

    try std.testing.expectError(
        error.InvalidPersistedTerminalLayout,
        dock.applyPersistedLayoutJson(allocator, invalid_layout_json),
    );
    try std.testing.expectEqual(@as(usize, 1), dock.tabs.items.len);
    try std.testing.expectEqual(live_pane_id, dock.activePaneConst().?.id);
}

test "persisted layout rejects cycles without replacing live layout" {
    const allocator = std.testing.allocator;
    var dock = try Dock.init(allocator);
    defer dock.deinit(allocator);
    try dock.tabs.append(allocator, try dock.buildSinglePaneTabWithoutSession(allocator));
    const live_pane_id = dock.activePaneConst().?.id;
    const invalid_layout_json =
        \\{"tabs":[{
        \\  "active_pane_id":7,"root_node_id":1,"nodes":[
        \\    {"node_id":1,"kind":"split","first_node_id":2,"second_node_id":1},
        \\    {"node_id":2,"kind":"leaf","pane_id":7}
        \\  ]
        \\}]}
    ;

    try std.testing.expectError(
        error.InvalidPersistedTerminalLayout,
        dock.applyPersistedLayoutJson(allocator, invalid_layout_json),
    );
    try std.testing.expectEqual(@as(usize, 1), dock.tabs.items.len);
    try std.testing.expectEqual(live_pane_id, dock.activePaneConst().?.id);
}

test "pane id exhaustion is fallible and never returns a duplicate" {
    const allocator = std.testing.allocator;
    var dock = try Dock.init(allocator);
    defer dock.deinit(allocator);
    _ = try dock.appendDaemonSessionPane(allocator, 1, "session-1");
    _ = try dock.appendDaemonSessionPane(allocator, 2, "session-2");
    _ = try dock.appendDaemonSessionPane(allocator, 3, "session-3");
    dock.next_pane_id = 1;

    try std.testing.expectError(error.PaneIdExhausted, dock.allocatePaneIdWithin(3));
    try std.testing.expectEqualStrings("session-1", dock.paneById(1).?.session_id.?);
    try std.testing.expectEqualStrings("session-2", dock.paneById(2).?.session_id.?);
    try std.testing.expectEqualStrings("session-3", dock.paneById(3).?.session_id.?);
}

test "pane id allocation stays linear at the full id bound" {
    const allocator = std.testing.allocator;
    var dock = try Dock.init(allocator);
    defer dock.deinit(allocator);

    var pane_id: u32 = 1;
    while (pane_id < MAX_PANE_ID) : (pane_id += 1) {
        const node = try allocator.create(PaneNode);
        node.* = .{ .leaf = .{ .id = pane_id } };
        dock.tabs.append(allocator, .{
            .id = pane_id,
            .root = node,
            .active_pane_id = pane_id,
        }) catch |err| {
            allocator.destroy(node);
            return err;
        };
    }
    dock.next_pane_id = 1;
    try std.testing.expectEqual(MAX_PANE_ID, try dock.allocatePaneIdWithin(MAX_PANE_ID));

    const last_node = try allocator.create(PaneNode);
    last_node.* = .{ .leaf = .{ .id = MAX_PANE_ID } };
    dock.tabs.append(allocator, .{
        .id = MAX_PANE_ID,
        .root = last_node,
        .active_pane_id = MAX_PANE_ID,
    }) catch |err| {
        allocator.destroy(last_node);
        return err;
    };
    try std.testing.expectError(error.PaneIdExhausted, dock.allocatePaneIdWithin(MAX_PANE_ID));
}

test "persisted restart revive policy reloads as attach" {
    const allocator = std.testing.allocator;
    var dock = try Dock.init(allocator);
    defer dock.deinit(allocator);

    const layout_json =
        \\{
        \\  "active_tab_index": 0,
        \\  "tabs": [{
        \\    "active_pane_id": 1,
        \\    "root_node_id": 1,
        \\    "nodes": [{
        \\      "node_id": 1,
        \\      "kind": "leaf",
        \\      "pane_id": 1,
        \\      "revive_policy": "restart"
        \\    }]
        \\  }]
        \\}
    ;

    try dock.applyPersistedLayoutJson(allocator, layout_json);
    try std.testing.expectEqual(TerminalRevivePolicy.attach_or_create, dock.activePaneConst().?.revive_policy);
}

test "persisted dock replacement keeps matching live emulator ownership" {
    if (comptime builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var current = try Dock.init(allocator);
    defer current.deinit(allocator);
    try current.restartWithProfile(allocator, "/tmp", .{
        .kind = .custom,
        .label = "projection runtime transfer",
        .command = &.{ "/bin/sh", "-c", "sleep 30" },
    });
    try lifecycle_testing.assignActiveSessionId(&current, allocator, "stable-daemon-session");
    const live_session = current.activePane().?.session.?;

    var replacement = try Dock.init(allocator);
    defer replacement.deinit(allocator);
    try replacement.applyPersistedLayoutJson(allocator,
        \\{
        \\  "tabs": [{
        \\    "title": "persisted replacement",
        \\    "active_pane_id": 42,
        \\    "root_node_id": 1,
        \\    "nodes": [{
        \\      "node_id": 1,
        \\      "kind": "leaf",
        \\      "pane_id": 42,
        \\      "session_id": "stable-daemon-session"
        \\    }]
        \\  }]
        \\}
    );

    try std.testing.expectEqual(@as(usize, 1), replacement.transferRuntimeFrom(&current));
    try std.testing.expect(current.activePane().?.session == null);
    try std.testing.expect(replacement.activePane().?.session.? == live_session);
    try std.testing.expectEqual(@as(u32, 42), replacement.activePane().?.id);
    try std.testing.expectEqualStrings("persisted replacement", replacement.tabs.items[0].title.?);
    try std.testing.expectEqualStrings("/tmp", replacement.cwd.?);
}

test "session ensure preserves a running non-null session" {
    const allocator = std.testing.allocator;
    const FakeSession = struct {
        running: bool,
        deinit_count: *usize,

        fn isRunning(self: *const @This()) bool {
            return self.running;
        }

        fn deinit(self: *@This(), _: std.mem.Allocator) void {
            self.deinit_count.* += 1;
        }
    };

    var deinit_count: usize = 0;
    const session = try allocator.create(FakeSession);
    session.* = .{ .running = true, .deinit_count = &deinit_count };
    var slot: ?*FakeSession = session;
    defer if (slot) |remaining| allocator.destroy(remaining);

    try std.testing.expect(!prepareSessionSlotForCreate(FakeSession, allocator, &slot));
    try std.testing.expect(slot.? == session);
    try std.testing.expectEqual(@as(usize, 0), deinit_count);
}

test "session ensure releases a stopped non-null session" {
    const allocator = std.testing.allocator;
    const FakeSession = struct {
        running: bool,
        deinit_count: *usize,

        fn isRunning(self: *const @This()) bool {
            return self.running;
        }

        fn deinit(self: *@This(), _: std.mem.Allocator) void {
            self.deinit_count.* += 1;
        }
    };

    var deinit_count: usize = 0;
    const session = try allocator.create(FakeSession);
    session.* = .{ .running = false, .deinit_count = &deinit_count };
    var slot: ?*FakeSession = session;

    try std.testing.expect(prepareSessionSlotForCreate(FakeSession, allocator, &slot));
    try std.testing.expectEqual(@as(?*FakeSession, null), slot);
    try std.testing.expectEqual(@as(usize, 1), deinit_count);
}

test "closing a restored tab without a live session does not claim teardown ownership" {
    const allocator = std.testing.allocator;
    var dock = try Dock.init(allocator);
    defer dock.deinit(allocator);

    const first_session_id = try allocator.dupe(u8, "session-a");
    const first_node = allocator.create(PaneNode) catch |err| {
        allocator.free(first_session_id);
        return err;
    };
    first_node.* = .{ .leaf = .{ .id = 1, .session_id = first_session_id } };
    dock.tabs.append(allocator, .{ .id = 1, .root = first_node, .active_pane_id = 1 }) catch |err| {
        deinitPaneNode(first_node, allocator);
        return err;
    };

    const second_session_id = try allocator.dupe(u8, "session-b");
    const second_node = allocator.create(PaneNode) catch |err| {
        allocator.free(second_session_id);
        return err;
    };
    second_node.* = .{ .leaf = .{ .id = 2, .session_id = second_session_id } };
    dock.tabs.append(allocator, .{ .id = 2, .root = second_node, .active_pane_id = 2 }) catch |err| {
        deinitPaneNode(second_node, allocator);
        return err;
    };

    try dock.closeTab(allocator, 0);
    try std.testing.expect(dock.takeSessionTeardown() == null);
    try std.testing.expect(dock.takeSessionTeardown() == null);
    try std.testing.expectEqual(@as(usize, 1), dock.tabs.items.len);
    try std.testing.expectEqualStrings("session-b", dock.tabs.items[0].root.leaf.session_id.?);
}

test "terminal teardown survives daemon unavailability or termination failure until confirmed" {
    try std.testing.expect(sessionTeardownNeedsTermination(.{ .running = true }));
    try std.testing.expect(resolveSessionTeardown(
        .{ .running = false, .confirmed_exit = false },
        true,
        .pane_closed,
    ) == null);
    try std.testing.expect(resolveSessionTeardown(
        .{ .running = true },
        false,
        .pane_closed,
    ) == null);
    try std.testing.expect(sessionTeardownNeedsTermination(.{ .running = true, .confirmed_exit = false }));

    const exited = resolveSessionTeardown(
        .{ .running = false, .confirmed_exit = true, .exit_code = 17 },
        false,
        .pane_closed,
    ).?;
    try std.testing.expectEqual(@as(?u32, 17), exited.exit_code);
    try std.testing.expectEqual(@as(?u32, null), exited.signal);
    try std.testing.expect(exited.cancellation_reason == null);

    const cancelled = resolveSessionTeardown(
        .{ .running = false, .confirmed_exit = true, .signal = 15 },
        true,
        .restarted,
    ).?;
    try std.testing.expectEqual(@as(?u32, 15), cancelled.signal);
    try std.testing.expectEqualStrings("terminal restarted", cancelled.cancellation_reason.?);
}

test "daemon kill response requires an accepted signal" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(
        error.SessionTerminationNotSignaled,
        ensureSessionKillSignaled(allocator, "{\"result\":{\"accepted\":true,\"signaled\":false}}"),
    );
    try ensureSessionKillSignaled(allocator, "{\"result\":{\"accepted\":true,\"signaled\":true}}");
    try std.testing.expectError(
        error.SessionRequestFailed,
        ensureSessionKillSignaled(allocator, "{\"error\":{\"code\":\"not_found\"}}"),
    );
}

test "unsignaled daemon kill response keeps a real teardown pending until observed exit" {
    if (comptime builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var dock = try Dock.init(allocator);
    defer dock.deinit(allocator);
    try dock.restartWithProfile(allocator, "/tmp", .{
        .kind = .custom,
        .label = "unsignaled daemon teardown",
        .command = &.{ "/bin/sh", "-c", "sleep 30" },
    });
    try lifecycle_testing.assignActiveSessionId(&dock, allocator, "unsignaled-daemon-session");
    try lifecycle_testing.simulateActiveDaemonKillResponse(
        &dock,
        "{\"result\":{\"accepted\":true,\"signaled\":false}}",
    );

    try dock.closeTab(allocator, 0);
    var teardown = dock.takeSessionTeardown() orelse return error.MissingSessionTeardown;
    defer teardown.deinit(allocator);
    defer lifecycle_testing.restoreTeardownLocal(&teardown);
    if (teardown.cancellation_initiated) return error.UnexpectedCancellationInitiation;
    if ((try teardown.poll(allocator)) != null) return error.UnexpectedEarlyTeardownCompletion;

    lifecycle_testing.signalTeardownForConfirmedExit(&teardown);
    var attempts: usize = 0;
    var snapshot: SessionSnapshot = .{ .running = true };
    while (attempts < 100 and !snapshot.confirmed_exit) : (attempts += 1) {
        snapshot = try lifecycle_testing.pollTeardownSession(&teardown, allocator);
        if (!snapshot.confirmed_exit) try std.Io.sleep(std.testing.io, .fromMilliseconds(10), .awake);
    }
    if (!snapshot.confirmed_exit) return error.UnconfirmedTerminalExit;
    const completion = try teardown.poll(allocator);
    const result = completion orelse return error.UnconfirmedTerminalExit;
    if (result.signal != @as(?u32, @intFromEnum(std.posix.SIG.TERM))) return error.UnexpectedTerminalSignal;
    if (result.cancellation_reason != null) return error.UnexpectedCancellationReason;
}

test "real teardown keeps unavailable live identity, completes missing, and preserves exit" {
    if (comptime builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var unavailable_dock = try Dock.init(allocator);
    defer unavailable_dock.deinit(allocator);
    try unavailable_dock.restartWithProfile(allocator, "/tmp", .{
        .kind = .custom,
        .label = "unavailable teardown",
        .command = &.{ "/bin/sh", "-c", "sleep 30" },
    });
    try lifecycle_testing.assignActiveSessionId(&unavailable_dock, allocator, "live-unavailable-session");
    const unavailable_leaf = unavailable_dock.activePane() orelse return error.MissingTerminalPane;
    const live_session_id = try allocator.dupe(u8, unavailable_leaf.session.?.sessionId() orelse return error.MissingSessionId);
    defer allocator.free(live_session_id);
    if (unavailable_leaf.session_id) |stored| allocator.free(stored);
    unavailable_leaf.session_id = try allocator.dupe(u8, "stale-persisted-session");
    unavailable_leaf.session.?.backend = .daemon;
    unavailable_leaf.session.?.daemon_state = .unavailable;
    unavailable_leaf.session.?.running = false;

    try unavailable_dock.closeTab(allocator, 0);
    var unavailable = unavailable_dock.takeSessionTeardown() orelse return error.MissingSessionTeardown;
    defer {
        unavailable.session.backend = .local;
        unavailable.session.daemon_state = .attached;
        unavailable.session.running = true;
        unavailable.deinit(allocator);
    }
    try std.testing.expectEqualStrings(live_session_id, unavailable.sessionId().?);
    try std.testing.expect((try unavailable.poll(allocator)) == null);
    try std.testing.expect(!unavailable.cancellation_initiated);
    unavailable.session.daemon_state = .missing;
    try std.testing.expect(!unavailable.session.snapshot().confirmed_exit);
    const missing = (try unavailable.poll(allocator)) orelse return error.MissingTeardownCompletion;
    try std.testing.expectEqual(@as(?u32, null), missing.exit_code);
    try std.testing.expectEqual(@as(?u32, null), missing.signal);
    try std.testing.expect(missing.cancellation_reason == null);

    var exited_dock = try Dock.init(allocator);
    defer exited_dock.deinit(allocator);
    try exited_dock.restartWithProfile(allocator, "/tmp", .{
        .kind = .custom,
        .label = "already exited teardown",
        .command = &.{ "/bin/sh", "-c", "exit 17" },
    });
    try lifecycle_testing.assignActiveSessionId(&exited_dock, allocator, "already-exited-session");
    var attempts: usize = 0;
    while (attempts < 100 and !(exited_dock.activeSessionSnapshot() orelse SessionSnapshot{ .running = false }).confirmed_exit) : (attempts += 1) {
        _ = try exited_dock.poll(allocator);
        try std.Io.sleep(std.testing.io, .fromMilliseconds(10), .awake);
    }
    try std.testing.expect((exited_dock.activeSessionSnapshot() orelse return error.MissingSessionSnapshot).confirmed_exit);
    try exited_dock.closeTab(allocator, 0);
    var exited = exited_dock.takeSessionTeardown() orelse return error.MissingSessionTeardown;
    defer exited.deinit(allocator);
    const completion = (try exited.poll(allocator)) orelse return error.UnconfirmedTerminalExit;
    try std.testing.expectEqual(@as(?u32, 17), completion.exit_code);
    try std.testing.expect(completion.cancellation_reason == null);
}

test "automatic terminal restart uses capped exponential backoff" {
    var backoff: AutoRestartBackoff = .{};
    const expected_delays = [_]i64{ 1_000, 2_000, 4_000, 8_000, 16_000, 30_000, 30_000 };
    var now_ms: i64 = 10_000;

    for (expected_delays) |delay_ms| {
        try std.testing.expect(backoff.reserve(now_ms));
        try std.testing.expectEqual(now_ms + delay_ms, backoff.retry_after_ms);
        try std.testing.expect(!backoff.reserve(backoff.retry_after_ms - 1));
        now_ms = backoff.retry_after_ms;
    }

    try std.testing.expectEqual(@as(u8, @intCast(expected_delays.len)), backoff.attempts);
    try std.testing.expectEqual(AUTO_RESTART_MAX_DELAY_MS, autoRestartDelayMs(backoff.attempts));
}

test "automatic terminal restart retains stopped render state after creation" {
    var backoff: AutoRestartBackoff = .{};

    // Explicit starts do not reserve an automatic attempt first, but still
    // need a hold so their stopped VT model reaches the renderer.
    backoff.armAfterCreate(1_000, true);
    try std.testing.expectEqual(@as(u8, 1), backoff.attempts);
    try std.testing.expectEqual(@as(i64, 2_000), backoff.retry_after_ms);

    // Anchor a full delay at the transition to stopped, rather than leaving
    // only the unused remainder of the delay that began before the shell ran.
    backoff.observeHealth(1_900, false);
    try std.testing.expectEqual(@as(?i64, 1_900), backoff.stopped_since_ms);
    try std.testing.expectEqual(@as(i64, 2_900), backoff.retry_after_ms);
    try std.testing.expect(!backoff.reserve(2_899));
    try std.testing.expect(backoff.reserve(2_900));

    // Creation time can move past work done by the reservation; extend the
    // next deadline without double-counting the attempt.
    backoff.armAfterCreate(3_000, false);
    try std.testing.expectEqual(@as(u8, 2), backoff.attempts);
    try std.testing.expectEqual(@as(i64, 5_000), backoff.retry_after_ms);
    try std.testing.expectEqual(@as(?i64, 3_000), backoff.stopped_since_ms);
}

test "automatic terminal restart resets only after continuous health" {
    var backoff: AutoRestartBackoff = .{};
    try std.testing.expect(backoff.reserve(1_000));

    backoff.observeHealth(1_500, true);
    backoff.observeHealth(5_000, true);
    try std.testing.expectEqual(@as(u8, 1), backoff.attempts);

    backoff.observeHealth(6_000, false);
    try std.testing.expectEqual(@as(?i64, null), backoff.healthy_since_ms);
    backoff.observeHealth(7_000, true);
    backoff.observeHealth(16_999, true);
    try std.testing.expectEqual(@as(u8, 1), backoff.attempts);

    backoff.observeHealth(17_000, true);
    try std.testing.expectEqual(@as(u8, 0), backoff.attempts);
    try std.testing.expectEqual(@as(i64, 0), backoff.retry_after_ms);
    try std.testing.expectEqual(@as(?i64, null), backoff.healthy_since_ms);
    try std.testing.expectEqual(@as(?i64, null), backoff.stopped_since_ms);
}

test "unix session PTY smoke" {
    if (!SESSION_SUPPORTED) return error.SkipZigTest;

    const testing = std.testing;
    const allocator = testing.allocator;
    const cwd = try std.process.currentPathAlloc(testing.io, allocator);
    defer allocator.free(cwd);

    const session = try UnixSession.create(allocator, .{
        .cwd = cwd,
        .cols = 80,
        .rows = 24,
    });
    defer {
        session.deinit(allocator);
        allocator.destroy(session);
    }

    _ = try session.writeInput("printf 'verde-terminal-smoke'\r");

    var found = false;
    var saw_change = false;
    for (0..40) |_| {
        if (try session.poll(allocator)) saw_change = true;
        const screen = try session.terminal.plainString(allocator);
        defer allocator.free(screen);
        if (std.mem.indexOf(u8, screen, "verde-terminal-smoke") != null) {
            found = true;
            break;
        }
        try std.Io.sleep(testing.io, .fromMilliseconds(50), .awake);
    }

    try testing.expect(saw_change);
    try testing.expect(found);

    _ = try session.writeInput("exit\r");
    for (0..40) |_| {
        _ = try session.poll(allocator);
        if (!session.running) break;
        try std.Io.sleep(testing.io, .fromMilliseconds(25), .awake);
    }
}

test "unix session clears render dirty state after render" {
    if (!SESSION_SUPPORTED) return error.SkipZigTest;

    const testing = std.testing;
    const allocator = testing.allocator;
    const cwd = try std.process.currentPathAlloc(testing.io, allocator);
    defer allocator.free(cwd);

    const session = try UnixSession.create(allocator, .{
        .cwd = cwd,
        .cols = 80,
        .rows = 24,
    });
    defer {
        session.deinit(allocator);
        allocator.destroy(session);
    }

    try testing.expect(session.render_state.dirty != .false);
    session.markRendered();
    try testing.expectEqual(.false, session.render_state.dirty);

    const row_data = session.render_state.row_data.slice();
    const row_dirties = row_data.items(.dirty);
    for (row_dirties) |dirty| {
        try testing.expect(!dirty);
    }
}

test "unix session alternate-screen resize follows terminal model without clearing" {
    if (!SESSION_SUPPORTED) return error.SkipZigTest;

    const testing = std.testing;
    const allocator = testing.allocator;
    const cwd = try std.process.currentPathAlloc(testing.io, allocator);
    defer allocator.free(cwd);

    const session = try UnixSession.create(allocator, .{
        .cwd = cwd,
        .cols = 80,
        .rows = 10,
    });
    defer {
        session.deinit(allocator);
        allocator.destroy(session);
    }

    session.stream.nextSlice(
        "\x1b[?1049h" ++
            "ALT-KEEP-01\r\n" ++
            "ALT-KEEP-02\r\n" ++
            "ALT-KEEP-03\r\n" ++
            "ALT-KEEP-04\r\n" ++
            "ALT-KEEP-05\r\n" ++
            "ALT-KEEP-06\r\n" ++
            "ALT-KEEP-07\r\n" ++
            "ALT-KEEP-08\r\n" ++
            "ALT-KEEP-09",
    );
    try session.refreshRenderState(allocator);

    try testing.expectEqual(.alternate, session.terminal.screens.active_key);

    try session.resize(allocator, 80, 6, CELL_PIXEL_WIDTH, CELL_PIXEL_HEIGHT);
    try testing.expectEqual(@as(u16, 80), session.cols);
    try testing.expectEqual(@as(u16, 80), session.terminal.cols);
    try testing.expectEqual(@as(u16, 6), session.rows);
    try testing.expectEqual(@as(u16, 6), session.terminal.rows);

    const screen = try session.terminal.plainString(allocator);
    defer allocator.free(screen);

    try testing.expect(std.mem.indexOf(u8, screen, "ALT-KEEP-04") != null);
    try testing.expect(std.mem.indexOf(u8, screen, "ALT-KEEP-09") != null);

    try session.resize(allocator, 80, 12, CELL_PIXEL_WIDTH, CELL_PIXEL_HEIGHT);
    try testing.expectEqual(@as(u16, 80), session.cols);
    try testing.expectEqual(@as(u16, 80), session.terminal.cols);
    try testing.expectEqual(@as(u16, 12), session.rows);
    try testing.expectEqual(@as(u16, 12), session.terminal.rows);
}

test "unix session restores alternate screen and mouse modes before daemon replay" {
    if (!SESSION_SUPPORTED) return error.SkipZigTest;

    const testing = std.testing;
    const allocator = testing.allocator;
    const cwd = try std.process.currentPathAlloc(testing.io, allocator);
    defer allocator.free(cwd);

    const session = try UnixSession.create(allocator, .{
        .cwd = cwd,
        .cols = 80,
        .rows = 24,
    });
    defer {
        session.deinit(allocator);
        allocator.destroy(session);
    }

    session.applyRestoredTerminalModes(.{
        .alternate_screen = true,
        .mouse_event = .any,
        .mouse_format = .sgr,
    });
    try testing.expectEqual(PersistedTerminalModes{
        .alternate_screen = true,
        .mouse_event = .any,
        .mouse_format = .sgr,
    }, session.persistedTerminalModes());
}

test "discontinuous terminal replay drops an orphaned escape suffix" {
    const testing = std.testing;

    try testing.expectEqualStrings(
        "prompt",
        terminalReplayFromParserBoundary("20mprompt"),
    );
    try testing.expectEqualStrings(
        "\x1b[38;5;174mcolored",
        terminalReplayFromParserBoundary("5;174mgarbage\x1b[38;5;174mcolored"),
    );
    try testing.expectEqualStrings(
        "plain output",
        terminalReplayFromParserBoundary("plain output"),
    );
    try testing.expectEqualStrings(
        "\x1b[0mcomplete",
        terminalReplayFromParserBoundary("\x1b[0mcomplete"),
    );
}

test "terminal geometry sanitization never returns zero cells" {
    const testing = std.testing;

    try testing.expectEqual(@as(u16, INITIAL_COLS), columnsForWidth(0.0, 1.0));
    try testing.expectEqual(@as(u16, INITIAL_COLS), columnsForWidth(-40.0, 1.0));
    try testing.expectEqual(@as(u16, INITIAL_COLS), columnsForWidth(std.math.nan(f32), 1.0));
    try testing.expectEqual(@as(u16, INITIAL_ROWS), rowsForHeight(0.0, 1.0));
    try testing.expectEqual(@as(u16, INITIAL_ROWS), rowsForHeight(-10.0, 1.0));
    try testing.expectEqual(@as(u16, INITIAL_ROWS), rowsForHeight(std.math.nan(f32), 1.0));
}

test "repair terminal state resets invalid scrolling region" {
    if (!SESSION_SUPPORTED) return error.SkipZigTest;

    const testing = std.testing;
    const allocator = testing.allocator;
    const cwd = try std.process.currentPathAlloc(testing.io, allocator);
    defer allocator.free(cwd);

    const session = try UnixSession.create(allocator, .{
        .cwd = cwd,
        .cols = 80,
        .rows = 24,
    });
    defer {
        session.deinit(allocator);
        allocator.destroy(session);
    }

    session.terminal.scrolling_region.left = 0;
    session.terminal.scrolling_region.right = 0;
    session.terminal.scrolling_region.top = 99;
    session.terminal.scrolling_region.bottom = 0;

    try session.repairTerminalState(allocator);

    try testing.expectEqual(@as(@TypeOf(session.terminal.scrolling_region.left), 0), session.terminal.scrolling_region.left);
    try testing.expectEqual(session.terminal.cols - 1, session.terminal.scrolling_region.right);
    try testing.expectEqual(@as(@TypeOf(session.terminal.scrolling_region.top), 0), session.terminal.scrolling_region.top);
    try testing.expectEqual(session.terminal.rows - 1, session.terminal.scrolling_region.bottom);
}

fn claudeBackgroundShells(model: *const ghostty_vt.Terminal) bool {
    const pages = &model.screens.active.pages;
    var y = model.rows -| 3;
    while (y < model.rows) : (y += 1) {
        const pin = pages.pin(.{ .active = .{ .x = 0, .y = y } }) orelse continue;
        var buffer: [2048]u8 = undefined;
        var len: usize = 0;
        for (pin.cells(.all)) |cell| {
            if (cell.wide == .spacer_tail) continue;
            const cp = if (cell.hasText()) cell.codepoint() else ' ';
            if (len + 4 > buffer.len) break;
            len += std.unicode.utf8Encode(cp, buffer[len..]) catch continue;
        }
        if (@import("claude_activity.zig").footerHasBackgroundShells(buffer[0..len])) return true;
    }
    return false;
}

test "Claude background shell footer follows live screen and clears after completion" {
    const allocator = std.testing.allocator;
    var model = try ghostty_vt.Terminal.init((ghostty_vt.TinyIo.init).io(), allocator, .{ .cols = 100, .rows = 10 });
    defer model.deinit(allocator);
    var stream = model.vtStream();
    defer stream.deinit();
    stream.nextSlice("old output\r\n" ** 20);
    stream.nextSlice("\x1b[9;1Hbypass permissions on · 1 shell · ← for agents");
    try std.testing.expect(claudeBackgroundShells(&model));
    model.scrollViewport(.top);
    try std.testing.expect(claudeBackgroundShells(&model));
    stream.nextSlice("\x1b[9;1H\x1b[2Kbypass permissions on");
    try std.testing.expect(!claudeBackgroundShells(&model));
    stream.nextSlice("\x1b[2;1Hbypass permissions on · 1 shell · ← for agents");
    try std.testing.expect(!claudeBackgroundShells(&model));
}
