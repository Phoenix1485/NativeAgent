import Foundation
import XCTest
@testable import NativeAgent

final class FileServiceTests: XCTestCase {
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
}
