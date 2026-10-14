import Foundation
import XCTest
@testable import NativeAgent

final class MemoryCredentials: CredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [ProviderKind: String] = [:]
    func read(_ provider: ProviderKind) throws -> String? { lock.lock(); defer { lock.unlock() }; return values[provider] }
    func save(_ key: String, for provider: ProviderKind) throws { lock.lock(); defer { lock.unlock() }; values[provider] = key }
    func remove(_ provider: ProviderKind) throws { lock.lock(); defer { lock.unlock() }; values.removeValue(forKey: provider) }
    func contains(_ provider: ProviderKind) throws -> Bool { try read(provider) != nil }
}

actor SettingsTestProvider: CodingProvider {
    let events: AsyncStream<ProviderEvent>
    private let continuation: AsyncStream<ProviderEvent>.Continuation
    var connectCount = 0
    var runs: [RunConfiguration] = []
    var sentModels: [String?] = []
    var sentPrompts: [String] = []
    var sentThreads: [String] = []
    var threadCount = 0
    var completeImmediately = true
    var failTurn = false
    var authenticated = true
    var threadDelay: Duration?
    func setThreadDelay(_ value: Duration?) { threadDelay = value }
    init() { (events, continuation) = AsyncStream.makeStream() }
    func setAuthenticated(_ value: Bool) { authenticated = value }
    func setCompleteImmediately(_ value: Bool) { completeImmediately = value }
    func setFailTurn(_ value: Bool) { failTurn = value }
    func emit(_ event: ProviderEvent) { continuation.yield(event) }
    func inspect() -> ProviderInspection { .init(binaryPath: nil, version: nil, isExecutable: true, capabilities: .init(), message: "Offline mock") }
    func connect() { connectCount += 1; continuation.yield(authenticated ? .connected(account: "test@example.invalid") : .authenticationRequired) }
    func disconnect() {}
    func beginLogin() { continuation.yield(.authenticationFailed("Cancelled")) }
    func loadModels() -> [ProviderModel] { [.init(id: "fast", displayName: "Fast", isDefault: true, reasoningEfforts: ["low", "high"]), .init(id: "deep", displayName: "Deep", reasoningEfforts: ["medium", "high"])] }
    func configure(_ configuration: RunConfiguration) { runs.append(configuration) }
    func startThread(projectPath: String, model: String?) async -> String {
        threadCount += 1
        if let threadDelay { try? await Task.sleep(for: threadDelay) }
        return "mock-thread-\(threadCount)"
    }
    func resumeThread(id: String, projectPath: String) {}
    func startTurn(threadID: String, prompt: String, projectPath: String, model: String?) throws {
        if failTurn { throw NativeAgentError.providerUnavailable("Mock connection failure") }
        sentModels.append(model); sentPrompts.append(prompt); sentThreads.append(threadID)
        if completeImmediately { continuation.yield(.turnCompleted(turnID: nil, status: .completed, error: nil)) }
    }
    func answerApproval(id: String, decision: ApprovalDecision) {}
    func interrupt(threadID: String, turnID: String?) {}
}

