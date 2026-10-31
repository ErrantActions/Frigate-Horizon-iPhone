import Foundation
import Network

public enum ServerConnectionRoute: String, Codable, CaseIterable, Identifiable, Sendable {
    case primary, local
    public var id: String { rawValue }
    public var label: String { self == .primary ? "Primary" : "Local" }
}

public struct ServerProfile: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let name: String
    public let primaryAddress: ServerAddress
    public let localAddress: ServerAddress?

    public init(id: UUID = UUID(), name: String, primary: String, local: String? = nil) throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 80,
              name.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw HorizonError.message("Choose a profile name between 1 and 80 characters.")
        }
        let primaryAddress = try ServerAddress(primary)
        guard primaryAddress.url.scheme == "https" else {
            throw HorizonError.message("Saved profiles require HTTPS with a certificate trusted by this iPhone.")
        }
        self.id = id
        self.name = name
        self.primaryAddress = primaryAddress
        let local = local?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        localAddress = local.isEmpty ? nil : try LocalServerAddress.address(local, relativeTo: primaryAddress)
    }

    public func address(for route: ServerConnectionRoute) throws -> ServerAddress {
        if route == .primary { return primaryAddress }
        guard let localAddress else { throw HorizonError.message("Add a local address to this profile first.") }
        return localAddress
    }

    private enum CodingKeys: String, CodingKey { case id, name, primary, local }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(id: values.decode(UUID.self, forKey: .id),
            name: values.decode(String.self, forKey: .name),
            primary: values.decode(String.self, forKey: .primary),
            local: values.decodeIfPresent(String.self, forKey: .local))
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(name, forKey: .name)
        try values.encode(primaryAddress.url.absoluteString, forKey: .primary)
        try values.encodeIfPresent(localAddress?.url.absoluteString, forKey: .local)
    }
}

public enum LocalServerAddress {
    public static func isPrivateIP(_ text: String) -> Bool {
        let host = text.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if let address = IPv4Address(host) {
            let bytes = Array(address.rawValue)
            return bytes[0] == 10 || (bytes[0] == 172 && (16...31).contains(bytes[1]))
                || (bytes[0] == 192 && bytes[1] == 168)
        }
        if let address = IPv6Address(host) { return address.rawValue.first.map { $0 & 0xfe == 0xfc } == true }
        return false
    }

    public static func address(_ text: String, relativeTo primary: ServerAddress) throws -> ServerAddress {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let result: ServerAddress
        if text.contains("://") {
            result = try ServerAddress(text)
        } else {
            let candidate = IPv6Address(text) != nil ? "[\(text)]" : text
            guard var parts = URLComponents(string: "https://" + candidate),
                  let host = parts.host, isPrivateIP(host),
                  parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
                  parts.path.isEmpty || parts.path == "/" else {
                throw HorizonError.message("Enter a private IP address, optionally with a port, or a full trusted HTTPS address.")
            }
            parts.path = primary.url.path
            parts.port = parts.port ?? primary.url.port
            guard let url = parts.url else { throw HorizonError.invalidAddress }
            result = try ServerAddress(url.absoluteString)
        }
        guard result.url.scheme == "https" else {
            throw HorizonError.message("Local profiles also require HTTPS. An IP address does not bypass certificate validation.")
        }
        return result
    }
}

public struct ServerProfileSelection: Codable, Equatable, Sendable {
    public let profileID: UUID
    public let route: ServerConnectionRoute
    public init(profileID: UUID, route: ServerConnectionRoute) {
        self.profileID = profileID
        self.route = route
    }
}

public struct ServerProfileLibrary: Codable, Equatable, Sendable {
    public private(set) var profiles: [ServerProfile] = []
    public private(set) var selection: ServerProfileSelection?
    public init() {}

    public func profile(_ id: UUID) throws -> ServerProfile {
        guard let profile = profiles.first(where: { $0.id == id }) else {
            throw HorizonError.message("That saved server profile no longer exists.")
        }
        return profile
    }

    public func address(for selection: ServerProfileSelection) throws -> ServerAddress {
        try profile(selection.profileID).address(for: selection.route)
    }

    public mutating func save(_ profile: ServerProfile) throws {
        guard !profiles.contains(where: { $0.id != profile.id && $0.name.lowercased() == profile.name.lowercased() }) else {
            throw HorizonError.message("A server profile with that name already exists.")
        }
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) { profiles[index] = profile }
        else { profiles.append(profile) }
        if selection?.profileID == profile.id, selection?.route == .local, profile.localAddress == nil {
            selection = ServerProfileSelection(profileID: profile.id, route: .primary)
        }
    }

    public mutating func select(_ selection: ServerProfileSelection?) throws {
        if let selection { _ = try address(for: selection) }
        self.selection = selection
    }

    public mutating func remove(_ id: UUID) throws {
        _ = try profile(id)
        profiles.removeAll { $0.id == id }
        if selection?.profileID == id { selection = nil }
    }

    public mutating func adopt(_ address: ServerAddress) throws -> ServerProfileSelection {
        if let selection, try self.address(for: selection) == address { return selection }
        let base = String((address.url.host ?? "My server").prefix(60))
        var name = base
        var suffix = 2
        while profiles.contains(where: { $0.name.lowercased() == name.lowercased() }) {
            name = "\(base) (\(suffix))"
            suffix += 1
        }
        let profile = try ServerProfile(name: String(name.prefix(80)), primary: address.url.absoluteString)
        try save(profile)
        let selected = ServerProfileSelection(profileID: profile.id, route: .primary)
        try select(selected)
        return selected
    }

    private enum CodingKeys: String, CodingKey { case version, profiles, selection }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard try values.decode(Int.self, forKey: .version) == 1 else {
            throw HorizonError.message("This saved profile format is not supported.")
        }
        let profiles = try values.decode([ServerProfile].self, forKey: .profiles)
        guard Set(profiles.map(\.id)).count == profiles.count,
              Set(profiles.map { $0.name.lowercased() }).count == profiles.count else {
            throw HorizonError.message("Saved profiles contain duplicate names or identifiers.")
        }
        self.profiles = profiles
        let selection = try values.decodeIfPresent(ServerProfileSelection.self, forKey: .selection)
        try select(selection)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(1, forKey: .version)
        try values.encode(profiles, forKey: .profiles)
        try values.encodeIfPresent(selection, forKey: .selection)
    }
}

public struct ServerProfileSession: Codable, Sendable {
    public let profileID: UUID
    public let username: String?
    public let session: SavedSession

    public init(profileID: UUID, username: String?, session: SavedSession) throws {
        guard username?.isEmpty != true else { throw HorizonError.message("The saved profile account is invalid.") }
        _ = try ServerAddress(session.server)
        self.profileID = profileID
        self.username = username
        self.session = session
    }

    public func requireMatch(profileID: UUID, address: ServerAddress) throws {
        guard self.profileID == profileID, try ServerAddress(session.server) == address,
              username?.isEmpty != true else {
            throw HorizonError.message("The saved session does not match this profile and address. Sign in again.")
        }
    }
}
