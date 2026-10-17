import XCTest
import PDFKit
@testable import NativeAgent

final class LibraryBackupTests: XCTestCase {
    func testBackupRestoreIncludesWALHistoryAndKeepsSafetyCopy() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("library.sqlite3")
        var db: DatabaseActor? = try DatabaseActor(url: url)
        var chat = Conversation(title: "Backed up"); chat.remoteThreadID = "old-remote-session"
        try await db!.save(conversation: chat)
        try await db!.save(entry: .init(kind: .userMessage, title: "You", text: "Keep this"), conversationID: chat.id)
        try await db!.saveDraft("Saved draft", conversationID: chat.id)
        try await db!.saveFeature("Exact constraint", kind: "chat-pins", id: chat.id.uuidString, conversationID: chat.id)
        let backups = try await db!.backupLibrary()
        let backup = try XCTUnwrap(backups.first)
        try LibrarySnapshots.validate(backup)
        let later = Conversation(title: "After backup")
        try await db!.save(conversation: later)
        try await db!.stageLibraryRestore(from: backup)
        let unchanged = try await db!.conversations()
        XCTAssertEqual(unchanged.count, 2, "Staging never replaces the live library")
        db = nil
        let restored = try DatabaseActor(url: url)
        let chats = try await restored.conversations()
        XCTAssertEqual(chats.map(\.title), ["Backed up"])
        XCTAssertNil(chats.first?.remoteThreadID)
        let draft = try await restored.draft(conversationID: chat.id)
        XCTAssertEqual(draft, "Saved draft")
        let pins = try await restored.feature(String.self, kind: "chat-pins", id: chat.id.uuidString)
        XCTAssertEqual(pins, "Exact constraint")
        let safety = try await restored.libraryBackups()
        XCTAssertTrue(safety.contains { $0.lastPathComponent.hasPrefix("before-restore-") })
        XCTAssertFalse(FileManager.default.fileExists(atPath: LibrarySnapshots.pending(for: url).path))
        let safetyDB = try DatabaseActor(url: try XCTUnwrap(safety.first { $0.lastPathComponent.hasPrefix("before-restore-") }))
        let safetyChats = try await safetyDB.conversations()
        XCTAssertEqual(safetyChats.count, 2)
    }

    func testDailyBackupIsNotRepeatedAndInvalidRestoreDoesNotStage() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("library.sqlite3"), db = try DatabaseActor(url: url)
        try await db.save(conversation: Conversation())
        _ = try await db.backupLibrary(daily: true)
        let repeated = try await db.backupLibrary(daily: true)
        XCTAssertEqual(repeated.count, 1)
        let invalid = directory.appendingPathComponent("invalid.sqlite3")
        try Data("not a database".utf8).write(to: invalid)
        do { try await db.stageLibraryRestore(from: invalid); XCTFail("Invalid backup accepted") } catch { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: LibrarySnapshots.pending(for: url).path))
    }

    @MainActor
    func testExportIncludesFullMessagesAndProducesMultipagePDF() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let db = try DatabaseActor(url: directory.appendingPathComponent("library.sqlite3"))
        let chat = Conversation(title: "Export test"); try await db.save(conversation: chat)
        let text = String(repeating: "Complete message content\n", count: 600) + "THE END"
        try await db.save(entry: .init(kind: .userMessage, title: "You", text: text), conversationID: chat.id)
        let markdown = try await db.conversationMarkdown(chat)
        XCTAssertTrue(markdown.contains(text))
        let pdf = try XCTUnwrap(PDFDocument(data: ChatExport.pdf(markdown)))
        XCTAssertGreaterThan(pdf.pageCount, 1)
        XCTAssertTrue(pdf.string?.contains("THE END") == true)
    }
}
