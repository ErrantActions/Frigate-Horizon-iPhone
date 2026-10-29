import XCTest
@testable import HorizonCore

final class IncidentReplayPolicyTests: XCTestCase {
    private let allowed: Set<String> = ["front", "drive", "yard", "gate"]

    func testSelectionDeduplicatesWhilePreservingCameraOrder() throws {
        XCTAssertEqual(try IncidentReplayPolicy.cameras(["drive", "front", "drive"], allowed: allowed),
            ["drive", "front"])
        XCTAssertEqual(try IncidentReplayPolicy.cameras(["front", "drive", "yard", "gate"], allowed: allowed).count, 4)
    }

    func testSelectionRejectsUnauthorizedCamerasRatherThanSilentlyRequestingThem() {
        XCTAssertThrowsError(try IncidentReplayPolicy.cameras(["front", "private"], allowed: allowed))
        XCTAssertThrowsError(try IncidentReplayPolicy.cameras(["front", "drive"], allowed: []))
    }

    func testSelectionRejectsFewerThanTwoAndMoreThanFourDistinctPlayers() {
        for ids in [[], ["front"], ["front", "front"], ["front", "drive", "yard", "gate", "fifth"]] {
            XCTAssertThrowsError(try IncidentReplayPolicy.cameras(ids, allowed: allowed.union(["fifth"])))
        }
    }

    func testBarrierWaitsForEveryPresentRecordingToFinishSeeking() {
        XCTAssertFalse(IncidentReplayPolicy.barrierOpen([:]))
        XCTAssertFalse(IncidentReplayPolicy.barrierOpen(["front": .ready, "drive": .loading]))
        XCTAssertFalse(IncidentReplayPolicy.barrierOpen(["front": .loading, "drive": .gap]))
        XCTAssertTrue(IncidentReplayPolicy.barrierOpen(["front": .ready, "drive": .ready]))
        XCTAssertTrue(IncidentReplayPolicy.barrierOpen(["front": .ready, "drive": .ready, "yard": .gap, "gate": .failed]))
    }

    func testKnownGapsDoNotHoldTheSharedClockOrBecomeLiveFallbacks() {
        XCTAssertTrue(IncidentReplayPolicy.barrierOpen(["front": .gap, "drive": .gap]))
        XCTAssertTrue(IncidentReplayPolicy.barrierOpen(["front": .ready, "drive": .gap]))
        XCTAssertFalse(IncidentReplayPolicy.barrierOpen(["front": .failed, "drive": .failed]))
        XCTAssertFalse(IncidentReplayPolicy.barrierOpen(["front": .loading, "drive": .failed]))
    }

    func testMasterSelectionIsStableAndIndependentOfAudioSelection() {
        let order = ["drive", "front", "yard"]
        let ready: [String: IncidentReplayReadiness] = ["drive": .ready, "front": .ready, "yard": .gap]
        XCTAssertEqual(IncidentReplayPolicy.master(orderedCameras: order, states: ready, previous: nil), "drive")
        XCTAssertEqual(IncidentReplayPolicy.master(orderedCameras: order, states: ready, previous: "front"), "front")
        XCTAssertEqual(IncidentReplayPolicy.master(orderedCameras: order, states: ready, previous: "yard"), "drive")
        XCTAssertEqual(IncidentReplayPolicy.master(orderedCameras: order, states: ready, previous: "unauthorized"), "drive")
    }

    func testMasterFallsBackOnlyToReadySelectedCameras() {
        let states: [String: IncidentReplayReadiness] = ["front": .gap, "drive": .ready, "private": .ready]
        XCTAssertEqual(IncidentReplayPolicy.master(orderedCameras: ["front", "drive"], states: states, previous: "front"), "drive")
        XCTAssertNil(IncidentReplayPolicy.master(orderedCameras: ["front"], states: states, previous: "private"))
        XCTAssertNil(IncidentReplayPolicy.master(orderedCameras: ["front", "yard"],
            states: ["front": .gap, "yard": .failed], previous: nil))
    }

    func testDriftDeadbandDoesNotChaseSmallClockNoise() {
        for drift in [-0.08, -0.01, 0, 0.01, 0.08] {
            XCTAssertEqual(IncidentReplayPolicy.correction(drift: drift, secondsSinceSeek: 3), .none)
        }
    }

    func testModerateDriftCorrectionRatesAreBoundedAndPointTowardTheClock() {
        XCTAssertEqual(IncidentReplayPolicy.correction(drift: 0.1, secondsSinceSeek: 3), .rate(0.97))
        XCTAssertEqual(IncidentReplayPolicy.correction(drift: -0.1, secondsSinceSeek: 3), .rate(1.03))
        XCTAssertEqual(IncidentReplayPolicy.correction(drift: 0.35, secondsSinceSeek: 3), .rate(0.97))
        XCTAssertEqual(IncidentReplayPolicy.correction(drift: -0.35, secondsSinceSeek: 3), .rate(1.03))
    }

    func testLargeDriftRequestsABarrierSeekRatherThanAnUnboundedRateChange() {
        XCTAssertEqual(IncidentReplayPolicy.correction(drift: 0.36, secondsSinceSeek: 3), .seek)
        XCTAssertEqual(IncidentReplayPolicy.correction(drift: -20, secondsSinceSeek: 3), .seek)
        XCTAssertGreaterThan(IncidentReplayPolicy.maximumHardCorrections, 0)
        XCTAssertLessThanOrEqual(IncidentReplayPolicy.maximumHardCorrections, 3)
    }

