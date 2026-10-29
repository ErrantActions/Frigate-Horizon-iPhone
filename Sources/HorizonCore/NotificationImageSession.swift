import Foundation

public struct NotificationImageSession: Codable, Equatable, Sendable {
    public let generation: UUID
    public let installationID: String
    public let serverID: String
    public let topic: String
    public let username: String
    public let allowedCameraIDs: [String]
    public let session: SavedSession
    public let imagesEnabled: Bool

    public init(installationID: String, serverID: String, topic: String, username: String,
                allowedCameraIDs: [String], session: SavedSession) throws {
        guard let installation = UUID(uuidString: installationID),
              serverID.range(of: "\\A[A-Za-z0-9._-]{1,64}\\z", options: .regularExpression) != nil,
              !topic.isEmpty, !username.isEmpty, !session.cookies.isEmpty else {
            throw HorizonError.message("Notification images require a registered server and an authenticated session.")
        }
        generation = UUID()
        self.installationID = installation.uuidString.lowercased()
        self.serverID = serverID
        self.topic = topic
        self.username = username
        self.allowedCameraIDs = Array(Set(allowedCameraIDs)).sorted()
        self.session = session
        imagesEnabled = true
        _ = try address()
    }

    public func address() throws -> ServerAddress {
        let address = try ServerAddress(session.server)
        guard address.url.scheme == "https" else {
            throw HorizonError.message("Lock-screen notification images require trusted HTTPS.")
        }
        return address
    }

    public func permits(_ route: NativeNotificationRoute) -> Bool {
        imagesEnabled && route.serverID == serverID
    }

    public func thumbnailURL(for route: NativeNotificationRoute) throws -> URL {
        guard permits(route), route.kind != .test, let identifier = route.identifier,
              let installation = UUID(uuidString: installationID) else {
            throw HorizonError.message("This notification has no authorized image reference.")
        }
        return try address().endpoint([
            "api", "notifications", "apns", "thumbnail", installation.uuidString.lowercased(),
            route.kind.rawValue, identifier,
        ], query: [URLQueryItem(name: "height", value: "360")])
    }
}
