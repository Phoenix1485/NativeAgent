import XCTest
@testable import NativeAgent

final class ConversationNavigationTests: XCTestCase {
    func testVisiblePromptSurvivesEvictionDuringLongLiveToolRun() {
        let first = TimelineEntry(kind: .userMessage, title: "You", text: "First")
        let second = TimelineEntry(kind: .userMessage, title: "You", text: "Second")
        let tool = TimelineEntry(kind: .command, title: "Tool", text: "Output")
        let prompts = [PromptBookmark(id: first.id, order: 1, preview: first.text), PromptBookmark(id: second.id, order: 100, preview: second.text)]
        XCTAssertEqual(PromptFisheye.currentPrompt(entryIndex: 0, timeline: [tool, second, tool], prompts: prompts), first.id)
        XCTAssertEqual(PromptFisheye.currentPrompt(entryIndex: 2, timeline: [tool, second, tool], prompts: prompts), second.id)
        XCTAssertEqual(PromptFisheye.currentPrompt(entryIndex: 0, timeline: [tool], prompts: prompts), second.id)
    }
    func testFisheyeFallsOffSymmetricallyAndClampsNavigation() {
        XCTAssertEqual(PromptFisheye.strength(distance: 0), 1)
        XCTAssertGreaterThan(PromptFisheye.strength(distance: 14), PromptFisheye.strength(distance: 28))
        XCTAssertEqual(PromptFisheye.strength(distance: -28), PromptFisheye.strength(distance: 28))
        XCTAssertEqual(PromptFisheye.strength(distance: 56), 0)
        XCTAssertEqual(PromptFisheye.strength(distance: 100), 0)
        XCTAssertNil(PromptFisheye.nearestIndex(y: 0, count: 0))
        XCTAssertEqual(PromptFisheye.nearestIndex(y: -10, count: 3), 0)
        XCTAssertEqual(PromptFisheye.nearestIndex(y: 500, count: 3), 2)
    }

