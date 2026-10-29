import XCTest
@testable import HorizonCore

final class CameraDashboardPreferencesTests: XCTestCase {
    func testDefaultsKeepConfiguredOrderAndHideNonDashboardCameras() throws {
        let preferences = CameraDashboardPreferences()
        XCTAssertEqual(preferences.density, .comfortable)
        XCTAssertFalse(preferences.favoritesOnly)
        XCTAssertEqual(preferences.cameras(from: try cameras()).map(\.id), ["front", "garden", "disabled"])
    }

    func testFavoritesAppearFirstWithoutReorderingEitherPartition() throws {
        var preferences = CameraDashboardPreferences()
        try preferences.toggleFavorite("disabled")
        try preferences.toggleFavorite("garden")
        XCTAssertEqual(preferences.cameras(from: try cameras()).map(\.id), ["garden", "disabled", "front"])
    }

    func testFavoritesFilterDoesNotInventPermissionOrRevealHiddenCameras() throws {
        var preferences = CameraDashboardPreferences()
        for id in ["front", "hidden", "not_allowed"] { try preferences.toggleFavorite(id) }
        preferences.favoritesOnly = true
        XCTAssertEqual(preferences.cameras(from: try cameras()).map(\.id), ["front"])
    }

    func testRevokedFavoriteDisappearsWithoutDiscardingThePreference() throws {
        var preferences = CameraDashboardPreferences()
        try preferences.toggleFavorite("front")
        preferences.favoritesOnly = true
        let remaining = try cameras().filter { $0.id != "front" }
        XCTAssertTrue(preferences.cameras(from: remaining).isEmpty)
        XCTAssertTrue(preferences.favoriteIDs.contains("front"))
        XCTAssertEqual(preferences.cameras(from: try cameras()).map(\.id), ["front"])
    }

    func testToggleRemovesAnExistingFavorite() throws {
        var preferences = CameraDashboardPreferences()
        try preferences.toggleFavorite("garden")
        try preferences.toggleFavorite("garden")
        XCTAssertTrue(preferences.favoriteIDs.isEmpty)
    }

    func testEmptyFavoriteIsRejectedWithoutChangingPreferences() {
        var preferences = CameraDashboardPreferences()
        XCTAssertThrowsError(try preferences.toggleFavorite(""))
        XCTAssertEqual(preferences, CameraDashboardPreferences())
    }

    func testEmptyAndUnselectedFavoriteViewsStayEmpty() throws {
        var preferences = CameraDashboardPreferences()
        XCTAssertTrue(preferences.cameras(from: []).isEmpty)
        preferences.favoritesOnly = true
        XCTAssertTrue(preferences.cameras(from: []).isEmpty)
        XCTAssertTrue(preferences.cameras(from: try cameras()).isEmpty)
    }

    func testEveryDensityAndFilterRoundTrips() throws {
        for density in CameraDashboardPreferences.Density.allCases {
            var preferences = CameraDashboardPreferences()
            preferences.density = density
            preferences.favoritesOnly = true
            try preferences.toggleFavorite("garden")
            try preferences.toggleFavorite("front")
            let data = try JSONEncoder().encode(preferences)
            XCTAssertEqual(try JSONDecoder().decode(CameraDashboardPreferences.self, from: data), preferences)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(object["favoriteIDs"] as? [String], ["front", "garden"])
        }
    }

    func testMalformedPreferencesAreNotSilentlyDefaulted() {
        for json in [
            #"{"favoriteIDs":[""],"density":"compact","favoritesOnly":false}"#,
            #"{"favoriteIDs":[],"density":"unknown","favoritesOnly":false}"#,
            #"{"favoriteIDs":[],"density":"compact","favoritesOnly":"yes"}"#,
            #"{"favoriteIDs":[]}"#,
        ] {
            XCTAssertThrowsError(try JSONDecoder().decode(CameraDashboardPreferences.self, from: Data(json.utf8)))
        }
    }

    func testTourCandidatesRetainTheFavoriteSelectionAndOrder() throws {
        var preferences = CameraDashboardPreferences()
        try preferences.toggleFavorite("garden")
        try preferences.toggleFavorite("disabled")
        preferences.favoritesOnly = true
        XCTAssertEqual(preferences.cameras(from: try cameras()).filter(\.isTourCandidate).map(\.id), ["garden"])
    }

    private func cameras() throws -> [HorizonCamera] {
        let configuration = try JSONDecoder().decode(HorizonConfiguration.self, from: Data("""
        {"cameras":{
          "front":{"enabled":true,"live":{"streams":{"Main":"front_main"}},"ui":{"order":1}},
          "garden":{"enabled":true,"live":{"streams":{"Main":"garden_main"}},"ui":{"order":2}},
          "hidden":{"enabled":true,"live":{"streams":{"Main":"hidden_main"}},"ui":{"order":3,"dashboard":false}},
          "disabled":{"enabled":false,"live":{"streams":{"Main":"disabled_main"}},"ui":{"order":4}}
        }}
        """.utf8))
        return configuration.orderedCameras
    }
}
