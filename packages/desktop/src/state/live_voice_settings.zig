//! Live voice settings for the call pill's popover: which provider and voice
//! the desktop's daemon uses (`voice.providers`, `voice.provider.configure`).
//! API keys are never read or shown here; the daemon only reports whether a
//! provider has one. Requests run on a worker thread so the render thread
//! never waits on the daemon.

const Self = @This();

const std = @import("std");
const loop_wakeup = @import("loop_wakeup");
const daemon_client = @import("../daemon/client.zig");

const log = std.log.scoped(.live_voice_settings);

pub const MAX_PROVIDERS: usize = 3;
pub const MAX_VOICES: usize = 12;
const REQUEST_TIMEOUT_MS: u32 = 15_000;

/// Fixed-capacity label (provider ids, labels, voice names).
pub const Text = struct {
    buffer: [48]u8 = undefined,
    len: u8 = 0,

    pub fn set(self: *Text, value: []const u8) void {
        var n = @min(value.len, self.buffer.len);
        // Never cut a UTF-8 sequence in half.
        while (n > 0 and n < value.len and (value[n] & 0xC0) == 0x80) n -= 1;
        @memcpy(self.buffer[0..n], value[0..n]);
        self.len = @intCast(n);
    }

    pub fn slice(self: *const Text) []const u8 {
        return self.buffer[0..self.len];
    }

    pub fn eql(self: *const Text, value: []const u8) bool {
        return std.mem.eql(u8, self.slice(), value);
    }
};

pub const Provider = struct {
    id: Text = .{},
    label: Text = .{},
    /// The daemon holds a key for it (environment or Verde); never the key.
    configured: bool = false,
    voice: Text = .{},
    voices: [MAX_VOICES]Text = @splat(.{}),
    voice_count: usize = 0,

    pub fn voiceIndex(self: *const Provider) ?usize {
        for (self.voices[0..self.voice_count], 0..) |*voice, index| if (voice.eql(self.voice.slice())) return index;
        return null;
    }
};

pub const Listing = struct {
    providers: [MAX_PROVIDERS]Provider = @splat(.{}),
    count: usize = 0,
    default_id: Text = .{},
};

pub const PollResult = enum { none, listed, configured, failed };

const Job = struct {
    kind: enum { list, configure },
    done: std.atomic.Value(bool) = .init(false),
    worker: ?std.Thread = null,
    pref_path: []u8,
    provider: Text = .{},
    voice: Text = .{},
    ok: bool = false,
    listing: Listing = .{},

    fn destroy(self: *Job, allocator: std.mem.Allocator) void {
        if (self.worker) |worker| worker.join();
        allocator.free(self.pref_path);
        allocator.destroy(self);
    }
};

allocator: std.mem.Allocator = std.heap.c_allocator,
listing: Listing = .{},
loaded: bool = false,
loading: bool = false,
saving: bool = false,
error_message: ?[]const u8 = null,
job: ?*Job = null,

pub fn deinit(self: *Self) void {
    if (self.job) |job| job.destroy(self.allocator);
    self.* = .{};
}

/// Index of the provider Live uses: the daemon default, else the first configured.
pub fn activeIndex(self: *const Self) ?usize {
    const listing = &self.listing;
    for (listing.providers[0..listing.count], 0..) |*provider, index| {
        if (provider.configured and provider.id.eql(listing.default_id.slice())) return index;
    }
    for (listing.providers[0..listing.count], 0..) |*provider, index| if (provider.configured) return index;
    return null;
}

/// Fetches the provider list (opening the popover). No-op while a request runs.
pub fn refresh(self: *Self, pref_path: []const u8) void {
    if (self.job != null) return;
    self.loading = true;
    self.start(.list, pref_path, .{}, .{});
}

/// Makes a provider (and optionally one of its voices) the Live default.
/// Optimistic: the listing changes now; a failure reloads it.
pub fn choose(self: *Self, pref_path: []const u8, provider_index: usize, voice_index: ?usize) bool {
    if (self.job != null or provider_index >= self.listing.count) return false;
    const provider = &self.listing.providers[provider_index];
    if (!provider.configured) {
        self.error_message = "Add an API key for this provider first (environment or the phone app).";
        return false;
    }
    var voice: Text = .{};
    if (voice_index) |index| {
        if (index >= provider.voice_count) return false;
        voice = provider.voices[index];
        provider.voice = voice;
    }
    self.listing.default_id = provider.id;
    self.error_message = null;
    self.saving = true;
    self.start(.configure, pref_path, provider.id, voice);
    return true;
}

/// Collects a finished request. `.configured` means the next Live session
/// (or a restart of the current one) uses the new choice.
pub fn poll(self: *Self) PollResult {
    const job = self.job orelse return .none;
    if (!job.done.load(.acquire)) return .none;
    self.job = null;
    defer job.destroy(self.allocator);
    self.loading = false;
    self.saving = false;
    if (!job.ok) {
        self.error_message = if (job.kind == .list) "Couldn't load voice settings from the daemon." else "Couldn't save the voice choice.";
        if (job.kind == .configure) self.loaded = false;
        return .failed;
    }
    self.error_message = null;
    if (job.kind == .list) {
        self.listing = job.listing;
        self.loaded = true;
        return .listed;
    }
    return .configured;
}