@MainActor
final class PreferencesTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!
    private var directory: URL!
    override func setUp() async throws {
        suite = "NativeAgentSettingsTests.\(UUID())"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }
    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
    private func model(_ provider: SettingsTestProvider = SettingsTestProvider(), keys: MemoryCredentials = MemoryCredentials()) throws -> WorkspaceViewModel {
        WorkspaceViewModel(provider: provider, database: try DatabaseActor(url: directory.appendingPathComponent("test.sqlite3")), files: FileService(), git: GitService(), automaticallyRestore: false, preferences: defaults, credentials: keys)
    }
    func testFirstLaunchAndAllPreferencesSurviveRestart() {
        let settings = AppPreferences(defaults: defaults)
        XCTAssertFalse(settings.onboardingComplete)
        settings.onboardingComplete = true
        settings.provider = .claude; settings.theme = .dark; settings.accent = .rose
        settings.textSize = 18; settings.showTimestamps = false; settings.access = .readOnly; settings.instructions = "Run tests."
        settings.update(.claude) { $0.binaryPath = "/example/claude"; $0.method = .apiKey; $0.accountLabel = "Example" }
        let restored = AppPreferences(defaults: defaults)
        XCTAssertTrue(restored.onboardingComplete)
        XCTAssertEqual(restored.provider, .claude); XCTAssertEqual(restored.theme, .dark); XCTAssertEqual(restored.accent, .rose)
        XCTAssertEqual(restored.textSize, 18); XCTAssertFalse(restored.showTimestamps)
        XCTAssertEqual(restored.access, .readOnly); XCTAssertEqual(restored.instructions, "Run tests.")
        XCTAssertEqual(restored.profile(.claude).binaryPath, "/example/claude")
        restored.onboardingComplete = false
        XCTAssertFalse(AppPreferences(defaults: defaults).onboardingComplete)
    }
    func testModelDisablingFavoritesAndDefaultFallback() {
        let settings = AppPreferences(defaults: defaults)
        settings.update(.codex) { $0.catalog = [.init(id: "a", displayName: "Alpha", isDefault: true), .init(id: "z", displayName: "Zeta")]; $0.starredModels = ["z"] }
        XCTAssertEqual(settings.enabledModels(.codex).map(\.id), ["z", "a"])
        settings.setDefault("z", provider: .codex)
        XCTAssertEqual(settings.resolvedDefault(.codex), "z")
        settings.setEnabled("z", enabled: false, provider: .codex)
        XCTAssertEqual(settings.resolvedDefault(.codex), "a")
        settings.setEnabled("a", enabled: false, provider: .codex)
        XCTAssertNil(settings.resolvedDefault(.codex)); XCTAssertTrue(settings.enabledModels(.codex).isEmpty)
        settings.setDefault("z", provider: .codex)
        XCTAssertEqual(AppPreferences(defaults: defaults).enabledModels(.codex).map(\.id), ["z"])
        XCTAssertTrue(settings.enabledModels(.claude).isEmpty)
    }
    func testUnsupportedReasoningNeverSent() {
        let settings = AppPreferences(defaults: defaults)
        let item = ProviderModel(id: "a", displayName: "A", reasoningEfforts: ["low", "high"])
        settings.update(.codex) { $0.reasoning["a"] = "impossible" }
        XCTAssertNil(settings.reasoning(for: item, provider: .codex))
        settings.update(.codex) { $0.reasoning["a"] = "high" }
        XCTAssertEqual(settings.reasoning(for: item, provider: .codex), "high")
    }
    func testKeysNeverWrittenToPreferencesAndRemovalWorks() async throws {
        let keys = MemoryCredentials(), value = "test-secret-not-a-real-key"
        let model = try model(keys: keys)
        let saved = await model.saveAPIKey(value, kind: .grok)
        XCTAssertTrue(saved); XCTAssertEqual(try keys.read(.grok), value)
        XCTAssertEqual(model.settings.profile(.grok).method, .apiKey)
        let serialized = try XCTUnwrap(defaults.data(forKey: "nativeagent.preferences.v1"))
        XCTAssertFalse(String(decoding: serialized, as: UTF8.self).contains(value))
        XCTAssertTrue(model.savedKeyProviders.contains(.grok))
        await model.removeAPIKey(.grok)
        XCTAssertNil(try keys.read(.grok)); XCTAssertFalse(model.savedKeyProviders.contains(.grok))
    }
    func testNoProviderStartsUntilUserConnectsAndUnauthenticatedIsNotReady() async throws {
        let provider = SettingsTestProvider()
        await provider.setAuthenticated(false)
        let model = try model(provider)
        await Task.yield()
        let initialCount = await provider.connectCount
        XCTAssertEqual(initialCount, 0); XCTAssertEqual(model.connectionStatus, .disconnected)
        await model.connect()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(model.connectionStatus, .notAuthenticated); XCTAssertFalse(model.canSend)
        XCTAssertNil(model.settings.profile(.codex).accountLabel)
    }
    func testDefaultsReasoningAndAccessReachProvider() async throws {
        let provider = SettingsTestProvider(), model = try model(provider)
        await model.connect()
        for _ in 0..<20 { await Task.yield() }
        model.settings.setDefault("deep", provider: .codex)
        model.settings.update(.codex) { $0.reasoning["deep"] = "high" }
        model.settings.access = .readOnly; model.settings.instructions = "Use Swift."
        await model.newConversation(); await model.addProject(directory)
        let project = try XCTUnwrap(model.selectedProject)
        defaults.set([project.id.uuidString], forKey: "trustedProjectIDs")
        model.draft = "Hello"
        XCTAssertTrue(model.canSend)
        await model.send()
        let runs = await provider.runs, sent = await provider.sentModels
        XCTAssertEqual(runs, [.init(reasoning: "high", access: .readOnly, instructions: "Use Swift.")])
        XCTAssertEqual(sent, ["deep"])
    }
    func testCrossProviderChatsCanSendButDisabledModelsCannot() async throws {
        let model = try model()
        await model.connect()
        for _ in 0..<20 { await Task.yield() }
        model.selectedProject = Project(name: "Test", canonicalPath: directory.path)
        var chat = Conversation(remoteThreadID: "foreign-thread")
        chat.providerID = .claude; model.selectedConversation = chat; model.draft = "Continue"
        XCTAssertTrue(model.canSend)
        chat.providerID = .codex; model.selectedConversation = chat
        XCTAssertTrue(model.canSend)
        model.settings.setEnabled("fast", enabled: false, provider: .codex)
        model.settings.setEnabled("deep", enabled: false, provider: .codex)
        XCTAssertFalse(model.canSend)
    }
    func testLegacyExecutableSettingMigrates() {
        defaults.set("/custom/codex", forKey: "codexBinaryPath")
        XCTAssertEqual(AppPreferences(defaults: defaults).profile(.codex).binaryPath, "/custom/codex")
    }
    func testCancelledLoginNeverBecomesReady() async throws {
        let provider = SettingsTestProvider()
        await provider.setAuthenticated(false)
        let model = try model(provider)
        await model.login()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(model.connectionStatus, .notAuthenticated)
        XCTAssertFalse(model.accountActionInProgress)
        XCTAssertFalse(model.canSend)
    }

    func testBrowserOpenFailureAndLateEventsCannotMarkConnectionReady() async throws {
        let provider = SettingsTestProvider()
        let model = WorkspaceViewModel(provider: provider, database: try DatabaseActor(url: directory.appendingPathComponent("browser.sqlite3")), files: FileService(), git: GitService(), automaticallyRestore: false, preferences: defaults, credentials: MemoryCredentials(), openBrowser: { _ in false })
        await provider.emit(.loginURL("https://auth.openai.com/test"))
        for _ in 0..<40 { await Task.yield() }
        await provider.emit(.connected(account: "late@example.invalid"))
        for _ in 0..<40 { await Task.yield() }
        XCTAssertEqual(model.connectionStatus, .notAuthenticated)
        XCTAssertFalse(model.accountActionInProgress)
        XCTAssertNil(model.providerAccount)
    }

    func testUsageLimitDoesNotSwitchBillingModeOrRetry() async throws {
        let provider = SettingsTestProvider()
        let model = try model(provider)
        await model.connect()
        await provider.emit(.usageLimitReached)
        for _ in 0..<40 { await Task.yield() }
        XCTAssertEqual(model.connectionStatus, .usageLimitReached)
        XCTAssertEqual(model.settings.profile(.codex).method, .account)
        XCTAssertFalse(model.canSend)
        let calls = await provider.connectCount
        XCTAssertEqual(calls, 1)
    }
    func testCatalogRefreshKeepsCustomModelsAndClearsDuplicates() {
        let settings = AppPreferences(defaults: defaults)
        let custom = ProviderModel(id: "custom", displayName: "Custom", description: "Custom model ID · access checked by provider")
        settings.update(.codex) { $0.catalog = [custom] }
        let fetched = ProviderModel(id: "listed", displayName: "Listed", reasoningEfforts: ["low", "high"], defaultReasoningEffort: "low")
        settings.mergeCatalog([fetched, fetched], provider: .codex)
        XCTAssertEqual(settings.profile(.codex).catalog.map(\.id), ["listed", "custom"])
        settings.update(.codex) { $0.reasoning["listed"] = "high" }
        XCTAssertEqual(settings.effectiveReasoning(for: fetched, provider: .codex), "high")
        settings.update(.codex) { $0.reasoning.removeValue(forKey: "listed") }
        XCTAssertEqual(settings.effectiveReasoning(for: fetched, provider: .codex), "low")
    }
}

