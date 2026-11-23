//! OSC 7501 Program Status Protocol (rev 0.4) observer for daemon-owned PTYs.
//!
//! The pinned libghostty-vt predates upstream's `program_status` OSC parser,
//! and the daemon never runs a VT engine, so the session daemon pre-scans raw
//! PTY output here. Bytes are only observed, never altered: the GUI/web VT
//! still receives the full stream and ignores the unknown OSC as before.
//!
//! Spec: https://www.superlogical.com/rex/docs/build/program-status
const std = @import("std");

pub const State = enum { idle, working, done, blocked, @"error" };
pub const Kind = enum { permission, question, auth };

/// Verde surface statuses a report can produce; tag names match
/// `db_types.SurfaceStatus`.
pub const SurfaceStatus = enum { working, waiting, done, @"error" };

/// Whole sequence, `OSC` through `ST`.
pub const MAX_SEQUENCE_BYTES: usize = 4096;
/// Body bytes between `ESC ]` and the shortest legal terminator (`BEL`).
const MAX_BODY_BYTES: usize = MAX_SEQUENCE_BYTES - 3;
/// The spec allows terminals to lower its 256-record cap down to 64.
pub const MAX_RECORDS: usize = 64;
const MAX_KEY_BYTES: usize = 16;
const MAX_MSG_ENCODED: usize = 2732;
const MAX_MSG_DECODED: usize = 2048;
const MAX_TITLE_ENCODED: usize = 256;
const MAX_TITLE_DECODED: usize = 192;
const MAX_APP_BYTES: usize = 32;
const MAX_ID_BYTES: usize = 128;
const MAX_ID_SEGMENT_BYTES: usize = 32;
const MAX_ID_DEPTH: usize = 8;
/// Records keep a shortened `msg` for notification bodies (spec: terminals
/// MAY shorten it), bounding per-pane memory.
const KEPT_MSG_BYTES: usize = 240;
/// Coalesces bursts so a program flapping states cannot flood the store,
/// the GUI notifier, or attached clients (spec: SHOULD rate-limit).
pub const MIN_PUBLISH_INTERVAL_MS: i64 = 250;
const MAX_PENDING_REPLIES: u8 = 4;

const OSC_7501_PREFIX = "7501;";
const OSC_133_PREFIX = "133;";
/// Feature-detection reply body. It contains nothing from any report.
const QUERY_REPLY_BODY = "\x1b]7501;?:states=idle,working,done,blocked,error:kinds=permission,question,auth";
pub const QUERY_REPLY_ST = QUERY_REPLY_BODY ++ "\x1b\\";
pub const QUERY_REPLY_BEL = QUERY_REPLY_BODY ++ "\x07";

/// One decoded report. Slices borrow the parsed body or the caller's scratch.
pub const Report = struct {
    /// `null` is `state=clear`.
    state: ?State,
    /// Empty addresses the root record.
    id: []const u8 = "",
    kind: ?Kind = null,
    progress: ?u8 = null,
    app: []const u8 = "",
    msg: []const u8 = "",
};

pub const Parsed = union(enum) {
    query,
    report: Report,
    /// Unknown state, broken limit, bad id, bad base64, or control text.
    ignored,
};

pub const Scratch = struct {
    msg: [MAX_MSG_DECODED]u8 = undefined,
    title: [MAX_TITLE_DECODED]u8 = undefined,
};

/// Parses the body after `7501;`. Nothing is applied for an ignored report.
pub fn parseBody(body: []const u8, scratch: *Scratch) Parsed {
    const trimmed = std.mem.trim(u8, body, " \t");
    if (std.mem.eql(u8, trimmed, "?")) return .query;

    var state_value: ?[]const u8 = null;
    var id_value: ?[]const u8 = null;
    var kind_value: ?[]const u8 = null;
    var progress_value: ?[]const u8 = null;
    var app_value: ?[]const u8 = null;
    var title_value: ?[]const u8 = null;
    var msg_value: ?[]const u8 = null;

    var pairs = std.mem.splitScalar(u8, body, ':');
    while (pairs.next()) |raw_pair| {
        const equals = std.mem.indexOfScalar(u8, raw_pair, '=') orelse continue;
        const key = std.mem.trim(u8, raw_pair[0..equals], " \t");
        const value = std.mem.trim(u8, raw_pair[equals + 1 ..], " \t");
        if (key.len > MAX_KEY_BYTES) return .ignored;
        if (key.len == 0 or !allBytes(key, isKeyByte) or !allBytes(value, isValueByte)) continue;
        // Repeated keys: the last value wins.
        if (std.mem.eql(u8, key, "state")) {
            state_value = value;
        } else if (std.mem.eql(u8, key, "id")) {
            id_value = value;
        } else if (std.mem.eql(u8, key, "kind")) {
            kind_value = value;
        } else if (std.mem.eql(u8, key, "progress")) {
            progress_value = value;
        } else if (std.mem.eql(u8, key, "app")) {
            app_value = value;
        } else if (std.mem.eql(u8, key, "title")) {
            title_value = value;
        } else if (std.mem.eql(u8, key, "msg")) {
            msg_value = value;
        }
    }

    const raw_state = state_value orelse return .ignored;
    const state: ?State = if (std.mem.eql(u8, raw_state, "clear"))
        null
    else
        std.meta.stringToEnum(State, raw_state) orelse return .ignored;

    var report: Report = .{ .state = state };
    if (id_value) |id| {
        if (!validId(id)) return .ignored;
        report.id = id;
    }
    if (app_value) |app| {
        if (app.len > MAX_APP_BYTES) return .ignored;
        if (app.len > 0 and allBytes(app, isNameByte)) report.app = app;
    }
    if (title_value) |title| {
        if (title.len > MAX_TITLE_ENCODED) return .ignored;
        // Titles label child records; Verde only validates them.
        _ = decodeText(title, &scratch.title) orelse return .ignored;
    }
    if (msg_value) |msg| {
        if (msg.len > MAX_MSG_ENCODED) return .ignored;
        report.msg = decodeText(msg, &scratch.msg) orelse return .ignored;
    }
    if (state == .blocked) {
        if (kind_value) |kind| report.kind = std.meta.stringToEnum(Kind, kind);
    }
    if (state == .working or state == .blocked) {
        if (progress_value) |progress| report.progress = parseProgress(progress);
    }
    return .{ .report = report };
}

