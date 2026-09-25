import Foundation
import Security

protocol SecureStorage {
    func get(_ key: String) throws -> Data?
    func put(_ key: String, value: Data) throws
    func delete(_ key: String) throws
}

struct StorageError: Error { let code: PlatformFailureCode }

extension SecureStorage {
    func execute(_ effect: Effect) -> Event {
        var id = "", generation = "", key = ""
        var value: Data?
        var failure: PlatformFailure?
        var reading = false
        do {
            switch effect {
            case .secure_store_get(let e):
                (id, generation, key, reading) = (e.effect_id, e.generation, e.key, true)
                value = try get(key)
            case .secure_store_put(let e):
                (id, generation, key) = (e.effect_id, e.generation, e.key)
                guard let bytes = Data(base64Encoded: e.value_base64) else { throw StorageError(code: .io) }
                try put(key, value: bytes)
            case .secure_store_delete(let e):
                (id, generation, key) = (e.effect_id, e.generation, e.key)
                try delete(key)
            default: preconditionFailure("storage_effect_required")
            }
        } catch { failure = PlatformFailure(code: (error as? StorageError)?.code ?? .io) }
        if reading {
            return .secure_store_value(EventSecureStoreValue(now_ms: 0, wall_time_ms: 0,
                effect_id: id, generation: generation, key: key, value_base64: value?.base64EncodedString(), error: failure))
        }
        return .secure_store_done(EventSecureStoreDone(now_ms: 0, wall_time_ms: 0,
            effect_id: id, generation: generation, key: key, error: failure))
    }
}

struct KeychainStorage: SecureStorage {
    var service = "dev.verdeai.app.core"

    func query(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: key,
         kSecAttrSynchronizable as String: false]
    }
    func get(_ key: String) throws -> Data? {
        var request = query(key)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try check(status)
        guard let value = result as? Data else { throw StorageError(code: .io) }
        return value
    }
    func put(_ key: String, value: Data) throws {
        let attributes: [String: Any] = [kSecValueData as String: value,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(query(key) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            try check(SecItemAdd(query(key).merging(attributes) { _, new in new } as CFDictionary, nil))
        } else { try check(status) }
    }
    func delete(_ key: String) throws {
        let status = SecItemDelete(query(key) as CFDictionary)
        if status != errSecItemNotFound { try check(status) }
    }
    private func check(_ status: OSStatus) throws {
        guard status != errSecSuccess else { return }
        switch status {
        case errSecInteractionNotAllowed: throw StorageError(code: .locked)
        case errSecAuthFailed, errSecMissingEntitlement: throw StorageError(code: .denied)
        case errSecNotAvailable: throw StorageError(code: .unavailable)
        case errSecAllocate: throw StorageError(code: .resource)
        default: throw StorageError(code: .io)
        }
    }
}
