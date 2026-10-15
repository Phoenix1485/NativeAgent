import AppKit
import Combine
import Foundation

@MainActor
final class WorkspaceViewModel: ObservableObject {
    @Published var projects: [Project] = []
    @Published var conversations: [Conversation] = []
    @Published var groups: [ChatGroup] = []
    @Published var selectedGroupID: UUID?
    @Published var expandedGroupIDs: Set<UUID> = []
    @Published var selectedProject: Project?
    @Published var selectedConversation: Conversation? {
        didSet {
            if oldValue?.id != selectedConversation?.id {
                navigationTarget = nil; summaryConversationID = nil; promptBookmarks = []; detailEntries = []
            }
        }
    }
    @Published var timeline: [TimelineEntry] = []
    @Published private(set) var promptBookmarks: [PromptBookmark] = []
    @Published private(set) var detailEntries: [TimelineEntry] = []
    @Published private(set) var summaryConversationID: UUID?
    @Published var navigationTarget: UUID?
    private var factIDs: [String: UUID] = [:]
    @Published var approvals: [ApprovalRequest] = []
    @Published var draft = ""
    @Published var turnStatus: TurnStatus = .idle
    @Published var connectionStatus: ConnectionStatus = .disconnected
    @Published var models: [ProviderModel] = []
    @Published var selectedModelID: String?
    @Published var rootFiles: [FileNode] = []
    @Published var selectedFile: FileNode?
    @Published var filePreview: FilePreview?
    @Published var gitSnapshot = GitSnapshot()
    @Published var selectedChange: GitFileChange?
    @Published var diffText = ""
    @Published var errorMessage: String?
    @Published var diagnosticMessages: [String] = []
    @Published var accountActionInProgress = false
    @Published var accountNotice: String?
    @Published var savedKeyProviders: Set<ProviderKind> = []
    @Published var providerInspection: ProviderInspection?
    @Published var providerAccount: ProviderAccount?
    @Published var usageWindows: [ProviderUsageWindow] = []
    @Published var chatGPTAccounts: [ChatGPTAccountChoice] = []
    @Published var selectedChatGPTAccount = ""
    @Published var showChatGPTPlanWelcome = false
    var directChatGPT: Bool { settings.provider == .codex && settings.profile(.codex).method == .account }
    var providerCapabilities: ProviderCapabilities { providerInspection?.capabilities ?? .init() }
    @Published var archivedConversations: [Conversation] = []
    @Published var archiveHasMore = false
    @Published var archiveLoading = false
    @Published var searchResults: [Conversation] = []
    @Published var searchHasMore = false
    @Published var searchLoading = false
    @Published var libraryHasMore: Set<String> = []
    @Published var hasOlderMessages = false
    @Published var hasNewerMessages = false
    @Published var historyLoading = false
    @Published var inspectorVisible = false
    let settings: AppPreferences
    lazy var features = WorkspaceFeaturesController(model: self, database: database, defaults: preferences)
    private var featuresSubscription: AnyCancellable?
    @Published var questions: [ProviderQuestionRequest] = []
    var conversationQuestions: [ProviderQuestionRequest] { conversationIsActive ? questions : [] }

    private var provider: any CodingProvider
    private let injectedProvider: Bool
    private let credentials: any CredentialStoring
    private let chatGPTCredentials: any ChatGPTCredentialStoring
    private var settingsSubscription: AnyCancellable?
    private var providerGeneration = UUID()
    private var accountOperation = UUID()
    private var browserLoginPending = false
    private let database: DatabaseActor
    private let files: FileService
    private let git: GitService
    private let preferences: UserDefaults
    private var eventTask: Task<Void, Never>?
    private var streamFlushTask: Task<Void, Never>?
    private var draftSaveTask: Task<Void, Never>?
    private var bufferedDelta = ""
    private var streamingEntry: TimelineEntry?
    private var activeConversationID: UUID?
    private var canceledBeforeTurn = false
    private var activeUserEntry: TimelineEntry?
    private var activeThreadID: String?
    private var activeTurnID: String?
    private var selectionVersion = UUID()
    private var libraryCursors: [String: Conversation] = [:]
    private var loadedScopes: Set<String> = []
    private var loadingScopes: Set<String> = []
    private var searchQuery = ""
    private var searchVersion = UUID()
    private var maintenanceTask: Task<Void, Never>?
    private var persistenceTask: Task<Void, Never>?
    private var creationTail: Task<Void, Never>?
    private var lastStreamSave = Date.distantPast
    private var workspaceLoadedID: UUID?
    private var modelSwitching = false
    private var draftLoaded = true
    private var archivingIDs: Set<UUID> = []
    private let openBrowser: @MainActor (URL) -> Bool

    init(provider: (any CodingProvider)? = nil, database: DatabaseActor, files: FileService, git: GitService, automaticallyRestore: Bool = true, preferences: UserDefaults = .standard, credentials: any CredentialStoring = KeychainCredentialStore(), chatGPTCredentials: any ChatGPTCredentialStoring = ChatGPTKeychainStore(), openBrowser: @escaping @MainActor (URL) -> Bool = { NSWorkspace.shared.open($0) }) {
        self.provider = provider ?? ChatGPTProvider(store: chatGPTCredentials)
        injectedProvider = provider != nil
        self.credentials = credentials
        self.chatGPTCredentials = chatGPTCredentials
        self.openBrowser = openBrowser
        settings = AppPreferences(defaults: preferences)
        self.database = database
        self.files = files
        self.git = git
        self.preferences = preferences
        expandedGroupIDs = Set((preferences.stringArray(forKey: "expandedGroups") ?? []).compactMap(UUID.init(uuidString:)))
        observeProvider()
        models = settings.profile(settings.provider).catalog
        selectedModelID = settings.resolvedDefault(settings.provider)
        settingsSubscription = settings.objectWillChange.sink { [weak self] in
            self?.objectWillChange.send()
            Task { @MainActor [weak self] in self?.reconcileModelSelection() }
        }
        if automaticallyRestore { Task { await restore() } }
        featuresSubscription = features.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
    }

    deinit { eventTask?.cancel(); streamFlushTask?.cancel(); draftSaveTask?.cancel(); maintenanceTask?.cancel() }

    func shutdown() async {
        await features.shutdown()
        accountOperation = UUID(); providerGeneration = UUID(); eventTask?.cancel()
        draftSaveTask?.cancel(); maintenanceTask?.cancel()
        _ = finishStreaming()
        await saveDraft()
        await persistenceTask?.value
        await provider.cancelLogin()
        await provider.disconnect()
    }

    var canSend: Bool {
        guard !features.finishingTask, features.activeTask == nil, !features.importingFiles, !features.editorHasChanges, !features.fileSaveInProgress else { return false }
        guard providerCapabilities.structuredStreaming else { return false }
        guard case .ready = connectionStatus else { return false }
        if let id = selectedConversation?.id, archivingIDs.contains(id) { return false }
        return !modelSwitching && !historyLoading && selectedConversation?.archivedAt == nil && availableModels.contains(where: { $0.id == selectedModelID }) && !accountActionInProgress && selectedProject != nil && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && [.idle, .completed, .interrupted, .failed].contains(turnStatus)
    }

