import XCTest
@testable import HorizonCore

final class EventMetadataTests: XCTestCase {
    private func makeEvent(id: String = "event-1", camera: String = "front",
                           subLabel: String? = nil, description: String? = nil) throws -> SearchEvent {
        let value: [String: Any] = [
            "id": id, "camera": camera, "label": "person",
            "sub_label": subLabel as Any? ?? NSNull(),
            "start_time": 100, "end_time": 120, "zones": [],
            "has_clip": false, "has_snapshot": false, "retain_indefinitely": false,
            "data": ["description": description as Any? ?? NSNull()],
        ]
        return try JSONDecoder().decode(SearchEvent.self, from: JSONSerialization.data(withJSONObject: value))
    }

    func testSubLabelRequestMatchesServerWithoutChoosingOwnerCameraOrConfidence() throws {
        let body = try EventSubLabelUpdate("  Delivery person  ")
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(body)) as? [String: Any])
        XCTAssertEqual(value["subLabel"] as? String, "Delivery person")
        XCTAssertEqual(Set(value.keys), Set(["subLabel"]))
        XCTAssertNil(value["camera"])
        XCTAssertNil(value["owner"])
        XCTAssertNil(value["subLabelScore"])
    }

    func testBlankLabelIsAnExplicitClearNotAnOmittedOrNullField() throws {
        let body = try EventSubLabelUpdate(" \n ")
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(body)) as? [String: Any])
        XCTAssertEqual(value["subLabel"] as? String, "")
        XCTAssertFalse(value["subLabel"] is NSNull)
    }

    func testLabelLimitMatchesServerUnicodeCodePointLength() throws {
        XCTAssertNoThrow(try EventSubLabelUpdate(String(repeating: "a", count: 100)))
        XCTAssertThrowsError(try EventSubLabelUpdate(String(repeating: "a", count: 101)))
        XCTAssertNoThrow(try EventSubLabelUpdate(String(repeating: "\u{1F642}", count: 100)))
        XCTAssertThrowsError(try EventSubLabelUpdate(String(repeating: "e\u{301}", count: 51)))
    }

    func testDescriptionPreservesFormattingAndClearsUsingAnEmptyString() throws {
        for text in ["", "First line\n  Second line\n", "  intentional spacing  "] {
            let body = EventDescriptionUpdate(text)
            let value = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(body)) as? [String: Any])
            XCTAssertEqual(Set(value.keys), Set(["description"]))
            XCTAssertEqual(value["description"] as? String, text)
            XCTAssertFalse(value["description"] is NSNull)
        }
    }

    func testMissingAndBlankMetadataShareTheSameEditableBaseline() throws {
        let missing = EventMetadataSnapshot(try makeEvent())
        let blank = try makeEvent(subLabel: "", description: "")
        XCTAssertEqual(missing.subLabel, "")
        XCTAssertEqual(missing.description, "")
        for field in EventMetadataField.allCases {
            XCTAssertNoThrow(try missing.requireUnchanged(blank, field: field))
        }
    }

    func testOpeningExistingWhitespaceDoesNotInventUnsavedLabelEdits() throws {
        let legacy = EventMetadataSnapshot(try makeEvent(subLabel: " Existing label "))
        XCTAssertFalse(legacy.hasSubLabelChanges(" Existing label "))
        XCTAssertTrue(legacy.hasSubLabelChanges("Existing label"))
        let normal = EventMetadataSnapshot(try makeEvent(subLabel: "Existing label"))
        XCTAssertFalse(normal.hasSubLabelChanges(" Existing label "))
        XCTAssertTrue(normal.hasSubLabelChanges("New label"))
    }

    func testLabelConflictDoesNotBlockAnUnchangedDescription() throws {
        let snapshot = EventMetadataSnapshot(try makeEvent(subLabel: "Original", description: "A person"))
        let latest = try makeEvent(subLabel: "Changed elsewhere", description: "A person")
        XCTAssertThrowsError(try snapshot.requireUnchanged(latest, field: .subLabel))
        XCTAssertNoThrow(try snapshot.requireUnchanged(latest, field: .description))
    }

    func testDescriptionConflictDoesNotBlockAnUnchangedLabel() throws {
        let snapshot = EventMetadataSnapshot(try makeEvent(subLabel: "Original", description: "A person"))
        let latest = try makeEvent(subLabel: "Original", description: "Changed elsewhere")
        XCTAssertNoThrow(try snapshot.requireUnchanged(latest, field: .subLabel))
        XCTAssertThrowsError(try snapshot.requireUnchanged(latest, field: .description))
    }

    func testWrongEventOrCameraCannotBecomeAnEditableBaseline() throws {
        var snapshot = EventMetadataSnapshot(try makeEvent())
        for latest in [try makeEvent(id: "other"), try makeEvent(camera: "private")] {
            for field in EventMetadataField.allCases {
                XCTAssertThrowsError(try snapshot.requireUnchanged(latest, field: field))
                XCTAssertThrowsError(try snapshot.confirm(latest, field: field))
            }
        }
    }

    func testConfirmingOneFieldDoesNotSilentlyAcceptAnotherEditorsChanges() throws {
        var snapshot = EventMetadataSnapshot(try makeEvent(subLabel: "Old label", description: "Original notes"))
        let latest = try makeEvent(subLabel: "New label", description: "Someone else's notes")
        try snapshot.confirm(latest, field: .subLabel)
        XCTAssertEqual(snapshot.subLabel, "New label")
        XCTAssertEqual(snapshot.description, "Original notes")
        XCTAssertThrowsError(try snapshot.requireUnchanged(latest, field: .description))
    }

    func testFieldsUseTheExistingRoutesRatherThanInventedMutationEndpoints() {
        XCTAssertEqual(EventMetadataField.subLabel.endpoint, "sub_label")
        XCTAssertEqual(EventMetadataField.description.endpoint, "description")
    }
}