pub const Record = struct {
    id_buf: [MAX_ID_BYTES]u8 = undefined,
    id_len: u8 = 0,
    state: State,
    kind: ?Kind = null,
    app_buf: [MAX_APP_BYTES]u8 = undefined,
    app_len: u8 = 0,
    msg_buf: [KEPT_MSG_BYTES]u8 = undefined,
    msg_len: u16 = 0,
    updated: u64 = 0,

    pub fn id(self: *const Record) []const u8 {
        return self.id_buf[0..self.id_len];
    }

    pub fn app(self: *const Record) []const u8 {
        return self.app_buf[0..self.app_len];
    }

    pub fn msg(self: *const Record) []const u8 {
        return self.msg_buf[0..self.msg_len];
    }
};

/// The one record that represents the pane: blocked beats working beats
/// error beats done beats idle; ties go to the most recently updated record.
pub const Aggregate = struct {
    state: State,
    kind: ?Kind,
    /// Own `app`, else the nearest ancestor's.
    app: []const u8,
    msg: []const u8,
};

/// Streaming OSC scanner plus the pane's record set.
pub const Tracker = struct {
    const ScanState = enum { ground, escape, osc, osc_escape, osc_skip, osc_skip_escape };

    records: std.ArrayList(Record) = .empty,
    tick: u64 = 0,
    scan: ScanState = .ground,
    body: [MAX_BODY_BYTES]u8 = undefined,
    body_len: usize = 0,
    body_overflow: bool = false,
    pending_replies: u8 = 0,
    reply_with_bel: bool = false,
    /// Set by any applied report; the owner reads and resets it.
    reported: bool = false,
    /// Set by OSC 133 `A` or `RIS`; the owner reads and resets it.
    prompt_seen: bool = false,

    pub fn deinit(self: *Tracker, allocator: std.mem.Allocator) void {
        self.records.deinit(allocator);
    }

    /// Observes PTY output. Allocation failure drops only the report.
    pub fn feed(self: *Tracker, allocator: std.mem.Allocator, bytes: []const u8) void {
        for (bytes) |byte| self.step(allocator, byte);
    }

    /// Next feature-detection reply to write back to the PTY, if any.
    pub fn takeReply(self: *Tracker) ?[]const u8 {
        if (self.pending_replies == 0) return null;
        self.pending_replies -= 1;
        return if (self.reply_with_bel) QUERY_REPLY_BEL else QUERY_REPLY_ST;
    }

    /// Process exit or a new shell prompt: drop `working` and `blocked`
    /// (MUST) and `idle` (MAY); `done` and `error` survive.
    pub fn dropLive(self: *Tracker) void {
        var index: usize = 0;
        while (index < self.records.items.len) {
            switch (self.records.items[index].state) {
                .working, .blocked, .idle => _ = self.records.orderedRemove(index),
                .done, .@"error" => index += 1,
            }
        }
    }

    pub fn hasLive(self: *const Tracker) bool {
        for (self.records.items) |record| {
            if (record.state == .working or record.state == .blocked) return true;
        }
        return false;
    }

    pub fn aggregate(self: *const Tracker) ?Aggregate {
        var best: ?*const Record = null;
        for (self.records.items) |*record| {
            const current = best orelse {
                best = record;
                continue;
            };
            const rank = stateRank(record.state);
            const best_rank = stateRank(current.state);
            if (rank > best_rank or (rank == best_rank and record.updated > current.updated)) best = record;
        }
        const record = best orelse return null;
        return .{
            .state = record.state,
            .kind = record.kind,
            .app = self.inheritedApp(record),
            .msg = record.msg(),
        };
    }

    pub fn apply(self: *Tracker, allocator: std.mem.Allocator, report: Report) void {
        const state = report.state orelse {
            self.clear(report.id);
            self.reported = true;
            return;
        };
        const record = self.find(report.id) orelse created: {
            if (self.records.items.len >= MAX_RECORDS) _ = self.records.orderedRemove(self.leastRecentlyUpdated());
            self.records.append(allocator, .{ .state = state }) catch return;
            break :created &self.records.items[self.records.items.len - 1];
        };
        // Each report replaces its record completely.
        self.tick +%= 1;
        record.* = .{ .state = state, .kind = report.kind, .updated = self.tick };
        @memcpy(record.id_buf[0..report.id.len], report.id);
        record.id_len = @intCast(report.id.len);
        @memcpy(record.app_buf[0..report.app.len], report.app);
        record.app_len = @intCast(report.app.len);
        const kept = keptDisplayText(report.msg, &record.msg_buf);
        record.msg_len = @intCast(kept.len);
        self.reported = true;
    }

    fn step(self: *Tracker, allocator: std.mem.Allocator, byte: u8) void {
        switch (self.scan) {
            .ground => if (byte == 0x1b) {
                self.scan = .escape;
            },
            .escape => self.stepEscape(byte),
            .osc => switch (byte) {
                0x07 => self.finishOsc(allocator, true),
                0x1b => self.scan = .osc_escape,
                0x18, 0x1a => self.scan = .ground,
                else => {
                    if (self.body_len < self.body.len) {
                        self.body[self.body_len] = byte;
                        self.body_len += 1;
                    } else {
                        self.body_overflow = true;
                    }
                    // Only OSC 7501 and OSC 133 matter; skip everything else
                    // (titles, hyperlinks, clipboard) without buffering it.
                    const seen = self.body[0..self.body_len];
                    if (seen.len <= OSC_7501_PREFIX.len and
                        !prefixMayMatch(seen, OSC_7501_PREFIX) and
                        !prefixMayMatch(seen, OSC_133_PREFIX))
                    {
                        self.scan = .osc_skip;
                    }
                },
            },
            .osc_escape => if (byte == '\\') {
                self.finishOsc(allocator, false);
            } else {
                // Any other escape aborts the string and starts a new one.
                self.stepEscape(byte);
            },
            .osc_skip => switch (byte) {
                0x07, 0x18, 0x1a => self.scan = .ground,
                0x1b => self.scan = .osc_skip_escape,
                else => {},
            },
            .osc_skip_escape => if (byte == '\\') {
                self.scan = .ground;
            } else {
                self.stepEscape(byte);
            },
        }
    }

    fn stepEscape(self: *Tracker, byte: u8) void {
        switch (byte) {
            ']' => {
                self.scan = .osc;
                self.body_len = 0;
                self.body_overflow = false;
            },
            0x1b => self.scan = .escape,
            'c' => {
                // RIS removes every record.
                self.records.clearRetainingCapacity();
                self.prompt_seen = true;
                self.scan = .ground;
            },
            else => self.scan = .ground,
        }
    }

    fn finishOsc(self: *Tracker, allocator: std.mem.Allocator, bel: bool) void {
        self.scan = .ground;
        // `ESC ]` plus `BEL` (1 byte) or `ESC \` (2 bytes) count toward the cap.
        const terminator_len: usize = if (bel) 1 else 2;
        if (self.body_overflow or 2 + self.body_len + terminator_len > MAX_SEQUENCE_BYTES) return;
        const body = self.body[0..self.body_len];
        if (std.mem.startsWith(u8, body, OSC_7501_PREFIX)) {
            var scratch: Scratch = .{};
            switch (parseBody(body[OSC_7501_PREFIX.len..], &scratch)) {
                .query => {
                    if (self.pending_replies < MAX_PENDING_REPLIES) self.pending_replies += 1;
                    self.reply_with_bel = bel;
                },
                .report => |report| self.apply(allocator, report),
                .ignored => {},
            }
        } else if (std.mem.startsWith(u8, body, OSC_133_PREFIX)) {
            const rest = body[OSC_133_PREFIX.len..];
            if (rest.len > 0 and rest[0] == 'A' and (rest.len == 1 or rest[1] == ';')) {
                self.dropLive();
                self.prompt_seen = true;
            }
        }
    }

    fn find(self: *Tracker, id: []const u8) ?*Record {
        for (self.records.items) |*record| {
            if (std.mem.eql(u8, record.id(), id)) return record;
        }
        return null;
    }

    fn clear(self: *Tracker, id: []const u8) void {
        if (id.len == 0) {
            self.records.clearRetainingCapacity();
            return;
        }
        var index: usize = 0;
        while (index < self.records.items.len) {
            const record_id = self.records.items[index].id();
            const descendant = record_id.len > id.len and std.mem.startsWith(u8, record_id, id) and record_id[id.len] == '/';
            if (std.mem.eql(u8, record_id, id) or descendant) {
                _ = self.records.orderedRemove(index);
            } else {
                index += 1;
            }
        }
    }

    fn leastRecentlyUpdated(self: *const Tracker) usize {
        var oldest: usize = 0;
        for (self.records.items, 0..) |record, index| {
            if (record.updated < self.records.items[oldest].updated) oldest = index;
        }
        return oldest;
    }

    fn inheritedApp(self: *const Tracker, record: *const Record) []const u8 {
        if (record.app_len > 0) return record.app();
        var ancestor = record.id();
        while (ancestor.len > 0) {
            ancestor = if (std.mem.lastIndexOfScalar(u8, ancestor, '/')) |slash| ancestor[0..slash] else "";
            for (self.records.items) |*candidate| {
                if (candidate.app_len > 0 and std.mem.eql(u8, candidate.id(), ancestor)) return candidate.app();
            }
        }
        return "";
    }
};

