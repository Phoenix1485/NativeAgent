import AppKit
import SwiftUI
import XCTest
@testable import NativeAgent

final class UsageSettingsSnapshotTests: XCTestCase {
    @MainActor
    func testUsageDashboardInLightAndDark() async throws {
        guard let destination = ProcessInfo.processInfo.environment["NATIVEAGENT_SNAPSHOT_DIR"] else {
            throw XCTSkip("Set NATIVEAGENT_SNAPSHOT_DIR to render the usage dashboard.")
        }
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "UsageSnapshots.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let database = try DatabaseActor(url: directory.appendingPathComponent("usage.sqlite3"))
        let model = WorkspaceViewModel(provider: SettingsTestProvider(), database: database, files: FileService(), git: GitService(), automaticallyRestore: false, preferences: defaults, credentials: MemoryCredentials(), chatGPTCredentials: MemoryChatGPTCredentials(), aiTokens: MemoryAITokens())
        let chat = Conversation(title: "Website release and accessibility review")
        try await database.save(conversation: chat)
        model.selectedConversation = chat
        model.settings.accent = .mint
        let now = Date.now.addingTimeInterval(-60)
        let providers = ["OpenAI", "Anthropic", "Custom connection"]
        let names = ["gpt-5.4", "claude-sonnet-4-6", "local-model"]
        for index in 0..<9 {
            let provider = index % 3
            try await database.recordUsage(UsageRecord(id: "fixture-\(index)", recordedAt: now.addingTimeInterval(-Double(index) * 86_400), provider: providers[provider], model: names[provider], source: "Fixture", activity: index % 2 == 0 ? "Chat" : "Code review", conversationID: index < 5 ? chat.id : nil,
                                                       tokens: index == 2 ? nil : UsageTokens(inputTokens: Int64((index + 1) * 1_240), outputTokens: Int64((index + 1) * 310), cachedInputTokens: Int64(index * 500), cacheWriteInputTokens: 250, reasoningOutputTokens: Int64(index * 100)), contextTokens: index == 0 ? 46_200 : nil, contextLimit: index == 0 ? 128_000 : nil))
        }
        model.usageWindows = [ProviderUsageWindow(id: "primary", usedPercent: 34, resetsAt: now.addingTimeInterval(3_600), durationMinutes: 300)]
        await model.usage.load(conversationID: chat.id)
        XCTAssertEqual(model.usage.summary?.totals.recordCount, 9)
        XCTAssertEqual(model.usage.summary?.totals.missingCount, 1)
        try FileManager.default.createDirectory(atPath: destination, withIntermediateDirectories: true)
        for dark in [true, false] {
            model.settings.theme = dark ? .dark : .light
            let settings = SettingsHub(model: model, settings: model.settings, page: .usage).environmentObject(AppUpdater())
            try await render(settings, name: "usage-settings" + (dark ? "-dark" : "-light"), dark: dark, destination: destination, size: NSSize(width: 940, height: 690))
            let full = UsageSettingsView(controller: model.usage, selectedConversation: chat, quotaWindows: model.usageWindows)
                .padding(28).accentColor(model.settings.accent.color).tint(model.settings.accent.color)
            try await render(full, name: "usage-dashboard" + (dark ? "-dark" : "-light"), dark: dark, destination: destination, size: NSSize(width: 720, height: 2_900))
        }
        await model.shutdown()
    }

    @MainActor
    private func render<Content: View>(_ content: Content, name: String, dark: Bool, destination: String, size: NSSize) async throws {
        let view = NSHostingView(rootView: content.frame(width: size.width, height: size.height, alignment: .top).background(Studio.canvas).environment(\.colorScheme, dark ? .dark : .light))
        view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        try await Task.sleep(for: .milliseconds(350))
        view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: destination).appendingPathComponent(name + ".png"))
        XCTAssertEqual(Int(view.bounds.width), Int(size.width))
        XCTAssertEqual(Int(view.bounds.height), Int(size.height))
        XCTAssertGreaterThan(data.count, 10_000)
    }
}
