import Foundation
import CryptoKit

actor TaskFileService {
    static let fileLimit = 1_048_576
    static let totalLimit = 8 * 1_048_576
    static let ignored: Set<String> = [".git", ".build", "node_modules", "vendor", "Pods", ".next", "dist", ".venv", "build"]
    nonisolated static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    func safeURL(root: String, path: String) throws -> URL {
        let base = URL(fileURLWithPath: root, isDirectory: true).resolvingSymlinksInPath().standardizedFileURL
        let candidate = path.hasPrefix("/") ? URL(fileURLWithPath: path).standardizedFileURL : base.appendingPathComponent(path).standardizedFileURL
        guard candidate.path.hasPrefix(base.path + "/"), candidate.resolvingSymlinksInPath().path == candidate.path else {
            throw NativeAgentError.unsupported("The file is outside the workspace or crosses a symbolic link.")
        }
        return candidate
    }

    func read(root: String, path: String) throws -> Data {
        let url = try safeURL(root: root, path: path)
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, (values.fileSize ?? Int.max) <= Self.fileLimit else { throw NativeAgentError.unsupported("Only regular files up to 1 MiB can be attached or checkpointed.") }
        let data = try Data(contentsOf: url)
        guard data.count <= Self.fileLimit, !data.prefix(8192).contains(0), String(data: data, encoding: .utf8) != nil else { throw NativeAgentError.unsupported("This integration accepts UTF-8 text attachments, not binary files.") }
        return data
    }

    func attach(root: String, path: String, referenceOnly: Bool, selectedText: String? = nil, lines: ClosedRange<Int>? = nil) throws -> ContextAttachment {
        let data = try read(root: root, path: path)
        return .init(kind: referenceOnly ? .fileReference : (selectedText == nil ? .attachment : .code), title: URL(fileURLWithPath: path).lastPathComponent,
                     text: referenceOnly ? "Reference only; file contents are not included." : selectedText ?? String(decoding: data, as: UTF8.self), path: path,
                     startLine: lines?.lowerBound, endLine: lines?.upperBound, sourceHash: Self.hash(data), metadata: "UTF-8 · \(data.count) source bytes")
    }

    func stale(_ context: ContextAttachment, root: String) -> Bool {
        guard let path = context.path, let hash = context.sourceHash else { return false }
        guard let data = try? read(root: root, path: path) else { return true }
        return Self.hash(data) != hash
    }

    private func candidates(root: String, limit: Int) throws -> [String] {
        let base = URL(fileURLWithPath: root).resolvingSymlinksInPath()
        guard let iterator = FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey], options: [.skipsHiddenFiles]) else { return [] }
        var result: [String] = [], visited = 0
        while let url = iterator.nextObject() as? URL {
            try Task.checkCancellation(); visited += 1
            if visited > 10_000 { break }
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            if Self.ignored.contains(url.lastPathComponent) || values?.isSymbolicLink == true { iterator.skipDescendants(); continue }
            if values?.isRegularFile == true, (values?.fileSize ?? Int.max) <= Self.fileLimit {
                // Foundation can enumerate /var as /private/var on macOS. Normalize both sides.
                let canonical = url.resolvingSymlinksInPath().standardizedFileURL.path
                guard canonical.hasPrefix(base.path + "/") else { continue }
                result.append(String(canonical.dropFirst(base.path.count + 1)))
                if result.count >= limit { break }
            }
        }
        return result
    }

    func capture(root: String) throws -> TaskCheckpoint {
        var files: [FileCheckpoint] = [], bytes = 0
        for path in try candidates(root: root, limit: 129) {
            guard files.count < 128, let data = try? read(root: root, path: path) else { continue }
            guard bytes + data.count <= Self.totalLimit else { continue }
            files.append(.init(path: path, before: data, beforeHash: Self.hash(data))); bytes += data.count
        }
        return .init(files: files, warnings: ["Rollback coverage is limited to up to 128 existing UTF-8 files, 1 MiB each / 8 MiB total. Hidden, ignored, binary, new and uncheckpointed files are not eligible. Changes observed during a task are not proof of agent authorship."])
    }

    func finish(_ baseline: TaskCheckpoint, root: String) -> TaskCheckpoint {
        var changed: [FileCheckpoint] = []
        for var file in baseline.files {
            let data = try? read(root: root, path: file.path)
            if data == file.before { continue }
            file.after = data; file.afterHash = data.map(Self.hash); changed.append(file)
        }
        return .init(files: changed, warnings: baseline.warnings)
    }

    func summarize(_ checkpoint: TaskCheckpoint) -> TaskChangeSummary { TaskChangeSummary.measure(checkpoint.files) }

    func rollback(_ file: FileCheckpoint, root: String) throws {
        guard !file.rolledBack, let expected = file.afterHash, file.after != nil else { throw NativeAgentError.unsupported("There is no verified applied-file baseline for rollback. Review manually.") }
        let url = try safeURL(root: root, path: file.path)
        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?, operationError: Error?
        coordinator.coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { target in
            do {
                _ = try safeURL(root: root, path: file.path)
                let current = try read(root: root, path: file.path)
                guard current.count <= Self.fileLimit, Self.hash(current) == expected, current == file.after else {
                    throw NativeAgentError.unsupported("Rollback conflict: this file changed after the task. Nothing was overwritten.")
                }
                let attributes = try FileManager.default.attributesOfItem(atPath: target.path)
                try file.before.write(to: target, options: .atomic)
                if let permissions = attributes[.posixPermissions] { try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: target.path) }
            } catch { operationError = error }
        }
        if let error = operationError ?? coordinationError { throw error }
    }

    func search(root: String, query: String, offset: Int = 0) throws -> [LocalSearchHit] {
        guard !query.isEmpty else { return [] }
        var matches: [LocalSearchHit] = [], skipped = 0
        for path in try candidates(root: root, limit: 2_000) {
            try Task.checkCancellation()
            guard let data = try? read(root: root, path: path), let text = String(data: data, encoding: .utf8), let range = text.range(of: query, options: .caseInsensitive) else { continue }
            if skipped < offset { skipped += 1; continue }
            let start = text.index(range.lowerBound, offsetBy: -60, limitedBy: text.startIndex) ?? text.startIndex
            matches.append(.init(kind: "project file", recordID: path, title: path, excerpt: String(text[start...].prefix(240)), projectName: URL(fileURLWithPath: root).lastPathComponent, conversationTitle: ""))
            if matches.count == 40 { break }
        }
        return matches
    }
}
