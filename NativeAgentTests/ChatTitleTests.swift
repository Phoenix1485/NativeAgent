import XCTest
@testable import NativeAgent

final class ChatTitleTests: XCTestCase {
    @MainActor
    func testLongTitleScrollsLeftAndRepeatsAtTheSamePosition() {
        let width: CGFloat = 268
        let cycle = 0.7 + Double((width + 32) / 30)
        XCTAssertEqual(ScrollingChatTitle.offset(elapsed: 0.5, width: width), 0)
        XCTAssertEqual(ScrollingChatTitle.offset(elapsed: 1.7, width: width), -30, accuracy: 0.001)
        XCTAssertEqual(ScrollingChatTitle.offset(elapsed: 1.7 + cycle, width: width), -30, accuracy: 0.001)
        XCTAssertEqual(ScrollingChatTitle.offset(elapsed: 1.7 + 100 * cycle, width: width), -30, accuracy: 0.001)
    }

    func testSuggestionReadsUnloadedMessagesAndSummarizesEveryPartInOrder() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try DatabaseActor(url: directory.appendingPathComponent("titles.sqlite3"))
        let chat = Conversation(title: "Old title")
        try await database.save(conversation: chat)
        for index in 1...85 {
            try await database.save(entry: .init(kind: index % 2 == 0 ? .agentMessage : .userMessage, title: "",
                                                 text: "MESSAGE-\(index) " + String(repeating: "x", count: 700)), conversationID: chat.id)
        }
        try await database.save(entry: .init(kind: .command, title: "", text: "EXCLUDE-TOOL-OUTPUT"), conversationID: chat.id)
        let other = Conversation(title: "Other")
        try await database.save(conversation: other)
        try await database.save(entry: .init(kind: .userMessage, title: "", text: "EXCLUDE-OTHER-CHAT"), conversationID: other.id)
        var requests: [String] = []
        let result = try await ChatTitleService.suggest(database: database, conversationID: chat.id) { instructions, input in
            requests.append(input)
            return instructions.hasPrefix("Write one") ? "  A useful conversation title  " : "Summary-\(requests.count)"
        }
        XCTAssertEqual(result, "A useful conversation title")
        XCTAssertGreaterThan(requests.count, 2)
        let combined = requests.joined()
        for index in 1...85 { XCTAssertTrue(combined.contains("MESSAGE-\(index) ")) }
        XCTAssertFalse(combined.contains("EXCLUDE-"))
        XCTAssertTrue(requests.last?.contains("Summary-2") == true)
        XCTAssertTrue(requests.allSatisfy { $0.count < ChatTitleService.chunkSize + 4_000 })
        let unchanged = try await database.conversation(id: chat.id)
        XCTAssertEqual(unchanged?.title, "Old title") // Suggestions are not automatically saved.
    }

    func testEmptyChatDoesNotMakeAnAIRequestAndCancellationDoesNotReturnTitle() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try DatabaseActor(url: directory.appendingPathComponent("titles.sqlite3"))
        let chat = Conversation()
        try await database.save(conversation: chat)
        do {
            _ = try await ChatTitleService.suggest(database: database, conversationID: chat.id) { _, _ in XCTFail("No transcript"); return "Wrong" }
            XCTFail("Empty transcript must not get an invented title")
        } catch { }
        try await database.save(entry: .init(kind: .userMessage, title: "", text: "Hello"), conversationID: chat.id)
        do {
            _ = try await ChatTitleService.suggest(database: database, conversationID: chat.id) { _, _ in throw CancellationError() }
            XCTFail("Cancellation must propagate")
        } catch is CancellationError { }
    }

    @MainActor
    func testInlineRenamePreservesLatestChatMetadataAndUpdatesSelectedAndSearchTitles() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try DatabaseActor(url: directory.appendingPathComponent("titles.sqlite3"))
        let suite = "NativeAgentTitles.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = WorkspaceViewModel(provider: CodexProvider(binaryPath: "/missing"), database: database, files: FileService(), git: GitService(), automaticallyRestore: false, preferences: defaults)
        var chat = Conversation(title: "Old title")
        try await database.save(conversation: chat)
        model.conversations = [chat]; model.selectedConversation = chat; model.searchResults = [chat]
        model.renameConversation(chat)
        XCTAssertEqual(model.renamingConversationID, chat.id)
        chat.remoteThreadID = "latest-thread"
        try await database.save(conversation: chat)
        try await model.saveConversationTitle(chat.id, title: "  Better name  ")
        let stored = try await database.conversation(id: chat.id)
        XCTAssertEqual(stored?.remoteThreadID, "latest-thread")
        XCTAssertEqual(stored?.title, "Better name")
        XCTAssertEqual(model.selectedConversation?.title, "Better name")
        XCTAssertEqual(model.searchResults.first?.title, "Better name")
        try await database.archiveConversation(id: chat.id)
        do { try await model.saveConversationTitle(chat.id, title: "Too late"); XCTFail("Archived chat") } catch { }
        XCTAssertThrowsError(try ChatTitleService.cleanTitle(" \n "))
        XCTAssertThrowsError(try ChatTitleService.cleanTitle(String(repeating: "a", count: 161)))
    }
}
