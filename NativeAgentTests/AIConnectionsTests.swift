import Foundation
import XCTest
@testable import NativeAgent

final class MemoryAITokens: AITokenStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UUID: String] = [:]
    func read(_ id: UUID) -> String? { lock.lock(); defer { lock.unlock() }; return values[id] }
    func save(_ token: String, id: UUID) { lock.lock(); defer { lock.unlock() }; values[id] = token }
    func remove(_ id: UUID) { lock.lock(); defer { lock.unlock() }; values.removeValue(forKey: id) }
}

actor ReviewProbe {
    var active = 0
    var maximum = 0
    var calls: [String] = []
    var results: [String] = []
    var prompts: [String] = []
    func complete(_ name: String, prompt: String = "", delay: Duration = .milliseconds(30)) async throws -> String {
        active += 1; maximum = max(maximum, active); calls.append(name); prompts.append(prompt)
        defer { active -= 1 }
        try await Task.sleep(for: delay)
        if name == "Broken" { throw NativeAgentError.providerUnavailable("Mock rejected request") }
        return "Answer from " + name
    }
    func received(_ name: String) { results.append(name) }
}

@MainActor
final class AIConnectionsTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!
    private var directory: URL!
    override func setUp() async throws {
        suite = "NativeAgentAIConnectionsTests.\(UUID())"
        defaults = UserDefaults(suiteName: suite)!
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }
    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
    private func connection(_ name: String = "Test") -> AIConnection {
        .init(name: name, baseURL: "https://example.invalid/v1", model: "test-model")
    }
    func testTenTokenLimitIncludesLegacyAndNeverPersistsSecrets() throws {
        let tokens = MemoryAITokens(), store = AIConnectionStore(defaults: defaults, tokens: tokens)
        for index in 0..<8 { try store.save(connection("AI \(index)"), token: "fake-secret-\(index)", legacyTokenCount: 2) }
        XCTAssertThrowsError(try store.save(connection("Eleventh"), token: "fake", legacyTokenCount: 2))
        let first = try XCTUnwrap(store.connections.first)
        try store.save(first, token: "replacement", legacyTokenCount: 2)
        XCTAssertEqual(try store.token(for: first.id), "replacement")
        let metadata = try XCTUnwrap(defaults.data(forKey: "nativeagent.ai-connections.v1"))
        XCTAssertFalse(String(decoding: metadata, as: UTF8.self).contains("fake-secret"))
        XCTAssertFalse(String(decoding: metadata, as: UTF8.self).contains("replacement"))
        let restored = AIConnectionStore(defaults: defaults, tokens: tokens)
        XCTAssertEqual(restored.connections.count, 8)
        try restored.remove(first.id)
        XCTAssertNil(tokens.read(first.id))
        try restored.save(connection("New"), token: "fake-new", legacyTokenCount: 2)
        XCTAssertEqual(restored.connections.count, 8)
    }
    func testEndpointChangeRequiresNewTokenAndInvalidInputsDoNotSave() throws {
        let store = AIConnectionStore(defaults: defaults, tokens: MemoryAITokens())
        var value = connection()
        try store.save(value, token: "fake")
        value.baseURL = "https://different.invalid/v1"
        XCTAssertThrowsError(try store.save(value, token: ""))
        XCTAssertEqual(store.connections[0].baseURL, "https://example.invalid/v1")
        for url in ["http://example.invalid/v1", "https://user:secret@example.invalid", "https://example.invalid?key=secret", "https://example.invalid#secret"] {
            value.baseURL = url; XCTAssertThrowsError(try store.save(value, token: "fake"))
        }
        XCTAssertThrowsError(try store.save(connection(), token: "bad\r\nheader"))
        var emptyModel = connection(); emptyModel.model = ""
        XCTAssertThrowsError(try store.save(emptyModel, token: "fake"))
        XCTAssertEqual(store.connections.count, 1)
    }
    func testBothAPIWireFormatsAndErrorRedaction() throws {
        for format in AIWireFormat.allCases {
            var value = connection(); value.format = format
            let request = try APIChatClient.request(connection: value, token: "fake-secret", instructions: "System", prompt: "Question")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fake-secret")
            XCTAssertEqual(request.url?.path, format == .anthropic ? "/v1/messages" : "/v1/chat/completions")
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
            XCTAssertNil(body["tools"]); XCTAssertEqual(body["stream"] as? Bool, false)
            XCTAssertEqual(body["model"] as? String, "test-model")
            if format == .anthropic { XCTAssertEqual(body["max_tokens"] as? Int, 4096); XCTAssertEqual(body["system"] as? String, "System") }
        }
        let openAI = Data(#"{"choices":[{"message":{"content":"Hello"}}]}"#.utf8)
        XCTAssertEqual(try APIChatClient.answer(data: openAI, status: 200, format: .openAI), "Hello")
        let anthropic = Data(#"{"content":[{"type":"thinking","thinking":"hidden"},{"type":"text","text":"Hello Claude"}]}"#.utf8)
        XCTAssertEqual(try APIChatClient.answer(data: anthropic, status: 200, format: .anthropic), "Hello Claude")
        for status in [302, 401, 403, 429, 500] {
            XCTAssertThrowsError(try APIChatClient.answer(data: Data("fake-secret".utf8), status: status, format: .openAI)) { error in
                XCTAssertFalse(error.localizedDescription.contains("fake-secret"))
            }
        }
        XCTAssertThrowsError(try APIChatClient.answer(data: Data(#"{"choices":[]}"#.utf8), status: 200, format: .openAI))
    }
    func testMentionDetectionDoesNotEatEmailsOrNormalText() {
        XCTAssertEqual(ComposerMention.query(in: "Review this @deep"), "deep")
        XCTAssertEqual(ComposerMention.removingToken(from: "Review this @deep"), "Review this ")
        XCTAssertEqual(ComposerMention.query(in: "@"), "")
        XCTAssertNil(ComposerMention.query(in: "mail@example.com"))
        XCTAssertNil(ComposerMention.query(in: "A @mention with words"))
        XCTAssertEqual(ComposerMention.removingToken(from: "Keep my email me@example.com"), "Keep my email me@example.com")
    }
    func testRunnerBoundsConcurrencyPreservesFailuresAndDoesNotRetry() async {
        let probe = ReviewProbe()
        let jobs = ["One", "Broken", "Three", "Four", "Five"].map { name in
            AIReviewJob(recipient: .init(id: name, name: name, model: "model", detail: "fixture")) { try await probe.complete(name) }
        }
        await AIReviewRunner.run(jobs) { recipient, _ in await probe.received(recipient.name) }
        let maximum = await probe.maximum, calls = await probe.calls, results = await probe.results
        XCTAssertEqual(maximum, 2); XCTAssertEqual(calls.count, 5); XCTAssertEqual(Set(results), Set(calls))
    }
    func testRunnerCancellationDoesNotStartQueuedRequests() async throws {
        let probe = ReviewProbe()
        let jobs = (0..<10).map { index in
            AIReviewJob(recipient: .init(id: "\(index)", name: "\(index)", model: "m", detail: "fixture")) { try await probe.complete("\(index)", delay: .seconds(10)) }
        }
        let task = Task { await AIReviewRunner.run(jobs) { recipient, _ in await probe.received(recipient.name) } }
        try await Task.sleep(for: .milliseconds(30)); task.cancel(); await task.value
        let calls = await probe.calls, results = await probe.results
        XCTAssertLessThanOrEqual(calls.count, 2); XCTAssertTrue(results.isEmpty)
    }
    func testSharedChatPersistsLabeledAnswersAndDoesNotLeakAcrossChatSwitch() async throws {
        let probe = ReviewProbe()
        let database = try DatabaseActor(url: directory.appendingPathComponent("test.sqlite3"))
        let model = WorkspaceViewModel(provider: SettingsTestProvider(), database: database, files: FileService(), git: GitService(), automaticallyRestore: false, preferences: defaults, credentials: MemoryCredentials(), chatGPTCredentials: MemoryChatGPTCredentials(), aiTokens: MemoryAITokens(), apiCompletion: { connection, _, _, prompt in try await probe.complete(connection.name, prompt: prompt, delay: .milliseconds(100)) })
        let first = connection("First"), second = connection("Broken")
        try model.saveAIConnection(first, token: "fixture-one"); try model.saveAIConnection(second, token: "fixture-two")
        let original = Conversation(remoteThreadID: "old-provider-thread", title: "Original")
        try await database.save(conversation: original)
        try await database.save(entry: .init(kind: .userMessage, title: "You", text: "Earlier question"), conversationID: original.id)
        await model.select(original)
        model.selectedAIRecipients = [first.id.uuidString, second.id.uuidString]
        model.draft = "Review this question"
        XCTAssertTrue(model.canSend, "API chat should not need a folder or the primary provider connection")
        await model.sendAIMessage(confirmed: true)
        for _ in 0..<100 where model.turnStatus == .starting { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(model.canSend)
        let other = Conversation(title: "Other")
        try await database.save(conversation: other); await model.select(other)
        for _ in 0..<200 where model.isWorking { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(model.isWorking); XCTAssertTrue(model.timeline.isEmpty)
        let entries = try await database.timeline(conversationID: original.id)
        XCTAssertEqual(entries.filter { $0.kind == .userMessage }.count, 2)
        XCTAssertEqual(entries.filter { $0.kind == .agentMessage }.map(\.title), ["First · test-model"])
        XCTAssertEqual(entries.filter { $0.kind == .error }.count, 1)
        let restored = try await database.conversation(id: original.id)
        XCTAssertNil(restored?.remoteThreadID, "Next provider must receive the intervening review answers")
        let prompts = await probe.prompts
        XCTAssertTrue(prompts.allSatisfy { $0.contains("Earlier question") && $0.contains("Review this question") })
        await model.shutdown()
    }
    func testContextIsBoundedAndExcludesTools() {
        let history = (0..<100).map { TimelineEntry(kind: .agentMessage, title: "AI \($0)", text: String(repeating: "x", count: 4_000)) } + [.init(kind: .command, title: "Secret tool", text: "do-not-share")]
        let context = AIReviewRunner.context(history: history, prompt: "Question")
        XCTAssertLessThan(context.count, 51_000); XCTAssertFalse(context.contains("do-not-share")); XCTAssertTrue(context.contains("AI 99"))
    }

    func testOfficialRuntimeReviewRequiresAuthenticationAndUsesReadOnly() async throws {
        let provider = SettingsTestProvider()
        await provider.setCompleteImmediately(false)
        let task = Task { try await AIReviewRunner.runtime(provider, model: "fixture", prompt: "Review", folder: "/tmp", timeout: .seconds(2)) }
        for _ in 0..<100 {
            if await provider.sentPrompts.count == 1 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let runs = await provider.runs
        XCTAssertEqual(runs.first?.access, .readOnly)
        await provider.emit(.agentDelta(turnID: "fixture", text: "Runtime answer"))
        await provider.emit(.turnCompleted(turnID: "fixture", status: .completed, error: nil))
        let answer = try await task.value
        XCTAssertEqual(answer, "Runtime answer")
        let denied = SettingsTestProvider()
        await denied.setAuthenticated(false)
        do { _ = try await AIReviewRunner.runtime(denied, model: "fixture", prompt: "Review", folder: "/tmp", timeout: .seconds(2)); XCTFail("Accepted an unauthenticated runtime") }
        catch { }
        let sent = await denied.sentPrompts
        XCTAssertTrue(sent.isEmpty)
    }

    func testStopCancelsSharedChatAndKeepsSavedQuestion() async throws {
        let probe = ReviewProbe()
        let database = try DatabaseActor(url: directory.appendingPathComponent("cancel.sqlite3"))
        let model = WorkspaceViewModel(provider: SettingsTestProvider(), database: database, files: FileService(), git: GitService(), automaticallyRestore: false, preferences: defaults, credentials: MemoryCredentials(), chatGPTCredentials: MemoryChatGPTCredentials(), aiTokens: MemoryAITokens(), apiCompletion: { connection, _, _, _ in try await probe.complete(connection.name, delay: .seconds(30)) })
        let first = connection()
        try model.saveAIConnection(first, token: "fixture")
        model.selectedAIRecipients = [first.id.uuidString]; model.draft = "Question"
        await model.sendAIMessage(confirmed: true)
        for _ in 0..<100 where model.turnStatus == .starting { try await Task.sleep(for: .milliseconds(5)) }
        let chat = try XCTUnwrap(model.selectedConversation)
        await model.stop()
        for _ in 0..<200 where model.isWorking { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(model.isWorking); XCTAssertEqual(model.turnStatus, .interrupted)
        XCTAssertTrue(model.pendingAIAnswers.isEmpty)
        let entries = try await database.timeline(conversationID: chat.id)
        XCTAssertEqual(entries.filter { $0.kind == .userMessage }.count, 1)
        XCTAssertFalse(entries.contains { $0.kind == .agentMessage })
        await model.shutdown()
    }
}
