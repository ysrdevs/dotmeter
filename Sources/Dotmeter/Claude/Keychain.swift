import Foundation
import Security

struct KeychainError: LocalizedError {
    let status: OSStatus
    var errorDescription: String? {
        (SecCopyErrorMessageString(status, nil) as String?) ?? "Keychain error \(status)"
    }
}

/// One key per provider, each under its own account name. The key never leaves the Keychain except in the
/// request that uses it.
enum Keychain {
    static let service = App.bundleID

    /// `service` is this app's identifier, or the one it had under its earlier name (see `Migration`).
    private static func base(_ account: String, service: String = Keychain.service) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    /// Whether a key is stored. Asks for attributes only, so macOS never needs to prompt for access.
    static func exists(_ account: String, service: String = Keychain.service) -> Bool {
        var query = base(account, service: service)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess
    }

    static func read(_ account: String, service: String = Keychain.service) -> String? {
        var query = base(account, service: service)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ value: String, account: String, label: String) throws {
        let data = Data(value.utf8)
        let status = SecItemUpdate(base(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = base(account)
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = label
            let added = SecItemAdd(add as CFDictionary, nil)
            guard added == errSecSuccess else { throw KeychainError(status: added) }
        } else if status != errSecSuccess {
            throw KeychainError(status: status)
        }
    }

    static func delete(_ account: String, service: String = Keychain.service) {
        SecItemDelete(base(account, service: service) as CFDictionary)
    }
}
