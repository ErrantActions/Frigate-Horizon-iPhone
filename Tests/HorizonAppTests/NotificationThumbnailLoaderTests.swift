import XCTest
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import HorizonCore
@testable import FrigateHorizon

final class NotificationThumbnailLoaderTests: XCTestCase {
    override func tearDown() {
        ThumbnailURLProtocol.setHandler(nil)
        super.tearDown()
    }

    func testEventUsesOnlyProtectedInstallationScopedImageService() async throws {
        let saved = try session()
        let state = ThumbnailTestState(session: saved)
        let png = try image()
        install(state: state, image: png)
        let data = try await loader().load(route: route(.event), session: saved, currentSession: { state.current() })
        XCTAssertEqual(state.paths(), [
            "/base/api/notifications/apns", "/base/api/profile",
            "/base/api/notifications/apns/thumbnail/00112233-4455-6677-8899-aabbccddeeff/event/event-1",
        ])
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let type = try XCTUnwrap(CGImageSourceGetType(source))
        XCTAssertEqual(type as String, UTType.jpeg.identifier)
        XCTAssertLessThanOrEqual(data.count, NotificationThumbnailLoader.maximumResponseBytes)
    }

    func testCameraUsesLatestPreviewOnlyAfterBothPermissionLists() async throws {
        let saved = try session()
        let state = ThumbnailTestState(session: saved)
        install(state: state, image: try image())
        _ = try await loader().load(route: route(.camera), session: saved, currentSession: { state.current() })
        XCTAssertEqual(state.paths().last,
            "/base/api/notifications/apns/thumbnail/00112233-4455-6677-8899-aabbccddeeff/camera/front")
    }

