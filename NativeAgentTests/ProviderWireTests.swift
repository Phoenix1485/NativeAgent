import Foundation
import XCTest
@testable import NativeAgent

private actor WireFixture {
    let input: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation
    private var requests: [JSONValue] = []
    private let responses: [String: JSONValue]
    init(_ responses: [String: JSONValue]) {
        self.responses = responses
        (input, continuation) = AsyncStream.makeStream()
    }
    func write(_ data: Data) throws {
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        requests.append(value)
        guard let method = value["method"]?.stringValue, let id = value["id"] else { return }
        var data = try JSONEncoder().encode(JSONValue.object(["id": id, "result": responses[method] ?? .object([:])]))
        data.append(10); continuation.yield(data)
    }
    func snapshot() -> [JSONValue] { requests }
    func finish() { continuation.finish() }
}

final class ProviderWireTests: XCTestCase {
    func testCodexWireContainsDefaultModelThinkingAndSandbox() async throws {
        let fixture = WireFixture(["thread/start": .object(["thread": .object(["id": .string("thread")])]), "turn/start": .object(["turn": .object(["id": .string("turn")])])])
        let client = RPCClient { try await fixture.write($0) }
        let consume = Task { await client.consume(fixture.input) }
        let provider = CodexProvider(binaryPath: "/never-launched", rpcClient: client)
        await provider.configure(.init(reasoning: "high", access: .readOnly, instructions: "Use Swift"))
        let id = try await provider.startThread(projectPath: "/test", model: "model")
        try await provider.startTurn(threadID: id, prompt: "Hello", projectPath: "/test", model: "model")
        let requests = await fixture.snapshot()
        XCTAssertEqual(requests[0]["params"]?["sandbox"], .string("read-only"))
        XCTAssertEqual(requests[0]["params"]?["approvalPolicy"], .string("on-request"))
        XCTAssertEqual(requests[0]["params"]?["developerInstructions"], .string("Use Swift"))
        XCTAssertEqual(requests[1]["params"]?["effort"], .string("high"))
        XCTAssertEqual(requests[1]["params"]?["model"], .string("model"))
        XCTAssertEqual(requests[1]["params"]?["sandboxPolicy"]?["type"], .string("readOnly"))
        await fixture.finish(); await consume.value; await client.close()
    }
    func testCodexAPIKeyUsesOfficialLoginRequest() async throws {
        let fixture = WireFixture(["account/read": .object(["account": .object(["type": .string("apiKey")])])])
        let client = RPCClient { try await fixture.write($0) }
        let consume = Task { await client.consume(fixture.input) }
        let provider = CodexProvider(binaryPath: "/never-launched", rpcClient: client)
        try await provider.login(apiKey: "test-fake-key")
        let requests = await fixture.snapshot()
        XCTAssertEqual(requests[0]["method"], .string("account/login/start"))
        XCTAssertEqual(requests[0]["params"]?["type"], .string("apiKey"))
        XCTAssertEqual(requests[0]["params"]?["apiKey"], .string("test-fake-key"))
        await fixture.finish(); await consume.value; await client.close()
    }
    func testGrokACPModelConfigurationAndPrompt() async throws {
        let modelOption: JSONValue = .object(["id": .string("models"), "category": .string("model"), "currentValue": .string("grok-test"), "options": .array([.object(["value": .string("grok-test"), "name": .string("Grok Test")])])])
        let fixture = WireFixture([
            "session/new": .object(["sessionId": .string("grok-session"), "configOptions": .array([modelOption])]),
            "session/set_config_option": .object(["configOptions": .array([modelOption])]),
            "session/prompt": .object(["stopReason": .string("end_turn")])
        ])
        let client = RPCClient(jsonRPCVersion: true) { try await fixture.write($0) }
        let consume = Task { await client.consume(fixture.input) }
        let provider = GrokProvider(path: "/never-launched", rpcClient: client)
        let events = await provider.events
        let completion = Task { for await event in events { if case .turnCompleted = event { return true } }; return false }
        let session = try await provider.startThread(projectPath: "/test", model: nil)
        let models = await provider.loadModels()
        XCTAssertEqual(models.map(\.id), ["grok-test"])
        try await provider.startTurn(threadID: session, prompt: "Hello", projectPath: "/test", model: "grok-test")
        let completed = await completion.value
        XCTAssertTrue(completed)
        let requests = await fixture.snapshot()
        XCTAssertTrue(requests.allSatisfy { $0["jsonrpc"] == .string("2.0") })
        XCTAssertEqual(requests[1]["method"], .string("session/set_config_option"))
        XCTAssertEqual(requests[1]["params"]?["value"], .string("grok-test"))
        XCTAssertEqual(requests[2]["params"]?["sessionId"], .string("grok-session"))
        await fixture.finish(); await consume.value; await client.close()
    }
}
