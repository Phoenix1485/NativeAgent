import Foundation

/// Direct, public SIWC + Responses integration. This type never starts a process.
/// Local execution is intentionally unavailable: account consent is not shell/file permission.
actor ChatGPTProvider: CodingProvider {
    let events: AsyncStream<ProviderEvent>
    private let continuation: AsyncStream<ProviderEvent>.Continuation
    private let store: any ChatGPTCredentialStoring
    private let http: ChatGPTHTTP
    private var loginTask: Task<Void, Never>?
    private var turnTask: Task<Void, Never>?
    private var refreshTask: Task<ChatGPTRegistration, Error>?
    private var generation = UUID()
    private var configuration = RunConfiguration()
    private var authenticated = false
    private var currentTurnID: String?

    init(store: any ChatGPTCredentialStoring = ChatGPTKeychainStore(), http: ChatGPTHTTP = ChatGPTHTTP()) {
        self.store = store; self.http = http
        (events, continuation) = AsyncStream.makeStream()
    }
    static var capabilities: ProviderCapabilities {
        .init(subscriptionAuth: true, apiKeyAuth: false, structuredStreaming: true, resume: false,
              interrupt: true, nativeApprovals: false, fileChangeEvents: false, usageReporting: false,
              imageInput: false, modelDiscovery: true, terminalSession: false)
    }
    func inspect() -> ProviderInspection {
        .init(binaryPath: nil, version: nil, isExecutable: false, capabilities: Self.capabilities,
              message: "Direct browser authorization and HTTPS streaming. No Codex installation. Chat and explicitly attached context only; local commands and automatic edits are not enabled.")
    }
    func connect() async throws {
        continuation.yield(.inspection(inspect()))
        guard try store.load().active?.tokens != nil else { continuation.yield(.authenticationRequired); return }
        let operation = generation
        let registration = try await validRegistration()
        let models = try await fetchModels(token: registration.tokens!.accessToken)
        guard operation == generation else { throw CancellationError() }
        publishAccount(registration); continuation.yield(.models(models))
    }
    func disconnect() {
        generation = UUID(); loginTask?.cancel(); loginTask = nil
        turnTask?.cancel(); turnTask = nil; refreshTask?.cancel(); refreshTask = nil
        currentTurnID = nil; authenticated = false
    }
    func cancelLogin() { disconnect() }
    func beginLogin() throws {
        guard loginTask == nil else { throw NativeAgentError.alreadyRunning }
        generation = UUID()
        let operation = generation
        // Do not inspect a CLI or require an existing credential before opening the browser.
        continuation.yield(.inspection(inspect()))
        loginTask = Task { await authorize(operation: operation) }
    }
    private func authorize(operation: UUID) async {
        let listener = ChatGPTLoopback()
        let timeout = Task {
            do { try await Task.sleep(for: .seconds(300)); listener.cancel() } catch { }
        }
        defer { timeout.cancel(); listener.cancel(); if generation == operation { loginTask = nil } }
        do {
            try await withTaskCancellationHandler {
                var record = try store.load()
                try record.prepareHostID()
                try store.save(record) // Persist the host ID before its first registration.
                let redirect = try await listener.start()
                try Task.checkCancellation()
                let attempt = try ChatGPTAuthorizationAttempt(redirect: redirect, registration: record.active)
                continuation.yield(.loginURL(try attempt.authorizationURL(hostID: record.hostID).absoluteString))
                let result = try attempt.validateCallback(await listener.result())
                try Task.checkCancellation()
                let response = try await http.json(URL(string: ChatGPTAuth.issuer + "/api/accounts/oauth/token")!, form: [
                    "grant_type": "authorization_code", "client_id": result.clientID, "code": result.code,
                    "code_verifier": attempt.verifier, "redirect_uri": redirect.absoluteString, "resource": ChatGPTAuth.resource])
                let tokens = try Self.tokens(response)
                guard let idToken = tokens.idToken else { throw ChatGPTAuth.failure("ChatGPT returned no identity token.") }
                let jwks = try await http.json(URL(string: ChatGPTAuth.issuer + "/.well-known/jwks.json")!)
                let identity = try ChatGPTIdentityValidator.validate(idToken, jwks: jwks, clientID: result.clientID, nonce: attempt.nonce)
                guard attempt.registration == nil || attempt.registration?.subject == identity.subject else {
                    throw ChatGPTAuth.failure("The signed-in account differs from the selected registration. Choose Add account to use another account.")
                }
                try Task.checkCancellation()
                guard operation == generation else { throw CancellationError() }
                let registration = ChatGPTRegistration(clientID: result.clientID, subject: identity.subject, email: identity.email, tokens: tokens)
                record.registrations.removeAll { $0.clientID == result.clientID }
                record.registrations.append(registration); record.activeClientID = result.clientID
                try store.save(record)
                publishAccount(registration)
                do {
                    let models = try await fetchModels(token: tokens.accessToken)
                    if operation == generation { continuation.yield(.models(models)) }
                } catch {
                    if operation == generation { continuation.yield(.diagnostic("Signed in, but the model catalog could not be loaded. Use Refresh in Models.")) }
                }
            } onCancel: { listener.cancel() }
        } catch {
            if operation == generation {
                authenticated = false
                let message = error is CancellationError ? "Browser sign-in expired or was cancelled. Try again." : Self.safeMessage(error)
                continuation.yield(.authenticationFailed(message))
            }
        }
    }
    static func tokens(_ response: [String: Any], previous: ChatGPTTokens? = nil, now: Date = .now) throws -> ChatGPTTokens {
        guard let token = response["access_token"] as? String, !token.isEmpty,
              (response["token_type"] as? String)?.lowercased() == "bearer",
              let expiry = (response["expires_in"] as? NSNumber)?.doubleValue, expiry > 0, expiry <= 86_400,
              let scope = response["scope"] as? String ?? previous?.scope,
              Set(scope.split(separator: " ").map(String.init)).isSuperset(of: ["chatgpt.tokens.use.direct", "resource.invoke"]) else {
            throw ChatGPTAuth.failure("ChatGPT plan access was not granted. Sign in again and authorize plan use; no API key fallback was used.")
        }
        return .init(accessToken: token, refreshToken: response["refresh_token"] as? String ?? previous?.refreshToken,
                     idToken: response["id_token"] as? String ?? previous?.idToken, expiresAt: now.addingTimeInterval(expiry),
                     earliestRefreshAt: (response["earliest_refresh_at"] as? Double).map { Date(timeIntervalSince1970: $0) }, scope: scope)
    }
    private func validRegistration() async throws -> ChatGPTRegistration {
        if let refreshTask { return try await refreshTask.value }
        guard var registration = try store.load().active, let tokens = registration.tokens else {
            throw ChatGPTAuth.failure("Choose Continue with ChatGPT to authorize NativeAgent in your browser.")
        }
        if tokens.expiresAt.timeIntervalSinceNow > 60 { return registration }
        guard let refresh = tokens.refreshToken else { throw ChatGPTAuth.failure("Your ChatGPT session expired. Sign in again.") }
        if let earliest = tokens.earliestRefreshAt, earliest > .now {
            throw ChatGPTAuth.failure("ChatGPT does not allow session renewal yet. Wait briefly and reconnect.")
        }
        let operation = generation
        let task = Task<ChatGPTRegistration, Error> {
            let response = try await http.json(URL(string: ChatGPTAuth.issuer + "/api/accounts/oauth/token")!, form: [
                "grant_type": "refresh_token", "client_id": registration.clientID,
                "refresh_token": refresh, "resource": ChatGPTAuth.resource])
            let replacement = try Self.tokens(response, previous: tokens)
            if let idToken = response["id_token"] as? String {
                let jwks = try await http.json(URL(string: ChatGPTAuth.issuer + "/.well-known/jwks.json")!)
                let identity = try ChatGPTIdentityValidator.validate(idToken, jwks: jwks, clientID: registration.clientID, nonce: nil)
                guard identity.subject == registration.subject else { throw ChatGPTAuth.failure("ChatGPT returned a different account during renewal. Sign in again.") }
            }
            try Task.checkCancellation()
            guard operation == generation else { throw CancellationError() }
            registration.tokens = replacement
            var record = try store.load()
            guard record.activeClientID == registration.clientID,
                  let index = record.registrations.firstIndex(where: { $0.clientID == registration.clientID }) else { throw CancellationError() }
            record.registrations[index] = registration; try store.save(record)
            return registration
        }
        refreshTask = task
        defer { if operation == generation { refreshTask = nil } }
        return try await task.value
    }
    func logout() async throws {
        disconnect()
        var record = try store.load()
        guard let index = record.registrations.firstIndex(where: { $0.clientID == record.activeClientID }) else { return }
        let registration = record.registrations[index]
        var revoked = registration.tokens?.refreshToken == nil
        if let refresh = registration.tokens?.refreshToken {
            do {
                let discovery = try await http.json(URL(string: ChatGPTAuth.issuer + "/.well-known/openid-configuration")!)
                guard let endpoint = discovery["revocation_endpoint"] as? String, let url = URL(string: endpoint),
                      url.scheme == "https", url.host == "auth.openai.com", url.user == nil, url.password == nil else {
                    throw ChatGPTAuth.failure("Remote revocation is unavailable.")
                }
                _ = try await http.json(url, form: ["token": refresh, "token_type_hint": "refresh_token", "client_id": registration.clientID])
                revoked = true
            } catch { revoked = false }
        }
        record.registrations[index].tokens = nil; try store.save(record)
        continuation.yield(.authenticationRequired)
        if !revoked { throw ChatGPTAuth.failure("Signed out locally. Remote revocation was not confirmed; disconnect NativeAgent in ChatGPT Settings → Usage to revoke access.") }
    }
    private func publishAccount(_ registration: ChatGPTRegistration) {
        authenticated = true
        continuation.yield(.accountDetails(.init(email: registration.email, method: .account, configuration: "NativeAgent Keychain · direct ChatGPT connection")))
        continuation.yield(.connected(account: registration.email ?? "ChatGPT account"))
    }
    func configure(_ configuration: RunConfiguration) { self.configuration = configuration }
    func loadModels() async throws -> [ProviderModel] {
        let registration = try await validRegistration()
        return try await fetchModels(token: registration.tokens!.accessToken)
    }
    private func fetchModels(token: String) async throws -> [ProviderModel] {
        let response = try await http.json(URL(string: ChatGPTAuth.resource + "/models")!, token: token)
        return try Self.models(response)
    }
    static func models(_ response: [String: Any]) throws -> [ProviderModel] {
        guard let models = response["models"] as? [[String: Any]] else { throw ChatGPTAuth.failure("ChatGPT returned an unrecognized model catalog.") }
        var seen = Set<String>()
        return models.compactMap { model in
            guard model["visibility"] as? String == "list", let id = model["slug"] as? String, !id.isEmpty,
                  seen.insert(id).inserted, let name = model["display_name"] as? String else { return nil }
            return ProviderModel(id: id, displayName: name, description: "Available from this ChatGPT account")
        }
    }
    func startThread(projectPath: String, model: String?) throws -> String { "chatgpt-direct/" + UUID().uuidString }
    func resumeThread(id: String, projectPath: String) throws { /* Context is explicitly resent by WorkspaceViewModel. */ }
    func startTurn(threadID: String, prompt: String, projectPath: String, model: String?) throws {
        guard authenticated else { throw ChatGPTAuth.failure("Connect your ChatGPT account first.") }
        guard turnTask == nil else { throw NativeAgentError.alreadyRunning }
        guard let model, !model.isEmpty else { throw ChatGPTAuth.failure("Choose an available ChatGPT model in Settings → Models.") }
        let id = UUID().uuidString; currentTurnID = id
        let operation = generation, instructions = configuration.instructions
        continuation.yield(.turnStarted(id))
        turnTask = Task { await stream(id: id, prompt: prompt, model: model, instructions: instructions, operation: operation) }
    }
    private func stream(id: String, prompt: String, model: String, instructions: String, operation: UUID) async {
        defer { if generation == operation { turnTask = nil; currentTurnID = nil } }
        do {
            let registration = try await validRegistration()
            var request = URLRequest(url: URL(string: ChatGPTAuth.resource + "/responses")!)
            request.httpMethod = "POST"
            request.setValue("Bearer " + registration.tokens!.accessToken, forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["model": model,
                "input": [["role": "user", "content": prompt]], "store": false, "stream": true,
                "instructions": "You are assisting inside NativeAgent. You have no shell or filesystem tools. Only use the conversation and explicitly supplied context. Do not claim you executed commands or changed local files.\n" + instructions])
            let (bytes, response) = try await http.session.bytes(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else { throw ChatGPTHTTPError(status: status) }
            // AsyncBytes.lines omits empty lines on macOS. Preserve SSE event boundaries ourselves.
            var framer = ChatGPTEventFramer()
            for try await byte in bytes {
                try Task.checkCancellation()
                guard generation == operation else { throw CancellationError() }
                if let frame = try framer.push(byte), try handleFrame(frame, turnID: id) {
                    return
                }
            }
            if let frame = try framer.finish(), try handleFrame(frame, turnID: id) { return }
            throw ChatGPTAuth.failure("The ChatGPT stream ended without completion. Partial output was preserved; nothing was automatically retried.")
        } catch {
            guard generation == operation else { return }
            let canceled = Task.isCancelled || error is CancellationError
            if let error = error as? ChatGPTHTTPError {
                if error.status == 429 { continuation.yield(.usageLimitReached) }
                if error.status == 401 || error.status == 403 { authenticated = false; continuation.yield(.authenticationFailed(Self.safeMessage(error))) }
            }
            continuation.yield(.turnCompleted(turnID: id, status: canceled ? .interrupted : .failed, error: canceled ? nil : Self.safeMessage(error)))
        }
    }
    private func handleFrame(_ frame: String, turnID: String) throws -> Bool {
        guard let data = frame.data(using: .utf8), let event = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = event["type"] as? String else { throw ChatGPTAuth.failure("ChatGPT returned an invalid stream event.") }
        switch type {
        case "response.output_text.delta", "response.refusal.delta":
            if let delta = event["delta"] as? String { continuation.yield(.agentDelta(turnID: turnID, text: delta)) }
        case "response.completed":
            continuation.yield(.turnCompleted(turnID: turnID, status: .completed, error: nil)); return true
        case "response.failed", "response.incomplete", "error":
            let response = event["response"] as? [String: Any]
            let error = response?["error"] as? [String: Any] ?? event["error"] as? [String: Any]
            let code = error?["code"] as? String ?? event["code"] as? String ?? ""
            if ["subscription_sharing_usage_limit_exceeded", "subscription_sharing_usage_unavailable"].contains(code) {
                continuation.yield(.usageLimitReached)
                throw ChatGPTAuth.failure("ChatGPT plan usage is currently unavailable or exhausted. Review usage in ChatGPT Settings. No API billing fallback was used.")
            }
            throw ChatGPTAuth.failure("ChatGPT reported a failed or incomplete response. Partial output was preserved.")
        default: break
        }
        return false
    }
    func answerApproval(id: String, decision: ApprovalDecision) throws { throw NativeAgentError.unsupported("Local tool execution in the direct ChatGPT connection") }
    func interrupt(threadID: String, turnID: String?) { turnTask?.cancel() }
    private static func safeMessage(_ error: Error) -> String {
        if error is NativeAgentError || error is ChatGPTHTTPError { return error.localizedDescription }
        return "The secure ChatGPT connection could not complete. Check your network and try again."
    }
}

struct ChatGPTEventFramer {
    private var line = Data()
    private var frame = Data()
    mutating func push(_ byte: UInt8) throws -> String? {
        guard line.count + frame.count < 4_194_304 else { throw ChatGPTAuth.failure("ChatGPT returned an oversized stream event.") }
        if byte != 10 { line.append(byte); return nil }
        if line.last == 13 { line.removeLast() }
        defer { line.removeAll(keepingCapacity: true) }
        if line.isEmpty {
            guard !frame.isEmpty else { return nil }
            defer { frame.removeAll(keepingCapacity: true) }
            guard let value = String(data: frame, encoding: .utf8) else { throw ChatGPTAuth.failure("ChatGPT returned invalid stream text.") }
            return value
        }
        if line.starts(with: Data("data:".utf8)) {
            var payload = line.dropFirst(5)
            if payload.first == 32 { payload = payload.dropFirst() }
            frame.append(contentsOf: payload); frame.append(10)
        }
        return nil
    }
    mutating func finish() throws -> String? {
        if !line.isEmpty { if let value = try push(10) { return value } }
        return try push(10)
    }
}
