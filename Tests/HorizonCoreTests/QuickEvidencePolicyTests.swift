import XCTest
@testable import HorizonCore

final class QuickEvidencePolicyTests: XCTestCase {
    func testQuickPresetsEndAtTheActualLatestRecordingInsteadOfNow() throws {
        let available = coverage([(100, 500)])
        let thirty = try QuickEvidencePolicy.assess(coverage: available, preset: .lastThirtySeconds,
            selected: nil, now: 1000)
        XCTAssertEqual(thirty.range, QuickEvidenceInterval(start: 470, end: 500))
        XCTAssertEqual(thirty.latestRecordingEnd, 500)
        XCTAssertEqual(thirty.ageSeconds, 500)
        XCTAssertTrue(thirty.isStale)
        XCTAssertTrue(thirty.canExport)
        let two = try QuickEvidencePolicy.assess(coverage: available, preset: .lastTwoMinutes,
            selected: nil, now: 1000)
        XCTAssertEqual(two.range, QuickEvidenceInterval(start: 380, end: 500))
    }

    func testAnchorNeverSelectsNewerFootageAndMayClipAnExistingSpan() throws {
        let result = try QuickEvidencePolicy.assess(coverage: coverage([(100, 800), (900, 1000)]),
            preset: .lastThirtySeconds, selected: nil, now: 1100, anchor: 600)
        XCTAssertEqual(result.range, QuickEvidenceInterval(start: 570, end: 600))
        XCTAssertEqual(result.latestRecordingEnd, 600)
        XCTAssertTrue(result.canExport)
    }

    func testFutureRecordingTimestampsCannotManufactureFutureEvidence() throws {
        let result = try QuickEvidencePolicy.assess(coverage: coverage([(100, 1200)]),
            preset: .lastThirtySeconds, selected: nil, now: 1000, anchor: 1500)
        XCTAssertEqual(result.range.end, 1000)
        XCTAssertEqual(result.ageSeconds, 0)
        XCTAssertFalse(result.isStale)
    }

    func testStalenessThresholdIsExplicit() throws {
        let fresh = try QuickEvidencePolicy.assess(coverage: coverage([(100, 500)]),
            preset: .lastThirtySeconds, selected: nil, now: 560)
        let stale = try QuickEvidencePolicy.assess(coverage: coverage([(100, 500)]),
            preset: .lastThirtySeconds, selected: nil, now: 561)
        XCTAssertFalse(fresh.isStale)
        XCTAssertTrue(stale.isStale)
    }

    func testKnownGapInsideQuickWindowIsReportedAndBlocksCapture() throws {
        let result = try QuickEvidencePolicy.assess(coverage: coverage([(100, 480), (490, 500)]),
            preset: .lastThirtySeconds, selected: nil, now: 505)
        XCTAssertEqual(result.range, QuickEvidenceInterval(start: 470, end: 500))
        XCTAssertEqual(result.gaps, [QuickEvidenceInterval(start: 480, end: 490)])
        XCTAssertFalse(result.canExport)
    }

    func testInsufficientRecordedHistoryIsNotPretendedToBeACompletePreset() throws {
        let result = try QuickEvidencePolicy.assess(coverage: coverage([(490, 500)]),
            preset: .lastThirtySeconds, selected: nil, now: 505)
        XCTAssertEqual(result.gaps, [QuickEvidenceInterval(start: 470, end: 490)])
        XCTAssertFalse(result.canExport)
    }

    func testSelectedRangeKeepsItsExactTimesInsteadOfSlidingToLatest() throws {
        let selected = QuickEvidenceInterval(start: 200, end: 250)
        let result = try QuickEvidencePolicy.assess(coverage: coverage([(100, 500)]),
            preset: .selectedRange, selected: selected, now: 1000)
        XCTAssertEqual(result.range, selected)
        XCTAssertTrue(result.canExport)
    }

    func testSelectedRangeReportsLeadingInternalAndTrailingGaps() throws {
        let result = try QuickEvidencePolicy.assess(coverage: coverage([(120, 140), (150, 170)]),
            preset: .selectedRange, selected: QuickEvidenceInterval(start: 100, end: 200), now: 250)
        XCTAssertEqual(result.gaps, [
            QuickEvidenceInterval(start: 100, end: 120),
            QuickEvidenceInterval(start: 140, end: 150),
            QuickEvidenceInterval(start: 170, end: 200),
        ])
        XCTAssertFalse(result.canExport)
    }

    func testAdjacentAndOverlappingCoverageIsMergedWithoutInventingGaps() throws {
        let raw = coverage([(160, 200), (100, 130), (125, 160), (200, 220), (110, 120)])
        XCTAssertEqual(QuickEvidencePolicy.intervals(raw.spans, before: 210),
            [QuickEvidenceInterval(start: 100, end: 210)])
        let result = try QuickEvidencePolicy.assess(coverage: raw, preset: .selectedRange,
            selected: QuickEvidenceInterval(start: 100, end: 210), now: 210)
        XCTAssertTrue(result.canExport)
    }

    func testGapPolicyHandlesUnsortedOverlappingAndMalformedIntervals() {
        let intervals = [
            QuickEvidenceInterval(start: 150, end: 180),
            QuickEvidenceInterval(start: 100, end: 120),
            QuickEvidenceInterval(start: 110, end: 140),
            QuickEvidenceInterval(start: .nan, end: 200),
            QuickEvidenceInterval(start: 190, end: 185),
        ]
        XCTAssertEqual(QuickEvidencePolicy.gaps(in: QuickEvidenceInterval(start: 100, end: 200), intervals: intervals), [
            QuickEvidenceInterval(start: 140, end: 150),
            QuickEvidenceInterval(start: 180, end: 200),
        ])
    }

