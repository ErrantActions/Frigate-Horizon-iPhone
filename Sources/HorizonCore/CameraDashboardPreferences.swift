import Foundation

public struct SavedCameraGroup: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let name: String
    public let cameraIDs: [String]
    public let density: CameraDashboardPreferences.Density

    public init(id: UUID = UUID(), name: String, cameraIDs: [String],
                density: CameraDashboardPreferences.Density) throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 80,
              name.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw HorizonError.message("Choose a camera group name between 1 and 80 characters.")
        }
        guard !cameraIDs.isEmpty, !cameraIDs.contains(""),
              Set(cameraIDs).count == cameraIDs.count else {
            throw HorizonError.message("Choose at least one camera, without duplicate or empty identifiers.")
        }
        self.id = id
        self.name = name
        self.cameraIDs = cameraIDs
        self.density = density
    }

    private enum CodingKeys: String, CodingKey { case id, name, cameraIDs, density }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(id: values.decode(UUID.self, forKey: .id),
            name: values.decode(String.self, forKey: .name),
            cameraIDs: values.decode([String].self, forKey: .cameraIDs),
            density: values.decode(CameraDashboardPreferences.Density.self, forKey: .density))
    }
}

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
    public private(set) var groups: [SavedCameraGroup] = []
    public private(set) var selectedGroupID: UUID?

    public init() {}

    public var selectedGroup: SavedCameraGroup? { groups.first { $0.id == selectedGroupID } }
    public var effectiveDensity: Density { selectedGroup?.density ?? density }

    public mutating func saveGroup(_ group: SavedCameraGroup) throws {
        guard !groups.contains(where: {
            $0.id != group.id && $0.name.lowercased() == group.name.lowercased()
        }) else { throw HorizonError.message("A camera group with that name already exists.") }
        if let index = groups.firstIndex(where: { $0.id == group.id }) { groups[index] = group }
        else { groups.append(group) }
        selectedGroupID = group.id
    }

    public mutating func selectGroup(_ id: UUID?) throws {
        guard id == nil || groups.contains(where: { $0.id == id }) else {
            throw HorizonError.message("That saved camera group no longer exists.")
        }
        selectedGroupID = id
    }

    public mutating func removeGroup(_ id: UUID) throws {
        guard groups.contains(where: { $0.id == id }) else {
            throw HorizonError.message("That saved camera group no longer exists.")
        }
        groups.removeAll { $0.id == id }
        if selectedGroupID == id { selectedGroupID = nil }
    }

    public mutating func setCurrentDensity(_ value: Density) throws {
        if let group = selectedGroup {
            try saveGroup(SavedCameraGroup(id: group.id, name: group.name,
                cameraIDs: group.cameraIDs, density: value))
        } else { density = value }
    }

    public mutating func toggleFavorite(_ cameraID: String) throws {
        guard !cameraID.isEmpty else { throw HorizonError.message("A camera identifier is required.") }
        if favoriteIDs.contains(cameraID) { favoriteIDs.remove(cameraID) }
        else { favoriteIDs.insert(cameraID) }
    }

    public func cameras(from available: [HorizonCamera]) -> [HorizonCamera] {
        let dashboard = available.filter { $0.settings.ui?.dashboard != false }
        let scoped = selectedGroup.map { group in
            group.cameraIDs.compactMap { id in dashboard.first { $0.id == id } }
        } ?? dashboard
        let favorites = scoped.filter { favoriteIDs.contains($0.id) }
        if favoritesOnly { return favorites }
        if selectedGroup != nil { return scoped }
        return favorites + scoped.filter { !favoriteIDs.contains($0.id) }
    }

    private enum CodingKeys: String, CodingKey { case favoriteIDs, density, favoritesOnly, groups, selectedGroupID }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        favoriteIDs = try values.decode(Set<String>.self, forKey: .favoriteIDs)
        guard !favoriteIDs.contains("") else {
            throw DecodingError.dataCorruptedError(forKey: .favoriteIDs, in: values,
                debugDescription: "Favorite camera identifiers must not be empty.")
        }
        density = try values.decode(Density.self, forKey: .density)
        favoritesOnly = try values.decode(Bool.self, forKey: .favoritesOnly)
        if values.contains(.groups) { groups = try values.decode([SavedCameraGroup].self, forKey: .groups) }
        else { groups = [] }
        selectedGroupID = try values.decodeIfPresent(UUID.self, forKey: .selectedGroupID)
        guard Set(groups.map(\.id)).count == groups.count,
              Set(groups.map { $0.name.lowercased() }).count == groups.count,
              selectedGroupID == nil || groups.contains(where: { $0.id == selectedGroupID }) else {
            throw DecodingError.dataCorruptedError(forKey: .groups, in: values,
                debugDescription: "Saved camera groups contain duplicate identities/names or an unavailable selection.")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(favoriteIDs.sorted(), forKey: .favoriteIDs)
        try values.encode(density, forKey: .density)
        try values.encode(favoritesOnly, forKey: .favoritesOnly)
        try values.encode(groups, forKey: .groups)
        try values.encodeIfPresent(selectedGroupID, forKey: .selectedGroupID)
    }
}
