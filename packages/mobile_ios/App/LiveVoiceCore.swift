import Foundation

/*
 * Live voice through the host core. The daemon keeps provider API keys on the desktop and mints
 * short-lived provider tokens; the core exposes `voice_providers_refresh`,
 * `voice_provider_configure`, `voice_session_create` and the `voice` view. Until CoreModels.swift
 * is regenerated with those types, intents go out as raw tagged events (`CoreHost.sendIntent`) and
 * the view is decoded here leniently: field-name fixes are one-liners in this file.
 * Tokens and keys are never logged.
 */

// MARK: - The `voice` view

struct LiveVoiceProvider: Decodable, Equatable, Identifiable {
    var id: String
    var label: String
    /// `openai_realtime` or `gemini_live` (wire field `protocol`).
    var protocolName: String
    var configured: Bool
    /// `none`, `environment` or `verde`.
    var key_source: String
    var model: String
    var voice: String
    var voices: [String]

    private enum Keys: String, CodingKey { case id, label, protocolName = "protocol", configured, key_source, model, voice, voices }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? id
        protocolName = try c.decodeIfPresent(String.self, forKey: .protocolName) ?? "openai_realtime"
        configured = try c.decodeIfPresent(Bool.self, forKey: .configured) ?? false
        key_source = try c.decodeIfPresent(String.self, forKey: .key_source) ?? "none"
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? ""
        voice = try c.decodeIfPresent(String.self, forKey: .voice) ?? ""
        voices = try c.decodeIfPresent([String].self, forKey: .voices) ?? []
    }
    init(id: String, label: String, protocolName: String, configured: Bool = true, key_source: String = "verde",
         model: String = "", voice: String = "", voices: [String] = []) {
        self.id = id; self.label = label; self.protocolName = protocolName; self.configured = configured
        self.key_source = key_source; self.model = model; self.voice = voice; self.voices = voices
    }

    var keyDescription: String {
        switch key_source {
        case "environment": return "Key from the desktop's environment"
        case "verde": return "Key saved in verde on the desktop"
        default: return configured ? "Configured" : "No API key yet"
        }
    }
}

struct LiveVoiceTool: Decodable, Equatable {
    var name: String
    var description: String
    /// JSON Schema as a raw JSON string.
    var parameters: String

    private enum Keys: String, CodingKey { case name, description, parameters }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        // Tolerate a schema sent as an object instead of a string.
        if let text = try? c.decodeIfPresent(String.self, forKey: .parameters) {
            parameters = text
        } else if let value = try? c.decodeIfPresent(JSONValue.self, forKey: .parameters),
                  let data = try? JSONEncoder().encode(value) {
            parameters = String(decoding: data, as: UTF8.self)
        } else {
            parameters = ""
        }
    }
    init(name: String, description: String, parameters: String) {
        self.name = name; self.description = description; self.parameters = parameters
    }
}

struct LiveVoiceCompanion: Decodable, Equatable {
    var id = ""
    var name = ""
    var home_workspace_id = ""
    var thread_id = ""
}

struct LiveVoiceSession: Decodable, Equatable {
    var intent_id: String
    /// `pending`, `ready` or `failed`.
    var status: String
    var error_code: String?
    var provider: String
    /// Wire field `protocol`.
    var protocolName: String
    var model: String
    var voice: String
    var token: String
    var expires_at_ms: Int64
    var websocket_url: String
    /// `bearer` (Authorization header) or `query` (token already in the URL).
    var auth: String
    var instructions: String
    var tools: [LiveVoiceTool]
    var companion: LiveVoiceCompanion?

    private enum Keys: String, CodingKey {
        case intent_id, status, error_code, provider, protocolName = "protocol", model, voice, token, expires_at_ms, websocket_url, auth, instructions, tools, companion
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        intent_id = try c.decodeIfPresent(String.self, forKey: .intent_id) ?? ""
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? "pending"
        error_code = try c.decodeIfPresent(String.self, forKey: .error_code)
        provider = try c.decodeIfPresent(String.self, forKey: .provider) ?? ""
        protocolName = try c.decodeIfPresent(String.self, forKey: .protocolName) ?? "openai_realtime"
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? ""
        voice = try c.decodeIfPresent(String.self, forKey: .voice) ?? ""
        token = try c.decodeIfPresent(String.self, forKey: .token) ?? ""
        expires_at_ms = try c.decodeIfPresent(Int64.self, forKey: .expires_at_ms) ?? 0
        websocket_url = try c.decodeIfPresent(String.self, forKey: .websocket_url) ?? ""
        auth = try c.decodeIfPresent(String.self, forKey: .auth) ?? "bearer"
        instructions = try c.decodeIfPresent(String.self, forKey: .instructions) ?? ""
        tools = try c.decodeIfPresent([LiveVoiceTool].self, forKey: .tools) ?? []
        companion = try c.decodeIfPresent(LiveVoiceCompanion.self, forKey: .companion)
    }
}

