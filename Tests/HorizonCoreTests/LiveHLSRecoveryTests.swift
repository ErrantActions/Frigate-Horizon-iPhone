import XCTest
@testable import HorizonCore

final class LiveHLSRecoveryTests: XCTestCase {
    func testOnly401UsesExistingReauthenticationNot403OrGatewayFailures() {
        XCTAssertTrue(LiveHLSGate.requiresReauthentication(HorizonError.unauthorized))
        XCTAssertTrue(LiveHLSGate.requiresReauthentication(HorizonError.http(401)))
        XCTAssertFalse(LiveHLSGate.requiresReauthentication(HorizonError.forbidden))
        XCTAssertFalse(LiveHLSGate.requiresReauthentication(HorizonError.http(403)))
        XCTAssertFalse(LiveHLSGate.requiresReauthentication(HorizonError.http(502)))
        XCTAssertFalse(LiveHLSGate.requiresReauthentication(HorizonError.http(503)))
    }

    func testNativeRecommendedOffsetIsRespectedAfterFiveSecondStall() {
        var state = LiveHLSEdgeRecoveryPolicy()
        XCTAssertNil(state.target(current: 82, seekableStart: 80, seekableEnd: 100,
            recommendedOffset: 1.5, stalledFor: 4.9, waiting: true))
        XCTAssertEqual(state.target(current: 82, seekableStart: 80, seekableEnd: 100,
            recommendedOffset: 1.5, stalledFor: 5, waiting: true), 98.5)
        XCTAssertEqual(state.attempts, 1)
    }

    func testAtMostOneAutomaticSeekWithoutReplacingThePlayerItem() {
        var state = LiveHLSEdgeRecoveryPolicy()
        XCTAssertEqual(state.target(current: 82, seekableStart: 80, seekableEnd: 100,
            recommendedOffset: nil, stalledFor: 5, waiting: true), 97)
        XCTAssertNil(state.target(current: 83, seekableStart: 82, seekableEnd: 120,
            recommendedOffset: nil, stalledFor: 30, waiting: true))
    }

    func testPausedOrPlayingStreamsDoNotTriggerRecovery() {
        var state = LiveHLSEdgeRecoveryPolicy()
        XCTAssertNil(state.target(current: 82, seekableStart: 80, seekableEnd: 100,
            recommendedOffset: 1, stalledFor: 10, waiting: false))
        XCTAssertEqual(state.attempts, 0)
    }

    func testAlreadyNearLiveEdgeDoesNotSeekOrConsumeRecoveryBudget() {
        var state = LiveHLSEdgeRecoveryPolicy()
        XCTAssertNil(state.target(current: 97, seekableStart: 80, seekableEnd: 100,
            recommendedOffset: 1, stalledFor: 8, waiting: true))
        XCTAssertEqual(state.attempts, 0)
    }

    func testShortWindowClampsToItsAvailableStart() {
        var state = LiveHLSEdgeRecoveryPolicy()
        XCTAssertEqual(state.target(current: 80, seekableStart: 99, seekableEnd: 100,
            recommendedOffset: 3, stalledFor: 6, waiting: true), 99)
    }

    func testPositionOutsideNewWindowCanReturnBackwardToLive() {
        var state = LiveHLSEdgeRecoveryPolicy()
        XCTAssertEqual(state.target(current: 110, seekableStart: 80, seekableEnd: 100,
            recommendedOffset: 3, stalledFor: 6, waiting: true), 97)
    }

    func testInvalidMeasurementsCannotCauseASeek() {
        var state = LiveHLSEdgeRecoveryPolicy()
        for value in [Double.nan, .infinity] {
            XCTAssertNil(state.target(current: value, seekableStart: 80, seekableEnd: 100,
                recommendedOffset: nil, stalledFor: 6, waiting: true))
            XCTAssertNil(state.target(current: 82, seekableStart: 80, seekableEnd: value,
                recommendedOffset: nil, stalledFor: 6, waiting: true))
        }
        XCTAssertNil(state.target(current: 82, seekableStart: 100, seekableEnd: 80,
            recommendedOffset: nil, stalledFor: 6, waiting: true))
        XCTAssertEqual(state.attempts, 0)
    }
}
