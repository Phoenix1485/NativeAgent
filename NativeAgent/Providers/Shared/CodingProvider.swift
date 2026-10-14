import Foundation

protocol CodingProvider: Actor {
    var events: AsyncStream<ProviderEvent> { get async }
    func inspect() async -> ProviderInspection
    func connect() async throws
    func disconnect() async
    func beginLogin() async throws
    func cancelLogin() async
    func login(apiKey: String) async throws
    func logout() async throws
    func configure(_ configuration: RunConfiguration) async
    func loadModels() async throws -> [ProviderModel]
    func startThread(projectPath: String, model: String?) async throws -> String
    func resumeThread(id: String, projectPath: String) async throws
    func startTurn(threadID: String, prompt: String, projectPath: String, model: String?) async throws
    func answerApproval(id: String, decision: ApprovalDecision) async throws
    func answerQuestion(id: String, answers: [String: String]) async throws
    func interrupt(threadID: String, turnID: String?) async throws
}

extension CodingProvider {
    func answerQuestion(id: String, answers: [String: String]) async throws { throw NativeAgentError.unsupported("Native question answers for this integration") }
    func cancelLogin() async { await disconnect() }
    func login(apiKey: String) async throws { throw NativeAgentError.unsupported("API key sign-in for this provider") }
    func logout() async throws { await disconnect() }
}

struct ProviderInspection: Sendable {
    let binaryPath: String?
    let version: String?
    let isExecutable: Bool
    let capabilities: ProviderCapabilities
    let message: String
}
