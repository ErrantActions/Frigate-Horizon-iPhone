import Foundation

public struct SearchEvent: Decodable, Identifiable, Sendable {
    public let id: String
    public let camera: String
    public let label: String
    public let subLabel: String?
    public let startTime: Double
    public let endTime: Double?
    public let zones: [String]
    public let hasClip: Bool
    public let hasSnapshot: Bool
    public let retainIndefinitely: Bool
    public let data: EventData

    enum CodingKeys: String, CodingKey {
        case id, camera, label, zones, data
        case subLabel = "sub_label"
        case startTime = "start_time"
        case endTime = "end_time"
        case hasClip = "has_clip"
        case hasSnapshot = "has_snapshot"
        case retainIndefinitely = "retain_indefinitely"
    }

    public struct EventData: Decodable, Sendable {
        public let topScore: Double?
        public let description: String?
        public let type: String?
        public let recognizedLicensePlate: String?
        enum CodingKeys: String, CodingKey {
            case description, type
            case topScore = "top_score"
            case recognizedLicensePlate = "recognized_license_plate"
        }
    }
}

public struct EventSearchQuery: Equatable, Sendable {
    public var text = ""
    public var similarityEventID: String?
    public var camera = "all"
    public var label = ""
    public var zone = ""
    public var subLabel = ""
    public var after: Double
    public var before: Double
    public var clipsOnly = false
    public var snapshotsOnly = false
    public let pageSize = 100

    public init(after: Double, before: Double) { self.after = after; self.before = before }
    public var isSemantic: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || similarityEventID != nil
    }
    public var path: [String] { isSemantic ? ["events", "search"] : ["events"] }

    public func items(offset: Int) throws -> [URLQueryItem] {
        guard after.isFinite, before.isFinite, after >= 0, before > after, offset >= 0 else {
            throw HorizonError.message("Choose a valid event search range.")
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty || similarityEventID == nil else {
            throw HorizonError.message("Choose either a text search or a similar-event search.")
        }
        var result = [
            URLQueryItem(name: "cameras", value: camera),
            URLQueryItem(name: "after", value: String(after)),
            URLQueryItem(name: "before", value: String(before)),
            URLQueryItem(name: "limit", value: String(pageSize)),
            URLQueryItem(name: "offset", value: String(offset)),
            URLQueryItem(name: "include_thumbnails", value: "0"),
        ]
        for (name, value) in [("labels", label), ("zones", zone), ("sub_labels", subLabel)] {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { result.append(URLQueryItem(name: name, value: trimmed)) }
        }
        if !trimmed.isEmpty {
            result.append(URLQueryItem(name: "query", value: trimmed))
            result.append(URLQueryItem(name: "search_type", value: "description,thumbnail"))
        }
        if let similarityEventID {
            result.append(URLQueryItem(name: "event_id", value: similarityEventID))
            result.append(URLQueryItem(name: "search_type", value: "similarity"))
        }
        if clipsOnly { result.append(URLQueryItem(name: "has_clip", value: isSemantic ? "true" : "1")) }
        if snapshotsOnly { result.append(URLQueryItem(name: "has_snapshot", value: isSemantic ? "true" : "1")) }
        return result
    }
}

public struct MediaExport: Decodable, Identifiable, Sendable {
    public let id: String
    public let camera: String
    public let name: String
    public let date: Double
    public let videoPath: String
    public let thumbPath: String?
    public let inProgress: Bool
    enum CodingKeys: String, CodingKey {
        case id, camera, name, date
        case videoPath = "video_path"
        case thumbPath = "thumb_path"
        case inProgress = "in_progress"
    }
}

public struct MediaExportJob: Decodable, Identifiable, Sendable {
    public let id: String
    public let camera: String
    public let status: String
    public let name: String?
    public let currentStep: String?
    public let progressPercent: Double?
    public let errorMessage: String?
    enum CodingKeys: String, CodingKey {
        case id, camera, status, name
        case currentStep = "current_step"
        case progressPercent = "progress_percent"
        case errorMessage = "error_message"
    }
}

public struct CreateExportBody: Encodable, Sendable {
    public let name: String
    public let source = "recordings"
    public let stream: String
    public let timestamp: String
    public let metadataCategories: [String]
    enum CodingKeys: String, CodingKey {
        case name, source, stream, timestamp
        case metadataCategories = "metadata_categories"
    }
    public init(name: String, stream: String, timestamp: String, metadataCategories: [String]) {
        self.name = name; self.stream = stream; self.timestamp = timestamp
        self.metadataCategories = metadataCategories
    }
}

public struct APIActionResult: Decodable, Sendable {
    public let success: Bool
    public let message: String?
    public let exportID: String?
    enum CodingKeys: String, CodingKey {
        case success, message
        case exportID = "export_id"
    }
    public func requireSuccess() throws {
        guard success else { throw HorizonError.message(message ?? "The server rejected the action.") }
    }
}
