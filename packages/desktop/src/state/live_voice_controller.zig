//! GUI side of Live voice with the Companion: starts and stops the engine,
//! routes the voice model's tools to the Companion (as the phone apps do),
//! records the transcript, and saves it into the Companion's chat with
//! `chat.message.append` from a worker thread. Everything here runs on the
//! render thread and never blocks: the engine owns audio and the network, and
//! daemon calls run on workers.
//!
//! The app is the `host` (`anytype`), which provides the Companion's identity,
//! sends spoken requests, reports status, and resolves approvals; see
//! `HostContract` in the tests for the exact surface.

const Self = @This();

const std = @import("std");
const loop_wakeup = @import("loop_wakeup");
const daemon_client = @import("../daemon/client.zig");
const Engine = @import("../live_voice/engine.zig");
const Transcript = @import("../live_voice/transcript.zig");
const Machine = @import("../live_voice/session.zig");
const protocol = @import("../live_voice/protocol.zig");

const log = std.log.scoped(.live_voice_ui);

pub const MAX_CAPTIONS: usize = 3;
const SESSION_TIMEOUT_MS: u32 = 45_000;
const SAVE_TIMEOUT_MS: u32 = 15_000;
const ASK_WAIT_MS: i64 = 30 * 60_000;
const MAX_RETIRING: usize = 4;
const MAX_UNSAVED: usize = 4;
const MAX_SAVE_ATTEMPTS: u8 = 3;
const MAX_APPROVAL_CANDIDATES: usize = 32;

pub const Phase = Machine.Phase;
pub const Activity = Machine.Activity;

/// What the Companion panel shows.
pub const Presentation = struct {
    phase: Phase = .off,
    activity: Activity = .listening,
    muted: bool = false,
    echo_cancel: bool = true,
    input_level: f32 = 0,
    output_level: f32 = 0,
    error_message: ?[]const u8 = null,
    captions: [MAX_CAPTIONS]Transcript.Caption = undefined,
    caption_count: usize = 0,

    pub fn active(self: *const Presentation) bool {
        return self.phase.active();
    }

    /// Short status line for the strip and the dock bubble.
    pub fn label(self: *const Presentation) []const u8 {
        return switch (self.phase) {
            .off => "Live voice",
            .connecting => "Connecting…",
            .reconnecting => "Reconnecting…",
            .failed => "Live voice stopped",
            .live => if (self.muted) "Muted" else switch (self.activity) {
                .listening => "Listening…",
                .thinking => "Thinking…",
                .speaking => "Speaking…",
            },
        };
    }
};

/// A chat with a pending approval the voice may decide.
pub const ApprovalCandidate = struct { workspace_id: []const u8, thread_id: []const u8, title: []const u8 };

pub const ApprovalMatch = union(enum) { found: ApprovalCandidate, not_found, ambiguous };

const MintContext = struct {
    pref_path: []u8,
    companion_id: []u8,
};

const Retiring = struct { engine: *Engine, mint: *MintContext };

/// A pending `ask_companion`: the reply is read aloud when that turn ends.
const Ask = struct { before_count: usize, started: bool, sent_at_ms: i64 };

const SaveMessage = struct { key: []u8, role: []const u8, author: []u8, body: []u8, created_at_ms: i64 };

const SaveJob = struct {
    done: std.atomic.Value(bool) = .init(false),
    ok: bool = false,
    worker: ?std.Thread = null,
    transcript: *Transcript,
    count: usize,
    pref_path: []const u8,
    workspace_id: []const u8,
    thread_id: []const u8,
    session_id: [16]u8,
    messages: []const SaveMessage,

    fn destroy(self: *SaveJob, allocator: std.mem.Allocator) void {
        if (self.worker) |worker| worker.join();
        for (self.messages) |message| {
            allocator.free(message.key);
            allocator.free(message.author);
            allocator.free(message.body);
        }
        allocator.free(self.messages);
        allocator.free(self.pref_path);
        allocator.free(self.workspace_id);
        allocator.free(self.thread_id);
        allocator.destroy(self);
    }
};

