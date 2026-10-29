import Foundation
import HorizonCore
import ImageIO
import UniformTypeIdentifiers

enum NotificationThumbnailFailure: String, Error {
    case invalidPayload, missingSession, sessionUnavailable, sessionChanged, imagesDisabled
    case unsupportedKind, untrustedServer, registrationMismatch, imageServiceUnavailable, accountMismatch, permissionDenied
    case invalidMetadata, invalidMediaPath, redirectRejected, authentication, httpFailure
    case connectivity, responseTooLarge, invalidMIME, invalidImage, imageDimensions
    case deadline, cancelled, attachment, fileCleanup, unexpected
}

/// This downloader deliberately rejects even same-origin redirects, unlike the app's media client.
struct NotificationThumbnailLoader {
    static let maximumResponseBytes = 2 * 1_024 * 1_024
    static let maximumMetadataBytes = 256 * 1_024
    static let maximumThumbnailDimension = 1_024

    private let configuration: URLSessionConfiguration
    private let budget: TimeInterval

    init(configuration: URLSessionConfiguration = .ephemeral, budget: TimeInterval = 15) {
        self.configuration = configuration
        self.budget = budget.isFinite ? min(15, max(0.001, budget)) : 15
    }

    /// Only protocol classes are taken from the injected configuration; storage is always ephemeral.
    func load(
        route: NativeNotificationRoute,
        session saved: NotificationImageSession,
        currentSession: @escaping @Sendable () throws -> NotificationImageSession?
    ) async throws -> Data {
        do {
            try Task.checkCancellation()
            guard saved.imagesEnabled else { throw NotificationThumbnailFailure.imagesDisabled }
            guard saved.permits(route) else { throw NotificationThumbnailFailure.registrationMismatch }
            guard [.event, .review, .camera].contains(route.kind) else { throw NotificationThumbnailFailure.unsupportedKind }
            try Self.requireCurrent(saved, read: currentSession)
            let address: ServerAddress
            do { address = try saved.address() }
            catch { throw NotificationThumbnailFailure.untrustedServer }
            let cookies = saved.session.cookies.compactMap { $0.restore(for: address) }
            guard !cookies.isEmpty else { throw NotificationThumbnailFailure.missingSession }

            let safe = URLSessionConfiguration.ephemeral
            safe.protocolClasses = configuration.protocolClasses
            safe.urlCache = nil
            safe.urlCredentialStorage = nil
            safe.requestCachePolicy = .reloadIgnoringLocalCacheData
            safe.timeoutIntervalForRequest = budget
            safe.timeoutIntervalForResource = budget
            safe.httpShouldSetCookies = true
            safe.httpCookieAcceptPolicy = .always
            safe.httpAdditionalHeaders = ["Cache-Control": "no-cache", "Pragma": "no-cache"]
            if let storage = safe.httpCookieStorage {
                for cookie in storage.cookies ?? [] { storage.deleteCookie(cookie) }
                for cookie in cookies { storage.setCookie(cookie) }
            } else {
                throw NotificationThumbnailFailure.missingSession
            }
            let client = URLSession(configuration: safe, delegate: NoRedirects(), delegateQueue: nil)
            defer { client.invalidateAndCancel() }
            let deadline = ProcessInfo.processInfo.systemUptime + budget
            let timeoutNanoseconds = UInt64(budget * 1_000_000_000)
            return try await withTaskCancellationHandler(operation: {
                try await withThrowingTaskGroup(of: Data.self) { group in
                    group.addTask {
                        try await Self.fetch(
                            route: route, saved: saved, address: address, client: client,
                            deadline: deadline, currentSession: currentSession
                        )
                    }
                    group.addTask {
                        try await Task.sleep(nanoseconds: timeoutNanoseconds)
                        client.invalidateAndCancel()
                        throw NotificationThumbnailFailure.deadline
                    }
                    defer { group.cancelAll() }
                    guard let result = try await group.next() else {
                        throw NotificationThumbnailFailure.cancelled
                    }
                    return result
                }
            }, onCancel: {
                client.invalidateAndCancel()
            })
        } catch let failure as NotificationThumbnailFailure {
            throw failure
        } catch is CancellationError {
            throw NotificationThumbnailFailure.cancelled
        } catch let error as URLError {
            switch error.code {
            case .cancelled:
                throw NotificationThumbnailFailure.cancelled
            case .timedOut:
                throw NotificationThumbnailFailure.deadline
            default:
                throw NotificationThumbnailFailure.connectivity
            }
        } catch {
            throw NotificationThumbnailFailure.unexpected
        }
    }

