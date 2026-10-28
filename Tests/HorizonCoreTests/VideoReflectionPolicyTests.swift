import XCTest
import CoreGraphics
@testable import HorizonCore

final class VideoReflectionPolicyTests: XCTestCase {
    func testEligibilityRequiresTabletopAndAllAccessibilityAndLifecycleConditions() {
        for mode in [FoldMode.flat, .book, .tabletop] {
            for foreground in [false, true] {
                for visible in [false, true] {
                    for reduceMotion in [false, true] {
                        for reduceTransparency in [false, true] {
                            XCTAssertEqual(VideoReflectionPolicy.isEligible(
                                foldMode: mode, foreground: foreground, visible: visible,
                                reduceMotion: reduceMotion, reduceTransparency: reduceTransparency
                            ), mode == .tabletop && foreground && visible && !reduceMotion && !reduceTransparency)
                        }
                    }
                }
            }
        }
    }

    func testSamplingNeverExceedsSixFramesPerSecond() {
        var gate = ReflectionSamplingGate()
        var accepted: [Double] = []
        for tick in 0..<600 {
            let time = Double(tick) / 120
            if gate.take(at: time) { accepted.append(time) }
        }
        XCTAssertFalse(accepted.isEmpty)
        XCTAssertLessThanOrEqual(accepted.count, 30)
        for (first, second) in zip(accepted, accepted.dropFirst()) {
            XCTAssertGreaterThanOrEqual(second - first, 1 / VideoReflectionPolicy.maximumFramesPerSecond)
        }
        XCTAssertFalse(gate.take(at: .nan))
        XCTAssertFalse(gate.take(at: .infinity))
        XCTAssertFalse(gate.take(at: -1))
    }

    func testDownsamplingIsBoundedPreservesAspectAndNeverUpscales() {
        XCTAssertEqual(VideoReflectionPolicy.downsampledSize(CGSize(width: 1920, height: 1080)),
                       CGSize(width: 320, height: 180))
        XCTAssertEqual(VideoReflectionPolicy.downsampledSize(CGSize(width: 1080, height: 1920)),
                       CGSize(width: 180, height: 320))
        XCTAssertEqual(VideoReflectionPolicy.downsampledSize(CGSize(width: 40, height: 20)),
                       CGSize(width: 40, height: 20))
        XCTAssertEqual(VideoReflectionPolicy.downsampledSize(CGSize(width: 10000, height: 1)),
                       CGSize(width: 320, height: 1))
        for size in [CGSize.zero, CGSize(width: -1, height: 10),
                     CGSize(width: CGFloat.infinity, height: 10), CGSize(width: 10, height: CGFloat.nan)] {
            XCTAssertNil(VideoReflectionPolicy.downsampledSize(size))
        }
    }
}
