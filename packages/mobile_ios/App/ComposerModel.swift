import Foundation
import Observation

struct ComposerToken: Equatable {
    let range: NSRange
    let query: String
    let marker: String
}

/// UTF-16 ranges match UITextView selection, including text containing emoji.
func composerToken(_ text: String, caret: Int) -> ComposerToken? {
    let value = text as NSString
    guard caret >= 0, caret <= value.length else { return nil }
    let prefix = value.substring(to: caret) as NSString
    var start = prefix.length
    while start > 0, let scalar = UnicodeScalar(prefix.character(at: start - 1)), !CharacterSet.whitespacesAndNewlines.contains(scalar) { start -= 1 }
    let word = prefix.substring(from: start)
    guard let marker = word.first, marker == "@" || (marker == "/" && start == 0) else { return nil }
    return ComposerToken(range: NSRange(location: start, length: caret - start), query: String(word.dropFirst()), marker: String(marker))
}

func composerFollowupKind(provider: String?, images: Bool) -> EventFollowupSubmitKind {
    !images && ["codex", "claude", "pi"].contains(provider ?? "") ? .steer : .queue
}

enum ComposerPicker: String, CaseIterable, Identifiable {
    case provider, model, effort, access, speed
    var id: String { rawValue }
}

/// The core owns persisted drafts and submission state. One ordered lane prevents a late
/// debounce from overwriting a newer draft or overtaking a send.
@MainActor @Observable
final class ComposerModel {
    static let maxImageBytes = 160 * 1024
    static let maxTotalBytes = 320 * 1024
    static let maxImages = 4
    let chat: TranscriptModel
    private(set) var text = ""
    private(set) var selection = NSRange(location: 0, length: 0)
    private(set) var busy = false
    var notice: String?
    private(set) var view: ChatComposerView?
    private(set) var previews: [String: Data] = [:]
    private var generation = 0
    private var savedGeneration = 0
    private var adopted = false
    private var debounce: Task<Void, Never>?
    private var search: Task<Void, Never>?
    private var lane: Task<Void, Never>?
    private var slashRequested = false

    init(chat: TranscriptModel) { self.chat = chat }
    var token: ComposerToken? { composerToken(text, caret: selection.location) }
    var pending: Bool { view?.send_operation?.state == "pending" }
    var canSubmit: Bool {
        guard let view, !busy, !pending, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !view.draft.attachments.isEmpty else { return false }
        if text.hasPrefix("/") && !text.hasPrefix("//") { return view.provider_ready }
        if chat.state.turn != nil { return view.provider_ready && (view.followup == nil || text.hasPrefix("!")) }
        return view.can_send
    }

    func adopt(_ next: ChatComposerView?) {
        guard let next else { return }
        view = next
        previews = previews.filter { key, _ in next.draft.attachments.contains { $0.local_id == key } }
        if !busy && (generation == savedGeneration || (!adopted && generation == 0)) {
            adopted = true
            if text != next.draft.text { text = next.draft.text; selection = NSRange(location: (text as NSString).length, length: 0) }
        }
    }

