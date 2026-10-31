import XCTest
@testable import HorizonCore

final class ServerProfileTests: XCTestCase {
    private func profile(name: String = "Home", local: String? = "10.10.20.3") throws -> ServerProfile {
        try ServerProfile(name: name, primary: "https://dvr.example.invalid:8443/horizon", local: local)
    }

    func testNamedProfileNormalizesAddressesWithoutCredentials() throws {
        let value = try profile(name: " Home ")
        XCTAssertEqual(value.name, "Home")
        XCTAssertEqual(value.localAddress?.url.absoluteString, "https://10.10.20.3:8443/horizon")
        XCTAssertEqual(try value.address(for: .primary), value.primaryAddress)
        XCTAssertEqual(try value.address(for: .local), value.localAddress)
    }

    func testLocalIPCanOverridePortWithoutLosingProxyBasePath() throws {
        let value = try profile(local: "192.168.10.4:8971")
        XCTAssertEqual(value.localAddress?.url.absoluteString, "https://192.168.10.4:8971/horizon")
    }

    func testFullLocalURLUsesItsOwnPathAndRequiresNormalHTTPS() throws {
        let value = try profile(local: "https://nas.example.invalid/other")
        XCTAssertEqual(value.localAddress?.url.absoluteString, "https://nas.example.invalid/other")
        XCTAssertThrowsError(try profile(local: "http://10.10.20.3"))
        XCTAssertThrowsError(try ServerProfile(name: "Home", primary: "http://dvr.example.invalid"))
    }

    func testPrivateIPv6UsesBracketedHTTPSAuthority() throws {
        let value = try profile(local: "fd12:3456::1")
        XCTAssertEqual(value.localAddress?.url.absoluteString, "https://[fd12:3456::1]:8443/horizon")
    }

    func testDNSCandidatesExcludePublicLoopbackAndLinkLocalAddresses() {
        for value in ["10.0.0.1", "172.16.1.1", "172.31.255.254", "192.168.1.3", "fc00::1", "fdff::1234"] {
            XCTAssertTrue(LocalServerAddress.isPrivateIP(value), value)
        }
        for value in ["8.8.8.8", "172.32.0.1", "127.0.0.1", "169.254.1.1", "::1", "fe80::1", "2001:4860::1", "invalid"] {
            XCTAssertFalse(LocalServerAddress.isPrivateIP(value), value)
        }
    }

    func testBareLocalInputRejectsPublicIPCredentialsAndAmbiguousPaths() {
        for value in ["8.8.8.8", "127.0.0.1", "user:password@10.10.20.3", "10.10.20.3/path", "10.10.20.3?token=secret", "10.10.20.3#fragment"] {
            XCTAssertThrowsError(try profile(local: value), value)
        }
        XCTAssertThrowsError(try profile(local: "https://user:password@10.10.20.3"))
        XCTAssertThrowsError(try profile(local: "https://nas.example.invalid/api"))
    }

    func testInvalidNamesAndMissingLocalRouteAreExplicitErrors() throws {
        for name in ["", "  ", "Home\nNAS", String(repeating: "a", count: 81)] {
            XCTAssertThrowsError(try profile(name: name))
        }
        let value = try profile(local: nil)
        XCTAssertThrowsError(try value.address(for: .local))
    }

    func testMultipleProfilesAndSelectionRoundTripWithoutSessionFields() throws {
        var library = ServerProfileLibrary()
        let home = try profile()
        let other = try ServerProfile(name: "Other", primary: "https://other.example.invalid")
        try library.save(home)
        try library.save(other)
        try library.select(ServerProfileSelection(profileID: home.id, route: .local))
        let data = try JSONEncoder().encode(library)
        XCTAssertEqual(try JSONDecoder().decode(ServerProfileLibrary.self, from: data), library)
        let text = String(decoding: data, as: UTF8.self)
        for key in ["cookies", "password", "username", "token"] { XCTAssertFalse(text.contains("\"\(key)\"")) }
    }

    func testDuplicateNamesAndUnknownSelectionsDoNotMutateLibrary() throws {
        var library = ServerProfileLibrary()
        try library.save(profile())
        let original = library
        XCTAssertThrowsError(try library.save(profile(name: "HOME")))
        XCTAssertThrowsError(try library.select(ServerProfileSelection(profileID: UUID(), route: .primary)))
        XCTAssertThrowsError(try library.remove(UUID()))
        XCTAssertEqual(library, original)
    }

