import Foundation

struct ProjectProfile: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var name = "Project defaults"
    var provider: ProviderKind = .codex
    var modelID: String?
    var reasoning: String?
    var workingDirectory: String
    var instructions = ""
    var buildCommand = ""
    var testCommand = ""
    var formatCommand = ""
    var contextNotes = ""
    var access: WorkspaceAccess = .readOnly
}

struct PromptTemplate: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var projectID: UUID?
    var title: String
    var folder = "General"
    var body: String
    static var starters: [Self] {
        ["Code review", "Bug investigation", "Write tests", "Explain code", "Refactor", "Documentation"].enumerated().map { index, title in
            Self(id: UUID(uuidString: String(format: "DA000000-0000-0000-0000-%012d", index + 1))!, title: title,
                 body: "\(title) for {{file_path}} ({{language}}).\n\n{{selected_code}}\n\nRequested outcome: {{outcome}}")
        }
    }
    func render(_ values: [String: String]) -> String {
        values.reduce(body) { $0.replacingOccurrences(of: "{{\($1.key)}}", with: $1.value) }
    }
}

struct ContextAttachment: Codable, Identifiable, Equatable, Sendable {
    enum Kind: String, Codable, CaseIterable, Sendable { case fileReference, code, excerpt, instructions, attachment }
    var id = UUID()
    var kind: Kind
    var title: String
    var text = ""
    var path: String?
    var startLine: Int?
    var endLine: Int?
    var sourceHash: String?
    var metadata = ""
    var stale = false
    // Optional fields keep older saved conversations readable. A snapshot is not write permission.
    var sourceURL: String?
    var allowEdits: Bool?
    var wireText: String {
        let location = path.map { "\nFile: \($0)" } ?? ""
        let lines = startLine.map { "\nLines: \($0)-\(endLine ?? $0)" } ?? ""
        return "[Explicit context: \(kind.rawValue) · \(title)]\(location)\(lines)\n\(text)\n\(metadata)"
    }
}

enum WorkTaskState: String, Codable, Sendable {
    case queued, running, awaitingApproval, awaitingInput, completed, failed, canceled, needsReview
    var isActive: Bool { [.running, .awaitingApproval, .awaitingInput].contains(self) }
}

struct QueuedWork: Codable, Identifiable, Sendable {
    var id = UUID()
    var position: Int
    var projectID: UUID
    var projectPath: String
    var provider: ProviderKind
    var authentication: AuthenticationMethod
    var executable: String
    var providerConfiguration: String
    var modelID: String
    var profile: ProjectProfile
    var prompt: String
    var context: [ContextAttachment]
    var state: WorkTaskState = .queued
    var conversationID: UUID?
    var failure: String?
}

struct RecordedCommand: Codable, Identifiable, Sendable {
    var id = UUID()
    var command: String
    var output: String
    var exitCode: Int?
    var isConfiguredTest: Bool
}

struct TaskReport: Codable, Identifiable, Sendable {
    struct Proposal: Codable, Sendable { var path: String; var diff: String; var state: String }
    var id = UUID()
    var conversationID: UUID
    var projectID: UUID
    var projectPath: String
    var provider: ProviderKind
    var prompt: String
    var state: WorkTaskState = .running
    var startedAt = Date()
    var finishedAt: Date?
    var providerTurnID: String?
    var queueID: UUID?
    var summary = ""
    var commands: [RecordedCommand] = []
    var fileChanges: [String: String] = [:]
    var warnings: [String] = []
    var remaining: [String] = []
    var testCommand = ""
    var snapshotPaths: [String] = []
    var proposals: [String: Proposal]?
    var markdown: String {
        var result = "# Task report\n\nStatus: \(state.rawValue)\nProvider: \(provider.title)\nWorkspace: \(projectPath)\n\n## Request\n\n\(prompt)\n\n## Provider summary (not independent verification)\n\n\(summary.isEmpty ? "No summary reported." : summary)\n\n## Changes\n"
        result += fileChanges.keys.sorted().map { "- `\($0)` — provider-reported change" }.joined(separator: "\n")
        result += "\n" + snapshotPaths.map { "- `\($0)` — observed byte changes; before/after available" }.joined(separator: "\n")
        result += "\n" + (proposals ?? [:]).values.sorted { $0.path < $1.path }.map { "- `\($0.path)` — provider proposal status: \($0.state)" }.joined(separator: "\n")
        result += "\n\n## Commands and actual exit results\n\n"
        result += commands.map { "### \($0.command)\n\nExit: \($0.exitCode.map(String.init) ?? "not reported")\($0.isConfiguredTest ? " · configured test command" : "")\n\n```text\n\($0.output.replacingOccurrences(of: "```", with: "` ` `"))\n```" }.joined(separator: "\n\n")
        if !commands.contains(where: { $0.isConfiguredTest && $0.exitCode != nil }) { result += "\nNo verified execution result for the configured test command. Prose claims do not establish test success.\n" }
        result += "\n## Errors and warnings\n\n" + (warnings.isEmpty ? "None recorded." : warnings.map { "- " + $0 }.joined(separator: "\n"))
        result += "\n\n## Remaining work / unresolved questions\n\n" + (remaining.isEmpty ? "None explicitly reported; this is not proof that no work remains." : remaining.map { "- " + $0 }.joined(separator: "\n"))
        return result
    }
}

