import XCTest
@testable import HorizonCore

final class BookmarkModelTests: XCTestCase {
    func testBookmarkCreationDoesNotChooseOwnerOrChangeProtection() throws {
        let body = try CreateBookmarkBody(timestamp: 100, endTime: 120, title: "  Front gate  ", notes: "Delivery")
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(body)) as? [String: Any])
        XCTAssertEqual(value["title"] as? String, "Front gate")
        XCTAssertEqual(value["timestamp"] as? Double, 100)
        XCTAssertEqual(value["end_time"] as? Double, 120)
        XCTAssertNil(value["owner"])
        XCTAssertNil(value["protects_footage"])
        XCTAssertNil(value["retain_indefinitely"])
    }

    func testPointBookmarkOmitsAnInventedEndTime() throws {
        let body = try CreateBookmarkBody(timestamp: 100, endTime: nil, title: "Arrival", notes: "")
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(body)) as? [String: Any])
        XCTAssertNil(value["end_time"])
    }

    func testInvalidBookmarkInputsAreRejected() {
        XCTAssertThrowsError(try CreateBookmarkBody(timestamp: .nan, endTime: nil, title: "Note", notes: ""))
        XCTAssertThrowsError(try CreateBookmarkBody(timestamp: -1, endTime: nil, title: "Note", notes: ""))
        XCTAssertThrowsError(try CreateBookmarkBody(timestamp: 100, endTime: 100, title: "Note", notes: ""))
        XCTAssertThrowsError(try CreateBookmarkBody(timestamp: 100, endTime: nil, title: "   ", notes: ""))
        XCTAssertThrowsError(try CreateBookmarkBody(timestamp: 100, endTime: nil, title: "Note",
            notes: String(repeating: "x", count: 4001)))
        XCTAssertThrowsError(try EditBookmarkBody(title: "Note", notes: "", revision: 0))
    }

    func testBookmarkResponsePreservesRevisionPermissionsAndMissingCoverage() throws {
        let bookmark = try JSONDecoder().decode(RecordingBookmark.self, from: Data("""
        {"id":"note-1","camera":"front","timestamp":100,"end_time":null,"title":"Delivery",
        "notes":"Shared note","owner":"viewer","revision":4,"can_edit":false,
        "available_at_anchor":false,"protects_footage":false}
        """.utf8))
        XCTAssertEqual(bookmark.revision, 4)
        XCTAssertFalse(bookmark.canEdit)
        XCTAssertFalse(bookmark.availableAtAnchor)
        XCTAssertFalse(bookmark.protectsFootage)
        XCTAssertNil(bookmark.endTime)
    }
}