/// Thread-safe allocator shared with the engine and save workers.
allocator: std.mem.Allocator = std.heap.c_allocator,
engine: ?*Engine = null,
mint: ?*MintContext = null,
retiring: [MAX_RETIRING]?Retiring = @splat(null),
transcript: ?*Transcript = null,
/// Ended sessions whose lines are not stored yet; retried.
unsaved: [MAX_UNSAVED]?*Transcript = @splat(null),
save_job: ?*SaveJob = null,
save_attempts: u8 = 0,
last_save_ms: i64 = 0,
ask: ?Ask = null,
/// Spoken requests waiting for a busy companion turn to finish.
queued_request: ?[]u8 = null,
muted: bool = false,
status: Engine.Status = .{},
error_message: ?[]const u8 = null,
notes: std.ArrayList(Engine.Note) = .empty,

pub fn deinit(self: *Self) void {
    if (self.engine) |engine| engine.destroy();
    if (self.mint) |mint| self.freeMint(mint);
    for (&self.retiring) |*slot| if (slot.*) |entry| {
        entry.engine.destroy();
        self.freeMint(entry.mint);
        slot.* = null;
    };
    if (self.save_job) |job| job.destroy(self.allocator);
    if (self.transcript) |record| self.destroyTranscript(record);
    for (&self.unsaved) |*slot| if (slot.*) |record| {
        self.destroyTranscript(record);
        slot.* = null;
    };
    for (self.notes.items) |item| item.deinit(self.allocator);
    self.notes.deinit(self.allocator);
    if (self.queued_request) |text| self.allocator.free(text);
    self.* = .{};
}

pub fn active(self: *const Self) bool {
    return self.engine != null and self.status.phase.active();
}

pub fn presentation(self: *const Self) Presentation {
    var out: Presentation = .{
        .phase = if (self.engine != null) self.status.phase else if (self.error_message != null) .failed else .off,
        .activity = self.status.activity,
        .muted = self.muted,
        .echo_cancel = self.status.echo_cancel,
        .input_level = self.status.input_level,
        .output_level = self.status.output_level,
        .error_message = self.error_message,
    };
    if (self.transcript) |record| out.caption_count = record.captions(&out.captions);
    return out;
}

/// Starts or ends Live voice (mic button and keybind).
pub fn toggle(self: *Self, host: anytype) void {
    if (self.engine != null) self.stop(host) else self.start(host);
}

pub fn start(self: *Self, host: anytype) void {
    if (self.engine != null) return;
    self.error_message = null;
    self.reapRetiring();
    if (self.retiringCount() == MAX_RETIRING) {
        self.error_message = "Still closing the last Live session. Try again in a moment.";
        return;
    }
    const mint = self.allocator.create(MintContext) catch return self.startFailed();
    mint.* = .{
        .pref_path = self.allocator.dupe(u8, host.livePrefPath()) catch {
            self.allocator.destroy(mint);
            return self.startFailed();
        },
        .companion_id = self.allocator.dupe(u8, host.liveCompanionId()) catch {
            self.allocator.free(mint.pref_path);
            self.allocator.destroy(mint);
            return self.startFailed();
        },
    };
    var session_id: [16]u8 = undefined;
    randomHex(&session_id);
    const record = self.allocator.create(Transcript) catch {
        self.freeMint(mint);
        return self.startFailed();
    };
    record.* = Transcript.init(self.allocator, host.liveCompanionName(), session_id) catch {
        self.allocator.destroy(record);
        self.freeMint(mint);
        return self.startFailed();
    };
    const engine = Engine.start(self.allocator, .{ .context = mint, .mint = mintSession, .wake = wake }, self.muted) catch {
        self.destroyTranscript(record);
        self.freeMint(mint);
        return self.startFailed();
    };
    self.engine = engine;
    self.mint = mint;
    self.transcript = record;
    self.ask = null;
    self.last_save_ms = nowMs();
    self.status = engine.status();
    requestFrame();
}

/// Ends Live now and saves the rest of the transcript. Never blocks.
pub fn stop(self: *Self, host: anytype) void {
    if (self.engine) |engine| {
        engine.requestStop();
        self.retire();
    }
    self.error_message = null;
    self.finishTranscript(host);
    requestFrame();
}

pub fn toggleMute(self: *Self) void {
    self.muted = !self.muted;
    if (self.engine) |engine| engine.setMuted(self.muted);
    requestFrame();
}

/// Cuts the companion off mid-sentence (clicking the speaking character).
pub fn interrupt(self: *Self) void {
    if (self.engine) |engine| engine.interrupt();
}

pub fn dismissError(self: *Self) void {
    if (self.error_message == null) return;
    self.error_message = null;
    requestFrame();
}

