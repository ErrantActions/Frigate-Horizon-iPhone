import Foundation
import Security
import CryptoKit
import HorizonCore

enum HorizonAccountScope {
    static func key(server: String, username: String) -> String {
        SHA256.hash(data: Data((server + "\0" + username).utf8))
            .map { String(format: "%02x", $0) }.joined()
    }
}

enum SessionVault {
    private static let profileService = "FrigateHorizon.profileSessions"
    private static let key: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "FrigateHorizon.session",
        kSecAttrAccount as String: "current",
    ]

    static func read() throws -> SavedSession? {
        guard let data = try readData(key) else { return nil }
        return try JSONDecoder().decode(SavedSession.self, from: data)
    }

    private static func readData(_ key: [String: Any]) throws -> Data? {
        var query = key
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw failure(status) }
        return data
    }

    static func save(_ api: HorizonAPI) throws {
        let saved = SavedSession(
            server: api.address.url.absoluteString, cookies: api.cookies.map(SavedSession.SavedCookie.init)
        )
        try writeData(JSONEncoder().encode(saved), key: key)
    }

    private static func writeData(_ data: Data, key: [String: Any]) throws {
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
        try remove(key)
    }

    private static func remove(_ key: [String: Any]) throws {
        let status = SecItemDelete(key as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw failure(status) }
    }

    private static func profileKey(_ id: UUID, address: ServerAddress) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: profileService,
            kSecAttrAccount as String: id.uuidString + "." + HorizonAccountScope.key(
                server: address.url.absoluteString, username: ""),
        ]
    }

    static func profileSession(_ id: UUID, address: ServerAddress) throws -> ServerProfileSession? {
        guard let data = try readData(profileKey(id, address: address)) else { return nil }
        let record = try JSONDecoder().decode(ServerProfileSession.self, from: data)
        try record.requireMatch(profileID: id, address: address)
        return record
    }

    static func saveProfile(_ id: UUID, username: String?, session: SavedSession) throws {
        let address = try ServerAddress(session.server)
        let record = try ServerProfileSession(profileID: id, username: username, session: session)
        try record.requireMatch(profileID: id, address: address)
        try writeData(JSONEncoder().encode(record), key: profileKey(id, address: address))
    }

    static func clearProfileEndpoint(_ id: UUID, address: ServerAddress) throws {
        try remove(profileKey(id, address: address))
    }

    static func clearProfile(_ id: UUID) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: profileService,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return }
        guard status == errSecSuccess, let records = result as? [[String: Any]] else { throw failure(status) }
        for record in records {
            guard let account = record[kSecAttrAccount as String] as? String else {
                throw HorizonError.message("A saved profile session has unreadable Keychain attributes.")
            }
            if account.hasPrefix(id.uuidString + ".") {
                try remove([
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: profileService,
                    kSecAttrAccount as String: account,
                ])
            }
        }
    }

    static func clearAllProfiles() throws {
        try remove([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: profileService,
        ])
    }

    private static func failure(_ status: OSStatus) -> HorizonError {
        .message("The secure session store is unavailable (Keychain \(status)).")
    }
}
