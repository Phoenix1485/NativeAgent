import Foundation

enum GitChangeKind: String, Sendable { case modified, added, deleted, renamed, copied, untracked, conflicted }

struct GitFileChange: Identifiable, Hashable, Sendable {
    var id: String { path + (staged ? ":staged" : ":working") }
    let path: String
    let kind: GitChangeKind
    let staged: Bool
}

struct GitSnapshot: Sendable {
    var branch: String = "Not a Git repository"
    var changes: [GitFileChange] = []
}

actor GitService {
    private let maximumOutput = 8 * 1_024 * 1_024

    func status(at root: String) throws -> GitSnapshot {
        let data = try run(arguments: ["-C", root, "status", "--porcelain=v1", "-z", "--branch"])
        let records = data.split(separator: 0, omittingEmptySubsequences: true).map { String(decoding: $0, as: UTF8.self) }
        var snapshot = GitSnapshot()
        var index = 0
        while index < records.count {
            let record = records[index]
            if record.hasPrefix("## ") {
                snapshot.branch = String(record.dropFirst(3)).components(separatedBy: "...").first ?? "Detached"
            } else if record.count >= 3 {
                let x = record[record.startIndex]
                let y = record[record.index(after: record.startIndex)]
                var path = String(record.dropFirst(3))
                if (x == "R" || x == "C") && index + 1 < records.count {
                    index += 1
                    path = records[index]
                }
                if x == "?" && y == "?" {
                    snapshot.changes.append(.init(path: path, kind: .untracked, staged: false))
                } else {
                    if x != " " { snapshot.changes.append(.init(path: path, kind: kind(for: x), staged: true)) }
                    if y != " " { snapshot.changes.append(.init(path: path, kind: kind(for: y), staged: false)) }
                }
            }
            index += 1
        }
        return snapshot
    }

    func diff(at root: String, path: String? = nil, staged: Bool = false) throws -> String {
        var arguments = ["-C", root, "diff", "--no-ext-diff", "--no-color"]
        if staged { arguments.append("--cached") }
        if let path { arguments += ["--", path] }
        return String(decoding: try run(arguments: arguments), as: UTF8.self)
    }

    private func kind(for marker: Character) -> GitChangeKind {
        switch marker {
        case "A": .added
        case "D": .deleted
        case "R": .renamed
        case "C": .copied
        case "U": .conflicted
        default: .modified
        }
    }

    private func run(arguments: [String]) throws -> Data {
        let process = Process()
        let output = Pipe()
        let error = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = error
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = error.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard data.count <= maximumOutput else { throw NativeAgentError.frameTooLarge(limit: maximumOutput) }
        guard process.terminationStatus == 0 else {
            let message = String(decoding: errorData.prefix(4_096), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw NativeAgentError.providerUnavailable(message.isEmpty ? "Git command failed." : message)
        }
        return data
    }
}