/// Collects engine notes and status, runs tools, follows asked companion
/// turns, and saves transcript lines. Call once per frame; cheap when idle.
pub fn tick(self: *Self, host: anytype) void {
    self.reapRetiring();
    self.collectSave();
    const now = nowMs();
    if (self.engine) |engine| {
        const previous = self.status;
        self.status = engine.status();
        if (!std.meta.eql(previous, self.status)) requestFrame();
        engine.takeNotes(&self.notes, self.allocator) catch {};
        var ended = false;
        for (self.notes.items) |item| {
            defer item.deinit(self.allocator);
            if (item == .ended) {
                ended = true;
                continue;
            }
            self.handleNote(host, engine, item, now);
        }
        self.notes.clearRetainingCapacity();
        if (ended or engine.isFinished()) {
            self.status = engine.status();
            if (self.status.failure) |failure| self.error_message = failure.message();
            self.retire();
            self.finishTranscript(host);
            requestFrame();
        } else {
            self.followAsk(host, engine, now);
        }
    }
    self.maybeSave(host, now);
}

// ---- notes and tools ---------------------------------------------------------------

fn handleNote(self: *Self, host: anytype, engine: *Engine, item: Engine.Note, now: i64) void {
    const record = self.transcript orelse return;
    const changed = switch (item) {
        .connected => |v| blk: {
            const header = std.fmt.allocPrint(self.allocator, "🎙 Live voice · {s} · {s}", .{ providerLabel(v.provider), v.voice }) catch break :blk false;
            defer self.allocator.free(header);
            record.header(header, now) catch {};
            break :blk true;
        },
        .user_partial => |v| blk: {
            record.userPartial(v.text, v.cumulative, now, v.item_id) catch {};
            break :blk true;
        },
        .user_text => |v| blk: {
            record.userFinal(v.text, now, v.item_id) catch {};
            break :blk true;
        },
        .assistant_text => |text| blk: {
            record.assistantDelta(text, now) catch {};
            break :blk true;
        },
        .response_started => blk: {
            record.assistantStarted() catch {};
            break :blk true;
        },
        .turn_done, .interrupted => blk: {
            record.assistantDone() catch {};
            break :blk true;
        },
        .tick => blk: {
            record.tick(now) catch {};
            break :blk true;
        },
        .tool_call => |call| blk: {
            self.runTool(host, engine, call.call_id, call.name, call.arguments, now);
            break :blk true;
        },
        .ended => false,
    };
    if (changed) requestFrame();
}

