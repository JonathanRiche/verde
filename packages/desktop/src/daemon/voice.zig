//! Real-time voice sessions for the machine Companion. API keys stay on the
//! desktop: the daemon mints short-lived, provider-issued session tokens and
//! hands phones only those, plus the voice persona and tool schemas the
//! real-time model needs. Providers are pluggable; each one maps to a token
//! endpoint and a WebSocket URL.
//!
//! Keys come from the daemon environment (XAI_API_KEY, OPENAI_API_KEY,
//! GEMINI_API_KEY / GOOGLE_API_KEY) or from `<pref>/voice.json`, which paired
//! devices may update with `voice.provider.configure`. Keys are never
//! returned to any client.

const std = @import("std");
const builtin = @import("builtin");

const log = std.log.scoped(.voice);

pub const METHOD_PROVIDERS = "voice.providers";
pub const METHOD_SESSION_CREATE = "voice.session.create";
pub const METHOD_PROVIDER_CONFIGURE = "voice.provider.configure";
pub const FILE_NAME = "voice.json";
const MAX_FILE_BYTES: usize = 32 * 1024;
const MAX_KEY_BYTES: usize = 512;
const TOKEN_SECONDS: i64 = 600;

pub const ProviderId = enum {
    xai,
    openai,
    gemini,

    pub fn label(self: ProviderId) []const u8 {
        return switch (self) {
            .xai => "xAI Grok Voice",
            .openai => "OpenAI Realtime",
            .gemini => "Google Gemini Live",
        };
    }

    pub fn defaultModel(self: ProviderId) []const u8 {
        return switch (self) {
            .xai => "grok-voice-latest",
            .openai => "gpt-realtime",
            .gemini => "gemini-3.8-live",
        };
    }

    pub fn defaultVoice(self: ProviderId) []const u8 {
        return switch (self) {
            .xai => "eve",
            .openai => "marin",
            .gemini => "Puck",
        };
    }

    pub fn voices(self: ProviderId) []const []const u8 {
        return switch (self) {
            .xai => &.{ "eve", "ara", "rex", "sal", "leo" },
            .openai => &.{ "marin", "cedar", "alloy", "ash", "ballad", "coral", "echo", "sage", "shimmer", "verse" },
            .gemini => &.{ "Puck", "Charon", "Kore", "Fenrir", "Aoede", "Leda", "Orus", "Zephyr" },
        };
    }

    fn envKeys(self: ProviderId) []const []const u8 {
        return switch (self) {
            .xai => &.{"XAI_API_KEY"},
            .openai => &.{"OPENAI_API_KEY"},
            .gemini => &.{ "GEMINI_API_KEY", "GOOGLE_API_KEY" },
        };
    }

    /// Wire protocol family the phone adapter must speak.
    pub fn protocol(self: ProviderId) []const u8 {
        return switch (self) {
            .xai, .openai => "openai_realtime",
            .gemini => "gemini_live",
        };
    }
};

pub const ProviderConfig = struct {
    api_key: []const u8 = "",
    model: []const u8 = "",
    voice: []const u8 = "",
};

const WireFile = struct {
    default_provider: []const u8 = "",
    xai: ProviderConfig = .{},
    openai: ProviderConfig = .{},
    gemini: ProviderConfig = .{},
};

/// Loaded voice configuration. Strings are owned by `arena`.
pub const Config = struct {
    arena: std.heap.ArenaAllocator,
    default_provider: ?ProviderId = null,
    providers: [3]ProviderConfig = .{ .{}, .{}, .{} },
    /// Which keys came from the environment (read-only; not saved to disk).
    from_env: [3]bool = .{ false, false, false },

    pub fn deinit(self: *Config) void {
        self.arena.deinit();
    }

    pub fn get(self: *const Config, id: ProviderId) ProviderConfig {
        return self.providers[@intFromEnum(id)];
    }

    pub fn configured(self: *const Config, id: ProviderId) bool {
        return self.get(id).api_key.len > 0;
    }

    pub fn model(self: *const Config, id: ProviderId) []const u8 {
        const value = self.get(id).model;
        return if (value.len > 0) value else id.defaultModel();
    }

    pub fn voice(self: *const Config, id: ProviderId) []const u8 {
        const value = self.get(id).voice;
        return if (value.len > 0) value else id.defaultVoice();
    }

    /// The provider to use when the client does not ask for one.
    pub fn pick(self: *const Config) ?ProviderId {
        if (self.default_provider) |id| if (self.configured(id)) return id;
        for ([_]ProviderId{ .xai, .openai, .gemini }) |id| if (self.configured(id)) return id;
        return null;
    }
};

