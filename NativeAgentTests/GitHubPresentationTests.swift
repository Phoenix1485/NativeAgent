import AppKit
import SwiftUI
import XCTest
@testable import NativeAgent

private struct GitHubPreviewRunner: GitCommandRunning {
    let root: String
    func run(_ command: GitCommand, progress: (@Sendable (String) -> Void)?) async throws -> GitCommandResult {
        let args = command.arguments
        var text = "", status: Int32 = 0
        let sha = String(repeating: "a", count: 40)
        if args == ["--version"] { text = "gh version 2.88.0\n" }
        else if args.starts(with: ["auth", "status"]) { text = "Logged in to github.com account example (keyring)\n" }
        else if args.contains(".login") { text = "example\n" }
        else if args.starts(with: ["pr", "list"]) {
            text = """
            [{"number":12,"title":"Improve project navigation","url":"https://github.com/example/workspace/pull/12","headRefName":"feature/navigation","baseRefName":"main","headRefOid":"\(sha)","isDraft":false,"mergeStateStatus":"CLEAN","state":"OPEN"}]
            """
        } else if args.contains("--show-toplevel") { text = root + "\n" }
        else if args.contains("symbolic-ref") { text = "feature/navigation\n" }
        else if args.contains("MERGE_HEAD") { status = 1 }
        else if args.contains("@{upstream}") { text = "origin/feature/navigation\n" }
        else if args.contains("get-url") { text = "https://github.com/example/workspace.git\n" }
        else if args.contains("--verify") { text = sha + "\n" }
        else if args.contains("rev-list") { text = "2\t0\n" }
        else if args.contains("status") { text = "## feature/navigation...origin/feature/navigation [ahead 2]\0 M Sources/WorkspaceView.swift\0A  Tests/NavigationTests.swift\0?? README.md\0" }
        else if args.contains("for-each-ref") { text = "feature/navigation\0*\0origin/feature/navigation\0\(sha)\0refs/heads/feature/navigation\nmain\0 \0origin/main\0\(sha)\0refs/heads/main\n" }
        else if args.contains("log") { text = "\(sha)\0Remember open file tabs\0Example User\02026-10-17T12:00:00Z\0" }
        else if args.contains("diff") { text = "--- a/Sources/WorkspaceView.swift\n+++ b/Sources/WorkspaceView.swift\n@@ -1,4 +1,7 @@\n import SwiftUI\n \n struct WorkspaceView: View {\n+    @State private var openFiles: [URL] = []\n+    @State private var showChat = true\n+\n     var body: some View {\n+        HSplitView { conversation; fileBrowser }\n     }\n }\n" }
        return .init(status: status, stdout: Data(text.utf8), stderr: Data())
    }
}

