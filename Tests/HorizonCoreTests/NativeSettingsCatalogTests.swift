import XCTest
@testable import HorizonCore

final class NativeSettingsCatalogTests: XCTestCase {
    private func value(_ text: String) throws -> NativeSettingValue {
        try JSONDecoder().decode(NativeSettingValue.self, from: Data(text.utf8))
    }

    private func schema() throws -> NativeSettingsSchema {
        NativeSettingsSchema(document: try value(##"""
        {"type":"object","properties":{
          "mqtt":{"type":"object","properties":{"password":{"type":"string","writeOnly":true}}},
          "cameras":{"type":"object","additionalProperties":{"$ref":"#/$defs/Camera"}},
          "notifications":{"$ref":"#/$defs/Notifications"}},
        "$defs":{
          "Camera":{"type":"object","properties":{"notifications":{"$ref":"#/$defs/Notifications"},
            "labels":{"type":"array","items":{"type":"string"}}}},
          "Notifications":{"type":"object","properties":{"cooldown":{"type":"integer"},"enabled":{"type":"boolean"}}}}}
        """##))
    }

    private func config() throws -> NativeSettingValue {
        try value(#"{"mqtt":{"password":"do-not-search-me"},"notifications":{"cooldown":20},"cameras":{"deck":{"notifications":{"enabled":false,"cooldown":30},"labels":["private-label-value"]},"hidden":{"notifications":{"cooldown":90}}}}"#)
    }

    func testTaskCategoriesKeepUnknownServerSettingsAccessible() {
        XCTAssertEqual(NativeSettingsSection.section(for: "record"), .recording)
        XCTAssertEqual(NativeSettingsSection.section(for: "motion"), .detection)
        XCTAssertEqual(NativeSettingsSection.section(for: "apns"), .alerts)
        XCTAssertEqual(NativeSettingsSection.section(for: "auth"), .security)
        XCTAssertEqual(NativeSettingsSection.section(for: "future_server_setting"), .advanced)
    }

    func testSearchFindsNestedFieldsButNeverUnauthorizedCameraPaths() throws {
        let result = NativeSettingsCatalog.search("cooldown", at: [], schema: try schema(),
            values: try config(), allowedCameraIDs: ["deck"])
        XCTAssertEqual(Set(result.entries.map(\.path)), [
            ["notifications", "cooldown"], ["cameras", "deck", "notifications", "cooldown"],
        ])
        XCTAssertTrue(result.unsupportedPaths.isEmpty)
    }

    func testSearchUsesSchemaNamesNotPrivateConfigurationValues() throws {
        for query in ["do-not-search-me", "private-label-value"] {
            let result = NativeSettingsCatalog.search(query, at: [], schema: try schema(),
                values: try config(), allowedCameraIDs: ["deck"])
            XCTAssertTrue(result.entries.isEmpty)
        }
        let result = NativeSettingsCatalog.search("password", at: [], schema: try schema(),
            values: try config(), allowedCameraIDs: ["deck"])
        XCTAssertEqual(result.entries.map(\.path), [["mqtt", "password"]])
    }

    func testSearchSupportsCameraAndSettingTermsWithoutChangingDraftValues() throws {
        let values = try config()
        let result = NativeSettingsCatalog.search("DECK cooldown", at: [], schema: try schema(),
            values: values, allowedCameraIDs: ["deck"])
        XCTAssertEqual(result.entries.map(\.path), [["cameras", "deck", "notifications", "cooldown"]])
        XCTAssertEqual(values, try config())
    }

    func testSearchIsScopedToCurrentSectionAndBounded() throws {
        let result = NativeSettingsCatalog.search("cooldown", at: ["cameras", "deck"], schema: try schema(),
            values: try config(), allowedCameraIDs: ["deck"])
        XCTAssertEqual(result.entries.map(\.path), [["cameras", "deck", "notifications", "cooldown"]])
        let bounded = NativeSettingsCatalog.search("notifications", at: [], schema: try schema(),
            values: try config(), allowedCameraIDs: ["deck"], limit: 1)
        XCTAssertEqual(bounded.entries.count, 1)
        XCTAssertTrue(bounded.limited)
    }

    func testUnavailableSchemaBranchIsReportedWithoutHidingOtherMatches() throws {
        let document = try value(##"{"type":"object","properties":{"broken":{"$ref":"#/$defs/Missing"},"cooldown":{"type":"integer"}}}"##)
        let result = NativeSettingsCatalog.search("cooldown", at: [], schema: NativeSettingsSchema(document: document),
            values: .object([:]), allowedCameraIDs: [])
        XCTAssertEqual(result.entries.map(\.path), [["cooldown"]])
        XCTAssertEqual(result.unsupportedPaths, [["broken"]])
    }

    func testEmptySearchAndRevokedSearchRootProduceNoEntries() throws {
        let empty = NativeSettingsCatalog.search(" ", at: [], schema: try schema(),
            values: try config(), allowedCameraIDs: ["deck"])
        XCTAssertTrue(empty.entries.isEmpty)
        let revoked = NativeSettingsCatalog.search("cooldown", at: ["cameras", "hidden"], schema: try schema(),
            values: try config(), allowedCameraIDs: ["deck"])
        XCTAssertTrue(revoked.entries.isEmpty)
    }
}
