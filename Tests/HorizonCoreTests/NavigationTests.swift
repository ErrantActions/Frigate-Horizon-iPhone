import XCTest
@testable import HorizonCore

final class NavigationTests: XCTestCase {
    func testCompactNavigationHasExactlyFiveDailyDestinations() {
        XCTAssertEqual(HorizonDestination.compactTabs, [.live, .activity, .recordings, .library, .settings])
        XCTAssertEqual(Set(HorizonDestination.compactTabs).count, 5)
    }

    func testEveryWideShortcutHasAVisibleCompactDestination() {
        for destination in HorizonDestination.allCases {
            XCTAssertTrue(HorizonDestination.compactTabs.contains(destination.compactDestination))
        }
        XCTAssertEqual(HorizonDestination.search.compactDestination, .activity)
        XCTAssertEqual(HorizonDestination.exports.compactDestination, .library)
        XCTAssertEqual(HorizonDestination.protectedMedia.compactDestination, .library)
        XCTAssertEqual(HorizonDestination.administration.compactDestination, .settings)
    }

    func testAdministrationShortcutRequiresAdministratorRole() {
        XCTAssertEqual(HorizonDestination.sidebarShortcuts(isAdmin: false), [.search, .exports, .protectedMedia])
        XCTAssertTrue(HorizonDestination.sidebarShortcuts(isAdmin: true).contains(.administration))
    }

    func testCameraHistoryPreservesCameraTimestampAndLocalDay() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: -5 * 3600)!
        let now = Date(timeIntervalSince1970: 1_793_389_200)
        let date = now.addingTimeInterval(-3600)
        let context = try CameraHistoryContext(camera: "deck", at: date,
            allowedCameraIDs: ["deck", "driveway"], now: now, calendar: calendar)
        XCTAssertEqual(context.camera, "deck")
        XCTAssertEqual(context.timestamp, date.timeIntervalSince1970)
        XCTAssertEqual(context.day, calendar.startOfDay(for: date))
    }

    func testCameraHistoryRejectsRevokedCameraAndFutureOrInvalidTime() {
        let now = Date(timeIntervalSince1970: 1000)
        XCTAssertThrowsError(try CameraHistoryContext(camera: "hidden", at: now, allowedCameraIDs: ["deck"], now: now))
        for time in [1001.0, -1.0, Double.infinity, Double.nan] {
            XCTAssertThrowsError(try CameraHistoryContext(camera: "deck", at: Date(timeIntervalSince1970: time),
                allowedCameraIDs: ["deck"], now: now))
        }
    }

    func testHistoricalAccessDoesNotRequireEnablingLiveCamera() throws {
        let now = Date(timeIntervalSince1970: 1000)
        XCTAssertNoThrow(try CameraHistoryContext(camera: "disabled-but-allowed", at: now,
            allowedCameraIDs: ["disabled-but-allowed"], now: now))
    }
}
