import Foundation

struct FileNode: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let relativePath: String
    let isDirectory: Bool
    let isSymbolicLink: Bool
}

struct FilePreview: Sendable {
    let relativePath: String
    let text: String
    let encodingName: String
    let size: Int
}

actor FileService {
    static let defaultExcluded = Set([".git", "node_modules", ".build", "DerivedData", "target", "dist"])
    private let previewLimit = 2 * 1_024 * 1_024

    func children(root: String, relativePath: String = "", excluded: Set<String> = defaultExcluded) throws -> [FileNode] {
        let rootURL = URL(fileURLWithPath: root, isDirectory: true).standardizedFileURL
        let directory = try safeURL(root: rootURL, relativePath: relativePath)
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .nameKey]
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])
            .compactMap { url in
                guard !excluded.contains(url.lastPathComponent) else { return nil }
                let values = try url.resourceValues(forKeys: keys)
                let childPath = relativePath.isEmpty ? url.lastPathComponent : relativePath + "/" + url.lastPathComponent
                return FileNode(id: childPath, name: values.name ?? url.lastPathComponent, relativePath: childPath, isDirectory: values.isDirectory == true, isSymbolicLink: values.isSymbolicLink == true)
            }
            .sorted {
                if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
    }

    func preview(root: String, relativePath: String, allowLarge: Bool = false) throws -> FilePreview {
        let rootURL = URL(fileURLWithPath: root, isDirectory: true).standardizedFileURL
        let url = try safeURL(root: rootURL, relativePath: relativePath)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
        if size > previewLimit && !allowLarge {
            throw NativeAgentError.unsupported("This file is larger than 2 MiB. Open it externally to inspect it safely.")
        }
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        if data.prefix(8_192).contains(0) { throw NativeAgentError.unsupported("Binary files are not shown as text.") }
        if let text = String(data: data, encoding: .utf8) {
            return FilePreview(relativePath: relativePath, text: text, encodingName: "UTF-8", size: size)
        }
        if let text = String(data: data, encoding: .isoLatin1) {
            return FilePreview(relativePath: relativePath, text: text, encodingName: "ISO Latin-1 (fallback)", size: size)
        }
        throw NativeAgentError.unsupported("The file encoding is not supported.")
    }

    private func safeURL(root: URL, relativePath: String) throws -> URL {
        let candidate = root.appendingPathComponent(relativePath).standardizedFileURL
        let rootPath = root.resolvingSymlinksInPath().path
        let resolved = candidate.resolvingSymlinksInPath().path
        guard resolved == rootPath || resolved.hasPrefix(rootPath + "/") else {
            throw NativeAgentError.unsupported("The path points outside the selected project.")
        }
        return candidate
    }
}
