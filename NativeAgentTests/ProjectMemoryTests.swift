import XCTest
@testable import NativeAgent

final class ProjectMemoryTests: XCTestCase {
    func testMemoryIsProjectScopedPersistentEditableAndBounded() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("memory.sqlite3"), db = try DatabaseActor(url: url)
        let first = Project(name: "First", canonicalPath: directory.appendingPathComponent("first").path)
        let second = Project(name: "Second", canonicalPath: directory.appendingPathComponent("second").path)
        try await db.save(project: first); try await db.save(project: second)
        let memory = ProjectMemory(frameworks: "SwiftUI", conventions: "Use actors", goals: "Offline-first", decisions: "Use SQLite", avoidances: "No cloud sync")
        try await db.saveProjectMemory(memory, projectID: first.id)
        let reopened = try DatabaseActor(url: url)
        let saved = try await reopened.projectMemory(first.id), other = try await reopened.projectMemory(second.id)
        XCTAssertEqual(saved, memory); XCTAssertTrue(other.isEmpty)
        for (_, value) in memory.fields { XCTAssertTrue(try saved.prompt().contains(value)) }
        do { try await db.saveProjectMemory(.init(frameworks: String(repeating: "x", count: 4_001)), projectID: first.id); XCTFail("Oversized memory accepted") } catch {}
        let unchanged = try await db.projectMemory(first.id); XCTAssertEqual(unchanged, memory)
        try await db.saveProjectMemory(ProjectMemory(), projectID: first.id)
        let cleared = try await reopened.projectMemory(first.id); XCTAssertEqual(try cleared.prompt(), "")
    }
}
