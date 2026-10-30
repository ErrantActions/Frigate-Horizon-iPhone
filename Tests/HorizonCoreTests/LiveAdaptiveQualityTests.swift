import XCTest
@testable import HorizonCore

final class LiveAdaptiveQualityTests: XCTestCase {
    private func camera(enabled: Bool = true, transcodeEnabled: Bool = false,
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
        XCTAssertNil(try camera(advertised: #""Main":"front_main","Sub":"front_sub""#).adaptiveQualityPlan(expanded: true))
        XCTAssertNil(try camera(advertised: #""720p":"front_transcode_720p""#).adaptiveQualityPlan(expanded: true))
    }

    func testManuallyAdvertisedProfilesWorkWithGenerationDisabled() throws {
        let manual = try camera(transcodeEnabled: false)
        let generated = try camera(transcodeEnabled: true)
        XCTAssertEqual(manual.adaptiveQualityPlan(expanded: true), generated.adaptiveQualityPlan(expanded: true))
        XCTAssertEqual(manual.preferredStream(expanded: false), "front_transcode_720p")
        XCTAssertEqual(manual.preferredStream(expanded: true), "front_transcode_1080p")
    }

    func testActualAutoPlaybackSelectionStartsLowButKeepsItsMaximum() throws {
        let choice = try XCTUnwrap(camera().playbackQuality(expanded: true))
        XCTAssertEqual(choice.requestedStream, "front_transcode_1080p")
        XCTAssertEqual(choice.startupStream, "front_transcode_720p")
        XCTAssertEqual(choice.adaptivePlan?.renditions.map(\.height), [720, 1080])
    }

    func testExplicitPinsNeverCreateAnAdaptivePlanOrLowerTheSelection() throws {
        let current = try camera(advertised: #""Main":"front_main","Sub":"front_sub","720p":"front_transcode_720p","1080p":"front_transcode_1080p""#)
        for pin in ["front_main", "front_sub", "front_transcode_720p", "front_transcode_1080p"] {
            let choice = try XCTUnwrap(current.playbackQuality(expanded: true, pinnedStream: pin, maximumHeight: 720))
            XCTAssertEqual(choice.requestedStream, pin)
            XCTAssertEqual(choice.startupStream, pin)
            XCTAssertNil(choice.adaptivePlan)
        }
        XCTAssertNil(current.playbackQuality(expanded: true, pinnedStream: "unadvertised"))
    }

    func testSelectedAutomaticMaximumIsNotExceeded() throws {
        let current = try camera()
        let limited = try XCTUnwrap(current.playbackQuality(expanded: true, maximumHeight: 720))
        XCTAssertEqual(limited.requestedStream, "front_transcode_720p")
        XCTAssertEqual(limited.startupStream, "front_transcode_720p")
        XCTAssertNil(limited.adaptivePlan)
        XCTAssertNil(current.playbackQuality(expanded: true, maximumHeight: 360))
        XCTAssertNil(try camera(advertised: #""1080p":"front_transcode_1080p""#)
            .playbackQuality(expanded: true, maximumHeight: 720))
    }

    func testMissingProfilesRemainSingleStreamWithoutInventingAliases() throws {
        let lowOnly = try XCTUnwrap(camera(advertised: #""720p":"front_transcode_720p""#)
            .playbackQuality(expanded: true))
        XCTAssertEqual(lowOnly.startupStream, "front_transcode_720p")
        XCTAssertNil(lowOnly.adaptivePlan)
        let highOnly = try XCTUnwrap(camera(advertised: #""1080p":"front_transcode_1080p""#)
            .playbackQuality(expanded: true))
        XCTAssertEqual(highOnly.startupStream, "front_transcode_1080p")
        XCTAssertNil(highOnly.adaptivePlan)
        let main = try XCTUnwrap(camera(advertised: #""Main":"front_main","Sub":"front_sub""#)
            .playbackQuality(expanded: true))
        XCTAssertEqual(main.startupStream, "front_main")
        XCTAssertNil(main.adaptivePlan)
    }

    func testDisabledCameraCannotResolveAutoOrPinnedPlayback() throws {
        let disabled = try camera(enabled: false)
        XCTAssertNil(disabled.preferredStream(expanded: true))
        XCTAssertNil(disabled.playbackQuality(expanded: true))
        XCTAssertNil(disabled.playbackQuality(expanded: true, pinnedStream: "front_transcode_720p"))
    }

    func testBelowMinimumKnownProfileIsNotAnAutomaticFallback() throws {
        let current = try camera(advertised: #""360p":"front_transcode_360p""#)
        XCTAssertNil(current.preferredStream(expanded: true))
        XCTAssertNil(current.playbackQuality(expanded: true))
        XCTAssertEqual(current.playbackQuality(expanded: true, pinnedStream: "front_transcode_360p")?.startupStream,
            "front_transcode_360p")
        XCTAssertNil(try camera(advertised: #""Main":"front_transcode_360p""#).playbackQuality(expanded: true))
    }

    func testMissingQualityMetadataDoesNotGuessAnAdaptiveLadder() throws {
        let data = Data(#"{"cameras":{"front":{"enabled":true,"live":{"streams":{"Main":"front_main","720p":"front_transcode_720p","1080p":"front_transcode_1080p"}}}}}"#.utf8)
        let current = try XCTUnwrap(JSONDecoder().decode(HorizonConfiguration.self, from: data).orderedCameras.first)
        XCTAssertNil(current.adaptiveQualityPlan(expanded: true))
        XCTAssertEqual(current.playbackQuality(expanded: true)?.startupStream, "front_main")
    }

    func testUnadvertisedMetadataAndOtherCameraProfilesAreIgnored() throws {
        let current = try camera(advertised: #""Main":"front_main","720p":"other_transcode_720p","1080p":"front_transcode_1080p""#)
        XCTAssertEqual(current.advertisedLiveRenditions.map(\.stream), ["front_transcode_1080p"])
        XCTAssertNil(current.adaptiveQualityPlan(expanded: true))
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

    func testDelayedFramesPreventAnUpgradeEvenBeforeAFullStall() throws {
        var state = LiveAdaptiveQualityState(plan: try plan(), now: 0)
        _ = state.observe(now: 0, frameAge: 0, videoReady: true, restrictedNetwork: false, frozen: false)
        XCTAssertNil(state.observe(now: 14, frameAge: 1.1, videoReady: true, restrictedNetwork: false, frozen: false))
        XCTAssertNil(state.observe(now: 15, frameAge: 0, videoReady: true, restrictedNetwork: false, frozen: false))
        XCTAssertNil(state.observe(now: 29.9, frameAge: 0, videoReady: true, restrictedNetwork: false, frozen: false))
        XCTAssertEqual(state.observe(now: 30, frameAge: 0, videoReady: true, restrictedNetwork: false, frozen: false),
            "front_transcode_1080p")
    }

    func testSustainedPlaybackQueuePressureDownshiftsDespiteFreshArrivals() throws {
        var state = LiveAdaptiveQualityState(plan: try plan(), now: 0)
        _ = state.observe(now: 0, frameAge: 0, videoReady: true, restrictedNetwork: false, frozen: false)
        _ = state.observe(now: 15, frameAge: 0, videoReady: true, restrictedNetwork: false, frozen: false)
        XCTAssertNil(state.observe(now: 23, frameAge: 0, videoReady: true, bufferedVideoDuration: 2.1,
            restrictedNetwork: false, frozen: false))
        XCTAssertNil(state.observe(now: 25.9, frameAge: 0, videoReady: true, bufferedVideoDuration: 2.1,
            restrictedNetwork: false, frozen: false))
        XCTAssertEqual(state.observe(now: 26, frameAge: 0, videoReady: true, bufferedVideoDuration: 2.1,
            restrictedNetwork: false, frozen: false), "front_transcode_720p")
    }

    func testTransientQueuePressureResetsInsteadOfCausingOscillation() throws {
        var state = LiveAdaptiveQualityState(plan: try plan(), now: 0)
        _ = state.observe(now: 0, frameAge: 0, videoReady: true, restrictedNetwork: false, frozen: false)
        _ = state.observe(now: 15, frameAge: 0, videoReady: true, restrictedNetwork: false, frozen: false)
        _ = state.observe(now: 23, frameAge: 0, videoReady: true, bufferedVideoDuration: 3,
            restrictedNetwork: false, frozen: false)
        XCTAssertNil(state.observe(now: 24, frameAge: 0, videoReady: true, bufferedVideoDuration: 0,
            restrictedNetwork: false, frozen: false))
        XCTAssertNil(state.observe(now: 25, frameAge: 0, videoReady: true, bufferedVideoDuration: 3,
            restrictedNetwork: false, frozen: false))
        XCTAssertEqual(state.stream, "front_transcode_1080p")
    }

    func testInvalidQueueMeasurementsCannotTriggerAnUpgrade() throws {
        var state = LiveAdaptiveQualityState(plan: try plan(), now: 0)
        _ = state.observe(now: 0, frameAge: 0, videoReady: true, restrictedNetwork: false, frozen: false)
        for value in [Double.nan, .infinity, -1] {
            XCTAssertNil(state.observe(now: 15, frameAge: 0, videoReady: true, bufferedVideoDuration: value,
                restrictedNetwork: false, frozen: false))
        }
        XCTAssertEqual(state.stream, "front_transcode_720p")
    }
}