/// What a pane last published to its Verde surface.
pub const Published = struct {
    status: SurfaceStatus,
    kind: ?Kind = null,
};

pub const Action = union(enum) {
    clear,
    status: Published,
};

/// Maps the aggregate onto Verde's surface lifecycle. `idle` (or no record)
/// clears a live working/needs-you status, since the spec has programs
/// report `idle` on interrupt; it leaves `done`/`error` for the user to
/// acknowledge, as the spec requires those to survive.
pub fn nextAction(published: ?Published, current: ?Aggregate) ?Action {
    const aggregate_value = current orelse return clearLive(published);
    const status: SurfaceStatus = switch (aggregate_value.state) {
        .idle => return clearLive(published),
        .working => .working,
        .blocked => .waiting,
        .done => .done,
        .@"error" => .@"error",
    };
    const target: Published = .{ .status = status, .kind = if (status == .waiting) aggregate_value.kind else null };
    if (published) |previous| {
        if (previous.status == target.status and previous.kind == target.kind) return null;
    }
    return .{ .status = target };
}

fn clearLive(published: ?Published) ?Action {
    const previous = published orelse return null;
    return switch (previous.status) {
        .working, .waiting => .clear,
        .done, .@"error" => null,
    };
}

pub const Publication = struct {
    action: Action,
    sequence: u64,
    app: []const u8,
    msg: []const u8,
};

