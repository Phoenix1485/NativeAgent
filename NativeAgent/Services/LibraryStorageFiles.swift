import Foundation
import Darwin

/// Inventories only this application's database, backup folder and dedicated cache folder.
actor LibraryStorageFiles {
    let databaseURL: URL
    let cacheRoot: URL
    private let fileManager = FileManager.default

    init(databaseURL: URL, cacheRoot: URL? = nil) {
        self.databaseURL = databaseURL.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(databaseURL.lastPathComponent)
        let cache = cacheRoot ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "NativeAgent", isDirectory: true)
        self.cacheRoot = cache.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(cache.lastPathComponent, isDirectory: true)
    }

    func inventory(limit: Int = 10_000) throws -> LibraryDiskStorage {
        var result = LibraryDiskStorage()
        for suffix in ["", "-wal", "-shm"] {
            let location = URL(fileURLWithPath: databaseURL.path + suffix)
            if let item = try? file(at: location, kind: .cache) { result.databaseBytes += item.bytes }
        }
        var visited = 0
        let maximum = max(1, min(limit, 50_000))
        let roots: [(URL, LibraryStorageFileKind)] = [(LibrarySnapshots.folder(for: databaseURL), .backup), (cacheRoot, .cache)]
        for (root, kind) in roots {
            guard fileManager.fileExists(atPath: root.path) else { continue }
            try validateRoot(root)
            guard let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey], options: []) else { continue }
            for case let candidate as URL in enumerator {
                try Task.checkCancellation()
                guard visited < maximum else { result.isPartial = true; break }
                visited += 1
                let values = try candidate.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
                // Foundation does not descend into symlinks. Calling skipDescendants on a link
                // can incorrectly skip the next real directory on some macOS versions.
                if values.isSymbolicLink == true { continue }
                if kind == .backup && values.isDirectory == true { enumerator.skipDescendants(); continue }
                guard kind != .backup || recognizedBackup(candidate), let item = try? file(at: candidate, kind: kind) else { continue }
                result.files.append(item)
                if kind == .backup { result.backupBytes += item.bytes } else { result.cacheBytes += item.bytes }
            }
        }
        result.files.sort { $0.bytes == $1.bytes ? $0.id < $1.id : $0.bytes > $1.bytes }
        return result
    }

    /// Revalidate both ownership and the exact file shown in the confirmation before removal.
    func delete(_ selected: [LibraryStorageFile]) throws -> Int {
        guard selected.count <= 100 else { throw failure("Select at most 100 files at a time.") }
        var verified: [URL] = []
        for item in selected {
            let root = item.kind == .backup ? LibrarySnapshots.folder(for: databaseURL) : cacheRoot
            try validateRoot(root)
            let candidate = item.url.standardizedFileURL
            guard candidate.path.hasPrefix(root.standardizedFileURL.path + "/"),
                  item.kind != .backup || (candidate.deletingLastPathComponent() == root.standardizedFileURL && recognizedBackup(candidate)) else {
                throw failure("This file is outside the app’s managed storage.")
            }
            var parent = candidate.deletingLastPathComponent()
            while parent.path.count >= root.path.count {
                guard try parent.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw failure("Symbolic links cannot be cleaned up here.") }
                if parent == root { break }
                parent.deleteLastPathComponent()
            }
            let current = try file(at: candidate, kind: item.kind)
            guard current.identity == item.identity, current.modifiedAt == item.modifiedAt, current.bytes == item.bytes else {
                throw failure("“\(candidate.lastPathComponent)” changed. Refresh storage before deleting it.")
            }
            verified.append(candidate)
        }
        for candidate in Set(verified) {
            guard let item = selected.first(where: { $0.url.standardizedFileURL == candidate }) else { continue }
            let root = item.kind == .backup ? LibrarySnapshots.folder(for: databaseURL) : cacheRoot
            try unlinkReviewedFile(item, root: root)
        }
        return Set(verified).count
    }

    private func unlinkReviewedFile(_ item: LibraryStorageFile, root: URL) throws {
        // Walk from / through directory descriptors. A symlink replacement cannot redirect unlinkat.
        var descriptor = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw failure("Could not open managed storage.") }
        defer { Darwin.close(descriptor) }
        let relative = item.url.standardizedFileURL.path.dropFirst(root.path.count + 1).split(separator: "/").map(String.init)
        // Foundation can normalize /private/var back to the /var alias. POSIX realpath keeps
        // the physical components needed by an O_NOFOLLOW walk on macOS.
        guard let resolved = Darwin.realpath(root.path, nil) else { throw failure("Storage changed. Refresh before deleting files.") }
        let physicalRoot = String(cString: resolved)
        free(resolved)
        let parents = physicalRoot.split(separator: "/").map(String.init) + relative.dropLast()
        for component in parents {
            let next = Darwin.openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            guard next >= 0 else { throw failure("Storage changed. Refresh before deleting files.") }
            Darwin.close(descriptor)
            descriptor = next
        }
        guard let name = relative.last else { throw failure("Invalid storage file.") }
        var status = stat()
        guard fstatat(descriptor, name, &status, AT_SYMLINK_NOFOLLOW) == 0,
              status.st_mode & S_IFMT == S_IFREG,
              String(status.st_dev) + ":" + String(status.st_ino) == item.identity,
              Int64(status.st_size) == item.bytes else {
            throw failure("The selected file changed. Refresh before deleting it.")
        }
        let modifiedAt = Double(status.st_mtimespec.tv_sec) + Double(status.st_mtimespec.tv_nsec) / 1_000_000_000
        guard abs(modifiedAt - item.modifiedAt.timeIntervalSince1970) < 0.000_001 else {
            throw failure("The selected file changed. Refresh before deleting it.")
        }
        // unlinkat without AT_REMOVEDIR never recursively removes directories.
        guard unlinkat(descriptor, name, 0) == 0 else { throw failure("Could not remove “\(name)”. Refresh storage and try again.") }
    }

    private func validateRoot(_ root: URL) throws {
        let values = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true,
              root.resolvingSymlinksInPath().standardizedFileURL == root.standardizedFileURL else {
            throw failure("Storage folder is not a regular application-owned directory.")
        }
    }

    private func recognizedBackup(_ url: URL) -> Bool {
        url.pathExtension == "sqlite3" && ["daily-", "manual-", "before-restore-"].contains { url.lastPathComponent.hasPrefix($0) }
    }

    private func file(at url: URL, kind: LibraryStorageFileKind) throws -> LibraryStorageFile {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw failure("Only regular storage files can be selected.") }
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        let inode = (attributes[.systemFileNumber] as? NSNumber)?.stringValue ?? ""
        let device = (attributes[.systemNumber] as? NSNumber)?.stringValue ?? ""
        return LibraryStorageFile(url: url.standardizedFileURL, kind: kind, bytes: Int64(values.fileSize ?? 0),
                                  modifiedAt: values.contentModificationDate ?? .distantPast, identity: device + ":" + inode)
    }

    private func failure(_ message: String) -> Error { NativeAgentError.unsupported(message) }
}