    func testDriftCorrectionHasASeekSettlingCooldownAndRejectsInvalidSamples() {
        for elapsed in [-1, 0, 1.99, Double.nan, Double.infinity] {
            XCTAssertEqual(IncidentReplayPolicy.correction(drift: 5, secondsSinceSeek: elapsed), .none)
        }
        for drift in [Double.nan, Double.infinity, -Double.infinity] {
            XCTAssertEqual(IncidentReplayPolicy.correction(drift: drift, secondsSinceSeek: 3), .none)
        }
        XCTAssertEqual(IncidentReplayPolicy.correction(drift: 1, secondsSinceSeek: 2), .seek)
    }

    func testChunkBoundariesStayInsideTheFrozenReviewDay() throws {
        let range = try reviewRange()
        let first = try IncidentReplayPolicy.chunk(at: range.start - 20, range: range)
        XCTAssertEqual(first.lowerBound, range.start)
        XCTAssertLessThanOrEqual(first.upperBound - first.lowerBound, 300)
        let middle = try IncidentReplayPolicy.chunk(at: range.start + 310, range: range)
        XCTAssertLessThanOrEqual(middle.lowerBound, range.start + 310)
        XCTAssertGreaterThan(middle.upperBound, range.start + 310)
        let last = try IncidentReplayPolicy.chunk(at: range.end + 30, range: range)
        XCTAssertEqual(last.upperBound, range.end)
        XCTAssertThrowsError(try IncidentReplayPolicy.chunk(at: .nan, range: range))
    }

    func testSeekGenerationsAreDistinctEvenForRepeatedTimeAndKeepPauseIntent() throws {
        let range = try reviewRange()
        let first = try IncidentReplaySeek(timestamp: range.start + 100, autoplay: false, range: range)
        let repeated = try IncidentReplaySeek(timestamp: range.start + 100, autoplay: false, range: range)
        XCTAssertNotEqual(first.id, repeated.id)
        XCTAssertEqual(first.timestamp, repeated.timestamp)
        XCTAssertFalse(first.autoplay)
        let end = try IncidentReplaySeek(timestamp: range.end + 10, autoplay: true, range: range)
        XCTAssertTrue(end.autoplay)
        XCTAssertLessThan(end.timestamp, range.end)
        XCTAssertThrowsError(try IncidentReplaySeek(timestamp: .infinity, autoplay: true, range: range))
    }

    func testSharedHostClockCannotAdvanceBeforeTheScheduledStartOrOutsideTheRange() throws {
        let range = try reviewRange()
        let anchor = range.start + 100
        XCTAssertEqual(try IncidentReplayPolicy.timestamp(anchor: anchor, hostElapsed: -0.15, range: range), anchor)
        XCTAssertEqual(try IncidentReplayPolicy.timestamp(anchor: anchor, hostElapsed: 5, range: range), anchor + 5)
        XCTAssertLessThan(try IncidentReplayPolicy.timestamp(anchor: anchor, hostElapsed: 100000, range: range), range.end)
        XCTAssertThrowsError(try IncidentReplayPolicy.timestamp(anchor: anchor, hostElapsed: .nan, range: range))
    }

    func testRealizedPositionsDifferPerCameraWithoutCollapsingTheSharedGap() {
        let front = PlaybackTimeline(spans: [
            PlaybackSpan(startTime: 100, endTime: 110, duration: 12000, leadInMilliseconds: 2000),
            PlaybackSpan(startTime: 120, endTime: 140, duration: 20000, leadInMilliseconds: 0),
        ])
        let drive = PlaybackTimeline(spans: [
            PlaybackSpan(startTime: 90, endTime: 140, duration: 51000, leadInMilliseconds: 1000),
        ])
        XCTAssertEqual(front.position(for: 105), 7)
        XCTAssertEqual(drive.position(for: 105), 16)
        XCTAssertNil(front.position(for: 115))
        XCTAssertNotNil(drive.position(for: 115))
        XCTAssertEqual(front.position(for: 125), 17)
        XCTAssertEqual(drive.position(for: 125), 36)
    }

    func testPlayerRunEndsBeforeTheNextKnownGapInEitherCoverageOrRealizedHLS() {
        let indexed = RecordingCoverage(spans: [
            CoverageSpan(startTime: 100, endTime: 110, streams: ["main"]),
            CoverageSpan(startTime: 110, endTime: 120, streams: ["main"]),
            CoverageSpan(startTime: 130, endTime: 150, streams: ["main"]),
        ], timelines: nil)
        let realized = PlaybackTimeline(spans: [
            PlaybackSpan(startTime: 100, endTime: 115, duration: 15000, leadInMilliseconds: 0),
            PlaybackSpan(startTime: 117, endTime: 150, duration: 33000, leadInMilliseconds: 0),
        ])
        XCTAssertEqual(IncidentReplayPolicy.recordedRunEnd(at: 105, coverage: indexed, timeline: realized), 115)
        XCTAssertEqual(IncidentReplayPolicy.recordedRunEnd(at: 118, coverage: indexed, timeline: realized), 120)
        XCTAssertEqual(IncidentReplayPolicy.recordedRunEnd(at: 135, coverage: indexed, timeline: realized), 150)
        XCTAssertNil(IncidentReplayPolicy.recordedRunEnd(at: 116, coverage: indexed, timeline: realized))
        XCTAssertNil(IncidentReplayPolicy.recordedRunEnd(at: 125, coverage: indexed, timeline: realized))
        XCTAssertNil(IncidentReplayPolicy.recordedRunEnd(at: .nan, coverage: indexed, timeline: realized))
    }

    private func reviewRange() throws -> ReviewTimeRange {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let day = Date(timeIntervalSince1970: 1793059200)
        return try ReviewTimeRange(day: day, now: day.addingTimeInterval(3650), calendar: calendar)
    }
}
