import Foundation
import XCTest
@testable import NativeAgent

final class GitServiceTests: XCTestCase {
    func testStatusSeparatesStagedAndWorkingChangesWithSpaces() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try runGit(["init", "-q"], at: root)
        let file = root.appendingPathComponent("name with spaces.txt")
        try Data("one\n".utf8).write(to: file)
        try runGit(["add", "--", "name with spaces.txt"], at: root)
        var snapshot = try await GitService().status(at: root.path)
        XCTAssertTrue(snapshot.changes.contains { $0.path == "name with spaces.txt" && $0.staged && $0.kind == .added })
        try Data("one\ntwo\n".utf8).write(to: file)
        snapshot = try await GitService().status(at: root.path)
        XCTAssertTrue(snapshot.changes.contains { $0.path == "name with spaces.txt" && !$0.staged && $0.kind == .modified })
    }

    private func runGit(_ arguments: [String], at directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", directory.path] + arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }
}
