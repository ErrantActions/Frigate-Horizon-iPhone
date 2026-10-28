import XCTest
@testable import HorizonCore

final class LibraryModelTests: XCTestCase {
    func testStandardEventFiltersUseOffsetPaginationAndIntegerMediaFlags() throws {
        var query = EventSearchQuery(after: 100, before: 200)
        query.camera = "front"
        query.label = "person,vehicle"
        query.clipsOnly = true
        query.snapshotsOnly = true
        let items = Dictionary(uniqueKeysWithValues: try query.items(offset: 100).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(query.path, ["events"])
        XCTAssertEqual(items["offset"], "100")
        XCTAssertEqual(items["limit"], "100")
        XCTAssertEqual(items["has_clip"], "1")
        XCTAssertEqual(items["has_snapshot"], "1")
        XCTAssertEqual(items["labels"], "person,vehicle")
    }

    func testSemanticSearchUsesBooleanFlagsAndSimilarityUsesItsOwnMode() throws {
        var query = EventSearchQuery(after: 100, before: 200)
        query.text = "  person carrying a box  "
        query.clipsOnly = true
        var items = Dictionary(uniqueKeysWithValues: try query.items(offset: 0).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(query.path, ["events", "search"])
        XCTAssertEqual(items["query"], "person carrying a box")
        XCTAssertEqual(items["has_clip"], "true")
        XCTAssertEqual(items["search_type"], "description,thumbnail")
        query.text = ""
        query.similarityEventID = "event-123"
        items = Dictionary(uniqueKeysWithValues: try query.items(offset: 0).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(items["search_type"], "similarity")
        XCTAssertEqual(items["event_id"], "event-123")
        query.text = "ambiguous"
        XCTAssertThrowsError(try query.items(offset: 0))
    }

    func testInvalidSearchRangesAreReported() {
        XCTAssertThrowsError(try EventSearchQuery(after: 200, before: 100).items(offset: 0))
        XCTAssertThrowsError(try EventSearchQuery(after: .nan, before: 100).items(offset: 0))
        XCTAssertThrowsError(try EventSearchQuery(after: 100, before: 200).items(offset: -1))
    }

    func testNativeAlarmEventKeepsUnknownConfidenceAndOptionalMetadata() throws {
        let event = try JSONDecoder().decode(SearchEvent.self, from: Data("""
        {"id":"native-1","camera":"front","label":"vehicle","sub_label":null,"start_time":100,
        "end_time":null,"zones":[],"has_clip":true,"has_snapshot":false,"retain_indefinitely":false,
        "data":{"top_score":null,"type":"reolink"}}
        """.utf8))
        XCTAssertNil(event.data.topScore)
        XCTAssertNil(event.endTime)
        XCTAssertEqual(event.data.type, "reolink")
        XCTAssertFalse(event.retainIndefinitely)
    }

    func testExportRequestDefaultsDoNotOptIntoSensitiveMetadata() throws {
        let body = CreateExportBody(name: "Driveway", stream: "main", timestamp: "subtitle", metadataCategories: [])
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(body)) as? [String: Any])
        XCTAssertEqual(value["source"] as? String, "recordings")
        XCTAssertEqual(value["stream"] as? String, "main")
        XCTAssertEqual(value["timestamp"] as? String, "subtitle")
        XCTAssertEqual(value["metadata_categories"] as? [String], [])
    }

    func testStoredExportsCannotEscapeTheirAuthenticatedMediaRoot() throws {
        let address = try ServerAddress("https://example.com/horizon")
        XCTAssertEqual(
            try address.mediaFile("/media/frigate/exports/driveway.mp4", root: "exports").path,
            "/horizon/exports/driveway.mp4"
        )
        XCTAssertTrue(try address.mediaFile("/media/frigate/exports/100% safe.mp4", root: "exports")
            .absoluteString.contains("100%25%20safe.mp4"))
        for path in [
            "https://other.invalid/export.mp4", "/media/frigate/exports/../config.yml",
            "/media/frigate/exports/%2e%2e/config.yml", "/media/frigate/clips/snapshot.jpg",
            "/media/frigate/exports/a%2fb.mp4", "/media/frigate/exports/a%5cb.mp4",
        ] {
            XCTAssertThrowsError(try address.mediaFile(path, root: "exports"))
        }
    }

    func testOnlyTheServerAdminRoleEnablesAdministration() throws {
        for (role, expected) in [("admin", true), ("viewer", false), ("custom", false)] {
            let profile = try JSONDecoder().decode(UserProfile.self, from: Data("""
            {"username":"test","role":"\(role)","allowed_cameras":["front"]}
            """.utf8))
            XCTAssertEqual(profile.isAdmin, expected)
        }
    }

    func testConfigurationCapabilitiesAndRoleMappingsUseServerValues() throws {
        let config = try JSONDecoder().decode(HorizonConfiguration.self, from: Data("""
        {"cameras":{},"semantic_search":{"enabled":false},"auth":{"roles":{
        "admin":[],"viewer":[],"front_only":["front"]}}}
        """.utf8))
        XCTAssertEqual(config.semanticSearch?.enabled, false)
        XCTAssertEqual(config.auth?.roles["front_only"], ["front"])
    }

    func testRejectedActionsCannotBeTreatedAsSuccess() throws {
        let result = try JSONDecoder().decode(APIActionResult.self,
            from: Data(#"{"success":false,"message":"Export queue full"}"#.utf8))
        XCTAssertThrowsError(try result.requireSuccess())
        let queued = try JSONDecoder().decode(APIActionResult.self,
            from: Data(#"{"success":true,"export_id":"job-1","message":"Queued"}"#.utf8))
        XCTAssertNoThrow(try queued.requireSuccess())
        XCTAssertEqual(queued.exportID, "job-1")
    }

    func testProtectedOriginalAvailabilityDoesNotDependOnTheOldClipFlag() throws {
        let item = try JSONDecoder().decode(ProtectedMediaItem.self, from: Data("""
        {"id":"saved-1","camera":"front","start_time":100,"end_time":120,"label":"person",
        "availability":"indexed_local","tiers":["local"],"recordings":2,"has_snapshot":true,
        "has_clip":false,"original_url":"front/start/100/end/120/clip.mp4"}
        """.utf8))
        XCTAssertTrue(item.canReadOriginal)
        let unavailable = try JSONDecoder().decode(ProtectedMediaItem.self, from: Data("""
        {"id":"saved-2","camera":"front","start_time":100,"end_time":120,"label":"person",
        "availability":"archive_unavailable","tiers":["archive"],"recordings":2,
        "has_snapshot":false,"original_url":null}
        """.utf8))
        XCTAssertFalse(unavailable.canReadOriginal)
    }

    func testUnknownProtectedStorageSizesRemainUnknown() throws {
        let usage = try JSONDecoder().decode(ProtectedStorageUsage.self, from: Data("""
        {"recordings":3,"known_bytes":1024,"unknown_size_recordings":1,"total_bytes":null}
        """.utf8))
        XCTAssertNil(usage.totalBytes)
        XCTAssertEqual(usage.knownBytes, 1024)
        XCTAssertEqual(usage.unknownSizeRecordings, 1)
    }
}