/// Returns the variable's value allocated in `allocator`, or null.
pub const EnvLookup = *const fn (allocator: std.mem.Allocator, name: []const u8) ?[]const u8;

pub fn processEnv(allocator: std.mem.Allocator, name: []const u8) ?[]const u8 {
    const environ: std.process.Environ = if (builtin.os.tag == .windows)
        .{ .block = .global }
    else
        .{ .block = .{ .slice = std.mem.span(std.c.environ) } };
    const value = environ.getAlloc(allocator, name) catch return null;
    return if (value.len == 0) null else value;
}

pub fn pathAlloc(allocator: std.mem.Allocator, pref_path: []const u8) ![]u8 {
    return std.fs.path.join(allocator, &.{ pref_path, FILE_NAME });
}

/// Loads `<pref>/voice.json` (if any) and fills unset keys from the environment.
pub fn load(allocator: std.mem.Allocator, pref_path: []const u8, env: EnvLookup) Config {
    var config: Config = .{ .arena = std.heap.ArenaAllocator.init(allocator) };
    const arena = config.arena.allocator();
    if (pref_path.len > 0) file: {
        const path = pathAlloc(arena, pref_path) catch break :file;
        var threaded = std.Io.Threaded.init_single_threaded;
        const bytes = std.Io.Dir.cwd().readFileAlloc(threaded.io(), path, arena, .limited(MAX_FILE_BYTES)) catch break :file;
        const parsed = std.json.parseFromSliceLeaky(WireFile, arena, bytes, .{ .ignore_unknown_fields = true }) catch {
            log.warn("ignoring unreadable voice.json", .{});
            break :file;
        };
        config.default_provider = std.meta.stringToEnum(ProviderId, parsed.default_provider);
        config.providers = .{ parsed.xai, parsed.openai, parsed.gemini };
    }
    for ([_]ProviderId{ .xai, .openai, .gemini }) |id| {
        const slot = &config.providers[@intFromEnum(id)];
        if (slot.api_key.len > 0) continue;
        for (id.envKeys()) |name| {
            if (env(arena, name)) |value| {
                slot.api_key = value;
                config.from_env[@intFromEnum(id)] = true;
                break;
            }
        }
    }
    return config;
}

pub const ConfigureRequest = struct {
    provider: ProviderId,
    /// null = keep; "" = remove the stored key.
    api_key: ?[]const u8 = null,
    model: ?[]const u8 = null,
    voice: ?[]const u8 = null,
    make_default: bool = false,
};

/// Updates `<pref>/voice.json` (owner-only permissions). Environment keys
/// are never written to disk.
pub fn configure(allocator: std.mem.Allocator, pref_path: []const u8, request: ConfigureRequest) !void {
    if (pref_path.len == 0) return error.InvalidParams;
    if (request.api_key) |key| {
        if (key.len > MAX_KEY_BYTES) return error.InvalidParams;
        for (key) |byte| if (byte < 0x21 or byte > 0x7e) return error.InvalidParams;
    }
    inline for (.{ request.model, request.voice }) |field| {
        if (field) |value| {
            if (value.len > 96) return error.InvalidParams;
            for (value) |byte| if (byte < 0x20 or byte == 0x7f) return error.InvalidParams;
        }
    }
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var stored: WireFile = .{};
    const path = try pathAlloc(arena, pref_path);
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    if (std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(MAX_FILE_BYTES))) |bytes| {
        stored = std.json.parseFromSliceLeaky(WireFile, arena, bytes, .{ .ignore_unknown_fields = true }) catch .{};
    } else |_| {}
    const slot = switch (request.provider) {
        .xai => &stored.xai,
        .openai => &stored.openai,
        .gemini => &stored.gemini,
    };
    if (request.api_key) |key| slot.api_key = key;
    if (request.model) |value| slot.model = value;
    if (request.voice) |value| slot.voice = value;
    if (request.make_default) stored.default_provider = @tagName(request.provider);
    const encoded = try std.json.Stringify.valueAlloc(arena, stored, .{ .whitespace = .indent_2 });
    const tmp_path = try std.fmt.allocPrint(arena, "{s}.tmp", .{path});
    const cwd = std.Io.Dir.cwd();
    var parent = try cwd.createDirPathOpen(io, pref_path, .{});
    parent.close(io);
    {
        var file = try cwd.createFile(io, tmp_path, .{ .permissions = if (builtin.os.tag == .windows) .default_file else .fromMode(0o600) });
        defer file.close(io);
        var buffer: [2048]u8 = undefined;
        var writer = file.writer(io, &buffer);
        try writer.interface.writeAll(encoded);
        try writer.interface.flush();
    }
    try cwd.rename(tmp_path, cwd, path, io);
}

