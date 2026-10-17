import Foundation

actor CodexProvider: CodingProvider {
    private let configuredBinaryPath: String?
    private let transport = ProcessTransport()
    private var rpc: RPCClient?
    private var consumeTask: Task<Void, Never>?
    private var notificationTask: Task<Void, Never>?
    private var requestTask: Task<Void, Never>?
    private var stderrTask: Task<Void, Never>?
    private var terminationTask: Task<Void, Never>?
    private var eventContinuation: AsyncStream<ProviderEvent>.Continuation?
    private var currentThreadID: String?
    private var currentTurnID: String?
    private var tokenUsage = CodexTurnUsageTracker()
    private var configuration = RunConfiguration()
    private var loginID: String?
    private var authenticationMethod: AuthenticationMethod
    private let command = ProviderCommand()
    private var version: String?
    private var lifecycle = UUID()
    private var startingLogin = false
    private var earlyLoginCompletion: JSONValue?
    private var loginTimer: Task<Void, Never>?
    private var authenticated = false
    private var authUpdatesAllowed = true
    private let loginTimeout: Duration
    private var pendingApprovals: [String: [ApprovalDecision]] = [:]
    private var pendingQuestions: [String: ProviderQuestionRequest] = [:]
    private var questionResponseSchema: JSONValue?

    let events: AsyncStream<ProviderEvent>

    init(binaryPath: String? = nil, rpcClient: RPCClient? = nil, authenticationMethod: AuthenticationMethod = .account, loginTimeout: Duration = .seconds(300), questionResponseSchema: JSONValue? = nil) {
        configuredBinaryPath = binaryPath
        rpc = rpcClient
        self.questionResponseSchema = questionResponseSchema
        self.authenticationMethod = authenticationMethod
        self.loginTimeout = loginTimeout
        var continuation: AsyncStream<ProviderEvent>.Continuation?
        events = AsyncStream { continuation = $0 }
        eventContinuation = continuation
    }

    func inspect() -> ProviderInspection {
        guard let path = resolvedBinaryPath() else {
            return ProviderInspection(binaryPath: nil, version: nil, isExecutable: false, capabilities: .init(), message: "Codex was not found. Choose its executable in Settings.")
        }
        let executable = FileManager.default.isExecutableFile(atPath: path)
        return ProviderInspection(
            binaryPath: path,
            version: version,
            isExecutable: executable,
            capabilities: .init(apiKeyAuth: true, usageReporting: true),
            message: executable ? "Shared provider profile: \(ProviderExecutable.profileDescription(.codex)). Disconnect preserves its login." : "The selected file is not executable."
        )
    }

    func connect() async throws {
        guard rpc == nil else { return }
        let token = lifecycle
        authUpdatesAllowed = true
        guard let path = resolvedBinaryPath(), FileManager.default.isExecutableFile(atPath: path) else {
            throw NativeAgentError.missingInstallation("Codex was not found. Choose its executable in Settings.")
        }
        version = try await RuntimeValidation.version(path: path, kind: .codex, command: command)
        emit(.inspection(inspect()))
        questionResponseSchema = try await RuntimeValidation.codexSchema(path: path, command: command)
        guard lifecycle == token else { throw CancellationError() }
        let output = try await transport.start(
            binary: URL(fileURLWithPath: path),
            arguments: ["app-server", "--listen", "stdio://", "-c", "model_provider=\"openai\""],
            workingDirectory: nil,
            environment: ProviderExecutable.environment(kind: .codex, key: nil)
        )
        let client = RPCClient(transport: transport)
        rpc = client
        consumeTask = Task {
            await client.consume(output.stdout)
            guard !Task.isCancelled else { return }
            await streamEnded()
        }
        notificationTask = Task {
            for await notification in client.notifications {
                guard !Task.isCancelled else { return }
                await self.handle(notification)
            }
        }
        requestTask = Task {
            for await request in client.serverRequests {
                guard !Task.isCancelled else { return }
                await self.handle(request)
            }
        }
        terminationTask = Task {
            for await code in output.termination {
                guard !Task.isCancelled else { return }
                await self.providerTerminated(code)
            }
        }
        stderrTask = Task {
            for await chunk in output.stderr {
                let text = String(decoding: chunk.prefix(8_192), as: UTF8.self)
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    self.emit(.diagnostic("Codex wrote diagnostic output. Consult the provider's own logs for details."))
                }
            }
        }

        do {
            _ = try await client.request(method: "initialize", params: .object([
                "clientInfo": .object([
                    "name": .string("nativeagent"),
                    "title": .string("NativeAgent"),
                    "version": .string("0.3.0")
                ]),
                "capabilities": .object([:])
            ]))
            try await client.notify(method: "initialized")
            try await refreshAccount()
        } catch {
            await disconnect()
            throw error
        }
    }

    func disconnect() async {
        lifecycle = UUID()
        loginTimer?.cancel(); loginTimer = nil
        loginID = nil; startingLogin = false; earlyLoginCompletion = nil
        authenticated = false; pendingApprovals = [:]; pendingQuestions = [:]
        await command.cancel()
        consumeTask?.cancel()
        notificationTask?.cancel()
        requestTask?.cancel()
        stderrTask?.cancel()
        terminationTask?.cancel()
        consumeTask = nil
        notificationTask = nil
        requestTask = nil
        stderrTask = nil
        terminationTask = nil
        await rpc?.close()
        rpc = nil
        await transport.stop()
        currentThreadID = nil
        currentTurnID = nil
        tokenUsage = CodexTurnUsageTracker()
    }

    func beginLogin() async throws {
        if authenticated, authenticationMethod == .account { return }
        authenticationMethod = .account
        let client = try connectedClient()
        await cancelLogin()
        let token = lifecycle
        authenticated = false; startingLogin = true; authUpdatesAllowed = true
        defer { startingLogin = false }
        let result = try await client.request(method: "account/login/start", params: .object(["type": .string("chatgpt")]), timeout: .seconds(120))
        guard lifecycle == token else { throw CancellationError() }
        guard let id = result["loginId"]?.stringValue, !id.isEmpty, let url = result["authUrl"]?.stringValue else {
            throw NativeAgentError.protocolError("The provider did not return a login ID and URL")
        }
        loginID = id; startingLogin = false
        emit(.loginURL(url))
        loginTimer = Task {
            do { try await Task.sleep(for: loginTimeout) } catch { return }
            guard loginID == id else { return }
            await cancelLogin()
            emit(.authenticationFailed("Browser sign-in timed out. Reconnect to check your account or start sign-in again."))
        }
        if let completion = earlyLoginCompletion {
            earlyLoginCompletion = nil
            await handle(.init(method: "account/login/completed", params: completion))
        }
    }

    func cancelLogin() async {
        authUpdatesAllowed = false
        loginTimer?.cancel(); loginTimer = nil
        let id = loginID
        loginID = nil; earlyLoginCompletion = nil; startingLogin = false
        if let id, let rpc { _ = try? await rpc.request(method: "account/login/cancel", params: .object(["loginId": .string(id)]), timeout: .seconds(5)) }
    }

    func login(apiKey: String) async throws {
        authenticationMethod = .apiKey
        do { _ = try await connectedClient().request(method: "account/login/start", params: .object(["type": .string("apiKey"), "apiKey": .string(apiKey)])) }
        catch { throw NativeAgentError.providerUnavailable("API key sign-in failed. Check your key and reconnect.") }
        try await refreshAccount()
    }

    func logout() async throws {
        _ = try await connectedClient().request(method: "account/logout")
        emit(.authenticationRequired)
    }

    func configure(_ configuration: RunConfiguration) { self.configuration = configuration }

    private func refreshAccount() async throws {
        let token = lifecycle
        let result = try await connectedClient().request(method: "account/read", params: .object(["refreshToken": .bool(true)]))
        guard token == lifecycle else { return }
        authenticated = false
        guard let account = result["account"], account != .null else { emit(.authenticationRequired); return }
        guard let actualMethod = Self.authenticationMethod(account), actualMethod == authenticationMethod else { emit(.authenticationRequired); return }
        emit(.accountDetails(.init(email: account["email"]?.stringValue, plan: account["planType"]?.stringValue,
                                  method: actualMethod, configuration: ProviderExecutable.profileDescription(.codex))))
        _ = try await loadModels()
        guard token == lifecycle, loginID == nil, !startingLogin else { return }
        authenticated = true
        emit(.connected(account: account["email"]?.stringValue))
        if actualMethod == .account {
            if let limits = try? await connectedClient().request(method: "account/rateLimits/read"), token == lifecycle {
                emit(.usage(Self.usageWindows(limits)))
            }
        }
    }

    static func authenticationMethod(_ account: JSONValue) -> AuthenticationMethod? {
        switch account["type"]?.stringValue { case "chatgpt": .account; case "apiKey": .apiKey; default: nil }
    }

    static func usageWindows(_ value: JSONValue) -> [ProviderUsageWindow] {
        let buckets = value["rateLimitsByLimitId"]?.objectValue ?? ["codex": value["rateLimits"] ?? .null]
        return buckets.keys.sorted().flatMap { name in
            ["primary", "secondary"].compactMap { window -> ProviderUsageWindow? in
                guard let data = buckets[name]?[window], let percent = data["usedPercent"]?.intValue, percent >= 0 else { return nil }
                return .init(id: name + " · " + window, usedPercent: percent,
                             resetsAt: data["resetsAt"]?.intValue.map { Date(timeIntervalSince1970: Double($0)) }, durationMinutes: data["windowDurationMins"]?.intValue)
            }
        }
    }

    func loadModels() async throws -> [ProviderModel] {
        var candidates: [JSONValue] = []
        var cursor: String?
        var cursors = Set<String>()
        repeat {
            var params: [String: JSONValue] = ["limit": .number(100)]
            if let cursor { params["cursor"] = .string(cursor) }
            let result = try await connectedClient().request(method: "model/list", params: .object(params))
            candidates += result["data"]?.arrayValue ?? result["models"]?.arrayValue ?? result.arrayValue ?? []
            cursor = result["nextCursor"]?.stringValue
            if let cursor, !cursors.insert(cursor).inserted { break }
        } while cursor != nil && candidates.count < 1_000
        let models = Self.parseModels(candidates)
        emit(.models(models))
        return models
    }

    static func parseModels(_ candidates: [JSONValue]) -> [ProviderModel] {
        candidates.compactMap { item -> ProviderModel? in
            guard let id = Self.findString(keys: ["id", "model"], in: item) else { return nil }
            let name = Self.findString(keys: ["displayName", "display_name", "name"], in: item) ?? id
            let efforts = item["supportedReasoningEfforts"]?.arrayValue?.compactMap { $0["reasoningEffort"]?.stringValue } ?? []
            return ProviderModel(id: id, displayName: name, description: Self.findString(keys: ["description"], in: item), isDefault: item["isDefault"] == .bool(true), reasoningEfforts: efforts, defaultReasoningEffort: item["defaultReasoningEffort"]?.stringValue)
        }
    }

    func startThread(projectPath: String, model: String?) async throws -> String {
        try await validateSelectedAuthentication()
        var params: [String: JSONValue] = [
            "cwd": .string(projectPath),
            "modelProvider": .string("openai"),
            "approvalPolicy": .string("on-request"),
            "sandbox": .string(configuration.access == .readOnly ? "read-only" : "workspace-write")
        ]
        if let model { params["model"] = .string(model) }
        if !configuration.instructions.isEmpty { params["developerInstructions"] = .string(configuration.instructions) }
        let result = try await connectedClient().request(method: "thread/start", params: .object(params), timeout: .seconds(30))
        guard let id = Self.findString(keys: ["id"], in: result["thread"] ?? result) else {
            throw NativeAgentError.protocolError("thread/start returned no thread id")
        }
        currentThreadID = id
        tokenUsage.reset(threadID: id, newThread: true, response: result)
        emit(.threadCreated(id))
        return id
    }

    func resumeThread(id: String, projectPath: String) async throws {
        tokenUsage.reset(threadID: id, newThread: false)
        let result = try await connectedClient().request(method: "thread/resume", params: .object([
            "threadId": .string(id), "cwd": .string(projectPath),
            "modelProvider": .string("openai"),
            "approvalPolicy": .string("on-request"),
            "sandbox": .string(configuration.access == .readOnly ? "read-only" : "workspace-write")
        ]), timeout: .seconds(30))
        currentThreadID = id
        tokenUsage.captureBaseline(result)
        emit(.threadCreated(id))
    }

    func startTurn(threadID: String, prompt: String, projectPath: String, model: String?) async throws {
        try await validateSelectedAuthentication()
        if currentThreadID != threadID {
            try await resumeThread(id: threadID, projectPath: projectPath)
        }
        if tokenUsage.needsBaseline {
            // Some versions include usage on read/resume; others replay it via
            // notifications. Missing data leaves the first resumed turn unknown.
            let state = try? await connectedClient().request(method: "thread/read", params: .object([
                "threadId": .string(threadID), "includeTurns": .bool(false)
            ]), timeout: .seconds(10))
            tokenUsage.captureBaseline(state)
        }
        var params: [String: JSONValue] = [
            "threadId": .string(threadID),
            "cwd": .string(projectPath),
            "input": .array([.object(["type": .string("text"), "text": .string(prompt)])])
        ]
        if let model { params["model"] = .string(model) }
        if let effort = configuration.reasoning { params["effort"] = .string(effort) }
        params["approvalPolicy"] = .string("on-request")
        params["sandboxPolicy"] = configuration.access == .readOnly
            ? .object(["type": .string("readOnly")])
            : .object(["type": .string("workspaceWrite"), "writableRoots": .array([.string(projectPath)]), "networkAccess": .bool(false)])
        tokenUsage.prepare(model: model)
        let result = try await connectedClient().request(method: "turn/start", params: .object(params), timeout: .seconds(30))
        currentTurnID = Self.findString(keys: ["id"], in: result["turn"] ?? result)
        emit(.turnStarted(currentTurnID ?? UUID().uuidString))
        if let currentTurnID { for report in tokenUsage.activate(turnID: currentTurnID) { emit(.tokenUsage(report)) } }
    }

    func answerApproval(id: String, decision: ApprovalDecision) async throws {
        guard pendingApprovals[id]?.contains(decision) == true else { throw NativeAgentError.protocolError("Approval is no longer pending or this choice is unsupported") }
        guard let requestID = parseRequestID(id) else { throw NativeAgentError.protocolError("Invalid approval request id") }
        let wireDecision: String
        switch decision {
        case .accept: wireDecision = "accept"
        case .acceptForSession: wireDecision = "acceptForSession"
        case .decline: wireDecision = "decline"
        case .cancel: wireDecision = "cancel"
        }
        try await connectedClient().reply(to: requestID, result: .object(["decision": .string(wireDecision)]))
        pendingApprovals.removeValue(forKey: id)
    }

    func interrupt(threadID: String, turnID: String?) async throws {
        var params: [String: JSONValue] = ["threadId": .string(threadID)]
        guard let turnID = turnID ?? currentTurnID else { throw NativeAgentError.protocolError("No active turn to interrupt") }
        params["turnId"] = .string(turnID)
        _ = try await connectedClient().request(method: "turn/interrupt", params: .object(params), timeout: .seconds(15))
    }

    func answerQuestion(id: String, answers: [String: String]) async throws {
        guard let request = pendingQuestions[id], let schema = questionResponseSchema, let requestID = parseRequestID(id), Set(answers.keys) == Set(request.questions.map(\.id)) else { throw NativeAgentError.unsupported("This question is no longer pending or its response schema is unavailable.") }
        for question in request.questions {
            guard let answer = answers[question.id], !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  answer.utf8.count <= 32_768,
                  question.options.isEmpty || question.allowsOther || question.options.contains(where: { $0.label == answer }) else { throw NativeAgentError.unsupported("Choose an advertised answer for each question.") }
        }
        let payload = JSONValue.object(["answers": .object(answers.mapValues { .object(["answers": .array([.string($0)])]) })])
        guard SchemaSubset.accepts(payload, schema: schema, root: schema) else { throw NativeAgentError.unsupported("The runtime does not accept this question-response shape.") }
        // Remove before suspension so repeated clicks cannot submit twice.
        pendingQuestions.removeValue(forKey: id)
        try await connectedClient().reply(to: requestID, result: payload)
        emit(.questionResolved(id))
    }

    func handle(_ notification: RPCNotification) async {
        let params = notification.params ?? .object([:])
        let turnID = Self.findString(keys: ["turnId", "turn_id"], in: params) ?? currentTurnID
        switch notification.method {
        case "thread/tokenUsage/updated":
            if let report = tokenUsage.consume(params) { emit(.tokenUsage(report)) }
        case "turn/plan/updated":
            let steps = (params["plan"]?.arrayValue ?? []).compactMap { value -> String? in
                guard let step = value["step"]?.stringValue, let status = value["status"]?.stringValue else { return nil }
                let label = ["pending": "Pending", "inProgress": "In progress", "completed": "Completed"][status] ?? status
                return "\(label): \(step)"
            }
            emit(.conversationFact(turnID: turnID, fact: .init(key: "plan", category: .plan, title: "Task plan", text: ([params["explanation"]?.stringValue].compactMap { $0 } + steps).joined(separator: "\n"))))
        case "item/started":
            if let item = params["item"] { emitItemFacts(item, turnID: turnID, completed: false) }
        case "item/commandExecution/outputDelta", "item/fileChange/outputDelta": break // authoritative completed output is recorded below
        case "item/agentMessage/delta", "agent/message/delta":
            if let delta = Self.findString(keys: ["delta", "text"], in: params) { emit(.agentDelta(turnID: turnID, text: delta)) }
        case "item/completed":
            if let item = params["item"] {
                emitItemFacts(item, turnID: turnID, completed: true)
                switch item["type"]?.stringValue {
                case "agentMessage": if let text = item["text"]?.stringValue { emit(.agentMessage(turnID: turnID, text: text)) }
                case "commandExecution": emit(.command(turnID: turnID, title: item["command"]?.stringValue ?? "Command", output: item["aggregatedOutput"]?.stringValue ?? "", exitCode: item["exitCode"]?.intValue))
                case "fileChange":
                    if item["status"]?.stringValue == "completed" {
                        for change in item["changes"]?.arrayValue ?? [] {
                            guard let path = change["path"]?.stringValue else { continue }
                            emit(.fileChange(turnID: turnID, path: path, summary: change["diff"]?.stringValue ?? "Provider reported a file change; no diff supplied."))
                        }
                    }
                default: break
                }
            }
        case "turn/started":
            if let id = Self.findString(keys: ["id"], in: params["turn"] ?? params) {
                currentTurnID = id
                emit(.turnStarted(id))
            }
        case "turn/completed":
            pendingApprovals = [:]; pendingQuestions = [:]
            let turn = params["turn"] ?? params
            let statusString = Self.findString(keys: ["status"], in: turn) ?? "failed"
            let status: TurnStatus = statusString == "completed" ? .completed : (statusString == "interrupted" ? .interrupted : .failed)
            if let id = turn["id"]?.stringValue ?? turnID, let report = tokenUsage.finish(turnID: id) { emit(.tokenUsage(report)) }
            emit(.turnCompleted(turnID: turn["id"]?.stringValue ?? turnID, status: status, error: turn["error"]?["message"]?.stringValue))
            handleProviderError(turn["error"])
            currentTurnID = nil
        case "account/login/completed":
            if startingLogin { earlyLoginCompletion = params; return }
            guard let id = loginID, params["loginId"]?.stringValue == id else { return }
            loginTimer?.cancel(); loginTimer = nil
            loginID = nil
            if params["success"] == .bool(true) {
                do {
                    try await refreshAccount()
                    if !authenticated { emit(.authenticationFailed("Sign-in finished without a confirmed ChatGPT account. Reconnect or try again.")) }
                }
                catch { emit(.authenticationFailed("Sign-in completed, but account refresh failed. Reconnect to retry.")) }
            } else { authUpdatesAllowed = false; emit(.authenticationFailed("Sign-in was cancelled or failed. Please try again.")) }
        case "account/updated":
            guard authUpdatesAllowed, loginID == nil, !startingLogin else { return }
            do { try await refreshAccount() } catch { emit(.authenticationRequired) }
        case "account/rateLimits/updated": emit(.usage(Self.usageWindows(params)))
        case "error": handleProviderError(params["error"])
        case "serverRequest/resolved":
            if let id = params["requestId"] { let key = serializeRequestID(id); pendingApprovals.removeValue(forKey: key); pendingQuestions.removeValue(forKey: key); emit(.approvalResolved(key)); emit(.questionResolved(key)) }
        default:
            if notification.method.contains("command") {
                let title = Self.findString(keys: ["command", "title"], in: params) ?? "Command"
                let output = Self.findString(keys: ["output", "aggregatedOutput", "stdout"], in: params) ?? ""
                emit(.command(turnID: turnID, title: title, output: output, exitCode: Self.findInt(keys: ["exitCode", "exit_code"], in: params)))
            } else if notification.method.contains("file") && notification.method.contains("change") {
                emit(.fileChange(turnID: turnID, path: Self.findString(keys: ["path", "filePath"], in: params) ?? "File", summary: Self.findString(keys: ["summary", "diff"], in: params) ?? "Changed"))
            }
        }
    }

    private func emitItemFacts(_ item: JSONValue, turnID: String?, completed: Bool) {
        guard let id = item["id"]?.stringValue, let type = item["type"]?.stringValue else { return }
        let title: String
        switch type {
        case "commandExecution": title = item["command"]?.stringValue ?? "Command"
        case "fileChange": title = "File changes"
        case "webSearch": title = item["query"]?.stringValue ?? "Web search"
        case "imageView": title = "View image"
        case "mcpToolCall": title = [item["server"]?.stringValue, item["tool"]?.stringValue].compactMap { $0 }.joined(separator: " · ")
        case "dynamicToolCall", "collabToolCall": title = item["tool"]?.stringValue ?? "Tool action"
        default: return
        }
        let state = item["status"]?.stringValue ?? (completed ? "completed" : "inProgress")
        let label = ["inProgress": "In progress", "completed": "Completed", "failed": "Failed", "declined": "Declined"][state] ?? state
        emit(.conversationFact(turnID: turnID, fact: .init(key: "item/" + id, category: .activity, title: title, text: label, state: state)))
        if type == "fileChange" {
            for change in (item["changes"]?.arrayValue ?? []).prefix(200) {
                guard let path = change["path"]?.stringValue else { continue }
                emit(.conversationFact(turnID: turnID, fact: .init(key: "change/" + id + "/" + path, category: .activity, title: path, text: String((change["diff"]?.stringValue ?? "No diff supplied").prefix(32_000)), state: completed ? state : "proposed", path: path)))
            }
        }
        guard completed else { return }
        if type == "commandExecution", state == "completed", item["exitCode"]?.intValue == 0 {
            for (index, action) in (item["commandActions"]?.arrayValue ?? []).enumerated() {
                guard action["type"]?.stringValue == "read", let suppliedPath = action["path"]?.stringValue else { continue }
                let path: String
                if !suppliedPath.hasPrefix("/"), let cwd = item["cwd"]?.stringValue {
                    path = URL(fileURLWithPath: cwd, isDirectory: true).appendingPathComponent(suppliedPath).standardizedFileURL.path
                } else { path = suppliedPath }
                emit(.conversationFact(turnID: turnID, fact: .init(key: "source/\(id)/\(index)", category: .source, title: path, text: "File referenced by a provider-reported read action in a successfully completed command.", path: path)))
            }
        }
        if type == "imageView", let path = item["path"]?.stringValue {
            emit(.conversationFact(turnID: turnID, fact: .init(key: "source/" + id, category: .source, title: path, text: "Image referenced by the provider’s image-view tool.", path: path)))
        }
        if type == "webSearch", let action = item["action"],
           ["openPage", "findInPage"].contains(action["type"]?.stringValue ?? ""), let url = action["url"]?.stringValue {
            emit(.conversationFact(turnID: turnID, fact: .init(key: "source/" + id, category: .source, title: url, text: "Web page referenced by the provider’s \(action["type"]?.stringValue ?? "web") action.", url: url)))
        }
    }

    func handle(_ request: RPCServerRequest) async {
        if request.method == "item/tool/requestUserInput" {
            let params = request.params ?? .null
            guard questionResponseSchema != nil, let questions = Self.parseQuestions(params), !questions.isEmpty else {
                emit(.conversationFact(turnID: params["turnId"]?.stringValue, fact: .init(key: "unsupported-question/" + serializeRequestID(request.id), category: .status, title: "Question requires a compatible runtime", text: "A provider requested user input, but its native answer schema could not be verified. The request was not answered. Review the provider output before continuing.", state: "inputUnavailable")))
                try? await rpc?.reply(to: request.id, errorCode: -32601, message: "User input response schema unavailable")
                return
            }
            let value = ProviderQuestionRequest(id: serializeRequestID(request.id), turnID: params["turnId"]?.stringValue ?? currentTurnID, questions: questions)
            pendingQuestions[value.id] = value; emit(.question(value)); return
        }
        guard ["item/commandExecution/requestApproval", "item/fileChange/requestApproval"].contains(request.method) else {
            try? await rpc?.reply(to: request.id, errorCode: -32601, message: "Unsupported server request")
            return
        }
        let params = request.params ?? .object([:])
        let id = serializeRequestID(request.id)
        let declaredChoices = Self.approvalChoices(in: params)
        let choices: [ApprovalDecision] = params["availableDecisions"] == nil || params["availableDecisions"] == .null
            ? (request.method == "item/fileChange/requestApproval" ? [.accept, .decline] : [.accept, .acceptForSession, .decline, .cancel]) : declaredChoices
        guard !choices.isEmpty else {
            try? await rpc?.reply(to: request.id, errorCode: -32602, message: "No supported approval decisions")
            emit(.diagnostic("The runtime requested an unsupported permission choice. No action was approved.")); return
        }
        pendingApprovals[id] = choices
        let approval = ApprovalRequest(
            id: id,
            turnID: Self.findString(keys: ["turnId", "turn_id"], in: params) ?? currentTurnID,
            method: request.method,
            title: request.method.contains("command") ? "Run command?" : "Apply file changes?",
            command: Self.findString(keys: ["command", "cmd"], in: params),
            workingDirectory: Self.findString(keys: ["cwd", "workingDirectory"], in: params),
            choices: choices
        )
        emit(.approval(approval))
    }

    static func parseQuestions(_ params: JSONValue) -> [ProviderQuestionRequest.Question]? {
        guard let values = params["questions"]?.arrayValue, (1...3).contains(values.count) else { return nil }
        var result: [ProviderQuestionRequest.Question] = []
        for value in values {
            guard let id = value["id"]?.stringValue, let text = value["question"]?.stringValue, !id.isEmpty, !text.isEmpty, text.utf8.count < 32_768, !result.contains(where: { $0.id == id }) else { return nil }
            let options = (value["options"]?.arrayValue ?? []).compactMap { option -> ProviderQuestionRequest.Question.Option? in
                guard let label = option["label"]?.stringValue, !label.isEmpty else { return nil }
                return .init(label: label, description: option["description"]?.stringValue ?? "")
            }
            guard options.count == (value["options"]?.arrayValue ?? []).count, options.count <= 12, Set(options.map(\.label)).count == options.count else { return nil }
            result.append(.init(id: id, header: value["header"]?.stringValue ?? "Question", text: text, secret: value["isSecret"] == .bool(true), allowsOther: value["isOther"] == .bool(true), options: options))
        }
        return result
    }

    private func providerTerminated(_ code: Int32) async {
        await rpc?.close(with: NativeAgentError.processEnded(code))
        rpc = nil
        authenticated = false
        loginTimer?.cancel(); loginTimer = nil; loginID = nil
        emit(.connectionFailed("Codex disconnected (exit \(code)). Reconnect to continue."))
        if currentTurnID != nil { emit(.turnCompleted(turnID: currentTurnID, status: .failed, error: "Provider process ended (\(code)). Check the workspace before retrying; a command may already have run.")) }
    }

    private func streamEnded() async {
        let turn = currentTurnID
        await disconnect()
        emit(.connectionFailed("Codex’s protocol stream ended or became invalid. Reconnect to continue."))
        if let turn { emit(.turnCompleted(turnID: turn, status: .failed, error: "Connection lost. Check the workspace before retrying.")) }
    }

    private func connectedClient() throws -> RPCClient {
        guard let rpc else { throw NativeAgentError.providerUnavailable("Connect the provider first.") }
        return rpc
    }

    private func resolvedBinaryPath() -> String? {
        if let configuredBinaryPath, !configuredBinaryPath.isEmpty { return configuredBinaryPath }
        return ProviderExecutable.resolve(.codex, configured: "")
    }

    private func handleProviderError(_ error: JSONValue?) {
        let info = error?["codexErrorInfo"]
        switch info?.stringValue {
        case "usageLimitExceeded", "UsageLimitExceeded": emit(.usageLimitReached)
        case "unauthorized", "Unauthorized": authenticated = false; emit(.authenticationRequired)
        default: break
        }
    }

    private func validateSelectedAuthentication() async throws {
        // Injected protocol fixtures do not start a runtime. Real connections are
        // checked again before every turn because another CLI can change shared auth.
        guard version != nil else { return }
        let result = try await connectedClient().request(method: "account/read", params: .object(["refreshToken": .bool(true)]))
        guard let account = result["account"], Self.authenticationMethod(account) == authenticationMethod else {
            authenticated = false; emit(.authenticationRequired)
            throw NativeAgentError.providerUnavailable("The shared provider login changed or expired. Reconnect using the selected billing mode.")
        }
    }

    private func emit(_ event: ProviderEvent) { eventContinuation?.yield(event) }

    private func serializeRequestID(_ id: JSONValue) -> String {
        switch id {
        case .string(let value): "s:\(value)"
        case .number(let value): "n:\(value)"
        default: "j:\((try? String(data: JSONEncoder().encode(id), encoding: .utf8)) ?? "null")"
        }
    }

    private func parseRequestID(_ value: String) -> JSONValue? {
        if value.hasPrefix("s:") { return .string(String(value.dropFirst(2))) }
        if value.hasPrefix("n:"), let number = Double(value.dropFirst(2)) { return .number(number) }
        return nil
    }

    private static func accountName(_ value: JSONValue) -> String? {
        findString(keys: ["email", "name", "displayName"], in: value["account"] ?? value)
    }

    private static func findString(keys: [String], in value: JSONValue) -> String? {
        guard let object = value.objectValue else { return value.stringValue }
        for key in keys {
            if let string = object[key]?.stringValue { return string }
        }
        for child in object.values {
            if let found = findString(keys: keys, in: child) { return found }
        }
        return nil
    }

    private static func findInt(keys: [String], in value: JSONValue) -> Int? {
        guard let object = value.objectValue else { return value.intValue }
        for key in keys { if let number = object[key]?.intValue { return number } }
        return nil
    }

    private static func approvalChoices(in value: JSONValue) -> [ApprovalDecision] {
        guard let raw = value["availableDecisions"]?.arrayValue ?? value["available_decisions"]?.arrayValue else { return [] }
        return raw.compactMap { item in
            switch item.stringValue {
            case "accept": .accept
            case "acceptForSession", "accept_for_session": .acceptForSession
            case "decline": .decline
            case "cancel": .cancel
            default: nil
            }
        }
    }
}
