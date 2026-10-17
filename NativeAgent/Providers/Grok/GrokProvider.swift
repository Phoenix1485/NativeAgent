import Foundation

/// Grok Build's documented ACP interface. Authentication remains with the official runtime.
actor GrokProvider: CodingProvider {
    let events: AsyncStream<ProviderEvent>
    private let continuation: AsyncStream<ProviderEvent>.Continuation
    private let path: String
    private var apiKey: String?
    private var transport = ProcessTransport()
    private var rpc: RPCClient?
    private let command = ProviderCommand()
    private var tasks: [Task<Void, Never>] = []
    private var configuration = RunConfiguration()
    private var sessionID: String?
    private var configOptions: [JSONValue] = []
    private var availableModels: [ProviderModel] = []
    private var permissions: [String: (JSONValue, [ApprovalDecision: String])] = [:]
    private var turnTask: Task<Void, Never>?
    private var usageTurnID: String?
    private var usageModel: String?
    private var contextUsage: ProviderTokenUsage?
    private var canLoad = false
    private var modes: [JSONValue] = []
    private var planModeApplied = false

    init(path: String, apiKey: String? = nil, rpcClient: RPCClient? = nil) {
        self.path = path; self.apiKey = apiKey
        rpc = rpcClient
        (events, continuation) = AsyncStream.makeStream()
    }
    func inspect() -> ProviderInspection {
        ProviderInspection(binaryPath: path, version: nil, isExecutable: FileManager.default.isExecutableFile(atPath: path), capabilities: .init(), message: "Uses the official Grok Build runtime and its account login.")
    }
    func connect() async throws {
        guard rpc == nil else { return }
        guard FileManager.default.isExecutableFile(atPath: path) else { throw NativeAgentError.providerUnavailable("Install Grok Build or choose its executable in Settings → Configuration.") }
        transport = ProcessTransport()
        let output = try await transport.start(binary: URL(fileURLWithPath: path), arguments: ["--no-auto-update", "agent", "stdio"], workingDirectory: nil, environment: ProviderExecutable.environment(kind: .grok, key: apiKey))
        let client = RPCClient(transport: transport, jsonRPCVersion: true)
        rpc = client
        tasks = [
            Task { await client.consume(output.stdout) },
            Task { for await event in client.notifications { self.handle(event) } },
            Task { for await request in client.serverRequests { await self.handle(request) } },
            Task { for await _ in output.stderr {} },
            Task { for await code in output.termination {
                await client.close(with: NativeAgentError.processEnded(code))
                if !Task.isCancelled { continuation.yield(.authenticationFailed("Grok Build disconnected. Reconnect to continue.")) }
            } }
        ]
        do {
            let result = try await client.request(method: "initialize", params: .object([
                "protocolVersion": .number(1), "clientInfo": .object(["name": .string("nativeagent"), "version": .string("0.3.0")]),
                "clientCapabilities": .object(["fs": .object(["readTextFile": .bool(false), "writeTextFile": .bool(false)]), "terminal": .bool(false)])
            ]))
            canLoad = result["agentCapabilities"]?["loadSession"] == .bool(true)
            let methods = Set((result["authMethods"]?.arrayValue ?? []).compactMap { $0["id"]?.stringValue })
            let method = apiKey == nil ? "cached_token" : "xai.api_key"
            guard methods.contains(method) else { continuation.yield(.authenticationRequired); return }
            do {
                _ = try await client.request(method: "authenticate", params: .object(["methodId": .string(method), "_meta": .object(["headless": .bool(true)])]))
                continuation.yield(.connected(account: apiKey == nil ? "Grok Build account" : "API key"))
            } catch { continuation.yield(.authenticationRequired) }
        } catch { await disconnect(); throw error }
    }
    func disconnect() async {
        turnTask?.cancel(); turnTask = nil
        tasks.forEach { $0.cancel() }; tasks = []
        await rpc?.close(); rpc = nil; await transport.stop(); await command.cancel(); sessionID = nil
        permissions = [:]
        usageTurnID = nil; usageModel = nil; contextUsage = nil
    }
    func beginLogin() async throws {
        await disconnect(); apiKey = nil
        let result = try await command.run(path: path, arguments: ["login"], environment: ProviderExecutable.environment(kind: .grok, key: nil))
        guard result.code == 0 else { throw NativeAgentError.providerUnavailable("Grok sign-in did not complete. Retry, or run ‘grok login’ in Terminal and reconnect.") }
        try await connect()
    }
    func login(apiKey: String) async throws { await disconnect(); self.apiKey = apiKey; try await connect() }
    func logout() async throws {
        await disconnect()
        let result = try await command.run(path: path, arguments: ["logout"], environment: ProviderExecutable.environment(kind: .grok, key: nil), timeout: .seconds(20))
        guard result.code == 0 else { throw NativeAgentError.providerUnavailable("Grok could not sign out. Use ‘grok logout’ to retry.") }
        apiKey = nil; continuation.yield(.authenticationRequired)
    }
    func configure(_ configuration: RunConfiguration) { self.configuration = configuration }
    func loadModels() -> [ProviderModel] {
        availableModels.isEmpty ? [.init(id: "__provider_default__", displayName: "Grok default", description: "Grok publishes available models when you start a workspace session.", isDefault: true)] : availableModels
    }
    func startThread(projectPath: String, model: String?) async throws -> String {
        let result = try await client().request(method: "session/new", params: .object(["cwd": .string(projectPath), "mcpServers": .array([])]), timeout: .seconds(45))
        guard let id = result["sessionId"]?.stringValue else { throw NativeAgentError.protocolError("Grok returned no session ID") }
        sessionID = id; readSession(result)
        planModeApplied = result["modes"]?["currentModeId"]?.stringValue == "plan"
        return id
    }
    func resumeThread(id: String, projectPath: String) async throws {
        guard canLoad else { throw NativeAgentError.unsupported("This Grok Build version cannot resume sessions over ACP. Start a new chat or update Grok Build.") }
        let result = try await client().request(method: "session/load", params: .object(["sessionId": .string(id), "cwd": .string(projectPath), "mcpServers": .array([])]), timeout: .seconds(45))
        sessionID = id; readSession(result)
        planModeApplied = result["modes"]?["currentModeId"]?.stringValue == "plan"
    }
    func startTurn(threadID: String, prompt: String, projectPath: String, model: String?) async throws {
        guard turnTask == nil else { throw NativeAgentError.alreadyRunning }
        if sessionID != threadID { try await resumeThread(id: threadID, projectPath: projectPath) }
        let client = try client()
        if let model, model != "__provider_default__" {
            if let option = configOptions.first(where: { $0["category"]?.stringValue == "model" }), let id = option["id"]?.stringValue {
                let result = try await client.request(method: "session/set_config_option", params: .object(["sessionId": .string(threadID), "configId": .string(id), "value": .string(model)]))
                readSession(result)
            } else {
                _ = try await client.request(method: "session/set_model", params: .object(["sessionId": .string(threadID), "modelId": .string(model)]))
            }
        }
        if let effort = configuration.reasoning, let option = configOptions.first(where: { $0["category"]?.stringValue == "thought_level" }), let id = option["id"]?.stringValue {
            guard Self.values(option).contains(where: { $0["value"]?.stringValue == effort }) else { throw NativeAgentError.unsupported("The selected Grok model does not support that thinking level.") }
            _ = try await client.request(method: "session/set_config_option", params: .object(["sessionId": .string(threadID), "configId": .string(id), "value": .string(effort)]))
        }
        if configuration.access == .readOnly {
            guard modes.contains(where: { $0["id"]?.stringValue == "plan" }) else { throw NativeAgentError.unsupported("This Grok runtime does not advertise a read-only plan mode. Choose Workspace edits or another provider.") }
            _ = try await client.request(method: "session/set_mode", params: .object(["sessionId": .string(threadID), "modeId": .string("plan")]))
            planModeApplied = true
        } else if planModeApplied {
            guard let mode = modes.first(where: { $0["id"]?.stringValue == "default" })?["id"]?.stringValue else {
                throw NativeAgentError.unsupported("This Grok session is in plan mode. Start a new chat to use Workspace edits.")
            }
            _ = try await client.request(method: "session/set_mode", params: .object(["sessionId": .string(threadID), "modeId": .string(mode)]))
            planModeApplied = false
        }
        let turnID = UUID().uuidString
        usageTurnID = turnID
        usageModel = model == "__provider_default__" ? availableModels.first(where: \.isDefault)?.id : model
        contextUsage = nil
        continuation.yield(.turnStarted(turnID))
        let text = configuration.instructions.isEmpty ? prompt : "User preferences for this turn:\n\(configuration.instructions)\n\nTask:\n\(prompt)"
        turnTask = Task {
            do {
                let result = try await client.request(method: "session/prompt", params: .object(["sessionId": .string(threadID), "prompt": .array([.object(["type": .string("text"), "text": .string(text)])])]), timeout: .seconds(3600))
                let reason = result["stopReason"]?.stringValue
                finishUsage(threadID: threadID, turnID: turnID)
                continuation.yield(.turnCompleted(turnID: turnID, status: reason == "cancelled" ? .interrupted : .completed, error: nil))
            } catch {
                finishUsage(threadID: threadID, turnID: turnID)
                continuation.yield(.turnCompleted(turnID: turnID, status: .failed, error: "Grok could not finish this turn. Check the runtime, account access, and selected model."))
            }
            turnTask = nil
        }
    }
    func interrupt(threadID: String, turnID: String?) async throws {
        try await client().notify(method: "session/cancel", params: .object(["sessionId": .string(threadID)]))
    }
    func answerApproval(id: String, decision: ApprovalDecision) async throws {
        guard let request = permissions[id] else { throw NativeAgentError.protocolError("Unknown Grok permission request") }
        let outcome: JSONValue
        if decision == .cancel { outcome = .object(["outcome": .string("cancelled")]) }
        else if let option = request.1[decision] { outcome = .object(["outcome": .string("selected"), "optionId": .string(option)]) }
        else { throw NativeAgentError.unsupported("This permission choice") }
        try await client().reply(to: request.0, result: .object(["outcome": outcome]))
        permissions.removeValue(forKey: id)
    }
    private func handle(_ request: RPCServerRequest) async {
        guard request.method == "session/request_permission" else { try? await rpc?.reply(to: request.id, errorCode: -32601, message: "NativeAgent does not provide this client capability."); return }
        guard configuration.access != .readOnly else {
            try? await rpc?.reply(to: request.id, result: .object(["outcome": .object(["outcome": .string("cancelled")])]))
            return
        }
        let params = request.params ?? .null
        var choices: [ApprovalDecision: String] = [:]
        for option in params["options"]?.arrayValue ?? [] {
            guard let id = option["optionId"]?.stringValue else { continue }
            switch option["kind"]?.stringValue {
            case "allow_once": choices[.accept] = id
            case "allow_always": choices[.acceptForSession] = id
            case "reject_once": choices[.decline] = id
            default: break
            }
        }
        let id = UUID().uuidString
        permissions[id] = (request.id, choices)
        continuation.yield(.approval(.init(id: id, turnID: nil, method: request.method, title: params["toolCall"]?["title"]?.stringValue ?? "Allow Grok tool?", command: nil, workingDirectory: nil, choices: ApprovalDecision.allCases.filter { $0 == .cancel || choices[$0] != nil })))
    }
    func handle(_ notification: RPCNotification) {
        guard notification.method == "session/update", let update = notification.params?["update"] else { return }
        switch update["sessionUpdate"]?.stringValue {
        case "usage_update":
            guard let threadID = notification.params?["sessionId"]?.stringValue, threadID == sessionID, let turnID = usageTurnID else { return }
            let report = TokenUsageParser.acpContext(update, threadID: threadID, turnID: turnID, model: usageModel)
            contextUsage = report; continuation.yield(.tokenUsage(report))
        case "agent_message_chunk": if let text = update["content"]?["text"]?.stringValue { continuation.yield(.agentDelta(turnID: nil, text: text)) }
        case "config_option_update": readSession(update)
        case "tool_call": continuation.yield(.command(turnID: nil, title: update["title"]?.stringValue ?? "Grok tool", output: "", exitCode: nil))
        default: break
        }
    }
    private func finishUsage(threadID: String, turnID: String) {
        guard usageTurnID == turnID else { return }
        continuation.yield(.tokenUsage(contextUsage ?? .init(id: "grok/" + threadID + "/" + turnID,
            turnID: turnID, threadID: threadID, model: usageModel)))
        usageTurnID = nil; contextUsage = nil
    }
    private func readSession(_ result: JSONValue) {
        if let options = result["configOptions"]?.arrayValue { configOptions = options }
        if let available = result["modes"]?["availableModes"]?.arrayValue { modes = available }
        let thoughts = configOptions.first { $0["category"]?.stringValue == "thought_level" }.map(Self.values)?.compactMap { $0["value"]?.stringValue } ?? []
        if let option = configOptions.first(where: { $0["category"]?.stringValue == "model" }) {
            availableModels = Self.values(option).compactMap { value in
                guard let id = value["value"]?.stringValue else { return nil }
                return .init(id: id, displayName: value["name"]?.stringValue ?? id, isDefault: id == option["currentValue"]?.stringValue, reasoningEfforts: id == option["currentValue"]?.stringValue ? thoughts : [])
            }
        } else if let models = result["models"]?["availableModels"]?.arrayValue {
            availableModels = models.compactMap { item in
                guard let id = item["modelId"]?.stringValue else { return nil }
                return .init(id: id, displayName: item["name"]?.stringValue ?? id, isDefault: id == result["models"]?["currentModelId"]?.stringValue)
            }
        }
        if !availableModels.isEmpty { continuation.yield(.models(availableModels)) }
    }
    private static func values(_ option: JSONValue) -> [JSONValue] { (option["options"]?.arrayValue ?? []).flatMap { $0["options"]?.arrayValue ?? [$0] } }
    private func client() throws -> RPCClient {
        guard let rpc else { throw NativeAgentError.providerUnavailable("Connect Grok first.") }; return rpc
    }
}
