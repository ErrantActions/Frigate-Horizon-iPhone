import XCTest
import UIKit
import HorizonCore
@testable import FrigateHorizon

@MainActor
final class ReviewTimelineInteractionTests: XCTestCase {
    private func range() throws -> ReviewTimeRange {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let day = Date(timeIntervalSince1970: 1793059200)
        return try ReviewTimeRange(day: day, now: day.addingTimeInterval(86400), calendar: calendar)
    }

    private func makeTimeline(_ range: ReviewTimeRange, time: Double,
                      scale: ReviewTimelineScale = .thirtySeconds) -> ReviewTimelineScrollView {
        let view = ReviewTimelineScrollView(frame: CGRect(x: 0, y: 0, width: 128, height: 320))
        view.configure(range: range, scale: scale, time: time, coverage: nil, events: [], motion: [])
        view.setNeedsLayout()
        view.layoutIfNeeded()
        return view
    }

    func testPlayheadIsOutsideScrollableContentAndNeverFollowsRulerOffsets() throws {
        let range = try range()
        let view = makeTimeline(range, time: range.start + 3600)
        XCTAssertTrue(view.playhead.superview === view)
        XCTAssertFalse(view.playhead.isDescendant(of: view.scrollView))
        for scale in ReviewTimelineScale.allCases {
            view.configure(range: range, scale: scale, time: range.start + 3600,
                coverage: nil, events: [], motion: [])
            let marker = view.playhead.frame
            for offset in [0.0, 16, 300, view.scrollView.contentSize.height - view.bounds.height] {
                view.scrollView.setContentOffset(CGPoint(x: 0, y: offset), animated: false)
                view.scrollViewDidScroll(view.scrollView)
                XCTAssertEqual(view.playhead.frame, marker)
                XCTAssertEqual(view.playhead.frame.midY, view.bounds.midY)
            }
        }
        view.frame.size.height = 480
        view.setNeedsLayout()
        view.layoutIfNeeded()
        XCTAssertEqual(view.playhead.frame.midY, 240)
    }

    func testDraggingTimelinePausesOnceUpdatesSelectedTimeAndCommitsOnce() throws {
        let range = try range()
        let selected = range.start + 3600
        let view = makeTimeline(range, time: selected)
        var begins = 0
        var commits: [Double] = []
        var times: [Double] = []
        view.onBeginScrub = { begins += 1 }
        view.onTimeChange = { times.append($0) }
        view.onCommit = { commits.append($0) }
        view.scrollViewWillBeginDragging(view.scrollView)
        view.scrollViewWillBeginDragging(view.scrollView)
        let offset = view.scrollView.contentOffset.y + 32
        view.scrollView.setContentOffset(CGPoint(x: 0, y: offset), animated: false)
        view.scrollViewDidScroll(view.scrollView)
        XCTAssertEqual(try XCTUnwrap(times.last), selected - 60, accuracy: 0.000001)
        XCTAssertTrue(commits.isEmpty)
        view.scrollViewDidEndDragging(view.scrollView, willDecelerate: false)
        view.scrollViewDidEndDecelerating(view.scrollView)
        XCTAssertEqual(begins, 1)
        XCTAssertEqual(commits.count, 1)
        XCTAssertEqual(try XCTUnwrap(commits.first), selected - 60, accuracy: 0.000001)
        XCTAssertEqual(view.playhead.frame.midY, 160)
    }

    func testDecelerationFinishesBeforeTheSingleSeekIsCommitted() throws {
        let range = try range()
        let view = makeTimeline(range, time: range.start + 3600)
        var commits: [Double] = []
        view.onCommit = { commits.append($0) }
        view.scrollViewWillBeginDragging(view.scrollView)
        view.scrollViewDidEndDragging(view.scrollView, willDecelerate: true)
        XCTAssertTrue(commits.isEmpty)
        view.scrollView.setContentOffset(CGPoint(x: 0, y: view.scrollView.contentOffset.y + 16), animated: false)
        view.scrollViewDidScroll(view.scrollView)
        view.scrollViewDidEndDecelerating(view.scrollView)
        XCTAssertEqual(commits.count, 1)
        XCTAssertEqual(try XCTUnwrap(commits.first), range.start + 3570, accuracy: 0.000001)
    }

    func testScaleAndPlaybackUpdatesMoveOnlyTheRulerWithoutUserSeeks() throws {
        let range = try range()
        let selected = range.start + 3600.125
        let view = makeTimeline(range, time: selected)
        var callbacks = 0
        view.onBeginScrub = { callbacks += 1 }
        view.onTimeChange = { _ in callbacks += 1 }
        view.onCommit = { _ in callbacks += 1 }
        let marker = view.playhead.frame
        for scale in ReviewTimelineScale.allCases {
            for time in [selected, selected + 0.25, selected + 15] {
                view.configure(range: range, scale: scale, time: time, coverage: nil, events: [], motion: [])
                let viewport = try ReviewTimelineViewport(range: range, scale: scale, height: 320)
                XCTAssertEqual(try viewport.timestamp(atOffset: view.timelineOffset), time, accuracy: 0.000001)
                XCTAssertLessThan(abs(view.timelineOffset - Double(view.scrollView.contentOffset.y)), 1)
                XCTAssertEqual(view.playhead.frame, marker)
            }
        }
        XCTAssertEqual(callbacks, 0)
    }

    func testDraggingAfterZoomRetainsTheFractionalTimeCorrection() throws {
        let range = try range()
        let selected = range.start + 3600.125
        let view = makeTimeline(range, time: selected, scale: .fiveMinutes)
        var committed: Double?
        view.onCommit = { committed = $0 }
        view.scrollViewWillBeginDragging(view.scrollView)
        view.scrollView.setContentOffset(CGPoint(x: 0, y: view.scrollView.contentOffset.y + 16), animated: false)
        view.scrollViewDidScroll(view.scrollView)
        view.scrollViewDidEndDragging(view.scrollView, willDecelerate: false)
        XCTAssertEqual(try XCTUnwrap(committed), selected - 300, accuracy: 0.000001)
        XCTAssertEqual(view.playhead.frame.midY, 160)
    }

    func testVoiceOverAdjustsOneSelectedScaleTickAndClampsAtDayBoundaries() throws {
        let range = try range()
        let view = makeTimeline(range, time: range.start + 60, scale: .fiveSeconds)
        var commits: [Double] = []
        view.onCommit = { commits.append($0) }
        view.accessibilityIncrement()
        XCTAssertEqual(try XCTUnwrap(commits.last), range.start + 65, accuracy: 0.000001)
        view.accessibilityDecrement()
        XCTAssertEqual(try XCTUnwrap(commits.last), range.start + 60, accuracy: 0.000001)
        view.configure(range: range, scale: .fiveSeconds, time: range.start, coverage: nil, events: [], motion: [])
        view.accessibilityDecrement()
        XCTAssertEqual(try XCTUnwrap(commits.last), range.start)
        view.configure(range: range, scale: .fiveSeconds, time: range.end - 1, coverage: nil, events: [], motion: [])
        view.accessibilityIncrement()
        XCTAssertLessThan(try XCTUnwrap(commits.last), range.end)
        XCTAssertEqual(view.playhead.frame.midY, 160)
    }
}