struct FileCheckpoint: Codable, Identifiable, Sendable {
    var id: String { path }
    var path: String
    var before: Data
    var after: Data?
    var beforeHash: String
    var afterHash: String?
    var rolledBack = false
    var diff: String {
        let old = String(decoding: before, as: UTF8.self), new = after.map { String(decoding: $0, as: UTF8.self) } ?? ""
        let oldLines = old.components(separatedBy: "\n"), newLines = new.components(separatedBy: "\n")
        return "--- before/\(path)\n+++ after/\(path)\n@@ -1,\(oldLines.count) +1,\(newLines.count) @@\n" + oldLines.map { "-" + $0 }.joined(separator: "\n") + "\n" + newLines.map { "+" + $0 }.joined(separator: "\n")
    }
}

struct TaskCheckpoint: Codable, Sendable {
    var files: [FileCheckpoint]
    var warnings: [String]
}

struct BranchLink: Codable, Identifiable, Sendable {
    var id: UUID
    var parentID: UUID
    var messageID: UUID
    var parentTitle: String
    var branchTitle: String
    var mode = "New conversation with selected context (not a native fork)"
}

struct SessionState: Codable, Equatable, Sendable {
    var conversationID: UUID?
    var projectID: UUID?
    var selectedFile: String?
    var readingPosition: UUID?
    var inspector = false
    var sidebar = true
    var inspectorTab = "Files"
    var terminal = false
    var reconnect = false
    var featurePanel: String?
    var reportID: UUID?
}

struct LocalSearchHit: Identifiable, Sendable {
    var id: String { kind + ":" + recordID }
    var kind: String
    var recordID: String
    var title: String
    var excerpt: String
    var projectID: UUID?
    var conversationID: UUID?
    var projectName: String
    var conversationTitle: String
}

enum WorkspaceCommand: String, CaseIterable, Identifiable {
    case newChat, dashboard, profiles, templates, reports, context, queue, search, settings, files, changes, terminal, selectedCode
    var id: String { rawValue }
    var title: String {
        switch self {
        case .newChat: "New conversation"
        case .dashboard: "Subscription dashboard"
        case .profiles: "Project profile"
        case .templates: "Prompt library"
        case .reports: "Task reports and change review"
        case .context: "Context for next request"
        case .queue: "Task queue"
        case .search: "Search local history"
        case .settings: "Provider settings"
        case .files: "Show files"
        case .changes: "Show changes"
        case .terminal: "Show terminal activity"
        case .selectedCode: "Selected-code actions"
        }
    }
    var shortcut: String { self == .newChat ? "⌘N" : self == .search ? "⌘⇧F" : "" }
    func matches(_ query: String) -> Bool {
        var remaining = query.lowercased().filter { !$0.isWhitespace }[...]
        for character in title.lowercased() where remaining.first == character { remaining = remaining.dropFirst(); if remaining.isEmpty { return true } }
        return remaining.isEmpty
    }
}