fn start(self: *Self, kind: @FieldType(Job, "kind"), pref_path: []const u8, provider: Text, voice: Text) void {
    const job = self.allocator.create(Job) catch return self.startFailed();
    job.* = .{
        .kind = kind,
        .pref_path = self.allocator.dupe(u8, pref_path) catch {
            self.allocator.destroy(job);
            return self.startFailed();
        },
        .provider = provider,
        .voice = voice,
    };
    job.worker = std.Thread.spawn(.{}, workerMain, .{ job, self.allocator }) catch {
        job.destroy(self.allocator);
        return self.startFailed();
    };
    self.job = job;
}

fn startFailed(self: *Self) void {
    self.loading = false;
    self.saving = false;
    self.error_message = "Couldn't reach the Verde daemon.";
}

fn workerMain(job: *Job, allocator: std.mem.Allocator) void {
    defer {
        job.done.store(true, .release);
        loop_wakeup.notify();
    }
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var transport: daemon_client.HeadlessTransport = .{ .allocator = arena, .pref_path = job.pref_path, .timeout_ms = REQUEST_TIMEOUT_MS };
    var client = daemon_client.headlessClient(arena, &transport);
    var params: std.json.ObjectMap = .empty;
    const method = switch (job.kind) {
        .list => "voice.providers",
        .configure => blk: {
            params.put(arena, "provider", .{ .string = job.provider.slice() }) catch return;
            if (job.voice.len > 0) params.put(arena, "voice", .{ .string = job.voice.slice() }) catch return;
            params.put(arena, "make_default", .{ .bool = true }) catch return;
            break :blk "voice.provider.configure";
        },
    };
    var parsed = client.call(method, std.json.Value{ .object = params }) catch |err| {
        log.warn("{s} failed: {s}", .{ method, @errorName(err) });
        return;
    };
    defer parsed.deinit();
    if (parsed.response.err) |err| {
        log.warn("{s} rejected: {s}", .{ method, err.code });
        return;
    }
    const result = parsed.response.result orelse return;
    // Both methods answer with the provider list.
    job.ok = parseListing(result, &job.listing);
}

/// Reads `{ default_provider, providers: [{ id, label, configured, voice, voices }] }`.
pub fn parseListing(value: std.json.Value, out: *Listing) bool {
    if (value != .object) return false;
    out.* = .{};
    if (value.object.get("default_provider")) |default| if (default == .string) out.default_id.set(default.string);
    const rows = value.object.get("providers") orelse return false;
    if (rows != .array) return false;
    for (rows.array.items) |row| {
        if (out.count == MAX_PROVIDERS) break;
        if (row != .object) continue;
        const fields = row.object;
        const id = stringField(fields, "id") orelse continue;
        const provider = &out.providers[out.count];
        provider.* = .{};
        provider.id.set(id);
        provider.label.set(stringField(fields, "label") orelse id);
        provider.configured = if (fields.get("configured")) |v| v == .bool and v.bool else false;
        provider.voice.set(stringField(fields, "voice") orelse "");
        if (fields.get("voices")) |voices| if (voices == .array) for (voices.array.items) |voice| {
            if (provider.voice_count == MAX_VOICES) break;
            if (voice != .string or voice.string.len == 0) continue;
            provider.voices[provider.voice_count].set(voice.string);
            provider.voice_count += 1;
        };
        out.count += 1;
    }
    return true;
}

fn stringField(fields: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const value = fields.get(name) orelse return null;
    return if (value == .string) value.string else null;
}

test "provider listing parses ids, keys-present flags, and voices" {
    const json =
        \\{"default_provider":"xai","providers":[
        \\ {"id":"xai","label":"xAI Grok Voice","configured":true,"key_source":"verde","voice":"eve","voices":["eve","ara","rex"]},
        \\ {"id":"openai","label":"OpenAI Realtime","configured":false,"voice":"marin","voices":["marin","cedar"]},
        \\ {"id":"gemini","label":"Google Gemini Live","configured":true,"voice":"Puck","voices":["Puck"]}]}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    var listing: Listing = .{};
    try std.testing.expect(parseListing(parsed.value, &listing));
    try std.testing.expectEqual(@as(usize, 3), listing.count);
    try std.testing.expectEqualStrings("xAI Grok Voice", listing.providers[0].label.slice());
    try std.testing.expect(!listing.providers[1].configured);
    try std.testing.expectEqual(@as(usize, 3), listing.providers[0].voice_count);
    try std.testing.expectEqual(@as(?usize, 0), listing.providers[0].voiceIndex());

    var settings: Self = .{ .listing = listing, .loaded = true };
    try std.testing.expectEqual(@as(?usize, 0), settings.activeIndex());
    // An unconfigured default falls back to the first provider with a key.
    settings.listing.default_id.set("openai");
    try std.testing.expectEqual(@as(?usize, 0), settings.activeIndex());
    try std.testing.expect(!settings.choose("/nonexistent", 1, null));
    try std.testing.expect(settings.error_message != null);
}

test "labels never split a UTF-8 sequence" {
    var text: Text = .{};
    text.set("é" ** 30);
    try std.testing.expect(std.unicode.utf8ValidateSlice(text.slice()));
    var listing: Listing = .{};
    try std.testing.expect(!parseListing(.null, &listing));
}
