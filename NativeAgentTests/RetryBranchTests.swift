import XCTest
@testable import NativeAgent

final class RetryBranchTests: XCTestCase {
    func testEditAndRegeneratePreserveOriginalAndFullEarlierHistory() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let db = try DatabaseActor(url: directory.appendingPathComponent("test.sqlite3"))
        let parent = Conversation(title: "Original"); try await db.save(conversation: parent)
        let first = TimelineEntry(kind: .userMessage, title: "You", text: String(repeating: "earlier ", count: 2000))
        let question = TimelineEntry(kind: .userMessage, title: "You", text: "Original question")
        let answer = TimelineEntry(kind: .agentMessage, title: "Agent", text: "Old answer")
        for entry in [first, question, answer] { try await db.save(entry: entry, conversationID: parent.id) }
        let child = try await db.retryBranch(from: parent, entryID: question.id, editedPrompt: "Corrected question")
        let messages = try await db.timeline(conversationID: child.id)
        XCTAssertEqual(messages.map(\.text), [first.text])
        XCTAssertNotEqual(messages.first?.id, first.id)
        XCTAssertNil(child.remoteThreadID)
        let draft = try await db.draft(conversationID: child.id)
        XCTAssertEqual(draft, "Corrected question")
        let regenerated = try await db.retryBranch(from: parent, entryID: answer.id)
        let retryDraft = try await db.draft(conversationID: regenerated.id)
        XCTAssertEqual(retryDraft, "Original question")
        let original = try await db.timeline(conversationID: parent.id)
        XCTAssertEqual(original.map(\.id), [first.id, question.id, answer.id])
        XCTAssertEqual(original.last?.text, "Old answer")
    }
}
