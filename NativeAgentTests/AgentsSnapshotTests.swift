import AppKit
import SwiftUI
import XCTest
@testable import NativeAgent

final class AgentsSnapshotTests: XCTestCase {
    @MainActor
    func testSettingsEditorAndAcceptedMentionsInBothThemes() async throws {
        guard let destination = ProcessInfo.processInfo.environment["NATIVEAGENT_SNAPSHOT_DIR"] else { throw XCTSkip("Set NATIVEAGENT_SNAPSHOT_DIR to render agents.") }
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "AgentsSnapshots.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let database = try DatabaseActor(url: directory.appendingPathComponent("fixture.sqlite3"))
        let model = WorkspaceViewModel(provider: SettingsTestProvider(), database: database, files: FileService(), git: GitService(), automaticallyRestore: false,
            preferences: defaults, credentials: MemoryCredentials(), chatGPTCredentials: MemoryChatGPTCredentials(), aiTokens: MemoryAITokens())
        let connection = AIConnection(name: "Project AI", baseURL: "https://example.invalid/v1", model: "configured-model")
        try model.saveAIConnection(connection, token: "fixture-token")
        let profile = AgentProfile(name: "Accessibility expert", handle: "accessibility", summary: "Review interfaces for keyboard access, contrast and screen readers.", connectionID: connection.id.uuidString,
            instructions: "Review the supplied interface for accessibility. Explain the user impact and suggest concrete fixes.", reference: "Our audience uses both keyboard navigation and VoiceOver.", outputStyle: "Prioritized findings with clear examples.", delegation: .automatic)
        try model.agents.save(profile)
        model.settings.accent = .mint
        let chat = Conversation(title: "Review our new interface"); try await database.save(conversation: chat); model.selectedConversation = chat
        model.draft = "@accessibility Review the navigation and account settings."
        XCTAssertTrue(model.canSend); XCTAssertEqual(model.mentionedAgents.map(\.id), [profile.id])
        try FileManager.default.createDirectory(atPath: destination, withIntermediateDirectories: true)
        for dark in [true, false] {
            model.settings.theme = dark ? .dark : .light
            let suffix = dark ? "dark" : "light"
            try await render(SettingsHub(model: model, settings: model.settings, page: .agents).environmentObject(AppUpdater()), name: "agents-settings-" + suffix, size: NSSize(width: 940, height: 740), dark: dark, destination: destination)
            try await render(AgentEditorView(model: model, store: model.agents, profile: profile), name: "agent-editor-" + suffix, size: NSSize(width: 728, height: 788), dark: dark, destination: destination)
            try await render(ConversationView().environmentObject(model), name: "agent-mention-" + suffix, size: NSSize(width: 1000, height: 760), dark: dark, destination: destination)
            try await render(ComposerActionsView(dismiss: {}, query: "access", agentsOnly: .constant(true), highlightedID: profile.recipientID).environmentObject(model), name: "agent-picker-" + suffix, size: NSSize(width: 580, height: 350), dark: dark, destination: destination)
        }
        await model.shutdown()
    }
    @MainActor
    private func render<Content: View>(_ content: Content, name: String, size: NSSize, dark: Bool, destination: String) async throws {
        let view = NSHostingView(rootView: content.frame(width: size.width, height: size.height, alignment: .top).background(Studio.canvas).environment(\.colorScheme, dark ? .dark : .light))
        view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view; window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        try await Task.sleep(for: .milliseconds(250)); view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds)); view.cacheDisplay(in: view.bounds, to: bitmap)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: destination).appendingPathComponent(name + ".png"))
        XCTAssertGreaterThan(data.count, 10_000)
    }
}
