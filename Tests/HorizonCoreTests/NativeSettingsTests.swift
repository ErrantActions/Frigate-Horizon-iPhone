import XCTest
@testable import HorizonCore

final class NativeSettingsTests: XCTestCase {
    private func value(_ text: String) throws -> NativeSettingValue {
        try JSONDecoder().decode(NativeSettingValue.self, from: Data(text.utf8))
    }

    private var config: String {
        #"{"apns":{"enabled":false,"private_key_file":"/config/apns.p8"},"notifications":{"enabled":false,"cooldown":20},"cameras":{"front":{"enabled":true,"notifications":{"enabled":false,"cooldown":30},"review":{"alerts":{"labels":["person","vehicle"],"required_zones":["driveway"]},"detections":{"labels":["animal"]}},"ffmpeg":{"inputs":[{"path":"__FRIGATE_SAVED_CREDENTIAL__","roles":["record","detect"]}]}}},"unknown":{"keep":true}}"#
    }

    func testJSONRoundTripPreservesBooleansIntegersArraysAndUnknownValues() throws {
        let original = try value(config)
        XCTAssertEqual(try JSONDecoder().decode(NativeSettingValue.self, from: JSONEncoder().encode(original)), original)
        XCTAssertEqual(try value("true"), .bool(true))
        XCTAssertEqual(try value("9223372036854775807"), .integer(Int64.max))
        XCTAssertEqual(try value("1.25"), .number(1.25))
    }

