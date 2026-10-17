import Foundation
import XCTest
@testable import NativeAgent

@MainActor
final class ConversationLifecycleTests: XCTestCase {
    private var directory: URL!
    private var suite: String!
    private var defaults: UserDefaults!
    private var database: DatabaseActor!
    private var provider: SettingsTestProvider!
    private var model: WorkspaceViewModel!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        suite = "NativeAgentLifecycleTests.\(UUID())"
        defaults = UserDefaults(suiteName: suite)!
        database = try DatabaseActor(url: directory.appendingPathComponent("test.sqlite3"))
        provider = SettingsTestProvider()
        model = WorkspaceViewModel(provider: provider, database: database, files: FileService(), git: GitService(), automaticallyRestore: false, preferences: defaults, credentials: MemoryCredentials())
    }
    override func tearDown() async throws {
        model = nil; provider = nil; database = nil
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
    private func readyChat() async throws {
        await model.connect()
        for _ in 0..<50 { await Task.yield() }
        await model.newConversation(); await model.addProject(directory)
        let project = try XCTUnwrap(model.selectedProject)
        defaults.set([project.id.uuidString], forKey: "trustedProjectIDs")
    }
    private func settle() async throws { try await Task.sleep(for: .milliseconds(20)) }
    private func waitForCompletedPrompts(_ count: Int) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline {
            let prompts = await provider.sentPrompts
            // A completed provider turn can still be saving its report/checkpoint.
            // Wait for the same task-finalization gates used by canSend.
            if prompts.count >= count && !model.isWorking && model.features.activeTask == nil && !model.features.finishingTask { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("The fixture turn did not complete before the deadline.")
    }

    func testExistingChatReadsLatestProjectMemoryAndPinnedInstructionsEverySend() async throws {
        try await readyChat()
        let project = try XCTUnwrap(model.selectedProject), chat = try XCTUnwrap(model.selectedConversation)
        try await database.saveProjectMemory(.init(frameworks: "First framework"), projectID: project.id)
        try await database.saveFeature("Pinned exact requirement", kind: "chat-pins", id: chat.id.uuidString, conversationID: chat.id)
        model.draft = "First request"; await model.send(); try await waitForCompletedPrompts(1)
        var prompts = await provider.sentPrompts
        XCTAssertTrue(prompts.last?.contains("First framework") == true)
        XCTAssertTrue(prompts.last?.contains("Pinned exact requirement") == true)
        try await database.saveProjectMemory(.init(frameworks: "Updated framework"), projectID: project.id)
        model.draft = "Next request"; await model.send(); try await waitForCompletedPrompts(2)
        prompts = await provider.sentPrompts
        XCTAssertTrue(prompts.last?.contains("Updated framework") == true)
        XCTAssertFalse(prompts.last?.contains("First framework") == true)
        XCTAssertEqual(model.selectedConversation?.id, chat.id)
    }

    func testUnreadAndWorkingIndicatorFollowOriginalChatWhenSelectionChanges() async throws {
        try await readyChat()
        await provider.setCompleteImmediately(false)
        let chat = try XCTUnwrap(model.selectedConversation)
        model.draft = "Work in this chat"; await model.send(); try await settle()
        XCTAssertTrue(model.chatIsWorking(chat.id))
        await model.newConversation()
        let other = try XCTUnwrap(model.selectedConversation)
        XCTAssertNotEqual(chat.id, other.id)
        XCTAssertFalse(model.chatIsWorking(other.id))
        await provider.emit(.turnCompleted(turnID: nil, status: .completed, error: nil)); try await settle()
        XCTAssertFalse(model.chatIsWorking(chat.id))
        XCTAssertTrue(model.chatAttention[chat.id]?.unread == true)
        XCTAssertNil(model.chatAttention[other.id])
        await model.select(chat)
        XCTAssertFalse(model.chatAttention[chat.id]?.unread == true)
    }

    func testDetailsScopeApprovalsAndKeepToolIdentityAcrossUpdates() async throws {
        try await readyChat()
        await provider.setCompleteImmediately(false)
        model.draft = "Check the project"
        await model.send(); try await settle()
        let chat = try XCTUnwrap(model.selectedConversation)
        let running = ConversationFact(key: "tool/1", category: .activity, title: "Run checks", text: "In progress", state: "inProgress")
        await provider.emit(.conversationFact(turnID: "details-turn", fact: running))
        await provider.emit(.approval(.init(id: "permission", turnID: "details-turn", method: "fixture", title: "Allow checks?", command: "swift test", workingDirectory: nil, choices: [.accept, .decline])))
        try await settle()
        XCTAssertEqual(model.conversationApprovals.count, 1)
        let original = try XCTUnwrap(model.conversationDetails.first { ConversationFact.decode($0.detail)?.key == "tool/1" })
        await provider.emit(.conversationFact(turnID: "details-turn", fact: .init(key: running.key, category: .activity, title: running.title, text: "Completed", state: "completed")))
        try await settle()
        let updated = model.conversationDetails.filter { ConversationFact.decode($0.detail)?.key == "tool/1" }
        XCTAssertEqual(updated.count, 1)
        XCTAssertEqual(updated.first?.id, original.id)
        XCTAssertEqual(updated.first?.text, "Completed")
        await model.newConversation()
        XCTAssertTrue(model.conversationApprovals.isEmpty)
        XCTAssertTrue(model.conversationDetails.isEmpty)
        XCTAssertEqual(model.conversationStatus, "No recorded task status")
        await model.select(chat); await model.refreshConversationSummaries()
        XCTAssertEqual(model.conversationApprovals.count, 1)
        await provider.emit(.turnCompleted(turnID: "details-turn", status: .completed, error: nil))
        try await settle()
        XCTAssertTrue(model.conversationApprovals.isEmpty)
        XCTAssertEqual(model.conversationStatus, "Last reported: Completed")
    }

    func testMinimapSeeksOutsideLoadedWindowWithoutChangingPromptIDs() async throws {
        await model.newConversation()
        let chat = try XCTUnwrap(model.selectedConversation)
        var prompts: [TimelineEntry] = []
        for number in 0..<150 {
            let prompt = TimelineEntry(kind: .userMessage, title: "You", text: "Question \(number)")
            prompts.append(prompt)
            try await database.save(entry: prompt, conversationID: chat.id)
            try await database.save(entry: .init(kind: .agentMessage, title: "Agent", text: "Response"), conversationID: chat.id)
        }
        await model.select(chat); await model.refreshConversationSummaries()
        XCTAssertEqual(model.conversationPrompts.map(\.id), prompts.map(\.id))
        let target = prompts[50].id
        XCTAssertFalse(model.timeline.contains { $0.id == target })
        await model.navigateToMessage(target)
        XCTAssertEqual(model.navigationTarget, target)
        XCTAssertTrue(model.timeline.contains { $0.id == target })
        XCTAssertLessThanOrEqual(model.timeline.count, 60)
        XCTAssertTrue(model.hasNewerMessages)
        await model.loadOlderMessages()
        XCTAssertTrue(model.timeline.contains { $0.id == target })
        XCTAssertEqual(model.conversationPrompts.map(\.id), prompts.map(\.id))
        await model.newConversation()
        XCTAssertNil(model.navigationTarget)
        XCTAssertTrue(model.conversationPrompts.isEmpty)
    }

    func testRapidNewChatRequestsReuseOneBlankChatAndPreservePreviousDraft() async throws {
        await model.newConversation()
        let original = try XCTUnwrap(model.selectedConversation)
        model.draft = "Keep my draft"
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<30 { group.addTask { await self.model.newConversation() } }
        }
        let chats = try await database.conversations()
        XCTAssertEqual(chats.count, 2)
        XCTAssertEqual(model.conversations.count, 2)
        XCTAssertNotEqual(model.selectedConversation?.id, original.id)
        XCTAssertEqual(model.draft, "")
        await model.select(original)
        XCTAssertEqual(model.draft, "Keep my draft")
        XCTAssertTrue(model.rootFiles.isEmpty, "Chat navigation must not eagerly scan workspace files")
    }

    func testNewChatDoesNotReopenAnUnsentDraft() async throws {
        await model.newConversation()
        let first = try XCTUnwrap(model.selectedConversation)
        try await database.save(entry: .init(kind: .userMessage, title: "You", text: "A sent message"), conversationID: first.id)
        await model.newConversation()
        let second = try XCTUnwrap(model.selectedConversation)
        XCTAssertNotEqual(first.id, second.id)
        model.draft = "Unsent work"
        await model.select(first)
        await model.newConversation()
        XCTAssertNotEqual(model.selectedConversation?.id, second.id)
        XCTAssertNotEqual(model.selectedConversation?.id, first.id)
        XCTAssertEqual(model.draft, "")
        let chats = try await database.conversations()
        XCTAssertEqual(chats.count, 3)
        await model.select(second)
        XCTAssertEqual(model.draft, "Unsent work")
    }

    func testStandaloneNewChatDoesNotReuseAnUnloadedGroupDraftAfterRestart() async throws {
        let parent = ChatGroup(name: "Parent")
        try await database.save(group: parent)
        let group = ChatGroup(parentID: parent.id, name: "Saved group")
        try await database.save(group: group)
        let saved = Conversation(groupID: group.id)
        try await database.save(conversation: saved)
        try await database.saveDraft("Saved draft", conversationID: saved.id)
        model.groups = [parent, group]
        XCTAssertTrue(model.conversations.isEmpty)
        await model.newConversation()
        XCTAssertNotEqual(model.selectedConversation?.id, saved.id)
        XCTAssertNil(model.selectedConversation?.groupID)
        XCTAssertEqual(model.draft, "")
        let chats = try await database.conversations()
        XCTAssertEqual(chats.count, 2)
        XCTAssertEqual(chats.first { $0.id == saved.id }?.groupID, group.id)
        await model.select(saved)
        XCTAssertEqual(model.draft, "Saved draft")
    }

    func testNewChatRespectsRequestedGroupAndReusesOnlyThatGroupsBlankChat() async throws {
        let group = ChatGroup(name: "Project group")
        try await database.save(group: group); model.groups = [group]
        await model.newConversation(in: group.id)
        let grouped = try XCTUnwrap(model.selectedConversation)
        await model.newConversation(fromUserAction: true)
        let standalone = try XCTUnwrap(model.selectedConversation)
        XCTAssertNotEqual(standalone.id, grouped.id)
        XCTAssertNil(standalone.groupID)
        XCTAssertNil(model.selectedGroupID)
        await model.newConversation(in: group.id, fromUserAction: true)
        XCTAssertEqual(model.selectedConversation?.id, grouped.id)
        XCTAssertTrue(model.expandedGroupIDs.contains(group.id))
        await model.newConversation(fromUserAction: true)
        XCTAssertEqual(model.selectedConversation?.id, standalone.id)
    }

    func testNewChatPreservesPreparedContextAndWorkingFolder() async throws {
        await model.newConversation(); await model.addProject(directory)
        let original = try XCTUnwrap(model.selectedConversation)
        let item = ContextAttachment(kind: .excerpt, title: "Review this", text: "Keep this context")
        await model.features.addContext(item)
        await model.newConversation(fromUserAction: true)
        XCTAssertNotEqual(model.selectedConversation?.id, original.id)
        XCTAssertEqual(model.selectedConversation?.projectID, original.projectID)
        XCTAssertTrue(model.features.context.isEmpty)
        await model.select(original)
        XCTAssertEqual(model.features.context, [item])
    }

    func testNewChatCommandReturnsToNormalChatAndRequestsFocusEvenWhenReusingBlankChat() async throws {
        await model.newConversation()
        let original = try XCTUnwrap(model.selectedConversation)
        model.selectedAIRecipients = ["previous-specialist"]
        model.features.panel = .github; model.features.paletteVisible = true
        let request = model.newChatFocusRequest
        // The menu's Command-N action uses the same dispatcher.
        model.features.execute(.newChat)
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while model.newChatFocusRequest == request && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNotEqual(model.newChatFocusRequest, request)
        XCTAssertEqual(model.selectedConversation?.id, original.id)
        XCTAssertFalse(model.usesRecipientChat)
        XCTAssertNil(model.features.panel)
        XCTAssertFalse(model.features.paletteVisible)
        model.selectedAIRecipients = ["chosen-for-attachment"]
        await model.newConversation()
        XCTAssertEqual(model.selectedAIRecipients, ["chosen-for-attachment"], "Implicit chat creation must keep an explicitly chosen recipient")
    }

    func testArchivedUnsentChatDoesNotBlockCreatingNewChat() async throws {
        await model.newConversation()
        let original = try XCTUnwrap(model.selectedConversation)
        model.draft = "Archived draft"
        await model.archive(original)
        await model.newConversation()
        XCTAssertNotEqual(model.selectedConversation?.id, original.id)
        XCTAssertEqual(model.draft, "")
        let savedDraft = try await database.draft(conversationID: original.id)
        XCTAssertEqual(savedDraft, "Archived draft")
    }

    func testSameChatSwitchesProvidersBothDirectionsWithContextAndModels() async throws {
        try await readyChat()
        let id = try XCTUnwrap(model.selectedConversation?.id)
        model.draft = "Build a calendar"
        await model.send(); try await settle()
        await provider.emit(.agentMessage(turnID: nil, text: "The calendar uses a week view."))
        try await settle()
        model.settings.mergeCatalog([.init(id: "deep", displayName: "Deep")], provider: .claude)
        await model.chooseModel("deep", provider: .claude)
        try await settle()
        model.draft = "Add drag and drop"
        XCTAssertTrue(model.canSend)
        await model.send(); try await settle()
        XCTAssertEqual(model.selectedConversation?.id, id)
        XCTAssertEqual(model.selectedConversation?.providerID, .claude)
        model.settings.mergeCatalog([.init(id: "fast", displayName: "Fast")], provider: .grok)
        await model.chooseModel("fast", provider: .grok); try await settle()
        model.draft = "Use keyboard shortcuts"
        await model.send(); try await settle()
        XCTAssertEqual(model.selectedConversation?.providerID, .grok)
        await model.chooseModel("fast", provider: .codex); try await settle()
        model.draft = "Now add tests"
        await model.send(); try await settle()
        let prompts = await provider.sentPrompts, threads = await provider.sentThreads, models = await provider.sentModels
        XCTAssertEqual(prompts.count, 4)
        XCTAssertEqual(prompts[0], "Build a calendar")
        XCTAssertTrue(prompts[1].contains("Build a calendar"))
        XCTAssertTrue(prompts[1].contains("The calendar uses a week view."))
        XCTAssertTrue(prompts[2].contains("Add drag and drop"))
        XCTAssertTrue(prompts[3].contains("Use keyboard shortcuts"))
        XCTAssertEqual(Set(threads).count, 4, "Never send a provider another provider’s remote session ID")
        XCTAssertEqual(models, ["fast", "deep", "fast", "fast"])
        XCTAssertEqual(model.selectedConversation?.id, id)
        let saved = try await database.conversations()
        XCTAssertEqual(saved.count, 1); XCTAssertEqual(saved.first?.providerID, .codex)
        XCTAssertTrue(model.timeline.contains { $0.text == "Build a calendar" })
        XCTAssertTrue(model.timeline.contains { $0.text == "Add drag and drop" })
    }

    func testSameProviderModelSwitchReusesSessionWithoutDuplicateHandoff() async throws {
        try await readyChat()
        model.draft = "First"
        await model.send(); try await settle()
        await model.chooseModel("deep", provider: .codex)
        model.draft = "Second"
        await model.send(); try await settle()
        let prompts = await provider.sentPrompts, threads = await provider.sentThreads, models = await provider.sentModels
        XCTAssertEqual(prompts, ["First", "Second"])
        XCTAssertEqual(Set(threads).count, 1); XCTAssertEqual(models, ["fast", "deep"])
    }

    func testDuplicateSendAndActiveChatArchiveArePrevented() async throws {
        try await readyChat()
        await provider.setCompleteImmediately(false)
        model.draft = "Only once"
        async let first: Void = model.send()
        async let second: Void = model.send()
        _ = await (first, second)
        let prompts = await provider.sentPrompts
        XCTAssertEqual(prompts, ["Only once"])
        let chat = try XCTUnwrap(model.selectedConversation)
        await model.archive(chat)
        XCTAssertNotNil(model.errorMessage)
        let active = try await database.conversations()
        XCTAssertEqual(active.count, 1)
        await provider.emit(.turnCompleted(turnID: nil, status: .completed, error: nil)); try await settle()
        model.errorMessage = nil
        model.draft = "Recover this too"
        await model.archive(chat)
        XCTAssertNil(model.selectedConversation)
        XCTAssertTrue(model.conversations.isEmpty)
        await model.loadArchive()
        let archived = try XCTUnwrap(model.archivedConversations.first)
        await model.restoreArchived(archived)
        let restored = try XCTUnwrap(model.conversations.first)
        await model.select(restored)
        XCTAssertEqual(model.draft, "Recover this too")
    }

    func testFailedProviderHandoffDoesNotLoseOriginalSession() async throws {
        try await readyChat()
        model.draft = "Original"
        await model.send(); try await settle()
        let original = try XCTUnwrap(model.selectedConversation)
        model.settings.mergeCatalog([.init(id: "deep", displayName: "Deep")], provider: .claude)
        await model.chooseModel("deep", provider: .claude); try await settle()
        await provider.setFailTurn(true)
        model.draft = "Continue"
        await model.send()
        XCTAssertEqual(model.turnStatus, .failed)
        XCTAssertEqual(model.selectedConversation?.remoteThreadID, original.remoteThreadID)
        XCTAssertEqual(model.selectedConversation?.providerID, original.providerID)
    }

    func testLongHistoryUsesBoundedWindowAndCanReturnToLatest() async throws {
        await model.newConversation()
        let chat = try XCTUnwrap(model.selectedConversation)
        for index in 1...300 {
            try await database.save(entry: .init(kind: .userMessage, title: "You", text: "Message \(index)"), conversationID: chat.id)
        }
        await model.select(chat)
        XCTAssertEqual(model.timeline.count, 40); XCTAssertEqual(model.timeline.last?.text, "Message 300")
        for _ in 0..<6 { await model.loadOlderMessages() }
        XCTAssertEqual(model.timeline.count, 200); XCTAssertTrue(model.hasNewerMessages)
        XCTAssertEqual(model.timeline.first?.text, "Message 21")
        await model.loadLatestMessages()
        XCTAssertEqual(model.timeline.count, 40); XCTAssertFalse(model.hasNewerMessages)
        XCTAssertEqual(model.timeline.last?.text, "Message 300")
        model.draft = "Unsent"
        await model.loadOlderMessages()
        XCTAssertEqual(model.draft, "Unsent")
    }

    func testHistoryPagesForwardAfterEvictionAndStaysBoundedInBothDirections() async throws {
        await model.newConversation()
        let chat = try XCTUnwrap(model.selectedConversation)
        for index in 1...360 {
            try await database.save(entry: .init(kind: .userMessage, title: "You", text: "Message \(index)"), conversationID: chat.id)
        }
        await model.select(chat)
        XCTAssertEqual(model.timeline.first?.receivedOrder, 321)
        for _ in 0..<7 { await model.loadOlderMessages() }
        XCTAssertEqual(model.timeline.count, 200)
        XCTAssertEqual(model.timeline.first?.receivedOrder, 41)
        XCTAssertEqual(model.timeline.last?.receivedOrder, 240)
        model.draft = "Keep this draft"
        for _ in 0..<3 {
            let previousLast = try XCTUnwrap(model.timeline.last?.receivedOrder)
            await model.loadNewerMessages()
            XCTAssertLessThanOrEqual(model.timeline.count, 200)
            XCTAssertEqual(model.timeline.last?.receivedOrder, previousLast + 40)
            XCTAssertEqual(Set(model.timeline.map(\.id)).count, model.timeline.count)
            XCTAssertEqual(model.timeline.compactMap(\.receivedOrder), model.timeline.compactMap(\.receivedOrder).sorted())
        }
        XCTAssertFalse(model.hasNewerMessages)
        XCTAssertEqual(model.timeline.last?.receivedOrder, 360)
        XCTAssertEqual(model.draft, "Keep this draft")
        await model.refreshConversationSummaries()
        XCTAssertEqual(model.promptBookmarks.count, 200)
        let unrelated = Conversation()
        try await database.save(conversation: unrelated)
        await model.select(unrelated)
        await model.loadNewerMessages()
        XCTAssertTrue(model.timeline.isEmpty)
        XCTAssertFalse(model.historyLoading)
    }

    func testRestoreOpensNewestPageInsteadOfFetchingOldReadingPosition() async throws {
        let chat = Conversation(title: "Restored long chat")
        try await database.save(conversation: chat)
        var oldest: UUID?
        for index in 1...100 {
            let entry = TimelineEntry(kind: .userMessage, title: "You", text: "Message \(index)")
            if index == 1 { oldest = entry.id }
            try await database.save(entry: entry, conversationID: chat.id)
        }
        try await database.saveFeature(SessionState(conversationID: chat.id, readingPosition: oldest), kind: "session", id: "workspace")
        model.settings.automaticallyConnect = false
        await model.restore()
        XCTAssertEqual(model.selectedConversation?.id, chat.id)
        XCTAssertEqual(model.timeline.count, 40)
        XCTAssertEqual(model.timeline.first?.receivedOrder, 61)
        XCTAssertEqual(model.timeline.last?.receivedOrder, 100)
        XCTAssertNil(model.navigationTarget)
        await model.shutdown()
    }

    func testHandoffIsBoundedAndDoesNotCopyCommandsOrErrors() {
        var history = (1...100).map { TimelineEntry(kind: .userMessage, title: "You", text: "Entry \($0): " + String(repeating: "x", count: 4_000)) }
        history += [.init(kind: .command, title: "Terminal", text: "secret-command-output"), .init(kind: .error, title: "Error", text: "private-runtime-error")]
        let prompt = ChatHandoff.prompt(history: history, current: "Continue")
        XCTAssertLessThan(prompt.count, 50_000)
        XCTAssertFalse(prompt.contains("Entry 1:")); XCTAssertTrue(prompt.contains("Entry 100:"))
        XCTAssertFalse(prompt.contains("secret-command-output")); XCTAssertFalse(prompt.contains("private-runtime-error"))
        XCTAssertTrue(prompt.hasSuffix("Continue"))
    }

    func testStreamingFinalWriteWinsAndDoesNotLeakIntoOtherChat() async throws {
        try await readyChat()
        await provider.setCompleteImmediately(false)
        let original = try XCTUnwrap(model.selectedConversation)
        model.draft = "Stream"
        await model.send()
        await provider.emit(.turnStarted("turn"))
        await provider.emit(.agentDelta(turnID: "turn", text: "Hello"))
        try await Task.sleep(for: .milliseconds(150))
        await model.newConversation()
        await provider.emit(.agentDelta(turnID: "turn", text: " world"))
        await provider.emit(.turnCompleted(turnID: "turn", status: .completed, error: nil))
        try await settle()
        XCTAssertTrue(model.timeline.isEmpty)
        await model.select(original)
        let result = try XCTUnwrap(model.timeline.last { $0.kind == .agentMessage })
        XCTAssertEqual(result.text, "Hello world"); XCTAssertFalse(result.isStreaming)
    }

    func testOlderHistoryRemainsReachableAfterLongLiveTurn() async throws {
        try await readyChat()
        await provider.setCompleteImmediately(false)
        model.draft = "Lots of tool activity"
        await model.send()
        for index in 1...230 {
            await provider.emit(.command(turnID: "turn", title: "Command \(index)", output: "Output \(index)", exitCode: 0))
        }
        await provider.emit(.turnCompleted(turnID: "turn", status: .completed, error: nil))
        try await settle()
        XCTAssertEqual(model.timeline.count, 200)
        XCTAssertTrue(model.hasOlderMessages)
        await model.loadOlderMessages()
        XCTAssertEqual(model.timeline.first?.text, "Lots of tool activity")
        XCTAssertFalse(model.hasOlderMessages)
        XCTAssertTrue(model.hasNewerMessages)
        await model.loadLatestMessages()
        XCTAssertEqual(model.timeline.last(where: { $0.kind == .command })?.title, "Command 230")
    }

    func testNavigationDuringTurnPreservesChosenModelAndOtherDraft() async throws {
        try await readyChat()
        await provider.setCompleteImmediately(false)
        await model.chooseModel("deep", provider: .codex)
        let original = try XCTUnwrap(model.selectedConversation)
        model.draft = "Original prompt"
        let sending = Task { await model.send() }
        while !model.isWorking { await Task.yield() }
        await model.newConversation()
        model.draft = "Different draft"
        await sending.value
        let prompts = await provider.sentPrompts, models = await provider.sentModels
        XCTAssertEqual(prompts, ["Original prompt"])
        XCTAssertEqual(models, ["deep"])
        XCTAssertEqual(model.draft, "Different draft")
        XCTAssertNotEqual(model.selectedConversation?.id, original.id)
    }

    func testLiveLargeMessageStoresFullTextButKeepsTimelinePreview() async throws {
        try await readyChat()
        await provider.setCompleteImmediately(false)
        model.draft = "Large response"
        await model.send()
        let text = String(repeating: "A long response. ", count: 2_000)
        await provider.emit(.agentDelta(turnID: "turn", text: text))
        await provider.emit(.turnCompleted(turnID: "turn", status: .completed, error: nil))
        try await settle()
        let preview = try XCTUnwrap(model.timeline.last(where: { $0.kind == .agentMessage }))
        XCTAssertEqual(preview.text.count, 8_000); XCTAssertTrue(preview.textIsPreview)
        XCTAssertFalse(preview.isStreaming)
        let full = await model.fullMessageText(preview.id)
        XCTAssertEqual(full, text)
    }
}
