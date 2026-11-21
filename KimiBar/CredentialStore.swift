import Foundation
import Security

protocol KimiCredentialStoring {
    func loadCredentials() throws -> KimiCredentials?
    func saveCredentials(_ credentials: KimiCredentials) throws
    func deleteCredentials() throws
}

struct KeychainCredentialStore: KimiCredentialStoring {
    private let service: String
    private let account: String

    init(service: String = "com.github.pabla.KimiBar", account: String = "kimi-oauth") {
        self.service = service
        self.account = account
    }

    func loadCredentials() throws -> KimiCredentials? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KimiCredentialError.storageUnavailable }
        guard let data = result as? Data,
              let credentials = try? JSONDecoder().decode(KimiCredentials.self, from: data)
        else { throw KimiCredentialError.authenticationRequired }
        return credentials
    }

    func saveCredentials(_ credentials: KimiCredentials) throws {
        let data = try JSONEncoder().encode(credentials)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess { return }
        if status == errSecItemNotFound {
            var item = baseQuery
            for (key, value) in attributes { item[key] = value }
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else {
                throw KimiCredentialError.storageUnavailable
            }
            return
        }
        throw KimiCredentialError.storageUnavailable
    }

    func deleteCredentials() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KimiCredentialError.storageUnavailable
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}
