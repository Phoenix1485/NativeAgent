import Foundation
import XCTest
@testable import NativeAgent

final class DatabaseTests: XCTestCase {
    func testProjectConversationTimelineAndDraftRoundTrip() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try DatabaseActor(url: directory.appendingPathComponent("test.sqlite3"))
        let project = Project(name: "Example", canonicalPath: directory.path)
        try await database.save(project: project)
        let projects = try await database.projects()
        XCTAssertEqual(projects.first?.id, project.id)
        XCTAssertEqual(projects.first?.name, project.name)
        XCTAssertEqual(projects.first?.canonicalPath, project.canonicalPath)

        let conversation = Conversation(projectID: project.id, title: "Test")
        try await database.save(conversation: conversation)
        let conversations = try await database.conversations(projectID: project.id)
        XCTAssertEqual(conversations.first?.title, "Test")

        let entry = TimelineEntry(kind: .userMessage, title: "You", text: "Hello")
        try await database.save(entry: entry, conversationID: conversation.id)
        let timeline = try await database.timeline(conversationID: conversation.id)
        XCTAssertEqual(timeline.map(\.text), ["Hello"])

        try await database.saveDraft("unfinished", conversationID: conversation.id)
        let draft = try await database.draft(conversationID: conversation.id)
        XCTAssertEqual(draft, "unfinished")
    }
}