    static func isCurrent(_ expected: NotificationImageSession, _ current: NotificationImageSession?) -> Bool {
        // Full equality also invalidates changed cookie or camera snapshots, not only a new generation.
        current == expected && expected.imagesEnabled
    }

    private static func requireCurrent(
        _ expected: NotificationImageSession,
        read: () throws -> NotificationImageSession?
    ) throws {
        let current: NotificationImageSession?
        do { current = try read() }
        catch { throw NotificationThumbnailFailure.sessionUnavailable }
        guard isCurrent(expected, current) else { throw NotificationThumbnailFailure.sessionChanged }
    }

    private static func checkBudget(_ deadline: TimeInterval) throws {
        try Task.checkCancellation()
        guard ProcessInfo.processInfo.systemUptime < deadline else {
            throw NotificationThumbnailFailure.deadline
        }
    }

    private static func fetch(
        route: NativeNotificationRoute, saved: NotificationImageSession, address: ServerAddress,
        client: URLSession, deadline: TimeInterval,
        currentSession: @escaping @Sendable () throws -> NotificationImageSession?
    ) async throws -> Data {
        let capabilities: NativePushCapabilities = try await metadata(
            address.endpoint(["api", "notifications", "apns"]),
            address: address, client: client, deadline: deadline
        )
        guard capabilities.enabled, capabilities.serverID == saved.serverID,
              capabilities.topic == saved.topic else {
            throw NotificationThumbnailFailure.registrationMismatch
        }
        guard capabilities.imageNotifications == true else { throw NotificationThumbnailFailure.imageServiceUnavailable }
        try requireCurrent(saved, read: currentSession)
        let profile: UserProfile = try await metadata(
            address.endpoint(["api", "profile"]), address: address, client: client, deadline: deadline
        )
        guard profile.username == saved.username else { throw NotificationThumbnailFailure.accountMismatch }
        let allowed = Set(profile.allowedCameras).intersection(saved.allowedCameraIDs)
        guard !allowed.isEmpty else { throw NotificationThumbnailFailure.permissionDenied }
        try requireCurrent(saved, read: currentSession)
        guard let identifier = route.identifier else { throw NotificationThumbnailFailure.invalidPayload }

        if route.kind == .camera {
            guard allowed.contains(identifier) else { throw NotificationThumbnailFailure.permissionDenied }
        }
        let imageURL: URL
        do { imageURL = try saved.thumbnailURL(for: route) }
        catch { throw NotificationThumbnailFailure.invalidMediaPath }
        try requireCurrent(saved, read: currentSession)
        // The backend must enforce current database role and installation scope on this request.
        // Legacy media APIs and /profile can retain a JWT's old role, so they are not an image gate.
        let (data, mime, cameraID) = try await response(
            imageURL, address: address, client: client, deadline: deadline,
            maximumBytes: maximumResponseBytes, image: true
        )
        guard let cameraID, allowed.contains(cameraID) else { throw NotificationThumbnailFailure.permissionDenied }
        try checkBudget(deadline)
        let jpeg = try makeJPEG(data, mime: mime)
        try checkBudget(deadline)
        try requireCurrent(saved, read: currentSession)
        return jpeg
    }

