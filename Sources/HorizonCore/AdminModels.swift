import Foundation

public struct AdminUser: Decodable, Identifiable, Sendable {
    public let username: String
    public let role: String
    public var id: String { username }
}

public struct ServiceLogs: Decodable, Sendable {
    public let totalLines: Int
    public let lines: [String]
}

public struct SystemStats: Decodable, Sendable {
    public let service: Service
    public let cameras: [String: Camera]?
    public let detectors: [String: Detector]?
    public let cameraFPS: Double?
    public let detectionFPS: Double?
    enum CodingKeys: String, CodingKey {
        case service, cameras, detectors
        case cameraFPS = "camera_fps"
        case detectionFPS = "detection_fps"
    }

    public struct Service: Decodable, Sendable {
        public let version: String
        public let uptime: Double
        public let retentionUnmet: Bool?
        public let storage: [String: Storage]?
        enum CodingKeys: String, CodingKey {
            case version, uptime, storage
            case retentionUnmet = "retention_unmet"
        }
    }
    public struct Storage: Decodable, Sendable {
        public let free: Double
        public let total: Double
        public let used: Double
    }
    public struct Camera: Decodable, Sendable {
        public let cameraFPS: Double?
        public let detectionFPS: Double?
        public let skippedFPS: Double?
        public let connectionQuality: String?
        enum CodingKeys: String, CodingKey {
            case cameraFPS = "camera_fps"
            case detectionFPS = "detection_fps"
            case skippedFPS = "skipped_fps"
            case connectionQuality = "connection_quality"
        }
    }
    public struct Detector: Decodable, Sendable {
        public let inferenceSpeed: Double?
        public let temperature: Double?
        enum CodingKeys: String, CodingKey {
            case inferenceSpeed = "inference_speed"
            case temperature
        }
    }
}