/// Per-pane policy around a `Tracker`: lifecycle, hook precedence, and
/// publication rate limiting. Owned by the daemon's PTY session.
pub const Pane = struct {
    tracker: Tracker = .{},
    published: ?Published = null,
    /// Foreground process group when the latest report was applied.
    report_pgrp: ?usize = null,
    /// A lifecycle hook (`verde notify`) reported for this pane while
    /// `hook_pgrp` was in the foreground. Hooks carry richer data (session
    /// titles, subagents, provider thread ids), so they win for that program.
    hook_reported: bool = false,
    hook_pgrp: ?usize = null,
    last_publish_ms: i64 = 0,
    sequence: u64 = 0,

    pub fn deinit(self: *Pane, allocator: std.mem.Allocator) void {
        self.tracker.deinit(allocator);
    }

    /// Observes PTY output. Returns true when a report was applied; the
    /// caller then records the reporter with `noteReporter`.
    pub fn observe(self: *Pane, allocator: std.mem.Allocator, bytes: []const u8) bool {
        self.tracker.feed(allocator, bytes);
        if (self.tracker.prompt_seen) {
            // A new prompt ends the program, and with it any hook authority.
            self.tracker.prompt_seen = false;
            self.hook_reported = false;
            self.report_pgrp = null;
        }
        const reported = self.tracker.reported;
        self.tracker.reported = false;
        return reported;
    }

    /// Foreground process group of the program whose report was just applied.
    pub fn noteReporter(self: *Pane, foreground: ?usize) void {
        self.report_pgrp = foreground;
    }

    /// The reporting program left the foreground and its shell took it back:
    /// treat that as the program's exit (Verde's PTY child is the shell).
    pub fn observeForeground(self: *Pane, current: ?usize, shell_pgrp: usize) void {
        const reporter = self.report_pgrp orelse return;
        if (reporter == shell_pgrp) return;
        if (current == null or current.? != shell_pgrp) return;
        self.tracker.dropLive();
        self.report_pgrp = null;
        self.hook_reported = false;
    }

    pub fn needsForegroundCheck(self: *const Pane, shell_pgrp: usize) bool {
        const reporter = self.report_pgrp orelse return false;
        return reporter != shell_pgrp and self.tracker.hasLive();
    }

    pub fn processExited(self: *Pane) void {
        self.tracker.dropLive();
        self.report_pgrp = null;
    }

    pub fn noteHookReport(self: *Pane, foreground: ?usize) void {
        self.hook_reported = true;
        self.hook_pgrp = foreground;
    }

    /// The next surface change to publish, if any. Slices borrow the tracker
    /// and stay valid until the next `observe`.
    pub fn nextPublication(self: *Pane, now_ms: i64) ?Publication {
        if (self.hook_reported and optionalEql(self.hook_pgrp, self.report_pgrp)) {
            // The hook owns this surface; forget ours so a later
            // hook-less program starts from a clean slate.
            self.published = null;
            return null;
        }
        const current = self.tracker.aggregate();
        const action = nextAction(self.published, current) orelse return null;
        if (self.last_publish_ms != 0 and now_ms - self.last_publish_ms < MIN_PUBLISH_INTERVAL_MS) return null;
        self.last_publish_ms = now_ms;
        self.sequence +%= 1;
        self.published = switch (action) {
            .clear => null,
            .status => |status| status,
        };
        return .{
            .action = action,
            .sequence = self.sequence,
            .app = if (current) |value| value.app else "",
            .msg = if (current) |value| value.msg else "",
        };
    }
};

/// `SurfaceProvider` tag for a well-known `app`, so the pane gets its icon.
pub fn surfaceProviderForApp(app: []const u8) ?[]const u8 {
    const known = [_]struct { app: []const u8, provider: []const u8 }{
        .{ .app = "claude-code", .provider = "claude" },
        .{ .app = "claude", .provider = "claude" },
        .{ .app = "codex", .provider = "codex" },
        .{ .app = "opencode", .provider = "opencode" },
        .{ .app = "cursor", .provider = "cursor" },
        .{ .app = "cursor-agent", .provider = "cursor" },
        .{ .app = "grok", .provider = "grok" },
        .{ .app = "amp", .provider = "amp" },
        .{ .app = "pi", .provider = "pi" },
        .{ .app = "antigravity", .provider = "antigravity" },
        .{ .app = "agy", .provider = "antigravity" },
    };
    for (known) |entry| {
        if (std.ascii.eqlIgnoreCase(app, entry.app)) return entry.provider;
    }
    return null;
}