    func testFreshCameraPermissionsCanRevokeSavedPermission() async throws {
        let saved = try session()
        let state = ThumbnailTestState(session: saved)
        install(state: state, image: try image(), profile: #"{"username":"owner","role":"admin","allowed_cameras":["other"]}"#)
        await expect(.permissionDenied) {
            try await self.loader().load(route: self.route(.camera), session: saved, currentSession: { state.current() })
        }
        XCTAssertEqual(state.paths().count, 2)
    }

    func testSavedCameraPermissionsCannotBeExpandedByFreshProfile() async throws {
        let saved = try session(cameras: ["other"])
        let state = ThumbnailTestState(session: saved)
        install(state: state, image: try image())
        await expect(.permissionDenied) {
            try await self.loader().load(route: self.route(.camera), session: saved, currentSession: { state.current() })
        }
        XCTAssertEqual(state.paths().count, 2)
    }

    func testChangedAccountAndRegistrationNeverRequestMetadataOrMedia() async throws {
        let saved = try session()
        let state = ThumbnailTestState(session: saved)
        install(state: state, image: try image(), profile: #"{"username":"different","role":"admin","allowed_cameras":["front"]}"#)
        await expect(.accountMismatch) {
            try await self.loader().load(route: self.route(.event), session: saved, currentSession: { state.current() })
        }
        XCTAssertEqual(state.paths().count, 2)
        ThumbnailURLProtocol.setHandler { _ in
            .json(#"{"enabled":true,"server_id":"server-1","topic":"another.topic"}"#)
        }
        await expect(.registrationMismatch) {
            try await self.loader().load(route: self.route(.event), session: saved, currentSession: { saved })
        }
    }

    func testGenerationChangeAndLogoutDuringMediaTransferRejectImage() async throws {
        for replacement in [try session(), nil] as [NotificationImageSession?] {
            let saved = try session()
            let state = ThumbnailTestState(session: saved)
            let png = try image()
            install(state: state, image: png, onImage: { state.replace(replacement) })
            await expect(.sessionChanged) {
                try await self.loader().load(route: self.route(.event), session: saved, currentSession: { state.current() })
            }
        }
    }

    func testOptOutAndTestNotificationMakeNoRequests() async throws {
        let enabled = try session()
        let encoded = try JSONEncoder().encode(enabled)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["imagesEnabled"] = false
        let disabled = try JSONDecoder().decode(
            NotificationImageSession.self, from: JSONSerialization.data(withJSONObject: object)
        )
        ThumbnailURLProtocol.setHandler { _ in XCTFail("No network request permitted"); return .json("{}") }
        await expect(.imagesDisabled) {
            try await self.loader().load(route: self.route(.camera), session: disabled, currentSession: { disabled })
        }
        await expect(.unsupportedKind) {
            try await self.loader().load(route: self.route(.test), session: enabled, currentSession: { enabled })
        }
        XCTAssertFalse(NotificationThumbnailLoader.isCurrent(enabled, disabled))
    }

    func testReviewUsesTheProtectedIDBasedRouteRatherThanLegacyMediaPaths() async throws {
        let saved = try session()
        let state = ThumbnailTestState(session: saved)
        install(state: state, image: try image())
        _ = try await loader().load(route: route(.review), session: saved, currentSession: { state.current() })
        XCTAssertEqual(state.paths().last,
            "/base/api/notifications/apns/thumbnail/00112233-4455-6677-8899-aabbccddeeff/review/review-1")
    }

    func testMissingOrUnapprovedCameraHeaderNeverAttaches() async throws {
        let saved = try session()
        for header in ["other", nil] as [String?] {
            let state = ThumbnailTestState(session: saved)
            install(state: state, image: try image(), cameraHeader: header)
            await expect(.permissionDenied) {
                try await self.loader().load(route: self.route(.event), session: saved, currentSession: { state.current() })
            }
            XCTAssertEqual(state.paths().count, 3)
        }
    }

    func testProtectedServiceCanDenyAnOldAdminJwtWithoutAnyImageDelivery() async throws {
        let saved = try session()
        let state = ThumbnailTestState(session: saved)
        install(state: state, image: try image(), imageStatus: 403)
        await expect(.authentication) {
            try await self.loader().load(route: self.route(.event), session: saved, currentSession: { state.current() })
        }
        XCTAssertEqual(state.paths().count, 3)
    }

    func testTextOnlyBackendCannotFallBackToLegacyThumbnailRequests() async throws {
        let saved = try session()
        ThumbnailURLProtocol.setHandler { request in
            XCTAssertEqual(request.url?.path, "/base/api/notifications/apns")
            return .json(#"{"enabled":true,"server_id":"server-1","topic":"com.errantactions.frigatehorizon"}"#)
        }
        await expect(.imageServiceUnavailable) {
            try await self.loader().load(route: self.route(.event), session: saved, currentSession: { saved })
        }
    }

    func testUnauthorizedNonSuccessAndRedirectResponsesFailClosed() async throws {
        let saved = try session()
        for (status, failure) in [
            (401, NotificationThumbnailFailure.authentication),
            (403, .authentication), (500, .httpFailure), (302, .redirectRejected),
        ] {
            ThumbnailURLProtocol.setHandler { _ in ThumbnailStub(status: status, mime: "application/json", data: Data()) }
            await expect(failure) {
                try await self.loader().load(route: self.route(.camera), session: saved, currentSession: { saved })
            }
        }
    }

    func testDeclaredAndStreamedOversizeBodiesAreRejected() async throws {
        let saved = try session()
        for declared in [true, false] {
            let state = ThumbnailTestState(session: saved)
            let oversized = Data(repeating: 0, count: NotificationThumbnailLoader.maximumResponseBytes + 1)
            install(state: state, image: oversized, declaredLength: declared)
            await expect(.responseTooLarge) {
                try await self.loader().load(route: self.route(.camera), session: saved, currentSession: { state.current() })
            }
        }
    }

    func testImageMIMEActualTypeAndPixelBoundsAreValidated() throws {
        let png = try image()
        XCTAssertThrowsError(try NotificationThumbnailLoader.makeJPEG(png, mime: "image/jpeg"))
        XCTAssertThrowsError(try NotificationThumbnailLoader.makeJPEG(png, mime: "image/svg+xml"))
        XCTAssertThrowsError(try NotificationThumbnailLoader.makeJPEG(Data("not an image".utf8), mime: "image/png"))
        let large = try image(width: 8_193, height: 1)
        XCTAssertThrowsError(try NotificationThumbnailLoader.makeJPEG(large, mime: "image/png")) {
            XCTAssertEqual($0 as? NotificationThumbnailFailure, .imageDimensions)
        }
        let jpeg = try NotificationThumbnailLoader.makeJPEG(try image(width: 2_000, height: 1_000), mime: "image/png")
        let source = try XCTUnwrap(CGImageSourceCreateWithData(jpeg as CFData, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertEqual((properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue, 1_024)
        XCTAssertEqual((properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue, 512)
    }

    func testWrongImageMIMEIsRejectedBeforeDecode() async throws {
        let saved = try session()
        let state = ThumbnailTestState(session: saved)
        install(state: state, image: try image(), mime: "text/html")
        await expect(.invalidMIME) {
            try await self.loader().load(route: self.route(.camera), session: saved, currentSession: { state.current() })
        }
    }

    func testCancellationAndInternalDeadlineEndStalledRequest() async throws {
        let saved = try session()
        let started = expectation(description: "Request started")
        ThumbnailURLProtocol.setHandler { _ in
            started.fulfill()
            return ThumbnailStub(status: 200, mime: "application/json", data: Data(), stalls: true)
        }
        let client = loader()
        let requestRoute = route(.camera)
        let work = Task { try await client.load(route: requestRoute, session: saved, currentSession: { saved }) }
        await fulfillment(of: [started], timeout: 2)
        work.cancel()
        await expect(.cancelled) { try await work.value }
        ThumbnailURLProtocol.setHandler { _ in
            ThumbnailStub(status: 200, mime: "application/json", data: Data(), stalls: true)
        }
        do {
            _ = try await loader(budget: 0.05).load(route: route(.camera), session: saved, currentSession: { saved })
            XCTFail("A stalled request must expire")
        } catch let failure as NotificationThumbnailFailure {
            XCTAssertTrue([.deadline, .cancelled].contains(failure))
        }
    }

    private func loader(budget: TimeInterval = 15) -> NotificationThumbnailLoader {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ThumbnailURLProtocol.self]
        return NotificationThumbnailLoader(configuration: configuration, budget: budget)
    }

    private func session(cameras: [String] = ["front"]) throws -> NotificationImageSession {
        let cookie = try XCTUnwrap(HTTPCookie(properties: [
            .name: "frigate_token", .value: "test-only", .domain: "horizon.invalid", .path: "/", .secure: "TRUE",
        ]))
        return try NotificationImageSession(
            installationID: "00112233-4455-6677-8899-aabbccddeeff",
            serverID: "server-1", topic: "com.errantactions.frigatehorizon", username: "owner",
            allowedCameraIDs: cameras,
            session: SavedSession(server: "https://horizon.invalid/base", cookies: [.init(cookie)])
        )
    }

    private func route(_ kind: NativePushKind) -> NativeNotificationRoute {
        let identifier = kind == .camera ? "front" : kind == .review ? "review-1" : "event-1"
        return NativeNotificationRoute(userInfo: [
            "server_id": "server-1", "kind": kind.rawValue, "identifier": identifier,
        ])!
    }

    private func install(
        state: ThumbnailTestState, image: Data,
        profile: String = #"{"username":"owner","role":"admin","allowed_cameras":["front"]}"#,
        mime: String = "image/png", declaredLength: Bool = false,
        cameraHeader: String? = "front", imageStatus: Int = 200,
        onImage: (() -> Void)? = nil
    ) {
        ThumbnailURLProtocol.setHandler { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.scheme, "https")
            XCTAssertEqual(request.url?.host, "horizon.invalid")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            let path = request.url?.path ?? ""
            state.record(path)
            switch path {
            case "/base/api/notifications/apns":
                return .json(#"{"enabled":true,"server_id":"server-1","topic":"com.errantactions.frigatehorizon","image_notifications":true}"#)
            case "/base/api/profile":
                return .json(profile)
            case "/base/api/notifications/apns/thumbnail/00112233-4455-6677-8899-aabbccddeeff/event/event-1",
                 "/base/api/notifications/apns/thumbnail/00112233-4455-6677-8899-aabbccddeeff/review/review-1",
                 "/base/api/notifications/apns/thumbnail/00112233-4455-6677-8899-aabbccddeeff/camera/front":
                let components = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
                XCTAssertEqual(components?.queryItems, [URLQueryItem(name: "height", value: "360")])
                onImage?()
                return ThumbnailStub(status: imageStatus, mime: mime, data: image,
                    declaredLength: declaredLength, cameraHeader: cameraHeader)
            default:
                XCTFail("Unexpected request")
                return ThumbnailStub(status: 404, mime: "application/json", data: Data())
            }
        }
    }

    private func image(width: Int = 4, height: Int = 2) throws -> Data {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(
            data as CFMutableData, UTType.png.identifier as CFString, 1, nil
        ))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func expect(
        _ failure: NotificationThumbnailFailure, file: StaticString = #filePath, line: UInt = #line,
        operation: () async throws -> Data
    ) async {
        do {
            _ = try await operation()
            XCTFail("Expected safe thumbnail fallback", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? NotificationThumbnailFailure, failure, file: file, line: line)
        }
    }
}

private struct ThumbnailStub {
    var status: Int
    var mime: String
    var data: Data
    var declaredLength = false
    var stalls = false
    var cameraHeader: String? = "front"

    static func json(_ value: String) -> Self {
        Self(status: 200, mime: "application/json", data: Data(value.utf8))
    }
}

private final class ThumbnailURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var handler: ((URLRequest) throws -> ThumbnailStub)?

    static func setHandler(_ value: ((URLRequest) throws -> ThumbnailStub)?) {
        lock.lock()
        handler = value
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        Self.lock.lock()
        let handler = Self.handler
        Self.lock.unlock()
        do {
            guard let handler else { throw URLError(.resourceUnavailable) }
            let stub = try handler(request)
            if stub.stalls { return }
            var headers = ["Content-Type": stub.mime]
            if let camera = stub.cameraHeader { headers["X-Frigate-Camera"] = camera }
            if stub.declaredLength { headers["Content-Length"] = String(stub.data.count) }
            guard let url = request.url, let response = HTTPURLResponse(
                url: url, statusCode: stub.status, httpVersion: "HTTP/1.1", headerFields: headers
            ) else { throw URLError(.badServerResponse) }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            // Separate chunks exercise the stream limit without relying on Content-Length.
            let chunkSize = 16_384
            for offset in stride(from: 0, to: stub.data.count, by: chunkSize) {
                client?.urlProtocol(self, didLoad: stub.data.subdata(in: offset..<min(offset + chunkSize, stub.data.count)))
            }
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
}

// Synchronous access is needed by the injected current-session closure; all state is lock-protected.
private final class ThumbnailTestState: @unchecked Sendable {
    private let lock = NSLock()
    private var saved: NotificationImageSession?
    private var requests: [String] = []

    init(session: NotificationImageSession) { saved = session }
    func current() -> NotificationImageSession? {
        lock.lock()
        defer { lock.unlock() }
        return saved
    }
    func replace(_ session: NotificationImageSession?) {
        lock.lock()
        saved = session
        lock.unlock()
    }
    func record(_ path: String) {
        lock.lock()
        requests.append(path)
        lock.unlock()
    }
    func paths() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }
}
