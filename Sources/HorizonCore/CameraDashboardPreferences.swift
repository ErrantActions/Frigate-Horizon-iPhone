import Foundation

public struct CameraDashboardPreferences: Codable, Equatable, Sendable {
    public enum Density: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
        case comfortable, compact, oneColumn

        public var id: String { rawValue }
        public var label: String {
            switch self {
            case .comfortable: return "Comfortable"
            case .compact: return "Compact"
            case .oneColumn: return "One column"
            }
        }
    }

    public private(set) var favoriteIDs: Set<String> = []
    public var density: Density = .comfortable
    public var favoritesOnly = false

    public init() {}

    public mutating func toggleFavorite(_ cameraID: String) throws {
        guard !cameraID.isEmpty else { throw HorizonError.message("A camera identifier is required.") }
        if favoriteIDs.contains(cameraID) { favoriteIDs.remove(cameraID) }
        else { favoriteIDs.insert(cameraID) }
    }

    public func cameras(from available: [HorizonCamera]) -> [HorizonCamera] {
        let dashboard = available.filter { $0.settings.ui?.dashboard != false }
        let favorites = dashboard.filter { favoriteIDs.contains($0.id) }
        return favoritesOnly ? favorites : favorites + dashboard.filter { !favoriteIDs.contains($0.id) }
    }

    private enum CodingKeys: String, CodingKey { case favoriteIDs, density, favoritesOnly }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        favoriteIDs = try values.decode(Set<String>.self, forKey: .favoriteIDs)
        guard !favoriteIDs.contains("") else {
            throw DecodingError.dataCorruptedError(forKey: .favoriteIDs, in: values,
                debugDescription: "Favorite camera identifiers must not be empty.")
        }
        density = try values.decode(Density.self, forKey: .density)
        favoritesOnly = try values.decode(Bool.self, forKey: .favoritesOnly)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(favoriteIDs.sorted(), forKey: .favoriteIDs)
        try values.encode(density, forKey: .density)
        try values.encode(favoritesOnly, forKey: .favoritesOnly)
    }
}
