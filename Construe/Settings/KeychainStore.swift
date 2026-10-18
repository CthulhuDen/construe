import Foundation
import Security

struct KeychainError: LocalizedError {
    let status: OSStatus

    var errorDescription: String? {
        SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status)"
    }
}

/// Stores a single string as a generic password in the data protection keychain.
///
/// Access is governed by the app's `keychain-access-groups` entitlement rather than per-item ACLs,
/// so there are no access prompts and other apps can't be granted access.
struct KeychainStore {
    let service: String
    let account: String

    /// Where the Anthropic API key lives.
    static let apiKey = KeychainStore(
        service: Bundle.main.bundleIdentifier ?? "Construe",
        account: "anthropic-api-key"
    )

    func read() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func save(_ value: String) throws {
        let data = Data(value.utf8)
        let status = SecItemUpdate(baseQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = baseQuery
            item[kSecValueData as String] = data
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError(status: addStatus) }
        } else if status != errSecSuccess {
            throw KeychainError(status: status)
        }
    }

    func delete() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status)
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }
}