    var availableModels: [ProviderModel] { settings.enabledModels(settings.provider) }
    var selectedProviderModel: ProviderModel? { settings.profile(settings.provider).catalog.first { $0.id == selectedModelID } }
    var selectedReasoning: String {
        get { settings.reasoning(for: selectedProviderModel, provider: settings.provider) ?? "" }
        set {
            guard let id = selectedModelID else { return }
            settings.update(settings.provider) { $0.reasoning[id] = newValue.isEmpty ? nil : newValue }
        }
    }
    private func reconcileModelSelection() {
        models = settings.profile(settings.provider).catalog
        if !availableModels.contains(where: { $0.id == selectedModelID }) { selectedModelID = settings.resolvedDefault(settings.provider) }
    }
    private func observeProvider() {
        eventTask?.cancel()
        let current = provider
        let generation = UUID(); providerGeneration = generation
        eventTask = Task { [weak self] in
            for await event in await current.events {
                guard let self, self.providerGeneration == generation, !Task.isCancelled else { return }
                await self.receive(event)
            }
        }
    }

    func useProvider(_ kind: ProviderKind) async {
        guard !isWorking, !accountActionInProgress, connectionStatus != .connecting, settings.provider != kind else { return }
        await disconnect()
        settings.provider = kind
        providerInspection = nil
        accountNotice = nil
        models = settings.profile(kind).catalog
        selectedModelID = settings.resolvedDefault(kind)
    }

    func chooseModel(_ id: String, provider kind: ProviderKind) async {
        guard !isWorking, !accountActionInProgress, !modelSwitching, connectionStatus != .connecting,
              settings.enabledModels(kind).contains(where: { $0.id == id }) else { return }
        modelSwitching = true
        defer { modelSwitching = false; objectWillChange.send() }
        if settings.provider != kind {
            await useProvider(kind)
        }
        if case .ready = connectionStatus { } else { await connect() }
        // Keep the explicit choice even if authentication needs attention.
        selectedModelID = id
    }

    func chats(in groupID: UUID?) -> [Conversation] {
        conversations.filter { $0.groupID == groupID }.sorted {
            $0.updatedAt == $1.updatedAt ? $0.id.uuidString > $1.id.uuidString : $0.updatedAt > $1.updatedAt
        }
    }

    func loadChats(in groupID: UUID? = nil, more: Bool = false) async {
        let scope = groupID?.uuidString ?? "root"
        guard !loadingScopes.contains(scope), more || !loadedScopes.contains(scope) else { return }
        loadingScopes.insert(scope)
        defer { loadingScopes.remove(scope) }
        do {
            let page = try await database.conversationPage(groupID: groupID, after: more ? libraryCursors[scope] : nil)
            for chat in page { upsertChat(chat) }
            if let last = page.last { libraryCursors[scope] = last }
            loadedScopes.insert(scope)
            if page.count == 50 { libraryHasMore.insert(scope) } else { libraryHasMore.remove(scope) }
        } catch { show(error) }
    }

    private func upsertChat(_ chat: Conversation) {
        if let index = conversations.firstIndex(where: { $0.id == chat.id }) { conversations[index] = chat }
        else { conversations.append(chat) }
        if let index = searchResults.firstIndex(where: { $0.id == chat.id }) { searchResults[index] = chat }
    }

    func searchChats(_ query: String, more: Bool = false) async {
        if more && searchLoading { return }
        let version = UUID(); searchVersion = version; searchQuery = query
        if !more { searchResults = []; searchHasMore = false }
        guard !query.isEmpty else { searchLoading = false; return }
        searchLoading = true
        defer { if searchVersion == version { searchLoading = false } }
        do {
            if !more { try await Task.sleep(for: .milliseconds(250)) }
            guard !Task.isCancelled, searchVersion == version else { return }
            let page = try await database.conversationPage(search: query, after: more ? searchResults.last : nil)
            guard !Task.isCancelled, searchVersion == version else { return }
            let existing = Set(searchResults.map(\.id))
            searchResults += page.filter { !existing.contains($0.id) }
            searchHasMore = page.count == 50
        } catch is CancellationError { } catch { show(error) }
    }

    func archive(_ chat: Conversation) async {
        guard !archivingIDs.contains(chat.id) else { return }
        guard activeConversationID != chat.id else {
            show(NativeAgentError.unsupported("Stop this chat’s current turn before archiving it.")); return
        }
        archivingIDs.insert(chat.id)
        defer { archivingIDs.remove(chat.id); objectWillChange.send() }
        do {
            if selectedConversation?.id == chat.id {
                draftSaveTask?.cancel()
                await saveDraft()
            }
            await persistenceTask?.value
            try await database.archiveConversation(id: chat.id)
            conversations.removeAll { $0.id == chat.id }
            searchResults.removeAll { $0.id == chat.id }
            if selectedConversation?.id == chat.id { await selectGroup(chat.groupID) }
        } catch { show(error) }
    }

    func loadArchive(more: Bool = false) async {
        guard !archiveLoading else { return }
        archiveLoading = true
        defer { archiveLoading = false }
        do {
            await maintainArchive()
            let page = try await database.conversationPage(archived: true, after: more ? archivedConversations.last : nil)
            if !more { archivedConversations = [] }
            let existing = Set(archivedConversations.map(\.id))
            archivedConversations += page.filter { !existing.contains($0.id) }
            archiveHasMore = page.count == 50
        } catch { show(error) }
    }

    func restoreArchived(_ chat: Conversation) async {
        do {
            guard try await database.restoreConversation(id: chat.id) else {
                archivedConversations.removeAll { $0.id == chat.id }
                show(NativeAgentError.unsupported("This chat’s 30-day recovery period has expired.")); return
            }
            var restored = chat; restored.archivedAt = nil
            upsertChat(restored)
            archivedConversations.removeAll { $0.id == chat.id }
            if let group = restored.groupID { expand(group, expanded: true) }
        } catch { show(error) }
    }

    func maintainArchive() async {
        do {
            while !Task.isCancelled {
                let purged = try await database.purgeExpiredArchive()
                let ids = Set(purged)
                archivedConversations.removeAll { ids.contains($0.id) }
                if purged.count < 100 { break }
                await Task.yield()
            }
        } catch { show(error) }
    }

    func refreshSavedKeys() {
        savedKeyProviders = Set(ProviderKind.allCases.filter { (try? credentials.contains($0)) == true })
    }

    func saveAPIKey(_ value: String, kind: ProviderKind) async -> Bool {
        guard !isWorking, !accountActionInProgress else { return false }
        do {
            try credentials.save(value, for: kind)
            if settings.provider == kind { await disconnect() }
            settings.update(kind) { $0.method = .apiKey; $0.accountLabel = nil; $0.verifiedAt = nil }
            refreshSavedKeys()
            accountNotice = "API key saved in macOS Keychain. Connect to use it."
            return true
        } catch { show(error); return false }
    }

    func removeAPIKey(_ kind: ProviderKind) async {
        guard !isWorking, !accountActionInProgress else { return }
        do {
            if settings.provider == kind { await disconnect() }
            try credentials.remove(kind)
            settings.update(kind) { $0.method = .account; $0.accountLabel = nil; $0.verifiedAt = nil }
            refreshSavedKeys(); accountNotice = "Saved API key removed from Keychain."
        } catch { show(error) }
    }