fn runTool(self: *Self, host: anytype, engine: *Engine, call_id: []const u8, name: []const u8, arguments_json: []const u8, now: i64) void {
    var arena_state = std.heap.ArenaAllocator.init(self.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const arguments = std.json.parseFromSliceLeaky(std.json.Value, arena, arguments_json, .{}) catch std.json.Value{ .object = .empty };
    const fields: std.json.ObjectMap = if (arguments == .object) arguments.object else .empty;
    const output = self.toolOutput(host, arena, name, fields, now) catch objectOf(arena, .{ .@"error" = "failed" });
    engine.sendToolResult(call_id, name, output);
}

fn toolOutput(self: *Self, host: anytype, arena: std.mem.Allocator, name: []const u8, fields: std.json.ObjectMap, now: i64) !std.json.Value {
    if (std.mem.eql(u8, name, "ask_companion")) {
        const request = std.mem.trim(u8, protocol.stringOf(fields.get("request")) orelse "", &std.ascii.whitespace);
        if (request.len == 0) return objectOf(arena, .{ .accepted = false, .@"error" = "empty_request" });
        if (self.transcript) |record| {
            const line = try std.fmt.allocPrint(arena, "→ Asked {s}: {s}", .{ companionName(host), request });
            record.system(line, now) catch {};
        }
        // A companion turn is running: send once it ends (sends are refused mid-turn).
        if (host.liveCompanionWorking() or self.queued_request != null) {
            try self.queueRequest(request);
            return objectOf(arena, .{ .accepted = true, .queued = true });
        }
        if (!self.sendRequest(host, request, now)) return objectOf(arena, .{ .accepted = false, .@"error" = "companion_not_ready" });
        return objectOf(arena, .{ .accepted = true });
    }
    if (std.mem.eql(u8, name, "companion_status")) return host.liveCompanionStatus(arena);
    if (std.mem.eql(u8, name, "decide_approval")) {
        const approve_value = fields.get("approve") orelse .null;
        if (approve_value != .bool) return objectOf(arena, .{ .@"error" = "missing_decision" });
        const approve = approve_value.bool;
        var buffer: [MAX_APPROVAL_CANDIDATES]ApprovalCandidate = undefined;
        const candidates = buffer[0..host.liveApprovalCandidates(&buffer)];
        const target = switch (matchApproval(protocol.stringOf(fields.get("chat")) orelse "", candidates)) {
            .not_found => return objectOf(arena, .{ .@"error" = "not_found" }),
            .ambiguous => return objectOf(arena, .{ .@"error" = "ambiguous" }),
            .found => |candidate| candidate,
        };
        const title = try arena.dupe(u8, target.title);
        if (!host.liveResolveApproval(target.workspace_id, target.thread_id, approve)) return objectOf(arena, .{ .chat = title, .@"error" = "no_pending_approval" });
        if (self.transcript) |record| {
            const line = try std.fmt.allocPrint(arena, "{s} {s}", .{ if (approve) "✓ Approved" else "✗ Denied", title });
            record.system(line, now) catch {};
        }
        return objectOf(arena, .{ .chat = title, .ok = true, .decision = if (approve) "approved" else "denied" });
    }
    return objectOf(arena, .{ .@"error" = "unknown_tool" });
}

fn queueRequest(self: *Self, request: []const u8) !void {
    const next = if (self.queued_request) |earlier| try joinDraft(self.allocator, earlier, request) else try self.allocator.dupe(u8, request);
    if (self.queued_request) |earlier| self.allocator.free(earlier);
    self.queued_request = next;
}

fn sendRequest(self: *Self, host: anytype, request: []const u8, now: i64) bool {
    const before = host.liveCompanionMessageCount();
    if (!host.liveAskCompanion(request)) return false;
    self.ask = .{ .before_count = before, .started = false, .sent_at_ms = now };
    return true;
}

/// After `ask_companion`, waits for the companion turn to start and finish,
/// then has the voice read the reply. Queued requests go out once idle.
fn followAsk(self: *Self, host: anytype, engine: *Engine, now: i64) void {
    if (self.queued_request) |text| if (self.ask == null and !host.liveCompanionWorking()) {
        self.queued_request = null;
        defer self.allocator.free(text);
        _ = self.sendRequest(host, text, now);
    };
    const pending = &(self.ask orelse return);
    if (now - pending.sent_at_ms > ASK_WAIT_MS) {
        self.ask = null;
        return;
    }
    const working = host.liveCompanionWorking();
    if (working) {
        pending.started = true;
        return;
    }
    if (!pending.started) return;
    const before = pending.before_count;
    self.ask = null;
    const reply = host.liveCompanionReplySince(before) orelse return;
    if (self.status.phase != .live) return;
    const update = protocol.companionUpdateAlloc(self.allocator, reply) catch return;
    defer self.allocator.free(update);
    if (self.transcript) |record| {
        const line = std.fmt.allocPrint(self.allocator, "← {s} replied", .{companionName(host)}) catch null;
        if (line) |text| {
            defer self.allocator.free(text);
            record.system(text, now) catch {};
        }
    }
    engine.inject(update);
    requestFrame();
}

// ---- saving ------------------------------------------------------------------------

fn finishTranscript(self: *Self, host: anytype) void {
    const record = self.transcript orelse return;
    self.transcript = null;
    self.ask = null;
    if (self.queued_request) |text| self.allocator.free(text);
    self.queued_request = null;
    const count = record.pending(true) catch 0;
    if (count == 0) {
        self.destroyTranscript(record);
        return;
    }
    for (&self.unsaved) |*slot| if (slot.* == null) {
        slot.* = record;
        self.save_attempts = 0;
        self.startSave(host, record, true);
        return;
    };
    log.warn("dropping a Live voice transcript: too many unsaved sessions", .{});
    self.destroyTranscript(record);
}

/// Periodic saves while live (when the companion is idle, so lines don't
/// land mid-reply) and retries of ended sessions.
fn maybeSave(self: *Self, host: anytype, now: i64) void {
    if (self.save_job != null) return;
    for (self.unsaved) |slot| if (slot) |record| {
        if (self.save_attempts >= MAX_SAVE_ATTEMPTS) break;
        if (now - self.last_save_ms < 5_000) return;
        self.last_save_ms = now;
        self.startSave(host, record, true);
        return;
    };
    const record = self.transcript orelse return;
    if (now - self.last_save_ms < Transcript.SAVE_INTERVAL_MS or host.liveCompanionWorking()) return;
    self.last_save_ms = now;
    self.startSave(host, record, false);
}

fn startSave(self: *Self, host: anytype, record: *Transcript, final: bool) void {
    if (self.save_job != null) return;
    const target = host.liveSaveTarget() orelse return;
    const count = record.pending(final) catch return;
    if (count == 0) return;
    const lines = record.pendingLines(count);
    const job = self.allocator.create(SaveJob) catch return;
    var messages: std.ArrayList(SaveMessage) = .empty;
    const built = blk: {
        for (lines) |line| {
            if (std.mem.trim(u8, line.body, &std.ascii.whitespace).len == 0) continue;
            const key = std.fmt.allocPrint(self.allocator, "{d}", .{line.key}) catch break :blk false;
            const author = self.allocator.dupe(u8, record.authorOf(line.role)) catch {
                self.allocator.free(key);
                break :blk false;
            };
            const body = self.allocator.dupe(u8, line.body) catch {
                self.allocator.free(key);
                self.allocator.free(author);
                break :blk false;
            };
            messages.append(self.allocator, .{ .key = key, .role = @tagName(line.role), .author = author, .body = body, .created_at_ms = wallMs(line.created_at_ms) }) catch {
                self.allocator.free(key);
                self.allocator.free(author);
                self.allocator.free(body);
                break :blk false;
            };
        }
        break :blk true;
    };
    const owned_messages: []const SaveMessage = messages.toOwnedSlice(self.allocator) catch blk: {
        for (messages.items) |message| {
            self.allocator.free(message.key);
            self.allocator.free(message.author);
            self.allocator.free(message.body);
        }
        messages.deinit(self.allocator);
        break :blk &.{};
    };
    job.* = .{
        .transcript = record,
        .count = count,
        .pref_path = self.allocator.dupe(u8, host.livePrefPath()) catch &.{},
        .workspace_id = self.allocator.dupe(u8, target.workspace_id) catch &.{},
        .thread_id = self.allocator.dupe(u8, target.thread_id) catch &.{},
        .session_id = record.session_id,
        .messages = owned_messages,
    };
    if (!built or job.pref_path.len == 0 or job.workspace_id.len == 0 or job.thread_id.len == 0) {
        job.destroy(self.allocator);
        return;
    }
    job.worker = std.Thread.spawn(.{}, saveWorker, .{ job, self.allocator }) catch {
        job.destroy(self.allocator);
        return;
    };
    self.save_job = job;
}

fn collectSave(self: *Self) void {
    const job = self.save_job orelse return;
    if (!job.done.load(.acquire)) return;
    self.save_job = null;
    defer job.destroy(self.allocator);
    const record = job.transcript;
    if (job.ok) {
        record.markSaved(job.count);
        self.save_attempts = 0;
    } else {
        self.save_attempts +|= 1;
    }
    for (&self.unsaved) |*slot| if (slot.* == record) {
        const rest = record.pending(true) catch 0;
        if (rest == 0 or self.save_attempts >= MAX_SAVE_ATTEMPTS) {
            if (rest > 0) log.warn("could not save a Live voice transcript", .{});
            self.destroyTranscript(record);
            slot.* = null;
            self.save_attempts = 0;
        }
    };
}

fn saveWorker(job: *SaveJob, allocator: std.mem.Allocator) void {
    defer {
        job.done.store(true, .release);
        loop_wakeup.notify();
    }
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var transport: daemon_client.HeadlessTransport = .{ .allocator = arena, .pref_path = job.pref_path, .timeout_ms = SAVE_TIMEOUT_MS };
    var client = daemon_client.headlessClient(arena, &transport);
    var registered = client.call("daemon.client.register", .{ .persistent = false }) catch return;
    defer registered.deinit();
    if (registered.response.err != null) return;
    const result = registered.response.result orelse return;
    const client_id = protocol.stringOf(if (result == .object) result.object.get("client_id") else null) orelse return;
    for (job.messages) |message| {
        const message_id = std.fmt.allocPrint(arena, "live:{s}:{s}", .{ &job.session_id, message.key }) catch return;
        var appended = client.call("chat.message.append", .{
            .mutation = .{ .request_key = message_id, .client_id = client_id },
            .workspace_id = job.workspace_id,
            .thread_id = job.thread_id,
            .message = .{
                .message_id = message_id,
                .role = message.role,
                .author = message.author,
                .body = message.body,
                .created_at_ms = message.created_at_ms,
                .updated_at_ms = message.created_at_ms,
            },
        }) catch return;
        defer appended.deinit();
        if (appended.response.err != null) return;
    }
    job.ok = true;
}

// ---- engine lifecycle -------------------------------------------------------------

fn retire(self: *Self) void {
    const engine = self.engine orelse return;
    const mint = self.mint.?;
    self.engine = null;
    self.mint = null;
    for (&self.retiring) |*slot| if (slot.* == null) {
        slot.* = .{ .engine = engine, .mint = mint };
        return;
    };
    // No free slot: wait for this one (rare; four sessions still closing).
    engine.destroy();
    self.freeMint(mint);
}

fn reapRetiring(self: *Self) void {
    for (&self.retiring) |*slot| if (slot.*) |entry| if (entry.engine.isFinished()) {
        entry.engine.destroy();
        self.freeMint(entry.mint);
        slot.* = null;
    };
}

fn retiringCount(self: *const Self) usize {
    var count: usize = 0;
    for (self.retiring) |slot| if (slot != null) {
        count += 1;
    };
    return count;
}

fn startFailed(self: *Self) void {
    self.error_message = "Couldn't start Live voice.";
}

fn freeMint(self: *Self, mint: *MintContext) void {
    self.allocator.free(mint.pref_path);
    self.allocator.free(mint.companion_id);
    self.allocator.destroy(mint);
}

fn destroyTranscript(self: *Self, record: *Transcript) void {
    record.deinit();
    self.allocator.destroy(record);
}

/// Engine hook: `voice.session.create` on the engine thread.
fn mintSession(context: ?*anyopaque, allocator: std.mem.Allocator) Engine.MintResult {
    const mint: *MintContext = @ptrCast(@alignCast(context.?));
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var transport: daemon_client.HeadlessTransport = .{ .allocator = arena, .pref_path = mint.pref_path, .timeout_ms = SESSION_TIMEOUT_MS };
    var client = daemon_client.headlessClient(arena, &transport);
    var params: std.json.ObjectMap = .empty;
    if (mint.companion_id.len > 0) params.put(arena, "companion_id", .{ .string = mint.companion_id }) catch {};
    var parsed = client.call("voice.session.create", std.json.Value{ .object = params }) catch return .{ .failure = .daemon_unavailable };
    defer parsed.deinit();
    if (parsed.response.err) |err| return .{ .failure = Machine.Failure.fromDaemonCode(err.code) };
    const result = parsed.response.result orelse return .{ .failure = .provider_unavailable };
    const json = std.json.Stringify.valueAlloc(allocator, result, .{}) catch return .{ .failure = .provider_unavailable };
    return .{ .json = json };
}

fn wake() void {
    loop_wakeup.notify();
}

/// UI-only change: run one more loop iteration and frame (never a store flush).
fn requestFrame() void {
    loop_wakeup.notify();
}

// ---- helpers -----------------------------------------------------------------------

fn companionName(host: anytype) []const u8 {
    const name = host.liveCompanionName();
    return if (name.len > 0) name else "Companion";
}

fn providerLabel(provider: []const u8) []const u8 {
    if (std.mem.eql(u8, provider, "xai")) return "xAI Grok Voice";
    if (std.mem.eql(u8, provider, "openai")) return "OpenAI Realtime";
    if (std.mem.eql(u8, provider, "gemini")) return "Google Gemini Live";
    return provider;
}

fn objectOf(arena: std.mem.Allocator, value: anytype) std.json.Value {
    const text = std.json.Stringify.valueAlloc(arena, value, .{}) catch return .{ .object = .empty };
    return std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{}) catch .{ .object = .empty };
}

