import XCTest
@testable import HorizonCore

final class NotificationImageSessionTests: XCTestCase {
    private func saved(server: String = "https://nvr.example.invalid", expires: Date? = nil) throws -> SavedSession {
        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: "session", .value: "synthetic-session-only", .domain: "nvr.example.invalid",
            .path: "/", .secure: "TRUE",
        ]
        if let expires { properties[.expires] = expires }
        let cookie = try XCTUnwrap(HTTPCookie(properties: properties))
        return SavedSession(server: server, cookies: [SavedSession.SavedCookie(cookie)])
    }

    private func record(session: SavedSession? = nil) throws -> NotificationImageSession {
        try NotificationImageSession(installationID: "00112233-4455-6677-8899-aabbccddeeff",
            serverID: "home-nvr", topic: "com.example.horizon", username: "test",
            allowedCameraIDs: ["garden", "front", "front"], session: session ?? saved())
    }

    func testSharedSessionPreservesTheExistingSavedCookieEncodingAndOriginRules() throws {
        let session = try saved()
        let restored = try JSONDecoder().decode(SavedSession.self, from: JSONEncoder().encode(session))
        XCTAssertEqual(restored, session)
        XCTAssertNotNil(restored.cookies.first?.restore(for: try ServerAddress(session.server)))
        XCTAssertNil(restored.cookies.first?.restore(for: try ServerAddress("https://other.invalid")))
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(session)) as? [String: Any])
        XCTAssertEqual(Set(value.keys), Set(["server", "cookies"]))
    }

    func testExpiredCookiesAreNotRestoredForImageAuthentication() throws {
        let session = try saved(expires: Date().addingTimeInterval(-3600))
        XCTAssertNil(session.cookies.first?.restore(for: try ServerAddress(session.server)))
    }

    func testImageSessionRequiresTrustedHttpsAndAnAuthenticatedIdentity() throws {
        XCTAssertThrowsError(try record(session: saved(server: "http://nvr.example.invalid")))
        XCTAssertThrowsError(try NotificationImageSession(installationID: "00112233-4455-6677-8899-aabbccddeeff",
            serverID: "home-nvr", topic: "com.example.horizon",
            username: "", allowedCameraIDs: [], session: saved()))
        XCTAssertThrowsError(try NotificationImageSession(installationID: "00112233-4455-6677-8899-aabbccddeeff",
            serverID: "home-nvr", topic: "com.example.horizon",
            username: "test", allowedCameraIDs: [], session: SavedSession(server: "https://nvr.example.invalid", cookies: [])))
    }

    func testImageSessionNormalizesCameraScopeAndBindsNotificationServer() throws {
        let session = try record()
        XCTAssertEqual(session.allowedCameraIDs, ["front", "garden"])
        let matching = try XCTUnwrap(NativeNotificationRoute(userInfo: ["server_id": "home-nvr", "kind": "test"]))
        let other = try XCTUnwrap(NativeNotificationRoute(userInfo: ["server_id": "another-nvr", "kind": "test"]))
        XCTAssertTrue(session.permits(matching))
        XCTAssertFalse(session.permits(other))
    }

    func testReplacingTheSharedSessionProducesANewRevocationGeneration() throws {
        let first = try record()
        let second = try record()
        XCTAssertNotEqual(first.generation, second.generation)
    }

    func testThumbnailRequestsUseOnlyTheProtectedInstallationScopedEndpoint() throws {
        let session = try record()
        let route = try XCTUnwrap(NativeNotificationRoute(userInfo: [
            "server_id": "home-nvr", "kind": "event", "identifier": "event-123",
        ]))
        let url = try session.thumbnailURL(for: route)
        XCTAssertEqual(url.absoluteString,
            "https://nvr.example.invalid/api/notifications/apns/thumbnail/00112233-4455-6677-8899-aabbccddeeff/event/event-123?height=360")
        let test = try XCTUnwrap(NativeNotificationRoute(userInfo: ["server_id": "home-nvr", "kind": "test"]))
        XCTAssertThrowsError(try session.thumbnailURL(for: test))
    }

    func testDecodedInstallationIDCannotInjectAThumbnailPath() throws {
        var value = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(record())) as? [String: Any])
        value["installationID"] = "../another-installation"
        let decoded = try JSONDecoder().decode(NotificationImageSession.self,
            from: JSONSerialization.data(withJSONObject: value))
        let route = try XCTUnwrap(NativeNotificationRoute(userInfo: [
            "server_id": "home-nvr", "kind": "camera", "identifier": "front",
        ]))
        XCTAssertThrowsError(try decoded.thumbnailURL(for: route))
    }

    func testDecodedSessionsStillRevalidateHttpsBeforeAnyNetworkRequest() throws {
        var value = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(record())) as? [String: Any])
        var session = try XCTUnwrap(value["session"] as? [String: Any])
        session["server"] = "http://nvr.example.invalid"
        value["session"] = session
        let decoded = try JSONDecoder().decode(NotificationImageSession.self,
            from: JSONSerialization.data(withJSONObject: value))
        XCTAssertThrowsError(try decoded.address())
    }

    func testDisabledImageRecordCannotAuthorizeAThumbnail() throws {
        var value = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(record())) as? [String: Any])
        value["imagesEnabled"] = false
        let decoded = try JSONDecoder().decode(NotificationImageSession.self,
            from: JSONSerialization.data(withJSONObject: value))
        let route = try XCTUnwrap(NativeNotificationRoute(userInfo: ["server_id": "home-nvr", "kind": "test"]))
        XCTAssertFalse(decoded.permits(route))
    }
}
