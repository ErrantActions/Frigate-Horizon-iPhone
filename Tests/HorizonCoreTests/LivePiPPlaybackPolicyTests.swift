import XCTest
@testable import HorizonCore

final class LivePiPPlaybackPolicyTests: XCTestCase {
    func testOrdinaryPlaybackRequiresVisibleActiveForegroundView() {
        for foreground in [false, true] {
            for visible in [false, true] {
                for active in [false, true] {
                    XCTAssertEqual(LivePiPPlaybackPolicy.mayKeepPlaying(
                        accountAuthorized: true, cameraEnabled: true, hasStream: true,
                        foreground: foreground, visible: visible, active: active,
                        pictureInPictureActive: false
                    ), foreground && visible && active)
                }
            }
        }
    }

    func testOnlyActiveAuthorizedPiPCanKeepOffscreenPlayback() {
        XCTAssertTrue(LivePiPPlaybackPolicy.mayKeepPlaying(
            accountAuthorized: true, cameraEnabled: true, hasStream: true,
            foreground: false, visible: false, active: false, pictureInPictureActive: true
        ))
        XCTAssertFalse(LivePiPPlaybackPolicy.mayKeepPlaying(
            accountAuthorized: true, cameraEnabled: true, hasStream: true,
            foreground: false, visible: false, active: false, pictureInPictureActive: false
        ))
    }

    func testPiPNeverOverridesAccountCameraOrSourceRevocation() {
        for authorized in [false, true] {
            for enabled in [false, true] {
                for hasStream in [false, true] {
                    for pip in [false, true] {
                        XCTAssertEqual(LivePiPPlaybackPolicy.mayKeepPlaying(
                            accountAuthorized: authorized, cameraEnabled: enabled, hasStream: hasStream,
                            foreground: true, visible: true, active: true,
                            pictureInPictureActive: pip
                        ), authorized && enabled && hasStream)
                    }
                }
            }
        }
    }
}
