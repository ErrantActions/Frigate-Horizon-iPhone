import Foundation

public struct CameraControlCapabilities: Decodable, Equatable, Sendable {
    public let camera: String
    public let ptz: PTZ
    public let talkback: Talkback

    public struct PTZ: Decodable, Equatable, Sendable {
        public let supported: Bool
        public let panTilt: Bool
        public let zoom: Bool
        public let presets: [Preset]
        enum CodingKeys: String, CodingKey {
            case supported, zoom, presets
            case panTilt = "pan_tilt"
        }
    }

    public struct Preset: Decodable, Equatable, Identifiable, Sendable {
        public let id: String
        public let name: String
    }

    public struct Talkback: Decodable, Equatable, Sendable {
        public let supported: Bool
    }

    public func validate(cameraID: String) throws {
        try CameraControlRoute.validate(cameraID)
        guard camera == cameraID,
              Set(ptz.presets.map(\.id)).count == ptz.presets.count,
              ptz.presets.allSatisfy({
                  !$0.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                  !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
              }) else {
            throw HorizonError.message("The server returned invalid camera controls. Reload controls before using them.")
        }
    }

    public func permits(_ command: CameraPTZCommand, preset: String? = nil) -> Bool {
        guard ptz.supported else { return false }
        switch command {
        case .up, .down, .left, .right: return ptz.panTilt && preset == nil
        case .zoomIn, .zoomOut: return ptz.zoom && preset == nil
        case .preset: return preset.map { id in ptz.presets.contains { $0.id == id } } == true
        case .stop: return preset == nil
        }
    }
}

public enum CameraControlRoute {
    public static func validate(_ cameraID: String) throws {
        let decoded = cameraID.removingPercentEncoding ?? cameraID
        guard !cameraID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              ![cameraID, decoded].contains(where: {
                  $0 == "." || $0 == ".." || $0.contains("/") || $0.contains("\\") ||
                  $0.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
              }) else {
            throw HorizonError.message("The camera identifier cannot be used for native controls.")
        }
    }

    public static func prefix(cameraID: String) throws -> [String] {
        try validate(cameraID)
        return ["native", "cameras", cameraID, "controls"]
    }

    public static func ptz(cameraID: String) throws -> [String] {
        try validate(cameraID)
        return ["native", "cameras", cameraID, "ptz"]
    }

    public static func talkback(cameraID: String, leaseID: UUID? = nil) throws -> [String] {
        try validate(cameraID)
        let base = ["native", "cameras", cameraID, "talkback"]
        return leaseID.map { base + [$0.uuidString.lowercased()] } ?? base
    }
}

public enum CameraPTZCommand: String, Codable, CaseIterable, Sendable {
    case up = "MOVE_UP"
    case down = "MOVE_DOWN"
    case left = "MOVE_LEFT"
    case right = "MOVE_RIGHT"
    case zoomIn = "ZOOM_IN"
    case zoomOut = "ZOOM_OUT"
    case stop = "STOP"
    case preset = "PRESET"
}

public struct CameraPTZRequest: Encodable, Equatable, Sendable {
    public static let leaseDurationMilliseconds = 500
    public let command: CameraPTZCommand
    public let leaseID: UUID
    public let durationMilliseconds: Int
    public let preset: String?

    enum CodingKeys: String, CodingKey {
        case command, preset
        case leaseID = "lease_id"
        case durationMilliseconds = "duration_ms"
    }

    public init(
        command: CameraPTZCommand, leaseID: UUID, preset: String? = nil,
        capabilities: CameraControlCapabilities, cameraID: String
    ) throws {
        try capabilities.validate(cameraID: cameraID)
        guard command != .stop, capabilities.permits(command, preset: preset) else {
            throw HorizonError.message("This camera or account does not support that PTZ control.")
        }
        self.command = command
        self.leaseID = leaseID
        self.durationMilliseconds = Self.leaseDurationMilliseconds
        self.preset = preset
    }

    private init(stopping leaseID: UUID) {
        command = .stop
        self.leaseID = leaseID
        durationMilliseconds = Self.leaseDurationMilliseconds
        preset = nil
    }

    // STOP must remain possible after permissions or capabilities have been revoked.
    public static func stop(leaseID: UUID) -> Self { Self(stopping: leaseID) }
}

