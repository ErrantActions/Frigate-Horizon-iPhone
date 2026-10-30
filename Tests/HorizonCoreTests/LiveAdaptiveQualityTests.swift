import XCTest
@testable import HorizonCore

final class LiveAdaptiveQualityTests: XCTestCase {
    private func camera(enabled: Bool = true, transcodeEnabled: Bool = true,
                        advertised: String = #""720p":"front_transcode_720p","1080p":"front_transcode_1080p""#) throws -> HorizonCamera {
        let data = Data("""
        {"cameras":{"front":{"enabled":\(enabled),"live":{"streams":{\(advertised)},
        "transcode":{"enabled":\(transcodeEnabled),"source":"front_main",
        "qualities":[{"height":360},{"height":720},{"height":1080},{"height":1080}]}}}}}
        """.utf8)
        return try XCTUnwrap(JSONDecoder().decode(HorizonConfiguration.self, from: data).orderedCameras.first)
    }

    private func plan() throws -> LiveAdaptiveQualityPlan {
        try XCTUnwrap(camera().adaptiveQualityPlan(expanded: true))
    }

    func testOnlyAdvertisedMainDerivedRenditionsAreUsed() throws {
        let plan = try plan()
        XCTAssertEqual(plan.renditions.map(\.height), [720, 1080])
        XCTAssertEqual(plan.startupStream, "front_transcode_720p")
        XCTAssertFalse(plan.identity.contains("360"))
    }