    func testPromptIndexAndSeekPreserveIDsAcrossHistoryWindows() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try DatabaseActor(url: directory.appendingPathComponent("test.sqlite3"))
        let chat = Conversation(title: "Long conversation")
        try await database.save(conversation: chat)
        var ids: [UUID] = []
        for index in 0..<300 {
            let prompt = TimelineEntry(kind: .userMessage, title: "You", text: "Prompt \(index) " + String(repeating: "x", count: 500))
            ids.append(prompt.id)
            try await database.save(entry: prompt, conversationID: chat.id)
            try await database.save(entry: .init(kind: .agentMessage, title: "Agent", text: "Reply"), conversationID: chat.id)
        }
        let bookmarks = try await database.promptBookmarks(conversationID: chat.id)
        XCTAssertEqual(bookmarks.map(\.id), ids)
        XCTAssertTrue(bookmarks.allSatisfy { $0.preview.count == 240 })
        let window = try await database.timelineWindow(conversationID: chat.id, around: ids[100])
        XCTAssertLessThanOrEqual(window.count, 60)
        XCTAssertTrue(window.contains { $0.id == ids[100] })
        let older = try await database.timeline(conversationID: chat.id, limit: 40, beforeOrder: window.first?.receivedOrder)
        XCTAssertTrue(Set(older.map(\.id)).isDisjoint(with: window.map(\.id)))
        XCTAssertEqual(PromptFisheye.currentPrompt(order: 202, prompts: bookmarks), ids[100])
        let wrongChat = Conversation(title: "Other")
        try await database.save(conversation: wrongChat)
        let wrongWindow = try await database.timelineWindow(conversationID: wrongChat.id, around: ids[100])
        XCTAssertTrue(wrongWindow.isEmpty)
    }

    func testFactsPersistAndUpdateWithoutChangingMessageIdentity() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try DatabaseActor(url: directory.appendingPathComponent("test.sqlite3"))
        let chat = Conversation()
        try await database.save(conversation: chat)
        var fact = ConversationFact(key: "tool/1", category: .activity, title: "Run tests", text: "In progress", state: "inProgress")
        var entry = TimelineEntry(kind: .fact, title: fact.title, text: fact.text, detail: fact.encoded)
        try await database.save(entry: entry, conversationID: chat.id)
        let order = try await database.timelineOrder(id: entry.id)
        fact.state = "completed"
        entry.detail = fact.encoded; entry.text = "Completed"
        try await database.save(entry: entry, conversationID: chat.id)
        let restored = try await database.timeline(conversationID: chat.id, detailsOnly: true)
        XCTAssertEqual(restored.count, 1)
        XCTAssertEqual(restored.first?.id, entry.id)
        XCTAssertEqual(restored.first?.receivedOrder, order)
        XCTAssertEqual(ConversationFact.decode(restored.first?.detail)?.state, "completed")
        for index in 0..<220 {
            try await database.save(entry: .init(kind: .command, title: "Command", text: "Output", createdAt: entry.createdAt.addingTimeInterval(Double(index + 1))), conversationID: chat.id)
        }
        entry.createdAt = entry.createdAt.addingTimeInterval(1_000)
        try await database.save(entry: entry, conversationID: chat.id)
        let recent = try await database.timeline(conversationID: chat.id, limit: 1, detailsOnly: true)
        XCTAssertEqual(recent.first?.id, entry.id, "An updated task fact stays discoverable after long tool runs")
        XCTAssertEqual(recent.first?.receivedOrder, order, "Updating details must not reorder message navigation")
    }

    func testCodexReportsOnlyExplicitSourcesAndSuccessfulFileChanges() async throws {
        let provider = CodexProvider(binaryPath: "/never-launched")
        let events = await provider.events
        let capture = Task { () -> [ProviderEvent] in
            var result: [ProviderEvent] = []
            for await event in events { result.append(event); if case .turnCompleted = event { break } }
            return result
        }
        func notification(_ method: String, _ json: String) throws -> RPCNotification {
            .init(method: method, params: try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8)))
        }
        await provider.handle(try notification("turn/plan/updated", #"{"turnId":"turn","plan":[{"step":"Inspect","status":"completed"},{"step":"Build","status":"inProgress"}]}"#))
        await provider.handle(try notification("item/started", #"{"turnId":"turn","item":{"id":"cmd","type":"commandExecution","command":"swift test","status":"inProgress"}}"#))
        await provider.handle(try notification("item/completed", #"{"turnId":"turn","item":{"id":"cmd","type":"commandExecution","command":"cat App.swift","cwd":"/project","commandActions":[{"type":"read","path":"App.swift"}],"status":"completed","exitCode":0}}"#))
        await provider.handle(try notification("item/completed", #"{"turnId":"turn","item":{"id":"search","type":"webSearch","query":"example"}}"#))
        await provider.handle(try notification("item/completed", #"{"turnId":"turn","item":{"id":"web","type":"webSearch","query":"example","action":{"type":"openPage","url":"https://example.com/docs"}}}"#))
        await provider.handle(try notification("item/completed", #"{"turnId":"turn","item":{"id":"image","type":"imageView","path":"Sources/diagram.png"}}"#))
        await provider.handle(try notification("item/completed", #"{"turnId":"turn","item":{"id":"edit","type":"fileChange","status":"declined","changes":[{"path":"NotWritten.swift","diff":"proposed"}]}}"#))
        await provider.handle(try notification("item/completed", #"{"turnId":"turn","item":{"id":"reply","type":"agentMessage","text":"Maybe see https://invented.invalid"}}"#))
        await provider.handle(try notification("turn/completed", #"{"turn":{"id":"turn","status":"completed"}}"#))
        let received = await capture.value
        let facts = received.compactMap { event -> ConversationFact? in if case .conversationFact(_, let fact) = event { return fact }; return nil }
        XCTAssertEqual(facts.filter { $0.category == .source }.count, 3)
        XCTAssertTrue(facts.contains { $0.path == "/project/App.swift" })
        XCTAssertEqual(facts.first { $0.url != nil }?.url, "https://example.com/docs")
        XCTAssertTrue(facts.contains { $0.category == .plan && $0.text.contains("Completed: Inspect") })
        XCTAssertEqual(facts.filter { $0.key == "item/cmd" }.map(\.state), ["inProgress", "completed"])
        XCTAssertFalse(received.contains { if case .fileChange = $0 { return true }; return false })
    }
}
