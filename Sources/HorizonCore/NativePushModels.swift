import Foundation

public struct NativePushCapabilities: Decodable, Sendable {
    public let enabled: Bool
    public let serverID: String?
    public let topic: String?
    enum CodingKeys: String, CodingKey {
        case enabled, topic
        case serverID = "server_id"
    }
}

public struct NativePushRegistrationBody: Encodable, Sendable {
    public let installationID: String
    public let token: String
    public let environment: String
    public let cameraIDs: [String]?
    enum CodingKeys: String, CodingKey {
        case token, environment
        case installationID = "installation_id"
        case cameraIDs = "camera_ids"
    }

    public init(installationID: String, token: String, environment: String, cameraIDs: [String]?) throws {
        guard let identifier = UUID(uuidString: installationID),
              token.count % 2 == 0,
              token.range(of: "\\A[0-9a-fA-F]{2,512}\\z", options: .regularExpression) != nil,
              ["production", "sandbox"].contains(environment) else {
            throw HorizonError.message("Native push device registration is invalid.")
        }
        self.installationID = identifier.uuidString.lowercased()
        self.token = token.lowercased()
        self.environment = environment
        self.cameraIDs = cameraIDs.map { Array(Set($0)).sorted() }
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

public enum NativePushKind: String, Hashable, Sendable {
    case review, event, camera, test
}

public struct NativeNotificationRoute: Identifiable, Hashable, Sendable {
    public let id = UUID()
    public let serverID: String
    public let kind: NativePushKind
    public let identifier: String?

    public init?(userInfo: [AnyHashable: Any]) {
        guard let serverID = userInfo["server_id"] as? String,
              serverID.range(of: "\\A[A-Za-z0-9._-]{1,64}\\z", options: .regularExpression) != nil,
              let value = userInfo["kind"] as? String,
              let kind = NativePushKind(rawValue: value) else { return nil }
        let identifier = userInfo["identifier"] as? String
        if kind != .test {
            guard let identifier, !identifier.isEmpty, identifier.count <= 256,
                  identifier != ".", identifier != "..",
                  !identifier.contains("/"), !identifier.contains("\\"),
                  !identifier.contains("%"), !identifier.contains(":"),
                  identifier.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
        }
        self.serverID = serverID
        self.kind = kind
        self.identifier = identifier
    }
}
