import Foundation
import Security
import HorizonCore

enum SessionVault {
    private static let key: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "FrigateHorizon.session",
        kSecAttrAccount as String: "current",
    ]

    static func read() throws -> SavedSession? {
        var query = key
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw failure(status) }
        return try JSONDecoder().decode(SavedSession.self, from: data)
    }

    static func save(_ api: HorizonAPI) throws {
        let saved = SavedSession(
            server: api.address.url.absoluteString, cookies: api.cookies.map(SavedSession.SavedCookie.init)
        )
        let data = try JSONEncoder().encode(saved)
        let status = SecItemUpdate(key as CFDictionary, [
            kSecValueData as String: data,
        ] as CFDictionary)
        if status == errSecItemNotFound {
            var attributes = key
            attributes[kSecValueData as String] = data
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let result = SecItemAdd(attributes as CFDictionary, nil)
            guard result == errSecSuccess else { throw failure(result) }
        } else if status != errSecSuccess {
            throw failure(status)
        }
    }

    static func clear() throws {
        let status = SecItemDelete(key as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw failure(status) }
    }

    private static func failure(_ status: OSStatus) -> HorizonError {
        .message("The secure session store is unavailable (Keychain \(status)).")
    }
}
