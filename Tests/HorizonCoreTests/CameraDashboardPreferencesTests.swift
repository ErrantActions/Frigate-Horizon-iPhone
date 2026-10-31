import XCTest
@testable import HorizonCore

final class CameraDashboardPreferencesTests: XCTestCase {
    func testDefaultsKeepConfiguredOrderAndHideDisabledAndNonDashboardCameras() throws {
        let preferences = CameraDashboardPreferences()
        XCTAssertEqual(preferences.density, .comfortable)
        XCTAssertFalse(preferences.favoritesOnly)
        XCTAssertEqual(preferences.cameras(from: try cameras()).map(\.id), ["front", "garden"])
    }

    func testFavoritesAppearFirstWithoutRevealingDisabledFavorites() throws {
        var preferences = CameraDashboardPreferences()
        try preferences.toggleFavorite("disabled")
        try preferences.toggleFavorite("garden")
        XCTAssertEqual(preferences.cameras(from: try cameras()).map(\.id), ["garden", "front"])
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

    func testCustomOrderWinsOverFavoritesAndServerOrder() throws {
        var preferences = CameraDashboardPreferences()
        try preferences.setCurrentCameraOrder(["garden", "front"], available: cameras())
        try preferences.toggleFavorite("front")
        XCTAssertEqual(preferences.cameras(from: try cameras()).map(\.id), ["garden", "front"])
        XCTAssertEqual(preferences.cameraOrder, ["garden", "front"])
    }

    func testCustomOrderRoundTripsWithoutChangingOtherPreferences() throws {
        var preferences = CameraDashboardPreferences()
        preferences.density = .compact
        try preferences.toggleFavorite("front")
        try preferences.setCurrentCameraOrder(["garden", "front"], available: cameras())
        let restored = try JSONDecoder().decode(CameraDashboardPreferences.self,
            from: JSONEncoder().encode(preferences))
        XCTAssertEqual(restored, preferences)
        XCTAssertEqual(restored.cameras(from: try cameras()).map(\.id), ["garden", "front"])
        XCTAssertEqual(restored.density, .compact)
        XCTAssertEqual(restored.favoriteIDs, ["front"])
    }

    func testLegacyMissingOrderKeepsFavoritesFirstAndExistingGroups() throws {
        var preferences = CameraDashboardPreferences()
        try preferences.toggleFavorite("garden")
        try preferences.saveGroup(SavedCameraGroup(name: "Doors", cameraIDs: ["front"], density: .oneColumn))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(preferences)) as? [String: Any])
        object.removeValue(forKey: "cameraOrder")
        let restored = try JSONDecoder().decode(CameraDashboardPreferences.self,
            from: JSONSerialization.data(withJSONObject: object))
        XCTAssertTrue(restored.cameraOrder.isEmpty)
        XCTAssertEqual(restored.groups, preferences.groups)
        XCTAssertEqual(restored.selectedGroupID, preferences.selectedGroupID)
        var all = restored
        try all.selectGroup(nil)
        XCTAssertEqual(all.cameras(from: try cameras()).map(\.id), ["garden", "front"])
    }

    func testDisabledCameraReturnsToItsSavedPositionWithoutBeingEnabledByPreferences() throws {
        var preferences = CameraDashboardPreferences()
        try preferences.setCurrentCameraOrder(["garden", "disabled", "front"], available: cameras(disabledEnabled: true))
        XCTAssertEqual(preferences.cameras(from: try cameras()).map(\.id), ["garden", "front"])
        XCTAssertEqual(preferences.cameraOrder, ["garden", "disabled", "front"])
        XCTAssertEqual(preferences.cameras(from: try cameras(disabledEnabled: true)).map(\.id), ["garden", "disabled", "front"])
    }

    func testReorderingVisibleCamerasRetainsDisabledAndRevokedSavedPositions() throws {
        var preferences = CameraDashboardPreferences()
        try preferences.setCurrentCameraOrder(["front", "disabled", "garden"], available: cameras(disabledEnabled: true))
        try preferences.setCurrentCameraOrder(["garden", "front"], available: cameras())
        XCTAssertEqual(preferences.cameraOrder, ["garden", "disabled", "front"])
        let revoked = try cameras(disabledEnabled: true).filter { $0.id != "front" }
        try preferences.setCurrentCameraOrder(["disabled", "garden"], available: revoked)
        XCTAssertEqual(preferences.cameraOrder, ["disabled", "garden", "front"])
        XCTAssertEqual(preferences.cameras(from: revoked).map(\.id), ["disabled", "garden"])
    }

    func testFavoritesOnlyReorderingPreservesOtherSavedSlots() throws {
        var preferences = CameraDashboardPreferences()
        try preferences.setCurrentCameraOrder(["front", "disabled", "garden"], available: cameras(disabledEnabled: true))
        try preferences.toggleFavorite("front")
        try preferences.toggleFavorite("garden")
        preferences.favoritesOnly = true
        try preferences.setCurrentCameraOrder(["garden", "front"], available: cameras(disabledEnabled: true))
        XCTAssertEqual(preferences.cameras(from: try cameras(disabledEnabled: true)).map(\.id), ["garden", "front"])
        preferences.favoritesOnly = false
        XCTAssertEqual(preferences.cameras(from: try cameras(disabledEnabled: true)).map(\.id), ["garden", "disabled", "front"])
    }

    func testNewlyEnabledCamerasAppendWithoutResettingCustomOrder() throws {
        var preferences = CameraDashboardPreferences()
        try preferences.setCurrentCameraOrder(["garden", "front"], available: cameras())
        XCTAssertEqual(preferences.cameras(from: try cameras(disabledEnabled: true)).map(\.id), ["garden", "front", "disabled"])
    }

    func testGroupReorderingRetainsUnavailableMembersAndDoesNotChangeGlobalOrder() throws {
        var preferences = CameraDashboardPreferences()
        try preferences.setCurrentCameraOrder(["garden", "front"], available: cameras())
        let group = try SavedCameraGroup(name: "Outside",
            cameraIDs: ["front", "disabled", "garden", "hidden", "not_allowed"], density: .oneColumn)
        try preferences.saveGroup(group)
        try preferences.setCurrentCameraOrder(["garden", "front"], available: cameras())
        XCTAssertEqual(preferences.selectedGroup?.cameraIDs, ["garden", "disabled", "front", "hidden", "not_allowed"])
        XCTAssertEqual(preferences.cameraOrder, ["garden", "front"])
        XCTAssertEqual(preferences.effectiveDensity, .oneColumn)
        XCTAssertEqual(preferences.cameras(from: try cameras()).map(\.id), ["garden", "front"])
        XCTAssertEqual(preferences.cameras(from: try cameras()).filter(\.isTourCandidate).map(\.id), ["garden", "front"])
    }

    func testInvalidOrStaleOrderIsRejectedWithoutChangingPreferences() throws {
        var preferences = CameraDashboardPreferences()
        let original = preferences
        for ids in [[], ["front"], ["front", "front"], ["garden", ""],
                    ["front", "garden", "disabled"], ["front", "garden", "not_allowed"]] {
            XCTAssertThrowsError(try preferences.setCurrentCameraOrder(ids, available: cameras()))
            XCTAssertEqual(preferences, original)
        }
    }

    func testMalformedPersistedOrderIsNotSilentlyDefaulted() {
        for order in ["null", #""front""#, #"["front","front"]"#, #"[""]"#] {
            let json = #"{"favoriteIDs":[],"density":"compact","favoritesOnly":false,"cameraOrder":"# + order + "}"
            XCTAssertThrowsError(try JSONDecoder().decode(CameraDashboardPreferences.self, from: Data(json.utf8)))
        }
    }

    private func cameras(disabledEnabled: Bool = false) throws -> [HorizonCamera] {
        let configuration = try JSONDecoder().decode(HorizonConfiguration.self, from: Data("""
        {"cameras":{
          "front":{"enabled":true,"live":{"streams":{"Main":"front_main"}},"ui":{"order":1}},
          "garden":{"enabled":true,"live":{"streams":{"Main":"garden_main"}},"ui":{"order":2}},
          "hidden":{"enabled":true,"live":{"streams":{"Main":"hidden_main"}},"ui":{"order":3,"dashboard":false}},
          "disabled":{"enabled":\(disabledEnabled),"live":{"streams":{"Main":"disabled_main"}},"ui":{"order":4}}
        }}
        """.utf8))
        return configuration.orderedCameras
    }
}
