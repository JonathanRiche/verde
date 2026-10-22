//! Real-time voice wire formats, ported from the phone apps
//! (`LiveProtocol.kt`, `LiveProtocols.swift`). Two provider protocols speak the
//! same live conversation: `openai_realtime` (OpenAI Realtime GA and xAI Grok
//! Voice, which keeps the beta session shape) and `gemini_live`. Everything
//! here is pure: JSON text in, normalized events out. Tokens, audio, and
//! transcripts are never logged.

const std = @import("std");

pub const OUTPUT_RATE: u32 = 24_000;

pub const Kind = enum {
    /// OpenAI Realtime GA session shape.
    openai_ga,
    /// xAI Grok Voice: classic beta session shape, cumulative transcripts.
    openai_beta,
    gemini,

    /// Maps the daemon's `protocol` + `provider` to an adapter.
    pub fn from(protocol: []const u8, provider: []const u8) ?Kind {
        if (std.mem.eql(u8, protocol, "openai_realtime")) return if (std.mem.eql(u8, provider, "openai")) .openai_ga else .openai_beta;
        if (std.mem.eql(u8, protocol, "gemini_live")) return .gemini;
        return null;
    }

    /// PCM16 mono rate the provider expects from the microphone.
    pub fn inputRate(self: Kind) u32 {
        return switch (self) {
            .openai_ga, .openai_beta => 24_000,
            .gemini => 16_000,
        };
    }

    pub fn outputRate(_: Kind) u32 {
        return OUTPUT_RATE;
    }

    /// True when the setup message alone makes the session ready.
    pub fn readyOnOpen(self: Kind) bool {
        return self != .gemini;
    }
};

/// What the voice model is told and may call. `tools` is the daemon's JSON
/// array of `{name, description, parameters}`.
pub const SessionConfig = struct {
    model: []const u8,
    voice: []const u8,
    instructions: []const u8,
    tools: std.json.Value = .null,
};

/// A provider message, normalized across protocols. Slices point into the
/// arena `parse` was given.
pub const Event = union(enum) {
    /// The session is configured and accepts audio.
    ready,
    /// PCM16 LE mono at `Kind.outputRate`.
    audio: []const u8,
    assistant_text: []const u8,
    /// The user's finished utterance.
    user_text: struct { text: []const u8, item_id: ?[]const u8 = null },
    /// The utterance so far: `cumulative` replaces the open line (xAI), otherwise it appends.
    user_partial: struct { text: []const u8, cumulative: bool, item_id: ?[]const u8 = null },
    /// The model began a response: whatever the user was saying is over.
    response_started,
    /// The user started talking: stop playback now (barge-in).
    interrupted,
    turn_done,
    tool_call: struct { call_id: []const u8, name: []const u8, arguments: std.json.Value },
    /// The server is about to close; reconnect with a fresh session.
    go_away,
    failure: []const u8,
    ignored,
};

// ---- outgoing ----------------------------------------------------------------

