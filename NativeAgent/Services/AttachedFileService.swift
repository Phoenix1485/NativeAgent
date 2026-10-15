import Foundation

struct AttachedFileSnapshot: Identifiable, Sendable {
    var id: String { url.path }
    let url: URL
    let data: Data
    var text: String { String(decoding: data, as: UTF8.self) }
    var hash: String { TaskFileService.hash(data) }
}

/// Only explicitly picked/dropped files are passed here. No arbitrary model-supplied paths.
actor AttachedFileService {
    private let files = TaskFileService()

    func load(_ url: URL) async throws -> AttachedFileSnapshot {
        guard url.isFileURL else { throw NativeAgentError.unsupported("Choose a local file.") }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let canonicalParent = url.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        let target = canonicalParent.appendingPathComponent(url.lastPathComponent)
        let data = try await files.read(root: canonicalParent.path, path: target.path)
        return AttachedFileSnapshot(url: target, data: data)
    }

    func save(_ snapshot: AttachedFileSnapshot, text: String) async throws -> AttachedFileSnapshot {
        let replacement = Data(text.utf8)
        guard replacement.count <= TaskFileService.fileLimit, !replacement.contains(0) else {
            throw NativeAgentError.unsupported("Edited files must be UTF-8 text up to 1 MiB, without NUL bytes.")
        }
        // Coordination and comparison happen in one synchronous accessor. Never replace newer edits.
        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?, operationError: Error?
        coordinator.coordinate(writingItemAt: snapshot.url, options: .forReplacing, error: &coordinationError) { target in
            do {
                guard target.standardizedFileURL == snapshot.url,
                      target.resolvingSymlinksInPath().standardizedFileURL == snapshot.url else {
                    throw NativeAgentError.unsupported("The file location changed or became a symbolic link. Nothing was saved.")
                }
                let values = try target.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                guard values.isRegularFile == true, (values.fileSize ?? Int.max) <= TaskFileService.fileLimit,
                      try Data(contentsOf: target) == snapshot.data else {
                    throw NativeAgentError.unsupported("This file changed on disk. Your edit was kept, but nothing was overwritten. Reopen the file to review the latest version.")
                }
                let attributes = try FileManager.default.attributesOfItem(atPath: target.path)
                try replacement.write(to: target, options: .atomic)
                if let mode = attributes[.posixPermissions] {
                    try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: target.path)
                }
            } catch { operationError = error }
        }
        if let error = operationError ?? coordinationError { throw error }
        return AttachedFileSnapshot(url: snapshot.url, data: replacement)
    }

    nonisolated static func replacing(_ snapshot: AttachedFileSnapshot, old: String, new: String) throws -> String {
        guard !old.isEmpty, let range = snapshot.text.range(of: old),
              snapshot.text[range.upperBound...].range(of: old) == nil else {
            throw NativeAgentError.unsupported("The original text must occur exactly once. Read the attached file and choose a unique replacement.")
        }
        let result = snapshot.text.replacingCharacters(in: range, with: new)
        guard result.utf8.count <= TaskFileService.fileLimit, !result.utf8.contains(0) else {
            throw NativeAgentError.unsupported("The replacement exceeds the text-file limit.")
        }
        return result
    }
}
