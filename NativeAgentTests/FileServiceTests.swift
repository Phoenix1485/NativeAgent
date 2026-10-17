import Foundation
import XCTest
@testable import NativeAgent

final class FileServiceTests: XCTestCase {
    func testSearchMatchesNestedPathsAndAllQueryTokensIgnoringCase() async throws {
        let root = try makeProject(files: [
            "src/components/DetailPanel.swift", "src/components/Other.swift", "docs/DetailPanel.md"
        ])
        defer { try? FileManager.default.removeItem(at: root) }

        let result = try await FileService().search(root: root.path, query: "  SRC\tpanel\n.SWIFT ")

        XCTAssertEqual(result.files.map(\.relativePath), ["src/components/DetailPanel.swift"])
        XCTAssertFalse(try XCTUnwrap(result.files.first).isDirectory)
        XCTAssertFalse(result.isTruncated)
    }

    func testSearchCombinesQueryWithFileTypeFilter() async throws {
        let root = try makeProject(files: [
            "feature/Panel.swift", "feature/Panel.md", "feature/Panel.PNG", "feature/README", "feature/Dockerfile", "other/Ignore.swift"
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        let service = FileService()

        let code = try await service.search(root: root.path, query: "feature", filter: .code)
        let documents = try await service.search(root: root.path, query: "feature", filter: .documents)
        let images = try await service.search(root: root.path, query: "feature", filter: .images)
        let all = try await service.search(root: root.path, query: "panel", filter: .all)

        XCTAssertEqual(Set(code.files.map(\.name)), ["Panel.swift", "Dockerfile"])
        XCTAssertEqual(Set(documents.files.map(\.name)), ["Panel.md", "README"])
        XCTAssertEqual(images.files.map(\.name), ["Panel.PNG"])
        XCTAssertEqual(all.files.count, 3)
    }

    func testSearchExcludesHiddenAndGeneratedDirectories() async throws {
        let root = try makeProject(files: [
            "src/Visible.swift", ".hidden.swift", ".private/Secret.swift", ".git/Internal.swift",
            "node_modules/Dependency.swift", "src/node_modules/Nested.swift", ".build/Generated.swift",
            "DerivedData/Build.swift", "target/Build.swift", "dist/Build.swift"
        ])
        defer { try? FileManager.default.removeItem(at: root) }

        let result = try await FileService().search(root: root.path, query: "")

        XCTAssertEqual(result.files.map(\.relativePath), ["src/Visible.swift"])
        XCTAssertFalse(result.isTruncated)
    }

    func testSearchSkipsSymlinkEscapesAndCycles() async throws {
        let fixture = try makeProject(files: ["project/src/Inside.swift", "outside/Secret.swift"])
        defer { try? FileManager.default.removeItem(at: fixture) }
        let root = fixture.appendingPathComponent("project")
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("outside"), withDestinationURL: fixture.appendingPathComponent("outside"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("cycle"), withDestinationURL: root)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Secret.swift"), withDestinationURL: fixture.appendingPathComponent("outside/Secret.swift"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("alias.swift"), withDestinationURL: root.appendingPathComponent("src/Inside.swift"))

        let result = try await FileService().search(root: root.path, query: "")

        XCTAssertEqual(result.files.map(\.relativePath), ["src/Inside.swift"])
        XCTAssertFalse(result.isTruncated)
    }

    func testSearchAcceptsSymbolicLinkProjectRoot() async throws {
        let fixture = try makeProject(files: ["project/src/Inside.swift"])
        defer { try? FileManager.default.removeItem(at: fixture) }
        let alias = fixture.appendingPathComponent("project-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.appendingPathComponent("project"))

        let result = try await FileService().search(root: alias.path, query: "inside")

        XCTAssertEqual(result.files.map(\.relativePath), ["src/Inside.swift"])
        XCTAssertFalse(result.isTruncated)
    }

    func testSearchReportsResultLimitOnlyWhenMatchesAreOmitted() async throws {
        let root = try makeProject(files: ["One.swift", "nested/Two.swift", "Three.md"])
        defer { try? FileManager.default.removeItem(at: root) }
        let service = FileService()

        let limited = try await service.search(root: root.path, query: "", filter: .code, limit: 1)
        let exact = try await service.search(root: root.path, query: "", filter: .code, limit: 2)
        let zero = try await service.search(root: root.path, query: "", limit: 0)
        let noMatches = try await service.search(root: root.path, query: "missing", limit: 0)

        XCTAssertEqual(limited.files.count, 1)
        XCTAssertTrue(limited.isTruncated)
        XCTAssertEqual(exact.files.count, 2)
        XCTAssertFalse(exact.isTruncated)
        XCTAssertTrue(zero.files.isEmpty)
        XCTAssertTrue(zero.isTruncated)
        XCTAssertTrue(noMatches.files.isEmpty)
        XCTAssertFalse(noMatches.isTruncated)
    }

    func testSearchHonorsCancellation() async throws {
        let root = try makeProject(files: ["File.swift"])
        defer { try? FileManager.default.removeItem(at: root) }
        let service = FileService()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await service.search(root: root.path, query: "")
        }

        do {
            _ = try await task.value
            XCTFail("Expected a cancelled search to throw")
        } catch is CancellationError {
            // Cancellation must propagate instead of appearing as an empty result.
        }
    }

    func testListsAndPreviewsFilesAndBlocksEscapingSymlink() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("hello".utf8).write(to: root.appendingPathComponent("a file.swift"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("node_modules"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("outside"), withDestinationURL: URL(fileURLWithPath: "/etc/hosts"))
        let service = FileService()
        let children = try await service.children(root: root.path)
        XCTAssertEqual(children.map(\.name).sorted(), ["a file.swift", "outside"])
        let preview = try await service.preview(root: root.path, relativePath: "a file.swift")
        XCTAssertEqual(preview.text, "hello")
        do {
            _ = try await service.preview(root: root.path, relativePath: "outside")
            XCTFail("Expected escaping symlink to be blocked")
        } catch { }
    }

    private func makeProject(files: [String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        do {
            for path in files {
                let url = root.appendingPathComponent(path)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data("fixture".utf8).write(to: url)
            }
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
        return root
    }
}
