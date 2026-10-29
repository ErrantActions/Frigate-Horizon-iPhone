import XCTest
import CoreGraphics
@testable import HorizonCore

final class HTTPSVideoPresentationTests: XCTestCase {
    func testConnectionAndNegotiationNeverClaimVideoIsPlaying() {
        var presentation = HTTPSVideoPresentation()
        XCTAssertEqual(presentation.phase, .connecting)
        XCTAssertEqual(presentation.status, "Connecting over HTTPS")
        XCTAssertNil(presentation.resolution)
        presentation.waitingForVideo()
        XCTAssertEqual(presentation.phase, .waiting)
        XCTAssertEqual(presentation.status, "Waiting for video")
        XCTAssertNil(presentation.resolution)
    }

    func testDisplayedVideoClearsWaitingWithoutAReadinessNotification() {
        var presentation = HTTPSVideoPresentation()
        presentation.waitingForVideo()
        presentation.confirmDisplayedVideo(displayedSize: CGSize(width: 1920, height: 1080),
            readyForDisplay: false, streamSize: CGSize(width: 1920, height: 1088))
        XCTAssertEqual(presentation.phase, .live)
        XCTAssertEqual(presentation.status, "Live over HTTPS")
        XCTAssertEqual(presentation.resolution, CGSize(width: 1920, height: 1080))
    }

    func testReadinessFlagCanConfirmVideoBeforeThePixelBufferIsAvailable() {
        var presentation = HTTPSVideoPresentation()
        presentation.waitingForVideo()
        presentation.confirmDisplayedVideo(displayedSize: nil,
            readyForDisplay: true, streamSize: CGSize(width: 1280, height: 720))
        XCTAssertEqual(presentation.phase, .live)
        XCTAssertEqual(presentation.resolution, CGSize(width: 1280, height: 720))
    }

    func testQueuedMetadataAloneDoesNotClearTheWaitingIndicator() {
        var presentation = HTTPSVideoPresentation()
        presentation.waitingForVideo()
        presentation.confirmDisplayedVideo(displayedSize: nil,
            readyForDisplay: false, streamSize: CGSize(width: 1280, height: 720))
        XCTAssertEqual(presentation.phase, .waiting)
        XCTAssertNil(presentation.resolution)
    }

    func testActualDisplayedDimensionsDoNotRequireTrackMetadata() {
        var presentation = HTTPSVideoPresentation()
        presentation.confirmDisplayedVideo(displayedSize: CGSize(width: 640, height: 360),
            readyForDisplay: false, streamSize: .zero)
        XCTAssertEqual(presentation.resolution, CGSize(width: 640, height: 360))
        XCTAssertEqual(presentation.status, "Live over HTTPS")
    }

    func testLateNegotiationAndTemporaryMissingEvidenceCannotRevertLiveState() {
        var presentation = HTTPSVideoPresentation()
        presentation.confirmDisplayedVideo(displayedSize: CGSize(width: 1280, height: 720),
            readyForDisplay: false, streamSize: .zero)
        presentation.waitingForVideo()
        presentation.confirmDisplayedVideo(displayedSize: nil, readyForDisplay: false, streamSize: .zero)
        XCTAssertEqual(presentation.phase, .live)
        XCTAssertEqual(presentation.status, "Live over HTTPS")
        XCTAssertEqual(presentation.resolution, CGSize(width: 1280, height: 720))
    }

    func testReconnectResetDiscardsTheOldPlayingStateAndDimensions() {
        var presentation = HTTPSVideoPresentation()
        presentation.confirmDisplayedVideo(displayedSize: CGSize(width: 1920, height: 1080),
            readyForDisplay: true, streamSize: .zero)
        presentation.reset()
        XCTAssertEqual(presentation.phase, .connecting)
        XCTAssertNil(presentation.resolution)
        presentation.waitingForVideo()
        XCTAssertEqual(presentation.status, "Waiting for video")
        XCTAssertNil(presentation.resolution)
    }

    func testInvalidOrZeroDimensionsAreNotPublishedAsLiveVideo() {
        for size in [CGSize.zero, CGSize(width: -1, height: 720),
                     CGSize(width: CGFloat.nan, height: 720), CGSize(width: 1280, height: CGFloat.infinity)] {
            var presentation = HTTPSVideoPresentation()
            presentation.waitingForVideo()
            presentation.confirmDisplayedVideo(displayedSize: size, readyForDisplay: true, streamSize: size)
            XCTAssertEqual(presentation.phase, .waiting)
            XCTAssertNil(presentation.resolution)
        }
    }
}
