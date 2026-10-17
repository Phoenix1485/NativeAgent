import Foundation
import XCTest
@testable import NativeAgent

private actor AuthWire {
    let input: AsyncStream<Data>
    let sink: AsyncStream<Data>.Continuation
    var requests: [JSONValue] = []
    var account: JSONValue = .object(["type": .string("chatgpt"), "email": .string("fixture@example.invalid"), "planType": .string("plus")])
    init() { (input, sink) = AsyncStream.makeStream() }
    func setAccount(_ value: JSONValue) { account = value }
    func write(_ data: Data) throws {
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        requests.append(value)
        guard let method = value["method"]?.stringValue, let id = value["id"] else { return }
        let result: JSONValue
        switch method {
        case "account/login/start": result = .object(["type": .string("chatgpt"), "loginId": .string("current-login"), "authUrl": .string("https://auth.openai.com/fixture")])
        case "account/read": result = .object(["account": account])
        case "model/list": result = .object(["data": .array([.object(["id": .string("fixture-model"), "displayName": .string("Fixture")])])])
        default: result = .object([:])
        }
        var frame = try JSONEncoder().encode(JSONValue.object(["id": id, "result": result])); frame.append(10)
        sink.yield(frame)
    }
    func snapshot() -> [JSONValue] { requests }
    func finish() { sink.finish() }
}

