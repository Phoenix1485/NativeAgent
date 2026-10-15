import XCTest
@testable import NativeAgent

@MainActor
final class AppUpdaterTests: XCTestCase {
    func testLaunchCheckRespectsOptOutAndAvoidsRepeatedChecks() {
        let now = Date()
        XCTAssertTrue(AppUpdater.shouldCheckAtLaunch(enabled: true, lastCheck: nil, now: now))
        XCTAssertFalse(AppUpdater.shouldCheckAtLaunch(enabled: false, lastCheck: nil, now: now))
        XCTAssertFalse(AppUpdater.shouldCheckAtLaunch(enabled: true, lastCheck: now.addingTimeInterval(-60), now: now))
        XCTAssertTrue(AppUpdater.shouldCheckAtLaunch(enabled: true, lastCheck: now.addingTimeInterval(-901), now: now))
    }
    func testUpdatesRequireHTTPSAndAnEd25519PublicKey() {
        let key = Data(repeating: 1, count: 32).base64EncodedString()
        XCTAssertTrue(AppUpdater.validConfiguration(["SUFeedURL": "https://example.com/appcast.xml", "SUPublicEDKey": key]))
        for url in ["http://example.com/feed", "file:///tmp/feed", "https://user:password@example.com/feed", "not a url"] {
            XCTAssertFalse(AppUpdater.validConfiguration(["SUFeedURL": url, "SUPublicEDKey": key]))
        }
        for invalid in ["", "not-a-key", Data(repeating: 1, count: 31).base64EncodedString()] {
            XCTAssertFalse(AppUpdater.validConfiguration(["SUFeedURL": "https://example.com/feed", "SUPublicEDKey": invalid]))
        }
        XCTAssertFalse(AppUpdater.validConfiguration([:]))
    }
}
