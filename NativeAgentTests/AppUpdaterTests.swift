import XCTest
@testable import NativeAgent

@MainActor
final class AppUpdaterTests: XCTestCase {
    func testInstalledVersionUsesBundleMetadataAndDoesNotInventARelease() {
        XCTAssertEqual(AppUpdater.versionLabel(info: ["CFBundleShortVersionString": "0.6.3", "CFBundleVersion": "13"]), "Version 0.6.3 (13)")
        XCTAssertEqual(AppUpdater.versionLabel(info: ["CFBundleShortVersionString": "0.6.2", "CFBundleVersion": "12"]), "Version 0.6.2 (12)")
        XCTAssertEqual(AppUpdater.versionLabel(info: ["CFBundleShortVersionString": "1.0"]), "Version 1.0")
        XCTAssertEqual(AppUpdater.versionLabel(info: [:]), "Development build")
        XCTAssertEqual(AppUpdater.versionLabel(info: ["CFBundleShortVersionString": " ", "CFBundleVersion": "13"]), "Development build")
        XCTAssertEqual(AppUpdater.downloadPageURL.absoluteString, "https://phoenix1485.github.io/NativeAgent/")
        if Bundle.main.bundleIdentifier != "dev.nativeagent.mac" {
            XCTAssertEqual(AppUpdater().installedVersionLabel, "Development build")
        }
    }

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
