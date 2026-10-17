import XCTest
@testable import NativeAgent

final class ConversationMemoryTests: XCTestCase {
    func testSummaryPreservesOlderMessagesAndRecentTextIsNotTruncated() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let db = try DatabaseActor(url: directory.appendingPathComponent("test.sqlite3"))
        let chat = Conversation(); try await db.save(conversation: chat)
        for index in 1...30 {
            try await db.save(entry: .init(kind: .userMessage, title: "", text: "MESSAGE-\(index) " + String(repeating: "x", count: 2100)), conversationID: chat.id)
        }
        var calls = 0
        let prompt = try await ConversationMemoryService.prepare(database: db, chat: chat.id, current: "NOW") { _, input in
            calls += 1
            return input.contains("MESSAGE-1 ") ? "Remember early goal" : "Remember early goal, updated"
        }
        XCTAssertGreaterThan(calls, 0)
        XCTAssertTrue(prompt.contains("Remember early goal"))
        XCTAssertTrue(prompt.contains("MESSAGE-30 " + String(repeating: "x", count: 2100)))
        XCTAssertTrue(prompt.contains("NOW"))
        _ = try await ConversationMemoryService.prepare(database: db, chat: chat.id, current: "NEXT") { _, _ in
            XCTFail("Unchanged history must reuse the summary"); return "wrong"
        }
        let saved = try await db.feature(ConversationMemory.self, kind: "chat-memory", id: chat.id.uuidString)
        XCTAssertNotNil(saved)
        let original = try await db.timeline(conversationID: chat.id, limit: 100)
        XCTAssertEqual(original.count, 30)
    }

    func testCancellationDoesNotAdvanceMemoryCheckpoint() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let db = try DatabaseActor(url: directory.appendingPathComponent("test.sqlite3"))
        let chat = Conversation(); try await db.save(conversation: chat)
        try await db.save(entry: .init(kind: .userMessage, title: "", text: String(repeating: "x", count: 50_000)), conversationID: chat.id)
        do {
            _ = try await ConversationMemoryService.prepare(database: db, chat: chat.id, current: "NOW") { _, _ in throw CancellationError() }
            XCTFail("Must propagate cancellation")
        } catch is CancellationError { }
        let saved = try await db.feature(ConversationMemory.self, kind: "chat-memory", id: chat.id.uuidString)
        XCTAssertNil(saved)
    }
}
