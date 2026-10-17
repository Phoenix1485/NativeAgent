import AppKit
import SwiftUI
import XCTest
@testable import NativeAgent

final class ArchivePresentationTests: XCTestCase {
    func testCustomDatesIncludeTheWholeLastDayAcrossDaylightSaving() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let date = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 12)))
        let query = ArchiveDateFilter.custom.query(search: "  design  ", from: date, through: date, now: date, calendar: calendar)
        let start = try XCTUnwrap(query.archivedFrom), end = try XCTUnwrap(query.archivedBefore)
        XCTAssertEqual(query.search, "design")
        XCTAssertEqual(calendar.component(.day, from: start), 8)
        XCTAssertEqual(calendar.component(.day, from: end), 9)
        XCTAssertEqual(calendar.component(.hour, from: start), 0)
        XCTAssertEqual(end.timeIntervalSince(start), 23 * 3600, "The entire local date is included even on a short DST day.")
    }

    func testRecentDatePresetIncludesTodayAndAnyDateRemovesBounds() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 17, hour: 12)))
        let recent = ArchiveDateFilter.lastWeek.query(search: "", from: now, through: now, now: now, calendar: calendar)
        XCTAssertEqual(calendar.component(.day, from: try XCTUnwrap(recent.archivedFrom)), 11)
        XCTAssertEqual(calendar.component(.day, from: try XCTUnwrap(recent.archivedBefore)), 18)
        let all = ArchiveDateFilter.any.query(search: "archive", from: now, through: now, now: now, calendar: calendar)
        XCTAssertNil(all.archivedFrom)
        XCTAssertNil(all.archivedBefore)
        XCTAssertEqual(all.search, "archive")
    }

    @MainActor
    func testRenderArchiveUsingSelectedAccents() async throws {
        guard let destination = ProcessInfo.processInfo.environment["NATIVEAGENT_SNAPSHOT_DIR"] else {
            throw XCTSkip("Set NATIVEAGENT_SNAPSHOT_DIR to render archive appearance.")
        }
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "ArchiveSnapshots.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let database = try DatabaseActor(url: directory.appendingPathComponent("library.sqlite3"))
        let model = WorkspaceViewModel(provider: SettingsTestProvider(), database: database, files: FileService(), git: GitService(), automaticallyRestore: false, preferences: defaults, credentials: MemoryCredentials(), chatGPTCredentials: MemoryChatGPTCredentials(), aiTokens: MemoryAITokens())
        let fixtures: [(String, Int, Int)] = [
            ("Website launch checklist", 2, 24_000),
            ("Design review and saved attachments", 8, 640_000),
            ("Long architecture exploration", 16, 12 * 1_024 * 1_024),
            ("Earlier navigation ideas", 24, 180_000)
        ]
        for (title, days, bytes) in fixtures {
            let chat = Conversation(title: title)
            try await database.save(conversation: chat)
            try await database.saveDraft(String(repeating: "x", count: bytes), conversationID: chat.id)
            try await database.archiveConversation(id: chat.id, now: Date.now.addingTimeInterval(-Double(days) * 86_400))
        }
        await model.loadArchive()
        XCTAssertEqual(model.archiveEntries.count, 4)
        try FileManager.default.createDirectory(atPath: destination, withIntermediateDirectories: true)
        for dark in [true, false] {
            model.settings.accent = dark ? .violet : .mint
            model.settings.theme = dark ? .dark : .light
            let view = NSHostingView(rootView: ArchiveView(automaticallyLoad: false).environmentObject(model))
            view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let size = NSSize(width: 700, height: 620)
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = view
            window.orderFront(nil)
            defer { window.orderOut(nil) }
            view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(150))
            view.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try data.write(to: URL(fileURLWithPath: destination).appendingPathComponent(dark ? "archive-violet-dark.png" : "archive-mint-light.png"))
            XCTAssertEqual(view.bounds.width, 700)
            XCTAssertEqual(view.bounds.height, 620)
        }
        await model.shutdown()
    }
}