fn randomHex(out: *[16]u8) void {
    var bytes: [8]u8 = undefined;
    std.Io.Threaded.global_single_threaded.io().random(&bytes);
    const hex = std.fmt.bytesToHex(bytes, .lower);
    out.* = hex;
}

fn nowMs() i64 {
    return std.Io.Clock.awake.now(std.Io.Threaded.global_single_threaded.io()).toMilliseconds();
}

/// Transcript times are monotonic; saved messages carry wall-clock times.
fn wallMs(monotonic_ms: i64) i64 {
    const io = std.Io.Threaded.global_single_threaded.io();
    const wall_now = std.Io.Clock.real.now(io).toMilliseconds();
    return wall_now - (nowMs() - monotonic_ms);
}

/// Exact id or title (case-insensitive) first, else a unique partial title match.
pub fn matchApproval(query: []const u8, candidates: []const ApprovalCandidate) ApprovalMatch {
    const q = std.mem.trim(u8, query, &std.ascii.whitespace);
    if (q.len == 0) return .not_found;
    var exact: ?ApprovalCandidate = null;
    var exact_count: usize = 0;
    var partial: ?ApprovalCandidate = null;
    var partial_count: usize = 0;
    for (candidates, 0..) |candidate, index| {
        // Duplicate rows for the same chat (inbox + crew) count once.
        const repeated = for (candidates[0..index]) |earlier| {
            if (std.mem.eql(u8, earlier.workspace_id, candidate.workspace_id) and std.mem.eql(u8, earlier.thread_id, candidate.thread_id)) break true;
        } else false;
        if (repeated) continue;
        const title = std.mem.trim(u8, candidate.title, &std.ascii.whitespace);
        if (std.ascii.eqlIgnoreCase(candidate.thread_id, q) or std.ascii.eqlIgnoreCase(title, q)) {
            exact = candidate;
            exact_count += 1;
        } else if (std.ascii.indexOfIgnoreCase(title, q) != null) {
            partial = candidate;
            partial_count += 1;
        }
    }
    if (exact_count == 1) return .{ .found = exact.? };
    if (exact_count > 1) return .ambiguous;
    if (partial_count == 1) return .{ .found = partial.? };
    if (partial_count > 1) return .ambiguous;
    return .not_found;
}

