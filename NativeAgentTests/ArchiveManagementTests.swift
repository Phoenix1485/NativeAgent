import Foundation
import XCTest
import CSQLite
@testable import NativeAgent

final class ArchiveManagementTests: XCTestCase {
    private var directory: URL!
    private var database: DatabaseActor!
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        database = try DatabaseActor(url: directory.appendingPathComponent("library.sqlite3"))
        _ = try await database.projects()
    }

    override func tearDown() async throws {
        database = nil
        try? FileManager.default.removeItem(at: directory)
    }

    private func executeFixture(_ sql: String) throws {
        var connection: OpaquePointer?
        XCTAssertEqual(sqlite3_open(directory.appendingPathComponent("library.sqlite3").path, &connection), SQLITE_OK)
        defer { sqlite3_close(connection) }
        guard sqlite3_exec(connection, sql, nil, nil, nil) == SQLITE_OK else {
            throw NSError(domain: "ArchiveFixture", code: 1, userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(connection))])
        }
    }

    private func chat(_ title: String, archivedDaysAgo days: Double = 1, bytes: Int64 = 0) async throws -> Conversation {
        let value = Conversation(title: title)
        try await database.save(conversation: value)
        try await database.archiveConversation(id: value.id, now: now.addingTimeInterval(-days * 86_400))
        if bytes != 0 { try executeFixture("UPDATE conversations SET stored_bytes=\(bytes) WHERE id='\(value.id)'") }
        return value
    }

    private func storedBytes(_ id: UUID, in database: DatabaseActor? = nil) async throws -> Int64? {
        try await (database ?? self.database).archivePage(limit: 200, now: now).first { $0.id == id }?.storedBytes
    }

    func testSearchDateRangeAndPagingUseArchiveDateAndLiteralWildcards() async throws {
        let from = now.addingTimeInterval(-7 * 86_400), before = now.addingTimeInterval(-2 * 86_400)
        let earliest = try await chat("needle at lower bound", archivedDaysAgo: 7)
        let middle = try await chat("needle middle", archivedDaysAgo: 4)
        let newest = try await chat("needle newest", archivedDaysAgo: 3)
        _ = try await chat("needle upper bound", archivedDaysAgo: 2)
        _ = try await chat("needle too old", archivedDaysAgo: 8)
        _ = try await chat("unrelated", archivedDaysAgo: 3)
        let search = ArchiveQuery(search: "NEEDLE", archivedFrom: from, archivedBefore: before)
        let first = try await database.archivePage(query: search, limit: 2, now: now)
        let second = try await database.archivePage(query: search, after: first.last?.conversation, limit: 2, now: now)
        XCTAssertEqual(first.map(\.id), [newest.id, middle.id])
        XCTAssertEqual(second.map(\.id), [earliest.id])
        let literal = try await chat("100%_done\\file")
        let escaped = try await database.archivePage(query: .init(search: "%_done\\"), now: now)
        XCTAssertEqual(escaped.map(\.id), [literal.id])
        let backwards = try await database.archivePage(query: .init(archivedFrom: before, archivedBefore: from), now: now)
        XCTAssertTrue(backwards.isEmpty)
        let count = try await database.archivedConversationCount(now: now)
        XCTAssertEqual(count, 7)
    }

    func testArchivePagingIsBoundedAndStableForEqualDatesAcrossEntireArchive() async throws {
        try executeFixture("""
        WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM n WHERE x<1000)
        INSERT INTO conversations(id,title,created_at,updated_at,archived_at)
        SELECT printf('00000000-0000-0000-0000-%012d',x),printf('Archived %04d',x),1,1000-x,\(now.timeIntervalSince1970) FROM n;
        """)
        let first = try await database.archivePage(limit: 50, now: now)
        let second = try await database.archivePage(after: first.last?.conversation, limit: 50, now: now)
        XCTAssertEqual(first.count, 50)
        XCTAssertEqual(second.count, 50)
        XCTAssertEqual(first.first?.conversation.title, "Archived 1000")
        XCTAssertEqual(second.first?.conversation.title, "Archived 0950")
        XCTAssertTrue(Set(first.map(\.id)).isDisjoint(with: second.map(\.id)))
        let found = try await database.archivePage(query: .init(search: "Archived 0001"), now: now)
        XCTAssertEqual(found.map(\.conversation.title), ["Archived 0001"])
        let bounded = try await database.archivePage(limit: 10_000, now: now)
        XCTAssertEqual(bounded.count, 200)
    }

    func testStoredContentCountersTrackUTF8UpdatesMovesAndDeletes() async throws {
        let first = try await chat("First"), second = try await chat("Second")
        var entry = TimelineEntry(kind: .agentMessage, title: "A", text: "🌍é", detail: "{}")
        try await database.save(entry: entry, conversationID: first.id)
        try await database.saveDraft("ä", conversationID: first.id)
        var bytes = try await storedBytes(first.id)
        XCTAssertEqual(bytes, 11) // 1 title + 6 text + 2 metadata + 2 draft.

        entry.text = "Z"; entry.detail = nil
        try await database.save(entry: entry, conversationID: first.id)
        try await database.saveDraft("draft", conversationID: first.id)
        try await database.saveFeature("🌍", kind: "test", id: "feature", title: "é", searchText: "X", conversationID: first.id)
        bytes = try await storedBytes(first.id)
        XCTAssertEqual(bytes, 16) // 2 timeline + 5 draft + 2 title + 1 search + 6 JSON payload.

        try await database.save(entry: entry, conversationID: second.id)
        try await database.saveFeature("x", kind: "test", id: "feature", conversationID: second.id)
        let movedFirst = try await storedBytes(first.id), movedSecond = try await storedBytes(second.id)
        XCTAssertEqual(movedFirst, 5)
        XCTAssertEqual(movedSecond, 5)
        try await database.removeFeature(kind: "test", id: "feature")
        try executeFixture("""
        INSERT INTO attachments VALUES('attachment','\(second.id)','é',NULL,'path',123456,'x');
        """)
        let attached = try await storedBytes(second.id)
        XCTAssertEqual(attached, 9) // 2 timeline + 7 attachment metadata; external file bytes are excluded.
        try executeFixture("UPDATE attachments SET file_name='z' WHERE id='attachment'")
        let changed = try await storedBytes(second.id)
        XCTAssertEqual(changed, 8)
        try executeFixture("DELETE FROM attachments WHERE id='attachment'; DELETE FROM timeline_items WHERE conversation_id='\(second.id)'")
        let empty = try await storedBytes(second.id)
        XCTAssertEqual(empty, 0)
    }

    func testMigrationBackfillsExistingContentAndIsIdempotent() async throws {
        let value = try await chat("Existing")
        try await database.save(entry: .init(kind: .agentMessage, title: "A", text: "🌍é", detail: "{}"), conversationID: value.id)
        try await database.saveDraft("ä", conversationID: value.id)
        try await database.saveFeature("x", kind: "test", id: "backfill", conversationID: value.id)
        try executeFixture("INSERT INTO attachments VALUES('attachment','\(value.id)','é',NULL,'path',0,NULL)")
        let before = try await storedBytes(value.id)
        database = nil
        let drops = ArchiveStorageSchema.triggers.keys.sorted().map { "DROP TRIGGER \($0);" }.joined(separator: "\n")
        try executeFixture("""
        \(drops)
        DROP INDEX conversations_archive_page;
        DROP INDEX features_conversation;
        DROP INDEX attachments_conversation;
        ALTER TABLE conversations DROP COLUMN stored_bytes;
        DROP TABLE usage_records;
        DROP TABLE usage_tracking;
        DELETE FROM schema_migrations WHERE version>=6;
        """)
        database = try DatabaseActor(url: directory.appendingPathComponent("library.sqlite3"))
        let migrated = try await storedBytes(value.id)
        XCTAssertEqual(migrated, before)
        XCTAssertEqual(migrated, 20)
        let reopened = try DatabaseActor(url: directory.appendingPathComponent("library.sqlite3"))
        let repeated = try await storedBytes(value.id, in: reopened)
        XCTAssertEqual(repeated, migrated)
        try await reopened.saveDraft("", conversationID: value.id)
        let updated = try await storedBytes(value.id, in: reopened)
        XCTAssertEqual(updated, 18)
    }

    func testEarlyCleanupStartsAtTwentyDaysAndStopsAtThirtyArchives() async throws {
        let oldest = try await chat("Old large", archivedDaysAgo: 25, bytes: ArchiveRetention.largeChatBytes)
        let boundary = try await chat("20 days", archivedDaysAgo: 20, bytes: ArchiveRetention.largeChatBytes)
        let tooYoung = try await chat("One second younger", archivedDaysAgo: 20 - 1.0 / 86_400, bytes: ArchiveRetention.largeChatBytes)
        _ = try await chat("Just below threshold", archivedDaysAgo: 29, bytes: ArchiveRetention.largeChatBytes - 1)
        for i in 0..<29 { _ = try await chat("Small \(i)") }
        let page = try await database.archivePage(limit: 200, now: now)
        let count = try await database.archivedConversationCount(now: now)
        XCTAssertEqual(count, 31)
        XCTAssertEqual(page.count, 31)
        XCTAssertFalse(page.contains { $0.id == oldest.id || $0.id == boundary.id })
        XCTAssertTrue(page.contains { $0.id == tooYoung.id })
        let restored = try await database.restoreConversation(id: oldest.id, now: now)
        XCTAssertFalse(restored)
        let first = try await database.purgeExpiredArchive(now: now, limit: 1)
        let second = try await database.purgeExpiredArchive(now: now, limit: 1)
        let unchanged = try await database.purgeExpiredArchive(now: now)
        XCTAssertEqual(first, [oldest.id])
        XCTAssertEqual(second, [boundary.id])
        XCTAssertTrue(unchanged.isEmpty)
        let third = try await database.purgeExpiredArchive(now: now.addingTimeInterval(1))
        XCTAssertEqual(third, [tooYoung.id])
        let remaining = try await database.archivedConversationCount(now: now.addingTimeInterval(1))
        XCTAssertEqual(remaining, 30)
    }

    func testOnlyOldestExcessChatIsExpiredAndThirtyArchivesRemainRestorable() async throws {
        let oldest = try await chat("Oldest", archivedDaysAgo: 25, bytes: ArchiveRetention.largeChatBytes)
        let surviving = try await chat("Keep large", archivedDaysAgo: 24, bytes: ArchiveRetention.largeChatBytes)
        for i in 0..<29 { _ = try await chat("Small \(i)") }
        let page = try await database.archivePage(limit: 200, now: now)
        XCTAssertEqual(page.count, 30)
        XCTAssertFalse(page.contains { $0.id == oldest.id })
        XCTAssertTrue(page.contains { $0.id == surviving.id })
        let purged = try await database.purgeExpiredArchive(now: now)
        XCTAssertEqual(purged, [oldest.id])
        let extra = try await database.purgeExpiredArchive(now: now)
        XCTAssertTrue(extra.isEmpty)
        let restored = try await database.restoreConversation(id: surviving.id, now: now)
        XCTAssertTrue(restored)
    }

    func testThirtyDayExpiryAlwaysRunsBeforePressureCleanupAndHonorsBatchLimit() async throws {
        let expired = try await chat("Expired", archivedDaysAgo: 30)
        let oldLarge = try await chat("Keep large", archivedDaysAgo: 25, bytes: ArchiveRetention.largeChatBytes)
        for i in 0..<29 { _ = try await chat("Small \(i)") }
        let count = try await database.archivedConversationCount(now: now)
        XCTAssertEqual(count, 30)
        let purged = try await database.purgeExpiredArchive(now: now, limit: 1)
        XCTAssertEqual(purged, [expired.id])
        let remaining = try await database.purgeExpiredArchive(now: now)
        XCTAssertTrue(remaining.isEmpty)
        let kept = try await database.conversation(id: oldLarge.id)
        XCTAssertNotNil(kept)
        let expiredAgain = try await database.restoreConversation(id: expired.id, now: now)
        XCTAssertFalse(expiredAgain)
    }

    func testManualPermanentDeleteCascadesAndProtectsActiveChats() async throws {
        let archived = try await chat("Delete"), active = Conversation(title: "Keep")
        try await database.save(conversation: active)
        let entry = TimelineEntry(kind: .userMessage, title: "You", text: "History")
        try await database.save(entry: entry, conversationID: archived.id)
        try await database.saveDraft("Draft", conversationID: archived.id)
        try await database.saveFeature("Private", kind: "test", id: "dependent", conversationID: archived.id)
        try executeFixture("""
        INSERT INTO turns VALUES('turn','\(archived.id)',NULL,'completed',1,2,NULL);
        INSERT INTO approval_records VALUES('approval','turn','request','command',NULL,NULL,NULL);
        INSERT INTO context_references VALUES('reference','\(entry.id)','a.swift',NULL,NULL,NULL,NULL);
        INSERT INTO attachments VALUES('attachment','\(archived.id)','file.txt',NULL,'unused',0,NULL);
        """)
        let protected = try await database.deleteArchivedConversation(id: active.id)
        XCTAssertFalse(protected)
        let deleted = try await database.deleteArchivedConversation(id: archived.id)
        let repeated = try await database.deleteArchivedConversation(id: archived.id)
        XCTAssertTrue(deleted)
        XCTAssertFalse(repeated)
        let restore = try await database.restoreConversation(id: archived.id, now: now)
        XCTAssertFalse(restore)
        let live = try await database.conversations()
        XCTAssertEqual(live.map(\.id), [active.id])
        try executeFixture("""
        CREATE TEMP TABLE assert_empty(value INTEGER CHECK(value=0));
        INSERT INTO assert_empty SELECT COUNT(*) FROM context_references;
        INSERT INTO assert_empty SELECT COUNT(*) FROM approval_records;
        INSERT INTO assert_empty SELECT COUNT(*) FROM attachments;
        INSERT INTO assert_empty SELECT COUNT(*) FROM turns;
        INSERT INTO assert_empty SELECT COUNT(*) FROM timeline_items;
        INSERT INTO assert_empty SELECT COUNT(*) FROM feature_records;
        INSERT INTO assert_empty SELECT COUNT(*) FROM drafts;
        """)
    }

    func testFailedPermanentDeleteRollsBackDependentCleanup() async throws {
        let archived = try await chat("Keep on error")
        try executeFixture("""
        INSERT INTO attachments VALUES('attachment','\(archived.id)','file',NULL,'path',0,NULL);
        CREATE TRIGGER block_delete BEFORE DELETE ON conversations BEGIN SELECT RAISE(ABORT,'fixture failure'); END;
        """)
        do {
            _ = try await database.deleteArchivedConversation(id: archived.id)
            XCTFail("Expected an atomic deletion failure")
        } catch { }
        let kept = try await database.conversation(id: archived.id)
        let bytes = try await storedBytes(archived.id)
        XCTAssertNotNil(kept)
        XCTAssertEqual(bytes, 8)
        try executeFixture("""
        CREATE TEMP TABLE assert_one(value INTEGER CHECK(value=1));
        INSERT INTO assert_one SELECT COUNT(*) FROM attachments;
        DROP TRIGGER block_delete;
        """)
        let deleted = try await database.deleteArchivedConversation(id: archived.id)
        XCTAssertTrue(deleted)
    }
}
