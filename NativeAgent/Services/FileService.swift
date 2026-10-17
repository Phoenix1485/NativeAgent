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

enum FileBrowserFilter: String, CaseIterable, Identifiable, Sendable {
    case all, code, documents, images

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "All files"
        case .code: return "Code"
        case .documents: return "Documents"
        case .images: return "Images"
        }
    }

    fileprivate func includes(name: String) -> Bool {
        let name = name.lowercased()
        let fileExtension = (name as NSString).pathExtension
        switch self {
        case .all:
            return true
        case .code:
            return Self.codeExtensions.contains(fileExtension) || Self.codeNames.contains(name)
        case .documents:
            return Self.documentExtensions.contains(fileExtension) || Self.documentNames.contains(name)
        case .images:
            return Self.imageExtensions.contains(fileExtension)
        }
    }

    private static let codeExtensions: Set<String> = [
        "swift", "js", "jsx", "ts", "tsx", "mjs", "cjs", "py", "html", "htm", "css", "scss", "sass", "less",
        "vue", "svelte", "json", "jsonc", "yaml", "yml", "toml", "xml", "sql", "sh", "bash", "zsh", "fish",
        "c", "h", "cc", "cpp", "cxx", "hpp", "m", "mm", "cs", "java", "kt", "kts", "go", "rs", "rb", "php",
        "dart", "r", "lua", "pl", "pm", "ex", "exs", "erl", "hrl", "clj", "cljs", "cljc", "edn", "fs", "fsx",
        "fsi", "vb", "ps1", "bat", "cmd", "graphql", "gql", "proto", "lock", "ini", "conf", "cfg"
    ]
    private static let codeNames: Set<String> = ["makefile", "dockerfile", "justfile", "gemfile", "rakefile", "procfile", "cmakelists.txt"]
    private static let documentExtensions: Set<String> = [
        "md", "markdown", "mdx", "txt", "rst", "rtf", "pdf", "doc", "docx", "odt", "pages", "csv", "tsv",
        "xls", "xlsx", "ods", "numbers", "ppt", "pptx", "odp", "key", "log", "org", "tex"
    ]
    private static let documentNames: Set<String> = ["readme", "license", "licence", "notice", "authors", "changelog", "contributing"]
    private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "avif", "svg", "ico", "icns", "tiff", "tif", "bmp", "raw", "eps", "psd", "ai"
    ]
}

struct FileSearchResult: Sendable {
    let files: [FileNode]
    let isTruncated: Bool
}

actor FileService {
    static let defaultExcluded = Set([".git", "node_modules", ".build", "DerivedData", "target", "dist"])
    private let previewLimit = 2 * 1_024 * 1_024

    func search(root: String, query: String, filter: FileBrowserFilter = .all, limit: Int = 500) throws -> FileSearchResult {
        try Task.checkCancellation()
        let rootURL = URL(fileURLWithPath: root, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
        guard try rootURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
            throw NativeAgentError.unsupported("The selected project is not a directory.")
        }
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .nameKey]
        var isTruncated = false
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles],
            errorHandler: { _, _ in
                isTruncated = true
                return true
            }
        ) else {
            throw NativeAgentError.unsupported("The selected project could not be searched.")
        }
        let tokens = query.split(whereSeparator: \.isWhitespace).map(String.init)
        let rootPrefix = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"
        let resultLimit = max(0, limit)
        var files: [FileNode] = []
        var visitedCount = 0
        while let url = enumerator.nextObject() as? URL {
            try Task.checkCancellation()
            visitedCount += 1
            guard visitedCount <= 20_000 else {
                isTruncated = true
                break
            }
            let values: URLResourceValues
            do {
                values = try url.resourceValues(forKeys: keys)
            } catch {
                isTruncated = true
                continue
            }
            if Self.defaultExcluded.contains(url.lastPathComponent) {
                if values.isDirectory == true { enumerator.skipDescendants() }
                continue
            }
            // Never follow aliases into another project, or back into an ancestor.
            // URL enumerators do not descend into symbolic links. Calling
            // skipDescendants for a leaf can instead skip the next directory.
            if values.isSymbolicLink == true {
                if values.isDirectory == true { enumerator.skipDescendants() }
                continue
            }
            // Foundation may enumerate /var and /tmp roots using their /private
            // aliases. Normalize both sides before checking containment or
            // calculating a relative path, after rejecting symbolic links.
            let resolvedPath = url.standardizedFileURL.resolvingSymlinksInPath().path
            guard resolvedPath.hasPrefix(rootPrefix) else {
                isTruncated = true
                if values.isDirectory == true { enumerator.skipDescendants() }
                continue
            }
            guard values.isRegularFile == true else { continue }
            let relativePath = String(resolvedPath.dropFirst(rootPrefix.count))
            guard filter.includes(name: url.lastPathComponent),
                  tokens.allSatisfy({ relativePath.range(of: $0, options: .caseInsensitive) != nil }) else { continue }
            do {
                _ = try safeURL(root: rootURL, relativePath: relativePath)
            } catch {
                isTruncated = true
                continue
            }
            guard files.count < resultLimit else {
                isTruncated = true
                break
            }
            files.append(FileNode(
                id: relativePath,
                name: values.name ?? url.lastPathComponent,
                relativePath: relativePath,
                isDirectory: false,
                isSymbolicLink: false
            ))
        }
        try Task.checkCancellation()
        files.sort { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
        return FileSearchResult(files: files, isTruncated: isTruncated)
    }

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