/// Spoken words join an existing draft like the phone apps do.
pub fn joinDraft(allocator: std.mem.Allocator, draft: []const u8, spoken: []const u8) ![]u8 {
    const before = std.mem.trimEnd(u8, draft, &std.ascii.whitespace);
    const words = std.mem.trim(u8, spoken, &std.ascii.whitespace);
    if (before.len == 0) return allocator.dupe(u8, words);
    return std.mem.concat(allocator, u8, &.{ before, "\n\n", words });
}

// ---- tests -------------------------------------------------------------------------

const testing = std.testing;

/// The host surface the controller relies on, as a test double.
const HostContract = struct {
    asked: std.ArrayList(u8) = .empty,
    working: bool = false,
    message_count: usize = 4,
    reply: ?[]const u8 = null,
    approvals: []const ApprovalCandidate = &.{},
    resolved: ?bool = null,

    pub fn livePrefPath(_: *HostContract) []const u8 {
        return "/nonexistent";
    }
    pub fn liveCompanionId(_: *HostContract) []const u8 {
        return "c1";
    }
    pub fn liveCompanionName(_: *HostContract) []const u8 {
        return "Moss";
    }
    pub fn liveSaveTarget(_: *HostContract) ?struct { workspace_id: []const u8, thread_id: []const u8 } {
        return null;
    }
    pub fn liveAskCompanion(self: *HostContract, text: []const u8) bool {
        self.asked.appendSlice(testing.allocator, text) catch return false;
        return true;
    }
    pub fn liveCompanionWorking(self: *HostContract) bool {
        return self.working;
    }
    pub fn liveCompanionMessageCount(self: *HostContract) usize {
        return self.message_count;
    }
    pub fn liveCompanionReplySince(self: *HostContract, _: usize) ?[]const u8 {
        return self.reply;
    }
    pub fn liveCompanionStatus(_: *HostContract, arena: std.mem.Allocator) !std.json.Value {
        return objectOf(arena, .{ .crew = &[_]u8{}, .needs_you = &[_]u8{} });
    }
    pub fn liveApprovalCandidates(self: *HostContract, out: []ApprovalCandidate) usize {
        const n = @min(out.len, self.approvals.len);
        @memcpy(out[0..n], self.approvals[0..n]);
        return n;
    }
    pub fn liveResolveApproval(self: *HostContract, _: []const u8, _: []const u8, approve: bool) bool {
        self.resolved = approve;
        return true;
    }
};