/// The message sent right after the socket opens.
pub fn setupAlloc(allocator: std.mem.Allocator, kind: Kind, config: SessionConfig) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var s: std.json.Stringify = .{ .writer = &out.writer };
    switch (kind) {
        .openai_ga, .openai_beta => {
            try s.beginObject();
            try s.objectField("type");
            try s.write("session.update");
            try s.objectField("session");
            try s.beginObject();
            if (kind == .openai_ga) {
                try s.objectField("type");
                try s.write("realtime");
                try s.objectField("instructions");
                try s.write(config.instructions);
                try s.objectField("audio");
                try s.write(.{
                    .input = .{
                        .format = .{ .type = "audio/pcm", .rate = kind.inputRate() },
                        .turn_detection = .{ .type = "server_vad" },
                        .transcription = .{ .model = "gpt-4o-mini-transcribe" },
                    },
                    .output = .{
                        .format = .{ .type = "audio/pcm", .rate = kind.outputRate() },
                        .voice = config.voice,
                    },
                });
            } else {
                try s.objectField("instructions");
                try s.write(config.instructions);
                try s.objectField("voice");
                try s.write(config.voice);
                try s.objectField("input_audio_format");
                try s.write("pcm16");
                try s.objectField("output_audio_format");
                try s.write("pcm16");
                try s.objectField("turn_detection");
                try s.write(.{ .type = "server_vad" });
                // xAI: the user's words come back as cumulative `...transcription.updated` events.
                try s.objectField("audio");
                try s.write(.{ .input = .{ .transcription = .{ .model = "grok-transcribe" } } });
            }
            try s.objectField("tools");
            try s.beginArray();
            for (toolRows(config.tools)) |tool| {
                try s.beginObject();
                try s.objectField("type");
                try s.write("function");
                try writeToolFields(&s, tool);
                try s.endObject();
            }
            try s.endArray();
            try s.endObject();
            try s.endObject();
        },
        .gemini => {
            try s.beginObject();
            try s.objectField("setup");
            try s.beginObject();
            try s.objectField("model");
            if (std.mem.startsWith(u8, config.model, "models/")) {
                try s.write(config.model);
            } else {
                const qualified = try std.fmt.allocPrint(allocator, "models/{s}", .{config.model});
                defer allocator.free(qualified);
                try s.write(qualified);
            }
            try s.objectField("generationConfig");
            try s.write(.{
                .responseModalities = &[_][]const u8{"AUDIO"},
                .speechConfig = .{ .voiceConfig = .{ .prebuiltVoiceConfig = .{ .voiceName = config.voice } } },
            });
            try s.objectField("systemInstruction");
            try s.write(.{ .parts = &[_]struct { text: []const u8 }{.{ .text = config.instructions }} });
            try s.objectField("tools");
            try s.beginArray();
            try s.beginObject();
            try s.objectField("functionDeclarations");
            try s.beginArray();
            for (toolRows(config.tools)) |tool| {
                try s.beginObject();
                try writeToolFields(&s, tool);
                try s.endObject();
            }
            try s.endArray();
            try s.endObject();
            try s.endArray();
            try s.objectField("inputAudioTranscription");
            try s.write(.{});
            try s.objectField("outputAudioTranscription");
            try s.write(.{});
            try s.endObject();
            try s.endObject();
        },
    }
    return out.toOwnedSlice();
}

/// One microphone chunk (PCM16 LE mono at `kind.inputRate()`).
pub fn audioAlloc(allocator: std.mem.Allocator, kind: Kind, pcm: []const u8) ![]u8 {
    const encoder = std.base64.standard.Encoder;
    const prefix: []const u8, const suffix: []const u8 = switch (kind) {
        .openai_ga, .openai_beta => .{ "{\"type\":\"input_audio_buffer.append\",\"audio\":\"", "\"}" },
        .gemini => .{ "{\"realtimeInput\":{\"audio\":{\"data\":\"", "\",\"mimeType\":\"audio/pcm;rate=16000\"}}}" },
    };
    const encoded_len = encoder.calcSize(pcm.len);
    const out = try allocator.alloc(u8, prefix.len + encoded_len + suffix.len);
    @memcpy(out[0..prefix.len], prefix);
    _ = encoder.encode(out[prefix.len..][0..encoded_len], pcm);
    @memcpy(out[prefix.len + encoded_len ..], suffix);
    return out;
}

/// Messages answering a tool call; `output` is a JSON object.
pub fn toolResultAlloc(allocator: std.mem.Allocator, kind: Kind, call_id: []const u8, name: []const u8, output: std.json.Value) ![]const []u8 {
    var messages: std.ArrayList([]u8) = .empty;
    errdefer {
        for (messages.items) |message| allocator.free(message);
        messages.deinit(allocator);
    }
    switch (kind) {
        .openai_ga, .openai_beta => {
            const output_text = try std.json.Stringify.valueAlloc(allocator, output, .{});
            defer allocator.free(output_text);
            try messages.append(allocator, try std.json.Stringify.valueAlloc(allocator, .{
                .type = "conversation.item.create",
                .item = .{ .type = "function_call_output", .call_id = call_id, .output = output_text },
            }, .{}));
            try messages.append(allocator, try allocator.dupe(u8, RESPONSE_CREATE));
        },
        .gemini => {
            const Response = struct { id: []const u8, name: []const u8, response: std.json.Value };
            try messages.append(allocator, try std.json.Stringify.valueAlloc(allocator, .{
                .toolResponse = .{ .functionResponses = &[_]Response{.{ .id = call_id, .name = name, .response = output }} },
            }, .{}));
        },
    }
    return messages.toOwnedSlice(allocator);
}

