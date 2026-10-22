import Foundation
import XCTest
@testable import ArchiveCore

final class RecentArchiveHistoryTests: XCTestCase {
    func testLegacyHistoryIsRemovedWithoutChangingOtherPreferences() throws {
        let name = "ArchiveDesk-history-test-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(["/private/old.zip"], forKey: "recentArchives")
        defaults.set("dark", forKey: "appearance")
        var history = RecentArchiveHistory(defaults: defaults)
        XCTAssertTrue(history.urls.isEmpty)
        XCTAssertNil(defaults.object(forKey: "recentArchives"))
        XCTAssertEqual(defaults.string(forKey: "appearance"), "dark")
        history.record(URL(fileURLWithPath: "/private/new.zip"))
        XCTAssertEqual(history.urls.count, 1)
        XCTAssertNil(defaults.object(forKey: "recentArchives"))
        XCTAssertEqual(RecentArchiveHistory(defaults: defaults).urls, [])
        history.clear()
        XCTAssertTrue(history.urls.isEmpty)
    }

    func testRecentItemsAreDeduplicatedAndBounded() {
        let name = "ArchiveDesk-history-test-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        var history = RecentArchiveHistory(defaults: defaults)
        let urls = (0..<12).map { URL(fileURLWithPath: "/private/\($0).zip") }
        for url in urls { history.record(url) }
        XCTAssertEqual(history.urls, Array(urls.reversed().prefix(10)))
        history.record(urls[5])
        XCTAssertEqual(history.urls.first, urls[5])
        XCTAssertEqual(history.urls.count, 10)
        XCTAssertEqual(Set(history.urls).count, 10)
    }
}
