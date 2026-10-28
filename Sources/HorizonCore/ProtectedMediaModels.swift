import Foundation

public struct ProtectedMediaPage: Decodable, Sendable {
    public let items: [ProtectedMediaItem]
    public let total: Int
    public let limit: Int
    public let offset: Int
    public let storage: [String: ProtectedStorageUsage]
    public let archiveState: String
    enum CodingKeys: String, CodingKey {
        case items, total, limit, offset, storage
        case archiveState = "archive_state"
    }
}

public struct ProtectedStorageUsage: Decodable, Sendable {
    public let recordings: Int
    public let knownBytes: Int64
    public let unknownSizeRecordings: Int
    public let totalBytes: Int64?
    enum CodingKeys: String, CodingKey {
        case recordings
        case knownBytes = "known_bytes"
        case unknownSizeRecordings = "unknown_size_recordings"
        case totalBytes = "total_bytes"
    }
}

public struct ProtectedMediaItem: Decodable, Identifiable, Sendable {
    public let id: String
    public let camera: String
    public let startTime: Double
    public let endTime: Double?
    public let label: String
    public let availability: String
    public let tiers: [String]
    public let recordings: Int
    public let hasSnapshot: Bool
    public let originalURL: String?
    enum CodingKeys: String, CodingKey {
        case id, camera, label, availability, tiers, recordings
        case startTime = "start_time"
        case endTime = "end_time"
        case hasSnapshot = "has_snapshot"
        case originalURL = "original_url"
    }
    public var canReadOriginal: Bool {
        originalURL != nil && ["indexed_local", "archive_online"].contains(availability)
            && endTime.map { $0 > startTime } == true
    }
}
