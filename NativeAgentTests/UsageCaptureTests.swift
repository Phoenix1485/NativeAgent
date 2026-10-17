import Foundation
import XCTest
@testable import NativeAgent

@MainActor
final class UsageCaptureTests: XCTestCase {
    private var directory: URL!
    private var suite: String!
    private var defaults: UserDefaults!
    private var database: DatabaseActor!
    private var provider: SettingsTestProvider!
    private var model: WorkspaceViewModel!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        suite = "NativeAgentUsageCaptureTests.\(UUID())"
        defaults = UserDefaults(suiteName: suite)!
        database = try DatabaseActor(url: directory.appendingPathComponent("test.sqlite3"))
        provider = SettingsTestProvider()
        model = WorkspaceViewModel(provider: provider, database: database, files: FileService(), git: GitService(),
            automaticallyRestore: false, preferences: defaults, credentials: MemoryCredentials(),
            chatGPTCredentials: MemoryChatGPTCredentials(), aiTokens: MemoryAITokens(),
            apiCompletion: { _, _, _, _ in "Offline answer" })
        await model.connect()
        await model.newConversation(); await model.addProject(directory)
        let project = try XCTUnwrap(model.selectedProject)
        defaults.set([project.id.uuidString], forKey: "trustedProjectIDs")
    }

    override func tearDown() async throws {
        await model.shutdown()
        model = nil; provider = nil; database = nil
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }

    private func waitForRecords(_ count: Int, total: Int64? = nil) async throws {
        for _ in 0..<100 {
            let summary = try await database.usageSummary()
            if summary.totals.recordCount == count, total == nil || summary.totals.tokens.totalTokens == total { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Usage capture did not reach the expected totals")
    }

    func testRepeatedReportsStayWithOriginalChatAndDifferentTurnsRemainSeparate() async throws {
        await provider.setCompleteImmediately(false)
        let chat = try XCTUnwrap(model.selectedConversation)
        model.draft = "First question"; await model.send()
        let threads = await provider.sentThreads
        let thread = try XCTUnwrap(threads.first)
        await provider.emit(.turnStarted("turn-one"))
        await model.newConversation()
        let visibleChat = try XCTUnwrap(model.selectedConversation)
        await provider.emit(.tokenUsage(.init(id: "private-response-id", turnID: "turn-one", threadID: "foreign-thread",
            tokens: .init(inputTokens: 999, outputTokens: 999))))
        await provider.emit(.tokenUsage(.init(id: "private-response-id", turnID: "turn-one", threadID: thread, model: "private-endpoint-echo",
            tokens: .init(inputTokens: 100, outputTokens: 10))))
        await provider.emit(.tokenUsage(.init(id: "private-response-id", turnID: "turn-one", threadID: thread, model: "private-endpoint-echo",
            tokens: .init(inputTokens: 120, outputTokens: 15, cachedInputTokens: 50), contextTokens: 120, contextLimit: 1000)))
        await provider.emit(.turnCompleted(turnID: "turn-one", status: .completed, error: nil))
        try await waitForRecords(1, total: 135)
        let records = try await database.usageRecords()
        XCTAssertEqual(records.first?.conversationID, chat.id)
        XCTAssertEqual(records.first?.tokens?.cachedInputTokens, 50)
        XCTAssertEqual(records.first?.contextTokens, 120)
        let stored = String(decoding: try JSONEncoder().encode(records), as: UTF8.self)
        XCTAssertFalse(stored.contains("private-response-id"))
        XCTAssertFalse(stored.contains("private-endpoint-echo"))
        XCTAssertEqual(model.selectedConversation?.id, visibleChat.id)
        for _ in 0..<100 where model.isWorking { try await Task.sleep(for: .milliseconds(10)) }
        model.draft = "Second question"; await model.send()
        await provider.emit(.turnStarted("turn-two"))
        await provider.emit(.tokenUsage(.init(id: "private-response-id", turnID: "turn-two", tokens: .init(inputTokens: 0, outputTokens: 0))))
        await provider.emit(.turnCompleted(turnID: "turn-two", status: .completed, error: nil))
        try await waitForRecords(2, total: 135)
        let summary = try await database.usageSummary()
        XCTAssertEqual(summary.totals.reportedCount, 2)
        XCTAssertEqual(Set(summary.conversations.map(\.id)), [chat.id.uuidString, visibleChat.id.uuidString])
    }

    func testUnreportedTurnIsMissingNotZeroAndForeignIdleEventsAreIgnored() async throws {
        await provider.emit(.tokenUsage(.init(id: "idle", tokens: .init(inputTokens: 800, outputTokens: 50))))
        model.draft = "No counters supplied"; await model.send()
        try await waitForRecords(1)
        let summary = try await database.usageSummary()
        XCTAssertEqual(summary.totals.reportedCount, 0)
        XCTAssertEqual(summary.totals.missingCount, 1)
        let records = try await database.usageRecords()
        XCTAssertNil(records.first?.tokens)
        XCTAssertEqual(records.first?.activity, "Chat")
    }

    func testIsolatedAIRequestCapturesRecipientActivityAndChatBeforeSelectionChanges() async throws {
        let chat = try XCTUnwrap(model.selectedConversation)
        let connection = AIConnection(name: "My Claude", baseURL: "https://api.anthropic.com/v1", model: "fixture-model", format: .anthropic)
        try model.saveAIConnection(connection, token: "fixture-secret")
        let recipient = AIRecipient(id: connection.id.uuidString, name: connection.name, model: connection.model,
            detail: "Fixture", connection: connection)
        let jobs = try model.makeAIReviewJobs(recipients: [recipient], instructions: "Private instructions", input: "Private prompt",
            projectPath: directory.path, activity: "Review changes", conversationID: chat.id)
        await model.newConversation()
        let answer = try await XCTUnwrap(jobs.first).complete()
        XCTAssertEqual(answer, "Offline answer")
        let records = try await database.usageRecords()
        let record = try XCTUnwrap(records.first)
        XCTAssertEqual(record.provider, "Claude"); XCTAssertEqual(record.model, connection.model)
        XCTAssertEqual(record.source, "API"); XCTAssertEqual(record.activity, "Review changes")
        XCTAssertEqual(record.conversationID, chat.id); XCTAssertNil(record.tokens)
        let stored = String(decoding: try JSONEncoder().encode(record), as: UTF8.self)
        for secret in ["Private instructions", "Private prompt", "fixture-secret"] { XCTAssertFalse(stored.contains(secret)) }
    }
}
