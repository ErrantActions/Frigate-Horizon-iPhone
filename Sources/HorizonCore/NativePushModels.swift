import Foundation

public struct NativePushCapabilities: Decodable, Sendable {
    public let enabled: Bool
    public let serverID: String?
    public let topic: String?
    public let imageNotifications: Bool?
    public let devicePreferences: Bool?
    public let actionNotifications: Bool?
    public let healthNotifications: Bool?
    public let supportsDeviceFeatures: Bool?
    enum CodingKeys: String, CodingKey {
        case enabled, topic
        case serverID = "server_id"
        case imageNotifications = "image_notifications"
        case devicePreferences = "device_preferences"
        case actionNotifications = "action_notifications"
        case healthNotifications = "health_notifications"
        case supportsDeviceFeatures = "supports_device_features"
    }
}

public struct NativePushRegistrationBody: Encodable, Sendable {
    public let installationID: String
    public let token: String
    public let environment: String
    public let cameraIDs: [String]?
    public let features: [String]?
    enum CodingKeys: String, CodingKey {
        case token, environment, features
        case installationID = "installation_id"
        case cameraIDs = "camera_ids"
    }

    public init(installationID: String, token: String, environment: String, cameraIDs: [String]?,
                features: [String]? = nil) throws {
        guard let identifier = UUID(uuidString: installationID),
              token.count % 2 == 0,
              token.range(of: "\\A[0-9a-fA-F]{2,512}\\z", options: .regularExpression) != nil,
              ["production", "sandbox"].contains(environment),
              features?.allSatisfy({ ["actions-v1", "health-v1"].contains($0) }) != false else {
            throw HorizonError.message("Native push device registration is invalid.")
        }
        self.installationID = identifier.uuidString.lowercased()
        self.token = token.lowercased()
        self.environment = environment
        self.cameraIDs = cameraIDs.map { Array(Set($0)).sorted() }
        self.features = features.map { Array(Set($0)).sorted() }
    }
}

public struct NativePushRegistrationResult: Decodable, Sendable {
    public let success: Bool
    public let message: String
    public let serverID: String
    enum CodingKeys: String, CodingKey {
        case success, message
        case serverID = "server_id"
    }
}

public enum NativePushKind: String, Codable, Hashable, Sendable {
    case review, event, camera, test, health
}

public struct NativeNotificationResolution: Decodable, Sendable {
    public let serverID: String
    public let kind: NativePushKind
    public let identifier: String
    public let camera: String
    public let timestamp: Double?
    enum CodingKeys: String, CodingKey {
        case serverID = "server_id"
        case kind, identifier, camera, timestamp
    }

    public func requireMatch(_ route: NativeNotificationRoute, allowedCameras: Set<String>) throws {
        guard [.event, .review, .camera].contains(kind), serverID == route.serverID,
              kind == route.kind, identifier == route.identifier,
              NativeNotificationRoute.isValidIdentifier(camera), allowedCameras.contains(camera),
              kind != .camera || camera == identifier,
              timestamp.map({ $0.isFinite && $0 >= 0 }) != false,
              kind == .camera || timestamp != nil else {
            throw HorizonError.message("The notification reference changed or is no longer authorized.")
        }
    }
}

public enum NativeNotificationIntent: String, Sendable, Hashable {
    case open, live, review, snooze, health

    public init?(actionIdentifier: String?) {
        switch actionIdentifier {
        case nil, "com.apple.UNNotificationDefaultActionIdentifier": self = .open
        case "HORIZON_LIVE": self = .live
        case "HORIZON_REVIEW": self = .review
        case "HORIZON_SNOOZE_15M": self = .snooze
        case "HORIZON_HEALTH": self = .health
        default: return nil
        }
    }
}

public struct NativeNotificationRoute: Identifiable, Hashable, Sendable {
    public let id = UUID()
    public let serverID: String
    public let kind: NativePushKind
    public let identifier: String?
    public let intent: NativeNotificationIntent
    public let receivedAt: Date
    public let registrationAccount: String?

    public init?(userInfo: [AnyHashable: Any], actionIdentifier: String? = nil, receivedAt: Date = Date(),
                 registrationAccount: String? = nil) {
        guard let serverID = userInfo["server_id"] as? String,
              serverID.range(of: "\\A[A-Za-z0-9._-]{1,64}\\z", options: .regularExpression) != nil,
              let value = userInfo["kind"] as? String,
              let kind = NativePushKind(rawValue: value),
              let intent = NativeNotificationIntent(actionIdentifier: actionIdentifier) else { return nil }
        let identifier = userInfo["identifier"] as? String
        if kind != .test {
            guard let identifier, Self.isValidIdentifier(identifier) else { return nil }
        }
        guard kind != .health || [.open, .health].contains(intent),
              kind != .test || intent == .open,
              intent != .health || kind == .health else { return nil }
        self.serverID = serverID
        self.kind = kind
        self.identifier = identifier
        self.intent = intent
        self.receivedAt = receivedAt
        self.registrationAccount = registrationAccount
    }

    public static func isValidIdentifier(_ identifier: String) -> Bool {
        !identifier.isEmpty && identifier.count <= 256
            && identifier != "." && identifier != ".."
            && !identifier.contains("/") && !identifier.contains("\\")
            && !identifier.contains("%") && !identifier.contains(":")
            && identifier.rangeOfCharacter(from: .controlCharacters) == nil
    }
}
