import Foundation
import XCTest
@testable import HorizonCore

final class LiveHLSLocalRouteTests: XCTestCase {
    private func route() throws -> LiveHLSLocalRoute {
        LiveHLSLocalRoute(policy: try LiveHLSResourcePolicy(address: ServerAddress("https://example.com/base"), camera: "front"),
            port: 43210, credential: "synthetic-local-cookie")
    }

    private func request(_ target: String = "/live-hls/base/api/front/live/hls/720p/index.m3u8",
                         method: String = "GET", cookie: String = "HorizonLocalLive=synthetic-local-cookie",
                         extra: String = "") -> Data {
        Data("\(method) \(target) HTTP/1.1\r\nHost: 127.0.0.1:43210\r\nCookie: \(cookie)\r\n\(extra)\r\n".utf8)
    }

    func testOnlyCookieAuthenticatedLoopbackRequestsMapToRemoteHTTPS() throws {
        let route = try route()
        let parsed = try route.parse(request())
        XCTAssertEqual(parsed.url.absoluteString, "https://example.com/base/api/front/live/hls/720p/index.m3u8")
        XCTAssertFalse(parsed.head)
        let local = try route.localURL(parsed.url)
        XCTAssertEqual(local.host, "127.0.0.1")
        XCTAssertEqual(local.port, 43210)
        XCTAssertEqual(local.scheme, "http")
        XCTAssertFalse(local.absoluteString.contains("synthetic-local-cookie"))
        XCTAssertNil(local.query)
        XCTAssertThrowsError(try route.parse(request(cookie: "HorizonLocalLive=wrong")))
    }

    func testLoopbackIsNotAnOpenProxyOrCrossCameraRoute() throws {
        for target in [
            "https://attacker.invalid/segment.m4s",
            "/live-hls/base/api/garden/live/hls/segment.m4s",
            "/live-hls/base/api/front/live/hls/../../config",
            "/live-hls/base/api/front/live/hls/part.m4s?token=secret",
        ] {
            XCTAssertThrowsError(try route().parse(request(target)), target)
        }
    }

    func testHeadAndSingleByteRangesAreBounded() throws {
        let parsed = try route().parse(request("/live-hls/base/api/front/live/hls/720p/init.mp4",
            method: "HEAD", extra: "Range: bytes=4-7\r\n"))
        XCTAssertTrue(parsed.head)
        XCTAssertEqual(parsed.range?.offset, 4)
        XCTAssertEqual(parsed.range?.length, 4)
        for value in ["bytes=-5", "bytes=4-2", "bytes=0-999999999", "bytes=0-1,4-5"] {
            XCTAssertThrowsError(try route().parse(request(extra: "Range: \(value)\r\n")), value)
        }
    }

    func testHTTPMutationSmugglingAndDuplicateAuthorityAreRejected() throws {
        XCTAssertThrowsError(try route().parse(request(method: "POST")))
        XCTAssertThrowsError(try route().parse(request(extra: "Content-Length: 3\r\n")))
        XCTAssertThrowsError(try route().parse(request(extra: "Transfer-Encoding: chunked\r\n")))
        XCTAssertThrowsError(try route().parse(request(extra: "Host: attacker.invalid\r\n")))
        XCTAssertThrowsError(try route().parse(Data(repeating: 65, count: 16_385)))
    }
}
