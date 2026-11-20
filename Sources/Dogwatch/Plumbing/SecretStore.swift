import Foundation
import Security

/// Pasted keys and cookies. One item per provider. The values never leave this type except as
/// the return of `read`, which providers pass straight into a request header.
protocol SecretStore: AnyObject {
    func read(_ provider: ProviderID) -> String?
    func write(_ value: String, for provider: ProviderID) throws
    func delete(_ provider: ProviderID) throws
}

enum SecretStoreError: LocalizedError {
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .keychain(let status):
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "error \(status)"
            return "The Keychain refused: \(message)"
        }
    }
}

/// The login Keychain, as generic passwords under Dogwatch's own service, with the provider id
/// as the account. Items are never synced and never readable by other apps without a prompt.
final class KeychainSecretStore: SecretStore {
    static let service = "Dogwatch provider keys"

    let service: String

    init(service: String = KeychainSecretStore.service) {
        self.service = service
    }

    private func query(_ provider: ProviderID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider.rawValue,
        ]
    }

    func read(_ provider: ProviderID) -> String? {
        var query = query(provider)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func write(_ value: String, for provider: ProviderID) throws {
        let data = Data(value.utf8)
        let status = SecItemUpdate(query(provider) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var attributes = query(provider)
            attributes[kSecValueData as String] = data
            attributes[kSecAttrLabel as String] = "Dogwatch: \(provider.title)"
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            let added = SecItemAdd(attributes as CFDictionary, nil)
            guard added == errSecSuccess else { throw SecretStoreError.keychain(added) }
        } else if status != errSecSuccess {
            throw SecretStoreError.keychain(status)
        }
    }

    func delete(_ provider: ProviderID) throws {
        let status = SecItemDelete(query(provider) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw SecretStoreError.keychain(status) }
    }
}

/// For tests and previews.
final class InMemorySecretStore: SecretStore {
    private var values: [ProviderID: String]

    init(_ values: [ProviderID: String] = [:]) { self.values = values }

    func read(_ provider: ProviderID) -> String? { values[provider] }
    func write(_ value: String, for provider: ProviderID) throws { values[provider] = value }
    func delete(_ provider: ProviderID) throws { values[provider] = nil }
}