struct LiveVoiceView: Decodable, Equatable {
    var loaded = false
    var loading = false
    var supported = true
    var default_provider = ""
    var providers: [LiveVoiceProvider] = []
    var session: LiveVoiceSession?

    private enum Keys: String, CodingKey { case loaded, loading, supported, default_provider, providers, session }
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        loaded = try c.decodeIfPresent(Bool.self, forKey: .loaded) ?? false
        loading = try c.decodeIfPresent(Bool.self, forKey: .loading) ?? false
        supported = try c.decodeIfPresent(Bool.self, forKey: .supported) ?? true
        default_provider = try c.decodeIfPresent(String.self, forKey: .default_provider) ?? ""
        providers = try c.decodeIfPresent([LiveVoiceProvider].self, forKey: .providers) ?? []
        session = try c.decodeIfPresent(LiveVoiceSession.self, forKey: .session)
    }
}

/// The selector envelope (`{api_version, revision, data, error}`).
private struct LiveVoiceQuery: Decodable { var data: LiveVoiceView? }

func decodeLiveVoiceView(_ data: Data?) -> LiveVoiceView? {
    guard let data else { return nil }
    return (try? JSONDecoder().decode(LiveVoiceQuery.self, from: data))?.data
}

// MARK: - Intents

enum LiveVoiceIntent {
    static let refresh = "voice_providers_refresh"
    static let configure = "voice_provider_configure"
    static let session = "voice_session_create"
    static let transcriptSave = "companion_transcript_save"

    static func refreshFields(intentID: String) -> [String: JSONValue] { ["intent_id": .string(intentID)] }

    /// Empty optional strings are omitted (unchanged on the desktop).
    static func configureFields(intentID: String, provider: String, apiKey: String?, model: String?, voice: String?,
                                makeDefault: Bool?) -> [String: JSONValue] {
        var fields: [String: JSONValue] = ["intent_id": .string(intentID), "provider": .string(provider)]
        if let apiKey, !apiKey.isEmpty { fields["api_key"] = .string(apiKey) }
        if let model, !model.isEmpty { fields["model"] = .string(model) }
        if let voice, !voice.isEmpty { fields["voice"] = .string(voice) }
        if let makeDefault { fields["make_default"] = .bool(makeDefault) }
        return fields
    }

    /// One `companion_transcript_save` event (callers batch to `LiveTranscript.batchLimit`).
    static func transcriptFields(intentID: String, workspaceID: String, threadID: String, sessionID: String,
                                 lines: [LiveTranscriptLine]) -> [String: JSONValue] {
        ["intent_id": .string(intentID), "workspace_id": .string(workspaceID), "thread_id": .string(threadID),
         "session_id": .string(sessionID),
         "messages": .array(lines.map { line -> JSONValue in
             JSONValue.object(["key": .string(line.key), "role": .string(line.role), "author": .string(line.author),
                      "body": .string(line.body), "created_at_ms": .integer(line.createdAtMs)])
         })]
    }

    static func sessionFields(intentID: String, provider: String?, model: String?, voice: String?, companionID: String?) -> [String: JSONValue] {
        var fields: [String: JSONValue] = ["intent_id": .string(intentID)]
        if let provider, !provider.isEmpty { fields["provider"] = .string(provider) }
        if let model, !model.isEmpty { fields["model"] = .string(model) }
        if let voice, !voice.isEmpty { fields["voice"] = .string(voice) }
        if let companionID, !companionID.isEmpty { fields["companion_id"] = .string(companionID) }
        return fields
    }
}

/// User-facing text for a session or intent failure code.
func liveVoiceMessage(_ code: String?) -> String {
    switch code {
    case "voice_not_configured"?: return "Add an API key for a live voice provider in Companion settings."
    case "voice_key_rejected"?: return "The provider rejected the API key saved on your desktop. Replace it in Companion settings."
    case "voice_provider_unavailable"?: return "The live voice provider is unavailable right now. Try again shortly."
    case "insufficient_scope"?, "scope_denied"?: return "This phone isn't allowed to start live voice on this host."
    case "rejected"?, "method_not_found"?, "unsupported"?: return "Update verde on the computer to use live voice."
    case "offline"?: return "Connect to the host first."
    default: return "Couldn't start live voice."
    }
}

