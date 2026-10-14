import Foundation
import XCTest
import CSQLite
@testable import NativeAgent

final class ArchiveAndPagingTests: XCTestCase {
    private var directory: URL!
    private var database: DatabaseActor!
    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        database = try DatabaseActor(url: directory.appendingPathComponent("library.sqlite3"))
        _ = try await database.projects()
    }
    override func tearDown() async throws { database = nil; try? FileManager.default.removeItem(at: directory) }

    private func executeFixture(_ sql: String) throws {
        var connection: OpaquePointer?
        XCTAssertEqual(sqlite3_open(directory.appendingPathComponent("library.sqlite3").path, &connection), SQLITE_OK)
        defer { sqlite3_close(connection) }
        let result = sqlite3_exec(connection, sql, nil, nil, nil)
        XCTAssertEqual(result, SQLITE_OK, String(cString: sqlite3_errmsg(connection)))
    }

    func testArchivePersistsAndRestoreKeepsFolderDraftAndMessages() async throws {
        let group = ChatGroup(name: "Work")
        try await database.save(group: group)
        let chat = Conversation(groupID: group.id, title: "Recover me")
        try await database.save(conversation: chat)
        try await database.saveDraft("Unsent work", conversationID: chat.id)
        try await database.save(entry: .init(kind: .userMessage, title: "You", text: "Saved work"), conversationID: chat.id)
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        try await database.archiveConversation(id: chat.id, now: now)
        try await database.archiveConversation(id: chat.id, now: now.addingTimeInterval(100))
        // A stale metadata update must not resurrect an archived conversation.
        try await database.save(conversation: chat)
        let active = try await database.conversations()
        XCTAssertTrue(active.isEmpty)
        let reopened = try DatabaseActor(url: directory.appendingPathComponent("library.sqlite3"))
        let archived = try await reopened.conversationPage(archived: true, now: now)
        XCTAssertEqual(archived.first?.archivedAt, now)
        XCTAssertEqual(archived.first?.groupID, group.id)
        let restored = try await reopened.restoreConversation(id: chat.id, now: now.addingTimeInterval(29 * 86_400))
        XCTAssertTrue(restored)
        let draft = try await reopened.draft(conversationID: chat.id)
        let entries = try await reopened.timeline(conversationID: chat.id)
        XCTAssertEqual(draft, "Unsent work"); XCTAssertEqual(entries.first?.text, "Saved work")
        let page = try await reopened.conversationPage(groupID: group.id)
        XCTAssertEqual(page.map(\.id), [chat.id]); XCTAssertNil(page.first?.archivedAt)
    }

    func testThirtyDayBoundaryAndPermanentCascadeCleanup() async throws {
        let chat = Conversation(title: "Expires"), active = Conversation(title: "Keep")
        let item = TimelineEntry(kind: .userMessage, title: "You", text: "Private local history")
        try await database.save(conversation: chat); try await database.save(conversation: active)
        try await database.save(entry: item, conversationID: chat.id)
        try await database.saveDraft("draft", conversationID: chat.id)
        try executeFixture("""
        INSERT INTO turns VALUES('turn','\(chat.id)',NULL,'completed',1,2,NULL);
        INSERT INTO approval_records VALUES('approval','turn','request','command',NULL,NULL,NULL);
        INSERT INTO context_references VALUES('ref','\(item.id)','a.swift',NULL,NULL,NULL,NULL);
        INSERT INTO attachments VALUES('attachment','\(chat.id)','fixture.txt',NULL,'unused',0,NULL);
        """)
        let start = Date(timeIntervalSince1970: 2_000_000_000), expiry = start.addingTimeInterval(30 * 86_400)
        try await database.archiveConversation(id: chat.id, now: start)
        let before = try await database.purgeExpiredArchive(now: expiry.addingTimeInterval(-1))
        XCTAssertTrue(before.isEmpty)
        let expiredPage = try await database.conversationPage(archived: true, now: expiry)
        XCTAssertTrue(expiredPage.isEmpty)
        let restored = try await database.restoreConversation(id: chat.id, now: expiry)
        XCTAssertFalse(restored)
        let purged = try await database.purgeExpiredArchive(now: expiry)
        XCTAssertEqual(purged, [chat.id])
        let timeline = try await database.timeline(conversationID: chat.id), draft = try await database.draft(conversationID: chat.id)
        XCTAssertTrue(timeline.isEmpty); XCTAssertEqual(draft, "")
        let remaining = try await database.conversations()
        XCTAssertEqual(remaining.map(\.id), [active.id])
        // These tables have no cascading foreign keys; verify explicit cleanup too.
        try executeFixture("""
        CREATE TEMP TABLE assert_empty(value INTEGER CHECK(value=0));
        INSERT INTO assert_empty SELECT COUNT(*) FROM context_references;
        INSERT INTO assert_empty SELECT COUNT(*) FROM approval_records;
        INSERT INTO assert_empty SELECT COUNT(*) FROM attachments;
        INSERT INTO assert_empty SELECT COUNT(*) FROM turns;
        """)
    }

    func testTenThousandChatLibraryUsesStableBoundedPagesAndGlobalSearch() async throws {
        try executeFixture("""
        BEGIN;
        WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM n WHERE x<10000)
        INSERT INTO conversations(id,title,created_at,updated_at,provider_id)
        SELECT printf('00000000-0000-0000-0000-%012d',x),printf('Chat %05d',x),1,1,'codex' FROM n;
        COMMIT;
        """)
        let start = Date()
        let first = try await database.conversationPage()
        XCTAssertEqual(first.count, 50)
        let second = try await database.conversationPage(after: first.last)
        XCTAssertEqual(second.count, 50)
        XCTAssertTrue(Set(first.map(\.id)).isDisjoint(with: second.map(\.id)))
        XCTAssertEqual(first.first?.title, "Chat 10000")
        XCTAssertEqual(second.first?.title, "Chat 09950")
        let found = try await database.conversationPage(search: "Chat 00001")
        XCTAssertEqual(found.map(\.title), ["Chat 00001"])
        let literal = Conversation(title: "100%_done\\file")
        try await database.save(conversation: literal)
        let escaped = try await database.conversationPage(search: "%_done\\")
        XCTAssertEqual(escaped.map(\.id), [literal.id])
        print("10,000-chat fixture: two 50-row pages and two searches in \(Date().timeIntervalSince(start)) seconds")
    }

    func testLongHistoryPagesAndLargeMessagePreviewsPreserveOriginal() async throws {
        let chat = Conversation()
        try await database.save(conversation: chat)
        try executeFixture("""
        BEGIN;
        WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM n WHERE x<10000)
        INSERT INTO timeline_items(id,conversation_id,kind,title,display_text,received_order,created_at)
        SELECT printf('00000000-0000-0000-0000-%012d',x),'\(chat.id)','userMessage','You',printf('Message %d',x),x,1 FROM n;
        COMMIT;
        """)
        let start = Date()
        let latest = try await database.timeline(conversationID: chat.id, limit: 40, previewCharacters: 8_000)
        let earlier = try await database.timeline(conversationID: chat.id, limit: 40, beforeOrder: latest.first?.receivedOrder, previewCharacters: 8_000)
        XCTAssertEqual(latest.count, 40); XCTAssertEqual(latest.first?.receivedOrder, 9_961)
        XCTAssertEqual(earlier.last?.receivedOrder, 9_960)
        XCTAssertTrue(Set(latest.map(\.id)).isDisjoint(with: earlier.map(\.id)))
        print("10,000-message fixture: two 40-row pages in \(Date().timeIntervalSince(start)) seconds")
        let large = TimelineEntry(kind: .agentMessage, title: "Agent", text: String(repeating: "🌍", count: 30_000))
        try await database.save(entry: large, conversationID: chat.id)
        let preview = try await database.timeline(conversationID: chat.id, limit: 1, previewCharacters: 8_000)
        XCTAssertEqual(preview.first?.text.count, 8_000); XCTAssertEqual(preview.first?.textIsPreview, true)
        let full = try await database.fullTimelineText(id: large.id)
        XCTAssertEqual(full, large.text)
    }
}
