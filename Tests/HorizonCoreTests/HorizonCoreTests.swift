import XCTest
import CoreGraphics
@testable import HorizonCore

final class HorizonCoreTests: XCTestCase {
    func testAddressPreservesProxyBaseAndEncodesStreamQuery() throws {
        let server = try ServerAddress("https://example.com:8971/frigate/")
        XCTAssertEqual(server.endpoint(["api", "profile"]).absoluteString, "https://example.com:8971/frigate/api/profile")
        let parts = URLComponents(url: server.webSocket(stream: "Front & Garden"), resolvingAgainstBaseURL: false)!
        XCTAssertEqual(parts.scheme, "wss")
        XCTAssertEqual(parts.path, "/frigate/live/webrtc/api/ws")
        XCTAssertEqual(parts.queryItems?.first?.value, "Front & Garden")
    }

    func testRejectsInvalidOrCredentialBearingAddresses() {
        for value in [
            "example.com", "ftp://example.com", "https://user:secret@example.com",
            "https://example.com?token=secret", "https://example.com/#fragment",
            "https://example.com/api/", "https://example.com/a/../b", "https://example.com:0",
        ] {
            XCTAssertThrowsError(try ServerAddress(value), value)
        }
    }

    func testRedirectOriginIncludesSchemeAndEffectivePort() throws {
        let server = try ServerAddress("https://example.com/frigate")
        XCTAssertTrue(server.hasSameOrigin(as: URL(string: "https://EXAMPLE.com:443/clips/video")!))
        XCTAssertFalse(server.hasSameOrigin(as: URL(string: "http://example.com/clips/video")!))
        XCTAssertFalse(server.hasSameOrigin(as: URL(string: "https://example.com:8971/clips/video")!))
        XCTAssertFalse(server.hasSameOrigin(as: URL(string: "https://other.example.com/clips/video")!))
    }

    func testThumbnailMappingDoesNotEscapeServer() throws {
        let server = try ServerAddress("https://example.com/frigate")
        XCTAssertEqual(
            try server.reviewThumbnail("/media/frigate/clips/review/thumb-front-123.webp").absoluteString,
            "https://example.com/frigate/clips/review/thumb-front-123.webp"
        )
        for value in [
            "https://other.example.com/image", "/media/frigate/clips/../secret",
            "/media/frigate/clips/%2e%2e/secret", "/media/frigate/recordings/a.mp4",
        ] {
            XCTAssertThrowsError(try server.reviewThumbnail(value))
        }
    }

    func testPlaybackUsesNginxHLSRootNotMappingAPI() throws {
        let server = try ServerAddress("https://example.com/frigate")
        XCTAssertEqual(
            try server.playback(camera: "front", start: 100, end: 200).path,
            "/frigate/vod/front/start/100.0/end/200.0/master.m3u8"
        )
        XCTAssertThrowsError(try server.playback(camera: "front", start: 100, end: 100))
        XCTAssertThrowsError(try server.playback(camera: "front", start: .nan, end: 200))
        XCTAssertThrowsError(try server.playback(camera: "front", start: 100, end: .infinity))
    }

    func testMainDerivedStreamsKeep720FloorAndDoNotPickSubstream() throws {
        let config = try decode(HorizonConfiguration.self, """
        {"cameras":{"front":{"friendly_name":"Front door","enabled":true,
        "live":{"streams":{"Sub":"front_sub","Main":"front_main","Low":"front_transcode_360p",
        "720p":"front_transcode_720p","1080p":"front_transcode_1080p"},
        "transcode":{"enabled":true,"source":"front_main","qualities":[{"height":360},{"height":720},{"height":1080}]}}}}}
        """)
        let camera = try XCTUnwrap(config.orderedCameras.first)
        XCTAssertEqual(camera.name, "Front door")
        XCTAssertEqual(camera.preferredStream(expanded: false), "front_transcode_720p")
        XCTAssertEqual(camera.preferredStream(expanded: true), "front_transcode_1080p")
    }

    func testMissingGeneratedStreamDoesNotInventOne() throws {
        let config = try decode(HorizonConfiguration.self, """
        {"cameras":{"front":{"enabled":true,"live":{"streams":{"Main":"front_main","Sub":"front_sub"},
        "transcode":{"enabled":true,"source":"front_main","qualities":[{"height":720}]}}}}}
        """)
        XCTAssertEqual(config.orderedCameras.first?.preferredStream(expanded: false), "front_main")
    }

    func testAmbiguousStreamsRequireExplicitSelection() throws {
        let config = try decode(HorizonConfiguration.self, """
        {"cameras":{"front":{"enabled":false,"live":{"streams":{"A":"alpha","B":"beta"}}}}}
        """)
        XCTAssertNil(config.orderedCameras.first?.preferredStream(expanded: false))
        XCTAssertEqual(config.orderedCameras.first?.settings.enabled, false)
    }

    func testReviewContractKeepsOngoingEventsOpenAndDoesNotRequireConfidence() throws {
        let ongoing = try decode(ReviewSegment.self, """
        {"id":"123","camera":"front","severity":"detection","start_time":100,"end_time":null,
        "thumb_path":"/media/frigate/clips/review/a.webp","has_been_reviewed":false,
        "data":{"objects":["vehicle"],"audio":[],"zones":[],"confidence":null}}
        """)
        XCTAssertEqual(ongoing.title, "Vehicle")
        XCTAssertFalse(ongoing.hasBeenReviewed)
        XCTAssertNil(ongoing.playbackRange(now: 200))
        let closed = try decode(ReviewSegment.self, """
        {"id":"124","camera":"front","severity":"alert","start_time":100,"end_time":150,
        "thumb_path":"/media/frigate/clips/review/a.webp","has_been_reviewed":true,
        "data":{"objects":["person","person"],"audio":[],"zones":[]}}
        """)
        XCTAssertEqual(closed.playbackRange(now: 200), 96...150)
        XCTAssertNil(closed.playbackRange(now: 120))
        XCTAssertEqual(closed.title, "Person")
    }

    func testRecordingWindowsMergeOverlapsButNeverBridgeGaps() throws {
        let segments = try decode([RecordingSegment].self, """
        [{"start_time":130,"end_time":140},{"start_time":90,"end_time":110},
        {"start_time":110,"end_time":120},{"start_time":115,"end_time":125},
        {"start_time":150,"end_time":149},{"start_time":180,"end_time":200}]
        """)
        XCTAssertEqual(
            RecordingWindow.available(segments, after: 100, before: 190),
            [
                RecordingWindow(start: 100, end: 125),
                RecordingWindow(start: 130, end: 140),
                RecordingWindow(start: 180, end: 190),
            ]
        )
    }

    func testFoldLayoutsUseActualActiveDivisionGeometry() {
        let bounds = CGRect(x: 0, y: 0, width: 800, height: 900)
        XCTAssertEqual(FoldMode.detect(activeDivisions: [], in: bounds), .flat)
        XCTAssertEqual(FoldMode.detect(
            activeDivisions: [CGRect(x: 0, y: 440, width: 800, height: 20)], in: bounds
        ), .tabletop)
        XCTAssertEqual(FoldMode.detect(
            activeDivisions: [CGRect(x: 390, y: 0, width: 20, height: 900)], in: bounds
        ), .book)
        XCTAssertEqual(FoldMode.detect(
            activeDivisions: [CGRect(x: 1000, y: 0, width: 20, height: 900)], in: bounds
        ), .flat)
        XCTAssertEqual(FoldMode.detect(
            activeDivisions: [CGRect(x: 0, y: 0, width: 0, height: 900)], in: bounds
        ), .flat)
    }

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }
}
