import Combine
import Foundation
import XCTest
@testable import NativeAgent

@MainActor
final class FileSelectionTests: XCTestCase {
    private var root: URL!
    private var defaults: UserDefaults!
    private var suite: String!
    private var files: FileService!
    private var model: WorkspaceViewModel!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        suite = "NativeAgentFileSelection.\(UUID())"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        files = FileService()
        model = WorkspaceViewModel(
            provider: SettingsTestProvider(), database: try DatabaseActor(url: root.appendingPathComponent("test.sqlite3")),
            files: files, git: GitService(), automaticallyRestore: false, preferences: defaults,
            credentials: MemoryCredentials(), chatGPTCredentials: MemoryChatGPTCredentials(), aiTokens: MemoryAITokens()
        )
        model.selectedProject = Project(name: "Files", canonicalPath: root.path)
        try Data("let first = 1\n".utf8).write(to: root.appendingPathComponent("first.swift"))
        try Data("let second = 2\n".utf8).write(to: root.appendingPathComponent("second.swift"))
    }

    override func tearDown() async throws {
        await model.shutdown()
        model = nil; files = nil
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }

    private func node(_ name: String) -> FileNode {
        FileNode(id: name, name: name, relativePath: name, isDirectory: false, isSymbolicLink: false)
    }

    func testSwitchClearsPreviousPreviewAndSelectedCodeWhileLoading() async throws {
        await model.selectFile(node("first.swift"))
        XCTAssertEqual(model.filePreview?.text, "let first = 1\n")
        model.features.selectedCode = "first"; model.features.selectedLines = 1...1
        var loadingObserved = false
        let subscription = model.$filePreviewLoading.dropFirst().sink { [model] loading in
            guard loading, let model else { return }
            loadingObserved = true
            XCTAssertNil(model.filePreview)
            XCTAssertNil(model.filePreviewError)
            XCTAssertTrue(model.features.selectedCode.isEmpty)
            XCTAssertNil(model.features.selectedLines)
        }
        defer { subscription.cancel() }

        await model.selectFile(node("second.swift"))

        XCTAssertTrue(loadingObserved)
        XCTAssertFalse(model.filePreviewLoading)
        XCTAssertEqual(model.selectedFile?.relativePath, "second.swift")
        XCTAssertEqual(model.filePreview?.text, "let second = 2\n")
    }

    func testUnsupportedFileReportsInlineAndNextSelectionRecovers() async throws {
        try Data([0, 1, 2, 3]).write(to: root.appendingPathComponent("binary.bin"))
        await model.selectFile(node("first.swift"))

        await model.selectFile(node("binary.bin"))

        XCTAssertEqual(model.selectedFile?.relativePath, "binary.bin")
        XCTAssertNil(model.filePreview)
        XCTAssertEqual(model.filePreviewError, "Not supported: Binary files are not shown as text.")
        XCTAssertFalse(model.filePreviewLoading)
        XCTAssertNil(model.errorMessage, "Preview failures belong beside the selected file, not in a modal alert.")

        await model.selectFile(node("second.swift"))
        XCTAssertNil(model.filePreviewError)
        XCTAssertEqual(model.filePreview?.relativePath, "second.swift")
    }

    func testRapidSwitchNeverPublishesSupersededPreview() async throws {
        let entered = expectation(description: "File reads are held")
        let release = DispatchSemaphore(value: 0)
        let files = try XCTUnwrap(files)
        let blocking = Task.detached { await files.holdForSelectionTests(entered: entered, release: release) }
        defer { release.signal() }
        await fulfillment(of: [entered], timeout: 2)
        var publishedPaths: [String] = []
        let previewSubscription = model.$filePreview.compactMap { $0?.relativePath }.sink { publishedPaths.append($0) }
        defer { previewSubscription.cancel() }

        let firstLoading = expectation(description: "First file starts loading")
        let firstSubscription = model.$filePreviewLoading.filter { $0 }.prefix(1).sink { _ in firstLoading.fulfill() }
        let first = Task { await model.selectFile(node("first.swift")) }
        await fulfillment(of: [firstLoading], timeout: 2)
        firstSubscription.cancel()
        let secondLoading = expectation(description: "Second file starts loading")
        let secondSubscription = model.$filePreviewLoading.dropFirst().filter { $0 }.prefix(1).sink { _ in secondLoading.fulfill() }
        let second = Task { await model.selectFile(node("second.swift")) }
        await fulfillment(of: [secondLoading], timeout: 2)
        secondSubscription.cancel()

        release.signal()
        await blocking.value; await first.value; await second.value

        XCTAssertEqual(publishedPaths, ["second.swift"])
        XCTAssertEqual(model.filePreview?.relativePath, "second.swift")
        XCTAssertFalse(model.filePreviewLoading)
        XCTAssertNil(model.filePreviewError)
    }

    func testLeavingAndReturningToProjectDiscardsPendingPreviewAndCodeSelection() async throws {
        let original = try XCTUnwrap(model.selectedProject)
        let entered = expectation(description: "File reads are held")
        let release = DispatchSemaphore(value: 0)
        let files = try XCTUnwrap(files)
        let blocking = Task.detached { await files.holdForSelectionTests(entered: entered, release: release) }
        defer { release.signal() }
        await fulfillment(of: [entered], timeout: 2)
        let loading = expectation(description: "File starts loading")
        let subscription = model.$filePreviewLoading.filter { $0 }.prefix(1).sink { _ in loading.fulfill() }
        let selection = Task { await model.selectFile(node("first.swift")) }
        await fulfillment(of: [loading], timeout: 2)
        subscription.cancel()
        model.features.selectedCode = "old selection"; model.features.selectedLines = 1...1

        model.selectedProject = Project(name: "Other", canonicalPath: root.appendingPathComponent("other").path)
        model.selectedProject = original
        XCTAssertNil(model.selectedFile)
        XCTAssertNil(model.filePreview)
        XCTAssertFalse(model.filePreviewLoading)
        XCTAssertTrue(model.features.selectedCode.isEmpty)
        XCTAssertNil(model.features.selectedLines)

        release.signal()
        await blocking.value; await selection.value

        XCTAssertNil(model.filePreview)
        XCTAssertNil(model.filePreviewError)
        XCTAssertNil(model.selectedFile)
    }
}

private extension FileService {
    /// Hold the actor briefly so tests can switch selection before a read completes.
    func holdForSelectionTests(entered: XCTestExpectation, release: DispatchSemaphore) {
        entered.fulfill()
        _ = release.wait(timeout: .now() + 10)
    }
}
