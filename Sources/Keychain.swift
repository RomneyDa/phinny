import Foundation
import Security

/// Secure storage for the SimpleFIN access URL, which embeds read-only bank
/// credentials. It is kept in the macOS Keychain - never written to disk in
/// plaintext (config.yaml holds only non-sensitive settings).
///
/// Backed by a generic-password item scoped to this app. `kSecAttrAccessible`
/// is set to "after first unlock" so a background launch can read it, but it
/// never syncs to iCloud and never leaves the device.
enum Keychain {
    private static let service = "com.dallinromney.phinny"
    private static let account = "simplefin-access-url"

    /// Read the stored access URL, or nil if none is saved.
    static func accessURL() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty
        else { return nil }
        return value
    }

    /// Store (or replace) the access URL.
    @discardableResult
    static func setAccessURL(_ value: String) -> Bool {
        let data = Data(value.utf8)
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        // Update in place if it already exists, otherwise add.
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let updateStatus = SecItemUpdate(base as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return true }
        if updateStatus == errSecItemNotFound {
            let addStatus = SecItemAdd(base.merging(attributes) { _, new in new } as CFDictionary, nil)
            return addStatus == errSecSuccess
        }
        return false
    }

    /// Remove the stored access URL (used by "Disconnect").
    @discardableResult
    static func deleteAccessURL() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    static var hasAccessURL: Bool { accessURL() != nil }
}