final class AuthenticationTests: XCTestCase {
    func testClaudeRequiresExplicitSuccessfulStatusAndMatchingBillingMode() throws {
        func status(_ text: String, _ method: AuthenticationMethod = .account, _ code: Int32 = 0) throws -> ProviderAccount? {
            try ClaudeProvider.validatedAccount(Data(text.utf8), exitCode: code, method: method)
        }
        XCTAssertThrowsError(try status("not JSON"))
        XCTAssertThrowsError(try status("{}"))
        XCTAssertNil(try status(#"{"loggedIn":false,"authMethod":"claude.ai"}"#))
        for method in ["api_key", "api_key_helper", "third_party", "oauth_token", "future_method"] {
            XCTAssertNil(try status("{\"loggedIn\":true,\"authMethod\":\"\(method)\"}"))
        }
        let account = try status(#"{"loggedIn":true,"authMethod":"claude.ai","email":"test@example.invalid","subscriptionType":"pro"}"#)
        XCTAssertEqual(account?.email, "test@example.invalid")
        XCTAssertEqual(account?.plan, "pro")
        XCTAssertNil(try status(#"{"loggedIn":true,"authMethod":"claude.ai"}"#, .apiKey))
        XCTAssertNotNil(try status(#"{"loggedIn":true,"authMethod":"api_key"}"#, .apiKey))
        XCTAssertThrowsError(try status("", .account, 9))
    }

    func testInheritedCredentialsCannotSelectAnotherBillingMode() {
        var inherited = Dictionary(uniqueKeysWithValues: ProviderExecutable.credentialVariables.map { ($0, "inherited-secret") })
        inherited["CODEX_WIF_TOKEN_FILE"] = "secret-path"
        inherited["CODEX_HOME"] = "/custom/codex-profile"
        inherited["CLAUDE_CONFIG_DIR"] = "/custom/claude-profile"
        for kind in ProviderKind.allCases {
            let environment = ProviderExecutable.environment(kind: kind, key: nil, inherited: inherited)
            for name in ProviderExecutable.credentialVariables { XCTAssertNil(environment[name], name) }
            XCTAssertNil(environment["CODEX_WIF_TOKEN_FILE"])
            XCTAssertEqual(environment["CODEX_HOME"], "/custom/codex-profile")
            XCTAssertEqual(environment["CLAUDE_CONFIG_DIR"], "/custom/claude-profile")
        }
        let selected = ProviderExecutable.environment(kind: .claude, key: "selected-fake-key", inherited: inherited)
        XCTAssertEqual(selected["ANTHROPIC_API_KEY"], "selected-fake-key")
        XCTAssertNil(selected["OPENAI_API_KEY"])
        XCTAssertEqual(inherited["ANTHROPIC_API_KEY"], "inherited-secret")
    }

    func testCodexDoesNotTreatUnknownAuthAsSubscription() {
        for type in ["apiKey", "amazonBedrock", "chatgptAuthTokens", "unknown"] {
            XCTAssertNotEqual(CodexProvider.authenticationMethod(.object(["type": .string(type)])), .account)
        }
        XCTAssertNil(CodexProvider.authenticationMethod(.object([:])))
        XCTAssertEqual(CodexProvider.authenticationMethod(.object(["type": .string("chatgpt")])), .account)
    }

    func testCodexLoginWaitsForMatchingCompletionThenReadsAccountAndModels() async throws {
        let wire = AuthWire()
        let rpc = RPCClient { try await wire.write($0) }
        let consume = Task { await rpc.consume(wire.input) }
        let provider = CodexProvider(binaryPath: "/never-launched", rpcClient: rpc)
        try await provider.beginLogin()
        await provider.handle(.init(method: "account/login/completed", params: .object(["loginId": .string("stale-login"), "success": .bool(true)])))
        var requests = await wire.snapshot()
        XCTAssertEqual(requests.count, 1)
        await provider.handle(.init(method: "account/updated", params: .object(["authMode": .string("chatgpt")])))
        requests = await wire.snapshot()
        XCTAssertEqual(requests.count, 1, "Account updates cannot complete an outstanding browser login")
        await provider.handle(.init(method: "account/login/completed", params: .object(["loginId": .string("current-login"), "success": .bool(true)])))
        requests = await wire.snapshot()
        XCTAssertEqual(requests.compactMap { $0["method"]?.stringValue }, ["account/login/start", "account/read", "model/list", "account/rateLimits/read"])
        XCTAssertEqual(requests[1]["params"]?["refreshToken"], .bool(true))
        await provider.disconnect(); await wire.finish(); await consume.value
    }

    func testCancelledCodexLoginRejectsLateSuccess() async throws {
        let wire = AuthWire()
        let rpc = RPCClient { try await wire.write($0) }
        let consume = Task { await rpc.consume(wire.input) }
        let provider = CodexProvider(binaryPath: "/never-launched", rpcClient: rpc)
        try await provider.beginLogin()
        await provider.cancelLogin()
        await provider.handle(.init(method: "account/login/completed", params: .object(["loginId": .string("current-login"), "success": .bool(true)])))
        await provider.handle(.init(method: "account/updated", params: .object(["authMode": .string("chatgpt")])))
        let requests = await wire.snapshot()
        XCTAssertEqual(requests.compactMap { $0["method"]?.stringValue }, ["account/login/start", "account/login/cancel"])
        XCTAssertEqual(requests.last?["params"]?["loginId"], .string("current-login"))
        await provider.disconnect(); await wire.finish(); await consume.value
    }

    func testApprovalResponsesRespectExactAdvertisedChoicesAndCannotReplay() async throws {
        let wire = AuthWire()
        let rpc = RPCClient { try await wire.write($0) }
        let provider = CodexProvider(binaryPath: "/never-launched", rpcClient: rpc)
        await provider.handle(RPCServerRequest(id: .string("permission"), method: "item/commandExecution/requestApproval",
            params: .object(["availableDecisions": .array([.string("decline")])])) )
        do { try await provider.answerApproval(id: "s:permission", decision: .accept); XCTFail("Accepted an unavailable choice") } catch {}
        try await provider.answerApproval(id: "s:permission", decision: .decline)
        do { try await provider.answerApproval(id: "s:permission", decision: .decline); XCTFail("Replayed approval") } catch {}
        let requests = await wire.snapshot()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0]["id"], .string("permission"))
        XCTAssertEqual(requests[0]["result"]?["decision"], .string("decline"))
        await provider.disconnect()
    }

    func testBrowserClosureTimeoutCancelsTheProviderLogin() async throws {
        let wire = AuthWire()
        let rpc = RPCClient { try await wire.write($0) }
        let consume = Task { await rpc.consume(wire.input) }
        let provider = CodexProvider(binaryPath: "/never-launched", rpcClient: rpc, loginTimeout: .milliseconds(20))
        let events = await provider.events
        let timedOut = expectation(description: "Recoverable browser timeout")
        let observer = Task {
            for await event in events {
                if case .authenticationFailed = event { timedOut.fulfill(); return }
            }
        }
        try await provider.beginLogin()
        await fulfillment(of: [timedOut], timeout: 2)
        let requests = await wire.snapshot()
        XCTAssertEqual(requests.last?["method"], .string("account/login/cancel"))
        observer.cancel(); await provider.disconnect(); await wire.finish(); await consume.value
    }

    func testSuccessfulBrowserCallbackDoesNotAcceptAPIKeyAccount() async throws {
        let wire = AuthWire()
        await wire.setAccount(.object(["type": .string("apiKey")]))
        let rpc = RPCClient { try await wire.write($0) }
        let consume = Task { await rpc.consume(wire.input) }
        let provider = CodexProvider(binaryPath: "/never-launched", rpcClient: rpc)
        let events = await provider.events
        let rejected = expectation(description: "Mismatched account rejected")
        let observer = Task {
            for await event in events {
                if case .connected = event { XCTFail("API key accepted as subscription") }
                if case .authenticationFailed = event { rejected.fulfill(); return }
            }
        }
        try await provider.beginLogin()
        await provider.handle(.init(method: "account/login/completed", params: .object(["loginId": .string("current-login"), "success": .bool(true)])))
        await fulfillment(of: [rejected], timeout: 2)
        let requests = await wire.snapshot()
        XCTAssertFalse(requests.contains { $0["method"] == .string("model/list") })
        observer.cancel(); await provider.disconnect(); await wire.finish(); await consume.value
    }

    func testUsageOnlyContainsProviderSuppliedWindowsAndResets() throws {
        let payload = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"rateLimits":{"primary":{"usedPercent":81},"secondary":null}}"#.utf8))
        let windows = CodexProvider.usageWindows(payload)
        XCTAssertEqual(windows.count, 1)
        XCTAssertEqual(windows[0].usedPercent, 81)
        XCTAssertNil(windows[0].resetsAt)
        XCTAssertNil(windows[0].durationMinutes)
        XCTAssertTrue(CodexProvider.usageWindows(.object([:])).isEmpty)
    }

    func testSchemaChecksRejectIncorrectWireEnumsAndMissingRequiredFields() throws {
        let schema = try JSONDecoder().decode(JSONValue.self, from: Data(##"{"definitions":{"Policy":{"enum":["on-request","never"],"type":"string"}},"properties":{"approvalPolicy":{"$ref":"#/definitions/Policy"},"sandbox":{"enum":["read-only","workspace-write"]}},"required":["approvalPolicy"],"type":"object"}"##.utf8))
        XCTAssertTrue(SchemaSubset.accepts(.object(["approvalPolicy": .string("on-request"), "sandbox": .string("read-only")]), schema: schema, root: schema))
        XCTAssertFalse(SchemaSubset.accepts(.object(["approvalPolicy": .string("onRequest")]), schema: schema, root: schema))
        XCTAssertFalse(SchemaSubset.accepts(.object([:]), schema: schema, root: schema))
        let sum = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"oneOf":[{"properties":{"type":{"enum":["chatgpt"]}},"required":["type"],"type":"object"},{"properties":{"type":{"enum":["apiKey"]},"apiKey":{"type":"string"}},"required":["type","apiKey"],"type":"object"}]}"#.utf8))
        XCTAssertTrue(SchemaSubset.accepts(.object(["type": .string("chatgpt")]), schema: sum, root: sum))
        XCTAssertFalse(SchemaSubset.accepts(.object(["type": .string("apiKey")]), schema: sum, root: sum))
    }

    func testQuestionAnswersRequireVerifiedSchemaAdvertisedChoicesAndCannotReplay() async throws {
        let schema = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"type":"object","required":["answers"],"properties":{"answers":{"type":"object","additionalProperties":{"type":"object","required":["answers"],"properties":{"answers":{"type":"array","items":{"type":"string"}}}}}}}"#.utf8))
        let wire = AuthWire(), rpc = RPCClient { try await wire.write($0) }
        let provider = CodexProvider(binaryPath: "/never-launched", rpcClient: rpc, questionResponseSchema: schema)
        let params = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"turnId":"t","questions":[{"id":"q","question":"Choose?","header":"Choice","isOther":false,"options":[{"label":"Safe option","description":"Do this"}]}]}"#.utf8))
        await provider.handle(RPCServerRequest(id: .string("input"), method: "item/tool/requestUserInput", params: params))
        do { try await provider.answerQuestion(id: "s:input", answers: ["q": "Not advertised"]); XCTFail("Accepted unsupported choice") } catch { }
        try await provider.answerQuestion(id: "s:input", answers: ["q": "Safe option"])
        do { try await provider.answerQuestion(id: "s:input", answers: ["q": "Safe option"]); XCTFail("Replayed question") } catch { }
        let frames = await wire.snapshot()
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames.first?["result"]?["answers"]?["q"]?["answers"], .array([.string("Safe option")]))
        XCTAssertNil(CodexProvider.parseQuestions(.object(["questions": .array([])])))
        let unverified = CodexProvider(binaryPath: "/never-launched", rpcClient: rpc)
        await unverified.handle(RPCServerRequest(id: .string("unknown"), method: "item/tool/requestUserInput", params: params))
        let denied = await wire.snapshot()
        XCTAssertNotNil(denied.last?["error"])
        await provider.disconnect(); await unverified.disconnect()
    }

    func testTerminalPathsAreShellQuotedAndCredentialsNeverEnterJob() throws {
        XCTAssertEqual(OfficialClaudeTerminal.shellQuote("/tmp/user's $(touch nope)"), "'/tmp/user'\\''s $(touch nope)'")
        let job = ClaudeTerminalJob(action: .login, executable: "/tmp/claude", configurationDirectory: "/tmp/profile", method: .account)
        XCTAssertEqual(job.arguments, ["auth", "login"])
        let json = String(decoding: try JSONEncoder().encode(job), as: UTF8.self)
        XCTAssertFalse(json.contains("access_token")); XCTAssertFalse(json.contains("refresh_token"))
    }

    func testCommandTimeoutAndEarlyExitAreNotSuccessfulLogin() async throws {
        let runner = ProviderCommand()
        do {
            _ = try await runner.run(path: "/bin/sleep", arguments: ["5"], environment: [:], timeout: .milliseconds(30))
            XCTFail("Timeout was accepted")
        } catch { XCTAssertEqual(error as? NativeAgentError, .requestTimedOut) }
        let result = try await ProviderCommand().run(path: "/usr/bin/false", arguments: [], environment: [:])
        XCTAssertNotEqual(result.code, 0)
    }
}
