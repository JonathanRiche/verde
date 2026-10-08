import Foundation
import Security

// Compiled into both the app and the notification service extension (I-10).

protocol KeychainAPI {
    func copy(_ query: CFDictionary, _ result: UnsafeMutablePointer<CFTypeRef?>) -> OSStatus
    func update(_ query: CFDictionary, _ attributes: CFDictionary) -> OSStatus
    func add(_ query: CFDictionary) -> OSStatus
    func remove(_ query: CFDictionary) -> OSStatus
}

struct SystemKeychainAPI: KeychainAPI {
    func copy(_ query: CFDictionary, _ result: UnsafeMutablePointer<CFTypeRef?>) -> OSStatus { SecItemCopyMatching(query, result) }
    func update(_ query: CFDictionary, _ attributes: CFDictionary) -> OSStatus { SecItemUpdate(query, attributes) }
    func add(_ query: CFDictionary) -> OSStatus { SecItemAdd(query, nil) }
    func remove(_ query: CFDictionary) -> OSStatus { SecItemDelete(query) }
}

/// The per-host push key records (`vc/1/<host_id>/push`, written by the core) live in a
/// Keychain access group shared with the notification service extension, so it can decrypt
/// while the phone is locked (`AfterFirstUnlockThisDeviceOnly`). Every other record stays
/// in the app's default group. No App Group is involved.
enum SharedKeychain {
    static let service = "dev.verdeai.app.core"
    static let groupSuffix = "dev.verdeai.app.shared"
    static let infoKey = "VerdeSharedKeychainGroup"
    /// Bound on records handed to `vc_push_open` (core `MAX_KEYS`).
    static let maxRecords = 32

    /// The signed build's `<TeamID>.dev.verdeai.app.shared`; nil in unsigned simulator builds,
    /// where `$(AppIdentifierPrefix)` is empty and the entitlement isn't applied.
    static let group: String? = resolve(Bundle.main.object(forInfoDictionaryKey: infoKey) as? String)

    static func resolve(_ value: String?) -> String? {
        guard let value, value.hasSuffix("." + groupSuffix) else { return nil }
        let prefix = value.dropLast(groupSuffix.count + 1)
        guard !prefix.isEmpty, prefix.allSatisfy({ $0.isLetter || $0.isNumber }) else { return nil }
        return value
    }

    /// `vc/1/<host_id>/push`; returns the host id.
    static func pushHost(_ account: String) -> String? {
        let parts = account.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 4, parts[0] == "vc", parts[1] == "1", parts[3] == "push", !parts[2].isEmpty else { return nil }
        return String(parts[2])
    }

    /// Every stored push key record as `(host_id, raw record bytes)`, sorted by host id.
    /// Unreadable items are skipped; the caller falls back to the generic notification.
    static func pushRecords(api: KeychainAPI = SystemKeychainAPI(), group: String? = group) -> [(host: String, record: Data)] {
        var list: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service,
                                   kSecAttrSynchronizable as String: false,
                                   kSecReturnAttributes as String: true,
                                   kSecMatchLimit as String: kSecMatchLimitAll]
        if let group { list[kSecAttrAccessGroup as String] = group }
        var result: CFTypeRef?
        guard api.copy(list as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else { return [] }
        let hosts = Set(items.compactMap { ($0[kSecAttrAccount as String] as? String).flatMap(pushHost) }).sorted()
        return hosts.prefix(maxRecords).compactMap { host in
            var one: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                      kSecAttrService as String: service,
                                      kSecAttrAccount as String: "vc/1/\(host)/push",
                                      kSecAttrSynchronizable as String: false,
                                      kSecReturnData as String: true,
                                      kSecMatchLimit as String: kSecMatchLimitOne]
            if let group { one[kSecAttrAccessGroup as String] = group }
            var data: CFTypeRef?
            guard api.copy(one as CFDictionary, &data) == errSecSuccess, let bytes = data as? Data else { return nil }
            return (host, bytes)
        }
    }
}
