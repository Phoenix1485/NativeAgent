import Foundation
import XCTest
@testable import NativeAgent

final class LibraryStorageFilesTests: XCTestCase {
    private var directory: URL!
    private var databaseURL: URL!
    private var cache: URL!
    private var service: LibraryStorageFiles!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        databaseURL = directory.appendingPathComponent("library.sqlite3")
        try Data(repeating: 1, count: 100).write(to: databaseURL)
        cache = directory.appendingPathComponent("Cache", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: LibrarySnapshots.folder(for: databaseURL), withIntermediateDirectories: true)
        service = LibraryStorageFiles(databaseURL: databaseURL, cacheRoot: cache)
    }

    override func tearDownWithError() throws {
        service = nil
        try? FileManager.default.removeItem(at: directory)
    }

    private func write(_ name: String, root: URL, bytes: Int) throws -> URL {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 7, count: bytes).write(to: url)
        return url
    }

    func testInventoryCountsOwnedFilesAndSkipsUnknownBackupsAndLinks() async throws {
        let backups = LibrarySnapshots.folder(for: databaseURL)
        _ = try write("manual-test.sqlite3", root: backups, bytes: 200)
        _ = try write("unknown.sqlite3", root: backups, bytes: 999)
        _ = try write("nested/preview.cache", root: cache, bytes: 30)
        _ = try write("library.sqlite3-wal", root: directory, bytes: 40)
        let outside = try write("outside.txt", root: directory, bytes: 900)
        try FileManager.default.createSymbolicLink(at: cache.appendingPathComponent("linked.cache"), withDestinationURL: outside)
        let inventory = try await service.inventory()
        XCTAssertEqual(inventory.databaseBytes, 140)
        XCTAssertEqual(inventory.backupBytes, 200)
        XCTAssertEqual(inventory.cacheBytes, 30)
        XCTAssertEqual(inventory.files.count, 2)
        XCTAssertFalse(inventory.files.contains { $0.url.lastPathComponent == "linked.cache" })
    }

    func testSelectedCleanupDeletesOnlyReviewedRegularFiles() async throws {
        let selected = try write("manual-remove.sqlite3", root: LibrarySnapshots.folder(for: databaseURL), bytes: 200)
        let keep = try write("manual-keep.sqlite3", root: LibrarySnapshots.folder(for: databaseURL), bytes: 100)
        let cacheFile = try write("preview.cache", root: cache, bytes: 30)
        let inventory = try await service.inventory()
        let entry = try XCTUnwrap(inventory.files.first { $0.url.lastPathComponent == selected.lastPathComponent })
        let count = try await service.delete([entry])
        XCTAssertEqual(count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: selected.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: keep.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: cacheFile.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: databaseURL.path))
    }

    func testChangedFileInvalidatesDeletionAndKeepsEverySelection() async throws {
        let first = try write("first.cache", root: cache, bytes: 10)
        let second = try write("second.cache", root: cache, bytes: 20)
        let inventory = try await service.inventory()
        try Data(repeating: 1, count: 100).write(to: second)
        do { _ = try await service.delete(inventory.files); XCTFail("Changed files require a fresh review") } catch { }
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
    }

    func testForgedOutsidePathAndDirectorySymlinkCannotBeDeleted() async throws {
        let original = try write("nested/preview.cache", root: cache, bytes: 10)
        let outside = try write("outside/preview.cache", root: directory, bytes: 10)
        let inventory = try await service.inventory()
        var forged = try XCTUnwrap(inventory.files.first)
        forged.url = outside
        do { _ = try await service.delete([forged]); XCTFail("Outside files must be rejected") } catch { }
        try FileManager.default.removeItem(at: original.deletingLastPathComponent())
        try FileManager.default.createSymbolicLink(at: original.deletingLastPathComponent(), withDestinationURL: outside.deletingLastPathComponent())
        do { _ = try await service.delete(inventory.files); XCTFail("A replaced directory cannot redirect deletion") } catch { }
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
    }

    func testSymlinkCacheRootAndOversizedSelectionsAreRejected() async throws {
        let outside = directory.appendingPathComponent("Outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        _ = try write("preview.cache", root: outside, bytes: 10)
        try FileManager.default.removeItem(at: cache)
        try FileManager.default.createSymbolicLink(at: cache, withDestinationURL: outside)
        do { _ = try await service.inventory(); XCTFail("A symlink cache folder cannot be managed") } catch { }
        let forged = LibraryStorageFile(url: outside.appendingPathComponent("preview.cache"), kind: .cache, bytes: 10, modifiedAt: .now, identity: "")
        do { _ = try await service.delete(Array(repeating: forged, count: 101)); XCTFail("Cleanup is bounded") } catch { }
    }

    func testInventorySignalsPartialScanInsteadOfClaimingFullSize() async throws {
        for index in 0..<12 { _ = try write("\(index).cache", root: cache, bytes: 10) }
        let inventory = try await service.inventory(limit: 5)
        XCTAssertTrue(inventory.isPartial)
        XCTAssertEqual(inventory.files.count, 5)
        XCTAssertEqual(inventory.cacheBytes, 50)
    }
}