/// Provider list for `voice.providers` (never includes keys).
pub fn writeProviders(s: *std.json.Stringify, config: *const Config) !void {
    try s.beginObject();
    try s.objectField("default_provider");
    try s.write(if (config.pick()) |id| @tagName(id) else null);
    try s.objectField("providers");
    try s.beginArray();
    for ([_]ProviderId{ .xai, .openai, .gemini }) |id| {
        try s.write(.{
            .id = @tagName(id),
            .label = id.label(),
            .protocol = id.protocol(),
            .configured = config.configured(id),
            .key_source = if (!config.configured(id)) "none" else if (config.from_env[@intFromEnum(id)]) "environment" else "verde",
            .model = config.model(id),
            .voice = config.voice(id),
            .voices = id.voices(),
        });
    }
    try s.endArray();
    try s.endObject();
}

// ---- sessions ----------------------------------------------------------------

pub const Session = struct {
    provider: ProviderId,
    model: []const u8,
    voice: []const u8,
    token: []const u8,
    expires_at_ms: i64,
    websocket_url: []const u8,
    /// How the phone presents the token: "bearer" (Authorization header) or
    /// "query" (access_token URL parameter, already in websocket_url).
    auth: []const u8,
};

pub const HttpPost = *const fn (allocator: std.mem.Allocator, url: []const u8, headers: []const std.http.Header, body: []const u8) anyerror!HttpResult;
pub const HttpResult = struct { status: u16, body: []u8 };