/// A user-side text (a companion update) that asks the model for a spoken answer.
pub fn injectAlloc(allocator: std.mem.Allocator, kind: Kind, text: []const u8) ![]const []u8 {
    var messages: std.ArrayList([]u8) = .empty;
    errdefer {
        for (messages.items) |message| allocator.free(message);
        messages.deinit(allocator);
    }
    const Text = struct { type: []const u8 = "input_text", text: []const u8 };
    const Part = struct { text: []const u8 };
    const Turn = struct { role: []const u8 = "user", parts: []const Part };
    switch (kind) {
        .openai_ga, .openai_beta => {
            try messages.append(allocator, try std.json.Stringify.valueAlloc(allocator, .{
                .type = "conversation.item.create",
                .item = .{ .type = "message", .role = "user", .content = &[_]Text{.{ .text = text }} },
            }, .{}));
            try messages.append(allocator, try allocator.dupe(u8, RESPONSE_CREATE));
        },
        .gemini => {
            try messages.append(allocator, try std.json.Stringify.valueAlloc(allocator, .{
                .clientContent = .{ .turns = &[_]Turn{.{ .parts = &[_]Part{.{ .text = text }} }}, .turnComplete = true },
            }, .{}));
        },
    }
    return messages.toOwnedSlice(allocator);
}

pub fn freeMessages(allocator: std.mem.Allocator, messages: []const []u8) void {
    for (messages) |message| allocator.free(message);
    allocator.free(messages);
}

const RESPONSE_CREATE = "{\"type\":\"response.create\"}";

fn toolRows(tools: std.json.Value) []const std.json.Value {
    return if (tools == .array) tools.array.items else &.{};
}

fn writeToolFields(s: *std.json.Stringify, tool: std.json.Value) !void {
    const fields = if (tool == .object) tool.object else std.json.ObjectMap.empty;
    try s.objectField("name");
    try s.write(stringOf(fields.get("name")) orelse "");
    try s.objectField("description");
    try s.write(stringOf(fields.get("description")) orelse "");
    try s.objectField("parameters");
    // A malformed schema degrades to an empty object schema.
    const schema = fields.get("parameters") orelse .null;
    if (schema == .object) {
        try s.write(schema);
    } else {
        try s.write(.{ .type = "object", .properties = .{} });
    }
}

// ---- incoming ----------------------------------------------------------------

/// Parses one provider text message. Events and their slices live in `arena`.
pub fn parse(arena: std.mem.Allocator, kind: Kind, text: []const u8) ![]const Event {
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{}) catch return &.{.ignored};
    if (root != .object) return &.{.ignored};
    return switch (kind) {
        .openai_ga, .openai_beta => parseOpenAi(arena, root.object),
        .gemini => parseGemini(arena, root.object),
    };
}

fn parseOpenAi(arena: std.mem.Allocator, message: std.json.ObjectMap) ![]const Event {
    const kind = stringOf(message.get("type")) orelse "";
    const event: Event = event: {
        if (eql(kind, "response.output_audio.delta") or eql(kind, "response.audio.delta")) {
            const pcm = try decodeBase64(arena, stringOf(message.get("delta")) orelse "") orelse break :event .ignored;
            break :event .{ .audio = pcm };
        }
        if (eql(kind, "response.output_audio_transcript.delta") or eql(kind, "response.audio_transcript.delta"))
            break :event .{ .assistant_text = stringOf(message.get("delta")) orelse "" };
        if (eql(kind, "conversation.item.input_audio_transcription.completed"))
            break :event .{ .user_text = .{ .text = stringOf(message.get("transcript")) orelse "", .item_id = stringOf(message.get("item_id")) } };
        if (eql(kind, "conversation.item.input_audio_transcription.updated"))
            break :event .{ .user_partial = .{
                .text = stringOf(message.get("transcript")) orelse stringOf(message.get("text")) orelse "",
                .cumulative = true,
                .item_id = stringOf(message.get("item_id")),
            } };
        if (eql(kind, "conversation.item.input_audio_transcription.delta"))
            break :event .{ .user_partial = .{ .text = stringOf(message.get("delta")) orelse "", .cumulative = false, .item_id = stringOf(message.get("item_id")) } };
        if (eql(kind, "response.created")) break :event .response_started;
        if (eql(kind, "input_audio_buffer.speech_started")) break :event .interrupted;
        if (eql(kind, "response.done")) break :event .turn_done;
        if (eql(kind, "response.function_call_arguments.done"))
            break :event .{ .tool_call = .{
                .call_id = stringOf(message.get("call_id")) orelse "",
                .name = stringOf(message.get("name")) orelse "",
                .arguments = toolArguments(arena, stringOf(message.get("arguments"))),
            } };
        if (eql(kind, "session.created") or eql(kind, "session.updated")) break :event .ready;
        if (eql(kind, "error")) {
            const detail = objectOf(message.get("error"));
            const code = if (detail) |d| stringOf(d.get("code")) orelse stringOf(d.get("type")) else null;
            break :event .{ .failure = code orelse "provider_error" };
        }
        break :event .ignored;
    };
    const out = try arena.alloc(Event, 1);
    out[0] = event;
    return out;
}

