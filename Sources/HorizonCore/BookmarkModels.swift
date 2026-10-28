import Foundation

public struct RecordingBookmark: Decodable, Identifiable, Sendable {
    public let id: String
    public let camera: String
    public let timestamp: Double
    public let endTime: Double?
    public let title: String
    public let notes: String
    public let owner: String
    public let revision: Int
    public let canEdit: Bool
    public let availableAtAnchor: Bool
    public let protectsFootage: Bool
    enum CodingKeys: String, CodingKey {
        case id, camera, timestamp, title, notes, owner, revision
        case endTime = "end_time"
        case canEdit = "can_edit"
        case availableAtAnchor = "available_at_anchor"
        case protectsFootage = "protects_footage"
    }
}

public struct BookmarkPage: Decodable, Sendable {
    public let items: [RecordingBookmark]
    public let hasMore: Bool
    enum CodingKeys: String, CodingKey {
        case items
        case hasMore = "has_more"
    }
}

public struct CreateBookmarkBody: Encodable, Sendable {
    public let timestamp: Double
    public let endTime: Double?
    public let title: String
    public let notes: String
    enum CodingKeys: String, CodingKey {
        case timestamp, title, notes
        case endTime = "end_time"
    }

    public init(timestamp: Double, endTime: Double?, title: String, notes: String) throws {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard timestamp.isFinite, timestamp >= 0, timestamp <= 253402300799,
              endTime.map({ $0.isFinite && $0 > timestamp && $0 <= 253402300799 }) ?? true,
              !title.isEmpty, title.count <= 128, notes.count <= 4000 else {
            throw HorizonError.message("Choose a valid bookmark time, a title up to 128 characters, and notes up to 4,000 characters.")
        }
        self.timestamp = timestamp; self.endTime = endTime; self.title = title; self.notes = notes
    }
}

public struct EditBookmarkBody: Encodable, Sendable {
    public let title: String
    public let notes: String
    public let revision: Int
    public init(title: String, notes: String, revision: Int) throws {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.count <= 128, notes.count <= 4000, revision >= 1 else {
            throw HorizonError.message("A title, valid revision, and notes up to 4,000 characters are required.")
        }
        self.title = title; self.notes = notes; self.revision = revision
    }
}
