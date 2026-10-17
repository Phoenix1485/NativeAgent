import AppKit
import SwiftUI
import XCTest
@testable import NativeAgent

final class FileBrowserSnapshotTests: XCTestCase {
    @MainActor
    func testSwitchingFileTabsRestoresViewportAndSelection() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = "import SwiftUI\n" + Array(repeating: "let source = \"" + String(repeating: "wide code ", count: 60) + "\"", count: 120).joined(separator: "\n")
        try Data(source.utf8).write(to: root.appendingPathComponent("First.swift"))
        try Data("import SwiftUI\nlet second = 2".utf8).write(to: root.appendingPathComponent("Second.swift"))
        let suite = "FileTabTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = WorkspaceViewModel(provider: SettingsTestProvider(), database: try DatabaseActor(url: root.appendingPathComponent(".library.sqlite3")), files: FileService(), git: GitService(), automaticallyRestore: false, preferences: defaults, credentials: MemoryCredentials(), chatGPTCredentials: MemoryChatGPTCredentials(), aiTokens: MemoryAITokens())
        model.selectedProject = Project(name: "Example", canonicalPath: root.path)
        let first = FileNode(id: "First.swift", name: "First.swift", relativePath: "First.swift", isDirectory: false, isSymbolicLink: false)
        let second = FileNode(id: "Second.swift", name: "Second.swift", relativePath: "Second.swift", isDirectory: false, isSymbolicLink: false)
        await model.setInspectorVisible(true)
        await model.selectFile(first)
        let browser = FileBrowserState(preferences: defaults)
        let view = NSHostingView(rootView: FileBrowserView(browser: browser, expanded: true).environmentObject(model))
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1100, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view; window.orderFront(nil)
        defer { window.orderOut(nil) }
        await settle(view)
        let original = try XCTUnwrap(findTextView(in: view))
        let originalScroll = try XCTUnwrap(original.enclosingScrollView)
        original.setSelectedRange(NSRange(location: 0, length: 14))
        originalScroll.contentView.scroll(to: NSPoint(x: 200, y: 500))
        originalScroll.reflectScrolledClipView(originalScroll.contentView)
        let origin = originalScroll.contentView.bounds.origin
        await model.selectFile(second)
        await settle(view)
        XCTAssertEqual(try XCTUnwrap(findTextView(in: view)).string, "import SwiftUI\nlet second = 2")
        XCTAssertEqual(browser.openFiles.map(\.id), [first.id, second.id])
        await model.selectFile(first)
        await settle(view)
        let restored = try XCTUnwrap(findTextView(in: view))
        let restoredScroll = try XCTUnwrap(restored.enclosingScrollView)
        XCTAssertEqual(restored.string, source)
        XCTAssertEqual(restored.selectedRange(), NSRange(location: 0, length: 14))
        XCTAssertEqual(restoredScroll.contentView.bounds.minX, origin.x, accuracy: 1)
        XCTAssertEqual(restoredScroll.contentView.bounds.minY, origin.y, accuracy: 1)
        await model.shutdown()
    }

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
        let browser = FileBrowserState(preferences: defaults)
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
        browser.splitWithChat = true
        await settle(workspace)
        let splitText = try XCTUnwrap(findTextView(in: workspace))
        XCTAssertGreaterThan(try XCTUnwrap(splitText.enclosingScrollView).frame.width, 240)
        XCTAssertTrue(splitText === openedText, "Opening the chat split retains the native code view.")
        try save(workspace, name: "files-workspace-split", destination: destination)
        browser.splitWithChat = false
        let detached = DetachedFilesWindow()
        detached.open(model: model, browser: browser)
        XCTAssertTrue(detached.isVisible)
        if let detachedWindow = NSApp.windows.first(where: { $0.title == "Files — NativeAgent" }), let content = detachedWindow.contentView {
            await settle(content)
            XCTAssertEqual(try XCTUnwrap(findTextView(in: content)).string, code)
            try save(content, name: "files-detached", destination: destination)
            detachedWindow.close()
        } else { XCTFail("A separate native file window must open.") }
        XCTAssertFalse(detached.isVisible)
        browser.closeTab()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(browser.tabOpen)
        XCTAssertFalse(browser.showingTab)
        await model.shutdown()
    }

    @MainActor
    private func settle(_ view: NSView) async {
        for _ in 0..<4 {
            view.layoutSubtreeIfNeeded()
            view.window?.displayIfNeeded()
            try? await Task.sleep(for: .milliseconds(30))
        }
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