fn parseGemini(arena: std.mem.Allocator, message: std.json.ObjectMap) ![]const Event {
    var out: std.ArrayList(Event) = .empty;
    if (message.get("setupComplete") != null) try out.append(arena, .ready);
    if (objectOf(message.get("serverContent"))) |content| {
        if (boolOf(content.get("interrupted"))) try out.append(arena, .interrupted);
        // Gemini streams the user's words in pieces; the line closes when the model answers.
        if (objectOf(content.get("inputTranscription"))) |input| {
            if (stringOf(input.get("text"))) |words| if (words.len > 0) try out.append(arena, .{ .user_partial = .{ .text = words, .cumulative = false } });
        }
        if (objectOf(content.get("outputTranscription"))) |output| {
            if (stringOf(output.get("text"))) |words| try out.append(arena, .{ .assistant_text = words });
        }
        if (objectOf(content.get("modelTurn"))) |turn| {
            const parts = turn.get("parts") orelse .null;
            if (parts == .array) for (parts.array.items) |part| {
                const inline_data = objectOf(if (part == .object) part.object.get("inlineData") else null) orelse continue;
                const data = stringOf(inline_data.get("data")) orelse continue;
                if (try decodeBase64(arena, data)) |pcm| try out.append(arena, .{ .audio = pcm });
            };
        }
        if (boolOf(content.get("turnComplete"))) try out.append(arena, .turn_done);
    }
    if (objectOf(message.get("toolCall"))) |call| {
        const calls = call.get("functionCalls") orelse .null;
        if (calls == .array) for (calls.array.items) |item| {
            if (item != .object) continue;
            try out.append(arena, .{ .tool_call = .{
                .call_id = stringOf(item.object.get("id")) orelse "",
                .name = stringOf(item.object.get("name")) orelse "",
                .arguments = if (item.object.get("args")) |args| (if (args == .object) args else emptyObject()) else emptyObject(),
            } });
        };
    }
    if (message.get("goAway") != null) try out.append(arena, .go_away);
    if (objectOf(message.get("error"))) |detail| try out.append(arena, .{ .failure = stringOf(detail.get("status")) orelse "provider_error" });
    if (out.items.len == 0) try out.append(arena, .ignored);
    return out.items;
}

/// Function arguments arrive as a JSON string; anything unreadable is an empty object.
fn toolArguments(arena: std.mem.Allocator, raw: ?[]const u8) std.json.Value {
    const text = raw orelse return emptyObject();
    const value = std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{}) catch return emptyObject();
    return if (value == .object) value else emptyObject();
}

fn emptyObject() std.json.Value {
    return .{ .object = .empty };
}

