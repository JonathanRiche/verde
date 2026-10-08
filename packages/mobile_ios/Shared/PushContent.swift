import Foundation
import UserNotifications
import VerdeClient

// Shared by the app and the notification service extension (I-10). The extension decrypts the
// relay's `ciphertext` with the core's pure `vc_push_open` and replaces the placeholder alert.
// Envelopes, key records and decrypted content are never logged.

/// `vc_push_open` request. `record_base64` is the unmodified `vc/1/<host_id>/push` value.
struct PushOpenInput: Encodable {
    struct Key: Encodable {
        var host_id: String
        var record_base64: String
    }
    var api_version: UInt32 = 1
    var envelope: String
    var keys: [Key]
    var recent: [String]? = nil
}

/// The fields of the core's `PushNotification` model the platform needs.
struct PushModel: Decodable, Equatable {
    var opened: Bool
    var update_required: Bool
    var error: String?
    var host_id: String?
    var workspace_id: String?
    var thread_id: String?
    var turn_id: String?
    var kind: String
    var channel: String
    var title: String
    var body: String
    var deep_link: String
    var actions: [String]
    var dedupe_key: String?
}

enum PushDecrypt {
    /// Decrypt and payload failures return the core's generic model; only a malformed
    /// request (or core failure) throws.
    static func open(_ input: PushOpenInput) throws -> PushModel {
        let request = try JSONEncoder().encode(input)
        var output = vc_buf(ptr: nil, len: 0)
        defer { vc_buf_free(output) }
        let status = request.withUnsafeBytes { bytes in
            vc_push_open(bytes.bindMemory(to: UInt8.self).baseAddress, request.count, &output)
        }
        guard status == 0, let pointer = output.ptr else { throw PushDecryptError.status(status) }
        return try JSONDecoder().decode(PushModel.self, from: Data(bytes: pointer, count: output.len))
    }
}

enum PushDecryptError: Error { case status(Int32) }

/// Notification categories and actions (registered by the app, chosen by the extension).
enum PushCategory {
    static let approval = "verde.approval"
    static let reply = "verde.reply"
    static let open = "verde.open"
    static let approveAction = "verde.approve"
    static let denyAction = "verde.deny"
    static let replyAction = "verde.reply"

    /// The core lists the allowed actions; approvals win over reply.
    static func identifier(for actions: [String]) -> String {
        if actions.contains("approve") && actions.contains("deny") { return approval }
        if actions.contains("reply") { return reply }
        return open
    }
}

/// Keys of the routing dictionary the extension stores under `userInfo["verde"]`.
enum PushUserInfo {
    static let root = "verde"
    static let ciphertext = "ciphertext"
    static let host = "host_id"
    static let workspace = "workspace_id"
    static let thread = "thread_id"
    static let turn = "turn_id"
    static let kind = "kind"
    static let deepLink = "deep_link"
    static let dedupe = "dedupe_key"
}

enum PushContentBuilder {
    /// The opened model for this push, or nil when there is nothing to decrypt or decryption
    /// failed (the caller then keeps the relay's placeholder alert exactly as delivered).
    static func model(userInfo: [AnyHashable: Any], records: [(host: String, record: Data)]) -> PushModel? {
        guard let envelope = userInfo[PushUserInfo.ciphertext] as? String, !envelope.isEmpty, !records.isEmpty else { return nil }
        let keys = records.map { PushOpenInput.Key(host_id: $0.host, record_base64: $0.record.base64EncodedString()) }
        guard let model = try? PushDecrypt.open(PushOpenInput(envelope: envelope, keys: keys)), model.opened,
              model.host_id != nil else { return nil }
        return model
    }

    /// Replaces the placeholder with the decrypted title, body, category and routing data.
    static func apply(_ model: PushModel, to content: UNMutableNotificationContent) {
        content.title = model.title
        content.body = model.body
        content.sound = .default
        content.categoryIdentifier = PushCategory.identifier(for: model.actions)
        var info = content.userInfo
        info.removeValue(forKey: PushUserInfo.ciphertext)
        var route: [String: String] = [PushUserInfo.kind: model.kind, PushUserInfo.deepLink: model.deep_link]
        route[PushUserInfo.host] = model.host_id
        route[PushUserInfo.workspace] = model.workspace_id
        route[PushUserInfo.thread] = model.thread_id
        route[PushUserInfo.turn] = model.turn_id
        route[PushUserInfo.dedupe] = model.dedupe_key
        info[PushUserInfo.root] = route
        content.userInfo = info
        if let host = model.host_id, let workspace = model.workspace_id, let thread = model.thread_id {
            content.threadIdentifier = [host, workspace, thread].joined(separator: "/")
        }
    }

    /// The extension's whole job: decrypted content, or the original placeholder unchanged.
    static func content(for original: UNNotificationContent, records: () -> [(host: String, record: Data)]) -> UNNotificationContent {
        guard original.userInfo[PushUserInfo.ciphertext] is String,
              let model = model(userInfo: original.userInfo, records: records()),
              let content = original.mutableCopy() as? UNMutableNotificationContent else { return original }
        apply(model, to: content)
        return content
    }
}