enum LiveVoiceError: Error, Equatable { case failed(String) }

/// Sends live-voice intents and follows their receipts and the `voice` view.
@MainActor
struct LiveVoiceClient {
    static let timeout: Duration = .seconds(20)
    let browse: BrowseModel

    var view: LiveVoiceView? { decodeLiveVoiceView(browse.session?.store.snapshots["voice"]) }

    private func send(_ type: String, _ fields: [String: JSONValue]) async throws -> (CoreHost, String) {
        guard let session = browse.session else { throw LiveVoiceError.failed("offline") }
        await session.start()
        guard let host = session.host, case .string(let intent)? = fields["intent_id"] else { throw LiveVoiceError.failed("offline") }
        do { try await host.sendIntent(type, fields) }
        catch CoreBridgeError.rejected { throw LiveVoiceError.failed("rejected") }
        catch { throw LiveVoiceError.failed("offline") }
        return (host, intent)
    }

    /// Waits for the receipt to leave `pending`; returns its error code when it failed.
    private func settle(_ host: CoreHost, _ intent: String) async throws -> String? {
        let deadline = ContinuousClock.now.advanced(by: Self.timeout)
        while ContinuousClock.now < deadline {
            let data = try? await host.query("operations")
            let operation = data.flatMap { try? JSONDecoder().decode(OperationsQuery.self, from: $0) }?
                .data?.items.first { $0.intent_id == intent }
            if let operation, operation.state != "pending" {
                return operation.state == "failed" ? (operation.error?.rpc_code ?? operation.error?.code ?? "failed") : nil
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        return "timeout"
    }

    func refresh() async {
        guard let sent = try? await send(LiveVoiceIntent.refresh, LiveVoiceIntent.refreshFields(intentID: UUID().uuidString)) else { return }
        _ = try? await settle(sent.0, sent.1)
    }

    /// Returns an error message, or nil when the desktop saved the change.
    func configure(provider: String, apiKey: String?, model: String?, voice: String?, makeDefault: Bool?) async -> String? {
        let fields = LiveVoiceIntent.configureFields(intentID: UUID().uuidString, provider: provider, apiKey: apiKey,
                                                     model: model, voice: voice, makeDefault: makeDefault)
        do {
            let (host, intent) = try await send(LiveVoiceIntent.configure, fields)
            guard let code = try await settle(host, intent) else { return nil }
            return code == "voice_key_rejected" ? liveVoiceMessage(code) : "The desktop couldn't save this (\(code))."
        } catch LiveVoiceError.failed(let code) { return liveVoiceMessage(code) }
        catch { return liveVoiceMessage(nil) }
    }

    /// Saves live conversation lines into the companion's chat; returns whether the desktop took them.
    func saveTranscript(workspaceID: String, threadID: String, sessionID: String, lines: [LiveTranscriptLine]) async -> Bool {
        let fields = LiveVoiceIntent.transcriptFields(intentID: UUID().uuidString, workspaceID: workspaceID, threadID: threadID,
                                                      sessionID: sessionID, lines: lines)
        guard let sent = try? await send(LiveVoiceIntent.transcriptSave, fields) else { return false }
        return (try? await settle(sent.0, sent.1)) == .some(nil)
    }

    /// Mints a session (provider token, URL, instructions and tools) on the desktop.
    func createSession(provider: String? = nil, model: String? = nil, voice: String? = nil, companionID: String?) async throws -> LiveVoiceSession {
        let id = UUID().uuidString
        let (host, intent) = try await send(LiveVoiceIntent.session, LiveVoiceIntent.sessionFields(
            intentID: id, provider: provider, model: model, voice: voice, companionID: companionID))
        let deadline = ContinuousClock.now.advanced(by: Self.timeout)
        while ContinuousClock.now < deadline {
            let data = try? await host.query("voice")
            if let session = decodeLiveVoiceView(data)?.session, session.intent_id == intent {
                if session.status == "ready", !session.websocket_url.isEmpty { return session }
                if session.status == "failed" { throw LiveVoiceError.failed(session.error_code ?? "failed") }
            }
            let ops = try? await host.query("operations")
            if let operation = ops.flatMap({ try? JSONDecoder().decode(OperationsQuery.self, from: $0) })?.data?.items.first(where: { $0.intent_id == intent }),
               operation.state == "failed" {
                throw LiveVoiceError.failed(operation.error?.rpc_code ?? operation.error?.code ?? "failed")
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw LiveVoiceError.failed("voice_provider_unavailable")
    }
}