    private func prepareProvider() async throws {
        guard !injectedProvider else { return }
        await provider.disconnect()
        let kind = settings.provider, profile = settings.profile(kind)
        if profile.method == .account {
            guard kind == .codex else {
                throw NativeAgentError.unsupported("Independent browser subscription authorization for \(kind.title) is not configured. NativeAgent will not launch its CLI or reuse another app’s credentials.")
            }
            provider = ChatGPTProvider(store: chatGPTCredentials)
            observeProvider()
            providerInspection = await provider.inspect()
            return
        }
        guard let path = ProviderExecutable.resolve(kind, configured: profile.binaryPath), FileManager.default.isExecutableFile(atPath: path) else {
            throw NativeAgentError.missingInstallation("\(kind.title) runtime not found. Install it using the official setup link, or choose its executable in Settings → Configuration.")
        }
        let key = profile.method == .apiKey ? try credentials.read(kind) : nil
        if profile.method == .apiKey && key == nil { throw NativeAgentError.providerUnavailable("Add an API key in Accounts first, or select account sign-in.") }
        switch kind {
        case .codex: provider = CodexProvider(binaryPath: path, authenticationMethod: profile.method)
        case .claude: provider = ClaudeProvider(path: path, apiKey: key)
        case .grok: provider = GrokProvider(path: path, apiKey: key)
        }
        observeProvider()
        providerInspection = await provider.inspect()
    }

    var selectedGroup: ChatGroup? { groups.first { $0.id == selectedGroupID } }
    var isWorking: Bool { [.starting, .running, .awaitingApproval, .awaitingUserInput, .interrupting, .stateUnknown].contains(turnStatus) }

    func project(for groupID: UUID?) -> Project? {
        var current = groupID
        var visited = Set<UUID>()
        while let id = current, visited.insert(id).inserted, let group = groups.first(where: { $0.id == id }) {
            if let project = projects.first(where: { $0.id == group.projectID }) { return project }
            current = group.parentID
        }
        return nil
    }

    func groupPath(_ id: UUID) -> String {
        guard let group = groups.first(where: { $0.id == id }) else { return "" }
        if let parent = group.parentID { return groupPath(parent) + " / " + group.name }
        return group.name
    }

    func expand(_ id: UUID, expanded: Bool) {
        if expanded { expandedGroupIDs.insert(id) } else { expandedGroupIDs.remove(id) }
        preferences.set(expandedGroupIDs.map(\.uuidString), forKey: "expandedGroups")
    }

    func saveGroup(name: String, parentID: UUID?, folder: URL?, editing: ChatGroup? = nil) async -> Bool {
        do {
            var workspace: Project?
            if let folder { workspace = try await registerProject(folder) }
            var group = editing ?? ChatGroup(parentID: parentID, name: name)
            group.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            group.projectID = workspace?.id ?? editing?.projectID
            try await database.save(group: group)
            groups = try await database.groups()
            if let parentID { expand(parentID, expanded: true) }
            expand(group.id, expanded: true)
            await selectGroup(group.id)
            return true
        } catch { show(error); return false }
    }

    func moveConversation(_ conversation: Conversation, to groupID: UUID?) async {
        var moved = conversation
        moved.groupID = groupID
        // An established chat keeps its actual working directory when reorganized.
        if moved.projectID == nil { moved.projectID = project(for: groupID)?.id }
        do {
            try await database.save(conversation: moved)
            upsertChat(moved)
            if let groupID { expand(groupID, expanded: true) }
            if selectedConversation?.id == moved.id { await select(moved) }
        } catch { show(error) }
    }

    func moveGroup(_ group: ChatGroup, to parentID: UUID?) async {
        var moved = group
        moved.parentID = parentID
        // Preserve its inherited workspace across a move.
        moved.projectID = project(for: group.id)?.id
        do {
            try await database.save(group: moved)
            groups = try await database.groups()
            if let parentID { expand(parentID, expanded: true) }
        } catch { show(error) }
    }

    func removeGroup(_ group: ChatGroup) async {
        do {
            try await database.removeEmptyGroup(id: group.id)
            groups = try await database.groups()
            if selectedGroupID == group.id { await selectGroup(nil) }
        } catch { show(error) }
    }

    func renameConversation(_ conversation: Conversation) {
        let alert = NSAlert()
        alert.messageText = "Rename chat"
        let input = NSTextField(string: conversation.title)
        input.frame = NSRect(x: 0, y: 0, width: 300, height: 26)
        alert.accessoryView = input
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = input
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let title = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        Task {
            var renamed = conversation
            renamed.title = title
            do {
                try await database.save(conversation: renamed)
                upsertChat(renamed)
                if selectedConversation?.id == renamed.id { selectedConversation = renamed }
            } catch { show(error) }
        }
    }

    func selectGroup(_ id: UUID?) async {
        try? await features.saveContext()
        draftSaveTask?.cancel()
        let previous = draftLoaded ? selectedConversation : nil, previousDraft = draft
        let version = UUID(); selectionVersion = version
        selectedGroupID = id
        selectedConversation = nil
        draft = ""
        timeline = []
        selectedProject = project(for: id)
        draftLoaded = true; historyLoading = false; hasOlderMessages = false; hasNewerMessages = false
        if let previous { try? await database.saveDraft(previousDraft, conversationID: previous.id) }
        guard selectionVersion == version else { return }
        await loadChats(in: id)
        guard selectionVersion == version else { return }
        await loadWorkspace()
        await features.selectionChanged()
    }

    func inspectProvider() async -> ProviderInspection { await provider.inspect() }