/// Short notification title, e.g. "Claude Code needs permission".
pub fn eventTitle(buffer: []u8, app: []const u8, published: Published) []const u8 {
    const name = displayName(app);
    const verb = switch (published.status) {
        .working => "is working",
        .done => "finished",
        .@"error" => "failed",
        .waiting => if (published.kind) |kind| switch (kind) {
            .permission => "needs permission",
            .question => "has a question",
            .auth => "needs sign-in",
        } else "needs you",
    };
    return std.fmt.bufPrint(buffer, "{s} {s}", .{ name, verb }) catch name;
}

fn displayName(app: []const u8) []const u8 {
    const names = [_]struct { app: []const u8, name: []const u8 }{
        .{ .app = "claude-code", .name = "Claude Code" },
        .{ .app = "claude", .name = "Claude Code" },
        .{ .app = "codex", .name = "Codex" },
        .{ .app = "opencode", .name = "OpenCode" },
    };
    for (names) |entry| {
        if (std.ascii.eqlIgnoreCase(app, entry.app)) return entry.name;
    }
    return if (app.len > 0) app else "Program";
}

fn stateRank(state: State) u8 {
    return switch (state) {
        .idle => 0,
        .done => 1,
        .@"error" => 2,
        .working => 3,
        .blocked => 4,
    };
}

/// Whether `seen` is still consistent with `prefix` (either is a prefix of
/// the other).
fn prefixMayMatch(seen: []const u8, prefix: []const u8) bool {
    const len = @min(seen.len, prefix.len);
    return std.mem.eql(u8, seen[0..len], prefix[0..len]);
}

fn optionalEql(a: ?usize, b: ?usize) bool {
    if (a) |left| return if (b) |right| left == right else false;
    return b == null;
}

fn allBytes(bytes: []const u8, comptime predicate: fn (u8) bool) bool {
    for (bytes) |byte| {
        if (!predicate(byte)) return false;
    }
    return true;
}

fn isKeyByte(byte: u8) bool {
    return byte >= 'a' and byte <= 'z';
}

fn isValueByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or switch (byte) {
        '_', '.', ',', '+', '/', '=', '-' => true,
        else => false,
    };
}

/// `[A-Za-z0-9_.+-]`: id segments and `app`.
fn isNameByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '.' or byte == '+' or byte == '-';
}

fn validId(id: []const u8) bool {
    if (id.len == 0 or id.len > MAX_ID_BYTES) return false;
    var depth: usize = 0;
    var segments = std.mem.splitScalar(u8, id, '/');
    while (segments.next()) |segment| {
        depth += 1;
        if (depth > MAX_ID_DEPTH) return false;
        if (segment.len == 0 or segment.len > MAX_ID_SEGMENT_BYTES or !allBytes(segment, isNameByte)) return false;
    }
    return true;
}

fn parseProgress(value: []const u8) ?u8 {
    if (value.len == 0 or value.len > 3 or !allBytes(value, std.ascii.isDigit)) return null;
    const parsed = std.fmt.parseInt(u8, value, 10) catch return null;
    return if (parsed <= 100) parsed else null;
}

/// Standard base64 with optional padding, decoded into `dest`; null when the
/// encoding, size, UTF-8, or control-character rules are broken.
fn decodeText(encoded: []const u8, dest: []u8) ?[]const u8 {
    var unpadded = encoded;
    var padding: usize = 0;
    while (padding < 2 and unpadded.len > 0 and unpadded[unpadded.len - 1] == '=') {
        unpadded = unpadded[0 .. unpadded.len - 1];
        padding += 1;
    }
    if (padding > 0 and encoded.len % 4 != 0) return null;
    const decoder = std.base64.standard_no_pad.Decoder;
    const size = decoder.calcSizeForSlice(unpadded) catch return null;
    if (size > dest.len) return null;
    decoder.decode(dest[0..size], unpadded) catch return null;
    const text = dest[0..size];
    if (!std.unicode.utf8ValidateSlice(text)) return null;
    var codepoints = std.unicode.Utf8View.initUnchecked(text).iterator();
    while (codepoints.nextCodepoint()) |codepoint| {
        if (codepoint < 0x20 or (codepoint >= 0x7f and codepoint <= 0x9f)) return null;
    }
    return text;
}

/// Copies at most `dest.len` bytes on a UTF-8 boundary, dropping bidi
/// controls so a message cannot reorder surrounding notification text.
fn keptDisplayText(text: []const u8, dest: []u8) []const u8 {
    var len: usize = 0;
    var codepoints = std.unicode.Utf8View.initUnchecked(text).iterator();
    while (codepoints.nextCodepointSlice()) |slice| {
        const codepoint = std.unicode.utf8Decode(slice) catch continue;
        if (isBidiControl(codepoint)) continue;
        if (len + slice.len > dest.len) break;
        @memcpy(dest[len .. len + slice.len], slice);
        len += slice.len;
    }
    return dest[0..len];
}

fn isBidiControl(codepoint: u21) bool {
    return codepoint == 0x061c or codepoint == 0x200e or codepoint == 0x200f or
        (codepoint >= 0x202a and codepoint <= 0x202e) or
        (codepoint >= 0x2066 and codepoint <= 0x2069);
}

const testing = std.testing;

fn testParse(body: []const u8) Parsed {
    const scratch = struct {
        var value: Scratch = .{};
    };
    return parseBody(body, &scratch.value);
}