    func edit(_ value: String, selection: NSRange) {
        guard !pending else { return }
        self.selection = selection
        if text != value {
            text = value
            generation += 1
            notice = nil
            debounce?.cancel()
            debounce = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(600))
                guard !Task.isCancelled else { return }
                self?.flushNow()
            }
        }
        search?.cancel()
        guard let token else { return }
        search = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard let self, !Task.isCancelled else { return }
            if token.marker == "@" {
                _ = await self.dispatch { id in .mention_search(EventMentionSearch(now_ms: 0, wall_time_ms: 0, intent_id: id, workspace_id: self.chat.workspaceID, thread_id: self.chat.threadID, query: token.query)) }
            } else { await self.loadSlash() }
        }
    }

    func accept(_ value: String) {
        guard let token else { return }
        let replacement = token.marker + value.trimmingCharacters(in: CharacterSet(charactersIn: token.marker)) + " "
        let next = (text as NSString).replacingCharacters(in: token.range, with: replacement)
        edit(next, selection: NSRange(location: token.range.location + (replacement as NSString).length, length: 0))
    }

    private func enqueue(_ action: @escaping () async -> Void) {
        let previous = lane
        lane = Task { await previous?.value; await action() }
    }

    func flushNow() {
        debounce?.cancel()
        enqueue { [self] in _ = await flush() }
    }

    private func refresh() async {
        guard let host = chat.host, let data = try? await host.query(chat.composerSelector), let next = try? JSONDecoder().decode(ComposerQuery.self, from: data).data else { return }
        adopt(next)
    }

    private func references() -> [AttachmentInput] {
        (view?.draft.attachments ?? []).map { AttachmentInput(local_id: $0.local_id, name: $0.name, mime: $0.mime, byte_size: $0.byte_size, bytes_base64: "") }
    }

    private func setDraft(_ value: String, _ attachments: [AttachmentInput]) async -> Bool {
        await dispatch { id in .draft_set(EventDraftSet(now_ms: 0, wall_time_ms: 0, intent_id: id, workspace_id: self.chat.workspaceID, thread_id: self.chat.threadID, text: value, attachments: attachments)) } != nil
    }

    private func flush() async -> Bool {
        guard generation != savedGeneration else { return true }
        let revision = generation
        let value = text
        guard await setDraft(value, references()) else { return false }
        savedGeneration = revision
        return true
    }

    /// Receipts are read directly from the actor; UI publications may still be queued.
    private func dispatch(_ event: (String) -> Event, wait: Bool = false) async -> Operation? {
        guard let host = chat.host else { notice = "The host is unavailable. Your draft is kept."; return nil }
        let id = UUID().uuidString
        do {
            try await host.send(event(id))
            let deadline = ContinuousClock.now.advanced(by: .seconds(30))
            repeat {
                let bytes = try await host.query("operations")
                let op = try JSONDecoder().decode(OperationsQuery.self, from: bytes).data?.items.first { $0.intent_id == id }
                if let op, op.state != "pending" || !wait || ContinuousClock.now >= deadline {
                    await refresh()
                    if op.state == "failed" { notice = op.error?.message ?? "The action failed. Your draft is kept."; return nil }
                    return op
                }
                if !wait || ContinuousClock.now >= deadline { break }
                try await Task.sleep(for: .milliseconds(50))
            } while !Task.isCancelled
            notice = "The action's result is not yet known. Check the chat before retrying."
        } catch { notice = "The action could not be submitted. Your draft is kept." }
        return nil
    }

    private func action(_ body: @escaping () async -> Void) {
        guard !busy else { return }
        busy = true
        notice = nil
        debounce?.cancel()
        enqueue { [self] in
            await body()
            busy = false
            await refresh()
        }
    }

    func submit() {
        guard canSubmit else { return }
        action { [self] in
            guard await flush(), let view else { return }
            let original = view.draft.text
            if original.hasPrefix("/") && !original.hasPrefix("//") {
                await loadSlash()
                let parts = original.split(maxSplits: 1, whereSeparator: \.isWhitespace)
                let name = String(parts.first ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                guard let command = self.view?.catalogs.slash.first(where: { $0.label.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == name }), command.enabled else { notice = "That command isn't available for this provider."; return }
                if let op = await dispatch({ id in .slash_run(EventSlashRun(now_ms: 0, wall_time_ms: 0, intent_id: id, workspace_id: chat.workspaceID, thread_id: chat.threadID, command: command.id, args: parts.count > 1 ? String(parts[1]) : "")) }, wait: true), op.state != "pending", text == original, generation == savedGeneration {
                    _ = await setDraft("", references())
                }
                return
            }
            if original.hasPrefix("//") { guard await setDraft(String(original.dropFirst()), references()) else { return } }
            guard let current = self.view else { return }
            if chat.state.turn != nil && !(original.hasPrefix("!") && !original.hasPrefix("!!")) {
                _ = await dispatch { id in .followup_submit(EventFollowupSubmit(now_ms: 0, wall_time_ms: 0, intent_id: id, workspace_id: chat.workspaceID, thread_id: chat.threadID, draft_revision: current.draft.revision, kind: composerFollowupKind(provider: current.selection.provider, images: !current.draft.attachments.isEmpty))) }
            } else {
                _ = await dispatch { id in .send(EventSend(now_ms: 0, wall_time_ms: 0, intent_id: id, workspace_id: chat.workspaceID, thread_id: chat.threadID, draft_revision: current.draft.revision)) }
            }
        }
    }

    private func loadSlash() async {
        guard !slashRequested else { return }
        slashRequested = true
        if await dispatch({ id in .slash_search(EventSlashSearch(now_ms: 0, wall_time_ms: 0, intent_id: id, workspace_id: chat.workspaceID, thread_id: chat.threadID, query: "")) }, wait: true) == nil { slashRequested = false }
    }

    func select(_ picker: ComposerPicker, _ value: String) {
        action { [self] in
            guard var next = view?.selection else { return }
            switch picker {
            case .provider: next = ChatSelection(provider: value, access: next.access)
            case .model: next.model = value; next.effort = nil; next.speed = nil
            case .effort: next.effort = value
            case .access: next.access = value
            case .speed: next.speed = value
            }
            _ = await dispatch { id in .composer_select(EventComposerSelect(now_ms: 0, wall_time_ms: 0, intent_id: id, workspace_id: chat.workspaceID, thread_id: chat.threadID, provider: next.provider, model: next.model, effort: next.effort, access: next.access, speed: next.speed)) }
            slashRequested = false
        }
    }

    func confirmShell(_ confirmation: ChatShellConfirmation, accept: Bool) {
        action { [self] in
            let original = text
            if let op = await dispatch({ id in .shell_confirm(EventShellConfirm(now_ms: 0, wall_time_ms: 0, intent_id: id, confirmation_id: confirmation.id, accept: accept)) }), op.state != "failed", accept, original == text, generation == savedGeneration {
                _ = await setDraft("", references())
            }
        }
    }

    func attach(_ bytes: Data) {
        action { [self] in
            guard await flush() else { return }
            let existing = references()
            guard existing.count < Self.maxImages else { notice = "Up to four images per message."; return }
            guard bytes.count <= Self.maxImageBytes, existing.reduce(bytes.count, { $0 + (Int($1.byte_size) ?? 0) }) <= Self.maxTotalBytes else { notice = "These images are too large together. Send some first."; return }
            let id = "img-" + UUID().uuidString
            if await setDraft(text, existing + [AttachmentInput(local_id: id, name: "Photo.jpg", mime: "image/jpeg", byte_size: String(bytes.count), bytes_base64: bytes.base64EncodedString())]) { previews[id] = bytes }
        }
    }

    func detach(_ id: String) { action { [self] in if await flush() { _ = await setDraft(text, references().filter { $0.local_id != id }) } } }

    func followup(_ verb: String, _ followup: ChatFollowup) {
        action { [self] in
            guard await flush() else { return }
            _ = await dispatch { id in
                switch verb {
                case "retry": return .followup_retry(EventFollowupRetry(now_ms: 0, wall_time_ms: 0, intent_id: id, workspace_id: chat.workspaceID, thread_id: chat.threadID, followup_id: followup.id))
                case "pull": return .followup_pull_back(EventFollowupPullBack(now_ms: 0, wall_time_ms: 0, intent_id: id, workspace_id: chat.workspaceID, thread_id: chat.threadID, followup_id: followup.id))
                default: return .followup_cancel(EventFollowupCancel(now_ms: 0, wall_time_ms: 0, intent_id: id, workspace_id: chat.workspaceID, thread_id: chat.threadID, followup_id: followup.id))
                }
            }
        }
    }
}
