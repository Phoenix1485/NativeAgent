import AppKit
import SwiftUI
import XCTest
@testable import NativeAgent

/// Opt-in renders of the actual SwiftUI view with a temporary, offline library.
final class WorkspaceSnapshotTests: XCTestCase {
    @MainActor
    func testRenderAIConnectionsAndComposerActions() async throws {
        guard let destination = ProcessInfo.processInfo.environment["NATIVEAGENT_SNAPSHOT_DIR"] else { throw XCTSkip("Set NATIVEAGENT_SNAPSHOT_DIR for UI renders.") }
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "NativeAgentAISnapshots.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = WorkspaceViewModel(provider: SettingsTestProvider(), database: try DatabaseActor(url: directory.appendingPathComponent("preview.sqlite3")), files: FileService(), git: GitService(), automaticallyRestore: false, preferences: defaults, credentials: MemoryCredentials(), chatGPTCredentials: MemoryChatGPTCredentials(), aiTokens: MemoryAITokens())
        for name in ["Claude", "Grok", "DeepSeek"] {
            try model.saveAIConnection(.init(name: name, baseURL: "https://example.invalid/v1", model: "fixture-model"), token: "fake-token")
        }
        model.selectedAIRecipients = Set(model.aiRecipients.prefix(2).map(\.id))
        try FileManager.default.createDirectory(atPath: destination, withIntermediateDirectories: true)
        for dark in [true, false] {
            let suffix = dark ? "dark" : "light"
            try renderView(ComposerActionsView(dismiss: {}, query: "").environmentObject(model), name: "ai-actions-" + suffix, dark: dark, destination: destination, size: NSSize(width: 580, height: 490))
            try renderView(AIConnectionsView().environmentObject(model).padding(24), name: "ai-settings-" + suffix, dark: dark, destination: destination, size: NSSize(width: 650, height: 540))
        }
        model.draft = "Review this question @"
        try render(model, name: "ai-composer-workspace", dark: true, destination: destination, size: NSSize(width: 1100, height: 820))
    }