test "program status parses a valid report" {
    const parsed = testParse("state=blocked:kind=permission:app=terraform:progress=40:msg=QXBwbHkgMyB0byBhZGQsIDEgdG8gY2hhbmdlLCAwIHRvIGRlc3Ryb3k/");
    const report = parsed.report;
    try testing.expectEqual(State.blocked, report.state.?);
    try testing.expectEqual(Kind.permission, report.kind.?);
    try testing.expectEqual(@as(?u8, 40), report.progress);
    try testing.expectEqualStrings("terraform", report.app);
    try testing.expectEqualStrings("Apply 3 to add, 1 to change, 0 to destroy?", report.msg);
    try testing.expectEqualStrings("", report.id);
}

test "program status skips malformed pairs and keeps the last duplicate" {
    const report = testParse(" state = working :bogus:=x:Key=v:note=a;b:state=done:kind=permission:progress=101:app=bad!app").report;
    try testing.expectEqual(State.done, report.state.?);
    // kind/progress only apply to blocked/working; bad app is absent.
    try testing.expectEqual(@as(?Kind, null), report.kind);
    try testing.expectEqual(@as(?u8, null), report.progress);
    try testing.expectEqualStrings("", report.app);
    try testing.expectEqual(Kind.question, testParse("state=blocked:kind=question").report.kind.?);
    try testing.expectEqual(@as(?Kind, null), testParse("state=blocked:kind=telepathy").report.kind);
    try testing.expectEqual(@as(?u8, null), testParse("state=working:progress=-1").report.progress);
}

test "program status ignores unknown or missing state" {
    try testing.expect(testParse("state=sleeping:app=x") == .ignored);
    try testing.expect(testParse("app=x:msg=aGk=") == .ignored);
    try testing.expect(testParse("") == .ignored);
    try testing.expect(testParse("state=clear").report.state == null);
}

test "program status enforces limits and id grammar" {
    try testing.expect(testParse("state=working:abcdefghijklmnopq=1") == .ignored);
    try testing.expect(testParse("state=working:app=" ++ "a" ** 33) == .ignored);
    try testing.expect(testParse("state=working:title=" ++ "QUFB" ** 65) == .ignored);
    try testing.expect(testParse("state=working:msg=" ++ "QUFB" ** 684) == .ignored);
    try testing.expect(testParse("state=working:id=a/b/c/d/e/f/g/h").report.state.? == .working);
    try testing.expect(testParse("state=working:id=a/b/c/d/e/f/g/h/i") == .ignored);
    try testing.expect(testParse("state=working:id=" ++ "a" ** 33) == .ignored);
    try testing.expect(testParse("state=working:id=a//b") == .ignored);
    try testing.expect(testParse("state=working:id=a,b") == .ignored);
    try testing.expectEqualStrings("build/test", testParse("state=working:id=build/test").report.id);
}

test "program status rejects bad base64 and control characters" {
    // "a\nb" and "\x1b[31m" decode to control characters.
    try testing.expect(testParse("state=done:msg=YQpi") == .ignored);
    try testing.expect(testParse("state=done:msg=G1szMW0=") == .ignored);
    // U+0085 (C1 NEL) encoded as UTF-8.
    try testing.expect(testParse("state=done:msg=woU=") == .ignored);
    try testing.expect(testParse("state=done:title=YQpi") == .ignored);
    try testing.expect(testParse("state=done:msg=!!!").report.msg.len == 0);
    try testing.expect(testParse("state=done:msg=QQ=A") == .ignored);
    try testing.expect(testParse("state=done:msg=Q") == .ignored);
    try testing.expect(testParse("state=done:msg=/w==") == .ignored);
    // Padding is optional.
    try testing.expectEqualStrings("hi", testParse("state=done:msg=aGk").report.msg);
    try testing.expectEqualStrings("hi", testParse("state=done:msg=aGk=").report.msg);
}

test "program status answers the feature query with the request terminator" {
    var tracker: Tracker = .{};
    defer tracker.deinit(testing.allocator);
    tracker.feed(testing.allocator, "\x1b]7501;?\x1b\\\x1b[c");
    try testing.expectEqualStrings(QUERY_REPLY_ST, tracker.takeReply().?);
    try testing.expect(tracker.takeReply() == null);
    tracker.feed(testing.allocator, "\x1b]7501;?\x07");
    try testing.expectEqualStrings(QUERY_REPLY_BEL, tracker.takeReply().?);
    try testing.expect(std.mem.startsWith(u8, QUERY_REPLY_ST, "\x1b]7501;?:states=idle,working,done,blocked,error:kinds=permission,question,auth"));
    for (0..10) |_| tracker.feed(testing.allocator, "\x1b]7501;?\x07");
    var replies: usize = 0;
    while (tracker.takeReply()) |_| replies += 1;
    try testing.expectEqual(@as(usize, MAX_PENDING_REPLIES), replies);
}

