import AppKit
import SwiftUI
import XCTest
@testable import NativeAgent

final class ProviderUpdateSnapshotTests: XCTestCase {
    @MainActor
    func testProviderUpdatePanelInBothThemes() async throws {
        guard let destination = ProcessInfo.processInfo.environment["NATIVEAGENT_SNAPSHOT_DIR"] else { throw XCTSkip("Set NATIVEAGENT_SNAPSHOT_DIR to render provider updates.") }
        _ = NSApplication.shared
        let suite = "ProviderUpdateSnapshots.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = ProviderUpdateService(fetch: { url in
            if url.host == "x.ai" { throw URLError(.notConnectedToInternet) }
            return Data("2.1.10".utf8)
        }, probe: { cli, _ in cli == .claude ? "2.1.9" : "1.0.1" })
        let controller = ProviderUpdateController(defaults: defaults, service: service,
            paths: { [.claude: "/fixture/claude", .grok: "/fixture/grok"] }, refreshModels: { .refreshed(6) })
        controller.start(); await controller.waitForCheck()
        XCTAssertTrue(controller.results.first!.updateAvailable)
        XCTAssertNotNil(controller.results.last!.issue)
        try FileManager.default.createDirectory(atPath: destination, withIntermediateDirectories: true)
        for dark in [true, false] {
            let content = ProviderUpdatesSettingsView(controller: controller).padding(28)
                .frame(width: 700, height: 880, alignment: .topLeading).background(Studio.canvas)
                .tint(AccentChoice.mint.color).accentColor(AccentChoice.mint.color)
                .environment(\.colorScheme, dark ? .dark : .light)
            let view = NSHostingView(rootView: content)
            view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 880), styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = view; window.orderFront(nil)
            try await Task.sleep(for: .milliseconds(200)); view.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try data.write(to: URL(fileURLWithPath: destination).appendingPathComponent("provider-updates-\(dark ? "dark" : "light").png"))
            XCTAssertGreaterThan(data.count, 10_000)
            window.orderOut(nil); window.contentView = nil
        }
        await controller.shutdown()
    }
}