fn decodeBase64(arena: std.mem.Allocator, text: []const u8) !?[]u8 {
    const decoder = std.base64.standard.Decoder;
    const size = decoder.calcSizeForSlice(text) catch return null;
    const out = try arena.alloc(u8, size);
    decoder.decode(out, text) catch return null;
    return out;
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

pub fn stringOf(value: ?std.json.Value) ?[]const u8 {
    const v = value orelse return null;
    return if (v == .string) v.string else null;
}

pub fn objectOf(value: ?std.json.Value) ?std.json.ObjectMap {
    const v = value orelse return null;
    return if (v == .object) v.object else null;
}

fn boolOf(value: ?std.json.Value) bool {
    const v = value orelse return false;
    return v == .bool and v.bool;
}

// ---- companion update text -----------------------------------------------------

pub const COMPANION_UPDATE_CHARS: usize = 600;

/// The text injected into the live session when the companion's turn
/// finishes: markdown punctuation dropped, clipped on a UTF-8 boundary.
pub fn companionUpdateAlloc(allocator: std.mem.Allocator, reply: []const u8) ![]u8 {
    var plain: std.ArrayList(u8) = .empty;
    defer plain.deinit(allocator);
    var in_fence = false;
    var lines = std.mem.splitScalar(u8, reply, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (std.mem.startsWith(u8, line, "```")) {
            in_fence = !in_fence;
            continue;
        }
        if (in_fence or line.len == 0) continue;
        const body = std.mem.trimStart(u8, line, "#>*-+ \t");
        if (body.len == 0) continue;
        if (plain.items.len > 0) try plain.append(allocator, ' ');
        for (body) |byte| if (byte != '*' and byte != '`' and byte != '_') try plain.append(allocator, byte);
    }
    const text = if (plain.items.len > 0) plain.items else std.mem.trim(u8, reply, &std.ascii.whitespace);
    if (text.len <= COMPANION_UPDATE_CHARS) return std.fmt.allocPrint(allocator, "companion_update: {s}", .{text});
    var cut = COMPANION_UPDATE_CHARS - 1;
    while (cut > 0 and (text[cut] & 0xC0) == 0x80) cut -= 1;
    return std.fmt.allocPrint(allocator, "companion_update: {s}…", .{std.mem.trimEnd(u8, text[0..cut], " ")});
}

// ---- tests ---------------------------------------------------------------------

const testing = std.testing;

fn testTools(arena: std.mem.Allocator) !std.json.Value {
    return std.json.parseFromSliceLeaky(std.json.Value, arena,
        \\[{"name":"ask_companion","description":"Ask","parameters":{"type":"object","properties":{"request":{"type":"string"}}}},
        \\ {"name":"companion_status","description":"Status","parameters":"broken"}]
    , .{});
}

test "kind maps daemon protocol and provider" {
    try testing.expectEqual(Kind.openai_ga, Kind.from("openai_realtime", "openai").?);
    try testing.expectEqual(Kind.openai_beta, Kind.from("openai_realtime", "xai").?);
    try testing.expectEqual(Kind.gemini, Kind.from("gemini_live", "gemini").?);
    try testing.expect(Kind.from("webrtc", "x") == null);
    try testing.expectEqual(@as(u32, 16_000), Kind.gemini.inputRate());
    try testing.expectEqual(@as(u32, 24_000), Kind.openai_beta.inputRate());
    try testing.expect(!Kind.gemini.readyOnOpen());
}

test "openai setup carries instructions, voice, vad, and function tools" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const config: SessionConfig = .{ .model = "gpt-realtime", .voice = "marin", .instructions = "Be brief", .tools = try testTools(arena) };
    const ga = try setupAlloc(arena, .openai_ga, config);
    const root = try std.json.parseFromSliceLeaky(std.json.Value, arena, ga, .{});
    const session = root.object.get("session").?.object;
    try testing.expectEqualStrings("session.update", root.object.get("type").?.string);
    try testing.expectEqualStrings("realtime", session.get("type").?.string);
    try testing.expectEqualStrings("marin", session.get("audio").?.object.get("output").?.object.get("voice").?.string);
    try testing.expectEqual(@as(i64, 24_000), session.get("audio").?.object.get("input").?.object.get("format").?.object.get("rate").?.integer);
    const tools = session.get("tools").?.array.items;
    try testing.expectEqual(@as(usize, 2), tools.len);
    try testing.expectEqualStrings("function", tools[0].object.get("type").?.string);
    // A malformed schema degrades to an empty object schema.
    try testing.expectEqualStrings("object", tools[1].object.get("parameters").?.object.get("type").?.string);

    const beta = try setupAlloc(arena, .openai_beta, config);
    const beta_root = try std.json.parseFromSliceLeaky(std.json.Value, arena, beta, .{});
    const beta_session = beta_root.object.get("session").?.object;
    try testing.expectEqualStrings("pcm16", beta_session.get("input_audio_format").?.string);
    try testing.expectEqualStrings("marin", beta_session.get("voice").?.string);
    try testing.expectEqualStrings("grok-transcribe", beta_session.get("audio").?.object.get("input").?.object.get("transcription").?.object.get("model").?.string);
}