test "program status scanner handles split, aborted, and oversize sequences" {
    var tracker: Tracker = .{};
    defer tracker.deinit(testing.allocator);
    const sequence = "\x1b]7501;state=working:app=codex\x1b\\";
    for (sequence) |byte| tracker.feed(testing.allocator, &.{byte});
    try testing.expectEqual(State.working, tracker.aggregate().?.state);
    try testing.expectEqualStrings("codex", tracker.aggregate().?.app);

    // An escape other than ST aborts the report.
    tracker.feed(testing.allocator, "\x1b]7501;state=done\x1b[0m");
    try testing.expectEqual(State.working, tracker.aggregate().?.state);
    // CAN aborts too; unrelated OSCs are skipped.
    tracker.feed(testing.allocator, "\x1b]7501;state=done\x18\x1b]0;title\x07\x1b]8;;http://x\x1b\\");
    try testing.expectEqual(State.working, tracker.aggregate().?.state);

    // Over 4096 bytes: discarded whole, and scanning recovers afterwards.
    tracker.feed(testing.allocator, "\x1b]7501;state=done:pad=");
    for (0..MAX_SEQUENCE_BYTES) |_| tracker.feed(testing.allocator, "a");
    tracker.feed(testing.allocator, "\x07");
    try testing.expectEqual(State.working, tracker.aggregate().?.state);
    tracker.feed(testing.allocator, "plain text \x1b]7501;state=done\x07");
    try testing.expectEqual(State.done, tracker.aggregate().?.state);

    // Exactly 4096 bytes with BEL is accepted; the same body with ESC \ is not.
    const prefix = "7501;state=error:pad=";
    const fill = MAX_SEQUENCE_BYTES - 3 - prefix.len;
    tracker.feed(testing.allocator, "\x1b]" ++ prefix);
    for (0..fill) |_| tracker.feed(testing.allocator, "a");
    tracker.feed(testing.allocator, "\x1b\\");
    try testing.expectEqual(State.done, tracker.aggregate().?.state);
    tracker.feed(testing.allocator, "\x1b]" ++ prefix);
    for (0..fill) |_| tracker.feed(testing.allocator, "a");
    tracker.feed(testing.allocator, "\x07");
    try testing.expectEqual(State.@"error", tracker.aggregate().?.state);
}

test "program status records replace, clear subtrees, aggregate, and evict" {
    var tracker: Tracker = .{};
    defer tracker.deinit(testing.allocator);
    const allocator = testing.allocator;
    tracker.feed(allocator, "\x1b]7501;state=working:app=deploy\x07");
    tracker.feed(allocator, "\x1b]7501;state=working:id=us-east\x07");
    tracker.feed(allocator, "\x1b]7501;state=blocked:kind=auth:id=eu-west:msg=TG9naW4=\x07");
    var aggregate_value = tracker.aggregate().?;
    try testing.expectEqual(State.blocked, aggregate_value.state);
    try testing.expectEqual(Kind.auth, aggregate_value.kind.?);
    try testing.expectEqualStrings("deploy", aggregate_value.app);
    try testing.expectEqualStrings("Login", aggregate_value.msg);

    tracker.feed(allocator, "\x1b]7501;state=clear:id=eu-west\x07");
    try testing.expectEqual(State.working, tracker.aggregate().?.state);
    // Replacement drops keys absent from the new report.
    tracker.feed(allocator, "\x1b]7501;state=done:msg=b2s=\x07");
    tracker.feed(allocator, "\x1b]7501;state=clear:id=us-east\x07");
    aggregate_value = tracker.aggregate().?;
    try testing.expectEqual(State.done, aggregate_value.state);
    try testing.expectEqualStrings("", aggregate_value.app);

    tracker.feed(allocator, "\x1b]7501;state=working:id=a\x07\x1b]7501;state=working:id=a/b\x07\x1b]7501;state=working:id=ab\x07");
    tracker.feed(allocator, "\x1b]7501;state=clear:id=a\x07");
    try testing.expectEqual(@as(usize, 2), tracker.records.items.len);
    tracker.feed(allocator, "\x1b]7501;state=clear\x07");
    try testing.expect(tracker.aggregate() == null);

    var buffer: [64]u8 = undefined;
    for (0..MAX_RECORDS + 5) |index| {
        const sequence = try std.fmt.bufPrint(&buffer, "\x1b]7501;state=idle:id=r{d}\x07", .{index});
        tracker.feed(allocator, sequence);
    }
    try testing.expectEqual(MAX_RECORDS, tracker.records.items.len);
    try testing.expect(tracker.find("r0") == null);
    try testing.expect(tracker.find("r68") != null);
}

test "program status prompt, process exit, and reset drop live records" {
    var tracker: Tracker = .{};
    defer tracker.deinit(testing.allocator);
    const allocator = testing.allocator;
    tracker.feed(allocator, "\x1b]7501;state=working\x07\x1b]7501;state=error:id=x\x07");
    tracker.feed(allocator, "\x1b]133;A;cl=m\x07");
    try testing.expect(tracker.prompt_seen);
    try testing.expectEqual(State.@"error", tracker.aggregate().?.state);
    tracker.feed(allocator, "\x1b]133;B\x07\x1b]7501;state=blocked\x07");
    tracker.dropLive();
    try testing.expectEqual(State.@"error", tracker.aggregate().?.state);
    tracker.feed(allocator, "\x1bc");
    try testing.expect(tracker.aggregate() == null);
}

