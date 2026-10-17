import CSQLite
import Foundation
import XCTest
@testable import NativeAgent

final class GroupRemovalTests: XCTestCase {
    private var directory: URL!
    private var database: DatabaseActor!
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        database = try DatabaseActor(url: directory.appendingPathComponent("library.sqlite3"))
    }

    override func tearDown() async throws {
        database = nil
        try? FileManager.default.removeItem(at: directory)
    }

    private func executeFixture(_ sql: String) throws {
        var connection: OpaquePointer?
        XCTAssertEqual(sqlite3_open(directory.appendingPathComponent("library.sqlite3").path, &connection), SQLITE_OK)
        defer { sqlite3_close(connection) }
        XCTAssertEqual(sqlite3_exec(connection, sql, nil, nil, nil), SQLITE_OK, String(cString: sqlite3_errmsg(connection)))
    }

    func testArchivedOnlyGroupRemovalPreservesHistoryAndWorkspaceThroughRestore() async throws {
        let inherited = Project(name: "Inherited", canonicalPath: directory.appendingPathComponent("inherited").path)
        let explicit = Project(name: "Explicit", canonicalPath: directory.appendingPathComponent("explicit").path)
        try await database.save(project: inherited)
        try await database.save(project: explicit)
        let parent = ChatGroup(projectID: inherited.id, name: "Parent")
        let group = ChatGroup(parentID: parent.id, name: "Empty in sidebar")
        let unrelated = ChatGroup(name: "Unrelated")
        for value in [parent, group, unrelated] { try await database.save(group: value) }
        var archived = Conversation(groupID: group.id, remoteThreadID: "preserved-thread", title: "Saved chat")
        archived.providerID = .grok
        let expired = Conversation(projectID: explicit.id, groupID: group.id, title: "Expired but not purged")
        let other = Conversation(groupID: unrelated.id, title: "Other archive")
        for chat in [archived, expired, other] {
            try await database.save(conversation: chat)
            try await database.archiveConversation(id: chat.id, now: chat.id == expired.id ? now.addingTimeInterval(-31 * 86_400) : now)
        }
        let message = TimelineEntry(kind: .userMessage, title: "You", text: "Keep this message")
        try await database.save(entry: message, conversationID: archived.id)
        try await database.saveDraft("Keep this draft", conversationID: archived.id)
        let bookmark = try await database.saveMessageBookmark(conversationID: archived.id, messageID: message.id, label: "Useful")
        let before = try await database.conversation(id: archived.id)
        let expiredBefore = try await database.conversation(id: expired.id)

        try await database.removeEmptyGroup(id: group.id)
        let reopened = try DatabaseActor(url: directory.appendingPathComponent("library.sqlite3"))
        let groups = try await reopened.groups()
        XCTAssertEqual(Set(groups.map(\.id)), [parent.id, unrelated.id])
        var expected = try XCTUnwrap(before)
        expected.groupID = nil
        expected.projectID = inherited.id
        let saved = try await reopened.conversation(id: archived.id)
        XCTAssertEqual(saved, expected)
        var expectedExpired = try XCTUnwrap(expiredBefore)
        expectedExpired.groupID = nil
        let savedExpired = try await reopened.conversation(id: expired.id)
        XCTAssertEqual(savedExpired, expectedExpired)
        let untouched = try await reopened.conversation(id: other.id)
        XCTAssertEqual(untouched?.groupID, unrelated.id)
        let draft = try await reopened.draft(conversationID: archived.id)
        let timeline = try await reopened.timeline(conversationID: archived.id)
        let savedBookmark = try await reopened.feature(MessageBookmark.self, kind: "message-bookmark", id: message.id.uuidString)
        XCTAssertEqual(draft, "Keep this draft")
        XCTAssertEqual(timeline.first?.text, message.text)
        XCTAssertEqual(savedBookmark?.id, bookmark.id)
        let restored = try await reopened.restoreConversation(id: archived.id, now: now.addingTimeInterval(86_400))
        XCTAssertTrue(restored)
        let standalone = try await reopened.conversationPage()
        XCTAssertEqual(standalone.map(\.id), [archived.id])
        XCTAssertEqual(standalone.first?.projectID, inherited.id)
        let purged = try await reopened.purgeExpiredArchive(now: now)
        XCTAssertEqual(purged, [expired.id])
        try executeFixture("CREATE TEMP TABLE integrity_check(value INTEGER CHECK(value=0)); INSERT INTO integrity_check SELECT COUNT(*) FROM pragma_foreign_key_check;")
    }

    func testActiveChatsAndChildGroupsBlockRemovalWithoutDetachingArchives() async throws {
        for hasChild in [false, true] {
            let group = ChatGroup(name: "Occupied")
            try await database.save(group: group)
            let archived = Conversation(groupID: group.id, title: "Archived")
            try await database.save(conversation: archived)
            try await database.archiveConversation(id: archived.id, now: now)
            if hasChild {
                try await database.save(group: ChatGroup(parentID: group.id, name: "Empty child"))
            } else {
                try await database.save(conversation: Conversation(groupID: group.id, title: "Active"))
            }
            do { try await database.removeEmptyGroup(id: group.id); XCTFail("Must preserve active chats and child groups") }
            catch { }
            let groups = try await database.groups()
            let saved = try await database.conversation(id: archived.id)
            XCTAssertTrue(groups.contains { $0.id == group.id })
            XCTAssertEqual(saved?.groupID, group.id)
            XCTAssertEqual(saved?.archivedAt, now)
        }
    }

    func testFailedDeleteRollsBackArchiveDetachment() async throws {
        let group = ChatGroup(name: "Keep on failure")
        try await database.save(group: group)
        let chat = Conversation(groupID: group.id, title: "Archived")
        try await database.save(conversation: chat)
        try await database.archiveConversation(id: chat.id, now: now)
        try executeFixture("CREATE TRIGGER reject_group_removal BEFORE DELETE ON chat_groups BEGIN SELECT RAISE(ABORT,'Simulated delete failure'); END;")
        do { try await database.removeEmptyGroup(id: group.id); XCTFail("Expected injected delete failure") }
        catch { }
        let saved = try await database.conversation(id: chat.id)
        XCTAssertEqual(saved?.groupID, group.id)
        try executeFixture("DROP TRIGGER reject_group_removal;")
        try await database.removeEmptyGroup(id: group.id)
        let remaining = try await database.groups()
        XCTAssertTrue(remaining.isEmpty)
    }

    @MainActor
    func testRemovingSelectedGroupUpdatesSidebarAndRestoresCachedArchiveUngrouped() async throws {
        let suite = "GroupRemovalTests.\(UUID())"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let group = ChatGroup(name: "Empty in sidebar")
        try await database.save(group: group)
        let chat = Conversation(groupID: group.id, title: "Recover me")
        try await database.save(conversation: chat)
        try await database.archiveConversation(id: chat.id)
        let model = WorkspaceViewModel(provider: SettingsTestProvider(), database: database, files: FileService(), git: GitService(), automaticallyRestore: false, preferences: preferences, credentials: MemoryCredentials())
        model.groups = try await database.groups()
        model.expand(group.id, expanded: true)
        await model.selectGroup(group.id)
        await model.loadArchive()
        let cached = try XCTUnwrap(model.archiveEntries.first?.conversation)
        XCTAssertTrue(model.conversations.isEmpty)
        await model.removeGroup(group)
        XCTAssertNil(model.errorMessage)
        XCTAssertTrue(model.groups.isEmpty)
        XCTAssertNil(model.selectedGroupID)
        XCTAssertFalse(model.expandedGroupIDs.contains(group.id))
        XCTAssertFalse((preferences.stringArray(forKey: "expandedGroups") ?? []).contains(group.id.uuidString))
        await model.restoreArchived(cached)
        XCTAssertNil(model.archiveError)
        XCTAssertEqual(model.conversations.map(\.id), [chat.id])
        XCTAssertNil(model.conversations.first?.groupID)
    }
}
