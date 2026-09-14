// Keychain — generic-password wrapper (service "Kura", accounts "anthropic"/"openai").
import Foundation
import Security
import LocalAuthentication

enum Keychain {
    private static let previewLock = NSLock()
    nonisolated(unsafe) private static var previewValues: [String: String] = [:]
    private static var service: String { Config.preview ? "KuraPreview" : "Kura" }

    @discardableResult static func set(_ value: String, account: String) -> Bool {
        if Config.preview { previewLock.withLock { previewValues[account] = value }; return true }
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add.merge(attributes) { _, new in new }
            return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
        }
        return status == errSecSuccess
    }

    static func get(account: String, allowInteraction: Bool = false) -> String? {
        if Config.preview { return previewLock.withLock { previewValues[account] } }
        return value(account: account, service: service, allowInteraction: allowInteraction)
    }

    private static func value(account: String, service: String, allowInteraction: Bool) -> String? {
        let context = LAContext()
        context.interactionNotAllowed = !allowInteraction
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: context,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult static func delete(account: String) -> Bool {
        if Config.preview { _ = previewLock.withLock { previewValues.removeValue(forKey: account) }; return true }
        return delete(account: account, service: service)
    }

    private static func delete(account: String, service: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