/// Mints a provider token with the stored key. `post` is injectable for tests.
pub fn createSession(
    arena: std.mem.Allocator,
    config: *const Config,
    provider: ProviderId,
    model_override: ?[]const u8,
    voice_override: ?[]const u8,
    now_ms: i64,
    post: HttpPost,
) !Session {
    const key = config.get(provider).api_key;
    if (key.len == 0) return error.ProviderNotConfigured;
    const model = if (model_override) |value| (if (value.len > 0) value else config.model(provider)) else config.model(provider);
    const voice = if (voice_override) |value| (if (value.len > 0) value else config.voice(provider)) else config.voice(provider);
    switch (provider) {
        .xai => {
            const auth = try std.fmt.allocPrint(arena, "Bearer {s}", .{key});
            const body = try std.json.Stringify.valueAlloc(arena, .{ .expires_after = .{ .seconds = TOKEN_SECONDS } }, .{});
            const result = try post(arena, "https://api.x.ai/v1/realtime/client_secrets", &.{
                .{ .name = "Authorization", .value = auth },
                .{ .name = "Content-Type", .value = "application/json" },
            }, body);
            const token = try tokenFrom(arena, result, &.{ "value", "client_secret.value", "token" });
            return .{
                .provider = provider,
                .model = model,
                .voice = voice,
                .token = token.value,
                .expires_at_ms = token.expires_at_ms orelse now_ms + TOKEN_SECONDS * 1000,
                .websocket_url = try std.fmt.allocPrint(arena, "wss://api.x.ai/v1/realtime?model={s}", .{model}),
                .auth = "bearer",
            };
        },
        .openai => {
            const auth = try std.fmt.allocPrint(arena, "Bearer {s}", .{key});
            const body = try std.json.Stringify.valueAlloc(arena, .{
                .expires_after = .{ .anchor = "created_at", .seconds = TOKEN_SECONDS },
                .session = .{ .type = "realtime", .model = model, .audio = .{ .output = .{ .voice = voice } } },
            }, .{});
            const result = try post(arena, "https://api.openai.com/v1/realtime/client_secrets", &.{
                .{ .name = "Authorization", .value = auth },
                .{ .name = "Content-Type", .value = "application/json" },
            }, body);
            const token = try tokenFrom(arena, result, &.{ "value", "client_secret.value" });
            return .{
                .provider = provider,
                .model = model,
                .voice = voice,
                .token = token.value,
                .expires_at_ms = token.expires_at_ms orelse now_ms + TOKEN_SECONDS * 1000,
                .websocket_url = try std.fmt.allocPrint(arena, "wss://api.openai.com/v1/realtime?model={s}", .{model}),
                .auth = "bearer",
            };
        },
        .gemini => {
            const expire = try rfc3339(arena, now_ms + 30 * 60 * 1000);
            const new_session = try rfc3339(arena, now_ms + 2 * 60 * 1000);
            const body = try std.json.Stringify.valueAlloc(arena, .{ .uses = 1, .expireTime = expire, .newSessionExpireTime = new_session }, .{});
            const result = try post(arena, "https://generativelanguage.googleapis.com/v1beta/auth_tokens", &.{
                .{ .name = "x-goog-api-key", .value = key },
                .{ .name = "Content-Type", .value = "application/json" },
            }, body);
            const token = try tokenFrom(arena, result, &.{"name"});
            const escaped = try percentEncode(arena, token.value);
            return .{
                .provider = provider,
                .model = model,
                .voice = voice,
                .token = token.value,
                .expires_at_ms = now_ms + 30 * 60 * 1000,
                .websocket_url = try std.fmt.allocPrint(arena, "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContentConstrained?access_token={s}", .{escaped}),
                .auth = "query",
            };
        },
    }
}

const Token = struct { value: []const u8, expires_at_ms: ?i64 };

fn tokenFrom(arena: std.mem.Allocator, result: HttpResult, paths: []const []const u8) !Token {
    if (result.status == 401 or result.status == 403) return error.ProviderRejectedKey;
    if (result.status < 200 or result.status >= 300) {
        log.warn("voice token request failed: HTTP {d}", .{result.status});
        return error.ProviderUnavailable;
    }
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, result.body, .{}) catch return error.ProviderUnavailable;
    for (paths) |path| {
        var node = root;
        var parts = std.mem.splitScalar(u8, path, '.');
        const found = while (parts.next()) |part| {
            if (node != .object) break false;
            node = node.object.get(part) orelse break false;
        } else true;
        if (found and node == .string and node.string.len > 0) {
            const expires: ?i64 = blk: {
                const holder = if (std.mem.indexOfScalar(u8, path, '.')) |_| root.object.get("client_secret") orelse root else root;
                if (holder != .object) break :blk null;
                break :blk switch (holder.object.get("expires_at") orelse .null) {
                    .integer => |seconds| seconds * 1000,
                    else => null,
                };
            };
            return .{ .value = node.string, .expires_at_ms = expires };
        }
    }
    return error.ProviderUnavailable;
}

fn rfc3339(arena: std.mem.Allocator, ms: i64) ![]u8 {
    const seconds: u64 = @intCast(@divFloor(ms, 1000));
    const epoch: std.time.epoch.EpochSeconds = .{ .secs = seconds };
    const day = epoch.getEpochDay();
    const year_day = day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const time = epoch.getDaySeconds();
    return std.fmt.allocPrint(arena, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        year_day.year,
        month_day.month.numeric(),
        @as(u32, month_day.day_index) + 1,
        time.getHoursIntoDay(),
        time.getMinutesIntoHour(),
        time.getSecondsIntoMinute(),
    });
}

fn percentEncode(arena: std.mem.Allocator, value: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    for (value) |byte| {
        if (std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == '.' or byte == '~' or byte == '/') {
            try out.append(arena, byte);
        } else {
            try out.print(arena, "%{X:0>2}", .{byte});
        }
    }
    return out.toOwnedSlice(arena);
}