    func testDisabledOrSingleStreamServersDoNotInventAdaptation() throws {
        XCTAssertNil(try camera(enabled: false).adaptiveQualityPlan(expanded: true))
        XCTAssertNil(try camera(transcodeEnabled: false).adaptiveQualityPlan(expanded: true))
        XCTAssertNil(try camera(advertised: #""Main":"front_main","Sub":"front_sub""#).adaptiveQualityPlan(expanded: true))
        XCTAssertNil(try camera(advertised: #""720p":"front_transcode_720p""#).adaptiveQualityPlan(expanded: true))
    }

    func testGridRemainsAtConfigured720Floor() throws {
        XCTAssertNil(try camera().adaptiveQualityPlan(expanded: false))
        XCTAssertEqual(try camera().preferredStream(expanded: false), "front_transcode_720p")
    }

    func testUpgradeRequiresFifteenSecondsOfActualHealthyVideo() throws {
        var state = LiveAdaptiveQualityState(plan: try plan(), now: 0)
        XCTAssertNil(state.observe(now: 0, frameAge: nil, videoReady: false, restrictedNetwork: false, frozen: false))
        XCTAssertNil(state.observe(now: 10, frameAge: 0, videoReady: true, restrictedNetwork: false, frozen: false))
        XCTAssertNil(state.observe(now: 24.9, frameAge: 0, videoReady: true, restrictedNetwork: false, frozen: false))
        XCTAssertEqual(state.observe(now: 25, frameAge: 0, videoReady: true, restrictedNetwork: false, frozen: false),
            "front_transcode_1080p")
    }

    func testRestrictedNetworkNeverUpgrades() throws {
        var state = LiveAdaptiveQualityState(plan: try plan(), now: 0)
        for time in [0.0, 15, 60, 120] {
            XCTAssertNil(state.observe(now: time, frameAge: 0, videoReady: true, restrictedNetwork: true, frozen: false))
        }
        XCTAssertEqual(state.stream, "front_transcode_720p")
    }

    func testPiPOrInactiveOwnerFreezesQuality() throws {
        var state = LiveAdaptiveQualityState(plan: try plan(), now: 0)
        XCTAssertNil(state.observe(now: 0, frameAge: 0, videoReady: true, restrictedNetwork: false, frozen: false))
        XCTAssertNil(state.observe(now: 30, frameAge: 0, videoReady: true, restrictedNetwork: false, frozen: true))
        XCTAssertNil(state.observe(now: 31, frameAge: 0, videoReady: true, restrictedNetwork: false, frozen: false))
        XCTAssertEqual(state.stream, "front_transcode_720p")
    }

    func testNetworkRestrictionDownshiftsAfterSwitchCooldown() throws {
        var state = LiveAdaptiveQualityState(plan: try plan(), now: 0)
        _ = state.observe(now: 0, frameAge: 0, videoReady: true, restrictedNetwork: false, frozen: false)
        _ = state.observe(now: 15, frameAge: 0, videoReady: true, restrictedNetwork: false, frozen: false)
        XCTAssertNil(state.observe(now: 20, frameAge: 0, videoReady: true, restrictedNetwork: true, frozen: false))
        XCTAssertEqual(state.observe(now: 23, frameAge: 0, videoReady: true, restrictedNetwork: true, frozen: false),
            "front_transcode_720p")
    }

    func testStallDownshiftsButDoesNotLoopBelowStartupQuality() throws {
        var state = LiveAdaptiveQualityState(plan: try plan(), now: 0)
        _ = state.observe(now: 0, frameAge: 0, videoReady: true, restrictedNetwork: false, frozen: false)
        _ = state.observe(now: 15, frameAge: 0, videoReady: true, restrictedNetwork: false, frozen: false)
        XCTAssertEqual(state.observe(now: 23, frameAge: 3.1, videoReady: true, restrictedNetwork: false, frozen: false),
            "front_transcode_720p")
        XCTAssertNil(state.reduceQuality(now: 24))
    }

    func testCapacityFailureCanDownshiftWithoutWaitingForAStall() throws {
        var state = LiveAdaptiveQualityState(plan: try plan(), now: 0)
        _ = state.observe(now: 0, frameAge: 0, videoReady: true, restrictedNetwork: false, frozen: false)
        _ = state.observe(now: 15, frameAge: 0, videoReady: true, restrictedNetwork: false, frozen: false)
        XCTAssertEqual(state.reduceQuality(now: 16), "front_transcode_720p")
        _ = state.observe(now: 17, frameAge: 0, videoReady: true, restrictedNetwork: false, frozen: false)
        XCTAssertNil(state.observe(now: 75.9, frameAge: 0, videoReady: true, restrictedNetwork: false, frozen: false))
        XCTAssertEqual(state.observe(now: 76, frameAge: 0, videoReady: true, restrictedNetwork: false, frozen: false),
            "front_transcode_1080p")
    }

    func testUpgradeWithoutVideoFallsBackAfterEightSeconds() throws {
        var state = LiveAdaptiveQualityState(plan: try plan(), now: 0)
        _ = state.observe(now: 0, frameAge: 0, videoReady: true, restrictedNetwork: false, frozen: false)
        _ = state.observe(now: 15, frameAge: 0, videoReady: true, restrictedNetwork: false, frozen: false)
        XCTAssertNil(state.observe(now: 22.9, frameAge: nil, videoReady: false, restrictedNetwork: false, frozen: false))
        XCTAssertEqual(state.observe(now: 23, frameAge: nil, videoReady: false, restrictedNetwork: false, frozen: false),
            "front_transcode_720p")
    }

    func testAtMostTwoAutomaticUpgradeAttemptsPerSession() throws {
        var state = LiveAdaptiveQualityState(plan: try plan(), now: 0)
        for (start, upgrade, down) in [(0.0, 15.0, 16.0), (17.0, 76.0, 77.0)] {
            _ = state.observe(now: start, frameAge: 0, videoReady: true, restrictedNetwork: false, frozen: false)
            XCTAssertEqual(state.observe(now: upgrade, frameAge: 0, videoReady: true, restrictedNetwork: false, frozen: false),
                "front_transcode_1080p")
            XCTAssertEqual(state.reduceQuality(now: down), "front_transcode_720p")
        }
        _ = state.observe(now: 78, frameAge: 0, videoReady: true, restrictedNetwork: false, frozen: false)
        XCTAssertNil(state.observe(now: 200, frameAge: 0, videoReady: true, restrictedNetwork: false, frozen: false))
    }

    func testInvalidMeasurementsCannotChangeQuality() throws {
        var state = LiveAdaptiveQualityState(plan: try plan(), now: 10)
        for time in [Double.nan, .infinity, 9] {
            XCTAssertNil(state.observe(now: time, frameAge: 0, videoReady: true, restrictedNetwork: false, frozen: false))
        }
        for age in [Double.nan, .infinity, -1] {
            XCTAssertNil(state.observe(now: 20, frameAge: age, videoReady: true, restrictedNetwork: false, frozen: false))
        }
        XCTAssertEqual(state.stream, "front_transcode_720p")
    }
}
