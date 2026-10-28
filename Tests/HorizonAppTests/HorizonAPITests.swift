import XCTest
@testable import FrigateHorizon
import HorizonCore

final class HorizonAPITests: XCTestCase {
    private var api: HorizonAPI!

    override func setUpWithError() throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        api = HorizonAPI(
            address: try ServerAddress("https://horizon.invalid/base"), configuration: configuration
        )
    }

    override func tearDown() {
        api.close()
        api = nil
        MockURLProtocol.handler = nil
    }

    func testSessionsUseEphemeralCookieStorage() throws {
        XCTAssertNil(api.session.configuration.urlCache)
        XCTAssertNotNil(api.session.configuration.httpCookieStorage)
        XCTAssertEqual(api.session.configuration.httpAdditionalHeaders?["X-CSRF-TOKEN"] as? String, "1")
    }

    @MainActor
    func testExportTrackingDoesNotLoseOtherQueuedJobs() {
        let model = AppModel()
        model.trackExport("job-1")
        model.trackExport("job-1")
        model.trackExport("job-2")
        XCTAssertEqual(model.pendingExportIDs, ["job-1", "job-2"])
        model.finishExport("job-1")
        XCTAssertEqual(model.pendingExportIDs, ["job-2"])
        model.finishExport("missing-job")
        XCTAssertEqual(model.pendingExportIDs, ["job-2"])
    }

    func testBookmarkDeletionSendsRevisionAndAcceptsNoContent() async throws {
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "DELETE")
            XCTAssertEqual(request.url?.path, "/base/api/front/recordings/bookmarks/note-1")
            let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
            XCTAssertEqual(components.queryItems, [URLQueryItem(name: "revision", value: "4")])
            return (204, "application/json", Data())
        }
        try await api.deleteBookmark(camera: "front", id: "note-1", revision: 4)
    }

    func testBookmarkRevisionConflictIsNotConvertedToSuccess() async throws {
        MockURLProtocol.handler = { _ in
            (409, "application/json", Data(#"{"detail":"Bookmark changed; refresh before deleting"}"#.utf8))
        }
        do {
            try await api.deleteBookmark(camera: "front", id: "note-1", revision: 4)
            XCTFail("Stale bookmark deletion must fail explicitly")
        } catch { XCTAssertTrue(error.localizedDescription.contains("Bookmark changed")) }
    }

    func testConfigurationSaveUsesPlainTextAndExplicitSaveMode() async throws {
        let config = "mqtt:\n  enabled: false\n"
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/base/api/config/save")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "text/plain")
            let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
            XCTAssertEqual(components.queryItems, [URLQueryItem(name: "save_option", value: "saveonly")])
            XCTAssertEqual(String(data: try XCTUnwrap(requestBody(request)), encoding: .utf8), config)
            return (200, "application/json", Data(#"{"success":true,"message":"Configuration saved."}"#.utf8))
        }
        let result = try await api.saveConfiguration(config, restart: false)
        XCTAssertEqual(result.message, "Configuration saved.")
    }

    func testRawConfigurationDecodesTheServersQuotedPlainTextBody() async throws {
        MockURLProtocol.handler = { _ in
            (200, "text/plain", Data(#""mqtt:\n  enabled: false\n""#.utf8))
        }
        let result = try await api.text(["config", "raw"])
        XCTAssertEqual(result, "mqtt:\n  enabled: false\n")
    }

    func testRejectedMutationAndServerErrorMessagesAreSurfaced() async throws {
        MockURLProtocol.handler = { _ in
            (200, "application/json", Data(#"{"success":false,"message":"Cannot delete protected event"}"#.utf8))
        }
        do {
            try await api.action(["events", "test"], method: "DELETE", body: [String: String]())
            XCTFail("A success-shaped HTTP response must not hide a rejected action")
        } catch { XCTAssertTrue(error.localizedDescription.contains("Cannot delete protected event")) }
        MockURLProtocol.handler = { _ in
            (409, "application/json", Data(#"{"success":false,"message":"Another export uses this name"}"#.utf8))
        }
        do {
            try await api.action(["export", "test", "rename"], method: "PATCH", body: ["name": "Duplicate"])
            XCTFail("A server conflict must not be hidden")
        } catch { XCTAssertTrue(error.localizedDescription.contains("Another export uses this name")) }
    }

    func testDownloadCannotSendSessionToAnotherOrigin() async throws {
        do {
            _ = try await api.download(URL(string: "https://other.invalid/export.mp4")!, fileExtension: "mp4")
            XCTFail("Cross-origin downloads must be rejected before starting a transfer")
        } catch HorizonError.invalidMediaPath {
        } catch { XCTFail("Unexpected error: \(error)") }
    }

    func testExportRenameAndUnprotectionUseExactMutationContracts() async throws {
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "PATCH")
            XCTAssertEqual(request.url?.path, "/base/api/export/job-1/rename")
            let bytes = try XCTUnwrap(requestBody(request))
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: String])
            XCTAssertEqual(body, ["name": "Front door"])
            return (200, "application/json", Data(#"{"success":true}"#.utf8))
        }
        try await api.action(["export", "job-1", "rename"], method: "PATCH", body: ["name": "Front door"])
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "DELETE")
            let bytes = try XCTUnwrap(requestBody(request))
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Bool])
            XCTAssertEqual(body, ["confirm": true, "acknowledge_retention": true])
            return (200, "application/json", Data(#"{"success":true}"#.utf8))
        }
        try await api.action(["events", "event-1", "retain"], method: "DELETE",
            body: ["confirm": true, "acknowledge_retention": true])
    }

    @MainActor
    func testRecordingStopClearsErrorsAndBusyState() {
        let playback = RecordingPlayer()
        playback.seek(to: .nan)
        XCTAssertNotNil(playback.error)
        playback.stop()
        XCTAssertNil(playback.error)
        XCTAssertFalse(playback.loading)
        XCTAssertFalse(playback.isSeeking)
        playback.seek(to: 5)
        XCTAssertEqual(playback.error, "No recording is loaded for seeking.")
        playback.stop()
    }

    @MainActor
    func testCameraSwitchKeepsFrozenReviewRangeAndPausedIntent() async throws {
        MockURLProtocol.handler = { request in
            let path = try XCTUnwrap(request.url?.path)
            if path.hasSuffix("/recordings/coverage") {
                return (200, "application/json", Data(#"{"spans":[],"timelines":{"auto":[]}}"#.utf8))
            }
            return (200, "application/json", Data("[]".utf8))
        }
        let day = Calendar.current.startOfDay(for: Date()).addingTimeInterval(-86400)
        let store = ReviewPlaybackStore()
        defer { store.stop() }
        let timestamp = day.timeIntervalSince1970 + 60
        await store.prepare(api: api, camera: "front", day: day, timestamp: timestamp, autoplay: false)
        let range = try XCTUnwrap(store.range)
        XCTAssertFalse(store.intendsToPlay)
        XCTAssertTrue(store.missingRecording)
        await store.prepare(api: api, camera: "garden", day: day, timestamp: timestamp, autoplay: false)
        XCTAssertEqual(store.range, range)
        XCTAssertFalse(store.intendsToPlay)
        XCTAssertNil(store.error)
    }

    @MainActor
    func testReviewMetadataFailuresRemainSeparateFromKnownRecordingGaps() async throws {
        MockURLProtocol.handler = { request in
            let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
            if components.path.hasSuffix("/recordings/coverage"),
               components.queryItems?.contains(URLQueryItem(name: "timelines", value: "true")) == true {
                return (200, "application/json", Data(#"{"spans":[],"timelines":{"auto":[]}}"#.utf8))
            }
            return (503, "application/json", Data())
        }
        let day = Calendar.current.startOfDay(for: Date()).addingTimeInterval(-86400)
        let store = ReviewPlaybackStore()
        defer { store.stop() }
        await store.prepare(api: api, camera: "front", day: day, timestamp: day.timeIntervalSince1970 + 60)
        XCTAssertNil(store.coverage, "A failed day-coverage request must not become confirmed empty coverage.")
        XCTAssertTrue(store.missingRecording, "The successful clip-coverage response independently confirms the selected gap.")
        XCTAssertEqual(store.metadataErrors.count, 3)
        XCTAssertTrue(store.metadataError?.contains("Recording coverage:") == true)
        XCTAssertTrue(store.metadataError?.contains("Motion timeline:") == true)
        XCTAssertTrue(store.metadataError?.contains("Activity timeline:") == true)
    }

    func testBundledVideoLibraryHasPrivacyPurposeStrings() throws {
        let bundle = Bundle(for: AppModel.self)
        for key in ["NSCameraUsageDescription", "NSMicrophoneUsageDescription", "NSLocalNetworkUsageDescription"] {
            let description = try XCTUnwrap(
                bundle.object(forInfoDictionaryKey: key) as? String,
                "The built app must declare \(key) for App Store processing."
            )
            XCTAssertFalse(description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, key)
            XCTAssertFalse(description.contains("$("), "Unexpanded purpose string for \(key)")
        }
    }

    func testSavedCookiesAreScopedAndExpiredCookiesAreExcluded() throws {
        let cookie = try XCTUnwrap(HTTPCookie(properties: [
            .name: "frigate_token", .value: "test-only", .domain: "horizon.invalid",
            .path: "/", .secure: "TRUE", .expires: Date().addingTimeInterval(60),
        ]))
        let saved = SavedSession.SavedCookie(cookie)
        XCTAssertNotNil(saved.restore(for: api.address))
        XCTAssertNil(saved.restore(for: try ServerAddress("https://other.invalid")))
        let expired = try XCTUnwrap(HTTPCookie(properties: [
            .name: "expired", .value: "test-only", .domain: "horizon.invalid",
            .path: "/", .expires: Date().addingTimeInterval(-60),
        ]))
        XCTAssertNil(SavedSession.SavedCookie(expired).restore(for: api.address))
    }

    func testReviewQueryUsesCalendarDayAndServerCategories() {
        var query = ReviewQuery()
        query.camera = "front"
        query.severity = "detection"
        let items = Dictionary(uniqueKeysWithValues: query.items.map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(items["cameras"], "front")
        XCTAssertEqual(items["severity"], "detection")
        XCTAssertEqual(items["limit"], "100")
        let expected = Calendar.current.date(byAdding: .day, value: 1, to: query.day)!
        XCTAssertEqual(items["before"], String(expected.timeIntervalSince1970))
    }

    func testLoginUsesFrigateFieldNamesAndAcceptsEmptySuccessBody() async throws {
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/base/api/login")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            let body = try XCTUnwrap(requestBody(request))
            let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
            XCTAssertEqual(fields, ["user": "viewer", "password": "test-only"])
            return (200, "application/json", Data())
        }
        try await api.login(user: "viewer", password: "test-only")
    }

    func testUnauthorizedResponseIsExplicit() async throws {
        MockURLProtocol.handler = { _ in (401, "application/json", Data()) }
        do {
            let _: UserProfile = try await api.get(["profile"])
            XCTFail("An unauthorized response must not return a profile")
        } catch HorizonError.unauthorized {
        } catch {
            XCTFail("Wrong error: \(error)")
        }
    }

    func testProxyHTMLIsNotTreatedAsAPISuccess() async throws {
        MockURLProtocol.handler = { _ in (200, "text/html", Data("<html>Sign in</html>".utf8)) }
        do {
            let _: UserProfile = try await api.get(["profile"])
            XCTFail("HTML must not be accepted as an API response")
        } catch HorizonError.unexpectedResponse {
        } catch {
            XCTFail("Wrong error: \(error)")
        }
    }

    func testReviewedMutationMatchesServerContract() async throws {
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/base/api/reviews/viewed")
            XCTAssertEqual(request.httpMethod, "POST")
            let body = try XCTUnwrap(requestBody(request))
            let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(fields["ids"] as? [String], ["review-123"])
            XCTAssertEqual(fields["reviewed"] as? Bool, true)
            return (200, "application/json", Data(#"{"success":true,"message":"Reviewed"}"#.utf8))
        }
        try await api.markReviewed("review-123", reviewed: true)
    }

    func testImageCannotSendSessionToAnotherOrigin() async throws {
        MockURLProtocol.handler = { _ in
            XCTFail("Cross-origin media must be rejected before making a request")
            return (200, "image/jpeg", Data())
        }
        do {
            _ = try await api.image(URL(string: "https://other.invalid/image.jpg")!)
            XCTFail("Cross-origin media must be rejected")
        } catch HorizonError.invalidMediaPath {
        } catch {
            XCTFail("Wrong error: \(error)")
        }
    }
}

private func requestBody(_ request: URLRequest) -> Data? {
    if let body = request.httpBody { return body }
    guard let stream = request.httpBodyStream else { return nil }
    stream.open()
    defer { stream.close() }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 1024)
    while stream.hasBytesAvailable {
        let count = stream.read(&buffer, maxLength: buffer.count)
        guard count > 0 else { break }
        data.append(contentsOf: buffer.prefix(count))
    }
    return data
}

private final class MockURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, String, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let handler = try XCTUnwrap(Self.handler)
            let (status, type, body) = try handler(request)
            let response = try XCTUnwrap(HTTPURLResponse(
                url: try XCTUnwrap(request.url), statusCode: status,
                httpVersion: nil, headerFields: ["Content-Type": type]
            ))
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