/// Real HTTPS POST with a bounded wait.
pub fn httpPost(allocator: std.mem.Allocator, url: []const u8, headers: []const std.http.Header, body: []const u8) anyerror!HttpResult {
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    var client: std.http.Client = .{ .allocator = allocator, .io = threaded.io() };
    defer client.deinit();
    var response: std.Io.Writer.Allocating = .init(allocator);
    defer response.deinit();
    const options: std.http.Client.FetchOptions = .{
        .location = .{ .url = url },
        .method = .POST,
        .payload = body,
        .keep_alive = false,
        .redirect_behavior = .not_allowed,
        .extra_headers = headers,
        .response_writer = &response.writer,
    };
    const Result = union(enum) { fetch: std.http.Client.FetchError!std.http.Client.FetchResult, timeout: std.Io.Cancelable!void };
    var buffer: [2]Result = undefined;
    var select = std.Io.Select(Result).init(threaded.io(), &buffer);
    select.async(.fetch, std.http.Client.fetch, .{ &client, options });
    select.async(.timeout, std.Io.sleep, .{ threaded.io(), std.Io.Duration.fromMilliseconds(10_000), .awake });
    defer select.cancelDiscard();
    const status: u16 = switch (try select.await()) {
        .fetch => |result| @intFromEnum((try result).status),
        .timeout => return error.ProviderTimeout,
    };
    return .{ .status = status, .body = try allocator.dupe(u8, response.written()) };
}

// ---- voice front persona and tools -----------------------------------------

/// Instructions for the real-time model: it is the companion's voice, and
/// the companion thread does the real work through `ask_companion`.
pub fn instructionsAlloc(allocator: std.mem.Allocator, name: []const u8, character_tagline: []const u8, orders: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, orders, " \t\r\n");
    return std.fmt.allocPrint(allocator,
        \\You are {s}, the user's Verde companion, speaking with them live by voice. ({s}.)
        \\You are the voice of an orchestrator that runs coding work across all of the user's Verde workspaces.
        \\Talk naturally and briefly, like a sharp colleague on a call. Never read code, paths, or long lists aloud.
        \\You cannot see code or run anything yourself. For any real work, status beyond what the tools return,
        \\or anything you are unsure about, call ask_companion with a clear, complete request; tell the user you're on it,
        \\and keep chatting while it works. When a companion_update arrives, summarize it in a sentence or two.
        \\Use companion_status for "what's running / what needs me". Only call decide_approval after the user clearly
        \\says to approve or deny a specific chat, and read back what you approved.{s}{s}
    , .{ name, character_tagline, if (trimmed.len > 0) "\nStanding orders from the user: " else "", trimmed });
}

/// Tool schemas shared by every provider adapter (JSON Schema parameters).
pub const TOOLS_JSON =
    \\[
    \\ {"name":"ask_companion","description":"Hand a request to the user's Verde companion, which can open and steer coding chats in any workspace, run processes, and report back. Returns once the request is accepted; the companion's reply arrives later as a companion_update message.","parameters":{"type":"object","properties":{"request":{"type":"string","description":"The complete request in plain language."}},"required":["request"]}},
    \\ {"name":"companion_status","description":"Current orchestration status: chats running in the companion's crew and chats anywhere that need the user's approval or input.","parameters":{"type":"object","properties":{}}},
    \\ {"name":"decide_approval","description":"Approve or deny a pending approval for a specific chat, only after the user explicitly asked to.","parameters":{"type":"object","properties":{"chat":{"type":"string","description":"Chat title or id from companion_status."},"approve":{"type":"boolean"}},"required":["chat","approve"]}}
    \\]
;

// ---- tests -------------------------------------------------------------------

fn testEnv(_: std.mem.Allocator, name: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, name, "GOOGLE_API_KEY")) return "g-key";
    return null;
}

test "config picks env keys, prefers the stored default, and never lists keys" {
    const allocator = std.testing.allocator;
    var config = load(allocator, "", testEnv);
    defer config.deinit();
    try std.testing.expect(config.configured(.gemini));
    try std.testing.expect(!config.configured(.xai));
    try std.testing.expectEqual(ProviderId.gemini, config.pick().?);
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var s: std.json.Stringify = .{ .writer = &out.writer };
    try writeProviders(&s, &config);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "g-key") == null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"key_source\":\"environment\"") != null);
}