test "gemini setup qualifies the model and declares functions" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const text = try setupAlloc(arena, .gemini, .{ .model = "gemini-live", .voice = "Puck", .instructions = "Hi", .tools = try testTools(arena) });
    const setup = (try std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{})).object.get("setup").?.object;
    try testing.expectEqualStrings("models/gemini-live", setup.get("model").?.string);
    try testing.expectEqualStrings("Puck", setup.get("generationConfig").?.object.get("speechConfig").?.object.get("voiceConfig").?.object.get("prebuiltVoiceConfig").?.object.get("voiceName").?.string);
    const declarations = setup.get("tools").?.array.items[0].object.get("functionDeclarations").?.array.items;
    try testing.expectEqualStrings("ask_companion", declarations[0].object.get("name").?.string);
    try testing.expect(setup.get("inputAudioTranscription") != null);
}

test "audio messages base64 the pcm" {
    const allocator = testing.allocator;
    const openai = try audioAlloc(allocator, .openai_beta, &.{ 1, 2, 3 });
    defer allocator.free(openai);
    try testing.expectEqualStrings("{\"type\":\"input_audio_buffer.append\",\"audio\":\"AQID\"}", openai);
    const gemini = try audioAlloc(allocator, .gemini, &.{ 1, 2, 3 });
    defer allocator.free(gemini);
    try testing.expectEqualStrings("{\"realtimeInput\":{\"audio\":{\"data\":\"AQID\",\"mimeType\":\"audio/pcm;rate=16000\"}}}", gemini);
}

test "openai events normalize audio, transcripts, barge-in, tools, and errors" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectEqualSlices(u8, &.{ 1, 2, 3 }, (try parse(arena, .openai_ga, "{\"type\":\"response.output_audio.delta\",\"delta\":\"AQID\"}"))[0].audio);
    try testing.expectEqualSlices(u8, &.{ 1, 2, 3 }, (try parse(arena, .openai_beta, "{\"type\":\"response.audio.delta\",\"delta\":\"AQID\"}"))[0].audio);
    try testing.expectEqualStrings("Hi", (try parse(arena, .openai_ga, "{\"type\":\"response.output_audio_transcript.delta\",\"delta\":\"Hi\"}"))[0].assistant_text);
    const done = (try parse(arena, .openai_ga, "{\"type\":\"conversation.item.input_audio_transcription.completed\",\"transcript\":\"Run tests\",\"item_id\":\"i1\"}"))[0].user_text;
    try testing.expectEqualStrings("Run tests", done.text);
    try testing.expectEqualStrings("i1", done.item_id.?);
    const updated = (try parse(arena, .openai_beta, "{\"type\":\"conversation.item.input_audio_transcription.updated\",\"transcript\":\"Run\"}"))[0].user_partial;
    try testing.expect(updated.cumulative);
    const delta = (try parse(arena, .openai_ga, "{\"type\":\"conversation.item.input_audio_transcription.delta\",\"delta\":\"Ru\"}"))[0].user_partial;
    try testing.expect(!delta.cumulative);
    try testing.expect((try parse(arena, .openai_ga, "{\"type\":\"input_audio_buffer.speech_started\"}"))[0] == .interrupted);
    try testing.expect((try parse(arena, .openai_ga, "{\"type\":\"response.created\"}"))[0] == .response_started);
    try testing.expect((try parse(arena, .openai_ga, "{\"type\":\"response.done\"}"))[0] == .turn_done);
    try testing.expect((try parse(arena, .openai_ga, "{\"type\":\"session.updated\"}"))[0] == .ready);
    const call = (try parse(arena, .openai_ga, "{\"type\":\"response.function_call_arguments.done\",\"call_id\":\"c1\",\"name\":\"ask_companion\",\"arguments\":\"{\\\"request\\\":\\\"deploy\\\"}\"}"))[0].tool_call;
    try testing.expectEqualStrings("c1", call.call_id);
    try testing.expectEqualStrings("deploy", call.arguments.object.get("request").?.string);
    const bad_args = (try parse(arena, .openai_ga, "{\"type\":\"response.function_call_arguments.done\",\"call_id\":\"c2\",\"name\":\"x\",\"arguments\":\"nope\"}"))[0].tool_call;
    try testing.expectEqual(@as(usize, 0), bad_args.arguments.object.count());
    try testing.expectEqualStrings("invalid_api_key", (try parse(arena, .openai_ga, "{\"type\":\"error\",\"error\":{\"code\":\"invalid_api_key\"}}"))[0].failure);
    try testing.expect((try parse(arena, .openai_ga, "not json"))[0] == .ignored);
    try testing.expect((try parse(arena, .openai_ga, "{\"type\":\"rate_limits.updated\"}"))[0] == .ignored);
}