    func testPayloadContainsOnlyExplicitlyChangedFieldsAndNeverRestarts() throws {
        var draft = NativeSettingsDraft(document: try value(config))
        try draft.set(.integer(60), at: ["cameras", "front", "notifications", "cooldown"])
        let bytes = try JSONEncoder().encode(draft.update())
        let body = try value(String(decoding: bytes, as: UTF8.self))
        XCTAssertEqual(body["requires_restart"], .integer(1))
        XCTAssertEqual(body["config_data"], try value(#"{"cameras":{"front":{"notifications":{"cooldown":60}}}}"#))
        XCTAssertNil(body["update_topic"])
        XCTAssertNil(body["replace_paths"])
        XCTAssertNil(body["skip_save"])
    }

    func testNativeLabelsRemainVehicleAndAnimalWithoutCoarseCategoryRelabeling() throws {
        var draft = NativeSettingsDraft(document: try value(config))
        try draft.set(.array([.string("person"), .string("vehicle"), .string("animal")]),
            at: ["cameras", "front", "review", "alerts", "labels"])
        XCTAssertEqual(draft.changes.count, 1)
        XCTAssertEqual(draft.changes[0].after, try value(#"["person","vehicle","animal"]"#))
        XCTAssertEqual(draft.changes[0].afterSummary, "person, vehicle, animal")
        XCTAssertEqual(draft.document.value(at: ["cameras", "front", "review", "alerts", "required_zones"]),
            try value(#"["driveway"]"#))
    }

    func testArrayChangesAreWholeListsAndPreserveUneditedObjectFields() throws {
        var draft = NativeSettingsDraft(document: try value(#"{"entries":[{"name":"old","unknown":7},{"name":"keep","flag":true}]}"#))
        try draft.set(.string("new"), at: ["entries", "0", "name"])
        XCTAssertEqual(draft.changes.map(\.path), [["entries"]])
        XCTAssertEqual(draft.changes[0].after, try value(#"[{"name":"new","unknown":7},{"name":"keep","flag":true}]"#))
    }

    func testMaskedCredentialsCannotBeRewrittenByAnUnrelatedArrayEdit() throws {
        var draft = NativeSettingsDraft(document: try value(config))
        XCTAssertThrowsError(try draft.set(.array([.string("record")]),
            at: ["cameras", "front", "ffmpeg", "inputs", "0", "roles"]))
        XCTAssertTrue(draft.changes.isEmpty)
    }

    func testPrivateKeyMaterialAndComputedOrAmbiguousPathsAreRejected() throws {
        var draft = NativeSettingsDraft(document: try value(config))
        XCTAssertThrowsError(try draft.set(.string("-----BEGIN PRIVATE KEY-----\nsecret"),
            at: ["apns", "private_key_file"]))
        XCTAssertThrowsError(try draft.set(.array([.string("-----BEGIN PRIVATE KEY-----\nsecret")]),
            at: ["custom_keys"]))
        XCTAssertThrowsError(try draft.set(.bool(true), at: ["cameras", "front", "enabled_in_config"]))
        XCTAssertThrowsError(try draft.set(.bool(true), at: ["cameras.front", "enabled"]))
        XCTAssertThrowsError(try draft.set(.bool(true), at: ["cameras", "../front", "enabled"]))
        XCTAssertTrue(draft.changes.isEmpty)
    }

    func testReturningAValueToItsOriginalStateRemovesThePendingEdit() throws {
        var draft = NativeSettingsDraft(document: try value(config))
        try draft.set(.integer(60), at: ["notifications", "cooldown"])
        XCTAssertEqual(draft.changes.count, 1)
        try draft.set(.integer(20), at: ["notifications", "cooldown"])
        XCTAssertTrue(draft.changes.isEmpty)
        XCTAssertThrowsError(try draft.update())
    }

    func testExplicitMapRemovalUsesNullWithoutReplacingUnrelatedKeys() throws {
        var draft = NativeSettingsDraft(document: try value(#"{"filters":{"person":{"threshold":0.8},"vehicle":{"threshold":0.7}}}"#))
        try draft.set(.null, at: ["filters", "vehicle"])
        XCTAssertEqual(try draft.update().configData, try value(#"{"filters":{"vehicle":null}}"#))
        XCTAssertEqual(draft.document.value(at: ["filters", "person", "threshold"]), .number(0.8))
    }

    func testSensitiveReviewSummaryDoesNotExposeCredentialsOrURLs() throws {
        var draft = NativeSettingsDraft(document: try value(#"{"mqtt":{"password":"old"},"camera_url":"rtsp://user:old@example.com/live"}"#))
        try draft.set(.string("new-secret"), at: ["mqtt", "password"])
        try draft.set(.string("rtsp://user:new@example.com/live"), at: ["camera_url"])
        for change in draft.changes {
            XCTAssertTrue(change.sensitive)
            XCTAssertEqual(change.beforeSummary, "Hidden")
            XCTAssertEqual(change.afterSummary, "Hidden")
        }

        func testEmptyRoleCameraListIsExplicitlyShownAsAllCameraAccess() throws {
            var draft = NativeSettingsDraft(document: try value(#"{"auth":{"roles":{"viewer":["front"]}}}"#))
            try draft.set(.array([]), at: ["auth", "roles", "viewer"])
            XCTAssertEqual(draft.changes.first?.afterSummary, "All cameras (empty role list)")
        }
    }

    private func schema() throws -> NativeSettingsSchema {
        NativeSettingsSchema(document: try value("""
        {"type":"object","properties":{
          "notifications":{"$ref":"#/$defs/Notifications"},
          "cameras":{"type":"object","additionalProperties":{"type":"object","properties":{
            "notifications":{"$ref":"#/$defs/Notifications"}}}}},
         "$defs":{"Notifications":{"type":"object","properties":{
          "enabled":{"type":"boolean","title":"Enable notifications"},
          "cooldown":{"type":"integer","minimum":0,"maximum":3600},
          "optional":{"anyOf":[{"type":"number","minimum":0},{"type":"null"}]},
          "mode":{"type":"string","enum":["all","motion"]},
          "computed":{"type":"integer","readOnly":true}}}}}
        """))
    }

    func testSchemaReferencesAndCameraDictionaryPropertiesResolve() throws {
        let schema = try schema()
        let node = try schema.node(at: ["cameras", "front", "notifications", "cooldown"], values: value(config))
        XCTAssertEqual(node["type"], .string("integer"))
        XCTAssertEqual(node["minimum"], .integer(0))
        XCTAssertEqual(try schema.keys(at: ["notifications"], values: value(config)),
            ["computed", "cooldown", "enabled", "mode", "optional"])
    }

    func testSchemaValidatesNumericBoundsAndReadOnlyValues() throws {
        let schema = try schema()
        let node = try schema.node(at: ["notifications", "cooldown"], values: value(config))
        XCTAssertNoThrow(try schema.validate(.integer(0), schema: node))
        XCTAssertThrowsError(try schema.validate(.integer(-1), schema: node))
        XCTAssertThrowsError(try schema.validate(.integer(3601), schema: node))
        XCTAssertThrowsError(try schema.validate(.string("0"), schema: node))
        let readOnly = try schema.node(at: ["notifications", "computed"], values: value(config))
        XCTAssertThrowsError(try schema.validate(.integer(1), schema: readOnly))
    }

    func testEnumsNullableValuesAndArrayRulesUseTheServerSchema() throws {
        let schema = try schema()
        let optional = try schema.node(at: ["notifications", "optional"], values: value(config))
        XCTAssertNoThrow(try schema.validate(.null, schema: optional))
        let mode = try schema.node(at: ["notifications", "mode"], values: value(config))
        XCTAssertThrowsError(try schema.validate(.string("invented"), schema: mode))
        let list = try value(#"{"type":"array","minItems":1,"items":{"type":"string"}}"#)
        XCTAssertThrowsError(try schema.validate(.array([]), schema: list))
        XCTAssertNoThrow(try schema.validate(.array([.string("vehicle")]), schema: list))
    }

    func testRecursiveAndMissingSchemaReferencesFailExplicitly() throws {
        let recursive = NativeSettingsSchema(document: try value(##"{"$defs":{"Loop":{"anyOf":[{"$ref":"#/$defs/Loop"}]}},"$ref":"#/$defs/Loop"}"##))
        XCTAssertThrowsError(try recursive.node(at: [], values: .null))
        let missing = NativeSettingsSchema(document: try value(##"{"$ref":"#/$defs/Missing"}"##))
        XCTAssertThrowsError(try missing.node(at: [], values: .null))
    }

    func testDetectorTaggedUnionUsesCurrentTypeInsteadOfInventingGPUSettings() throws {
        let schema = NativeSettingsSchema(document: try value("""
        {"oneOf":[
          {"type":"object","properties":{"type":{"const":"cpu"},"num_threads":{"type":"integer"}}},
          {"type":"object","properties":{"type":{"const":"edgetpu"},"device":{"type":"string"}}}]}
        """))
        let node = try schema.node(at: [], values: value(#"{"type":"edgetpu","device":"pci:0"}"#))
        XCTAssertNotNil(node["properties"]?["device"])
        XCTAssertNil(node["properties"]?["num_threads"])
    }

    func testIntegerValuesCanUseANumberVariantWithoutBecomingStrings() throws {
        let schema = NativeSettingsSchema(document: try value(#"{"anyOf":[{"type":"string"},{"type":"number"}]}"#))
        let node = try schema.node(at: [], values: .integer(5))
        XCTAssertEqual(node["type"], .string("number"))
        XCTAssertNoThrow(try schema.validate(.integer(5), schema: node))
    }
}
