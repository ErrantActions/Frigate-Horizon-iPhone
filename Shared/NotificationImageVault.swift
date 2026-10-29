import Foundation
import Security
import HorizonCore

enum NotificationImageVault {
    private static func query() throws -> [String: Any] {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "HorizonNotificationKeychainGroup") as? String,
              !group.isEmpty, !group.contains("$(") else {
            throw HorizonError.message("This build does not have configured notification-image storage.")
        }
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "FrigateHorizon.notificationImages",
            kSecAttrAccount as String: "current",
            kSecAttrAccessGroup as String: group,
            kSecAttrSynchronizable as String: false,
        ]
    }

    static func read() throws -> NotificationImageSession? {
        var attributes = try query()
        attributes[kSecReturnData as String] = true
        attributes[kSecMatchLimit as String] = kSecMatchLimitOne
        attributes[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        var result: CFTypeRef?
        let status = SecItemCopyMatching(attributes as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw failure(status) }
        return try JSONDecoder().decode(NotificationImageSession.self, from: data)
    }

    static func save(_ session: NotificationImageSession) throws {
        let attributes = try query()
        let data = try JSONEncoder().encode(session)
        let status = SecItemUpdate(attributes as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var addition = attributes
            addition[kSecValueData as String] = data
            addition[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let result = SecItemAdd(addition as CFDictionary, nil)
            guard result == errSecSuccess else { throw failure(result) }
        } else if status != errSecSuccess { throw failure(status) }
    }

    static func clear() throws {
        let status = SecItemDelete(try query() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw failure(status) }
    }

    private static func failure(_ status: OSStatus) -> HorizonError {
        .message("Secure notification-image storage is unavailable (Keychain \(status)).")
    }
}
