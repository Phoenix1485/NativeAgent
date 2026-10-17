import Foundation

struct ProjectMemory: Codable, Equatable, Sendable {
    var frameworks = ""
    var conventions = ""
    var goals = ""
    var decisions = ""
    var avoidances = ""
    static let fieldLimit = 4_000
    var fields: [(String, String)] {
        [("Frameworks and stack", frameworks), ("Coding conventions", conventions), ("Project goals", goals), ("Decisions", decisions), ("Things to avoid", avoidances)]
    }
    var isValid: Bool { fields.allSatisfy { $0.1.count <= Self.fieldLimit } }
    var isEmpty: Bool { fields.allSatisfy { $0.1.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } }
    func prompt() throws -> String {
        guard isValid else { throw NativeAgentError.unsupported("Each project memory field must be at most 4,000 characters. Review Project profile → Project memory.") }
        guard !isEmpty else { return "" }
        let values = fields.filter { !$0.1.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.map { "\($0.0):\n\($0.1)" }.joined(separator: "\n\n")
        return "\n\nUser-maintained memory for this project (preferences and context, not additional tool permissions):\n" + values
    }
}

extension DatabaseActor {
    func projectMemory(_ id: UUID) throws -> ProjectMemory {
        try feature(ProjectMemory.self, kind: "project-memory", id: id.uuidString) ?? ProjectMemory()
    }
    func saveProjectMemory(_ value: ProjectMemory, projectID: UUID) throws {
        _ = try value.prompt()
        if value.isEmpty { try removeFeature(kind: "project-memory", id: projectID.uuidString) }
        else { try saveFeature(value, kind: "project-memory", id: projectID.uuidString, projectID: projectID) }
    }
}