    private static func metadata<T: Decodable>(
        _ url: URL, address: ServerAddress, client: URLSession, deadline: TimeInterval
    ) async throws -> T {
        let (data, _, _) = try await response(
            url, address: address, client: client, deadline: deadline,
            maximumBytes: maximumMetadataBytes, image: false
        )
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw NotificationThumbnailFailure.invalidMetadata }
    }

    private static func response(
        _ url: URL, address: ServerAddress, client: URLSession, deadline: TimeInterval,
        maximumBytes: Int, image: Bool
    ) async throws -> (Data, String, String?) {
        try checkBudget(deadline)
        guard url.scheme == "https", address.hasSameOrigin(as: url) else {
            throw NotificationThumbnailFailure.untrustedServer
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = "GET"
        request.timeoutInterval = max(0.001, deadline - ProcessInfo.processInfo.systemUptime)
        request.setValue(image ? "image/jpeg, image/png, image/webp" : "application/json",
                         forHTTPHeaderField: "Accept")
        let (bytes, result) = try await client.bytes(for: request)
        guard let response = result as? HTTPURLResponse,
              response.url == url else { throw NotificationThumbnailFailure.httpFailure }
        if (300..<400).contains(response.statusCode) { throw NotificationThumbnailFailure.redirectRejected }
        if response.statusCode == 401 || response.statusCode == 403 {
            throw NotificationThumbnailFailure.authentication
        }
        guard (200..<300).contains(response.statusCode) else { throw NotificationThumbnailFailure.httpFailure }
        let mime = response.mimeType?.lowercased() ?? ""
        guard image ? ["image/jpeg", "image/png", "image/webp"].contains(mime) : mime == "application/json" else {
            throw NotificationThumbnailFailure.invalidMIME
        }
        guard response.expectedContentLength <= Int64(maximumBytes) else {
            throw NotificationThumbnailFailure.responseTooLarge
        }
        var data = Data()
        for try await byte in bytes {
            guard data.count < maximumBytes else { throw NotificationThumbnailFailure.responseTooLarge }
            data.append(byte)
            if data.count.isMultiple(of: 4_096) { try checkBudget(deadline) }
        }
        try checkBudget(deadline)
        return (data, mime, response.value(forHTTPHeaderField: "X-Frigate-Camera"))
    }

    static func makeJPEG(_ data: Data, mime: String) throws -> Data {
        guard data.count <= maximumResponseBytes else { throw NotificationThumbnailFailure.responseTooLarge }
        let types = [
            "image/jpeg": UTType.jpeg.identifier,
            "image/png": UTType.png.identifier,
            "image/webp": UTType.webP.identifier,
        ]
        guard let expectedType = types[mime] else { throw NotificationThumbnailFailure.invalidMIME }
        guard let source = CGImageSourceCreateWithData(
            data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary
        ), CGImageSourceGetStatus(source) == .statusComplete,
           CGImageSourceGetCount(source) == 1,
           let actualType = CGImageSourceGetType(source), actualType as String == expectedType,
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
           let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else {
            throw NotificationThumbnailFailure.invalidImage
        }
        let w = width.doubleValue, h = height.doubleValue
        guard w.isFinite, h.isFinite, w >= 1, h >= 1, w <= 8_192, h <= 8_192,
              w * h <= 2_000_000 else { throw NotificationThumbnailFailure.imageDimensions }
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumThumbnailDimension,
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary),
              image.width > 0, image.height > 0,
              image.width <= maximumThumbnailDimension, image.height <= maximumThumbnailDimension else {
            throw NotificationThumbnailFailure.invalidImage
        }
        let encoded = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            encoded as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil
        ) else { throw NotificationThumbnailFailure.invalidImage }
        CGImageDestinationAddImage(destination, image, [
            kCGImageDestinationLossyCompressionQuality: 0.75,
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination), encoded.length > 0 else {
            throw NotificationThumbnailFailure.invalidImage
        }
        guard encoded.length <= maximumResponseBytes else { throw NotificationThumbnailFailure.responseTooLarge }
        return encoded as Data
    }

    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(
            _ session: URLSession, task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }

        func urlSession(
            _ session: URLSession, task: URLSessionTask,
            didReceive challenge: URLAuthenticationChallenge,
            completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
        ) {
            // System TLS trust only; no client credentials, trust exceptions, or interactive authentication.
            if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
                completionHandler(.performDefaultHandling, nil)
            } else {
                completionHandler(.cancelAuthenticationChallenge, nil)
            }
        }
    }
}
