import AppKit
import SwiftUI
import XCTest
@testable import NativeAgent

final class FileBrowserSnapshotTests: XCTestCase {
    @MainActor
    func testCompactAndExpandedFileBrowser() async throws {
        guard let destination = ProcessInfo.processInfo.environment["NATIVEAGENT_SNAPSHOT_DIR"] else {
            throw XCTSkip("Set NATIVEAGENT_SNAPSHOT_DIR to render the file browser.")
        }
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("src"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let code = "import SwiftUI\n\nstruct WelcomeView: View {\n    let title = \"Your code is visible\"\n\n    var body: some View {\n        Text(title)\n            .font(.title)\n    }\n}\n"
        try Data(code.utf8).write(to: root.appendingPathComponent("src/WelcomeView.swift"))
        try Data("# Example project\n".utf8).write(to: root.appendingPathComponent("README.md"))
        try Data("{}\n".utf8).write(to: root.appendingPathComponent("package.json"))
        let suite = "FileBrowserSnapshots.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let files = FileService()
        let model = WorkspaceViewModel(provider: SettingsTestProvider(), database: try DatabaseActor(url: root.appendingPathComponent(".preview.sqlite3")), files: files, git: GitService(), automaticallyRestore: false, preferences: defaults, credentials: MemoryCredentials(), chatGPTCredentials: MemoryChatGPTCredentials(), aiTokens: MemoryAITokens())
        model.selectedProject = Project(name: "Example", canonicalPath: root.path)
        await model.setInspectorVisible(true)
        let node = FileNode(id: "src/WelcomeView.swift", name: "WelcomeView.swift", relativePath: "src/WelcomeView.swift", isDirectory: false, isSymbolicLink: false)
        await model.selectFile(node)
        let browser = FileBrowserState()
        browser.expandedPaths = ["src"]
        try FileManager.default.createDirectory(atPath: destination, withIntermediateDirectories: true)

        for dark in [true, false] {
            for expanded in [false, true] {
                let size = NSSize(width: expanded ? 1100 : 300, height: 700)
                let content = FileBrowserView(browser: browser, expanded: expanded, onExpand: expanded ? nil : {})
                    .environmentObject(model).environment(\.colorScheme, dark ? .dark : .light)
                    .frame(width: size.width, height: size.height)
                let view = NSHostingView(rootView: content)
                view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
                window.contentView = view
                window.orderFront(nil)
                defer { window.orderOut(nil) }
                view.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(300))
                view.layoutSubtreeIfNeeded()
                let textView = try XCTUnwrap(findTextView(in: view))
                XCTAssertEqual(textView.string, code)
                let scroll = try XCTUnwrap(textView.enclosingScrollView)
                let codeFrame = scroll.convert(scroll.bounds, to: view)
                XCTAssertGreaterThan(codeFrame.width, expanded ? 500 : 250)
                XCTAssertGreaterThan(codeFrame.height, 170)
                if expanded {
                    XCTAssertLessThan(codeFrame.maxX, size.width - 230, "The file navigator remains on the right.")
                }
                let suffix = (expanded ? "expanded" : "compact") + (dark ? "-dark" : "-light")
                try save(view, name: "files-" + suffix, destination: destination)
                if expanded && dark {
                    browser.query = "src swift"
                    browser.filter = .code
                    try await Task.sleep(for: .milliseconds(400))
                    view.layoutSubtreeIfNeeded()
                    XCTAssertEqual(textView.string, code, "Filtering does not discard the open file.")
                    try save(view, name: "files-search-dark", destination: destination)
                    browser.query = ""; browser.filter = .all
                }
            }
        }
        let workspace = NSHostingView(rootView: WorkspaceView(fileBrowser: browser).environmentObject(model).environmentObject(AppUpdater())
            .environment(\.colorScheme, .dark).frame(width: 1100, height: 800))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 800), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = workspace
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        workspace.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(300))
        browser.openTab()
        try await Task.sleep(for: .milliseconds(300))
        workspace.layoutSubtreeIfNeeded()
        let openedText = try XCTUnwrap(findTextView(in: workspace))
        XCTAssertGreaterThan(try XCTUnwrap(openedText.enclosingScrollView).frame.width, 500)
        try save(workspace, name: "files-workspace-tab", destination: destination)
        browser.showingTab = false
        try await Task.sleep(for: .milliseconds(100))
        browser.showingTab = true
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(findTextView(in: workspace) === openedText, "Switching tabs retains the open code view.")
        browser.closeTab()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(browser.tabOpen)
        XCTAssertFalse(browser.showingTab)
        await model.shutdown()
    }

    @MainActor
    private func findTextView(in view: NSView) -> NSTextView? {
        if let text = view as? NSTextView, text.string.hasPrefix("import SwiftUI") { return text }
        return view.subviews.lazy.compactMap { self.findTextView(in: $0) }.first
    }

    @MainActor
    private func save(_ view: NSView, name: String, destination: String) throws {
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: destination).appendingPathComponent(name + ".png"))
    }
}
