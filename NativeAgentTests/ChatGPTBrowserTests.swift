import CryptoKit
import Foundation
import Security
import XCTest
@testable import NativeAgent

final class MemoryChatGPTCredentials: ChatGPTCredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var record = ChatGPTCredentialRecord()
    func load() -> ChatGPTCredentialRecord { lock.lock(); defer { lock.unlock() }; return record }
    func save(_ record: ChatGPTCredentialRecord) { lock.lock(); defer { lock.unlock() }; self.record = record }
}

private actor ToolExecutionCounter {
    var count = 0
    func run() -> String { count += 1; return "fixture tool result" }
}

private final class ChatGPTFixtureProtocol: URLProtocol {
    static let lock = NSLock()
    static var stream = ""
    static var queuedStreams: [String] = []
    static var requests: [URLRequest] = []
    static var authResponses: [String: Data] = [:]
    static func prepare(_ value: String) { lock.lock(); defer { lock.unlock() }; stream = value; queuedStreams = []; requests = [] }
    static func prepareStreams(_ values: [String]) { lock.lock(); defer { lock.unlock() }; queuedStreams = values; stream = ""; requests = [] }
    static func setAuth(_ responses: [String: Data]) { lock.lock(); defer { lock.unlock() }; authResponses = responses }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var captured = request
        if captured.httpBody == nil, let input = request.httpBodyStream {
            input.open(); defer { input.close() }
            var data = Data(), bytes = [UInt8](repeating: 0, count: 4096)
            while input.hasBytesAvailable {
                let count = input.read(&bytes, maxLength: bytes.count)
                if count <= 0 { break }; data.append(contentsOf: bytes.prefix(count))
            }
            captured.httpBody = data
        }
        Self.lock.lock(); Self.requests.append(captured)
        let stream = request.url?.path == "/v1/responses" && !Self.queuedStreams.isEmpty ? Self.queuedStreams.removeFirst() : Self.stream
        let auth = Self.authResponses[request.url?.path ?? ""]; Self.lock.unlock()
        let isModels = request.url?.path == "/v1/models"
        let body = isModels ? #"{"models":[{"slug":"fixture","display_name":"Fixture","visibility":"list"}]}"# : stream
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": isModels ? "application/json" : "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: auth ?? Data(body.utf8)); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class ChatGPTBrowserTests: XCTestCase {
    private let redirect = URL(string: "http://127.0.0.1:54321/auth/callback")!
    private let fixtureHostID = "urn:uuid:550e8400-e29b-41d4-a716-446655440000"
    private func callback(_ attempt: ChatGPTAuthorizationAttempt, changes: [String: String] = [:]) -> URL {
        var url = URLComponents(url: attempt.redirect, resolvingAgainstBaseURL: false)!
        let values = ["state": attempt.state, "code": "fake-code", "client_id": "oaiapp_fixture"].merging(changes) { _, new in new }
        url.queryItems = values.map { .init(name: $0.key, value: $0.value) }; return url.url!
    }
    private func b64(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    func testFreshBrowserRequestUsesOwnDynamicRegistrationAndPKCE() throws {
        let attempt = try ChatGPTAuthorizationAttempt(redirect: redirect, registration: nil)
        let second = try ChatGPTAuthorizationAttempt(redirect: redirect, registration: nil)
        let url = try attempt.authorizationURL(hostID: fixtureHostID)
        let values = Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value!) })
        XCTAssertEqual(url.host, "auth.openai.com")
        XCTAssertEqual(url.path, "/api/accounts/authorize")
        XCTAssertEqual(values["client_id"], "dynamic_agent_client")
        XCTAssertEqual(values["agent_name_hint"], "NativeAgent")
        XCTAssertEqual(values["ext_agent_host_id"], fixtureHostID)
        XCTAssertEqual(values["redirect_uri"], redirect.absoluteString)
        XCTAssertEqual(values["code_challenge"], b64(Data(SHA256.hash(data: Data(attempt.verifier.utf8)))))
        XCTAssertNil(values["client_secret"])
        XCTAssertNotEqual(attempt.state, second.state); XCTAssertNotEqual(attempt.nonce, second.nonce)
        XCTAssertNotEqual(attempt.verifier, second.verifier)
        XCTAssertFalse(url.absoluteString.contains(attempt.verifier))
    }
    func testReturningRegistrationReusesClientWithoutRegistrationHint() throws {
        let account = ChatGPTRegistration(clientID: "oaiapp_saved", subject: "sub", email: "a@example.invalid")
        let attempt = try ChatGPTAuthorizationAttempt(redirect: redirect, registration: account)
        let values = Dictionary(uniqueKeysWithValues: URLComponents(url: try attempt.authorizationURL(hostID: fixtureHostID), resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value!) })
        XCTAssertEqual(values["client_id"], "oaiapp_saved"); XCTAssertNil(values["agent_name_hint"])
        XCTAssertThrowsError(try attempt.validateCallback(callback(attempt)))
        var url = URLComponents(url: callback(attempt), resolvingAgainstBaseURL: false)!
        url.queryItems?.removeAll { $0.name == "client_id" }
        XCTAssertEqual(try attempt.validateCallback(url.url!).clientID, "oaiapp_saved")
    }
    func testRejectsStateMismatchExpiredDeniedDuplicateAndWrongCallback() throws {
        let attempt = try ChatGPTAuthorizationAttempt(redirect: redirect, registration: nil)
        XCTAssertEqual(try attempt.validateCallback(callback(attempt)).clientID, "oaiapp_fixture")
        for changes in [["state": "wrong"], ["client_id": "dynamic_agent_client"], ["code": ""], ["error": "access_denied"]] {
            XCTAssertThrowsError(try attempt.validateCallback(callback(attempt, changes: changes)))
        }
        XCTAssertThrowsError(try attempt.validateCallback(callback(attempt), now: attempt.createdAt.addingTimeInterval(301)))
        XCTAssertThrowsError(try attempt.validateCallback(URL(string: callback(attempt).absoluteString + "&state=" + attempt.state)!))
        for replacement in ["http://localhost:54321/auth/callback", "http://127.0.0.1:1234/auth/callback", "http://127.0.0.1:54321/callback"] {
            let url = URL(string: callback(attempt).absoluteString.replacingOccurrences(of: redirect.absoluteString, with: replacement))!
            XCTAssertThrowsError(try attempt.validateCallback(url))
        }
    }
    func testFormEncodingDoesNotTreatPlusAndAmpersandAsSyntax() {
        XCTAssertEqual(String(decoding: ChatGPTAuth.form(["value": "a+b&c=d /?"]), as: UTF8.self), "value=a%2Bb%26c%3Dd%20%2F%3F")
    }
    func testNewHostIsPersistableUUIDv4URIAndStaysStable() throws {
        var record = ChatGPTCredentialRecord()
        let original = record.hostID
        XCTAssertTrue(ChatGPTHostID.isValid(original))
        XCTAssertNotEqual(original, ChatGPTCredentialRecord().hostID)
        try record.prepareHostID()
        let restored = try JSONDecoder().decode(ChatGPTCredentialRecord.self, from: JSONEncoder().encode(record))
        XCTAssertEqual(restored.hostID, original)
    }
    func testLegacyBareUUIDMigrationPreservesIdentityRegistrationsAndCredentials() throws {
        var record = ChatGPTCredentialRecord()
        record.hostID = "550E8400-E29B-41D4-A716-446655440000"
        record.activeClientID = "oaiapp_existing"
        record.registrations = [.init(clientID: "oaiapp_existing", subject: "existing-subject", email: "fixture@example.invalid",
            tokens: .init(accessToken: "fixture-access", refreshToken: "fixture-refresh", idToken: "fixture-id", expiresAt: .distantFuture, scope: ChatGPTAuth.scope))]
        let originalRegistrations = try JSONEncoder().encode(record.registrations)
        // Exercise decoding the exact format saved by the previous build.
        var restored = try JSONDecoder().decode(ChatGPTCredentialRecord.self, from: JSONEncoder().encode(record))
        try restored.prepareHostID()
        XCTAssertEqual(restored.hostID, "urn:uuid:" + record.hostID)
        XCTAssertEqual(restored.activeClientID, record.activeClientID)
        XCTAssertEqual(try JSONDecoder().decode([ChatGPTRegistration].self, from: originalRegistrations).first?.tokens?.refreshToken, restored.active?.tokens?.refreshToken)
        XCTAssertEqual(restored.active?.subject, record.active?.subject)
        XCTAssertEqual(restored.active?.tokens?.accessToken, record.active?.tokens?.accessToken)
        XCTAssertEqual(restored.active?.tokens?.idToken, record.active?.tokens?.idToken)
        let migratedID = restored.hostID
        try restored.prepareHostID()
        XCTAssertEqual(restored.hostID, migratedID)
        let reloaded = try JSONDecoder().decode(ChatGPTCredentialRecord.self, from: JSONEncoder().encode(restored))
        XCTAssertEqual(reloaded.hostID, migratedID)
    }
    func testInvalidHostIDsCannotReachBrowserAuthorization() throws {
        let attempt = try ChatGPTAuthorizationAttempt(redirect: redirect, registration: nil)
        for host in ["stable-host", "", "550e8400-e29b-41d4-a716-446655440000", "urn:uuid:invalid", "urn:uuid:550e8400-e29b-11d4-a716-446655440000", fixtureHostID + "\n"] {
            XCTAssertThrowsError(try attempt.authorizationURL(hostID: host))
        }
        var record = ChatGPTCredentialRecord()
        record.hostID = "malformed"
        XCTAssertThrowsError(try record.prepareHostID())
        XCTAssertEqual(record.hostID, "malformed")
    }
    func testVerifiesCryptographicSignatureAndAllIdentityBindings() throws {
        let key = P256.Signing.PrivateKey()
        let representation = key.publicKey.x963Representation
        let jwks: [String: Any] = ["keys": [["kid": "fixture", "kty": "EC", "crv": "P-256", "alg": "ES256", "use": "sig",
            "x": b64(representation.subdata(in: 1..<33)), "y": b64(representation.subdata(in: 33..<65))]]]
        let now = Date()
        let claims: [String: Any] = ["iss": ChatGPTAuth.issuer, "aud": "oaiapp_fixture", "sub": "subject", "nonce": "nonce",
            "iat": now.timeIntervalSince1970, "exp": now.addingTimeInterval(120).timeIntervalSince1970, "email": "fixture@example.invalid"]
        func token(_ changes: [String: Any] = [:], wrongKey: Bool = false) throws -> String {
            let header = try b64(JSONSerialization.data(withJSONObject: ["kid": "fixture", "alg": "ES256"]))
            let payload = try b64(JSONSerialization.data(withJSONObject: claims.merging(changes) { _, new in new }))
            let message = header + "." + payload
            let signature = try (wrongKey ? P256.Signing.PrivateKey() : key).signature(for: Data(message.utf8))
            return message + "." + b64(signature.rawRepresentation)
        }
        let valid = try ChatGPTIdentityValidator.validate(token(), jwks: jwks, clientID: "oaiapp_fixture", nonce: "nonce", now: now)
        XCTAssertEqual(valid.subject, "subject"); XCTAssertEqual(valid.email, "fixture@example.invalid")
        for changes: [String: Any] in [["iss": "https://attacker.invalid"], ["aud": "another-client"], ["nonce": "another-nonce"],
            ["exp": now.addingTimeInterval(-60).timeIntervalSince1970], ["iat": now.addingTimeInterval(60).timeIntervalSince1970],
            ["sub": ""], ["aud": ["oaiapp_fixture", "another"], "azp": "another"], ["nbf": now.addingTimeInterval(60).timeIntervalSince1970]] {
            XCTAssertThrowsError(try ChatGPTIdentityValidator.validate(token(changes), jwks: jwks, clientID: "oaiapp_fixture", nonce: "nonce", now: now))
        }
        XCTAssertThrowsError(try ChatGPTIdentityValidator.validate(token(wrongKey: true), jwks: jwks, clientID: "oaiapp_fixture", nonce: "nonce"))
        XCTAssertThrowsError(try ChatGPTIdentityValidator.validate("a.b.c", jwks: jwks, clientID: "oaiapp_fixture", nonce: "nonce"))
    }
    func testIdentityOnlyPermissionCannotEnablePlanUseAndRefreshRotatesTokens() throws {
        let response: [String: Any] = ["access_token": "fake-access", "refresh_token": "fake-refresh", "id_token": "fake-id", "token_type": "Bearer", "expires_in": 3600, "scope": ChatGPTAuth.scope]
        let original = try ChatGPTProvider.tokens(response)
        XCTAssertThrowsError(try ChatGPTProvider.tokens(response.merging(["scope": "openid email profile"]) { _, new in new }))
        XCTAssertThrowsError(try ChatGPTProvider.tokens(response.merging(["token_type": "wrong"]) { _, new in new }))
        let refreshed = try ChatGPTProvider.tokens(["access_token": "replacement", "refresh_token": "rotated", "token_type": "Bearer", "expires_in": 3600], previous: original)
        XCTAssertEqual(refreshed.refreshToken, "rotated"); XCTAssertEqual(refreshed.scope, original.scope)
    }
    func testRS256IdentitySignatureUsesPublishedRSAKey() throws {
        let privateKey = try XCTUnwrap(SecKeyCreateRandomKey([kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048] as CFDictionary, nil))
        let publicKey = try XCTUnwrap(SecKeyCopyPublicKey(privateKey))
        let data = try XCTUnwrap(SecKeyCopyExternalRepresentation(publicKey, nil)) as Data
        var position = 0
        func field(_ expectedTag: UInt8) throws -> Data {
            XCTAssertEqual(data[position], expectedTag); position += 1
            var length = Int(data[position]); position += 1
            if length >= 128 {
                let count = length & 127; length = 0
                for _ in 0..<count { length = length << 8 | Int(data[position]); position += 1 }
            }
            if expectedTag == 0x30 { return Data() }
            let value = data.subdata(in: position..<(position + length)); position += length
            return value.first == 0 ? Data(value.dropFirst()) : value
        }
        _ = try field(0x30)
        let modulus = try field(0x02), exponent = try field(0x02)
        let jwks: [String: Any] = ["keys": [["kid": "rsa", "kty": "RSA", "alg": "RS256", "n": b64(modulus), "e": b64(exponent)]]]
        let header = try b64(JSONSerialization.data(withJSONObject: ["kid": "rsa", "alg": "RS256"]))
        let payload = try b64(JSONSerialization.data(withJSONObject: ["iss": ChatGPTAuth.issuer, "aud": "oaiapp_test", "sub": "subject", "nonce": "n",
            "iat": Date().timeIntervalSince1970, "exp": Date().addingTimeInterval(120).timeIntervalSince1970]))
        let message = header + "." + payload
        let signature = try XCTUnwrap(SecKeyCreateSignature(privateKey, .rsaSignatureMessagePKCS1v15SHA256, Data(message.utf8) as CFData, nil)) as Data
        let identity = try ChatGPTIdentityValidator.validate(message + "." + b64(signature), jwks: jwks, clientID: "oaiapp_test", nonce: "n")
        XCTAssertEqual(identity.subject, "subject")
    }
    func testAccountSpecificCatalogHidesUnlistedAndUnknownModels() throws {
        let models = try ChatGPTProvider.models(["models": [
            ["slug": "visible", "display_name": "Visible", "visibility": "list"],
            ["slug": "hidden", "display_name": "Hidden", "visibility": "hidden"],
            ["slug": "visible", "display_name": "Duplicate", "visibility": "list"]]])
        XCTAssertEqual(models.map(\.id), ["visible"])
        XCTAssertTrue(models[0].reasoningEfforts.isEmpty)
        XCTAssertThrowsError(try ChatGPTProvider.models(["data": []]))
        XCTAssertTrue(ChatGPTProvider.capabilities.nativeApprovals)
        XCTAssertTrue(ChatGPTProvider.capabilities.fileChangeEvents)
    }
    @MainActor
    func testRealLoginButtonPathOpensBrowserWithoutAnExecutableAndCancellationClearsListener() async throws {
        let suite = "NativeAgentBrowserTests.\(UUID())", directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let opened = expectation(description: "Browser authorization URL")
        var browserURL: URL?
        let store = MemoryChatGPTCredentials()
        var legacy = store.load()
        legacy.hostID = "550e8400-e29b-41d4-a716-446655440000"
        store.save(legacy)
        let model = WorkspaceViewModel(database: try DatabaseActor(url: directory.appendingPathComponent("db.sqlite3")), files: FileService(), git: GitService(),
            automaticallyRestore: false, preferences: defaults, credentials: MemoryCredentials(), chatGPTCredentials: store,
            openBrowser: { url in browserURL = url; opened.fulfill(); return true })
        model.settings.update(.codex) { $0.binaryPath = "/never-execute/codex" }
        await model.login()
        await fulfillment(of: [opened], timeout: 10)
        XCTAssertEqual(browserURL?.host, "auth.openai.com")
        let browserHostID = browserURL.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "ext_agent_host_id" })?.value }
        XCTAssertEqual(browserHostID, fixtureHostID)
        XCTAssertEqual(store.load().hostID, fixtureHostID)
        XCTAssertNil(model.providerInspection?.binaryPath)
        XCTAssertEqual(model.connectionStatus, .signingIn)
        XCTAssertTrue(model.accountActionInProgress)
        XCTAssertNil(store.load().active?.tokens)
        await model.cancelLogin()
        XCTAssertEqual(model.connectionStatus, .notAuthenticated)
        XCTAssertFalse(model.accountActionInProgress)
        XCTAssertNil(store.load().active?.tokens)
    }
    func testLoopbackReceivesOnlyCallbackAndStopsWithoutPolling() async throws {
        let listener = ChatGPTLoopback()
        defer { listener.cancel() }
        let redirect = try await listener.start()
        XCTAssertEqual(redirect.host, "127.0.0.1")
        let attempt = try ChatGPTAuthorizationAttempt(redirect: redirect, registration: nil)
        let callback = callback(attempt)
        let result = Task { try await listener.result() }
        let (data, response) = try await URLSession.shared.data(from: callback)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains(attempt.state))
        let received = try await result.value
        XCTAssertEqual(try attempt.validateCallback(received).code, "fake-code")
        listener.cancel()
    }
    func testDirectNativeStreamCompletesOnlyWithTerminalCompletion() async throws {
        for terminal in ["response.completed", "response.failed", "missing"] {
            let frame = "event: response.output_text.delta\ndata: {\"type\":\"response.output_text.delta\",\"delta\":\"Hello\"}\n\n"
            let end = terminal == "missing" ? "" : "event: \(terminal)\ndata: {\"type\":\"\(terminal)\",\"response\":{\"status\":\"\(terminal == "response.completed" ? "completed" : "failed")\"}}\n\n"
            ChatGPTFixtureProtocol.prepare(frame + end)
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [ChatGPTFixtureProtocol.self]
            let store = MemoryChatGPTCredentials()
            var record = store.load()
            record.activeClientID = "oaiapp_fixture"
            record.registrations = [.init(clientID: "oaiapp_fixture", subject: "fixture", email: "fixture@example.invalid",
                tokens: .init(accessToken: "fake-access", expiresAt: .now.addingTimeInterval(3600), scope: ChatGPTAuth.scope))]
            store.save(record)
            let provider = ChatGPTProvider(store: store, http: ChatGPTHTTP(session: URLSession(configuration: configuration)))
            let completed = expectation(description: terminal)
            let events = await provider.events
            let task = Task { () -> (String, TurnStatus?) in
                var text = ""
                for await event in events {
                    if case .agentDelta(_, let delta) = event { text += delta }
                    if case .turnCompleted(_, let status, _) = event { completed.fulfill(); return (text, status) }
                }
                return (text, nil)
            }
            try await provider.connect()
            try await provider.startTurn(threadID: "fixture-thread", prompt: "A test", projectPath: "/unused", model: "fixture")
            await fulfillment(of: [completed], timeout: 5)
            task.cancel()
            let (text, status) = await task.value
            XCTAssertEqual(text, "Hello")
            XCTAssertEqual(status, terminal == "response.completed" ? .completed : .failed)
            await provider.disconnect()
        }
    }

    func testTitleRequestUsesIsolatedTextResponseAndRejectsIncompleteOutput() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ChatGPTFixtureProtocol.self]
        let store = MemoryChatGPTCredentials()
        var record = store.load()
        record.activeClientID = "oaiapp_fixture"
        record.registrations = [.init(clientID: "oaiapp_fixture", subject: "fixture", email: "fixture@example.invalid",
            tokens: .init(accessToken: "fake-access", expiresAt: .now.addingTimeInterval(3600), scope: ChatGPTAuth.scope))]
        store.save(record)
        let provider = ChatGPTProvider(store: store, http: ChatGPTHTTP(session: URLSession(configuration: configuration)))
        ChatGPTFixtureProtocol.prepare("data: {\"type\":\"response.completed\",\"response\":{\"output\":[{\"type\":\"message\",\"content\":[{\"type\":\"output_text\",\"text\":\"Sidebar interaction improvements\"}]}]}}\n\n")
        try await provider.connect()
        let unexpected = expectation(description: "Title generation must not write to the chat event stream")
        unexpected.isInverted = true
        let events = await provider.events
        let observer = Task {
            for await event in events {
                switch event {
                case .agentDelta, .agentMessage, .turnStarted, .turnCompleted, .approval: unexpected.fulfill()
                default: break
                }
            }
        }
        let title = try await provider.titleCompletion(instructions: "Name the chat", input: "Transcript", model: "fixture")
        XCTAssertEqual(title, "Sidebar interaction improvements")
        let request = try XCTUnwrap(ChatGPTFixtureProtocol.requests.last { $0.url?.path == "/v1/responses" })
        let body = try JSONDecoder().decode(JSONValue.self, from: XCTUnwrap(request.httpBody))
        XCTAssertEqual(body["store"], .bool(false)); XCTAssertEqual(body["stream"], .bool(true))
        XCTAssertNil(body["tools"]); XCTAssertNil(body["previous_response_id"])
        XCTAssertEqual(body["model"], .string("fixture"))
        for frame in ["data: {\"type\":\"response.output_text.delta\",\"delta\":\"Partial title\"}\n\n",
                      "data: {\"type\":\"response.incomplete\"}\n\n"] {
            ChatGPTFixtureProtocol.prepare(frame)
            do {
                _ = try await provider.titleCompletion(instructions: "Name", input: "Transcript", model: "fixture")
                XCTFail("Partial output must not become a suggestion")
            } catch { }
        }
        await fulfillment(of: [unexpected], timeout: 0.1)
        observer.cancel()
        await provider.disconnect()
    }

    func testNativeToolLoopRequiresApprovalAndPreservesStatelessHistory() async throws {
        for decision in [ApprovalDecision.accept, .decline, .cancel] {
            let call: JSONValue = .object(["type": .string("function_call"), "id": .string("fc_fixture"), "call_id": .string("call_fixture"),
                "namespace": .string("nativeagent"), "name": .string("fixture_tool"), "arguments": .string("{\"text\":\"hello\"}")])
            let first: JSONValue = .object(["type": .string("response.completed"), "response": .object(["output": .array([call])])])
            let frame = "data: " + String(decoding: try JSONEncoder().encode(first), as: UTF8.self) + "\n\n"
            ChatGPTFixtureProtocol.prepareStreams([frame, "data: {\"type\":\"response.completed\",\"response\":{\"output\":[]}}\n\n"])
            let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [ChatGPTFixtureProtocol.self]
            let store = MemoryChatGPTCredentials()
            var record = store.load(); record.activeClientID = "oaiapp_fixture"
            record.registrations = [.init(clientID: "oaiapp_fixture", subject: "fixture", email: nil,
                tokens: .init(accessToken: "fake-access", expiresAt: .now.addingTimeInterval(3600), scope: ChatGPTAuth.scope))]
            store.save(record)
            let provider = ChatGPTProvider(store: store, http: ChatGPTHTTP(session: URLSession(configuration: configuration)))
            let counter = ToolExecutionCounter()
            await provider.setNativeTools([NativeTool(name: "fixture_tool", description: "Offline fixture", schema: .object(["type": .string("object")])) { _ in
                PreparedNativeTool(title: "Fixture", review: "Review exact fixture arguments") { await counter.run() }
            }])
            let completed = expectation(description: "Tool loop \(decision)")
            let events = await provider.events
            let consumer = Task { () -> TurnStatus? in
                for await event in events {
                    if case .approval(let request) = event {
                        let before = await counter.count; XCTAssertEqual(before, 0)
                        XCTAssertEqual(request.choices, [.accept, .decline, .cancel])
                        try? await provider.answerApproval(id: request.id, decision: decision)
                        do { try await provider.answerApproval(id: request.id, decision: .accept); XCTFail("Approval replay accepted") } catch {}
                    }
                    if case .turnCompleted(_, let status, _) = event { completed.fulfill(); return status }
                }
                return nil
            }
            try await provider.connect()
            try await provider.startTurn(threadID: "fixture", prompt: "Use the test tool", projectPath: "/unused", model: "fixture")
            await fulfillment(of: [completed], timeout: 5)
            consumer.cancel()
            let status = await consumer.value, count = await counter.count
            XCTAssertEqual(status, decision == .cancel ? .interrupted : .completed)
            XCTAssertEqual(count, decision == .accept ? 1 : 0)
            let requests = ChatGPTFixtureProtocol.requests.filter { $0.url?.path == "/v1/responses" }
            XCTAssertEqual(requests.count, decision == .cancel ? 1 : 2)
            let body = try JSONDecoder().decode(JSONValue.self, from: XCTUnwrap(requests.first?.httpBody))
            XCTAssertEqual(body["tools"]?.arrayValue?.first?["type"], .string("namespace"))
            XCTAssertEqual(body["tools"]?.arrayValue?.first?["name"], .string("nativeagent"))
            XCTAssertEqual(body["store"], .bool(false)); XCTAssertEqual(body["stream"], .bool(true))
            XCTAssertNil(body["previous_response_id"])
            if requests.count == 2 {
                let second = try JSONDecoder().decode(JSONValue.self, from: XCTUnwrap(requests.last?.httpBody))
                let input = try XCTUnwrap(second["input"]?.arrayValue)
                XCTAssertTrue(input.contains(call))
                XCTAssertEqual(input.last?["type"], .string("function_call_output"))
                XCTAssertTrue(input.last?["output"]?.stringValue?.contains(decision == .accept ? "fixture tool result" : "denied") == true)
            }
            await provider.disconnect()
        }
    }
    func testBrowserCallbackExchangesCodeAndSavesOnlyVerifiedAppCredentials() async throws {
        ChatGPTFixtureProtocol.prepare("")
        defer { ChatGPTFixtureProtocol.setAuth([:]) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ChatGPTFixtureProtocol.self]
        let store = MemoryChatGPTCredentials()
        let provider = ChatGPTProvider(store: store, http: ChatGPTHTTP(session: URLSession(configuration: configuration)))
        let completed = expectation(description: "Verified account")
        let events = await provider.events
        let task = Task {
            for await event in events {
                switch event {
                case .loginURL(let rawURL):
                    do {
                        let parameters = Dictionary(uniqueKeysWithValues: URLComponents(string: rawURL)!.queryItems!.map { ($0.name, $0.value!) })
                        let privateKey = P256.Signing.PrivateKey(), representation = privateKey.publicKey.x963Representation
                        let jwks: [String: Any] = ["keys": [["kid": "fixture", "kty": "EC", "crv": "P-256", "alg": "ES256",
                            "x": b64(representation.subdata(in: 1..<33)), "y": b64(representation.subdata(in: 33..<65))]]]
                        let header = try b64(JSONSerialization.data(withJSONObject: ["alg": "ES256", "kid": "fixture"]))
                        let payload = try b64(JSONSerialization.data(withJSONObject: ["iss": ChatGPTAuth.issuer, "aud": "oaiapp_fixture", "sub": "verified-subject",
                            "nonce": parameters["nonce"]!, "iat": Date().timeIntervalSince1970, "exp": Date().addingTimeInterval(3600).timeIntervalSince1970]))
                        let message = header + "." + payload
                        let token = message + "." + b64(try privateKey.signature(for: Data(message.utf8)).rawRepresentation)
                        ChatGPTFixtureProtocol.setAuth([
                            "/.well-known/jwks.json": try JSONSerialization.data(withJSONObject: jwks),
                            "/api/accounts/oauth/token": try JSONSerialization.data(withJSONObject: ["access_token": "fake-access", "refresh_token": "fake-refresh", "id_token": token,
                                "token_type": "Bearer", "expires_in": 3600, "scope": ChatGPTAuth.scope])])
                        var callback = URLComponents(string: parameters["redirect_uri"]!)!
                        callback.queryItems = [.init(name: "state", value: parameters["state"]), .init(name: "code", value: "fake-code"), .init(name: "client_id", value: "oaiapp_fixture")]
                        _ = try await URLSession.shared.data(from: callback.url!)
                    } catch { XCTFail("Local callback fixture failed: \(error)"); completed.fulfill(); return }
                case .connected:
                    completed.fulfill(); return
                case .authenticationFailed(let error):
                    XCTFail(error); completed.fulfill(); return
                default: break
                }
            }
        }
        try await provider.beginLogin()
        await fulfillment(of: [completed], timeout: 10)
        task.cancel(); await provider.disconnect()
        let registration = try XCTUnwrap(store.load().active)
        XCTAssertEqual(registration.clientID, "oaiapp_fixture")
        XCTAssertEqual(registration.subject, "verified-subject")
        XCTAssertEqual(registration.tokens?.refreshToken, "fake-refresh")
    }
}
