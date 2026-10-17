import Foundation
import XCTest
@testable import NativeAgent

@MainActor
final class AIAssistanceTests: XCTestCase {
    private var directory: URL!
    private var suite: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        suite = "AIAssistanceTests.\(UUID())"; defaults = UserDefaults(suiteName: suite)!
    }
    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
    private func model(probe: ReviewProbe, delay: Duration = .milliseconds(20)) throws -> WorkspaceViewModel {
        WorkspaceViewModel(provider: SettingsTestProvider(), database: try DatabaseActor(url: directory.appendingPathComponent("test.sqlite3")), files: FileService(), git: GitService(), automaticallyRestore: false, preferences: defaults, credentials: MemoryCredentials(), chatGPTCredentials: MemoryChatGPTCredentials(), aiTokens: MemoryAITokens(), apiCompletion: { connection, _, _, prompt in
            try await probe.complete(connection.name, prompt: prompt, delay: delay)
        })
    }
    private func add(_ name: String, to model: WorkspaceViewModel) throws -> AIConnection {
        let connection = AIConnection(name: name, baseURL: "https://fixture.invalid/v1", model: "test-model")
        try model.saveAIConnection(connection, token: "test-token")
        return connection
    }
    func testExplicitReviewSendsOnlySelectedSourceAndPreservesIndependentFailures() async throws {
        let probe = ReviewProbe(), model = try model(probe: probe)
        let first = try add("Custom", to: model), second = try add("Broken", to: model)
        model.draft = "PRIVATE DRAFT"
        model.timeline = [.init(kind: .userMessage, title: "You", text: "UNRELATED HISTORY")]
        let request = AIAssistanceRequest(purpose: .review, source: "Selected staged diff", content: "+let answer = 42", projectPath: nil)
        model.assistant.prepare(request)
        model.assistant.selectedRecipients = [first.id.uuidString, second.id.uuidString]
        XCTAssertFalse(model.assistant.isRunning)
        let initial = await probe.calls; XCTAssertTrue(initial.isEmpty)
        model.assistant.run()
        XCTAssertTrue(model.isWorking)
        for _ in 0..<100 where model.assistant.isRunning { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(model.assistant.isRunning)
        XCTAssertEqual(model.assistant.answers.count, 2)
        XCTAssertEqual(model.assistant.answers.first { $0.name == "Custom" }?.text, "Answer from Custom")
        XCTAssertNotNil(model.assistant.answers.first { $0.name == "Broken" }?.error)
        let prompts = await probe.prompts
        XCTAssertEqual(prompts.count, 2)
        XCTAssertTrue(prompts.allSatisfy { $0.contains("+let answer = 42") && !$0.contains("PRIVATE DRAFT") && !$0.contains("UNRELATED HISTORY") })
        XCTAssertEqual(model.draft, "PRIVATE DRAFT")
        XCTAssertEqual(model.timeline.count, 1)
        await model.shutdown()
    }
    func testStopCancelsReviewWithoutStartingQueuedProvidersOrReplacingRequest() async throws {
        let probe = ReviewProbe(), model = try model(probe: probe, delay: .seconds(10))
        var ids: Set<String> = []
        for index in 0..<4 { ids.insert(try add("AI \(index)", to: model).id.uuidString) }
        let original = AIAssistanceRequest(purpose: .commit, source: "Staged", content: "+change", projectPath: nil)
        model.assistant.prepare(original); model.assistant.selectedRecipients = ids; model.assistant.run()
        model.assistant.prepare(.init(purpose: .review, source: "Other", content: "other", projectPath: nil))
        XCTAssertEqual(model.assistant.request?.id, original.id)
        try await Task.sleep(for: .milliseconds(30))
        await model.stop()
        await model.assistant.shutdown()
        let calls = await probe.calls
        XCTAssertLessThanOrEqual(calls.count, 2)
        XCTAssertTrue(model.assistant.answers.allSatisfy { $0.text == nil })
        XCTAssertFalse(model.isWorking)
        await model.shutdown()
    }
    func testOversizedOrUnavailableSelectionDoesNotSend() async throws {
        let probe = ReviewProbe(), model = try model(probe: probe)
        let connection = try add("Custom", to: model)
        model.assistant.prepare(.init(purpose: .review, source: "Huge", content: String(repeating: "🙂", count: 50_000), projectPath: nil))
        model.assistant.run()
        XCTAssertFalse(model.assistant.isRunning); XCTAssertNotNil(model.assistant.notice)
        model.assistant.prepare(.init(purpose: .review, source: "Small", content: "diff", projectPath: nil))
        try model.removeAIConnection(connection.id)
        model.assistant.run()
        let calls = await probe.calls; XCTAssertTrue(calls.isEmpty)
        XCTAssertNotNil(model.assistant.notice)
        await model.shutdown()
    }
    func testComparisonPreservesAttributionAndRejectsSilentTruncation() throws {
        let text = try AIAnswerComparison.content([(title: "Claude", text: "Use A\n\"quoted\""), (title: "Custom", text: "Use B")])
        let values = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [[String: String]])
        XCTAssertEqual(values.map { $0["speaker"] }, ["Claude", "Custom"])
        XCTAssertEqual(values[0]["answer"], "Use A\n\"quoted\"")
        XCTAssertThrowsError(try AIAnswerComparison.content([(title: "Only", text: "one")]))
        XCTAssertThrowsError(try AIAnswerComparison.content([(title: "Large", text: String(repeating: "x", count: 160_000)), (title: "Other", text: "answer")]))
    }
}
