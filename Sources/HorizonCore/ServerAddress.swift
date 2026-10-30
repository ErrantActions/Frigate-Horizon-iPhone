import Foundation

public enum HorizonError: LocalizedError {
    case invalidAddress
    case invalidMediaPath
    case unauthorized
    case http(Int)
    case server(status: Int, message: String)
    case unexpectedResponse
    case message(String)

    public var errorDescription: String? {
        switch self {
        case .invalidAddress:
            return "Enter the server's HTTP or HTTPS address, including its port and optional base path, without /api, credentials, or query parameters."
        case .invalidMediaPath:
            return "The server returned an unsupported media path."
        case .unauthorized:
            return "Your session expired or access was denied. Reconnect in Settings."
        case .http(let status):
            return "The server returned HTTP \(status)."
        case .server(let status, let message):
            return "HTTP \(status): \(message)"
        case .unexpectedResponse:
            return "The server returned an unexpected response. Check the address and reverse proxy."
        case .message(let message):
            return message
        }
    }

    public var httpStatusCode: Int? {
        switch self {
        case .unauthorized: return 401
        case .http(let status), .server(let status, _): return status
        default: return nil
        }
    }
}

public struct ServerAddress: Hashable, Codable, Sendable {
    public let url: URL

    public init(_ text: String) throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var parts = URLComponents(string: trimmed),
              let scheme = parts.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil,
              parts.port.map({ (1...65535).contains($0) }) ?? true
        else { throw HorizonError.invalidAddress }
        let segments = parts.path.split(separator: "/").map(String.init)
        guard !segments.contains(where: { $0 == "." || $0 == ".." }),
              segments.last?.lowercased() != "api"
        else { throw HorizonError.invalidAddress }
        parts.scheme = scheme
        parts.path = segments.isEmpty ? "" : "/" + segments.joined(separator: "/")
        guard let url = parts.url else { throw HorizonError.invalidAddress }
        self.url = url
    }

    public func endpoint(_ components: [String], query: [URLQueryItem] = []) -> URL {
        let path = components.reduce(url) { $0.appendingPathComponent($1) }
        var parts = URLComponents(url: path, resolvingAgainstBaseURL: false)!
        if !query.isEmpty { parts.queryItems = query }
        return parts.url!
    }

    public func webSocket(stream: String, transport: String = "webrtc") -> URL {
        var parts = URLComponents(
            url: endpoint(["live", transport == "mse" ? "mse" : "webrtc", "api", "ws"], query: [
                URLQueryItem(name: "src", value: stream),
            ]),
            resolvingAgainstBaseURL: false
        )!
        parts.scheme = url.scheme == "https" ? "wss" : "ws"
        return parts.url!
    }

    public func messageWebSocket() -> URL {
        var parts = URLComponents(url: endpoint(["ws"]), resolvingAgainstBaseURL: false)!
        parts.scheme = url.scheme == "https" ? "wss" : "ws"
        return parts.url!
    }

    public func reviewThumbnail(_ path: String) throws -> URL {
        try mediaFile(path, root: "clips")
    }

    public func mediaFile(_ path: String, root: String) throws -> URL {
        let prefix = "/media/frigate/"
        guard ["clips", "exports"].contains(root), path.hasPrefix(prefix) else { throw HorizonError.invalidMediaPath }
        let relative = String(path.dropFirst(prefix.count))
        let segments = relative.split(separator: "/").map(String.init)
        guard segments.first == root,
              segments.allSatisfy({
                  let decoded = $0.removingPercentEncoding ?? $0
                  return $0 != "." && $0 != ".." && !$0.contains("\\")
                      && decoded != "." && decoded != ".." && !decoded.contains("/") && !decoded.contains("\\")
              })
        else { throw HorizonError.invalidMediaPath }
        return endpoint(segments)
    }

    public func playback(camera: String, start: Double, end: Double) throws -> URL {
        guard start.isFinite, end.isFinite, start >= 0, end > start else {
            throw HorizonError.message("No completed recording is available for this time range.")
        }
        return endpoint([
            "vod", camera, "start", String(start), "end", String(end), "master.m3u8",
        ])
    }

    public func hasSameOrigin(as other: URL) -> Bool {
        func port(_ value: URL) -> Int { value.port ?? (value.scheme == "https" ? 443 : 80) }
        return url.scheme == other.scheme
            && url.host?.lowercased() == other.host?.lowercased()
            && port(url) == port(other)
    }
}