    @MainActor
    func testScrollLoadsOnlyRequestedHistoryPageAndRendersSkeleton() async throws {
        guard let destination = ProcessInfo.processInfo.environment["NATIVEAGENT_SNAPSHOT_DIR"] else {
            throw XCTSkip("Set NATIVEAGENT_SNAPSHOT_DIR to verify native scrolling and render skeletons.")
        }
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "NativeAgentLoadingSnapshots.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let database = try DatabaseActor(url: directory.appendingPathComponent("loading.sqlite3"))
        let model = WorkspaceViewModel(provider: SettingsTestProvider(), database: database, files: FileService(), git: GitService(), automaticallyRestore: false, preferences: defaults, credentials: MemoryCredentials(), chatGPTCredentials: MemoryChatGPTCredentials())
        let chat = Conversation(title: "Long chat fixture")
        try await database.save(conversation: chat)
        for index in 1...300 {
            try await database.save(entry: .init(kind: .userMessage, title: "You", text: "Message \(index)"), conversationID: chat.id)
        }
        try FileManager.default.createDirectory(atPath: destination, withIntermediateDirectories: true)
        model.selectedConversation = chat; model.historyLoading = true
        try renderView(ConversationView().environmentObject(model), name: "chat-skeleton-dark", dark: true, destination: destination, size: NSSize(width: 800, height: 600))
        try renderView(ConversationSkeleton(rows: 1, label: "Loading earlier messages…").padding(24), name: "chat-page-skeleton-light", dark: false, destination: destination, size: NSSize(width: 600, height: 150))
        model.historyLoading = false
        await model.select(chat)
        let view = NSHostingView(rootView: ConversationView().environmentObject(model).frame(width: 800, height: 600))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        defer { window.orderOut(nil) }
        view.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(250))
        func findObserver(_ root: NSView) -> TimelineScrollActivity.ObserverView? {
            if let observer = root as? TimelineScrollActivity.ObserverView { return observer }
            return root.subviews.lazy.compactMap { findObserver($0) }.first
        }
        let observer = try XCTUnwrap(findObserver(view))
        let scroll = try XCTUnwrap(observer.enclosingScrollView)
        observer.attach()
        XCTAssertEqual(model.timeline.count, 40, "Opening and layout must not eagerly load older messages")
        XCTAssertEqual(model.timeline.last?.text, "Message 300")
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
        let top: CGFloat = scroll.documentView?.isFlipped == true ? 0 : max(0, (scroll.documentView?.bounds.height ?? 0) - scroll.contentView.bounds.height)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: top)); scroll.reflectScrolledClipView(scroll.contentView)
        NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: scroll)
        for _ in 0..<100 where model.timeline.count == 40 { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(model.timeline.count, 80, "User scrolling near the top requests one page")
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(model.timeline.count, 80, "Page insertion and anchor restoration cannot cascade into more loads")
        XCTAssertEqual(model.timeline.first?.text, "Message 221")
        await model.shutdown()
    }

    @MainActor
    func testRenderModelPicker() async throws {
        guard let destination = ProcessInfo.processInfo.environment["NATIVEAGENT_SNAPSHOT_DIR"] else {
            throw XCTSkip("Set NATIVEAGENT_SNAPSHOT_DIR to render visual verification images.")
        }
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "NativeAgentPickerSnapshots.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = WorkspaceViewModel(provider: SettingsTestProvider(), database: try DatabaseActor(url: directory.appendingPathComponent("preview.sqlite3")), files: FileService(), git: GitService(), automaticallyRestore: false, preferences: defaults, credentials: MemoryCredentials())
        let item = ProviderModel(id: "fixture-astra", displayName: "GPT-6 Astra", reasoningEfforts: ["low", "medium", "high", "xhigh", "max"], defaultReasoningEffort: "medium")
        model.settings.update(.codex) { $0.catalog = [item, .init(id: "fixture-sol", displayName: "GPT-5.6 Sol"), .init(id: "fixture-terra", displayName: "GPT-5.6 Terra"), .init(id: "fixture-luna", displayName: "GPT-5.6 Luna")] }
        model.selectedModelID = item.id; model.selectedReasoning = "high"
        try FileManager.default.createDirectory(atPath: destination, withIntermediateDirectories: true)
        for dark in [true, false] {
            let accent = dark ? AccentChoice.violet : .mint
            let suffix = dark ? "dark" : "light"
            try renderView(ChatModelPickerPanel(showingEffort: .constant(false), dismiss: {}).environmentObject(model).accentColor(accent.color), name: "model-list-" + suffix, dark: dark, destination: destination, size: NSSize(width: 340, height: 365))
            try renderView(ChatModelPickerPanel(showingEffort: .constant(true), dismiss: {}).environmentObject(model).accentColor(accent.color), name: "model-effort-" + suffix, dark: dark, destination: destination, size: NSSize(width: 340, height: 230))
            try renderView(ChatModelPicker().environmentObject(model).accentColor(accent.color), name: "model-pill-" + suffix, dark: dark, destination: destination, size: NSSize(width: 320, height: 60))
        }
        model.selectedReasoning = ""
        try renderView(ModelEffortControl(model: item, selection: .constant("")).accentColor(AccentChoice.violet.color), name: "model-effort-auto", dark: true, destination: destination, size: NSSize(width: 340, height: 200))
        try renderView(ModelEffortControl(model: .init(id: "unknown", displayName: "Provider-managed model"), selection: .constant("")), name: "model-effort-unavailable", dark: true, destination: destination, size: NSSize(width: 340, height: 180))
        try render(model, name: "model-picker-small-workspace", dark: true, destination: destination, size: NSSize(width: 900, height: 620))
    }

    @MainActor
    func testRenderWorkspace() async throws {
        guard let destination = ProcessInfo.processInfo.environment["NATIVEAGENT_SNAPSHOT_DIR"] else {
            throw XCTSkip("Set NATIVEAGENT_SNAPSHOT_DIR to render visual verification images.")
        }
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try DatabaseActor(url: directory.appendingPathComponent("preview.sqlite3"))
        let suite = "NativeAgentSnapshots.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = WorkspaceViewModel(provider: CodexProvider(binaryPath: "/does-not-exist"), database: database, files: FileService(), git: GitService(), automaticallyRestore: false, preferences: defaults, credentials: MemoryCredentials())
        model.settings.update(.codex) { $0.binaryPath = "/not-installed" }
        try FileManager.default.createDirectory(atPath: destination, withIntermediateDirectories: true)
        try render(model, name: "welcome-dark", dark: true, destination: destination)
        try render(model, name: "welcome-light", dark: false, destination: destination)
        let root = ChatGroup(name: "Studio website")
        let child = ChatGroup(parentID: root.id, name: "Frontend")
        let nested = ChatGroup(parentID: child.id, name: "Components")
        model.groups = [root, child, nested, ChatGroup(name: "Side projects")]
        model.expandedGroupIDs = Set(model.groups.map(\.id))
        model.conversations = [Conversation(groupID: root.id, title: "Plan the redesign"), Conversation(groupID: child.id, title: "Build the navigation"), Conversation(groupID: nested.id, title: "Button variants"), Conversation(title: "A new idea"), Conversation(title: "Explore Swift concurrency")]
        model.selectedGroupID = root.id
        try render(model, name: "groups-dark", dark: true, destination: destination)
        let longChat = Conversation(title: "Improve sidebar hover menus and conversation titles without losing the original chat")
        model.conversations.append(longChat)
        try render(model, name: "long-chat-title", dark: true, destination: destination)
        model.renameConversation(longChat)
        try render(model, name: "inline-chat-rename", dark: true, destination: destination)
        model.renamingConversationID = nil
        try await database.save(conversation: longChat)
        try await database.setChatAttention(longChat.id, pinned: true, unread: true)
        await model.refreshChatAttention()
        try render(model, name: "pinned-unread-chat", dark: true, destination: destination)
        try render(model, name: "groups-small", dark: false, destination: destination, size: NSSize(width: 900, height: 620))
        model.selectedConversation = model.conversations.first
        model.timeline = [
            TimelineEntry(kind: .userMessage, title: "You", text: "Let's simplify the navigation and make the workspace feel lighter."),
            TimelineEntry(kind: .agentMessage, title: "NativeAgent", text: "I'll start with the sidebar and the main workspace. Related chats will live together, with room for folders as your project grows.")
        ]
        try render(model, name: "conversation-dark", dark: true, destination: destination)
        let originalTimeline = model.timeline
        for index in 1...12 {
            model.timeline.append(.init(kind: .userMessage, title: "You", text: "Iteration \(index): refine the navigation and preserve keyboard access."))
            model.timeline.append(.init(kind: .agentMessage, title: "NativeAgent", text: "Updated the navigation layout and checked its message identifiers."))
        }
        let plan = ConversationFact(key: "plan", category: .plan, title: "Task plan", text: "Completed: inspect navigation\nCompleted: add prompt markers\nIn progress: verify accessibility")
        let source = ConversationFact(key: "source", category: .source, title: "Sources/Navigation.swift", text: "File referenced by a provider-reported read action.", path: "Sources/Navigation.swift")
        model.timeline += [
            .init(kind: .fact, title: plan.title, text: plan.text, detail: plan.encoded),
            .init(kind: .fileChange, title: "Sources/Navigation.swift", text: "@@ -1 +1 @@\n-old navigation\n+accessible navigation"),
            .init(kind: .fact, title: source.title, text: source.text, detail: source.encoded)
        ]
        try render(model, name: "conversation-minimap", dark: true, destination: destination)
        try render(model, name: "conversation-minimap-small", dark: false, destination: destination, size: NSSize(width: 900, height: 620))
        for section in ["Progress", "Results", "Sources"] {
            try renderView(ConversationDetailsView(section: section).environmentObject(model), name: "conversation-details-" + section.lowercased(), dark: true, destination: destination, size: NSSize(width: 390, height: 460))
        }
        model.timeline = originalTimeline
        let project = Project(name: "Feature preview", canonicalPath: directory.path)
        try await database.save(project: project)
        model.projects = [project]; model.selectedProject = project
        model.features.templates = PromptTemplate.starters
        model.features.profile = ProjectProfile(id: project.id, workingDirectory: directory.path)
        model.features.context = [.init(kind: .code, title: "Navigation.swift", text: "let selection = currentMessage.id", path: "Navigation.swift", startLine: 12, endLine: 12)]
        for command in [WorkspaceCommand.dashboard, .profiles, .templates, .context, .memory, .queue, .reports, .search] {
            model.features.panel = command
            try renderView(FeaturePanel(features: model.features).environmentObject(model), name: "feature-" + command.rawValue, dark: true, destination: destination, size: NSSize(width: 760, height: 650))
        }
        model.features.panel = nil
        try await database.saveProjectMemory(.init(frameworks: "SwiftUI and SQLite", conventions: "Use actors for data access", goals: "Reliable local workspace", decisions: "Keep credentials in Keychain", avoidances: "No automatic cloud sync"), projectID: project.id)
        try renderView(Form { ProjectMemoryEditor(projectID: project.id) }.formStyle(.grouped).environmentObject(model), name: "project-memory", dark: true, destination: destination, size: NSSize(width: 700, height: 650))
        try renderView(WhatsNewView(), name: "whats-new", dark: true, destination: destination, size: NSSize(width: 570, height: 600))
        try renderView(WorkspaceCommandPalette(features: model.features).environmentObject(model), name: "command-palette", dark: true, destination: destination, size: NSSize(width: 600, height: 440))
        try renderView(GroupEditorView(request: GroupEditorRequest(parentID: root.id)).environmentObject(model), name: "new-folder", dark: true, destination: destination, size: NSSize(width: 486, height: 500))
        try renderView(SettingsHub(model: model, settings: model.settings, onboarding: true), name: "onboarding", dark: true, destination: destination, size: NSSize(width: 940, height: 690))
        model.settings.update(.codex) {
            $0.catalog = [.init(id: "fast-model", displayName: "Fast model", reasoningEfforts: ["low", "medium", "high"]), .init(id: "deep-model", displayName: "Deep model", reasoningEfforts: ["medium", "high", "xhigh"]), .init(id: "compact-model", displayName: "Compact model")]
            $0.starredModels = ["deep-model"]; $0.disabledModels = ["compact-model"]; $0.defaultModelID = "deep-model"; $0.reasoning["deep-model"] = "high"
        }
        try renderView(SettingsHub(model: model, settings: model.settings, page: .models), name: "settings-models", dark: true, destination: destination, size: NSSize(width: 940, height: 690))
        try renderView(SettingsHub(model: model, settings: model.settings, page: .configuration), name: "settings-configuration", dark: true, destination: destination, size: NSSize(width: 940, height: 690))
        try renderView(SettingsHub(model: model, settings: model.settings, page: .updates), name: "settings-updates", dark: true, destination: destination, size: NSSize(width: 940, height: 690))
        try renderView(SettingsHub(model: model, settings: model.settings, page: .plugins), name: "settings-plugins", dark: true, destination: destination, size: NSSize(width: 940, height: 690))
        let file = AttachedFileSnapshot(url: directory.appendingPathComponent("Example.swift"), data: Data("import SwiftUI\n\nstruct Example: View {\n    var body: some View { Text(\"Hello\") }\n}\n".utf8))
        try renderView(AttachedFileEditor(file: file, features: model.features).environmentObject(model), name: "file-editor", dark: true, destination: destination, size: NSSize(width: 820, height: 620))
        model.settings.mergeCatalog([.init(id: "sonnet", displayName: "Claude Sonnet", reasoningEfforts: ["low", "medium", "high"])], provider: .claude)
        model.settings.provider = .claude
        model.selectedModelID = "sonnet"
        model.selectedConversation?.remoteThreadID = "preview-only"
        model.hasOlderMessages = true
        try render(model, name: "provider-switch", dark: true, destination: destination)
        for (title, days) in [("Website launch checklist", 4.0), ("Earlier navigation exploration", 29.0)] {
            let chat = Conversation(title: title)
            try await database.save(conversation: chat)
            try await database.archiveConversation(id: chat.id, now: Date.now.addingTimeInterval(-days * 86_400))
        }
        await model.loadArchive()
        try renderView(ArchiveView(automaticallyLoad: false).environmentObject(model), name: "archive-dark", dark: true, destination: destination, size: NSSize(width: 640, height: 520))
        try renderView(ArchiveView(automaticallyLoad: false).environmentObject(model), name: "archive-light", dark: false, destination: destination, size: NSSize(width: 640, height: 520))
        try renderView(LongMessageView(text: (1...1_000).map { "Line \($0): A long message stays in a bounded, selectable native text viewport." }.joined(separator: "\n")), name: "expanded-long-message", dark: true, destination: destination, size: NSSize(width: 640, height: 360))
        model.settings.theme = .light; model.settings.accent = .mint
        try renderView(SettingsHub(model: model, settings: model.settings, page: .appearance), name: "settings-appearance", dark: false, destination: destination, size: NSSize(width: 940, height: 690))
    }

    @MainActor
    private func render(_ model: WorkspaceViewModel, name: String, dark: Bool, destination: String, size: NSSize = NSSize(width: 1280, height: 820)) throws {
        try renderView(WorkspaceView().environmentObject(model).environmentObject(AppUpdater()), name: name, dark: dark, destination: destination, size: size)
    }

    @MainActor
    private func renderView<Content: View>(_ root: Content, name: String, dark: Bool, destination: String, size: NSSize) throws {
        let view = NSHostingView(rootView: root.environmentObject(AppUpdater()).frame(width: size.width, height: size.height).background(Studio.canvas).environment(\.colorScheme, dark ? .dark : .light))
        view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        view.frame = NSRect(origin: .zero, size: size)
        view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return XCTFail("No bitmap") }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let image = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try image.write(to: URL(fileURLWithPath: destination).appendingPathComponent(name + ".png"))
        XCTAssertEqual(Int(view.bounds.width), Int(size.width))
        XCTAssertEqual(Int(view.bounds.height), Int(size.height))
        window.orderOut(nil)
    }
}
