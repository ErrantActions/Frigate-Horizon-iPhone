import Foundation

public struct LiveHLSStatus: Decodable, Sendable {
    public struct Rendition: Decodable, Sendable {
        public let height: Int
        public let bitrate: Int
    }

    public let version: Int
    public let protocolName: String
    public let enabled: Bool
    public let available: Bool
    public let playlist: String
    public let renditions: [Rendition]
    public var isAvailable: Bool { version == 1 && protocolName == "ll-hls" && enabled && available }

    enum CodingKeys: String, CodingKey {
        case version, enabled, available, playlist, renditions
        case protocolName = "protocol"
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        protocolName = try values.decode(String.self, forKey: .protocolName)
        if version != 1 || protocolName != "ll-hls" {
            enabled = false; available = false; playlist = ""; renditions = []
            return
        }
        enabled = try values.decode(Bool.self, forKey: .enabled)
        available = try values.decode(Bool.self, forKey: .available)
        playlist = try values.decodeIfPresent(String.self, forKey: .playlist) ?? ""
        renditions = try values.decodeIfPresent([Rendition].self, forKey: .renditions) ?? []
        if enabled && available && (playlist.isEmpty || renditions.isEmpty ||
            renditions.contains(where: { $0.height <= 0 || $0.bitrate <= 0 })) {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                debugDescription: "Available live HLS requires a playlist and valid renditions."))
        }
    }
}

public enum LiveHLSGate {
    public static func shouldProbe(cameraEnabled: Bool, optedIn: Bool, automatic: Bool, transport: String) -> Bool {
        cameraEnabled && optedIn && automatic && transport == "https"
    }

    public static func isUnsupportedHTTP(_ status: Int) -> Bool { [404, 405, 410, 501].contains(status) }
}

public struct LiveHLSConfiguration: Equatable, Sendable {
    public let maximumHeight: Int?
    public init(maximumHeight: Int? = nil) { self.maximumHeight = maximumHeight }
}

public struct LiveHLSStartupPolicy: Sendable {
    private let lowestBandwidth: Double
    private var healthySince: TimeInterval?
    private var lastObservation: TimeInterval?
    public private(set) var released = false
    public var preferredPeakBitRate: Double { released ? 0 : lowestBandwidth }

    public init(lowestBandwidth: Int) { self.lowestBandwidth = Double(lowestBandwidth) }

    public mutating func observe(now: TimeInterval, decodedVideo: Bool, bufferedAhead: TimeInterval,
                                 playing: Bool, restrictedNetwork: Bool) {
        guard now.isFinite, lastObservation.map({ now >= $0 }) ?? true else {
            healthySince = nil
            return
        }
        lastObservation = now
        if restrictedNetwork {
            released = false
            healthySince = nil
            return
        }
        guard !released else { return }
        guard decodedVideo, playing, bufferedAhead.isFinite, bufferedAhead >= 1 else {
            healthySince = nil
            return
        }
        if healthySince == nil { healthySince = now }
        if let healthySince, now - healthySince >= 3 { released = true }
    }
}

public struct LiveHLSResourcePolicy: Sendable {
    public let address: ServerAddress
    public let camera: String
    public let root: URL
    public let canonicalMaster: URL
    private static let assetScheme = "horizon-hls"

    public init(address: ServerAddress, camera: String) throws {
        guard address.url.scheme == "https", !camera.isEmpty, camera.utf8.count <= 256,
              camera != ".", camera != "..",
              !camera.contains(where: { "/\\?#%".contains($0) || $0.isWhitespace || $0.isNewline }),
              !camera.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { throw HorizonError.message("Live HLS requires a trusted HTTPS server and a valid camera.") }
        self.address = address
        self.camera = camera
        root = address.endpoint(["api", camera, "live", "hls"])
        canonicalMaster = root.appendingPathComponent("master.m3u8")
    }

    public func masterURL(_ reference: String) throws -> URL {
        let api = address.endpoint(["api"]).appendingPathComponent("")
        let url = try resolve(reference, relativeTo: api)
        guard url == canonicalMaster else { throw HorizonError.invalidMediaPath }
        return url
    }