    func openProject() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Use Folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await addProject(url) }
    }

    func addProject(_ url: URL) async {
        if selectedConversation?.remoteThreadID != nil {
            show(NativeAgentError.unsupported("This chat already has a working folder. Create a new chat to use another folder."))
            return
        }
        do {
            let project = try await registerProject(url)
            selectedProject = project
            if var chat = selectedConversation {
                chat.projectID = project.id
                try await database.save(conversation: chat)
                selectedConversation = chat
                upsertChat(chat)
            }
            await loadWorkspace()
            await features.selectionChanged()
            await features.applyProfileForNewConversation()
        } catch { show(error) }
    }

    private func registerProject(_ url: URL) async throws -> Project {
        let canonical = url.resolvingSymlinksInPath().standardizedFileURL
        var project = projects.first(where: { $0.canonicalPath == canonical.path }) ?? Project(name: canonical.lastPathComponent, canonicalPath: canonical.path)
        project.lastOpenedAt = .now
        try await database.save(project: project)
        projects = try await database.projects()
        return project
    }

    func select(_ project: Project) async {
        await selectGroup(nil)
        selectedProject = project
        await loadWorkspace()
        await features.selectionChanged()
        await features.applyProfileForNewConversation()
    }

    func removeProject(_ project: Project) async {
        do {
            try await database.removeProject(id: project.id)
            projects.removeAll { $0.id == project.id }
            if selectedProject?.id == project.id {
                selectedProject = projects.first
                if let first = projects.first { await select(first) }
            }
        } catch { show(error) }
    }

    func newConversation(in groupID: UUID? = nil) async {
        let previous = creationTail
        let operation = Task { [weak self] in
            await previous?.value
            await self?.createConversation(in: groupID)
        }
        creationTail = operation
        await operation.value
    }

    private func createConversation(in groupID: UUID?) async {
        do {
            await persistenceTask?.value
            var excluded = archivingIDs
            if let activeConversationID { excluded.insert(activeConversationID) }
            if let existing = try await database.unsentConversation(preferredID: selectedConversation?.id, excluding: excluded) {
                upsertChat(existing)
                if selectedConversation?.id != existing.id { await select(existing) }
                var ancestor = existing.groupID
                var visited: Set<UUID> = []
                while let id = ancestor, visited.insert(id).inserted {
                    expand(id, expanded: true)
                    ancestor = groups.first { $0.id == id }?.parentID
                }
                return
            }
            var conversation = Conversation(projectID: project(for: groupID)?.id ?? (groupID == nil && selectedGroupID == nil ? selectedProject?.id : nil), groupID: groupID)
            conversation.providerID = settings.provider
            if !isWorking { selectedModelID = settings.resolvedDefault(settings.provider) }
            try await database.save(conversation: conversation)
            conversations.insert(conversation, at: 0)
            await select(conversation)
            await features.applyProfileForNewConversation()
            if let groupID { expand(groupID, expanded: true) }
        } catch { show(error) }
    }

    func select(_ conversation: Conversation) async {
        guard conversation.archivedAt == nil else { return }
        try? await features.saveContext()
        draftSaveTask?.cancel()
        let previous = draftLoaded ? selectedConversation : nil, previousDraft = draft
        let version = UUID()
        selectionVersion = version
        selectedConversation = conversation
        selectedGroupID = conversation.groupID
        selectedProject = projects.first { $0.id == conversation.projectID } ?? project(for: conversation.groupID)
        timeline = []
        draft = ""
        draftLoaded = false; historyLoading = true; hasOlderMessages = false; hasNewerMessages = false
        do {
            if let previous { try await database.saveDraft(previousDraft, conversationID: previous.id) }
            await persistenceTask?.value
            let entries = try await database.timeline(conversationID: conversation.id, limit: 40, previewCharacters: 8_000)
            let savedDraft = try await database.draft(conversationID: conversation.id)
            guard selectionVersion == version else { return }
            timeline = entries
            if activeConversationID == conversation.id, let streamingEntry {
                if let index = timeline.firstIndex(where: { $0.id == streamingEntry.id }) { timeline[index] = displayEntry(streamingEntry) }
                else { timeline.append(displayEntry(streamingEntry)) }
            }
            hasOlderMessages = (entries.first?.receivedOrder ?? 1) > 1
            draft = savedDraft
            draftLoaded = true; historyLoading = false
            await loadWorkspace()
            await features.selectionChanged()
        } catch { if selectionVersion == version { historyLoading = false; show(error) } }
    }

    func loadOlderMessages() async {
        guard !historyLoading, hasOlderMessages, let chat = selectedConversation, let first = timeline.first else { return }
        let version = selectionVersion
        historyLoading = true
        defer { if selectionVersion == version { historyLoading = false } }
        do {
            await persistenceTask?.value
            let savedOrder = try await database.timelineOrder(id: first.id)
            guard let order = first.receivedOrder ?? savedOrder else { return }
            let page = try await database.timeline(conversationID: chat.id, limit: 40, beforeOrder: order, previewCharacters: 8_000)
            guard selectionVersion == version else { return }
            timeline.insert(contentsOf: page, at: 0)
            hasOlderMessages = (page.first?.receivedOrder ?? 1) > 1
            if timeline.count > 200 { timeline = Array(timeline.prefix(200)); hasNewerMessages = true }
        } catch { show(error) }
    }

    func loadLatestMessages() async {
        guard let chat = selectedConversation, !historyLoading else { return }
        let version = selectionVersion; historyLoading = true
        defer { if selectionVersion == version { historyLoading = false } }
        do {
            await persistenceTask?.value
            let entries = try await database.timeline(conversationID: chat.id, limit: 40, previewCharacters: 8_000)
            guard selectionVersion == version else { return }
            timeline = entries; hasNewerMessages = false
            hasOlderMessages = (entries.first?.receivedOrder ?? 1) > 1
            if activeConversationID == chat.id, let streamingEntry {
                if let index = timeline.firstIndex(where: { $0.id == streamingEntry.id }) { timeline[index] = displayEntry(streamingEntry) }
                else { timeline.append(displayEntry(streamingEntry)) }
            }
        } catch { show(error) }
    }

    func fullMessageText(_ id: UUID) async -> String? {
        await persistenceTask?.value
        return try? await database.fullTimelineText(id: id)
    }

    var conversationPrompts: [PromptBookmark] {
        var result = summaryConversationID == selectedConversation?.id ? promptBookmarks : []
        let known = Set(result.map(\.id))
        var order = result.last?.order ?? 0
        for entry in timeline where entry.kind == .userMessage && !known.contains(entry.id) {
            order = max(order + 1, entry.receivedOrder ?? 0)
            result.append(.init(id: entry.id, order: entry.receivedOrder ?? order, preview: String(entry.text.prefix(240))))
        }
        return result.sorted { $0.order < $1.order }
    }

    var conversationDetails: [TimelineEntry] {
        var result = summaryConversationID == selectedConversation?.id ? detailEntries : []
        for entry in timeline where entry.kind != .userMessage && !entry.isStreaming {
            if let index = result.firstIndex(where: { $0.id == entry.id }) { result[index] = entry }
            else { result.append(entry) }
        }
        return result.sorted { $0.createdAt < $1.createdAt }
    }

    var conversationIsActive: Bool { selectedConversation?.id != nil && selectedConversation?.id == activeConversationID }
    var conversationApprovals: [ApprovalRequest] { conversationIsActive ? approvals : [] }
    var conversationStatus: String {
        if conversationIsActive { return turnStatus.label }
        guard let recorded = conversationDetails.last(where: { ConversationFact.decode($0.detail)?.category == .status }) else { return "No recorded task status" }
        return "Last reported: " + recorded.text
    }

    func refreshConversationSummaries(includePrompts: Bool = true) async {
        guard let chat = selectedConversation else { promptBookmarks = []; detailEntries = []; summaryConversationID = nil; return }
        let version = selectionVersion
        await persistenceTask?.value
        do {
            let prompts = includePrompts ? try await database.promptBookmarks(conversationID: chat.id) : nil
            let details = try await database.timeline(conversationID: chat.id, limit: 200, previewCharacters: 600, detailsOnly: true)
            guard selectedConversation?.id == chat.id, selectionVersion == version else { return }
            if let prompts { promptBookmarks = prompts }
            var merged = Dictionary(uniqueKeysWithValues: details.map { ($0.id, $0) })
            if summaryConversationID == chat.id {
                // Events may arrive while the database query is suspended.
                // Keep those newer in-memory facts instead of replacing them.
                for entry in detailEntries { merged[entry.id] = entry }
            }
            detailEntries = Array(merged.values.sorted { $0.createdAt < $1.createdAt }.suffix(200))
            summaryConversationID = chat.id
        } catch { show(error) }
    }

    /// Seek by persistent ID without loading every intervening message.
    func navigateToMessage(_ id: UUID) async {
        guard let chat = selectedConversation, !historyLoading else { return }
        if timeline.contains(where: { $0.id == id }) { navigationTarget = id; return }
        let version = selectionVersion
        historyLoading = true
        defer { if selectionVersion == version { historyLoading = false } }
        do {
            await persistenceTask?.value
            let entries = try await database.timelineWindow(conversationID: chat.id, around: id)
            let latest = try await database.timeline(conversationID: chat.id, limit: 1, previewCharacters: 1)
            guard selectionVersion == version, selectedConversation?.id == chat.id, entries.contains(where: { $0.id == id }) else { return }
            timeline = entries
            hasOlderMessages = (entries.first?.receivedOrder ?? 1) > 1
            hasNewerMessages = entries.last?.id != latest.last?.id
            navigationTarget = id
        } catch { show(error) }
    }

    func previewConversationFile(_ path: String) async throws -> String {
        guard let project = selectedProject else { throw NativeAgentError.noProject }
        var relative = path
        if path.hasPrefix("/") {
            let prefix = project.canonicalPath + "/"
            guard path.hasPrefix(prefix) else { throw NativeAgentError.unsupported("This file is outside the conversation’s working folder.") }
            relative = String(path.dropFirst(prefix.count))
        }
        return try await files.preview(root: project.canonicalPath, relativePath: relative).text
    }

    private func recordFact(_ fact: ConversationFact, turnID: String?) {
        guard let chatID = activeConversationID ?? selectedConversation?.id else { return }
        let key = "\(chatID)/\(turnID ?? "")/\(fact.key)"
        let id = factIDs[key] ?? UUID(); factIDs[key] = id
        let entry = TimelineEntry(id: id, turnID: turnID, kind: .fact, title: fact.title, text: fact.text, detail: fact.encoded)
        if selectedConversation?.id == chatID, !hasNewerMessages {
            if let index = timeline.firstIndex(where: { $0.id == id }) { timeline[index] = entry }
            else { timeline.append(entry); trimLiveTimeline() }
        }
        persist(entry, conversationID: chatID)
    }

    private func loadWorkspace() async {
        if workspaceLoadedID == selectedProject?.id { return }
        selectedFile = nil
        filePreview = nil
        selectedChange = nil
        diffText = ""
        rootFiles = []
        gitSnapshot = GitSnapshot()
        workspaceLoadedID = nil
        guard inspectorVisible, let project = selectedProject else { return }
        let nodes = try? await files.children(root: project.canonicalPath)
        let status = try? await git.status(at: project.canonicalPath)
        guard selectedProject?.id == project.id else { return }
        rootFiles = nodes ?? []
        gitSnapshot = status ?? GitSnapshot()
        workspaceLoadedID = project.id
    }

    func setInspectorVisible(_ value: Bool) async {
        inspectorVisible = value
        if value { await loadWorkspace() }
    }

    func connect() async {
        guard connectionStatus != .connecting, !isWorking, !accountActionInProgress else { return }
        accountActionInProgress = true
        let operation = UUID(); accountOperation = operation
        defer { if accountOperation == operation { accountActionInProgress = false } }
        providerAccount = nil; usageWindows = []; accountNotice = nil
        connectionStatus = .connecting
        do {
            try await prepareProvider()
            guard accountOperation == operation else { return }
            try await provider.connect()
            guard accountOperation == operation else { return }
            if settings.provider == .codex, settings.profile(.codex).method == .apiKey, let key = try credentials.read(.codex) { try await provider.login(apiKey: key) }
            guard accountOperation == operation else { return }
            if settings.provider != .codex || injectedProvider { await refreshModels() }
            selectedModelID = settings.resolvedDefault(settings.provider)
        } catch {
            if accountOperation == operation { connectionError(error) }
        }
    }

    func disconnect() async {
        guard !isWorking else { return }
        accountOperation = UUID(); browserLoginPending = false; accountActionInProgress = false
        providerAccount = nil; usageWindows = []; approvals = []
        if !injectedProvider { eventTask?.cancel(); providerGeneration = UUID() }
        await provider.disconnect()
        connectionStatus = .disconnected
        accountNotice = directChatGPT ? "Disconnected. NativeAgent’s saved ChatGPT authorization is preserved." : "Disconnected. The provider’s shared login is preserved."
    }

    func login() async {
        guard !isWorking, !accountActionInProgress else { return }
        accountActionInProgress = true
        let operation = UUID(); accountOperation = operation
        defer { if accountOperation == operation && !browserLoginPending { accountActionInProgress = false } }
        accountNotice = "Preparing browser authorization for NativeAgent. No provider application will be opened."
        providerAccount = nil; usageWindows = []
        settings.update(settings.provider) { $0.method = .account }
        connectionStatus = .connecting
        do {
            try await prepareProvider()
            guard accountOperation == operation else { return }
            if !(provider is ChatGPTProvider) { try await provider.connect() }
            guard accountOperation == operation else { return }
            if case .ready = connectionStatus { } else { connectionStatus = .signingIn }
            if provider is ChatGPTProvider { browserLoginPending = true }
            try await provider.beginLogin()
            guard accountOperation == operation else { return }
            if settings.provider != .codex || injectedProvider { await refreshModels() }
        } catch { if accountOperation == operation { browserLoginPending = false; connectionError(error) } }
    }

    func cancelLogin() async {
        accountOperation = UUID()
        browserLoginPending = false
        eventTask?.cancel(); providerGeneration = UUID()
        await provider.cancelLogin()
        await provider.disconnect()
        eventTask?.cancel(); providerGeneration = UUID()
        providerAccount = nil; usageWindows = []
        connectionStatus = .notAuthenticated; accountActionInProgress = false
        accountNotice = "Sign-in cancelled. The local callback has been closed. You can close the browser tab and try again."
    }

    func signOut() async {
        guard !isWorking, !accountActionInProgress else { return }
        accountActionInProgress = true
        defer { accountActionInProgress = false }
        do {
            try await prepareProvider()
            if !(provider is ChatGPTProvider) { try await provider.connect() }
            try await provider.logout()
            await disconnect()
            settings.update(settings.provider) { $0.accountLabel = nil; $0.verifiedAt = nil }
            accountNotice = directChatGPT ? "Signed out of NativeAgent’s ChatGPT connection. Other apps are unchanged." : "Signed out of the provider runtime."
            refreshChatGPTAccounts()
        } catch {
            if directChatGPT { await disconnect(); settings.update(.codex) { $0.accountLabel = nil; $0.verifiedAt = nil }; refreshChatGPTAccounts() }
            show(error)
        }
    }

    struct ChatGPTAccountChoice: Identifiable { var id: String; var label: String }
    func refreshChatGPTAccounts() {
        guard !injectedProvider else { return }
        do {
            let record = try chatGPTCredentials.load()
            chatGPTAccounts = record.registrations.map { .init(id: $0.clientID, label: ($0.email ?? "ChatGPT account") + " · " + String($0.clientID.suffix(8))) }
            selectedChatGPTAccount = record.activeClientID ?? ""
        } catch { accountNotice = error.localizedDescription }
    }
    func selectChatGPTAccount(_ id: String) async {
        guard !isWorking, !accountActionInProgress, !injectedProvider else { return }
        await disconnect()
        do {
            var record = try chatGPTCredentials.load()
            guard id.isEmpty || record.registrations.contains(where: { $0.clientID == id }) else { return }
            record.activeClientID = id.isEmpty ? nil : id
            try chatGPTCredentials.save(record)
            settings.update(.codex) { $0.accountLabel = nil; $0.verifiedAt = nil; $0.catalog = [] }
            models = []; selectedModelID = nil
            refreshChatGPTAccounts()
        } catch { show(error) }
    }

    func refreshModels() async {
        do {
            let value = try await provider.loadModels()
            settings.mergeCatalog(value, provider: settings.provider)
            models = value
            reconcileModelSelection()
        } catch { accountNotice = "The model list could not be refreshed. Connect or sign in and try again." }
    }

    func openClaudeTerminal() async {
        guard case .ready = connectionStatus, !accountActionInProgress, !isWorking,
              let claude = provider as? ClaudeProvider else { return }
        guard let project = selectedProject else { openProject(); return }
        guard confirmTrustIfNeeded(for: project) else { return }
        do {
            try await claude.openTerminal(folder: project.canonicalPath, model: nil, readOnly: settings.access == .readOnly)
            accountNotice = "Official Claude Code is open in Terminal. Choose /model and /resume there; permissions and Ctrl-C are handled by Claude Code. This session is not captured in NativeAgent’s chat history."
        } catch { show(error) }
    }

    private func connectionError(_ error: Error) {
        browserLoginPending = false
        providerAccount = nil; usageWindows = []
        switch error {
        case NativeAgentError.missingInstallation: connectionStatus = .missingInstallation
        case NativeAgentError.unsupportedVersion(let message): connectionStatus = .unsupportedVersion(message)
        case is CancellationError: connectionStatus = .notAuthenticated
        default: connectionStatus = .failed(error.localizedDescription)
        }
        accountNotice = error is CancellationError ? "Connection cancelled. Try again when ready." : error.localizedDescription
        if !(error is CancellationError) { show(error) }
    }

    func send() async {
        guard canSend, let project = selectedProject else { return }
        guard confirmTrustIfNeeded(for: project) else { return }
        // Claim the single active turn before the first suspension, including chat creation.
        turnStatus = .starting
        canceledBeforeTurn = false
        let prompt = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let chosenModelID = selectedModelID
        let run = RunConfiguration(reasoning: settings.effectiveReasoning(for: selectedProviderModel, provider: settings.provider), access: settings.access, instructions: settings.instructions)
        var conversation = selectedConversation ?? Conversation(projectID: project.id, groupID: selectedGroupID)
        let previousSession = conversation
        let needsNewSession = conversation.remoteThreadID == nil || conversation.providerID != settings.provider
        if needsNewSession { conversation.remoteThreadID = nil; conversation.providerID = settings.provider }
        if conversation.projectID == nil { conversation.projectID = project.id }
        selectedConversation = conversation
        upsertChat(conversation)
        draftSaveTask?.cancel()
        draft = ""
        activeConversationID = conversation.id
        let userEntry = TimelineEntry(kind: .userMessage, title: "You", text: prompt)
        activeUserEntry = userEntry
        let preparationContextOwner = features.contextOwner
        do {
            try await database.save(conversation: conversation)
            let explicitContext = try await features.contextForSend()
            let contextSnapshot = features.context
            let localTools = provider is ChatGPTProvider ? try await features.nativeTools(access: run.access, attachments: contextSnapshot, owner: conversation.id) : []
            guard features.contextOwner == preparationContextOwner else { throw NativeAgentError.unsupported("Conversation changed while preparing attachments. Review and send again.") }
            try await features.beginTask(conversation: conversation, project: project, prompt: prompt)
            await persistenceTask?.value
            // Direct Responses has no durable provider thread. Resend a disclosed bounded excerpt.
            let history = (needsNewSession || provider is ChatGPTProvider) ? try await database.timeline(conversationID: conversation.id, limit: 24, previewCharacters: 2_000, messagesOnly: true) : []
            let providerPrompt = ChatHandoff.prompt(history: history, current: prompt) + explicitContext
            if canceledBeforeTurn { throw CancellationError() }
            if selectedConversation?.id == conversation.id && hasNewerMessages { await loadLatestMessages() }
            append(userEntry, conversationID: conversation.id)
            if previousSession.providerID != settings.provider && !history.isEmpty {
                append(.init(kind: .notice, title: "Switched to \(settings.provider.title)", text: "Sent a bounded excerpt of recent visible messages to this provider. Older messages and long-message tails may be omitted."), conversationID: conversation.id)
            }
            await provider.configure(run)
            if let direct = provider as? ChatGPTProvider {
                await direct.setNativeTools(localTools)
            }
            try await database.saveDraft("", conversationID: conversation.id)
            let threadID: String
            if let existing = conversation.remoteThreadID {
                threadID = existing
            } else {
                threadID = try await provider.startThread(projectPath: project.canonicalPath, model: chosenModelID)
                conversation.remoteThreadID = threadID
                if conversation.title == "New chat" { conversation.title = String(prompt.prefix(60)) }
            }
            conversation.updatedAt = .now
            try await database.save(conversation: conversation)
            if selectedConversation?.id == conversation.id { selectedConversation = conversation }
            upsertChat(conversation)
            activeThreadID = threadID
            if canceledBeforeTurn { throw CancellationError() }
            try await provider.startTurn(threadID: threadID, prompt: providerPrompt, projectPath: project.canonicalPath, model: chosenModelID)
            for item in contextSnapshot {
                let fact = ConversationFact(key: "attachment/\(userEntry.id)/\(item.id)", category: .source, title: item.title,
                    text: item.wireText, path: item.path)
                append(.init(turnID: activeTurnID, kind: .fact, title: fact.title, text: fact.text, detail: fact.encoded), conversationID: conversation.id)
            }
            if !history.isEmpty {
                // Store only the exact visible context that this application sent.
                let fact = ConversationFact(key: "handoff/\(userEntry.id)", category: .source, title: "Recent conversation context", text: providerPrompt)
                append(.init(turnID: activeTurnID, kind: .fact, title: fact.title, text: fact.text, detail: fact.encoded), conversationID: conversation.id)
            }
        } catch {
            // A failed handoff must not strand the chat on an empty foreign session.
            if selectedConversation?.id == conversation.id, draft.isEmpty { draft = prompt; scheduleDraftSave() }
            if needsNewSession {
                conversation.remoteThreadID = previousSession.remoteThreadID
                conversation.providerID = previousSession.providerID
                try? await database.save(conversation: conversation)
                if selectedConversation?.id == conversation.id { selectedConversation = conversation }
                upsertChat(conversation)
            }
            let canceled = error is CancellationError
            turnStatus = canceled ? .interrupted : .failed
            await features.completeTask(canceled ? .canceled : .failed, error: canceled ? nil : error.localizedDescription)
            recordFact(.init(key: "turn-status", category: .status, title: "Task status", text: canceled ? "Canceled before execution" : "Failed to start", state: canceled ? "interrupted" : "failed"), turnID: activeTurnID)
            if !canceled { append(.init(kind: .error, title: "Couldn’t start", text: error.localizedDescription), conversationID: conversation.id) }
            activeConversationID = nil
            activeUserEntry = nil
            activeThreadID = nil
            activeTurnID = nil
            if !canceled { show(error) }
        }
    }

    func stop() async {
        guard providerCapabilities.interrupt else { return }
        if activeThreadID == nil, turnStatus == .starting || turnStatus == .interrupting {
            canceledBeforeTurn = true; features.pauseQueue(); turnStatus = .interrupting; return
        }
        guard let threadID = activeThreadID else { return }
        turnStatus = .interrupting
        do { try await provider.interrupt(threadID: threadID, turnID: activeTurnID) }
        catch { turnStatus = .stateUnknown; show(error) }
    }

    func detachUnknownExecution() async {
        guard turnStatus == .stateUnknown else { return }
        let alert = NSAlert()
        alert.messageText = "Disconnect from uncertain execution?"
        alert.informativeText = "Verify the provider and any external commands before starting more work. This does not prove the task stopped or succeeded. Its report remains marked for review and the queue stays paused. No task will be resent."
        alert.addButton(withTitle: "Disconnect and keep report unknown"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        features.pauseQueue(); await features.completeTask(.needsReview)
        _ = finishStreaming(); await persistenceTask?.value
        if !injectedProvider { eventTask?.cancel(); providerGeneration = UUID() }
        await provider.disconnect()
        activeConversationID = nil; activeThreadID = nil; activeTurnID = nil; activeUserEntry = nil
        approvals = []; questions = []; turnStatus = .idle; connectionStatus = .disconnected
    }

    func answer(_ approval: ApprovalRequest, decision: ApprovalDecision) async {
        do {
            try await provider.answerApproval(id: approval.id, decision: decision)
            approvals.removeAll { $0.id == approval.id }
            turnStatus = decision == .cancel ? .interrupting : .running
        } catch { show(error) }
    }

    func answerQuestion(_ request: ProviderQuestionRequest, answers: [String: String]) async {
        guard questions.contains(where: { $0.id == request.id }) else { return }
        do { try await provider.answerQuestion(id: request.id, answers: answers) }
        catch { features.pauseQueue(); turnStatus = .stateUnknown; show(error) }
    }

    func saveDraft() async {
        guard draftLoaded, let conversation = selectedConversation else { return }
        try? await database.saveDraft(draft, conversationID: conversation.id)
    }

    func scheduleDraftSave() {
        draftSaveTask?.cancel()
        let value = draft
        guard draftLoaded, let conversationID = selectedConversation?.id else { return }
        draftSaveTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            try? await database.saveDraft(value, conversationID: conversationID)
        }
    }

    func selectFile(_ node: FileNode) async {
        features.selectedCode = ""; features.selectedLines = nil
        guard !node.isDirectory, let project = selectedProject else { return }
        selectedFile = node
        do { filePreview = try await files.preview(root: project.canonicalPath, relativePath: node.relativePath) }
        catch { filePreview = nil; show(error) }
    }

    func loadChildren(of node: FileNode) async -> [FileNode] {
        guard node.isDirectory, let project = selectedProject else { return [] }
        do { return try await files.children(root: project.canonicalPath, relativePath: node.relativePath) }
        catch { show(error); return [] }
    }

    func refreshGit() async {
        guard inspectorVisible, let project = selectedProject else { return }
        do {
            let snapshot = try await git.status(at: project.canonicalPath)
            guard selectedProject?.id == project.id else { return }
            gitSnapshot = snapshot
        }
        catch { gitSnapshot = GitSnapshot(); diagnosticMessages.append(error.localizedDescription) }
    }

    func selectChange(_ change: GitFileChange) async {
        guard let project = selectedProject else { return }
        selectedChange = change
        do { diffText = try await git.diff(at: project.canonicalPath, path: change.path, staged: change.staged) }
        catch { diffText = error.localizedDescription }
    }

    func restore() async {
        do {
            projects = try await database.projects()
            groups = try await database.groups()
            await loadChats()
            await features.restore()
            maintenanceTask?.cancel()
            maintenanceTask = Task { [weak self] in
                await self?.maintainArchive()
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(3_600)) } catch { return }
                    await self?.maintainArchive()
                }
            }
        } catch { show(error) }
    }

    private func receive(_ event: ProviderEvent) async {
        let eventConversationID = activeConversationID
        switch event {
        case .question(let request):
            questions.removeAll { $0.id == request.id }; questions.append(request); turnStatus = .awaitingUserInput
            append(.init(turnID: request.turnID, kind: .notice, title: "Input requested", text: request.questions.map(\.text).joined(separator: "\n")))
        case .questionResolved(let id):
            questions.removeAll { $0.id == id }
            if questions.isEmpty && turnStatus == .awaitingUserInput { turnStatus = approvals.isEmpty ? .running : .awaitingApproval }
        case .connected(let account):
            connectionStatus = .ready(account: account)
            if browserLoginPending { browserLoginPending = false; accountActionInProgress = false }
            settings.update(settings.provider) { $0.accountLabel = account ?? "Connected account"; $0.verifiedAt = .now }
            accountNotice = "Connected to \(settings.provider.title)."
            if directChatGPT {
                refreshChatGPTAccounts()
                if provider is ChatGPTProvider, !preferences.bool(forKey: "chatGPTPlanWelcomeShown") {
                    showChatGPTPlanWelcome = true; preferences.set(true, forKey: "chatGPTPlanWelcomeShown")
                }
            }
        case .authenticationRequired:
            providerAccount = nil
            if !browserLoginPending { connectionStatus = .notAuthenticated }
            accountNotice = browserLoginPending ? accountNotice : "The provider did not confirm the selected authentication mode. Sign in or choose the matching connection mode."
        case .authenticationFailed(let message):
            browserLoginPending = false; accountActionInProgress = false
            connectionStatus = .notAuthenticated; accountNotice = message
        case .loginURL(let value):
            if let url = URL(string: value), url.scheme == "https", let host = url.host, ["auth.openai.com", "chatgpt.com", "auth0.openai.com"].contains(host) {
                browserLoginPending = true; accountActionInProgress = true; connectionStatus = .signingIn
                accountNotice = "Waiting for browser sign-in. Finish in your browser, or Cancel to try again."
                if !openBrowser(url) {
                    await cancelLogin()
                    accountNotice = "macOS could not open the sign-in page. Check your default browser and try again."
                }
            } else {
                await cancelLogin()
                show(NativeAgentError.providerUnavailable("The provider returned an unrecognized sign-in URL. No browser was opened."))
            }
        case .inspection(let value): providerInspection = value
        case .accountDetails(let value): providerAccount = value
        case .usage(let value): usageWindows = value
        case .usageLimitReached:
            connectionStatus = .usageLimitReached
            accountNotice = "The provider reported a usage limit. Reconnect after it resets. NativeAgent will not switch to API billing."
        case .connectionFailed(let message):
            questions = []
            if activeConversationID != nil { turnStatus = .stateUnknown }
            browserLoginPending = false; accountActionInProgress = false; providerAccount = nil
            connectionStatus = .failed(message); accountNotice = message; approvals = []
        case .approvalResolved(let id): approvals.removeAll { $0.id == id }
        case .models(let value):
            settings.mergeCatalog(value, provider: settings.provider); models = settings.profile(settings.provider).catalog
            reconcileModelSelection()
        case .threadCreated: break
        case .conversationFact(let turnID, let fact): recordFact(fact, turnID: turnID)
        case .turnStarted(let id):
            if activeTurnID != id { factIDs = [:] }
            turnStatus = .running; activeTurnID = id; streamingEntry = nil; bufferedDelta = ""; setActiveUserTurnID(id)
            recordFact(.init(key: "turn-status", category: .status, title: "Task status", text: "Working", state: "running"), turnID: id)
        case .agentDelta(let turnID, let text): buffer(text, turnID: turnID)
        case .agentMessage(let turnID, let text): let streamedText = finishStreaming(); if !text.isEmpty && streamedText != text { append(.init(turnID: turnID, kind: .agentMessage, title: "Agent", text: text)) }
        case .command(let turnID, let title, let output, let exitCode): append(.init(turnID: turnID, kind: .command, title: title, text: limited(output), detail: exitCode.map { "Exit code \($0)" }))
        case .fileChange(let turnID, let path, let summary): append(.init(turnID: turnID, kind: .fileChange, title: path, text: summary))
        case .approval(let approval): approvals.append(approval); turnStatus = .awaitingApproval
        case .turnCompleted(let turnID, let status, let error):
            questions = []
            recordFact(.init(key: "turn-status", category: .status, title: "Task status", text: status.label, state: status.rawValue), turnID: turnID ?? activeTurnID)
            approvals = []
            _ = finishStreaming()
            turnStatus = status
            if let error { append(.init(kind: .error, title: "Turn failed", text: error), conversationID: activeConversationID) }
            activeConversationID = nil
            activeUserEntry = nil
            activeThreadID = nil
            activeTurnID = nil
            await refreshGit()
        case .diagnostic(let text): diagnosticMessages.append(limited(text)); if diagnosticMessages.count > 100 { diagnosticMessages.removeFirst() }
        }
        await features.handle(event, conversationID: eventConversationID)
    }

    func flushPendingPersistence() async { await persistenceTask?.value }

    private func buffer(_ text: String, turnID: String?) {
        bufferedDelta += text
        if streamingEntry == nil {
            let entry = TimelineEntry(turnID: turnID, kind: .agentMessage, title: "Agent", text: "", isStreaming: true)
            streamingEntry = entry
            if selectedConversation?.id == activeConversationID && !hasNewerMessages { timeline.append(entry); trimLiveTimeline() }
        }
        guard streamFlushTask == nil else { return }
        streamFlushTask = Task {
            let constrained = ProcessInfo.processInfo.isLowPowerModeEnabled || ProcessInfo.processInfo.thermalState == .serious || ProcessInfo.processInfo.thermalState == .critical
            try? await Task.sleep(for: .milliseconds(constrained ? 300 : 100))
            guard !Task.isCancelled else { return }
            self.flushDelta()
        }
    }

    private func flushDelta() {
        streamFlushTask?.cancel()
        streamFlushTask = nil
        guard !bufferedDelta.isEmpty, var entry = streamingEntry else { return }
        entry.text += bufferedDelta
        bufferedDelta = ""
        streamingEntry = entry
        if let index = timeline.firstIndex(where: { $0.id == entry.id }) { timeline[index] = displayEntry(entry) }
        if Date.now.timeIntervalSince(lastStreamSave) >= 1 {
            persist(entry, conversationID: activeConversationID)
            lastStreamSave = .now
        }
    }

    @discardableResult
    private func finishStreaming() -> String? {
        flushDelta()
        guard var entry = streamingEntry else { return nil }
        entry.isStreaming = false
        streamingEntry = entry
        if let index = timeline.firstIndex(where: { $0.id == entry.id }) { timeline[index] = displayEntry(entry) }
        persist(entry, conversationID: activeConversationID)
        streamingEntry = nil
        return entry.text
    }

    private func setActiveUserTurnID(_ id: String) {
        guard var entry = activeUserEntry else { return }
        entry.turnID = id
        activeUserEntry = entry
        if let index = timeline.firstIndex(where: { $0.id == entry.id }) { timeline[index] = displayEntry(entry) }
        persist(entry, conversationID: activeConversationID)
    }

    private func append(_ entry: TimelineEntry, conversationID: UUID? = nil) {
        let target = conversationID ?? activeConversationID ?? selectedConversation?.id
        if selectedConversation?.id == target && !hasNewerMessages { timeline.append(displayEntry(entry)); trimLiveTimeline() }
        persist(entry, conversationID: target)
    }

    private func persist(_ entry: TimelineEntry, conversationID: UUID?) {
        guard let conversationID else { return }
        if !entry.isStreaming, entry.kind != .userMessage, selectedConversation?.id == conversationID {
            summaryConversationID = conversationID
            var summary = entry
            summary.text = String(entry.text.prefix(600)); summary.textIsPreview = entry.text.count > 600
            if let index = detailEntries.firstIndex(where: { $0.id == entry.id }) { detailEntries[index] = summary }
            else { detailEntries.append(summary) }
            if detailEntries.count > 200 { detailEntries.removeFirst(detailEntries.count - 200) }
        }
        let previous = persistenceTask, database = database
        persistenceTask = Task { [weak self] in
            await previous?.value
            do {
                try await database.save(entry: entry, conversationID: conversationID)
                if entry.kind == .userMessage, self?.selectedConversation?.id == conversationID {
                    // Launch after this persistence task completes; never await ourselves.
                    Task { [weak self] in await self?.refreshConversationSummaries() }
                }
            }
            catch { self?.show(error) }
        }
    }

    private func trimLiveTimeline() {
        if timeline.count > 200 { timeline.removeFirst(timeline.count - 200); hasOlderMessages = true }
    }

    private func displayEntry(_ entry: TimelineEntry) -> TimelineEntry {
        guard entry.text.prefix(8_001).count > 8_000 else { return entry }
        var preview = entry
        preview.text = String(entry.text.prefix(8_000))
        preview.textIsPreview = true
        return preview
    }

    private func limited(_ text: String) -> String {
        let limit = 2 * 1_024 * 1_024
        guard text.utf8.count > limit else { return text }
        return String(text.prefix(limit)) + "\n\n[Older output omitted at the 2 MiB display limit]"
    }

    private func confirmTrustIfNeeded(for project: Project) -> Bool {
        let key = "trustedProjectIDs"
        var trusted = Set(preferences.stringArray(forKey: key) ?? [])
        guard !trusted.contains(project.id.uuidString) else { return true }
        let alert = NSAlert()
        alert.messageText = "Trust this project?"
        alert.informativeText = "Agent runs can read project instructions, execute commands, and request file changes inside:\n\n\(project.canonicalPath)\n\nReview unfamiliar repositories for hooks and executable configuration before continuing."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Trust and Continue")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        trusted.insert(project.id.uuidString)
        preferences.set(Array(trusted), forKey: key)
        return true
    }

    private func show(_ error: Error) { errorMessage = error.localizedDescription }
}
