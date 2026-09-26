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

struct KeychainStorage: SecureStorage {
    var service = "dev.verdeai.app.core"
    var api: KeychainAPI = SystemKeychainAPI()

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
        let status = api.copy(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try check(status)
        guard let value = result as? Data else { throw StorageError(code: .io) }
        return value
    }
    func put(_ key: String, value: Data) throws {
        let attributes: [String: Any] = [kSecValueData as String: value,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = api.update(query(key) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            try check(api.add(query(key).merging(attributes) { _, new in new } as CFDictionary))
        } else { try check(status) }
    }
    func delete(_ key: String) throws {
        let status = api.remove(query(key) as CFDictionary)
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

/// Confines one host handle to its own `vc/1/<host_id>/` records, so a core can
/// never read or erase another host's credential, pin or caches.
struct HostScopedStorage: SecureStorage {
    let base: SecureStorage
    let prefix: String
    init(base: SecureStorage, hostID: String) { self.base = base; prefix = "vc/1/\(hostID)/" }
    private func check(_ key: String) throws {
        guard key.hasPrefix(prefix), key.utf8.count <= 4096 else { throw StorageError(code: .denied) }
    }
    func get(_ key: String) throws -> Data? { try check(key); return try base.get(key) }
    func put(_ key: String, value: Data) throws { try check(key); try base.put(key, value: value) }
    func delete(_ key: String) throws { try check(key); try base.delete(key) }
}
