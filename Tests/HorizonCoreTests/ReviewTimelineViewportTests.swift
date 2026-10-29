import XCTest
@testable import HorizonCore

final class ReviewTimelineViewportTests: XCTestCase {
    private func range() throws -> ReviewTimeRange {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let day = Date(timeIntervalSince1970: 1793059200)
        return try ReviewTimeRange(day: day, now: day.addingTimeInterval(86400), calendar: calendar)
    }

    func testEveryScaleKeepsSelectedTimeAtTheStationaryViewportCenter() throws {
        let range = try range()
        for scale in ReviewTimelineScale.allCases {
            for height in [128.0, 320.0, 700.0] {
                let viewport = try ReviewTimelineViewport(range: range, scale: scale, height: height)
                for time in [range.start, range.start + 123.456, range.end - 0.125] {
                    let offset = try viewport.offset(for: time)
                    XCTAssertEqual(try viewport.position(for: time, atOffset: offset), height / 2, accuracy: 0.000001)
                    XCTAssertEqual(try viewport.timestamp(atOffset: offset), time, accuracy: 0.000001)
                }
            }
        }
    }

    func testDraggingTheRulerChangesTimeByExactlyOneTickPerSixteenPoints() throws {
        let range = try range()
        for scale in ReviewTimelineScale.allCases {
            let viewport = try ReviewTimelineViewport(range: range, scale: scale, height: 320)
            let selected = range.start + 3600
            let offset = try viewport.offset(for: selected)
            XCTAssertEqual(try viewport.timestamp(atOffset: offset + 16), selected - scale.secondsPerTick, accuracy: 0.000001)
            XCTAssertEqual(try viewport.timestamp(atOffset: offset - 16), selected + scale.secondsPerTick, accuracy: 0.000001)
            XCTAssertEqual(viewport.playheadY, 160)
        }
    }

    func testScaleChangesPreserveTheSameFractionalInstantWithoutQuantizing() throws {
        let range = try range()
        let selected = range.start + 12345.6789
        let offsets = try ReviewTimelineScale.allCases.map { scale -> Double in
            let viewport = try ReviewTimelineViewport(range: range, scale: scale, height: 320)
            let offset = try viewport.offset(for: selected)
            XCTAssertEqual(try viewport.timestamp(atViewportY: 160, offset: offset), selected, accuracy: 0.000001)
            return offset
        }
        XCTAssertEqual(try XCTUnwrap(offsets.last) / XCTUnwrap(offsets.first), 300, accuracy: 0.000001)
    }

    func testPaddingAllowsBothDayBoundariesToReachTheSameFixedPlayhead() throws {
        let range = try range()
        let viewport = try ReviewTimelineViewport(range: range, scale: .fiveSeconds, height: 320)
        XCTAssertEqual(viewport.contentHeight - viewport.maximumOffset, 320)
        XCTAssertEqual(try viewport.timestamp(atOffset: viewport.maximumOffset), range.start)
        XCTAssertLessThan(try viewport.timestamp(atOffset: 0), range.end)
        XCTAssertEqual(try viewport.position(for: range.start, atOffset: viewport.maximumOffset), 160)
        XCTAssertEqual(try viewport.position(for: range.end, atOffset: 0), 160)
        XCTAssertEqual(try viewport.timestamp(atOffset: viewport.maximumOffset + 1000), range.start)
        XCTAssertLessThan(try viewport.timestamp(atOffset: -1000), range.end)
    }

    func testTapSelectionMovesTheTappedRulerTimeUnderThePlayhead() throws {
        let range = try range()
        let viewport = try ReviewTimelineViewport(range: range, scale: .fifteenSeconds, height: 320)
        let offset = try viewport.offset(for: range.start + 3600)
        let target = try viewport.timestamp(atViewportY: 240, offset: offset)
        XCTAssertEqual(target, range.start + 3600 - 75, accuracy: 0.000001)
        XCTAssertEqual(try viewport.position(for: target, atOffset: viewport.offset(for: target)), 160, accuracy: 0.000001)
    }

    func testVisibleTicksStayBoundedAtTheFinestScaleAcrossLongDays() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Chicago"))
        for (month, day, hours) in [(3, 8, 23), (11, 1, 25)] {
            let date = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: month, day: day)))
            let range = try ReviewTimeRange(day: date, now: date.addingTimeInterval(172800), calendar: calendar)
            let viewport = try ReviewTimelineViewport(range: range, scale: .oneSecond, height: 320)
            XCTAssertEqual(viewport.maximumOffset, Double(hours * 3600) * 16)
            let ticks = try viewport.visibleTicks(atOffset: viewport.offset(for: range.start + 3600))
            XCTAssertLessThanOrEqual(ticks.count, 22)
            XCTAssertTrue(ticks.allSatisfy { $0 >= range.start && $0 <= range.end })
            XCTAssertTrue(zip(ticks, ticks.dropFirst()).allSatisfy { pair in pair.0 - pair.1 == 1 })
        }
    }

    func testScaleChoicesHaveExplicitLimitsAndReversibleZoomSteps() {
        XCTAssertEqual(ReviewTimelineScale.allCases.map(\.rawValue), [300, 60, 30, 15, 5, 1])
        XCTAssertNil(ReviewTimelineScale.fiveMinutes.coarser)
        XCTAssertNil(ReviewTimelineScale.oneSecond.finer)
        for scale in ReviewTimelineScale.allCases {
            if let finer = scale.finer { XCTAssertEqual(finer.coarser, scale) }
            if let coarser = scale.coarser { XCTAssertEqual(coarser.finer, scale) }
        }
    }

    func testInvalidCoordinatesAreNotRenderedOrConvertedToValidSeeks() throws {
        let range = try range()
        for height in [0.0, -1, .nan, .infinity] {
            XCTAssertThrowsError(try ReviewTimelineViewport(range: range, scale: .thirtySeconds, height: height))
        }
        let viewport = try ReviewTimelineViewport(range: range, scale: .thirtySeconds, height: 320)
        XCTAssertThrowsError(try viewport.offset(for: .nan))
        XCTAssertThrowsError(try viewport.timestamp(atOffset: .infinity))
        XCTAssertThrowsError(try viewport.timestamp(atViewportY: .nan, offset: 0))
        XCTAssertThrowsError(try viewport.position(for: .nan, atOffset: 0))
        XCTAssertThrowsError(try viewport.visibleTicks(atOffset: .nan))
    }
}