test "approval matching prefers exact titles and refuses ambiguity" {
    const candidates = [_]ApprovalCandidate{
        .{ .workspace_id = "w1", .thread_id = "t1", .title = "Deploy web" },
        .{ .workspace_id = "w1", .thread_id = "t2", .title = "Deploy web staging" },
        .{ .workspace_id = "w2", .thread_id = "t3", .title = "Fix tests" },
        .{ .workspace_id = "w2", .thread_id = "t3", .title = "Fix tests" },
    };
    try testing.expectEqualStrings("t1", matchApproval("deploy WEB", &candidates).found.thread_id);
    try testing.expectEqualStrings("t3", matchApproval("tests", &candidates).found.thread_id);
    try testing.expect(matchApproval("deploy", &candidates) == .ambiguous);
    try testing.expect(matchApproval("nothing", &candidates) == .not_found);
    try testing.expect(matchApproval("  ", &candidates) == .not_found);
    try testing.expectEqualStrings("t2", matchApproval("t2", &candidates).found.thread_id);
}

test "spoken requests join the draft" {
    const joined = try joinDraft(testing.allocator, "half typed  \n", " run tests ");
    defer testing.allocator.free(joined);
    try testing.expectEqualStrings("half typed\n\nrun tests", joined);
    const alone = try joinDraft(testing.allocator, "   ", "run tests");
    defer testing.allocator.free(alone);
    try testing.expectEqualStrings("run tests", alone);
}

