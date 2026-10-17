import Foundation
import XCTest
@testable import NativeAgent

private actor AgentRequestProbe {
    struct Request: Sendable { let model: String; let instructions: String; let input: String }
    var requests: [Request] = []
    func answer(_ connection: AIConnection, instructions: String, input: String) async throws -> String {
        requests.append(.init(model: connection.model, instructions: instructions, input: input))
        try await Task.sleep(for: .milliseconds(20))
        return "Specialist answer"
    }
}

@MainActor
final class AgentTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!
    private var directory: URL!
    private var database: DatabaseActor!
    private var model: WorkspaceViewModel!
    private var probe: AgentRequestProbe!
    private var connection: AIConnection!
    override func setUp() async throws {
        suite = "AgentTests.\(UUID())"; defaults = UserDefaults(suiteName: suite)!
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        database = try DatabaseActor(url: directory.appendingPathComponent("agents.sqlite3"))
        let probe = AgentRequestProbe(); self.probe = probe
        model = WorkspaceViewModel(provider: SettingsTestProvider(), database: database, files: FileService(), git: GitService(),
            automaticallyRestore: false, preferences: defaults, credentials: MemoryCredentials(), chatGPTCredentials: MemoryChatGPTCredentials(),
            aiTokens: MemoryAITokens(), apiCompletion: { connection, _, instructions, input in try await probe.answer(connection, instructions: instructions, input: input) })
        connection = AIConnection(name: "Fixture connection", baseURL: "https://fixture.invalid/v1", model: "connection-default")
        try model.saveAIConnection(connection, token: "fixture-secret")
        let chat = Conversation(title: "Agent conversation"); try await database.save(conversation: chat)
        await model.select(chat)
    }
    override func tearDown() async throws {
        await model.shutdown(); model = nil; database = nil
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
    private func specialist() -> AgentProfile {
        AgentProfile(name: "Database expert", handle: "database", summary: "Review database changes", connectionID: connection.id.uuidString,
                     model: "specialist-model", instructions: "Inspect transactions and concurrency.", reference: "Reference rule: preserve ordering.")
    }

    func testPresetsPersistOverridesAndImportsAreAtomicAndInactive() throws {
        let store = model.agents
        XCTAssertEqual(store.profiles.count, 6)
        XCTAssertEqual(Set(store.profiles.map(\.id)), Set(AgentProfile.builtIns.map(\.id)))
        var agent = specialist(); agent.delegation = .automatic
        try store.save(agent)
        let restored = AgentStore(defaults: defaults)
        XCTAssertEqual(restored.profiles.last, agent)
        var collision = agent; collision.id = UUID(); collision.handle = "DATABASE"
        XCTAssertThrowsError(try store.save(collision))
        var invalid = agent; invalid.handle = "two words"
        XCTAssertThrowsError(try store.save(invalid))
        let otherSuite = "AgentImportTests.\(UUID())", otherDefaults = UserDefaults(suiteName: otherSuite)!
        defer { otherDefaults.removePersistentDomain(forName: otherSuite) }
        let imported = AgentStore(defaults: otherDefaults)
        try imported.importData(JSONEncoder().encode([agent]))
        let value = try XCTUnwrap(imported.profiles.last)
        XCTAssertFalse(value.enabled); XCTAssertEqual(value.delegation, .manual); XCTAssertNotEqual(value.id, agent.id)
        let before = imported.profiles
        XCTAssertThrowsError(try imported.importData(JSONEncoder().encode([agent])))
        XCTAssertEqual(imported.profiles, before)
        try store.restoreBuiltIns(); XCTAssertTrue(store.profiles.contains(agent))
    }

    func testMentionsRespectCaseBoundariesUnicodeAndCode() {
        let agents = [specialist()]
        let text = "😀 @DATABASE, inspect this. mail@database.test \\@database @database_extra\n`@database` ``@database``\n```swift\n@database\n```\n~~~\n@database\n~~~\n@database"
        let matches = AgentMention.matches(in: text, profiles: agents)
        XCTAssertEqual(matches.count, 2)
        XCTAssertEqual((text as NSString).substring(with: matches[0].range), "@DATABASE")
        let stripped = AgentMention.removing(in: text, profiles: agents)
        XCTAssertTrue(stripped.hasPrefix("😀 , inspect"))
        XCTAssertTrue(stripped.contains("mail@database.test")); XCTAssertTrue(stripped.contains("``@database``"))
        XCTAssertTrue(stripped.contains("```swift\n@database\n```"))
        XCTAssertEqual(AgentMention.matches(in: "@database2", profiles: agents).count, 0)
    }

    func testAcceptedMentionsStayInDraftAndUnavailableAgentCannotFallThrough() async throws {
        var agent = specialist(); try model.agents.save(agent)
        model.draft = "Review this @dat"
        model.acceptAgent(agent)
        XCTAssertEqual(model.mentionedAgents.map(\.id), [agent.id]); XCTAssertTrue(model.draft.contains("@database "))
        XCTAssertEqual(model.requestPrompt, "Review this"); XCTAssertTrue(model.canSend)
        let original = try XCTUnwrap(model.selectedConversation)
        await model.saveDraft()
        let other = Conversation(title: "Another chat")
        try await database.save(conversation: other)
        await model.select(other)
        XCTAssertTrue(model.mentionedAgents.isEmpty)
        await model.select(original)
        XCTAssertEqual(model.mentionedAgents.map(\.id), [agent.id])
        agent.enabled = false; try model.agents.save(agent)
        XCTAssertNotNil(model.agentSelectionIssue); XCTAssertFalse(model.canSend)
        await model.send()
        let calls = await probe.requests
        XCTAssertTrue(calls.isEmpty)
        model.removeAgentMention(agent.id); XCTAssertFalse(model.hasAgentMentions)
    }

    func testAgentConfigurationControlsModelInstructionsAndContext() async throws {
        var agent = specialist(); agent.includeHistory = false; agent.includeAttachments = false
        try model.agents.save(agent)
        let job = try model.makeAgentJob(agent, task: "Inspect this transaction", history: [.init(kind: .userMessage, title: "You", text: "private-history")],
            attachments: "private-attachment", chatInstructions: "private-pins", projectPath: nil, conversationID: model.selectedConversation?.id)
        _ = try await job.complete()
        let captured = await probe.requests
        let request = try XCTUnwrap(captured.first)
        XCTAssertEqual(request.model, "specialist-model")
        XCTAssertTrue(request.instructions.contains(agent.instructions)); XCTAssertTrue(request.input.contains(agent.reference))
        for excluded in ["private-history", "private-attachment", "private-pins", "fixture-secret"] { XCTAssertFalse(request.input.contains(excluded)) }
        let records = try await database.usageRecords()
        XCTAssertEqual(records.first?.activity, "Agent: @database")
    }

    func testExplicitAgentReplyIsLabeledAndDoesNotMoveToAnotherChat() async throws {
        let agent = specialist(); try model.agents.save(agent)
        let original = try XCTUnwrap(model.selectedConversation)
        model.draft = "@database Check this schema"
        await model.sendAIMessage(confirmed: true)
        for _ in 0..<100 {
            if !(await probe.requests).isEmpty { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        await model.newConversation()
        for _ in 0..<100 where model.isWorking { try await Task.sleep(for: .milliseconds(10)) }
        await model.flushPendingPersistence()
        let entries = try await database.timeline(conversationID: original.id)
        XCTAssertTrue(entries.contains { $0.kind == .agentMessage && $0.title.contains("@database") && $0.text == "Specialist answer" })
        XCTAssertFalse(model.timeline.contains { $0.text == "Specialist answer" })
        let requests = await probe.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertTrue(requests[0].instructions.contains(agent.instructions))
    }

    func testDelegationModesBudgetAndConfigurationRecheck() async throws {
        var agent = specialist(); agent.delegation = .manual; try model.agents.save(agent)
        let id = try XCTUnwrap(model.selectedConversation?.id)
        func tools() -> [NativeTool] { model.agentTools(conversationID: id, history: [], attachments: "", chatInstructions: "", projectPath: directory.path) }
        XCTAssertTrue(tools().isEmpty)
        agent.delegation = .ask; try model.agents.save(agent)
        let args: JSONValue = .object(["agent": .string(agent.handle), "task": .string("Review the schema")])
        let askingTool = try XCTUnwrap(tools().first)
        let asking = try await askingTool.prepare(args)
        XCTAssertTrue(asking.requiresApproval); XCTAssertTrue(asking.review.contains("fixture.invalid"))
        agent.delegation = .automatic; try model.agents.save(agent)
        do { _ = try await askingTool.prepare(args); XCTFail("Stale configuration was accepted") } catch { }
        model.agents.callLimit = 2
        let automaticTool = try XCTUnwrap(tools().first)
        let automatic = try await automaticTool.prepare(args)
        XCTAssertFalse(automatic.requiresApproval)
        _ = try await automatic.execute(); _ = try await automatic.execute()
        do { _ = try await automatic.execute(); XCTFail("Delegation exceeded the per-turn limit") } catch { }
        let calls = await probe.requests; XCTAssertEqual(calls.count, 2)
        model.agents.automaticEnabled = false
        XCTAssertTrue(tools().isEmpty)
        do { _ = try await automaticTool.prepare(args); XCTFail("Disabled delegation ran") } catch { }
    }

    func testCanceledDelegationDoesNotSendAndUnknownAgentIsRejected() async throws {
        var agent = specialist(); agent.delegation = .automatic; try model.agents.save(agent)
        let tool = try XCTUnwrap(model.agentTools(conversationID: UUID(), history: [], attachments: "", chatInstructions: "", projectPath: directory.path).first)
        do { _ = try await tool.prepare(.object(["agent": .string("unknown"), "task": .string("Do work")])); XCTFail("Unknown agent accepted") } catch { }
        let prepared = try await tool.prepare(.object(["agent": .string(agent.handle), "task": .string("Do work")]))
        let task = Task { withUnsafeCurrentTask { $0?.cancel() }; return try await prepared.execute() }
        do { _ = try await task.value; XCTFail("Canceled request completed") } catch { }
        let calls = await probe.requests; XCTAssertTrue(calls.isEmpty)
    }
}