public struct CameraTalkbackDescription: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case offer, answer }
    public let type: Kind
    public let sdp: String

    public init(offer: String) throws {
        try Self.validate(offer)
        type = .offer
        sdp = offer
    }

    public func validatedAnswer() throws -> String {
        guard type == .answer else {
            throw HorizonError.message("The camera did not return a talkback answer.")
        }
        try Self.validate(sdp)
        var sessionDirection = "a=sendrecv"
        var mediaDirection: String?
        var audioPort: Int?
        var inAudio = false
        let directions: Set<String> = ["a=sendrecv", "a=recvonly", "a=sendonly", "a=inactive"]
        for line in sdp.components(separatedBy: .newlines) {
            if line.hasPrefix("m=audio ") {
                inAudio = true
                let fields = line.split(separator: " ")
                if fields.count > 1 {
                    audioPort = fields[1].split(separator: "/").first.flatMap { Int($0) }
                }
            } else if directions.contains(line) {
                if inAudio { mediaDirection = line } else { sessionDirection = line }
            }
        }
        let direction = mediaDirection ?? sessionDirection
        guard let audioPort, (1...65535).contains(audioPort),
              direction == "a=sendrecv" || direction == "a=recvonly" else {
            throw HorizonError.message("The camera did not accept a microphone backchannel.")
        }
        return sdp
    }

    private static func validate(_ sdp: String) throws {
        let lines = sdp.components(separatedBy: .newlines)
        guard sdp.utf8.count <= 262_144, lines.filter({ $0.hasPrefix("m=audio ") }).count == 1,
              !lines.contains(where: { $0.hasPrefix("m=") && !$0.hasPrefix("m=audio ") }) else {
            throw HorizonError.message("The camera returned an invalid audio-only talkback description.")
        }
    }
}

public struct CameraTalkbackEmptyBody: Encodable, Sendable {
    public init() {}
}

public struct CameraTalkbackLeaseRenewal: Decodable, Equatable, Sendable {
    public let leaseID: UUID
    public let expiresAt: TimeInterval
    public let renewAfterMilliseconds: Int
    enum CodingKeys: String, CodingKey {
        case leaseID = "lease_id"
        case expiresAt = "expires_at"
        case renewAfterMilliseconds = "renew_after_ms"
    }
}

public struct CameraTalkbackLease: Equatable, Sendable {
    public static let idHeader = "X-Horizon-Talkback-Lease"
    public static let expiresHeader = "X-Horizon-Talkback-Expires"
    public static let renewHeader = "X-Horizon-Talkback-Renew-After-Ms"
    public static let headerNames = [idHeader, expiresHeader, renewHeader]
    public static let timeToLive: TimeInterval = 15
    public static let renewalMilliseconds = 5000
    public static let maximumServerLifetime: TimeInterval = 120
    public let id: UUID
    public let expiresAt: TimeInterval
    public let renewAfterMilliseconds: Int

    public static func id(in headers: [String: String]) -> UUID? {
        value(idHeader, in: headers).flatMap(UUID.init(uuidString:))
    }

    public init(headers: [String: String], now: TimeInterval = Date().timeIntervalSince1970) throws {
        guard let id = Self.id(in: headers),
              let expires = Self.value(Self.expiresHeader, in: headers).flatMap(Double.init),
              let renewal = Self.value(Self.renewHeader, in: headers).flatMap(Int.init) else {
            throw HorizonError.message("The server omitted or returned invalid talkback lease headers. Microphone capture was not enabled.")
        }
        self.id = id
        expiresAt = expires
        renewAfterMilliseconds = renewal
        try validate(now: now)
    }

    public init(
        renewal: CameraTalkbackLeaseRenewal, expectedID: UUID,
        now: TimeInterval = Date().timeIntervalSince1970
    ) throws {
        guard renewal.leaseID == expectedID else {
            throw HorizonError.message("The server renewed a different talkback lease. Microphone capture must stop.")
        }
        id = renewal.leaseID
        expiresAt = renewal.expiresAt
        renewAfterMilliseconds = renewal.renewAfterMilliseconds
        try validate(now: now)
    }

    public func validate(now: TimeInterval) throws {
        // Permit one second of clock skew, but never extend the local TTL beyond 15 seconds.
        guard now.isFinite, expiresAt.isFinite, expiresAt > now,
              expiresAt - now <= Self.timeToLive + 1,
              renewAfterMilliseconds == Self.renewalMilliseconds else {
            throw HorizonError.message("The talkback lease is expired or invalid. Check the server connection and device clock.")
        }
    }

    private static func value(_ name: String, in headers: [String: String]) -> String? {
        let matches = headers.filter { $0.key.caseInsensitiveCompare(name) == .orderedSame }
        guard matches.count == 1 else { return nil }
        return matches.first?.value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