    public func resolve(_ reference: String, relativeTo base: URL) throws -> URL {
        guard !reference.isEmpty, reference.utf8.count <= 4096,
              !reference.contains("\\"),
              !reference.contains("{$"),
              !reference.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              let components = URLComponents(string: reference),
              components.user == nil, components.password == nil, components.fragment == nil else {
            throw HorizonError.invalidMediaPath
        }
        try validateSegments(components.percentEncodedPath)
        guard let url = URL(string: reference, relativeTo: base)?.absoluteURL else {
            throw HorizonError.invalidMediaPath
        }
        return try validate(url)
    }

    public func validate(_ url: URL) throws -> URL {
        guard address.hasSameOrigin(as: url), url.scheme == "https",
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.user == nil, components.password == nil, components.fragment == nil
        else { throw HorizonError.invalidMediaPath }
        try validateSegments(components.percentEncodedPath)
        var segments: [Substring] = []
        for segment in components.percentEncodedPath.split(separator: "/") {
            if segment == "." { continue }
            if segment == ".." {
                guard !segments.isEmpty else { throw HorizonError.invalidMediaPath }
                segments.removeLast()
            } else { segments.append(segment) }
        }
        components.percentEncodedPath = "/" + segments.joined(separator: "/")
        guard let normalized = components.url, normalized.path.hasPrefix(root.path + "/"),
              ["m3u8", "mp4", "m4s", "m4a", "aac", "ts"].contains(normalized.pathExtension.lowercased())
        else { throw HorizonError.invalidMediaPath }
        let query = components.queryItems ?? []
        guard Set(query.map(\.name)).count == query.count,
              query.isEmpty || normalized.pathExtension.lowercased() == "m3u8" else { throw HorizonError.invalidMediaPath }
        for item in query {
            guard let value = item.value else { throw HorizonError.invalidMediaPath }
            switch item.name {
            case "_HLS_msn", "_HLS_part":
                guard !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }),
                      Int64(value) != nil else { throw HorizonError.invalidMediaPath }
            case "_HLS_skip":
                guard ["YES", "v2"].contains(value) else { throw HorizonError.invalidMediaPath }
            default: throw HorizonError.invalidMediaPath
            }
        }
        return normalized
    }

    public func assetURL(_ network: URL) throws -> URL {
        let safe = try validate(network)
        var parts = URLComponents(url: safe, resolvingAgainstBaseURL: false)!
        parts.scheme = Self.assetScheme
        guard let result = parts.url else { throw HorizonError.invalidMediaPath }
        return result
    }

    public func networkURL(_ asset: URL) throws -> URL {
        guard asset.scheme == Self.assetScheme,
              var parts = URLComponents(url: asset, resolvingAgainstBaseURL: false) else {
            throw HorizonError.invalidMediaPath
        }
        parts.scheme = "https"
        guard let result = parts.url else { throw HorizonError.invalidMediaPath }
        return try validate(result)
    }

    private func validateSegments(_ path: String) throws {
        for segment in path.split(separator: "/") {
            var value = String(segment)
            for _ in 0..<4 {
                guard !value.contains("/"), !value.contains("\\"),
                      !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                      let decoded = value.removingPercentEncoding else { throw HorizonError.invalidMediaPath }
                if decoded == value { break }
                guard decoded != ".", decoded != ".." else { throw HorizonError.invalidMediaPath }
                value = decoded
            }
            guard !value.contains("%"), !value.contains("/"), !value.contains("\\") else {
                throw HorizonError.invalidMediaPath
            }
        }
    }

    public func rewritePlaylist(_ text: String, url: URL) throws -> String {
        _ = try validate(url)
        return try transformPlaylist(text) { reference in
            try assetURL(resolve(reference, relativeTo: url))
        }
    }

    public func rewriteAssetPlaylist(_ text: String, resourceURL: (URL) throws -> URL) throws -> String {
        try transformPlaylist(text) { reference in
            guard let asset = URL(string: reference) else { throw HorizonError.invalidMediaPath }
            return try resourceURL(networkURL(asset))
        }
    }

    private func transformPlaylist(_ text: String, resourceURL: (String) throws -> URL) throws -> String {
        guard text.utf8.count <= 1_048_576, text.hasPrefix("#EXTM3U") else {
            throw HorizonError.unexpectedResponse
        }
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        return try lines.components(separatedBy: "\n").map { line in
            if line.isEmpty { return line }
            if !line.hasPrefix("#") { return try resourceURL(line).absoluteString }
            if line.hasPrefix("#EXT-X-KEY:") || line.hasPrefix("#EXT-X-SESSION-KEY:") ||
                line.hasPrefix("#EXT-X-DEFINE:") || line.hasPrefix("#EXT-X-CONTENT-STEERING:") {
                throw HorizonError.message("The live HLS playlist uses an unsupported key or steering contract.")
            }
            guard line.contains("URI=") else { return line }
            let attributes = try HLSAttributes.parse(line)
            guard let uri = attributes["URI"] else { throw HorizonError.unexpectedResponse }
            let replacement = try resourceURL(uri).absoluteString
            guard let range = line.range(of: "URI=\"\(uri)\"") else { throw HorizonError.unexpectedResponse }
            return line.replacingCharacters(in: range, with: "URI=\"\(replacement)\"")
        }.joined(separator: "\n")
    }
}