final class ProviderConfigurationTests: XCTestCase {
    func testCodexModelCapabilitiesParsedWithoutInventingEffortLevels() throws {
        let data = Data("""
        [{"id":"a","displayName":"Model A","isDefault":true,"supportedReasoningEfforts":[{"reasoningEffort":"low"},{"reasoningEffort":"high"}]},{"id":"b","displayName":"Model B"}]
        """.utf8)
        let values = try JSONDecoder().decode([JSONValue].self, from: data)
        let models = CodexProvider.parseModels(values)
        XCTAssertEqual(models[0].reasoningEfforts, ["low", "high"]); XCTAssertTrue(models[0].isDefault)
        XCTAssertTrue(models[1].reasoningEfforts.isEmpty)
    }
    func testClaudeTerminalPreservesInteractivePermissionsAndSubscriptionAuthentication() {
        let job = ClaudeTerminalJob(action: .session, executable: "/example/claude", configurationDirectory: "/example/profile", method: .account, model: "opus", readOnly: true)
        XCTAssertEqual(job.arguments, ["--model", "opus", "--permission-mode", "plan"])
        XCTAssertFalse(job.arguments.contains("--bare"))
        XCTAssertFalse(job.arguments.contains("--dangerously-skip-permissions"))
        XCTAssertFalse(job.arguments.contains("-p"))
    }
    func testClaudeNativeControlsFailClosedUntilVerified() async throws {
        let provider = ClaudeProvider(path: "/never-launched")
        let capabilities = await provider.inspect().capabilities
        XCTAssertTrue(capabilities.terminalSession)
        XCTAssertFalse(capabilities.structuredStreaming)
        XCTAssertFalse(capabilities.nativeApprovals)
        XCTAssertFalse(capabilities.interrupt)
        do { _ = try await provider.startThread(projectPath: "/tmp", model: nil); XCTFail("Unverified native execution") }
        catch { guard case NativeAgentError.unsupported = error else { return XCTFail("Unexpected error") } }
    }
    func testProviderNamespacesSurviveDatabaseRestart() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("test.sqlite3"), database = try DatabaseActor(url: directory.appendingPathComponent("test.sqlite3"))
        let codex = Conversation(remoteThreadID: "same-id")
        var claude = Conversation(remoteThreadID: "same-id"); claude.providerID = .claude
        try await database.save(conversation: codex); try await database.save(conversation: claude)
        let restored = try await DatabaseActor(url: url).conversations()
        XCTAssertEqual(Set(restored.map(\.providerID)), [.codex, .claude])
    }
    func testShortLivedCommandsDrainOutputBeforeReturning() async throws {
        let runner = ProviderCommand()
        for _ in 0..<10 {
            let result = try await runner.run(path: "/usr/bin/printf", arguments: ["%s", "{\"loggedIn\":true}"], environment: [:], timeout: .seconds(3))
            XCTAssertEqual(result.code, 0)
            XCTAssertEqual(String(decoding: result.output, as: UTF8.self), #"{"loggedIn":true}"#)
        }
    }
}
