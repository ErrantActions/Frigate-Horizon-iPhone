import Foundation

public enum HorizonDestination: String, CaseIterable, Hashable, Sendable {
    case live, activity, recordings, library, settings
    case search, exports, protectedMedia, administration

    public static let compactTabs: [Self] = [.live, .activity, .recordings, .library, .settings]

    public var compactDestination: Self {
        switch self {
        case .search: return .activity
        case .exports, .protectedMedia: return .library
        case .administration: return .settings
        default: return self
        }
    }

    public static func sidebarShortcuts(isAdmin: Bool) -> [Self] {
        [.search, .exports, .protectedMedia] + (isAdmin ? [.administration] : [])
    }
}

public enum ActivityMode: String, CaseIterable, Hashable, Sendable {
    case review, search
}

public enum LibrarySection: String, CaseIterable, Hashable, Sendable {
    case exports, protectedMedia
}

public struct CameraHistoryContext: Equatable, Sendable {
    public let camera: String
    public let day: Date
    public let timestamp: Double

    public init(camera: String, at date: Date, allowedCameraIDs: Set<String>,
                now: Date = Date(), calendar: Calendar = .current) throws {
        guard allowedCameraIDs.contains(camera), date.timeIntervalSince1970.isFinite,
              date.timeIntervalSince1970 >= 0, date <= now else {
            throw HorizonError.message("Choose an allowed camera and an available recording date.")
        }
        self.camera = camera
        self.day = calendar.startOfDay(for: date)
        self.timestamp = date.timeIntervalSince1970
    }
}
