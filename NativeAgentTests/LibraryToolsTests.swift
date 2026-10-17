import CSQLite
import Foundation
import XCTest
@testable import NativeAgent

@MainActor
final class LibraryToolsTests: XCTestCase {
    private var directory: URL!
    private var database: DatabaseActor!
    private var tools: LibraryToolsController!
    private var model: WorkspaceViewModel!
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        database = try DatabaseActor(url: directory.appendingPathComponent("library.sqlite3"))
        tools = LibraryToolsController(database: database, cacheRoot: directory.appendingPathComponent("Cache"))
        suite = "NativeAgentLibraryToolsTests.\(UUID())"
        defaults = UserDefaults(suiteName: suite)!
        model = WorkspaceViewModel(provider: SettingsTestProvider(), database: database, files: FileService(), git: GitService(), automaticallyRestore: false, preferences: defaults, credentials: MemoryCredentials())
    }

    override func tearDown() async throws {
        model = nil; tools = nil; database = nil
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }

    private func chat(_ title: String, bytes: Int = 10, archived: Bool = false) async throws -> Conversation {
        let value = Conversation(title: title)
        try await database.save(conversation: value)
        try await database.saveDraft(String(repeating: "x", count: bytes), conversationID: value.id)
        if archived { try await database.archiveConversation(id: value.id) }
        let saved = try await database.conversation(id: value.id)
        return try XCTUnwrap(saved)
    }

    func testStorageSizesIncludeEncodedAttachmentsInsideChatTotal() async throws {
        let value = try await chat("Media", bytes: 20)
        let attachment = ContextAttachment(kind: .attachment, title: "Example", text: "Sample", mediaData: Data([0, 1, 2, 3, 4, 5]), mimeType: "image/png")
        try await database.saveFeature([attachment], kind: "context", id: value.id.uuidString, conversationID: value.id)
        let summary = try await database.libraryStorageSummary()
        XCTAssertEqual(summary.chatCount, 1)
        XCTAssertEqual(summary.attachmentPayloadBytes, 14, "Six text bytes plus eight base64 payload bytes")
        XCTAssertGreaterThan(summary.chatBytes, summary.attachmentPayloadBytes + 20)
        await tools.refreshStorage()
        XCTAssertEqual(tools.storageSummary.chatBytes, summary.chatBytes)
        XCTAssertGreaterThan(tools.diskStorage.databaseBytes, 0)
        XCTAssertEqual(tools.diskStorage.cacheBytes, 0)
    }

    func testRefreshRequestedDuringScanIncludesCleanupAndSurvivesCallerCancellation() async throws {
        let value = try await chat("Remove during scan", bytes: 2_000, archived: true)
        let database = try XCTUnwrap(database)
        let gate = StorageSummaryReadGate()
        let captured = expectation(description: "First summary captured before cleanup")
        let queued = expectation(description: "Cleanup requests a fresh summary")
        let library = LibraryToolsController(database: database, cacheRoot: directory.appendingPathComponent("Cache"), storageSummaryLoader: {
            let summary = try await database.libraryStorageSummary()
            await gate.pauseFirstRead(entered: captured)
            return summary
        })
        let first = Task { await library.refreshStorage() }
        await fulfillment(of: [captured], timeout: 2)
        let removed = try await database.deleteArchivedConversation(id: value.id)
        XCTAssertTrue(removed)
        let second = Task {
            queued.fulfill()
            await library.refreshStorage()
        }
        await fulfillment(of: [queued], timeout: 2)
        first.cancel() // Closing the view must not cancel cleanup's queued refresh.
        await gate.release()
        await first.value
        await second.value
        XCTAssertEqual(library.storageSummary.chatCount, 0)
        XCTAssertEqual(library.storageSummary.chatBytes, 0)
        XCTAssertTrue(library.upcomingDeletions.isEmpty)
        XCTAssertFalse(library.storageRefreshing)
        let reads = await gate.readCount
        XCTAssertEqual(reads, 2)
    }

    func testStorageKeysetPagingSortAndArchivedScope() async throws {
        for index in 0..<57 { _ = try await chat("Sized \(index)", bytes: index / 3 + 1, archived: index % 2 == 0) }
        let first = try await database.chatStoragePage()
        let second = try await database.chatStoragePage(after: first.last)
        XCTAssertEqual(first.count, 50)
        XCTAssertEqual(second.count, 7)
        XCTAssertEqual(Set((first + second).map(\.id)).count, 57)
        XCTAssertEqual((first + second).map(\.storedBytes), (first + second).map(\.storedBytes).sorted(by: >))
        let archived = try await database.chatStoragePage(query: .init(sort: .smallest, scope: .archived))
        XCTAssertEqual(archived.count, 29)
        XCTAssertTrue(archived.allSatisfy { $0.conversation.archivedAt != nil })
        XCTAssertEqual(archived.map(\.storedBytes), archived.map(\.storedBytes).sorted())
    }

    func testStorageQueryChangesSuppressPreviousSearch() async throws {
        _ = try await chat("First query")
        let second = try await chat("Second query")
        let firstTask = Task { await tools.loadStorage(query: .init(search: "First")) }
        while tools.storageQuery.search != "First" { await Task.yield() }
        await tools.loadStorage(query: .init(search: "Second"))
        await firstTask.value
        XCTAssertEqual(tools.storageEntries.map(\.id), [second.id])
        XCTAssertFalse(tools.storageLoading)
    }

    func testMultiSelectCleanupProtectsActiveAndExplicitlyProtectedChats() async throws {
        let remove = try await chat("Remove", archived: true)
        let protect = try await chat("Protect", archived: true)
        let active = try await chat("Active")
        let rows = try await database.chatStoragePage()
        await tools.deleteArchivedChats(rows, protectedIDs: [protect.id])
        let removed = try await database.conversation(id: remove.id)
        let protected = try await database.conversation(id: protect.id)
        let activeStored = try await database.conversation(id: active.id)
        XCTAssertNil(removed)
        XCTAssertNotNil(protected)
        XCTAssertNotNil(activeStored)
        XCTAssertEqual(tools.storageSummary.chatCount, 2)
        XCTAssertFalse(tools.storageBusy)
    }

    func testUpcomingDeletionsAreBoundedAndUseLargeChatPolicy() async throws {
        let old = try await chat("Old large", bytes: Int(ArchiveRetention.largeChatBytes), archived: true)
        for index in 0..<31 { _ = try await chat("Other \(index)", archived: true) }
        let upcoming = try await database.upcomingArchiveDeletions(limit: 5)
        XCTAssertEqual(upcoming.count, 5)
        XCTAssertEqual(upcoming.first?.id, old.id)
        let expected = try XCTUnwrap(old.archivedAt).addingTimeInterval(20 * 86_400)
        XCTAssertEqual(upcoming.first?.deletionDate, expected)
    }

    func testBookmarkPersistsRenamesAndRejectsWrongConversation() async throws {
        let value = try await chat("Original"), wrong = try await chat("Wrong")
        let message = TimelineEntry(kind: .agentMessage, title: "Agent", text: String(repeating: "Useful content ", count: 100))
        try await database.save(entry: message, conversationID: value.id)
        let original = try await database.saveMessageBookmark(conversationID: value.id, messageID: message.id, label: "First label")
        let updated = try await database.saveMessageBookmark(conversationID: value.id, messageID: message.id, label: "Renamed")
        XCTAssertEqual(original.createdAt, updated.createdAt)
        XCTAssertEqual(updated.preview.count, 300)
        do {
            _ = try await database.saveMessageBookmark(conversationID: wrong.id, messageID: message.id, label: "Wrong owner")
            XCTFail("Messages must belong to their saved conversation")
        } catch { }
        let reopened = try DatabaseActor(url: directory.appendingPathComponent("library.sqlite3"))
        let saved = try await reopened.messageBookmarkPage(search: "Renamed")
        XCTAssertEqual(saved.map(\.id), [message.id])
        XCTAssertEqual(saved.first?.conversationTitle, value.title)
        XCTAssertTrue(saved.first?.messageExists == true)
    }

    func testBookmarkPageIsBoundedAndStableAfterLabelChange() async throws {
        let value = try await chat("Chat")
        for index in 0..<53 {
            let message = TimelineEntry(kind: .userMessage, title: "You", text: "Message \(index)")
            try await database.save(entry: message, conversationID: value.id)
            _ = try await database.saveMessageBookmark(conversationID: value.id, messageID: message.id, label: "Label \(index)")
        }
        let first = try await database.messageBookmarkPage()
        let cursor = try XCTUnwrap(first.last?.bookmark)
        _ = try await database.saveMessageBookmark(conversationID: value.id, messageID: cursor.id, label: "Updated cursor")
        let second = try await database.messageBookmarkPage(after: cursor)
        XCTAssertEqual(first.count, 50)
        XCTAssertEqual(second.count, 3)
        XCTAssertEqual(Set((first + second).map(\.id)).count, 53)
    }

    func testEditingAndRemovingBookmarksPreservesAlreadyLoadedPages() async throws {
        let value = try await chat("Bookmarked history")
        for index in 0..<53 {
            let message = TimelineEntry(kind: .userMessage, title: "You", text: "Message \(index)")
            try await database.save(entry: message, conversationID: value.id)
            _ = try await database.saveMessageBookmark(conversationID: value.id, messageID: message.id, label: "Label \(index)")
        }
        await tools.loadBookmarks()
        await tools.loadBookmarks(more: true)
        XCTAssertEqual(tools.bookmarks.count, 53)
        let lastPageBookmark = try XCTUnwrap(tools.bookmarks.last?.bookmark)
        let firstID = try XCTUnwrap(tools.bookmarks.first?.id)
        let saved = await tools.saveBookmark(messageID: lastPageBookmark.id, conversationID: value.id, label: "Updated on page two")
        XCTAssertTrue(saved)
        XCTAssertEqual(tools.bookmarks.count, 53)
        XCTAssertEqual(tools.bookmarks.last?.id, lastPageBookmark.id)
        XCTAssertEqual(tools.bookmarks.last?.bookmark.label, "Updated on page two")
        await tools.removeBookmark(firstID)
        XCTAssertEqual(tools.bookmarks.count, 52)
        XCTAssertEqual(tools.bookmarks.last?.id, lastPageBookmark.id)
        XCTAssertFalse(tools.bookmarksHaveMore)
    }

    func testBookmarkJumpLoadsOriginalMessageOutsideVisibleWindow() async throws {
        let value = try await chat("Long history")
        var target: TimelineEntry?
        for index in 0..<140 {
            let message = TimelineEntry(kind: .userMessage, title: "You", text: "Prompt \(index)")
            try await database.save(entry: message, conversationID: value.id)
            if index == 5 { target = message }
        }
        let targetMessage = try XCTUnwrap(target)
        let bookmark = try await database.saveMessageBookmark(conversationID: value.id, messageID: targetMessage.id, label: "Earlier prompt")
        await tools.openBookmark(bookmark, model: model)
        XCTAssertEqual(model.selectedConversation?.id, value.id)
        XCTAssertEqual(model.navigationTarget, targetMessage.id)
        XCTAssertTrue(model.timeline.contains { $0.id == targetMessage.id })
        XCTAssertNil(tools.bookmarkNotice)
    }

    func testMissingOriginalIsReportedAndChatDeletionCascadesBookmark() async throws {
        let value = try await chat("Disposable")
        let message = TimelineEntry(kind: .agentMessage, title: "Agent", text: "Save me")
        try await database.save(entry: message, conversationID: value.id)
        let bookmark = try await database.saveMessageBookmark(conversationID: value.id, messageID: message.id, label: "Saved")
        var connection: OpaquePointer?
        XCTAssertEqual(sqlite3_open(directory.appendingPathComponent("library.sqlite3").path, &connection), SQLITE_OK)
        defer { sqlite3_close(connection) }
        XCTAssertEqual(sqlite3_exec(connection, "DELETE FROM timeline_items WHERE id='\(message.id)'", nil, nil, nil), SQLITE_OK)
        let stale = try await database.messageBookmarkPage()
        XCTAssertEqual(stale.first?.messageExists, false)
        await tools.openBookmark(bookmark, model: model)
        XCTAssertNotNil(tools.bookmarkNotice)
        XCTAssertNil(model.navigationTarget)
        try await database.archiveConversation(id: value.id)
        _ = try await database.deleteArchivedConversation(id: value.id)
        let remaining = try await database.messageBookmarkPage()
        let feature = try await database.feature(MessageBookmark.self, kind: "message-bookmark", id: message.id.uuidString)
        XCTAssertTrue(remaining.isEmpty)
        XCTAssertNil(feature)
    }

    func testBookmarkLabelsValidateAndStreamingMessagesCannotBeSaved() async throws {
        let value = try await chat("Streaming")
        let message = TimelineEntry(kind: .agentMessage, title: "Agent", text: "Partial", isStreaming: true)
        try await database.save(entry: message, conversationID: value.id)
        let result = await tools.saveBookmark(messageID: message.id, conversationID: value.id, label: "Label")
        XCTAssertFalse(result)
        XCTAssertNotNil(tools.bookmarkNotice)
        XCTAssertTrue(tools.bookmarkOperationIDs.isEmpty)
        var finished = message; finished.isStreaming = false
        try await database.save(entry: finished, conversationID: value.id)
        let blank = await tools.saveBookmark(messageID: message.id, conversationID: value.id, label: "  ")
        XCTAssertFalse(blank)
        let tooLong = await tools.saveBookmark(messageID: message.id, conversationID: value.id, label: String(repeating: "x", count: 161))
        XCTAssertFalse(tooLong)
    }
}

private actor StorageSummaryReadGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var readCount = 0

    func pauseFirstRead(entered: XCTestExpectation) async {
        readCount += 1
        guard readCount == 1 else { return }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            entered.fulfill()
        }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}