enum HLSAttributes {
    static func parse(_ line: String) throws -> [String: String] {
        guard let colon = line.firstIndex(of: ":") else { throw HorizonError.unexpectedResponse }
        var quoted = false
        var token = ""
        var tokens: [String] = []
        for character in line[line.index(after: colon)...] {
            if character == "\"" { quoted.toggle() }
            if character == "," && !quoted { tokens.append(token); token = "" }
            else { token.append(character) }
        }
        guard !quoted else { throw HorizonError.unexpectedResponse }
        tokens.append(token)
        var result: [String: String] = [:]
        for token in tokens {
            guard let equals = token.firstIndex(of: "=") else { throw HorizonError.unexpectedResponse }
            let key = String(token[..<equals]).trimmingCharacters(in: .whitespaces)
            var value = String(token[token.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                value.removeFirst(); value.removeLast()
            }
            guard !key.isEmpty, !value.contains("\""), result[key] == nil else { throw HorizonError.unexpectedResponse }
            result[key] = value
        }
        return result
    }
}

public struct LiveHLSMaster: Sendable {
    public struct Variant: Equatable, Sendable {
        public let url: URL
        public let bandwidth: Int
        public let width: Int
        public let height: Int
    }

    public let variants: [Variant]
    public let playlist: String
    public var lowestBandwidth: Int { variants.map(\.bandwidth).min()! }

    public init(text: String, policy: LiveHLSResourcePolicy, url: URL, maximumHeight: Int? = nil) throws {
        guard text.utf8.count <= 1_048_576, text.hasPrefix("#EXTM3U") else { throw HorizonError.unexpectedResponse }
        _ = try policy.rewritePlaylist(text, url: url)
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
        var kept: [String] = []
        var variants: [Variant] = []
        var index = 0
        while index < lines.count {
            let line = lines[index]
            if line.hasPrefix("#EXT-X-STREAM-INF:") {
                let attributes = try HLSAttributes.parse(line)
                guard let bandwidth = attributes["BANDWIDTH"].flatMap(Int.init), bandwidth > 0,
                      let resolution = attributes["RESOLUTION"]?.split(separator: "x"), resolution.count == 2,
                      let width = Int(resolution[0]), let height = Int(resolution[1]), width > 0, height > 0,
                      index + 1 < lines.count, !lines[index + 1].isEmpty,
                      !lines[index + 1].hasPrefix("#") else { throw HorizonError.unexpectedResponse }
                let child = try policy.resolve(lines[index + 1], relativeTo: url)
                if height >= 720 && (maximumHeight.map({ height <= $0 }) ?? true) {
                    variants.append(Variant(url: child, bandwidth: bandwidth, width: width, height: height))
                    kept.append(line); kept.append(lines[index + 1])
                }
                index += 2
            } else {
                kept.append(line)
                index += 1
            }
        }
        guard !variants.isEmpty, variants.count <= 32 else {
            throw HorizonError.message("The live HLS master has no supported video profiles within the selected maximum.")
        }
        self.variants = variants
        playlist = kept.joined(separator: "\n")
    }
}
