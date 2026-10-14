import Foundation

/// Subscription credentials remain within the unmodified official program.
/// Until native permission/control support is verified, conversations run in Terminal.
actor ClaudeProvider: CodingProvider {
    let events: AsyncStream<ProviderEvent>
    private let continuation: AsyncStream<ProviderEvent>.Continuation
    private let path: String
    private var apiKey: String?
    private let command = ProviderCommand()
    private let terminal = OfficialClaudeTerminal()
    private var version: String?
    private var authenticated = false
    private var generation = UUID()

    init(path: String, apiKey: String? = nil) {
        self.path = path; self.apiKey = apiKey
        (events, continuation) = AsyncStream.makeStream()
    }
    func inspect() -> ProviderInspection {
        .init(binaryPath: path, version: version, isExecutable: FileManager.default.isExecutableFile(atPath: path),
              capabilities: .claudeTerminal, message: "Official Claude Code terminal session. Native controls are not verified for this installation. Permissions, streaming, /model, /resume and Ctrl-C are handled in Terminal.")
    }
    func connect() async throws {
        let token = generation
        authenticated = false
        version = try await RuntimeValidation.version(path: path, kind: .claude, command: command)
        continuation.yield(.inspection(inspect()))
        try await RuntimeValidation.claudeCommands(path: path, command: command)
        guard generation == token else { throw CancellationError() }
        let result = try await command.run(path: path, arguments: ["auth", "status"], environment: environment, timeout: .seconds(20))
        guard generation == token else { throw CancellationError() }
        guard let account = try Self.validatedAccount(result.output, exitCode: result.code, method: apiKey == nil ? .account : .apiKey) else {
            continuation.yield(.authenticationRequired); return
        }
        authenticated = true
        continuation.yield(.accountDetails(account))
        continuation.yield(.connected(account: account.email))
    }
    static func validatedAccount(_ data: Data, exitCode: Int32, method: AuthenticationMethod) throws -> ProviderAccount? {
        if exitCode == 1 { return nil }
        guard exitCode == 0 else { throw NativeAgentError.providerUnavailable("Claude Code could not check its authentication (exit \(exitCode)).") }
        guard let status = try? JSONDecoder().decode(JSONValue.self, from: data),
              case .bool(let loggedIn) = status["loggedIn"], let auth = status["authMethod"]?.stringValue else {
            throw NativeAgentError.unsupportedVersion("Claude Code returned an unrecognized auth status. Update the runtime or NativeAgent.")
        }
        guard loggedIn else { return nil }
        // Unknown methods, gateways and Console OAuth aren't subscription proof.
        guard auth == (method == .account ? "claude.ai" : "api_key") else { return nil }
        return .init(email: status["email"]?.stringValue, plan: status["subscriptionType"]?.stringValue,
                     method: method, configuration: status["configDirectory"]?.stringValue ?? ProviderExecutable.profileDescription(.claude))
    }
    func beginLogin() async throws {
        guard apiKey == nil else { throw NativeAgentError.unsupported("Select subscription mode before connecting Claude Code.") }
        if authenticated { return }
        let token = generation
        try await terminal.login(path: path)
        guard token == generation else { throw CancellationError() }
        try await connect()
    }
    func cancelLogin() async { generation = UUID(); await terminal.cancel(); await command.cancel() }
    func login(apiKey: String) async throws { self.apiKey = apiKey; try await connect() }
    func logout() async throws {
        let result = try await command.run(path: path, arguments: ["auth", "logout"], environment: environment, timeout: .seconds(20))
        guard result.code == 0 else { throw NativeAgentError.providerUnavailable("Claude Code could not sign out. Reconnect and retry.") }
        authenticated = false; apiKey = nil; continuation.yield(.authenticationRequired)
    }
    func disconnect() async { await cancelLogin(); authenticated = false }
    func openTerminal(folder: String, model: String?, readOnly: Bool) async throws {
        guard authenticated else { throw NativeAgentError.providerUnavailable("Connect Claude Code first.") }
        try await terminal.openSession(path: path, method: apiKey == nil ? .account : .apiKey, folder: folder, model: model, readOnly: readOnly)
    }
    func configure(_ configuration: RunConfiguration) {}
    func loadModels() -> [ProviderModel] { [] }
    func startThread(projectPath: String, model: String?) throws -> String { throw terminalOnly }
    func resumeThread(id: String, projectPath: String) throws { throw terminalOnly }
    func startTurn(threadID: String, prompt: String, projectPath: String, model: String?) throws { throw terminalOnly }
    func answerApproval(id: String, decision: ApprovalDecision) throws { throw terminalOnly }
    func interrupt(threadID: String, turnID: String?) throws { throw terminalOnly }
    private var terminalOnly: NativeAgentError { .unsupported("Use the official Claude Code terminal session for tasks, permissions, continuation and interruption.") }
    private var environment: [String: String] { ProviderExecutable.environment(kind: .claude, key: apiKey) }
}
