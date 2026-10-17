import AppKit
import XCTest
@testable import NativeAgent

final class FileWorkspaceTests: XCTestCase {
    func testLexerKeepsQuotedCommentMarkersAndUnicodeRangesIntact() {
        let source = "let face = \"🙂 // not a comment\" // true comment\nlet number = 42"
        let tokens = CodeSyntaxHighlighter.tokens(in: source, path: "Example.swift")
        let lexemes = tokens.map { (kind: $0.kind, text: (source as NSString).substring(with: $0.range)) }
        XCTAssertTrue(lexemes.contains { $0.kind == .string && $0.text == "\"🙂 // not a comment\"" })
        XCTAssertEqual(lexemes.filter { $0.kind == .comment }.map(\.text), ["// true comment"])
        XCTAssertTrue(lexemes.contains { $0.kind == .number && $0.text == "42" })
        XCTAssertTrue(CodeSyntaxHighlighter.tokens(in: source, path: "notes.txt").isEmpty)
        let python = "value = 'a#b' # comment\n"
        XCTAssertEqual(CodeSyntaxHighlighter.tokens(in: python, path: "main.py").filter { $0.kind == .comment }.map { (python as NSString).substring(with: $0.range) }, ["# comment"])
    }

    @MainActor
    func testTabsHaveIndependentPositionsAndResetBetweenProjects() throws {
        let suite = "FileWorkspace.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let browser = FileBrowserState(preferences: defaults)
        let a = FileNode(id: "a.swift", name: "a.swift", relativePath: "a.swift", isDirectory: false, isSymbolicLink: false)
        let b = FileNode(id: "b.swift", name: "b.swift", relativePath: "b.swift", isDirectory: false, isSymbolicLink: false)
        browser.remember(a); browser.remember(b); browser.remember(a)
        XCTAssertEqual(browser.openFiles, [a, b])
        let state = browser.documentState(for: a.relativePath)
        state.scrollOrigin = NSPoint(x: 20, y: 200)
        XCTAssertTrue(browser.documentState(for: a.relativePath) === state)
        XCTAssertNil(browser.documentState(for: b.relativePath).scrollOrigin)
        XCTAssertNil(browser.documentState(for: a.relativePath, scope: "detached").scrollOrigin)
        XCTAssertEqual(browser.closeFile(a, selectedPath: a.relativePath), b)
        XCTAssertNil(browser.documentState(for: a.relativePath).scrollOrigin)
        browser.fontSize = 18; browser.wrapsLines = true; browser.syntaxHighlighting = false
        let restored = FileBrowserState(preferences: defaults)
        XCTAssertEqual(restored.fontSize, 18); XCTAssertTrue(restored.wrapsLines); XCTAssertFalse(restored.syntaxHighlighting)
        browser.openSplit()
        XCTAssertTrue(browser.tabOpen && browser.showingTab && browser.splitWithChat)
        browser.reset()
        XCTAssertTrue(browser.openFiles.isEmpty)
        XCTAssertNil(browser.documentState(for: b.relativePath).scrollOrigin)
        XCTAssertEqual(browser.fontSize, 18, "Changing project preserves reading preferences.")
    }
}
