import CSQLite
import Foundation
import XCTest
@testable import NativeAgent

@MainActor
final class ArchiveViewModelTests: XCTestCase {
    private var directory: URL!
    private var defaults: UserDefaults!
    private var suite: String!
    private var database: DatabaseActor!
    private var model: WorkspaceViewModel!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        suite = "NativeAgentArchiveViewModelTests.\(UUID())"
        defaults = UserDefaults(suiteName: suite)!
        database = try DatabaseActor(url: directory.appendingPathComponent("library.sqlite3"))
        model = WorkspaceViewModel(provider: SettingsTestProvider(), database: database, files: FileService(), git: GitService(), automaticallyRestore: false, preferences: defaults, credentials: MemoryCredentials())
    }

    override func tearDown() async throws {
        model = nil
        database = nil
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }

    @discardableResult
    private func archivedChat(_ title: String, at date: Date = .now) async throws -> Conversation {
        let chat = Conversation(title: title)
        try await database.save(conversation: chat)
        try await database.archiveConversation(id: chat.id, now: date)
        let stored = try await database.conversation(id: chat.id)
        return try XCTUnwrap(stored)
    }

    func testRapidSearchChangesSuppressStaleResults() async throws {
        _ = try await archivedChat("Alpha conversation")
        let beta = try await archivedChat("Beta conversation")
        let first = Task { await model.loadArchive(query: ArchiveQuery(search: "Alpha")) }
        while model.archiveQuery.search != "Alpha" { await Task.yield() }
        XCTAssertTrue(model.archiveLoading)
        await model.loadArchive(query: ArchiveQuery(search: "Beta"))
        await first.value
        XCTAssertEqual(model.archiveQuery.search, "Beta")
        XCTAssertEqual(model.archiveEntries.map(\.id), [beta.id])
        XCTAssertEqual(model.archiveTotalCount, 2)
        XCTAssertFalse(model.archiveLoading)
        XCTAssertNil(model.archiveError)
    }

    func testCancelledQueryLeavesNoStaleRowsOrLoadingIndicator() async throws {
        _ = try await archivedChat("Original")
        await model.loadArchive()
        let request = Task { await model.loadArchive(query: ArchiveQuery(search: "Cancelled")) }
        while model.archiveQuery.search != "Cancelled" { await Task.yield() }
        request.cancel()
        await request.value
        XCTAssertTrue(model.archiveEntries.isEmpty)
        XCTAssertFalse(model.archiveLoading)
        XCTAssertNil(model.archiveError)
        await model.loadArchive(query: ArchiveQuery())
        XCTAssertEqual(model.archiveEntries.count, 1)
    }

    func testFilteredArchivePaginatesWithoutDuplicatesAndKeepsTotalCount() async throws {
        let now = Date.now
        var expected: Set<UUID> = []
        for index in 0..<63 {
            let chat = try await archivedChat("Matching \(index)", at: now.addingTimeInterval(-3_600))
            expected.insert(chat.id)
        }
        _ = try await archivedChat("Matching outside date range", at: now.addingTimeInterval(-10 * 86_400))
        _ = try await archivedChat("Unrelated", at: now.addingTimeInterval(-3_600))
        let query = ArchiveQuery(search: "Matching", archivedFrom: now.addingTimeInterval(-86_400), archivedBefore: now)
        await model.loadArchive(query: query)
        XCTAssertEqual(model.archiveEntries.count, 50)
        XCTAssertTrue(model.archiveHasMore)
        XCTAssertEqual(model.archiveTotalCount, 65)
        await model.loadArchive(more: true)
        XCTAssertEqual(model.archiveEntries.count, 63)
        XCTAssertEqual(Set(model.archiveEntries.map(\.id)), expected)
        XCTAssertFalse(model.archiveHasMore)
        XCTAssertEqual(model.archiveQuery, query)
    }

    func testChangingQueryWhileLoadingMoreCannotAppendOldMatches() async throws {
        for index in 0..<51 { _ = try await archivedChat("Previous \(index)") }
        let current = try await archivedChat("Current result")
        await model.loadArchive(query: ArchiveQuery(search: "Previous"))
        let olderPage = Task { await model.loadArchive(more: true) }
        await Task.yield()
        await model.loadArchive(query: ArchiveQuery(search: "Current"))
        await olderPage.value
        XCTAssertEqual(model.archiveEntries.map(\.id), [current.id])
        XCTAssertEqual(model.archiveQuery.search, "Current")
        XCTAssertFalse(model.archiveHasMore)
        XCTAssertFalse(model.archiveLoading)
    }

    func testPermanentDeleteOnlyRemovesTargetArchiveAndKeepsSearch() async throws {
        let target = try await archivedChat("Selected target")
        let matching = try await archivedChat("Selected keep")
        let other = try await archivedChat("Other archived chat")
        let active = Conversation(title: "Active chat")
        try await database.save(conversation: active)
        try await database.saveDraft("Target draft", conversationID: target.id)
        try await database.save(entry: .init(kind: .userMessage, title: "You", text: "Target history"), conversationID: target.id)
        await model.loadArchive(query: ArchiveQuery(search: "Selected"))
        await model.deleteArchived(target)
        XCTAssertEqual(model.archiveEntries.map(\.id), [matching.id])
        XCTAssertEqual(model.archiveQuery.search, "Selected")
        XCTAssertEqual(model.archiveTotalCount, 2)
        XCTAssertTrue(model.archiveOperationIDs.isEmpty)
        XCTAssertNil(model.archiveError)
        let removed = try await database.conversation(id: target.id)
        let otherStored = try await database.conversation(id: other.id)
        let removedDraft = try await database.draft(conversationID: target.id)
        let removedMessages = try await database.timeline(conversationID: target.id)
        XCTAssertNil(removed)
        XCTAssertNotNil(otherStored)
        XCTAssertEqual(removedDraft, "")
        XCTAssertTrue(removedMessages.isEmpty)
        await model.deleteArchived(active)
        let activeStored = try await database.conversation(id: active.id)
        XCTAssertNotNil(activeStored)
        XCTAssertEqual(model.archiveTotalCount, 2)
    }

    func testRestoreRefreshesArchiveAndPreservesConversationAssociations() async throws {
        let project = Project(name: "Project", canonicalPath: directory.path)
        let group = ChatGroup(projectID: project.id, name: "Work")
        try await database.save(project: project)
        try await database.save(group: group)
        let chat = Conversation(projectID: project.id, groupID: group.id, remoteThreadID: "provider-thread", title: "Restore")
        try await database.save(conversation: chat)
        try await database.saveDraft("Unsent work", conversationID: chat.id)
        try await database.save(entry: .init(kind: .userMessage, title: "You", text: "Saved message"), conversationID: chat.id)
        try await database.archiveConversation(id: chat.id)
        model.groups = [group]
        await model.loadArchive()
        let archived = try XCTUnwrap(model.archivedConversations.first)
        await model.restoreArchived(archived)
        XCTAssertTrue(model.archiveEntries.isEmpty)
        XCTAssertEqual(model.archiveTotalCount, 0)
        let restored = try XCTUnwrap(model.conversations.first)
        XCTAssertEqual(restored.groupID, group.id)
        XCTAssertEqual(restored.projectID, project.id)
        XCTAssertEqual(restored.remoteThreadID, "provider-thread")
        XCTAssertNil(restored.archivedAt)
        XCTAssertTrue(model.expandedGroupIDs.contains(group.id))
        let draft = try await database.draft(conversationID: chat.id)
        let messages = try await database.timeline(conversationID: chat.id)
        XCTAssertEqual(draft, "Unsent work")
        XCTAssertEqual(messages.first?.text, "Saved message")
    }

    func testSearchDoesNotPurgeButOpeningArchivePerformsMaintenance() async throws {
        let expired = try await archivedChat("Expired", at: Date.now.addingTimeInterval(-31 * 86_400))
        let recoverable = try await archivedChat("Recoverable")
        await model.loadArchive(query: ArchiveQuery(search: "Recoverable"))
        let beforeMaintenance = try await database.conversation(id: expired.id)
        XCTAssertNotNil(beforeMaintenance, "A search should only query archive metadata")
        await model.openArchive()
        let afterMaintenance = try await database.conversation(id: expired.id)
        XCTAssertNil(afterMaintenance)
        XCTAssertEqual(model.archiveEntries.map(\.id), [recoverable.id])
        XCTAssertEqual(model.archiveTotalCount, 1)
    }

    func testExpiredRestoreReportsErrorInsideArchive() async throws {
        let expired = try await archivedChat("Expired", at: Date.now.addingTimeInterval(-31 * 86_400))
        await model.restoreArchived(expired)
        XCTAssertTrue(model.archiveEntries.isEmpty)
        XCTAssertEqual(model.archiveTotalCount, 0)
        XCTAssertNotNil(model.archiveError)
        XCTAssertNil(model.errorMessage)
        XCTAssertTrue(model.archiveOperationIDs.isEmpty)
        XCTAssertTrue(model.conversations.isEmpty)
    }

    func testMaintenanceRemovesPreviouslyLoadedExpiredRowAndUpdatesCount() async throws {
        let chat = try await archivedChat("Expires while open")
        await model.loadArchive()
        var connection: OpaquePointer?
        XCTAssertEqual(sqlite3_open(directory.appendingPathComponent("library.sqlite3").path, &connection), SQLITE_OK)
        defer { sqlite3_close(connection) }
        let archivedAt = Date.now.addingTimeInterval(-31 * 86_400).timeIntervalSince1970
        let result = sqlite3_exec(connection, "UPDATE conversations SET archived_at=\(archivedAt) WHERE id='\(chat.id)'", nil, nil, nil)
        XCTAssertEqual(result, SQLITE_OK)
        await model.maintainArchive()
        XCTAssertTrue(model.archiveEntries.isEmpty)
        XCTAssertEqual(model.archiveTotalCount, 0)
        XCTAssertFalse(model.archiveHasMore)
    }

    func testArchivingRefreshesAlreadyLoadedArchiveCountAndRows() async throws {
        let chat = Conversation(title: "New archive")
        try await database.save(conversation: chat)
        await model.loadArchive()
        XCTAssertEqual(model.archiveTotalCount, 0)
        await model.archive(chat)
        XCTAssertEqual(model.archiveTotalCount, 1)
        XCTAssertEqual(model.archiveEntries.map(\.id), [chat.id])
    }
}
