import Foundation
import Security
import CryptoKit

struct AIKeychainCredentialState: Equatable {
    var apiKey: String?
    var migrationMarker: String?
}

@MainActor
protocol AIKeychainStoring {
    func loadAPIKey(for configuration: AIConnectionConfiguration, allowLegacyFallback: Bool) -> String
    func credentialState(for configuration: AIConnectionConfiguration) throws -> AIKeychainCredentialState
    /// May partially update Keychain before throwing. The settings transaction
    /// owns rollback using credentialState, including failures while saving disk state.
    func saveAPIKey(_ value: String, for configuration: AIConnectionConfiguration) throws
    func restoreCredentialState(_ state: AIKeychainCredentialState, for configuration: AIConnectionConfiguration) throws
    func hasScopedCredential(for configuration: AIConnectionConfiguration) -> Bool
}

struct SystemAIKeychainStore: AIKeychainStoring {
    func loadAPIKey(for configuration: AIConnectionConfiguration, allowLegacyFallback: Bool = false) -> String {
        KeychainStore.loadAPIKey(for: configuration, allowLegacyFallback: allowLegacyFallback)
    }

    func credentialState(for configuration: AIConnectionConfiguration) throws -> AIKeychainCredentialState {
        try KeychainStore.credentialState(for: configuration)
    }

    func saveAPIKey(_ value: String, for configuration: AIConnectionConfiguration) throws {
        try KeychainStore.saveAPIKey(value, for: configuration)
    }

    func restoreCredentialState(_ state: AIKeychainCredentialState, for configuration: AIConnectionConfiguration) throws {
        try KeychainStore.restoreCredentialState(state, for: configuration)
    }

    func hasScopedCredential(for configuration: AIConnectionConfiguration) -> Bool {
        KeychainStore.hasScopedCredential(for: configuration)
    }
}

enum KeychainStore {
    private static let service = "local.studycompanion.ai"
    private static let legacyService = "local.studycompanion.deepseek"
    private static let legacyAccount = "api-key"

    static func saveAPIKey(_ value: String, for configuration: AIConnectionConfiguration) throws {
        try set(value.isEmpty ? nil : value, account: scopedAccount(for: configuration))
        try write("migrated", service: service, account: migrationMarker(for: configuration))
    }

    static func credentialState(for configuration: AIConnectionConfiguration) throws -> AIKeychainCredentialState {
        let credentialAccount = scopedAccount(for: configuration)
        return AIKeychainCredentialState(
            apiKey: try readCredential(service: service, account: credentialAccount),
            migrationMarker: try readCredential(service: service, account: migrationMarker(for: configuration))
        )
    }

    static func restoreCredentialState(_ state: AIKeychainCredentialState, for configuration: AIConnectionConfiguration) throws {
        try set(state.apiKey, account: scopedAccount(for: configuration))
        try set(state.migrationMarker, account: migrationMarker(for: configuration))
    }

    private static func set(_ value: String?, account: String) throws {
        if let value {
            try write(value, service: service, account: account)
        } else {
            try remove(service: service, account: account)
        }
    }

    static func loadAPIKey(for configuration: AIConnectionConfiguration, allowLegacyFallback: Bool = false) -> String {
        let credentialAccount = scopedAccount(for: configuration)
        if let scopedValue = read(service: service, account: credentialAccount) { return scopedValue }
        if read(service: service, account: migrationMarker(for: configuration)) != nil { return "" }

        // The old item has no endpoint metadata. Callers may enable this fallback only when
        // loading a pre-provider local configuration; restored backups must leave it disabled.
        guard canReadLegacyCredential(for: configuration, allowLegacyFallback: allowLegacyFallback),
              let legacyValue = read(service: legacyService, account: legacyAccount),
              !legacyValue.isEmpty else { return "" }
        do {
            try write(legacyValue, service: service, account: credentialAccount)
            try write("migrated", service: service, account: migrationMarker(for: configuration))
        } catch {
            // Keep the legacy item available until a scoped copy succeeds.
        }
        return legacyValue
    }

    static func canReadLegacyCredential(for configuration: AIConnectionConfiguration, allowLegacyFallback: Bool) -> Bool {
        allowLegacyFallback && configuration.protocolKind == .openAIChatCompletions && configuration.authMode == .providerKey
    }

    static func scopedAccount(for configuration: AIConnectionConfiguration) -> String {
        let digest = SHA256.hash(data: Data(configuration.credentialScope.utf8))
        return "credential." + digest.map { String(format: "%02x", $0) }.joined()
    }

    static func hasScopedCredential(for configuration: AIConnectionConfiguration) -> Bool {
        read(service: service, account: scopedAccount(for: configuration)) != nil
    }

    private static func migrationMarker(for configuration: AIConnectionConfiguration) -> String {
        "migration." + scopedAccount(for: configuration).dropFirst("credential.".count)
    }

    private static func read(service: String, account: String) -> String? {
        try? readCredential(service: service, account: account)
    }

    private static func readCredential(service: String, account: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw KeychainError(status: status) }
        return String(decoding: data, as: UTF8.self)
    }

    private static func write(_ value: String, service: String, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [kSecValueData as String: Data(value.utf8)]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item.merge(attributes) { _, new in new }
            status = SecItemAdd(item as CFDictionary, nil)
            if status == errSecDuplicateItem {
                status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            }
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    private static func remove(service: String, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }

    struct KeychainError: LocalizedError {
        var status: OSStatus
        var errorDescription: String? { "Keychain 保存失败：\(status)" }
    }

}
