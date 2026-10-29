import XCTest
@testable import HorizonCore

final class NativeNotificationPreferenceTests: XCTestCase {
    func testOvernightQuietHoursBelongToTheirStartingWeekday() throws {
        let hours = try NativeQuietHours(enabled: true, startMinute: 22 * 60, endMinute: 7 * 60,
            timezone: "UTC", days: [1])
        XCTAssertTrue(try hours.isQuiet(at: date("2026-10-26T23:00:00Z")))
        XCTAssertTrue(try hours.isQuiet(at: date("2026-10-27T06:59:00Z")))
        XCTAssertFalse(try hours.isQuiet(at: date("2026-10-27T07:00:00Z")))
        XCTAssertFalse(try hours.isQuiet(at: date("2026-10-27T22:00:00Z")))
        XCTAssertFalse(try hours.isQuiet(at: date("2026-10-26T21:59:00Z")))
    }

    func testDSTSpringAndRepeatedFallHoursUseLocalWallTime() throws {
        let spring = try NativeQuietHours(enabled: true, startMinute: 60, endMinute: 240,
            timezone: "America/Chicago", days: [7])
        XCTAssertTrue(try spring.isQuiet(at: date("2026-03-08T07:30:00Z")))
        XCTAssertTrue(try spring.isQuiet(at: date("2026-03-08T08:30:00Z")))
        XCTAssertFalse(try spring.isQuiet(at: date("2026-03-08T09:00:00Z")))
        let fall = try NativeQuietHours(enabled: true, startMinute: 60, endMinute: 120,
            timezone: "America/Chicago", days: [7])
        XCTAssertTrue(try fall.isQuiet(at: date("2026-11-01T06:30:00Z")))
        XCTAssertTrue(try fall.isQuiet(at: date("2026-11-01T07:30:00Z")))
        XCTAssertFalse(try fall.isQuiet(at: date("2026-11-01T08:00:00Z")))
    }

    func testDisabledAndSameDayQuietHoursHaveExplicitBounds() throws {
        let disabled = try NativeQuietHours(enabled: false, startMinute: 60, endMinute: 120,
            timezone: "UTC", days: [1])
        XCTAssertFalse(try disabled.isQuiet(at: date("2026-10-26T01:30:00Z")))
        let active = try NativeQuietHours(enabled: true, startMinute: 60, endMinute: 120,
            timezone: "UTC", days: [1])
        XCTAssertTrue(try active.isQuiet(at: date("2026-10-26T01:00:00Z")))
        XCTAssertFalse(try active.isQuiet(at: date("2026-10-26T02:00:00Z")))
        XCTAssertFalse(try active.isQuiet(at: date("2026-10-27T01:30:00Z")))
    }

    func testInvalidQuietHoursAreRejectedRatherThanSuppressingEverything() {
        for (start, end, zone, days) in [
            (60, 60, "UTC", [1]), (-1, 120, "UTC", [1]),
            (60, 1440, "UTC", [1]), (60, 120, "Not/AZone", [1]),
            (60, 120, "UTC", []), (60, 120, "UTC", [0]),
            (60, 120, "UTC", [1, 1]),
        ] {
            XCTAssertThrowsError(try NativeQuietHours(enabled: true, startMinute: start,
                endMinute: end, timezone: zone, days: days))
        }
    }