@MainActor
final class GitHubPresentationTests: XCTestCase {
    func testRenderGitHubWorkspaceAndAnswerComparison() async throws {
        guard let destination = ProcessInfo.processInfo.environment["NATIVEAGENT_SNAPSHOT_DIR"] else { throw XCTSkip("Set NATIVEAGENT_SNAPSHOT_DIR to render GitHub and answer comparison.") }
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "GitHubPreview.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let database = try DatabaseActor(url: root.appendingPathComponent("library.sqlite3"))
        let model = WorkspaceViewModel(provider: SettingsTestProvider(), database: database, files: FileService(), git: GitService(), automaticallyRestore: false, preferences: defaults, credentials: MemoryCredentials(), chatGPTCredentials: MemoryChatGPTCredentials(), aiTokens: MemoryAITokens(), apiCompletion: { connection, _, _, _ in
            "Review from \(connection.name)\n\nThe changes preserve the selected file while opening another view. Keep each window’s scroll position independent.\n\nAdd a regression for switching tabs after horizontal scrolling. No test execution was included in the supplied diff."
        })
        let project = Project(name: "Example workspace", canonicalPath: root.path)
        try await database.save(project: project)
        model.projects = [project]; model.selectedProject = project
        let gh = root.appendingPathComponent("gh")
        try Data().write(to: gh); try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: gh.path)
        let controller = GitHubController(service: GitHubService(runner: GitHubPreviewRunner(root: root.path), configuredCLIPath: gh.path), preferences: defaults)
        await controller.refreshAuth(); await controller.setProject(root: root.path); await controller.compare(.working())
        XCTAssertNil(controller.error); XCTAssertEqual(controller.snapshot?.changes.count, 3)
        let chat = Conversation(projectID: project.id, title: "Compare navigation approaches")
        try await database.save(conversation: chat); model.selectedConversation = chat
        for (name, text) in [
            ("Claude · configured API", "Use one shared file selection and separate viewport state per window.\n\nThis keeps the file navigator consistent while allowing independent scrolling. Test tab switching, long lines, and changes to the selected project."),
            ("Custom · configured model", "A shared tab list works well. Each window should retain its own scroll and selection state.\n\nI would also cancel stale preview loads when the project changes and keep keyboard focus local to the active window.")
        ] {
            let entry = TimelineEntry(turnID: "comparison", kind: .agentMessage, title: name, text: text)
            try await database.save(entry: entry, conversationID: chat.id)
            model.timeline.append(entry); model.assistant.comparisonSelection.insert(entry.id)
        }
        try FileManager.default.createDirectory(atPath: destination, withIntermediateDirectories: true)
        var reviewerIDs: Set<String> = []
        for name in ["Claude API", "Custom AI"] {
            let connection = AIConnection(name: name, baseURL: "https://fixture.invalid/v1", model: "fixture-model")
            try model.saveAIConnection(connection, token: "fixture-token")
            reviewerIDs.insert(connection.id.uuidString)
        }
        for dark in [true, false] {
            model.settings.theme = dark ? .dark : .light
            model.settings.accent = dark ? .violet : .mint
            try await render(GitHubWorkspaceView(model: model, controller: controller).environmentObject(model), size: NSSize(width: 1012, height: 692), dark: dark, path: URL(fileURLWithPath: destination).appendingPathComponent("github-\(dark ? "dark" : "light").png"))
            try await render(AIComparisonView(model: model, assistant: model.assistant), size: NSSize(width: 712, height: 560), dark: dark, path: URL(fileURLWithPath: destination).appendingPathComponent("answer-comparison-\(dark ? "dark" : "light").png"))
            let request = AIAssistanceRequest(purpose: .review, source: "Selected staged diff", content: controller.diff, projectPath: root.path)
            try await render(AIAssistanceView(assistant: model.assistant, request: request, onUse: { _ in }, sourceExpanded: true).environmentObject(model), size: NSSize(width: 868, height: 748), dark: dark, path: URL(fileURLWithPath: destination).appendingPathComponent("ai-review-expanded-\(dark ? "dark" : "light").png"), afterAppear: {
                model.assistant.selectedRecipients = reviewerIDs
                model.assistant.run()
                for _ in 0..<100 where model.assistant.isRunning { try await Task.sleep(for: .milliseconds(10)) }
                XCTAssertFalse(model.assistant.isRunning)
                XCTAssertEqual(model.assistant.answers.compactMap(\.text).count, 2)
            })
        }
        await model.shutdown()
    }

    private func render<V: View>(_ content: V, size: NSSize, dark: Bool, path: URL, afterAppear: (() async throws -> Void)? = nil) async throws {
        let view = NSHostingView(rootView: content.padding(24).frame(width: size.width, height: size.height).background(Studio.canvas).preferredColorScheme(dark ? .dark : .light))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = view; window.orderFront(nil)
        defer { window.orderOut(nil) }
        view.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        if let afterAppear { try await afterAppear(); try await Task.sleep(for: .milliseconds(100)) }
        view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        XCTAssertEqual(view.bounds.width, size.width)
        XCTAssertEqual(view.bounds.height, size.height)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: path)
    }
}
