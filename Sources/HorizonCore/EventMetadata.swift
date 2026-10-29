import Foundation

public enum EventMetadataField: String, CaseIterable, Hashable, Sendable {
    case subLabel, description

    public var title: String { self == .subLabel ? "Sub-label" : "Description" }
    public var endpoint: String { self == .subLabel ? "sub_label" : "description" }
}

public struct EventSubLabelUpdate: Encodable, Sendable {
    public let subLabel: String

    public init(_ value: String) throws {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.unicodeScalars.count <= 100 else {
            throw HorizonError.message("Event sub-labels must contain at most 100 characters.")
        }
        subLabel = value
    }
}

public struct EventDescriptionUpdate: Encodable, Sendable {
    public let description: String
    public init(_ value: String) { description = value }
}

public struct EventMetadataSnapshot: Equatable, Sendable {
    public let eventID: String
    public let camera: String
    public private(set) var subLabel: String
    public private(set) var description: String

    public init(_ event: SearchEvent) {
        eventID = event.id
        camera = event.camera
        subLabel = event.subLabel ?? ""
        description = event.data.description ?? ""
    }

    public func value(for field: EventMetadataField) -> String {
        field == .subLabel ? subLabel : description
    }

    public func requireSameEvent(_ latest: SearchEvent) throws {
        guard latest.id == eventID, latest.camera == camera else {
            throw HorizonError.message("The server returned a different event. Close and reload before editing.")
        }
    }

    public func requireUnchanged(_ latest: SearchEvent, field: EventMetadataField) throws {
        try requireSameEvent(latest)
        guard value(for: field) == Self(latest).value(for: field) else {
            throw HorizonError.message("\(field.title) changed on the server. Close and reopen the editor before saving.")
        }
    }

    public mutating func confirm(_ latest: SearchEvent, field: EventMetadataField) throws {
        try requireSameEvent(latest)
        let value = Self(latest).value(for: field)
        switch field {
        case .subLabel: subLabel = value
        case .description: description = value
        }
    }
}