test "tools route to the companion and approvals" {
    var host: HostContract = .{};
    defer host.asked.deinit(testing.allocator);
    var controller: Self = .{ .allocator = testing.allocator };
    defer controller.deinit();
    var record = try Transcript.init(testing.allocator, "Moss", @splat('a'));
    defer record.deinit();
    controller.transcript = &record;
    defer controller.transcript = null;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var ask_fields: std.json.ObjectMap = .empty;
    try ask_fields.put(arena, "request", .{ .string = "run the tests" });
    const asked = try controller.toolOutput(&host, arena, "ask_companion", ask_fields, 1);
    try testing.expect(asked.object.get("accepted").?.bool);
    try testing.expectEqualStrings("run the tests", host.asked.items);
    try testing.expectEqual(@as(usize, 4), controller.ask.?.before_count);
    try testing.expectEqualStrings("→ Asked Moss: run the tests", record.lines.items[record.lines.items.len - 1].body);

    const empty = try controller.toolOutput(&host, arena, "ask_companion", .empty, 2);
    try testing.expectEqualStrings("empty_request", empty.object.get("error").?.string);

    host.approvals = &.{.{ .workspace_id = "w", .thread_id = "t", .title = "Deploy" }};
    var decide: std.json.ObjectMap = .empty;
    try decide.put(arena, "chat", .{ .string = "deploy" });
    try decide.put(arena, "approve", .{ .bool = true });
    const decided = try controller.toolOutput(&host, arena, "decide_approval", decide, 3);
    try testing.expectEqualStrings("approved", decided.object.get("decision").?.string);
    try testing.expect(host.resolved.?);

    var undecided: std.json.ObjectMap = .empty;
    try undecided.put(arena, "chat", .{ .string = "deploy" });
    try testing.expectEqualStrings("missing_decision", (try controller.toolOutput(&host, arena, "decide_approval", undecided, 4)).object.get("error").?.string);
    try testing.expectEqualStrings("unknown_tool", (try controller.toolOutput(&host, arena, "nope", .empty, 5)).object.get("error").?.string);
    _ = try controller.toolOutput(&host, arena, "companion_status", .empty, 6);
}

test "presentation labels follow phase and activity" {
    var p: Presentation = .{ .phase = .live, .activity = .speaking };
    try testing.expectEqualStrings("Speaking…", p.label());
    p.muted = true;
    try testing.expectEqualStrings("Muted", p.label());
    p = .{ .phase = .connecting };
    try testing.expect(p.active());
    try testing.expectEqualStrings("Connecting…", p.label());
}

test "the full controller API instantiates against the host contract" {
    var host: HostContract = .{};
    defer host.asked.deinit(testing.allocator);
    var controller: Self = .{ .allocator = testing.allocator };
    defer controller.deinit();
    // Compile every host-generic path; running them would start a real engine.
    var run_it = false;
    _ = &run_it;
    if (run_it) {
        controller.toggle(&host);
        controller.start(&host);
        controller.tick(&host);
        controller.stop(&host);
        controller.toggleMute();
        controller.dismissError();
        controller.interrupt();
    }
    // Idle ticks are safe and do nothing.
    controller.tick(&host);
    try testing.expect(!controller.active());
    try testing.expectEqual(Phase.off, controller.presentation().phase);
}
