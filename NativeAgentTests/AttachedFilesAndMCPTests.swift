import Foundation
import XCTest
@testable import NativeAgent

final class AttachedFilesAndMCPTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("NativeAgentFiles-" + UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func testExplicitSavePreservesUTF8LineEndingsAndMode() async throws {
        let url = root.appendingPathComponent("script.swift")
        try Data("let café = 1\r\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        let service = AttachedFileService(), initial = try await service.load(url)
        let changed = try AttachedFileService.replacing(initial, old: "= 1", new: "= 2")
        XCTAssertEqual(try Data(contentsOf: url), initial.data, "Preparing an edit must not write")
        let saved = try await service.save(initial, text: changed)
        XCTAssertEqual(saved.text, "let café = 2\r\n")
        XCTAssertEqual(try Data(contentsOf: url), saved.data)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int, 0o755)
    }

    func testSaveRejectsExternalChangesAndSymlinkSwap() async throws {
        let url = root.appendingPathComponent("file.txt"), other = root.appendingPathComponent("other.txt")
        try Data("original".utf8).write(to: url)
        try Data("other".utf8).write(to: other)
        let service = AttachedFileService(), initial = try await service.load(url)
        try Data("external change".utf8).write(to: url)
        do { _ = try await service.save(initial, text: "replacement"); XCTFail("Overwrote newer edit") } catch {}
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "external change")
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: other)
        do { _ = try await service.save(initial, text: "replacement"); XCTFail("Followed symlink") } catch {}
        do { _ = try await service.load(url); XCTFail("Attached symlink") } catch {}
        XCTAssertEqual(try String(contentsOf: other, encoding: .utf8), "other")
    }

    func testRejectsBinaryOversizeDirectoryAndAmbiguousReplacements() async throws {
        let service = AttachedFileService(), url = root.appendingPathComponent("file")
        for data in [Data([0, 1, 2]), Data([0xff]), Data(repeating: 65, count: TaskFileService.fileLimit + 1)] {
            try data.write(to: url)
            do { _ = try await service.load(url); XCTFail("Accepted unsupported file") } catch {}
        }
        do { _ = try await service.load(root); XCTFail("Accepted directory") } catch {}
        let snapshot = AttachedFileSnapshot(url: url, data: Data("aa aa".utf8))
        for old in ["", "missing", "aa"] { XCTAssertThrowsError(try AttachedFileService.replacing(snapshot, old: old, new: "b")) }
    }

    func testOlderAttachmentsDecodeWithoutWritePermission() throws {
        let old = ContextAttachment(kind: .attachment, title: "Old", text: "data")
        let restored = try JSONDecoder().decode(ContextAttachment.self, from: JSONEncoder().encode(old))
        XCTAssertNil(restored.sourceURL); XCTAssertNil(restored.allowEdits)
    }

    func testMCPToolValidationAndNumericIDsDoNotCrash() throws {
        let result: JSONValue = .object(["tools": .array([.object(["name": .string("echo"), "inputSchema": .object(["type": .string("object")])])])])
        XCTAssertEqual(try MCPConnection.parseTools(result).first?.name, "echo")
        XCTAssertThrowsError(try MCPConnection.parseTools(.object([:])))
        XCTAssertThrowsError(try MCPConnection.parseTools(.object(["tools": .array([.object(["name": .string("bad")])])])) )
        XCTAssertNil(JSONValue.number(1e100).intValue)
        XCTAssertNil(JSONValue.number(1.5).intValue)
        XCTAssertNil(JSONValue.number(.infinity).intValue)
        XCTAssertEqual(JSONValue.number(42).intValue, 42)
    }

    func testRealStdioMCPHandshakePaginationCallAndDisconnect() async throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/mcp-server.py")
        let connection = MCPConnection()
        let tools = try await connection.connect(.init(name: "Test fixture", executable: "/usr/bin/python3", arguments: [fixture.path]))
        XCTAssertEqual(tools.map(\.name), ["echo", "second"])
        let result = try await connection.call(tools[0], arguments: .object(["text": .string("hello")]))
        XCTAssertTrue(result.contains("hello"))
        await connection.disconnect()
        do { _ = try await connection.call(tools[0], arguments: .object([:])); XCTFail("Called disconnected server") } catch {}
    }

    func testStopUnblocksBackpressuredPipeWithoutBlockingTransportActor() async throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/mcp-server.py")
        let transport = ProcessTransport()
        _ = try await transport.start(binary: URL(fileURLWithPath: "/usr/bin/python3"), arguments: [fixture.path, "--ignore-input"], workingDirectory: root)
        let write = Task { try await transport.write(Data(repeating: 65, count: 1_048_576)) }
        try await Task.sleep(for: .milliseconds(100))
        let start = ContinuousClock.now
        await transport.stop()
        do { try await write.value; XCTFail("Write to stopped server succeeded") } catch {}
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(2))
    }

    func testCancelPendingMCPCallClosesConnectionAndDoesNotRetry() async throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/mcp-server.py")
        let connection = MCPConnection()
        let tools = try await connection.connect(.init(name: "Fixture", executable: "/usr/bin/python3", arguments: [fixture.path]))
        let call = Task { try await connection.call(tools[0], arguments: .object(["text": .string("wait-without-reply")])) }
        try await Task.sleep(for: .milliseconds(100))
        let start = ContinuousClock.now
        call.cancel()
        do { _ = try await call.value; XCTFail("Canceled tool returned success") } catch {}
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(2))
        await connection.disconnect()
    }

    @MainActor
    func testMCPConfigurationIsPersistedButNeverAutostarted() throws {
        let suite = "MCPTests." + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = MCPManager(defaults: defaults)
        try manager.add(name: "Fixture", executable: "/usr/bin/python3", arguments: "[\"server.py\"]")
        let restored = MCPManager(defaults: defaults)
        XCTAssertEqual(restored.servers, manager.servers)
        XCTAssertTrue(restored.connected.isEmpty); XCTAssertTrue(restored.toolBindings().isEmpty)
        XCTAssertThrowsError(try manager.add(name: "Bad", executable: "sh", arguments: "[]"))
        XCTAssertThrowsError(try manager.add(name: "Bad", executable: "/usr/bin/python3", arguments: "--shell arguments"))
    }
}