    func testAddressAdoptionPreservesExplicitProfileAndLocalRoute() throws {
        var library = ServerProfileLibrary()
        let value = try profile()
        try library.save(value)
        let selection = ServerProfileSelection(profileID: value.id, route: .local)
        try library.select(selection)
        XCTAssertEqual(try library.adopt(value.address(for: .local)), selection)
        XCTAssertEqual(library.profiles.count, 1)
    }

    func testLegacyAddressAdoptionCreatesOneProfileAndUniqueNames() throws {
        var library = ServerProfileLibrary()
        let address = try ServerAddress("https://dvr.example.invalid")
        let first = try library.adopt(address)
        XCTAssertEqual(try library.address(for: first), address)
        XCTAssertEqual(try library.adopt(address), first)
        try library.select(nil)
        let second = try library.adopt(address)
        XCTAssertNotEqual(first.profileID, second.profileID)
        XCTAssertEqual(Set(library.profiles.map(\.name)).count, 2)
    }

    func testRemovingLocalAddressChangesSelectionToPrimaryWithoutInventingEndpoint() throws {
        var library = ServerProfileLibrary()
        let value = try profile()
        try library.save(value)
        try library.select(ServerProfileSelection(profileID: value.id, route: .local))
        try library.save(ServerProfile(id: value.id, name: value.name, primary: value.primaryAddress.url.absoluteString))
        XCTAssertEqual(library.selection?.route, .primary)
        XCTAssertNil(try library.profile(value.id).localAddress)
    }

    func testDeletingProfileDoesNotDeleteOtherProfilesOrTheirSelection() throws {
        var library = ServerProfileLibrary()
        let first = try profile()
        let second = try profile(name: "Other")
        try library.save(first)
        try library.save(second)
        let selected = ServerProfileSelection(profileID: second.id, route: .primary)
        try library.select(selected)
        try library.remove(first.id)
        XCTAssertEqual(library.profiles, [second])
        XCTAssertEqual(library.selection, selected)
        try library.remove(second.id)
        XCTAssertNil(library.selection)
    }

    func testMalformedMetadataIsRejectedInsteadOfDefaulted() throws {
        let value = try profile()
        let encoded = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
        for json in [
            #"{"version":2,"profiles":[]}"#,
            #"{"version":1,"profiles":"invalid"}"#,
            "{\"version\":1,\"profiles\":[\(encoded),\(encoded)]}",
            "{\"version\":1,\"profiles\":[],\"selection\":{\"profileID\":\"\(value.id)\",\"route\":\"primary\"}}",
            "{\"version\":1,\"profiles\":[\(encoded)],\"selection\":{\"profileID\":\"\(value.id)\",\"route\":\"unknown\"}}",
        ] {
            XCTAssertThrowsError(try JSONDecoder().decode(ServerProfileLibrary.self, from: Data(json.utf8)))
        }
    }

    func testSavedSessionRequiresExactProfileOriginPortAndProxyBasePath() throws {
        let value = try profile()
        let record = try ServerProfileSession(profileID: value.id, username: "admin",
            session: SavedSession(server: value.primaryAddress.url.absoluteString, cookies: []))
        XCTAssertNoThrow(try record.requireMatch(profileID: value.id, address: value.primaryAddress))
        XCTAssertThrowsError(try record.requireMatch(profileID: UUID(), address: value.primaryAddress))
        for url in ["https://other.example.invalid:8443/horizon", "https://dvr.example.invalid/horizon",
                    "https://dvr.example.invalid:8443/other", "http://dvr.example.invalid:8443/horizon",
                    "https://10.10.20.3:8443/horizon"] {
            XCTAssertThrowsError(try record.requireMatch(profileID: value.id, address: ServerAddress(url)))
        }
    }

    func testMigratedSessionMayLearnUsernameButEmptyAccountIsRejected() throws {
        let value = try profile()
        let saved = SavedSession(server: value.primaryAddress.url.absoluteString, cookies: [])
        let imported = try ServerProfileSession(profileID: value.id, username: nil, session: saved)
        XCTAssertNoThrow(try imported.requireMatch(profileID: value.id, address: value.primaryAddress))
        XCTAssertThrowsError(try ServerProfileSession(profileID: value.id, username: "", session: saved))
        let restored = try JSONDecoder().decode(ServerProfileSession.self, from: JSONEncoder().encode(imported))
        XCTAssertNoThrow(try restored.requireMatch(profileID: value.id, address: value.primaryAddress))
    }
}
