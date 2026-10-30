import Foundation
import XCTest
@testable import HorizonCore

final class LiveHLSTests: XCTestCase {
    private func policy(_ root: String = "https://example.com/base") throws -> LiveHLSResourcePolicy {
        try LiveHLSResourcePolicy(address: ServerAddress(root), camera: "front")
    }

    private func status(_ replacement: String? = nil) throws -> LiveHLSStatus {
        let data = replacement.map { Data($0.utf8) } ?? LiveHLSFixtures.status
        return try JSONDecoder().decode(LiveHLSStatus.self, from: data)
    }

    func testLiveHLSUIFlagDefaultsFalseAndDecodesSnakeCase() throws {
        for ui in [#"{}"#, #"{"order":1,"dashboard":true}"#] {
            XCTAssertFalse(try JSONDecoder().decode(CameraUI.self, from: Data(ui.utf8)).liveHLS)
        }
        XCTAssertTrue(try JSONDecoder().decode(CameraUI.self, from: Data(#"{"live_hls":true}"#.utf8)).liveHLS)
    }

    func testProbeRequiresEnabledCameraOptInAutomaticAndHTTPSChoice() {
        XCTAssertTrue(LiveHLSGate.shouldProbe(cameraEnabled: true, optedIn: true, automatic: true, transport: "https"))
        XCTAssertFalse(LiveHLSGate.shouldProbe(cameraEnabled: false, optedIn: true, automatic: true, transport: "https"))
        XCTAssertFalse(LiveHLSGate.shouldProbe(cameraEnabled: true, optedIn: false, automatic: true, transport: "https"))
        XCTAssertFalse(LiveHLSGate.shouldProbe(cameraEnabled: true, optedIn: true, automatic: false, transport: "https"))
        XCTAssertFalse(LiveHLSGate.shouldProbe(cameraEnabled: true, optedIn: true, automatic: true, transport: "webrtc"))
    }

    func testStatusUsesVersionedContractWithoutTreatingTargetsAsBandwidth() throws {
        let status = try status()
        XCTAssertTrue(status.isAvailable)
        XCTAssertEqual(status.renditions.map(\.bitrate), [1200, 2500])
        let policy = try policy()
        let url = try policy.masterURL(status.playlist)
        let master = try LiveHLSMaster(text: LiveHLSFixtures.master, policy: policy, url: url)
        XCTAssertEqual(master.lowestBandwidth, 1_450_000)
        XCTAssertEqual(master.variants.map(\.bandwidth), [1_450_000, 2_850_000])
    }

    func testDisabledUnavailableAndUnknownVersionUseCompatibility() throws {
        for json in [
            #"{"version":1,"protocol":"ll-hls","enabled":false,"available":false}"#,
            #"{"version":1,"protocol":"ll-hls","enabled":true,"available":false}"#,
            #"{"version":2,"protocol":"future-hls"}"#,
            #"{"version":1,"protocol":"other"}"#,
        ] {
            XCTAssertFalse(try status(json).isAvailable)
        }
    }

    func testMalformedAvailableContractIsNotACompatibilitySuccess() {
        for json in [
            #"{"version":1,"protocol":"ll-hls","enabled":true,"available":true}"#,
            #"{"version":1,"protocol":"ll-hls","enabled":true,"available":true,"playlist":"front/live/hls/master.m3u8","renditions":[{"height":720,"bitrate":0}]}"#,
        ] {
            XCTAssertThrowsError(try status(json))
        }
    }

    func testOnlyUnsupportedHTTPResponsesPermitFallbackNotAuthenticationOrTLS() {
        for code in [404, 405, 410, 501] { XCTAssertTrue(LiveHLSGate.isUnsupportedHTTP(code)) }
        for code in [401, 403, 429, 500, 502, 503] { XCTAssertFalse(LiveHLSGate.isUnsupportedHTTP(code)) }
    }

    func testMasterPathIsRelativeToAPIBaseAndCameraScoped() throws {
        let policy = try policy()
        let master = try policy.masterURL("front/live/hls/master.m3u8")
        XCTAssertEqual(master.absoluteString, "https://example.com/base/api/front/live/hls/master.m3u8")
        XCTAssertThrowsError(try policy.masterURL("garden/live/hls/master.m3u8"))
        XCTAssertThrowsError(try policy.masterURL("front/live/hls/master.m3u8?token=secret"))
        XCTAssertThrowsError(try self.policy("http://example.com/base"))
    }

    func testEveryPlaylistAudioInitSegmentAndPartStaysInTheCameraRoot() throws {
        let policy = try policy()
        let master = try policy.masterURL("front/live/hls/master.m3u8")
        let child = try policy.resolve("720p/index.m3u8", relativeTo: master)
        for ref in ["audio/index.m3u8", "720p/init.mp4", "720p/segment-1.m4s", "720p/part-1.m4s", "720p/segment-1.ts"] {
            let url = try policy.resolve(ref, relativeTo: master)
            XCTAssertTrue(url.path.hasPrefix("/base/api/front/live/hls/"))
            XCTAssertEqual(try policy.networkURL(policy.assetURL(url)), url)
        }
        let rewrite = try policy.rewritePlaylist(LiveHLSFixtures.safeChild, url: child)
        XCTAssertTrue(rewrite.contains("horizon-hls://example.com/base/api/front/live/hls/720p/init.mp4"))
        XCTAssertTrue(rewrite.contains("horizon-hls://example.com/base/api/front/live/hls/720p/part-2.m4s"))
        XCTAssertTrue(rewrite.contains("horizon-hls://example.com/base/api/front/live/hls/1080p/index.m3u8"))
        XCTAssertNoThrow(try policy.rewritePlaylist(LiveHLSFixtures.child, url: child))
    }

    func testCredentialQueryOriginCameraAndTraversalEscapesAreRejected() throws {
        let policy = try policy()
        let master = try policy.masterURL("front/live/hls/master.m3u8")
        for ref in [
            "https://attacker.invalid/segment.m4s", "http://example.com/base/api/front/live/hls/segment.m4s",
            "https://user:password@example.com/base/api/front/live/hls/segment.m4s",
            "/base/api/garden/live/hls/segment.m4s", "/base/api/config",
            "../../config", "%2e%2e/config.m3u8", "%252e%252e/config.m3u8",
            "720p%2fother/index.m3u8", "720p\\index.m3u8", "segment.m4s?token=secret",
            "720p/index.m3u8?session=private", "720p/index.m3u8#fragment",
        ] {
            XCTAssertThrowsError(try policy.resolve(ref, relativeTo: master), ref)
        }
    }

    func testLLHLSReloadQueryAllowlistIsBoundedAndDuplicateFree() throws {
        let policy = try policy()
        let master = try policy.masterURL("front/live/hls/master.m3u8")
        XCTAssertNoThrow(try policy.resolve("720p/index.m3u8?_HLS_msn=12&_HLS_part=2&_HLS_skip=YES", relativeTo: master))
        for ref in [
            "720p/index.m3u8?_HLS_msn=-1", "720p/index.m3u8?_HLS_msn=1&_HLS_msn=2",
            "720p/index.m3u8?_HLS_skip=secret", "part.m4s?_HLS_msn=1",
        ] { XCTAssertThrowsError(try policy.resolve(ref, relativeTo: master)) }
    }

    func testMasterMaximumFiltersOnlyActualVariantsAndRetainsAudio() throws {
        let policy = try policy()
        let url = try policy.masterURL("front/live/hls/master.m3u8")
        let master = try LiveHLSMaster(text: LiveHLSFixtures.master, policy: policy, url: url, maximumHeight: 720)
        XCTAssertEqual(master.variants.map(\.height), [720])
        XCTAssertTrue(master.playlist.contains("TYPE=AUDIO"))
        XCTAssertFalse(master.playlist.contains("1080p/index.m3u8"))
        XCTAssertThrowsError(try LiveHLSMaster(text: LiveHLSFixtures.master, policy: policy, url: url, maximumHeight: 360))
    }

    func testCRLFMasterAndPlaylistHaveTheSameRenditions() throws {
        let policy = try policy()
        let url = try policy.masterURL("front/live/hls/master.m3u8")
        let master = try LiveHLSMaster(text: LiveHLSFixtures.master.replacingOccurrences(of: "\n", with: "\r\n"),
            policy: policy, url: url)
        XCTAssertEqual(master.variants.map(\.height), [720, 1080])
    }

    func testUnsafePlaylistURIAttributesAreNotLeftForAVPlayerToFetch() throws {
        let policy = try policy()
        let url = try policy.masterURL("front/live/hls/master.m3u8")
        for text in [
            LiveHLSFixtures.master.replacingOccurrences(of: "audio/index.m3u8", with: "https://attacker.invalid/audio.m3u8"),
            "#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI=\"secret.key\"\n",
            "#EXTM3U\n#EXT-X-CONTENT-STEERING:SERVER-URI=\"https://attacker.invalid/\"\n",
        ] { XCTAssertThrowsError(try policy.rewritePlaylist(text, url: url)) }
    }

    func testMalformedMasterDoesNotInventVariantsOrUseTargetKbps() throws {
        let policy = try policy()
        let url = try policy.masterURL("front/live/hls/master.m3u8")
        for text in [
            "<html>Sign in</html>", "#EXTM3U\n",
            "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=0,RESOLUTION=1280x720\n720p/index.m3u8\n",
            "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1200000\n720p/index.m3u8\n",
        ] { XCTAssertThrowsError(try LiveHLSMaster(text: text, policy: policy, url: url)) }
    }

    func testStartupCapRequiresDecodedVideoAndSustainedHealthyBuffer() {
        var state = LiveHLSStartupPolicy(lowestBandwidth: 1_450_000)
        XCTAssertEqual(state.preferredPeakBitRate, 1_450_000)
        state.observe(now: 0, decodedVideo: false, bufferedAhead: 3, playing: true, restrictedNetwork: false)
        state.observe(now: 20, decodedVideo: true, bufferedAhead: 0.2, playing: true, restrictedNetwork: false)
        XCTAssertFalse(state.released)
        state.observe(now: 21, decodedVideo: true, bufferedAhead: 1.5, playing: true, restrictedNetwork: false)
        state.observe(now: 23.9, decodedVideo: true, bufferedAhead: 1.5, playing: true, restrictedNetwork: false)
        XCTAssertFalse(state.released)
        state.observe(now: 24, decodedVideo: true, bufferedAhead: 1.5, playing: true, restrictedNetwork: false)
        XCTAssertTrue(state.released)
        XCTAssertEqual(state.preferredPeakBitRate, 0)
    }

    func testLowDataModeRetainsOrReappliesLowestCapWithoutReplacingPlayer() {
        var state = LiveHLSStartupPolicy(lowestBandwidth: 1_450_000)
        state.observe(now: 0, decodedVideo: true, bufferedAhead: 2, playing: true, restrictedNetwork: false)
        state.observe(now: 3, decodedVideo: true, bufferedAhead: 2, playing: true, restrictedNetwork: false)
        XCTAssertTrue(state.released)
        state.observe(now: 4, decodedVideo: true, bufferedAhead: 2, playing: true, restrictedNetwork: true)
        XCTAssertEqual(state.preferredPeakBitRate, 1_450_000)
        state.observe(now: 30, decodedVideo: true, bufferedAhead: 2, playing: true, restrictedNetwork: true)
        XCTAssertFalse(state.released)
    }

    func testStallAndInvalidClockResetHealthyStartupWindow() {
        var state = LiveHLSStartupPolicy(lowestBandwidth: 100)
        state.observe(now: 0, decodedVideo: true, bufferedAhead: 2, playing: true, restrictedNetwork: false)
        state.observe(now: 2, decodedVideo: true, bufferedAhead: 2, playing: false, restrictedNetwork: false)
        state.observe(now: 3, decodedVideo: true, bufferedAhead: .nan, playing: true, restrictedNetwork: false)
        state.observe(now: 4, decodedVideo: true, bufferedAhead: 2, playing: true, restrictedNetwork: false)
        state.observe(now: 6.9, decodedVideo: true, bufferedAhead: 2, playing: true, restrictedNetwork: false)
        XCTAssertFalse(state.released)
    }

    func testExistingPiPOwnershipPolicyAppliesWithoutBackgroundAutoplay() {
        XCTAssertFalse(LivePiPPlaybackPolicy.mayKeepPlaying(accountAuthorized: true, cameraEnabled: true,
            hasStream: true, foreground: false, visible: false, active: false, pictureInPictureActive: false))
        XCTAssertTrue(LivePiPPlaybackPolicy.mayKeepPlaying(accountAuthorized: true, cameraEnabled: true,
            hasStream: true, foreground: false, visible: false, active: false, pictureInPictureActive: true))
        XCTAssertFalse(LivePiPPlaybackPolicy.mayKeepPlaying(accountAuthorized: false, cameraEnabled: true,
            hasStream: true, foreground: false, visible: false, active: false, pictureInPictureActive: true))
    }
}
