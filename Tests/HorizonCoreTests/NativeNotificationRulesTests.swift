import XCTest
@testable import HorizonCore

final class NativeNotificationRulesTests: XCTestCase {
    private func rules(_ json: String) throws -> NativeCameraNotificationRules {
        NativeCameraNotificationRules(camera: "front",
            configuration: try JSONDecoder().decode(NativeSettingValue.self, from: Data(json.utf8)))
    }

    func testMissingRulesAreUnknownNotEnabled() throws {
        let value = try rules(#"{"cameras":{"front":{}}}"#)
        XCTAssertNil(value.notificationsEnabled)
        XCTAssertNil(value.cameraEnabled)
        XCTAssertNil(value.eligible)
        XCTAssertNil(value.alertLabels)
    }

    func testCameraOverridePreservesExplicitOptOut() throws {
        let value = try rules(#"{"notifications":{"enabled":true},"cameras":{"front":{"enabled":true,"notifications":{"enabled":false}}}}"#)
        XCTAssertEqual(value.notificationsEnabled, false)
        XCTAssertEqual(value.eligible, false)
    }

    func testGlobalDefaultOnlyFillsMissingCameraRule() throws {
        let value = try rules(#"{"notifications":{"enabled":true},"cameras":{"front":{"enabled":true}}}"#)
        XCTAssertEqual(value.eligible, true)
    }

    func testDisabledCameraIsNotNotificationEligible() throws {
        let value = try rules(#"{"notifications":{"enabled":true},"cameras":{"front":{"enabled":false}}}"#)
        XCTAssertEqual(value.eligible, false)
    }

    func testNativeVehicleAndAnimalLabelsAndZonesStayExact() throws {
        let value = try rules(#"{"cameras":{"front":{"enabled":true,"notifications":{"enabled":true,"cooldown":45},"review":{"alerts":{"labels":["person","vehicle","animal"],"required_zones":["driveway"]}}}}}"#)
        XCTAssertEqual(value.alertLabels, ["person", "vehicle", "animal"])
        XCTAssertEqual(value.requiredZones, ["driveway"])
        XCTAssertEqual(value.cooldown, 45)
    }

    func testEmptyAndUnreportedZonesAreNotConflated() throws {
        XCTAssertEqual(try rules(#"{"cameras":{"front":{"review":{"alerts":{"required_zones":[]}}}}}"#).requiredZones, [])
        XCTAssertNil(try rules(#"{"cameras":{"front":{}}}"#).requiredZones)
    }
}