    func testPreferenceBodyEncodesNullToExplicitlyDisableQuietHours() throws {
        let preferences = try NativeDevicePreferences(revision: 4, cameraSnoozeUntil: [:],
            quietHours: nil, healthAlerts: false)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(preferences)) as? [String: Any])
        XCTAssertTrue(object["quiet_hours"] is NSNull)
        XCTAssertEqual(object["revision"] as? Int, 4)
        XCTAssertEqual(object["health_alerts"] as? Bool, false)
        XCTAssertEqual(try JSONDecoder().decode(NativeDevicePreferences.self,
            from: JSONEncoder().encode(preferences)), preferences)
    }

    func testQuietHoursCodecUsesBackendKeysAndSortedDays() throws {
        let hours = try NativeQuietHours(enabled: true, startMinute: 1320, endMinute: 420,
            timezone: "America/Chicago", days: [7, 1, 3])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(hours)) as? [String: Any])
        XCTAssertEqual(object["start_minute"] as? Int, 1320)
        XCTAssertEqual(object["end_minute"] as? Int, 420)
        XCTAssertEqual(object["days"] as? [Int], [1, 3, 7])
        XCTAssertEqual(try JSONDecoder().decode(NativeQuietHours.self,
            from: JSONEncoder().encode(hours)), hours)
    }

    func testSnoozeBodyRejectsUntrustedCameraAndUnexpectedDurations() throws {
        for seconds in [0, 900, 3600] {
            let request = try NativeCameraSnoozeBody(cameraID: "front", seconds: seconds)
            XCTAssertEqual(request.seconds, seconds)
        }
        for seconds in [-1, 1, 86401] {
            XCTAssertThrowsError(try NativeCameraSnoozeBody(cameraID: "front", seconds: seconds))
        }
        for camera in ["", "../front", "https:camera", "front%2Fother"] {
            XCTAssertThrowsError(try NativeCameraSnoozeBody(cameraID: camera, seconds: 900))
        }
    }

    func testFeatureNegotiationDoesNotChangeLegacyRegistrationShape() throws {
        let id = "00112233-4455-6677-8899-aabbccddeeff"
        let legacy = try NativePushRegistrationBody(installationID: id, token: "ab",
            environment: "production", cameraIDs: nil)
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [String: Any])
        XCTAssertNil(original["features"])
        let negotiated = try NativePushRegistrationBody(installationID: id, token: "ab",
            environment: "production", cameraIDs: nil, features: ["health-v1", "actions-v1", "actions-v1"])
        XCTAssertEqual(negotiated.features, ["actions-v1", "health-v1"])
        XCTAssertThrowsError(try NativePushRegistrationBody(installationID: id, token: "ab",
            environment: "production", cameraIDs: nil, features: ["arbitrary-feature"]))
        let capabilities = try JSONDecoder().decode(NativePushCapabilities.self,
            from: Data(#"{"enabled":true,"server_id":"home-nvr","topic":"com.example.app"}"#.utf8))
        XCTAssertNil(capabilities.devicePreferences)
        XCTAssertNil(capabilities.supportsDeviceFeatures)
    }

    func testActionsAreAllowlistedAndHealthCannotBecomeAnImageOrCameraAction() throws {
        let event: [AnyHashable: Any] = ["server_id": "home-nvr", "kind": "event", "identifier": "123-front"]
        XCTAssertEqual(NativeNotificationRoute(userInfo: event, actionIdentifier: "HORIZON_SNOOZE_15M")?.intent, .snooze)
        XCTAssertEqual(NativeNotificationRoute(userInfo: event, actionIdentifier: "HORIZON_LIVE")?.intent, .live)
        XCTAssertNil(NativeNotificationRoute(userInfo: event, actionIdentifier: "OPEN_URL"))
        let health: [AnyHashable: Any] = ["server_id": "home-nvr", "kind": "health", "identifier": "storage"]
        XCTAssertEqual(NativeNotificationRoute(userInfo: health)?.kind, .health)
        XCTAssertNil(NativeNotificationRoute(userInfo: health, actionIdentifier: "HORIZON_SNOOZE_15M"))
        XCTAssertNil(NativeNotificationRoute(userInfo: health, actionIdentifier: "HORIZON_LIVE"))
    }

    func testIncompleteHealthSnapshotIsNotConfusedWithVerifiedHealthyState() throws {
        let snapshot = try JSONDecoder().decode(NativeHealthSnapshot.self,
            from: Data(#"{"sampled_at":1800000000,"checks_complete":false,"issues":[]}"#.utf8))
        XCTAssertFalse(snapshot.checksComplete)
        XCTAssertTrue(snapshot.issues.isEmpty)
        XCTAssertThrowsError(try JSONDecoder().decode(NativeHealthSnapshot.self,
            from: Data(#"{"sampled_at":0,"checks_complete":true,"issues":[]}"#.utf8)))
    }

    func testStatefulActionAccountBindingCannotComeFromAPNsPayload() throws {
        let payload: [AnyHashable: Any] = [
            "server_id": "home-nvr", "kind": "camera", "identifier": "front",
            "registration_account": "untrusted",
        ]
        let unbound = try XCTUnwrap(NativeNotificationRoute(userInfo: payload, actionIdentifier: "HORIZON_SNOOZE_15M"))
        XCTAssertNil(unbound.registrationAccount)
        let bound = try XCTUnwrap(NativeNotificationRoute(userInfo: payload,
            actionIdentifier: "HORIZON_SNOOZE_15M", registrationAccount: "local-account-hash"))
        XCTAssertEqual(bound.registrationAccount, "local-account-hash")
    }

    func testFreshResolutionMustMatchServerReferenceAndCurrentCameraScope() throws {
        let route = try XCTUnwrap(NativeNotificationRoute(userInfo: [
            "server_id": "home-nvr", "kind": "event", "identifier": "event-1",
        ]))
        let good = try JSONDecoder().decode(NativeNotificationResolution.self,
            from: Data(#"{"server_id":"home-nvr","kind":"event","identifier":"event-1","camera":"front","timestamp":1800000000}"#.utf8))
        XCTAssertNoThrow(try good.requireMatch(route, allowedCameras: ["front"]))
        XCTAssertThrowsError(try good.requireMatch(route, allowedCameras: ["garden"]))
        let changed = try JSONDecoder().decode(NativeNotificationResolution.self,
            from: Data(#"{"server_id":"other","kind":"event","identifier":"event-1","camera":"front","timestamp":1800000000}"#.utf8))
        XCTAssertThrowsError(try changed.requireMatch(route, allowedCameras: ["front"]))
    }

    private func date(_ string: String) throws -> Date {
        try XCTUnwrap(ISO8601DateFormatter().date(from: string))
    }
}