test "program status maps aggregates onto Verde surface statuses" {
    const working: Aggregate = .{ .state = .working, .kind = null, .app = "", .msg = "" };
    const blocked: Aggregate = .{ .state = .blocked, .kind = .question, .app = "", .msg = "" };
    const idle: Aggregate = .{ .state = .idle, .kind = null, .app = "", .msg = "" };
    const done: Aggregate = .{ .state = .done, .kind = null, .app = "", .msg = "" };
    const failed: Aggregate = .{ .state = .@"error", .kind = null, .app = "", .msg = "" };

    try testing.expectEqual(SurfaceStatus.working, nextAction(null, working).?.status.status);
    try testing.expect(nextAction(.{ .status = .working }, working) == null);
    const waiting = nextAction(.{ .status = .working }, blocked).?.status;
    try testing.expectEqual(SurfaceStatus.waiting, waiting.status);
    try testing.expectEqual(Kind.question, waiting.kind.?);
    try testing.expect(nextAction(.{ .status = .waiting, .kind = .permission }, blocked) != null);
    try testing.expectEqual(SurfaceStatus.done, nextAction(.{ .status = .working }, done).?.status.status);
    try testing.expectEqual(SurfaceStatus.@"error", nextAction(null, failed).?.status.status);
    // Interrupt (idle) or exit clears live statuses but keeps done/error.
    try testing.expect(nextAction(.{ .status = .working }, idle).? == .clear);
    try testing.expect(nextAction(.{ .status = .waiting }, null).? == .clear);
    try testing.expect(nextAction(.{ .status = .done }, idle) == null);
    try testing.expect(nextAction(.{ .status = .@"error" }, null) == null);
    try testing.expect(nextAction(null, idle) == null);
}

test "program status pane rate-limits and defers to lifecycle hooks" {
    var pane: Pane = .{};
    defer pane.deinit(testing.allocator);
    const allocator = testing.allocator;
    try testing.expect(pane.observe(allocator, "\x1b]7501;state=working:app=claude-code\x07"));
    pane.noteReporter(200);
    const first = pane.nextPublication(1000).?;
    try testing.expectEqual(SurfaceStatus.working, first.action.status.status);
    try testing.expectEqualStrings("claude-code", first.app);
    try testing.expect(pane.nextPublication(1001) == null);
    try testing.expect(!pane.observe(allocator, "plain output \x1b]0;title\x07"));

    try testing.expect(pane.observe(allocator, "\x1b]7501;state=blocked:kind=permission:app=claude-code\x07"));
    pane.noteReporter(200);
    try testing.expect(pane.nextPublication(1100) == null);
    try testing.expectEqual(SurfaceStatus.waiting, pane.nextPublication(1300).?.action.status.status);

    // A hook reporting for the same foreground program wins.
    pane.noteHookReport(200);
    _ = pane.observe(allocator, "\x1b]7501;state=done:app=claude-code\x07");
    pane.noteReporter(200);
    try testing.expect(pane.nextPublication(5000) == null);
    try testing.expect(pane.published == null);
    // A different foreground program without hooks publishes again.
    _ = pane.observe(allocator, "\x1b]7501;state=working:app=codex\x07");
    pane.noteReporter(300);
    try testing.expectEqual(SurfaceStatus.working, pane.nextPublication(5500).?.action.status.status);

    // A new prompt ends hook authority even when process groups are unknown.
    pane.noteHookReport(null);
    _ = pane.observe(allocator, "\x1b]7501;state=blocked\x07");
    pane.noteReporter(null);
    try testing.expect(pane.nextPublication(6000) == null);
    _ = pane.observe(allocator, "\x1b]133;A\x07\x1b]7501;state=working\x07");
    pane.noteReporter(null);
    try testing.expectEqual(SurfaceStatus.working, pane.nextPublication(7000).?.action.status.status);
}

test "program status pane treats the shell regaining the foreground as exit" {
    var pane: Pane = .{};
    defer pane.deinit(testing.allocator);
    const shell: usize = 100;
    _ = pane.observe(testing.allocator, "\x1b]7501;state=working\x07");
    pane.noteReporter(200);
    try testing.expect(pane.needsForegroundCheck(shell));
    pane.observeForeground(200, shell);
    try testing.expect(pane.tracker.hasLive());
    pane.observeForeground(300, shell);
    try testing.expect(pane.tracker.hasLive());
    pane.observeForeground(shell, shell);
    try testing.expect(!pane.tracker.hasLive());
    try testing.expect(!pane.needsForegroundCheck(shell));

    // Reports from the shell itself are not dropped when it has the foreground.
    _ = pane.observe(testing.allocator, "\x1b]7501;state=working\x07");
    pane.noteReporter(shell);
    try testing.expect(!pane.needsForegroundCheck(shell));
    pane.processExited();
    try testing.expect(!pane.tracker.hasLive());
}

test "program status names providers and notification titles" {
    const db_types = @import("../db/types.zig");
    for ([_][]const u8{ "claude-code", "codex", "opencode", "cursor-agent", "grok", "amp", "pi", "agy" }) |app| {
        const provider = surfaceProviderForApp(app).?;
        try testing.expect(std.meta.stringToEnum(db_types.SurfaceProvider, provider) != null);
    }
    try testing.expect(surfaceProviderForApp("terraform") == null);
    inline for (@typeInfo(SurfaceStatus).@"enum".fields) |field| {
        try testing.expect(std.meta.stringToEnum(db_types.SurfaceStatus, field.name) != null);
    }
    var buffer: [96]u8 = undefined;
    try testing.expectEqualStrings("Claude Code needs permission", eventTitle(&buffer, "claude-code", .{ .status = .waiting, .kind = .permission }));
    try testing.expectEqualStrings("terraform finished", eventTitle(&buffer, "terraform", .{ .status = .done }));
    try testing.expectEqualStrings("Program needs you", eventTitle(&buffer, "", .{ .status = .waiting }));
}

test "program status keeps a bounded, bidi-free message" {
    var buffer: [8]u8 = undefined;
    try testing.expectEqualStrings("ab", keptDisplayText("a\u{202e}b", &buffer));
    try testing.expectEqualStrings("ééé", keptDisplayText("éééé", buffer[0..7]));
}
