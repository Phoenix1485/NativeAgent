import Foundation
import XCTest
@testable import NativeAgent

@MainActor
final class WorkspaceFeaturesTests: XCTestCase {
    private var root: URL!
    private var database: DatabaseActor!
    private var provider: SettingsTestProvider!
    private var model: WorkspaceViewModel!
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        suite = "NativeAgentFeatures.\(UUID())"; defaults = UserDefaults(suiteName: suite)!
        database = try DatabaseActor(url: root.appendingPathComponent("library.sqlite3"))
        provider = SettingsTestProvider()
        model = WorkspaceViewModel(provider: provider, database: database, files: FileService(), git: GitService(), automaticallyRestore: false, preferences: defaults, credentials: MemoryCredentials())
        await model.connect()
        await model.newConversation(); await model.addProject(root)
        defaults.set([try XCTUnwrap(model.selectedProject).id.uuidString], forKey: "trustedProjectIDs")
        try await wait { self.model.connectionStatus == .ready(account: "test@example.invalid") }
    }
    override func tearDown() async throws {
        await model.shutdown()
        model = nil; provider = nil; database = nil
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }
    private func wait(_ condition: () async -> Bool) async throws {
        for _ in 0..<400 { if await condition() { return }; try await Task.sleep(for: .milliseconds(5)) }
        XCTFail("Timed out waiting for feature state")
    }

    func testFileAttachmentsRequireOptInAndWorkspaceWriteBeforeAIToolsExist() async throws {
        let url = root.appendingPathComponent("attached.swift")
        try Data("let value = 1\n".utf8).write(to: url)
        await model.features.attachURLs([url, url])
        XCTAssertEqual(model.features.context.count, 1)
        let attachment = try XCTUnwrap(model.features.context.first)
        XCTAssertEqual(attachment.allowEdits, false)
        let owner = model.selectedConversation?.id
        var tools = try await model.features.nativeTools(access: .workspaceWrite, attachments: model.features.context, owner: owner)
        XCTAssertTrue(tools.isEmpty)
        await model.features.setFileEditable(attachment.id, enabled: true)
        tools = try await model.features.nativeTools(access: .readOnly, attachments: model.features.context, owner: owner)
        XCTAssertTrue(tools.isEmpty)
        tools = try await model.features.nativeTools(access: .workspaceWrite, attachments: model.features.context, owner: owner)
        XCTAssertEqual(tools.count, 1)
        let prepared = try await tools[0].prepare(.object(["old_text": .string("= 1"), "new_text": .string("= 2")]))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "let value = 1\n")
        XCTAssertTrue(prepared.review.contains("WITH:\n= 2"))
        _ = try await prepared.execute()
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "let value = 2\n")
        XCTAssertEqual(model.features.context.first?.text, "let value = 2\n")
        await model.features.validateContext()
        XCTAssertEqual(model.features.context.first?.stale, false)
        let saved = try await database.feature([ContextAttachment].self, kind: "context", id: XCTUnwrap(owner).uuidString)
        XCTAssertEqual(saved?.first?.text, "let value = 2\n")
    }

    func testExternalAttachmentAndUnsavedEditorBlockUnsafeActionsAndRelaunch() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("external.txt")
        try Data("selected externally".utf8).write(to: url)
        await model.features.attachURLs([url])
        let context = try await model.features.contextForSend()
        XCTAssertTrue(context.contains("selected externally"))
        try Data("changed outside app".utf8).write(to: url)
        do { _ = try await model.features.contextForSend(); XCTFail("Sent stale attachment") } catch {}
        let updater = AppUpdater(); updater.model = model
        model.features.editorHasChanges = true
        XCTAssertFalse(model.canSend); XCTAssertTrue(updater.installationMustWait)
        model.features.editorHasChanges = false
        model.features.fileSaveInProgress = true
        XCTAssertTrue(updater.installationMustWait)
        model.features.fileSaveInProgress = false
    }

    func testBranchPreservesOriginalAndHasIndependentDraftAndSession() async throws {
        let parent = try XCTUnwrap(model.selectedConversation)
        let earlier = TimelineEntry(kind: .agentMessage, title: "Agent", text: "Earlier answer")
        let prompt = TimelineEntry(kind: .userMessage, title: "You", text: "Original approach")
        try await database.save(entry: earlier, conversationID: parent.id)
        try await database.save(entry: prompt, conversationID: parent.id)
        try await database.saveDraft("Original draft", conversationID: parent.id)
        let (branch, context) = try await database.branch(from: parent, messageID: prompt.id)
        XCTAssertNotEqual(branch.id, parent.id); XCTAssertNil(branch.remoteThreadID)
        XCTAssertTrue(context.first?.text.contains("Earlier answer") == true)
        XCTAssertFalse(context.first?.text.contains("Original approach") == true)
        let childDraft = try await database.draft(conversationID: branch.id)
        XCTAssertEqual(childDraft, "Original approach")
        try await database.saveDraft("Different approach", conversationID: branch.id)
        let originalDraft = try await database.draft(conversationID: parent.id)
        let original = try await database.timeline(conversationID: parent.id)
        let links = try await database.branchLinks(for: parent.id)
        XCTAssertEqual(originalDraft, "Original draft"); XCTAssertEqual(original.map(\.id), [earlier.id, prompt.id])
        XCTAssertEqual(links.first?.id, branch.id)
    }

    func testQueueRequiresExplicitStartAndSerializesThroughApprovalAndCompletion() async throws {
        await provider.setCompleteImmediately(false)
        model.draft = "First"; await model.features.enqueueDraft()
        model.draft = "Second"; await model.features.enqueueDraft()
        let initial = await provider.sentPrompts; XCTAssertTrue(initial.isEmpty)
        XCTAssertTrue(model.features.queuePaused)
        await model.features.startQueue()
        try await wait { await self.provider.sentPrompts.count == 1 }
        await provider.emit(.approval(.init(id: "approve", turnID: nil, method: "fixture", title: "Run?", command: nil, workingDirectory: nil, choices: [.accept, .decline])))
        try await wait { self.model.features.queue.first?.state == .awaitingApproval }
        let blocked = await provider.sentPrompts; XCTAssertEqual(blocked.count, 1)
        await provider.emit(.approvalResolved("approve"))
        await provider.emit(.turnCompleted(turnID: nil, status: .completed, error: nil))
        try await wait { await self.provider.sentPrompts.count == 2 }
        let threads = await provider.sentThreads; XCTAssertEqual(Set(threads).count, 2)
        await provider.emit(.turnCompleted(turnID: nil, status: .completed, error: nil))
        try await wait { self.model.features.queue.allSatisfy { $0.state == .completed } }
    }

    func testQueueCapturesOverridesAndPausesAfterFailure() async throws {
        model.settings.instructions = "Reviewed override"; model.settings.access = .readOnly
        model.selectedModelID = "deep"; model.selectedReasoning = "high"
        model.draft = "Fail safely"; await model.features.enqueueDraft()
        model.draft = "Do not start"; await model.features.enqueueDraft()
        XCTAssertEqual(model.features.queue.first?.profile.instructions, "Reviewed override")
        XCTAssertEqual(model.features.queue.first?.profile.reasoning, "high")
        await provider.setFailTurn(true)
        await model.features.startQueue()
        try await wait { self.model.features.queue.first?.state == .failed }
        XCTAssertTrue(model.features.queuePaused)
        XCTAssertEqual(model.features.queue.last?.state, .queued)
        await model.features.startQueue()
        XCTAssertTrue(model.features.queuePaused)
        let runs = await provider.runs; XCTAssertEqual(runs.count, 1)
    }

    func testQueueBlocksForQuestionsAndPausesOnUnknownExecution() async throws {
        await provider.setCompleteImmediately(false)
        model.draft = "Ask first"; await model.features.enqueueDraft()
        model.draft = "Wait"; await model.features.enqueueDraft()
        await model.features.startQueue()
        let question = ProviderQuestionRequest(id: "q-request", questions: [.init(id: "q", header: "Choice", text: "Which approach?", secret: false, allowsOther: true, options: [])])
        await provider.emit(.question(question))
        try await wait { self.model.features.queue.first?.state == .awaitingInput }
        XCTAssertEqual(model.turnStatus, .awaitingUserInput)
        let blocked = await provider.sentPrompts; XCTAssertEqual(blocked.count, 1)
        await provider.emit(.connectionFailed("Lost provider"))
        try await wait { self.model.features.queue.first?.state == .needsReview }
        XCTAssertTrue(model.features.queuePaused); XCTAssertEqual(model.features.queue.last?.state, .queued)
        let sent = await provider.sentPrompts; XCTAssertEqual(sent.count, 1)
    }

    func testQueueReorderEditCancelAndPauseNeverStartWork() async throws {
        model.draft = "A"; await model.features.enqueueDraft()
        model.draft = "B"; await model.features.enqueueDraft()
        var item = try XCTUnwrap(model.features.queue.last)
        item.prompt = "B edited"; await model.features.editQueue(item)
        await model.features.moveQueue(item, by: -1)
        XCTAssertEqual(model.features.queue.sorted { $0.position < $1.position }.first?.prompt, "B edited")
        await model.features.cancelQueue(item)
        XCTAssertEqual(model.features.queue.first { $0.id == item.id }?.state, .canceled)
        await model.features.removeQueue(item)
        model.features.pauseQueue()
        let prompts = await provider.sentPrompts; XCTAssertTrue(prompts.isEmpty)
    }

    func testCancelDuringPreparationNeverSendsProviderTurn() async throws {
        await provider.setThreadDelay(.milliseconds(80))
        model.draft = "Cancel before execution"
        let sending = Task { await model.send() }
        try await wait { await self.provider.threadCount == 1 }
        await model.stop(); await sending.value
        let sent = await provider.sentPrompts
        XCTAssertTrue(sent.isEmpty); XCTAssertEqual(model.turnStatus, .interrupted)
        let reports = try await database.features(TaskReport.self, kind: "report")
        XCTAssertEqual(reports.first?.state, .canceled)
    }

    func testContextTracksStalenessAndRejectsEscapes() async throws {
        let url = root.appendingPathComponent("source.swift")
        try Data("let answer = 42\n".utf8).write(to: url)
        let service = model.features.fileService
        let copy = try await service.attach(root: root.path, path: "source.swift", referenceOnly: false, selectedText: "answer", lines: 1...1)
        let reference = try await service.attach(root: root.path, path: "source.swift", referenceOnly: true)
        XCTAssertEqual(copy.startLine, 1); XCTAssertEqual(copy.text, "answer")
        XCTAssertFalse(reference.text.contains("42"))
        await model.features.addContext(copy)
        try Data("let answer = 43\n".utf8).write(to: url)
        do { _ = try await model.features.contextForSend(); XCTFail("Stale content sent") } catch { }
        do { _ = try await service.read(root: root.path, path: "../escape"); XCTFail("Escaped root") } catch { }
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link.swift"), withDestinationURL: url)
        do { _ = try await service.read(root: root.path, path: "link.swift"); XCTFail("Followed symlink") } catch { }
        model.draft = "Keep this unsent draft"; await model.send()
        XCTAssertEqual(model.draft, "Keep this unsent draft")
        let sent = await provider.sentPrompts; XCTAssertTrue(sent.isEmpty)
        await model.features.removeContext(copy.id)
        let value = try await model.features.contextForSend(); XCTAssertEqual(value, "")
    }

    func testRollbackPreservesBaselineUserEditsAndRefusesLaterChanges() async throws {
        let service = TaskFileService(), url = root.appendingPathComponent("edited.swift")
        let before = Data("pre-existing user edits\n".utf8), after = Data("agent modification\n".utf8)
        try before.write(to: url)
        let baseline = try await service.capture(root: root.path)
        XCTAssertTrue(baseline.files.contains { $0.path == "edited.swift" }, "Captured paths: \(baseline.files.map(\.path)) · root \(root.path)")
        let matches = try await service.search(root: root.path, query: "pre-existing user edits")
        XCTAssertEqual(matches.first?.recordID, "edited.swift")
        try after.write(to: url)
        let changes = await service.finish(baseline, root: root.path)
        let file = try XCTUnwrap(changes.files.first { $0.path == "edited.swift" })
        XCTAssertEqual(file.before, before); XCTAssertEqual(file.after, after)
        try Data("later user edit\n".utf8).write(to: url)
        do { try await service.rollback(file, root: root.path); XCTFail("Overwrote overlapping user edit") } catch { }
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "later user edit\n")
        try after.write(to: url); try await service.rollback(file, root: root.path)
        XCTAssertEqual(try Data(contentsOf: url), before)
        XCTAssertTrue(file.diff.contains("--- before/edited.swift"))
    }

    func testRestorationKeepsDraftContextReadingPositionAndNeverResendsInterruptedTask() async throws {
        let chat = try XCTUnwrap(model.selectedConversation), project = try XCTUnwrap(model.selectedProject)
        let prompt = TimelineEntry(kind: .userMessage, title: "You", text: "Read here")
        try await database.save(entry: prompt, conversationID: chat.id)
        model.draft = "Unsaved composer text"
        await model.features.addContext(.init(kind: .excerpt, title: "Important", text: "Selected context"))
        model.features.session.readingPosition = prompt.id; model.features.session.inspector = true
        model.features.session.inspectorTab = "Changes"
        await model.features.saveSession()
        let task = QueuedWork(position: 0, projectID: project.id, projectPath: project.canonicalPath, provider: .codex, authentication: .account, executable: "", providerConfiguration: "", modelID: "fast", profile: try XCTUnwrap(model.features.defaultProfile()), prompt: "Uncertain task", context: [], state: .running)
        try await database.saveFeature(task, kind: "queue", id: task.id.uuidString, projectID: project.id)
        let interruptedReport = TaskReport(conversationID: chat.id, projectID: project.id, projectPath: project.canonicalPath, provider: .codex, prompt: "Uncertain report")
        try await database.saveTaskReport(interruptedReport)
        await model.shutdown()
        let otherProvider = SettingsTestProvider()
        let restored = WorkspaceViewModel(provider: otherProvider, database: database, files: FileService(), git: GitService(), automaticallyRestore: false, preferences: defaults, credentials: MemoryCredentials())
        await restored.restore()
        XCTAssertEqual(restored.selectedConversation?.id, chat.id)
        XCTAssertEqual(restored.draft, "Unsaved composer text")
        XCTAssertEqual(restored.features.context.first?.text, "Selected context")
        XCTAssertEqual(restored.features.session.readingPosition, prompt.id)
        XCTAssertEqual(restored.features.session.inspectorTab, "Changes")
        XCTAssertEqual(restored.features.queue.first?.state, .needsReview)
        XCTAssertTrue(restored.features.queuePaused)
        let report = try await database.feature(TaskReport.self, kind: "report", id: interruptedReport.id.uuidString)
        XCTAssertEqual(report?.state, .needsReview)
        let unfinished = try await database.unfinishedReports(); XCTAssertTrue(unfinished.isEmpty)
        let sent = await otherProvider.sentPrompts, connections = await otherProvider.connectCount
        XCTAssertTrue(sent.isEmpty); XCTAssertEqual(connections, 0)
        await restored.shutdown()
    }

    func testProfilesTemplatesReportsAndSearchSurviveDatabaseReopen() async throws {
        let project = try XCTUnwrap(model.selectedProject), chat = try XCTUnwrap(model.selectedConversation)
        var profile = try XCTUnwrap(model.features.defaultProfile()); profile.instructions = "Find needle"; profile.testCommand = "swift test"
        await model.features.saveProfile(profile)
        let template = PromptTemplate(projectID: project.id, title: "Needle template", folder: "Review", body: "Review {{file_path}} for {{outcome}}")
        await model.features.saveTemplate(template)
        XCTAssertEqual(template.render(["file_path": "main.swift", "outcome": "bugs"]), "Review main.swift for bugs")
        let report = TaskReport(conversationID: chat.id, projectID: project.id, projectPath: project.canonicalPath, provider: .codex, prompt: "Needle task", state: .completed, summary: "Tests passed", testCommand: "swift test")
        try await database.saveTaskReport(report)
        XCTAssertTrue(report.markdown.contains("No verified execution result"))
        let reopened = try DatabaseActor(url: root.appendingPathComponent("library.sqlite3"))
        let saved = try await reopened.feature(ProjectProfile.self, kind: "profile", id: project.id.uuidString)
        XCTAssertEqual(saved, profile)
        let hits = try await reopened.globalSearch("needle")
        XCTAssertTrue(hits.contains { $0.kind == "report" }); XCTAssertTrue(hits.contains { $0.kind == "template" })
        let summaries = try await reopened.reportSummaries(projectID: project.id)
        XCTAssertEqual(summaries.first?.id, report.id); XCTAssertTrue(summaries.first?.summary.isEmpty == true)
        let runs = await provider.runs; XCTAssertTrue(runs.isEmpty)
    }

    func testProjectSelectionAppliesProfileBeforeImplicitConversationSend() async throws {
        let project = try XCTUnwrap(model.selectedProject)
        var profile = try XCTUnwrap(model.features.defaultProfile())
        profile.modelID = "deep"; profile.reasoning = "high"; profile.instructions = "Use project conventions"
        profile.contextNotes = "Prefer existing components"; profile.buildCommand = "Never execute on save"
        await model.features.saveProfile(profile)
        await model.select(project)
        XCTAssertNil(model.selectedConversation)
        XCTAssertEqual(model.selectedModelID, "deep")
        XCTAssertEqual(model.settings.instructions, "Use project conventions")
        XCTAssertEqual(model.features.context.first?.text, "Prefer existing components")
        model.draft = "Apply the profile"; await model.send()
        try await wait { self.model.features.activeTask == nil }
        let sent = await provider.sentPrompts, runs = await provider.runs
        XCTAssertTrue(sent.first?.contains("Prefer existing components") == true)
        XCTAssertEqual(runs.first?.instructions, "Use project conventions")
        let chat = try XCTUnwrap(model.selectedConversation)
        let saved = try await database.feature([ContextAttachment].self, kind: "context", id: chat.id.uuidString)
        XCTAssertEqual(saved?.first?.text, "Prefer existing components")
    }

    func testGlobalSearchPaginatesLongHistoryAndCancelsStaleQuery() async throws {
        let chat = try XCTUnwrap(model.selectedConversation)
        for index in 0..<160 { try await database.save(entry: .init(kind: .userMessage, title: "User", text: "Unique search fixture \(index)"), conversationID: chat.id) }
        let first = try await database.globalSearch("Unique search fixture"), next = try await database.globalSearch("Unique search fixture", offset: 40)
        XCTAssertEqual(first.count, 40); XCTAssertEqual(next.count, 40)
        XCTAssertTrue(Set(first.map(\.id)).isDisjoint(with: next.map(\.id)))
        model.features.search("Unique search fixture"); model.features.search("No matching result")
        try await wait { !self.model.features.searchLoading }
        XCTAssertTrue(model.features.searchResults.isEmpty)
        XCTAssertTrue(WorkspaceCommand.context.matches("cntxt")); XCTAssertFalse(WorkspaceCommand.context.matches("zzzz"))
    }
}
