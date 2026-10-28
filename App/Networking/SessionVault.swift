import Foundation
import Security
import HorizonCore

struct SavedSession: Codable {
    let server: String
    let cookies: [SavedCookie]

    struct SavedCookie: Codable {
        let name: String
        let value: String
        let domain: String
        let path: String
        let secure: Bool
        let expires: Date?

        init(_ cookie: HTTPCookie) {
            name = cookie.name
            value = cookie.value
            domain = cookie.domain
            path = cookie.path
            secure = cookie.isSecure
            expires = cookie.expiresDate
        }

        func restore(for address: ServerAddress) -> HTTPCookie? {
            let host = address.url.host?.lowercased() ?? ""
            let cookieDomain = domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            guard host == cookieDomain || host.hasSuffix("." + cookieDomain),
                  expires.map({ $0 > Date() }) ?? true else { return nil }
            var properties: [HTTPCookiePropertyKey: Any] = [
                .name: name, .value: value, .domain: domain, .path: path,
            ]
            if secure { properties[.secure] = "TRUE" }
            if let expires { properties[.expires] = expires }
            return HTTPCookie(properties: properties)
        }
    }
}

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
