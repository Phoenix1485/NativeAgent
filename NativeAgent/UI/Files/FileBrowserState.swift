import AppKit
import SwiftUI

/// A viewport belongs to a file, so changing tabs does not require keeping every
/// file's text layout in memory. Native views restore it when the file is reopened.
@MainActor
final class CodeDocumentState {
    var scrollOrigin: NSPoint?
    var selection = NSRange(location: 0, length: 0)
}

@MainActor
final class FileBrowserState: ObservableObject {
    @Published var tabOpen = false
    @Published var showingTab = false
    @Published var splitWithChat = false
    @Published var quickOpenVisible = false
    @Published var query = ""
    @Published var filter: FileBrowserFilter = .all
    @Published var expandedPaths: Set<String> = []
    @Published private(set) var openFiles: [FileNode] = []
    @Published var fontSize: Double { didSet { preferences.set(fontSize, forKey: "codeFontSize") } }
    @Published var wrapsLines: Bool { didSet { preferences.set(wrapsLines, forKey: "codeWrapsLines") } }
    @Published var syntaxHighlighting: Bool { didSet { preferences.set(syntaxHighlighting, forKey: "codeSyntaxHighlighting") } }
    private var documentStates: [String: CodeDocumentState] = [:]
    private let preferences: UserDefaults

    init(preferences: UserDefaults = .standard) {
        self.preferences = preferences
        let stored = preferences.double(forKey: "codeFontSize")
        fontSize = stored == 0 ? 12 : min(28, max(9, stored))
        wrapsLines = preferences.bool(forKey: "codeWrapsLines")
        syntaxHighlighting = preferences.object(forKey: "codeSyntaxHighlighting") == nil || preferences.bool(forKey: "codeSyntaxHighlighting")
    }

    func openTab() { tabOpen = true; showingTab = true }
    func closeTab() { showingTab = false; tabOpen = false; splitWithChat = false }
    func openSplit() { openTab(); splitWithChat = true }

    func remember(_ node: FileNode) {
        guard !node.isDirectory, !openFiles.contains(where: { $0.id == node.id }) else { return }
        openFiles.append(node)
    }

    func documentState(for path: String, scope: String = "workspace") -> CodeDocumentState {
        let key = scope + "\u{0}" + path
        if let state = documentStates[key] { return state }
        let state = CodeDocumentState()
        documentStates[key] = state
        return state
    }

    /// Returns the adjacent file to select when closing the active tab.
    func closeFile(_ node: FileNode, selectedPath: String?) -> FileNode? {
        guard let index = openFiles.firstIndex(where: { $0.id == node.id }) else { return nil }
        openFiles.remove(at: index)
        documentStates = documentStates.filter { !$0.key.hasSuffix("\u{0}" + node.relativePath) }
        guard selectedPath == node.relativePath, !openFiles.isEmpty else { return nil }
        return openFiles[min(index, openFiles.count - 1)]
    }

    func reset() {
        query = ""; filter = .all; expandedPaths = []
        openFiles = []; documentStates = [:]
        quickOpenVisible = false
    }
}
