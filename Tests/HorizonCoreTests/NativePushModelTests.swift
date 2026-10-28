import XCTest
@testable import HorizonCore

final class NativePushModelTests: XCTestCase {
    private let installation = "00112233-4455-6677-8899-AABBCCDDEEFF"

    func testRegistrationContainsOnlyDeviceAndPreferenceFields() throws {
        let body = try NativePushRegistrationBody(installationID: installation,
            token: String(repeating: "AB", count: 32), environment: "production",
            cameraIDs: ["garden", "front", "front"])
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(body)) as? [String: Any])
        XCTAssertEqual(Set(value.keys), Set(["installation_id", "token", "environment", "camera_ids"]))
        XCTAssertEqual(value["installation_id"] as? String, installation.lowercased())
        XCTAssertEqual(value["token"] as? String, String(repeating: "ab", count: 32))
        XCTAssertEqual(value["environment"] as? String, "production")
        XCTAssertEqual(value["camera_ids"] as? [String], ["front", "garden"])
    }

    func testAllCamerasAndNoCamerasRemainDifferent() throws {
        let all = try NativePushRegistrationBody(installationID: installation,
            token: "ab", environment: "sandbox", cameraIDs: nil)
        let none = try NativePushRegistrationBody(installationID: installation,
            token: "ab", environment: "sandbox", cameraIDs: [])
        let allValue = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(all)) as? [String: Any])
        let noneValue = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(none)) as? [String: Any])
        XCTAssertNil(allValue["camera_ids"])
        XCTAssertEqual(noneValue["camera_ids"] as? [String], [])
    }

    func testVariableLengthHexTokensAndBothAppleEnvironments() throws {
        for length in [2, 64, 96, 512] {
            for environment in ["sandbox", "production"] {
                let body = try NativePushRegistrationBody(installationID: installation,
                    token: String(repeating: "a", count: length), environment: environment, cameraIDs: nil)
                XCTAssertEqual(body.token.count, length)
                XCTAssertEqual(body.environment, environment)
            }
        }
    }

    func testInvalidDeviceRegistrationIsRejected() {
        for token in ["", "a", "abc", "aaa\n", "aaa\r", "non-hex-token", String(repeating: "a", count: 514)] {
            XCTAssertThrowsError(try NativePushRegistrationBody(installationID: installation,
                token: token, environment: "production", cameraIDs: nil))
        }
        XCTAssertThrowsError(try NativePushRegistrationBody(installationID: "not-a-uuid",
            token: "ab", environment: "production", cameraIDs: nil))
        for environment in ["development", "https://example.com", "PRODUCTION", ""] {
            XCTAssertThrowsError(try NativePushRegistrationBody(installationID: installation,
                token: "ab", environment: environment, cameraIDs: nil))
        }
    }

    func testCapabilitiesAndAcknowledgementDecodeBackendKeys() throws {
        let capabilities = try JSONDecoder().decode(NativePushCapabilities.self, from: Data("""
        {"enabled":true,"server_id":"home-nvr","topic":"com.errantactions.frigatehorizon"}
        """.utf8))
        XCTAssertTrue(capabilities.enabled)
        XCTAssertEqual(capabilities.serverID, "home-nvr")
        XCTAssertEqual(capabilities.topic, "com.errantactions.frigatehorizon")
        let disabled = try JSONDecoder().decode(NativePushCapabilities.self,
            from: Data(#"{"enabled":false,"server_id":null,"topic":null}"#.utf8))
        XCTAssertFalse(disabled.enabled)
        XCTAssertNil(disabled.serverID)
        let acknowledgement = try JSONDecoder().decode(NativePushRegistrationResult.self, from: Data("""
        {"success":true,"message":"Registered","server_id":"home-nvr"}
        """.utf8))
        XCTAssertTrue(acknowledgement.success)
        XCTAssertEqual(acknowledgement.serverID, "home-nvr")
    }

    func testKnownRoutesHaveFreshNavigationIdentityForRepeatedTaps() throws {
        for kind in ["review", "event", "camera"] {
            let payload: [AnyHashable: Any] = [
                "server_id": "home-nvr", "kind": kind, "identifier": "1700000000.25-front_1",
            ]
            let first = try XCTUnwrap(NativeNotificationRoute(userInfo: payload))
            let repeated = try XCTUnwrap(NativeNotificationRoute(userInfo: payload))
            XCTAssertEqual(first.serverID, "home-nvr")
            XCTAssertEqual(first.kind.rawValue, kind)
            XCTAssertEqual(first.identifier, "1700000000.25-front_1")
            XCTAssertNotEqual(first.id, repeated.id)
        }
        let test = try XCTUnwrap(NativeNotificationRoute(userInfo: ["server_id": "home-nvr", "kind": "test"]))
        XCTAssertEqual(test.kind, .test)
        XCTAssertNil(test.identifier)
    }

    func testInvalidServerKindAndIdentifiersCannotBecomeDestinations() {
        for server in ["", "home-nvr\n", "https://example.com", "../home", String(repeating: "a", count: 65)] {
            XCTAssertNil(NativeNotificationRoute(userInfo: ["server_id": server, "kind": "test"]))
        }
        XCTAssertNil(NativeNotificationRoute(userInfo: ["server_id": "home-nvr", "kind": "url"]))
        XCTAssertNil(NativeNotificationRoute(userInfo: ["kind": "test"]))
        for identifier in ["", ".", "..", "/api/events", "../front", "front\\other",
                           "https://example.com", "https:example.com", "id%2Fother", "front\n",
                           String(repeating: "a", count: 257)] {
            XCTAssertNil(NativeNotificationRoute(userInfo: [
                "server_id": "home-nvr", "kind": "event", "identifier": identifier,
            ]))
        }
        XCTAssertNil(NativeNotificationRoute(userInfo: ["server_id": "home-nvr", "kind": "camera"]))
        XCTAssertNil(NativeNotificationRoute(userInfo: [
            "server_id": "home-nvr", "kind": "camera", "identifier": 123,
        ]))
    }
}
