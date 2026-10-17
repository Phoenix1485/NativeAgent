import AppKit
import SwiftUI
import XCTest
@testable import NativeAgent

final class LibraryToolsSnapshotTests: XCTestCase {
    @MainActor
    func testStorageAndMessageBookmarksPanelsInLightAndDark() async throws {
        guard let destination = ProcessInfo.processInfo.environment["NATIVEAGENT_SNAPSHOT_DIR"] else {
            throw XCTSkip("Set NATIVEAGENT_SNAPSHOT_DIR to render storage and bookmark panels.")
        }
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let cache = root.appendingPathComponent("FixtureCache", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "LibraryToolsSnapshots.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let database = try DatabaseActor(url: root.appendingPathComponent("library.sqlite3"))
        let model = WorkspaceViewModel(provider: SettingsTestProvider(), database: database, files: FileService(), git: GitService(), automaticallyRestore: false, preferences: defaults, credentials: MemoryCredentials(), chatGPTCredentials: MemoryChatGPTCredentials(), aiTokens: MemoryAITokens())
        // The actual FeaturePanel resolves this controller; the real application cache is never scanned.
        let library = LibraryToolsController(database: database, cacheRoot: cache)
        model.libraryTools = library
        model.settings.accent = .mint
        let titles = ["Website release checklist", "Architecture review and notes", "API integration experiments", "Design system refinements", "Earlier landing page exploration", "Saved research and image references"]
        for (index, title) in titles.enumerated() {
            let chat = Conversation(title: title)
            try await database.save(conversation: chat)
            try await database.saveDraft(String(repeating: "Saved local context. ", count: (index + 1) * 1_000), conversationID: chat.id)
            let message = TimelineEntry(kind: index % 2 == 0 ? .agentMessage : .userMessage, title: index % 2 == 0 ? "Assistant" : "You",
                                        text: index == 0 ? "Before release, verify the navigation labels, keyboard shortcuts, and restored chat state. The checklist should remain easy to scan." : "Keep the database queries bounded and use stable identifiers when navigating back to an earlier message.")
            try await database.save(entry: message, conversationID: chat.id)
            if index == 0 || index == 4 {
                _ = try await database.saveMessageBookmark(conversationID: chat.id, messageID: message.id, label: index == 0 ? "Release checklist" : "Earlier navigation decision")
            }
            if index >= 4 { try await database.archiveConversation(id: chat.id, now: Date.now.addingTimeInterval(-Double(index) * 86_400)) }
            if index == 5 {
                let attachment = ContextAttachment(kind: .attachment, title: "Reference.png", text: "Saved reference notes", mediaData: Data(repeating: 3, count: 192 * 1_024), mimeType: "image/png")
                try await database.saveFeature([attachment], kind: "context", id: chat.id.uuidString, conversationID: chat.id)
            }
        }
        try Data(repeating: 1, count: 64 * 1_024).write(to: cache.appendingPathComponent("preview.cache"))
        _ = try await database.backupLibrary()
        await library.refreshStorage()
        await library.loadStorage()
        await library.loadBookmarks()
        XCTAssertEqual(library.storageEntries.count, titles.count)
        XCTAssertEqual(library.bookmarks.count, 2)
        XCTAssertEqual(library.diskStorage.cacheBytes, 64 * 1_024)
        try FileManager.default.createDirectory(atPath: destination, withIntermediateDirectories: true)
        for dark in [true, false] {
            model.settings.theme = dark ? .dark : .light
            for panel in [WorkspaceCommand.storage, .bookmarks] {
                model.features.panel = panel
                let view = FeaturePanel(features: model.features).environmentObject(model)
                try await render(view, name: (panel == .storage ? "storage" : "bookmarks") + (dark ? "-dark" : "-light"), dark: dark, destination: destination)
            }
        }
        await model.shutdown()
    }

    @MainActor
    private func render<Content: View>(_ content: Content, name: String, dark: Bool, destination: String) async throws {
        let size = NSSize(width: 760, height: 650)
        let view = NSHostingView(rootView: content.frame(width: size.width, height: size.height).background(Studio.canvas).environment(\.colorScheme, dark ? .dark : .light))
        view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        try await Task.sleep(for: .milliseconds(300))
        view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: destination).appendingPathComponent(name + ".png"))
        XCTAssertEqual(Int(view.bounds.width), 760)
        XCTAssertEqual(Int(view.bounds.height), 650)
        XCTAssertGreaterThan(data.count, 10_000)
    }
}