    func testCoverageSanitizationRejectsMalformedSpansAndClampsElapsedTime() {
        let raw = coverage([
            (Double.nan, 200), (100, Double.infinity), (200, 100), (100, 100),
            (-100, 50), (100, 200), (500, 600),
        ])
        XCTAssertEqual(QuickEvidencePolicy.intervals(raw.spans, before: 150), [
            QuickEvidenceInterval(start: 0, end: 50),
            QuickEvidenceInterval(start: 100, end: 150),
        ])
        XCTAssertTrue(QuickEvidencePolicy.intervals(raw.spans, before: .nan).isEmpty)
    }

    func testNoCoverageOrOnlyFutureFootageFailsRatherThanDefaultingToNow() {
        for unavailable in [coverage([]), coverage([(1000, 1200)]), coverage([(200, 100)])] {
            XCTAssertThrowsError(try QuickEvidencePolicy.assess(coverage: unavailable,
                preset: .lastThirtySeconds, selected: nil, now: 500))
        }
    }

    func testInvalidRangesAndUnboundedExportRequestsAreRejected() {
        let available = coverage([(0, 200000)])
        let invalid = [
            QuickEvidenceInterval(start: -1, end: 100),
            QuickEvidenceInterval(start: 200, end: 100),
            QuickEvidenceInterval(start: 100, end: 100),
            QuickEvidenceInterval(start: .nan, end: 100),
            QuickEvidenceInterval(start: 100, end: .infinity),
            QuickEvidenceInterval(start: 100, end: 100001),
            QuickEvidenceInterval(start: 0, end: QuickEvidencePolicy.maximumDuration + 1),
        ]
        for range in invalid {
            XCTAssertThrowsError(try QuickEvidencePolicy.assess(coverage: available,
                preset: .selectedRange, selected: range, now: 100000))
        }
        XCTAssertThrowsError(try QuickEvidencePolicy.assess(coverage: available,
            preset: .selectedRange, selected: nil, now: 100000))
    }

    func testExactlyTwentyFourHourRangeIsAllowed() throws {
        let duration = QuickEvidencePolicy.maximumDuration
        let result = try QuickEvidencePolicy.assess(coverage: coverage([(100, 100 + duration)]),
            preset: .selectedRange, selected: QuickEvidenceInterval(start: 100, end: 100 + duration),
            now: 100 + duration)
        XCTAssertTrue(result.canExport)
    }

    func testSelectedRangeCannotEscapeHistoricalAnchor() {
        XCTAssertThrowsError(try QuickEvidencePolicy.assess(coverage: coverage([(100, 1000)]),
            preset: .selectedRange, selected: QuickEvidenceInterval(start: 400, end: 700),
            now: 1000, anchor: 600))
    }

    func testNonFiniteClockAndAnchorValuesAreRejected() {
        for now in [Double.nan, .infinity, -.infinity, 0, -1] {
            XCTAssertThrowsError(try QuickEvidencePolicy.assess(coverage: coverage([(100, 500)]),
                preset: .lastThirtySeconds, selected: nil, now: now))
        }
        for anchor in [Double.nan, .infinity, -.infinity, -1] {
            XCTAssertThrowsError(try QuickEvidencePolicy.assess(coverage: coverage([(100, 500)]),
                preset: .lastThirtySeconds, selected: nil, now: 1000, anchor: anchor))
        }
    }

    func testProtectionRequiresBothAdminAndCapabilityAndACompletedExport() {
        for admin in [false, true] {
            for capability in [false, true] {
                for ready in [false, true] {
                    XCTAssertEqual(QuickEvidencePolicy.canProtect(isAdmin: admin, capability: capability, readyExport: ready),
                        admin && capability && ready)
                }
            }
        }
    }

    func testProtectionCapabilityDecodingIsFailClosed() throws {
        XCTAssertFalse(try JSONDecoder().decode(QuickEvidenceNativeFeatures.self, from: Data("{}".utf8)).exportProtection)
        XCTAssertFalse(try JSONDecoder().decode(QuickEvidenceNativeFeatures.self,
            from: Data(#"{"export_protection":false}"#.utf8)).exportProtection)
        XCTAssertTrue(try JSONDecoder().decode(QuickEvidenceNativeFeatures.self,
            from: Data(#"{"export_protection":true}"#.utf8)).exportProtection)
        XCTAssertThrowsError(try JSONDecoder().decode(QuickEvidenceNativeFeatures.self,
            from: Data(#"{"export_protection":"true"}"#.utf8)))
    }

    func testProtectedLabelCanOnlyFollowAnExplicitSuccessfulResponse() throws {
        let rejected = try JSONDecoder().decode(QuickEvidenceProtectionResult.self,
            from: Data(#"{"success":false,"message":"Permission denied"}"#.utf8))
        XCTAssertThrowsError(try rejected.requireSuccess())
        let confirmed = try JSONDecoder().decode(QuickEvidenceProtectionResult.self,
            from: Data(#"{"success":true,"protected_id":"opaque-export-copy"}"#.utf8))
        XCTAssertNoThrow(try confirmed.requireSuccess())
        XCTAssertEqual(confirmed.protectedID, "opaque-export-copy")
        let withoutID = try JSONDecoder().decode(QuickEvidenceProtectionResult.self,
            from: Data(#"{"success":true}"#.utf8))
        XCTAssertNoThrow(try withoutID.requireSuccess())
    }

    private func coverage(_ intervals: [(Double, Double)]) -> RecordingCoverage {
        RecordingCoverage(spans: intervals.map { CoverageSpan(startTime: $0.0, endTime: $0.1, streams: ["main"]) },
            timelines: nil)
    }
}