test "gemini messages split into several events" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expect((try parse(arena, .gemini, "{\"setupComplete\":{}}"))[0] == .ready);
    const events = try parse(arena, .gemini,
        \\{"serverContent":{"inputTranscription":{"text":"hel"},"outputTranscription":{"text":"Sure"},
        \\"modelTurn":{"parts":[{"inlineData":{"data":"AQID","mimeType":"audio/pcm"}}]},"turnComplete":true}}
    );
    try testing.expectEqual(@as(usize, 4), events.len);
    try testing.expectEqualStrings("hel", events[0].user_partial.text);
    try testing.expectEqualStrings("Sure", events[1].assistant_text);
    try testing.expectEqualSlices(u8, &.{ 1, 2, 3 }, events[2].audio);
    try testing.expect(events[3] == .turn_done);
    try testing.expect((try parse(arena, .gemini, "{\"serverContent\":{\"interrupted\":true}}"))[0] == .interrupted);
    const call = (try parse(arena, .gemini, "{\"toolCall\":{\"functionCalls\":[{\"id\":\"f1\",\"name\":\"companion_status\",\"args\":{}}]}}"))[0].tool_call;
    try testing.expectEqualStrings("f1", call.call_id);
    try testing.expect((try parse(arena, .gemini, "{\"goAway\":{\"timeLeft\":\"5s\"}}"))[0] == .go_away);
}

test "tool results and injected updates per protocol" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var output: std.json.ObjectMap = .empty;
    try output.put(arena, "accepted", .{ .bool = true });
    const openai = try toolResultAlloc(arena, .openai_ga, "c1", "ask_companion", .{ .object = output });
    try testing.expectEqual(@as(usize, 2), openai.len);
    const item = (try std.json.parseFromSliceLeaky(std.json.Value, arena, openai[0], .{})).object.get("item").?.object;
    try testing.expectEqualStrings("{\"accepted\":true}", item.get("output").?.string);
    try testing.expectEqualStrings("{\"type\":\"response.create\"}", openai[1]);
    const gemini = try toolResultAlloc(arena, .gemini, "f1", "ask_companion", .{ .object = output });
    try testing.expectEqual(@as(usize, 1), gemini.len);
    const response = (try std.json.parseFromSliceLeaky(std.json.Value, arena, gemini[0], .{})).object.get("toolResponse").?.object.get("functionResponses").?.array.items[0].object;
    try testing.expect(response.get("response").?.object.get("accepted").?.bool);

    const inject = try injectAlloc(arena, .openai_beta, "companion_update: done");
    try testing.expectEqual(@as(usize, 2), inject.len);
    try testing.expect(std.mem.indexOf(u8, inject[0], "input_text") != null);
    const gemini_inject = try injectAlloc(arena, .gemini, "hi");
    try testing.expect(std.mem.indexOf(u8, gemini_inject[0], "\"turnComplete\":true") != null);
}

test "companion update strips markdown and clips on a character boundary" {
    const allocator = testing.allocator;
    const short = try companionUpdateAlloc(allocator, "## Done\n\n- **Tests** pass\n```\ncode\n```\n");
    defer allocator.free(short);
    try testing.expectEqualStrings("companion_update: Done Tests pass", short);
    const long_text = "é" ** 400;
    const long = try companionUpdateAlloc(allocator, long_text);
    defer allocator.free(long);
    try testing.expect(std.unicode.utf8ValidateSlice(long));
    try testing.expect(std.mem.endsWith(u8, long, "…"));
}
