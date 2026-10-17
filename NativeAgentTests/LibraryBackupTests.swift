import XCTest
import PDFKit
import CSQLite
@testable import NativeAgent

final class LibraryBackupTests: XCTestCase {
    func testArchiveCountersSurviveBackupRestoreAndVersionFiveMigration() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = try DatabaseActor(url: directory.appendingPathComponent("original.sqlite3"))
        let chat = Conversation(title: "Archive migration")
        try await original.save(conversation: chat)
        try await original.saveDraft("🙂 archived draft", conversationID: chat.id)
        try await original.archiveConversation(id: chat.id)
        let backups = try await original.backupLibrary()
        let backup = try XCTUnwrap(backups.first)
        let expected = try await original.archivePage().first?.storedBytes
        try LibrarySnapshots.validate(backup)
        // A genuine version-five backup has no accounting triggers/column yet.
        let dropTriggers = ArchiveStorageSchema.triggers.keys.sorted().map { "DROP TRIGGER \($0);" }.joined(separator: "\n")
        try updateFixture(backup, sql: """
        \(dropTriggers)
        DROP INDEX conversations_archive_page;
        DROP INDEX features_conversation;
        DROP INDEX attachments_conversation;
        ALTER TABLE conversations DROP COLUMN stored_bytes;
        DROP TABLE usage_records;
        DROP TABLE usage_tracking;
        DELETE FROM schema_migrations WHERE version>=6;
        """)
        try LibrarySnapshots.validate(backup)
        let target = directory.appendingPathComponent("restored.sqlite3")
        try LibrarySnapshots.stage(source: backup, database: target)
        let restored = try DatabaseActor(url: target)
        let page = try await restored.archivePage()
        XCTAssertEqual(page.first?.storedBytes, expected)
        XCTAssertEqual(page.first?.id, chat.id)
        let upgradedBackups = try await restored.backupLibrary()
        let upgraded = try XCTUnwrap(upgradedBackups.first)
        try LibrarySnapshots.validate(upgraded)
    }

    func testBackupRejectsUnknownAndModifiedStorageTriggers() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try DatabaseActor(url: directory.appendingPathComponent("library.sqlite3"))
        try await database.save(conversation: Conversation())
        let backups = try await database.backupLibrary()
        let backup = try XCTUnwrap(backups.first)
        try updateFixture(backup, sql: "CREATE TRIGGER unexpected AFTER INSERT ON drafts BEGIN DELETE FROM conversations; END;")
        XCTAssertThrowsError(try LibrarySnapshots.validate(backup))
        try updateFixture(backup, sql: "DROP TRIGGER unexpected;")
        try LibrarySnapshots.validate(backup)
        let name = try XCTUnwrap(ArchiveStorageSchema.triggers.keys.sorted().first)
        try updateFixture(backup, sql: "DROP TRIGGER \(name); CREATE TRIGGER \(name) AFTER INSERT ON drafts BEGIN DELETE FROM conversations; END;")
        XCTAssertThrowsError(try LibrarySnapshots.validate(backup))
    }

    private func updateFixture(_ url: URL, sql: String) throws {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK else { throw NativeAgentError.unsupported("Could not open fixture") }
        defer { sqlite3_close(database) }
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw NativeAgentError.unsupported(String(cString: sqlite3_errmsg(database)))
        }
    }

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
