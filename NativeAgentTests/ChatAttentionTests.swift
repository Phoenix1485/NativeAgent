import XCTest
@testable import NativeAgent

final class ChatAttentionTests: XCTestCase {
    func testPinnedAndUnreadPersistIndependentlyAndArchiveHidesThem() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("library.sqlite3"), db = try DatabaseActor(url: url)
        let chat = Conversation(title: "Important"); try await db.save(conversation: chat)
        try await db.setChatAttention(chat.id, pinned: true)
        try await db.setChatAttention(chat.id, unread: true)
        let reopened = try DatabaseActor(url: url)
        var states = try await reopened.chatAttention()
        XCTAssertEqual(states[chat.id], ChatAttention(pinned: true, unread: true))
        let pinned = try await reopened.pinnedConversations()
        XCTAssertEqual(pinned.map(\.id), [chat.id])
        try await db.setChatAttention(chat.id, unread: false)
        states = try await reopened.chatAttention()
        XCTAssertEqual(states[chat.id], ChatAttention(pinned: true, unread: false))
        try await db.archiveConversation(id: chat.id)
        states = try await reopened.chatAttention()
        XCTAssertNil(states[chat.id])
        let archivedPins = try await reopened.pinnedConversations()
        XCTAssertTrue(archivedPins.isEmpty)
    }
}
