import XCTest
@testable import HorizonCore

final class SavedCameraGroupTests: XCTestCase {
    func testVersion18PreferencesMigrateWithoutLosingFavoritesOrLayout() throws {
        let data = Data(#"{"favoriteIDs":["garden"],"density":"compact","favoritesOnly":true}"#.utf8)
        let value = try JSONDecoder().decode(CameraDashboardPreferences.self, from: data)
        XCTAssertEqual(value.favoriteIDs, ["garden"])
        XCTAssertEqual(value.density, .compact)
        XCTAssertTrue(value.favoritesOnly)
        XCTAssertTrue(value.groups.isEmpty)
        XCTAssertNil(value.selectedGroupID)
    }

    func testGroupOrderWinsOverFavoritesAndNeverWidensCameraAccess() throws {
        var value = CameraDashboardPreferences()
        try value.toggleFavorite("front")
        try value.saveGroup(SavedCameraGroup(name: "Outside",
            cameraIDs: ["garden", "not_allowed", "hidden", "front"], density: .compact))
        XCTAssertEqual(value.cameras(from: try cameras()).map(\.id), ["garden", "front"])
        XCTAssertEqual(value.effectiveDensity, .compact)
    }

    func testFavoritesOnlyIntersectsTheSelectedGroup() throws {
        var value = CameraDashboardPreferences()
        try value.toggleFavorite("front")
        try value.toggleFavorite("driveway")
        try value.saveGroup(SavedCameraGroup(name: "Doors", cameraIDs: ["garden", "front"], density: .comfortable))
        value.favoritesOnly = true
        XCTAssertEqual(value.cameras(from: try cameras()).map(\.id), ["front"])
    }

    func testDeletingSelectedGroupRestoresAllCameraPreferences() throws {
        var value = CameraDashboardPreferences()
        value.density = .oneColumn
        try value.toggleFavorite("garden")
        let group = try SavedCameraGroup(name: "Outside", cameraIDs: ["front"], density: .compact)
        try value.saveGroup(group)
        try value.removeGroup(group.id)
        XCTAssertNil(value.selectedGroupID)
        XCTAssertEqual(value.effectiveDensity, .oneColumn)
        XCTAssertEqual(value.favoriteIDs, ["garden"])
    }

    func testSelectingAllCamerasRetainsSavedGroups() throws {
        var value = CameraDashboardPreferences()
        try value.saveGroup(SavedCameraGroup(name: "Outside", cameraIDs: ["front"], density: .compact))
        try value.selectGroup(nil)
        XCTAssertEqual(value.groups.count, 1)
        XCTAssertNil(value.selectedGroup)
    }

    func testLayoutChangesApplyToSelectedGroupWithoutOverwritingAllCameraLayout() throws {
        var value = CameraDashboardPreferences()
        value.density = .comfortable
        try value.saveGroup(SavedCameraGroup(name: "Doors", cameraIDs: ["front"], density: .compact))
        try value.setCurrentDensity(.oneColumn)
        XCTAssertEqual(value.effectiveDensity, .oneColumn)
        XCTAssertEqual(value.density, .comfortable)
        try value.selectGroup(nil)
        XCTAssertEqual(value.effectiveDensity, .comfortable)
    }

    func testUpdatingExistingGroupDoesNotCreateAnotherGroup() throws {
        var value = CameraDashboardPreferences()
        let group = try SavedCameraGroup(name: "Outside", cameraIDs: ["front"], density: .comfortable)
        try value.saveGroup(group)
        try value.saveGroup(SavedCameraGroup(id: group.id, name: "Entrances",
            cameraIDs: ["garden", "front"], density: .oneColumn))
        XCTAssertEqual(value.groups.count, 1)
        XCTAssertEqual(value.selectedGroup?.cameraIDs, ["garden", "front"])
        XCTAssertEqual(value.selectedGroup?.name, "Entrances")
    }

    func testDuplicateNamesAndUnknownSelectionsFailWithoutChangingState() throws {
        var value = CameraDashboardPreferences()
        try value.saveGroup(SavedCameraGroup(name: "Outside", cameraIDs: ["front"], density: .compact))
        let before = value
        XCTAssertThrowsError(try value.saveGroup(SavedCameraGroup(name: "OUTSIDE",
            cameraIDs: ["garden"], density: .comfortable)))
        XCTAssertThrowsError(try value.selectGroup(UUID()))
        XCTAssertThrowsError(try value.removeGroup(UUID()))
        XCTAssertEqual(value, before)
    }

    func testGroupCodecRoundTripsAndPermissionRemovalDoesNotEraseSelection() throws {
        var value = CameraDashboardPreferences()
        try value.saveGroup(SavedCameraGroup(name: "Night", cameraIDs: ["garden", "front"], density: .oneColumn))
        let restored = try JSONDecoder().decode(CameraDashboardPreferences.self,
            from: JSONEncoder().encode(value))
        XCTAssertEqual(restored, value)
        XCTAssertTrue(restored.cameras(from: []).isEmpty)
        XCTAssertNotNil(restored.selectedGroup)
    }

    func testInvalidGroupNamesAndCameraListsAreRejected() {
        for name in ["", "  ", String(repeating: "a", count: 81), "Night\nDoors"] {
            XCTAssertThrowsError(try SavedCameraGroup(name: name, cameraIDs: ["front"], density: .compact))
        }
        for ids in [[], [""], ["front", "front"]] {
            XCTAssertThrowsError(try SavedCameraGroup(name: "Outside", cameraIDs: ids, density: .comfortable))
        }
    }

    func testDanglingPersistedSelectionIsNotSilentlyDiscarded() {
        let json = """
        {"favoriteIDs":[],"density":"compact","favoritesOnly":false,"groups":[],
        "selectedGroupID":"\(UUID().uuidString)"}
        """
        XCTAssertThrowsError(try JSONDecoder().decode(CameraDashboardPreferences.self, from: Data(json.utf8)))
    }

    private func cameras() throws -> [HorizonCamera] {
        try JSONDecoder().decode(HorizonConfiguration.self, from: Data("""
        {"cameras":{
          "front":{"enabled":true,"live":{"streams":{"Main":"front"}},"ui":{"order":1}},
          "garden":{"enabled":true,"live":{"streams":{"Main":"garden"}},"ui":{"order":2}},
          "hidden":{"enabled":true,"live":{"streams":{"Main":"hidden"}},"ui":{"dashboard":false,"order":3}},
          "driveway":{"enabled":true,"live":{"streams":{"Main":"driveway"}},"ui":{"order":4}}
        }}
        """.utf8)).orderedCameras
    }
}
