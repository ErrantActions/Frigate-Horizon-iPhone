import XCTest
@testable import HorizonCore

final class CameraTourTests: XCTestCase {
    func testTourCandidatesExcludeDisabledHiddenAndUnconfiguredStreams() throws {
        let configuration = try JSONDecoder().decode(HorizonConfiguration.self, from: Data("""
        {"cameras":{
          "front":{"enabled":true,"live":{"streams":{"Main":"front_main"}}},
          "disabled":{"enabled":false,"live":{"streams":{"Main":"disabled_main"}}},
          "hidden":{"enabled":true,"live":{"streams":{"Main":"hidden_main"}},"ui":{"dashboard":false}},
          "missing":{"enabled":true,"live":{"streams":{}}}
        }}
        """.utf8))
        XCTAssertEqual(configuration.orderedCameras.filter(\.isTourCandidate).map(\.id), ["front"])
    }

    func testTourUsesTheProvidedCameraOrderAndWrapsBothDirections() {
        var tour = CameraTourState(cameraIDs: ["front", "garden", "garage"])
        XCTAssertEqual(tour.currentID, "front")
        XCTAssertEqual(tour.position, 1)
        tour.previous()
        XCTAssertEqual(tour.currentID, "garage")
        XCTAssertEqual(tour.position, 3)
        tour.next()
        XCTAssertEqual(tour.currentID, "front")
        tour.next()
        XCTAssertEqual(tour.currentID, "garden")
    }

    func testDuplicateAndEmptyIDsDoNotRepeatOrCreateMissingCameras() {
        let tour = CameraTourState(cameraIDs: ["front", "front", "", "garden", "front"])
        XCTAssertEqual(tour.cameraIDs, ["front", "garden"])
        XCTAssertEqual(tour.currentID, "front")
    }

    func testPermissionOrConfigurationChangesDiscardUnavailableCameras() {
        var tour = CameraTourState(cameraIDs: ["front", "garden"])
        tour.next()
        tour.update(cameraIDs: ["garage", "garden", "front"])
        XCTAssertEqual(tour.currentID, "garden")
        XCTAssertEqual(tour.position, 2)
        tour.update(cameraIDs: ["front"])
        XCTAssertEqual(tour.currentID, "front")
        XCTAssertEqual(tour.position, 1)
        tour.update(cameraIDs: [])
        XCTAssertNil(tour.currentID)
        XCTAssertNil(tour.position)
    }

    func testEmptyAndSingleCameraToursCannotAdvanceToInvalidPositions() {
        var empty = CameraTourState()
        empty.next()
        empty.previous()
        XCTAssertNil(empty.currentID)
        var single = CameraTourState(cameraIDs: ["front"])
        single.next()
        single.previous()
        XCTAssertEqual(single.currentID, "front")
        XCTAssertEqual(single.position, 1)
    }

    func testConnectingDoesNotConsumeTheCameraViewingInterval() {
        XCTAssertNil(schedule(ready: false).advanceAfterSeconds)
        XCTAssertEqual(schedule(ready: true).advanceAfterSeconds, 15)
    }

    func testUnavailableCameraHasAnExplicitShortSkipDelay() {
        XCTAssertEqual(schedule(ready: false, failed: true).advanceAfterSeconds, 3)
        XCTAssertEqual(schedule(ready: true, failed: true).advanceAfterSeconds, 3)
    }

    func testPausedBackgroundSingleAndEmptyToursHaveNoAutomaticAdvance() {
        XCTAssertNil(schedule(cycling: false).advanceAfterSeconds)
        XCTAssertNil(schedule(foreground: false).advanceAfterSeconds)
        XCTAssertNil(schedule(count: 1).advanceAfterSeconds)
        XCTAssertNil(schedule(count: 0).advanceAfterSeconds)
        XCTAssertNil(schedule(cameraID: nil).advanceAfterSeconds)
    }

    func testEveryIntervalIsMeasuredInSecondsAfterReadiness() {
        XCTAssertEqual(CameraTourInterval.allCases.map(\.rawValue), [5, 10, 15, 30, 60])
        for interval in CameraTourInterval.allCases {
            XCTAssertEqual(schedule(interval: interval).advanceAfterSeconds, interval.rawValue)
        }
    }

    func testCameraIntervalAndLifecycleChangesInvalidateAnOldSchedule() {
        let current = schedule()
        XCTAssertNotEqual(current, schedule(cameraID: "garden"))
        XCTAssertNotEqual(current, schedule(interval: .thirty))
        XCTAssertNotEqual(current, schedule(cycling: false))
        XCTAssertNotEqual(current, schedule(foreground: false))
        XCTAssertNotEqual(current, schedule(ready: false))
        XCTAssertNotEqual(current, schedule(failed: true))
    }

    func testScreenStaysAwakeOnlyForAVisibleForegroundCameraTour() {
        XCTAssertTrue(CameraTourSchedule.keepAwake(active: true, visible: true, foreground: true, hasCamera: true))
        XCTAssertFalse(CameraTourSchedule.keepAwake(active: false, visible: true, foreground: true, hasCamera: true))
        XCTAssertFalse(CameraTourSchedule.keepAwake(active: true, visible: false, foreground: true, hasCamera: true))
        XCTAssertFalse(CameraTourSchedule.keepAwake(active: true, visible: true, foreground: false, hasCamera: true))
        XCTAssertFalse(CameraTourSchedule.keepAwake(active: true, visible: true, foreground: true, hasCamera: false))
    }

    private func schedule(cameraID: String? = "front", count: Int = 2,
                          interval: CameraTourInterval = .fifteen, cycling: Bool = true,
                          foreground: Bool = true, ready: Bool = true, failed: Bool = false) -> CameraTourSchedule {
        CameraTourSchedule(cameraID: cameraID, cameraCount: count, interval: interval,
            cycling: cycling, foreground: foreground, ready: ready, failed: failed)
    }
}
