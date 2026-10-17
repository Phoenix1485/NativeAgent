import Combine
import Foundation
import AppKit

@MainActor
final class GitHubController: ObservableObject {
    @Published private(set) var auth = GitHubAuthState()
    @Published private(set) var repositories: [GitHubRepository] = []
    @Published private(set) var hasMoreRepositories = false
    @Published private(set) var snapshot: GitDesktopSnapshot?
    @Published private(set) var branches: [GitBranch] = []
    @Published private(set) var commits: [GitCommit] = []
    @Published private(set) var pullRequests: [GitHubPullRequest] = []
    @Published private(set) var diff = ""
    @Published private(set) var compareSelection = "Working changes"
    @Published private(set) var busy = false
    @Published var error: String?
    @Published private(set) var githubError: String?
    @Published private(set) var loginOutput = ""
    @Published private(set) var lastFetchedAt: Date?
    @Published private(set) var projectRoot: String?
    let installationURL = URL(string: "https://cli.github.com/")!
    var onRepositoryChanged: (@MainActor () async -> Void)?
    var executablePath: String? { auth.executablePath }
    var configuredCLIPath: String? { preferences.string(forKey: Self.cliPreference) }

    private static let cliPreference = "githubCLIExecutablePath"
    private let service: GitHubService
    private let preferences: UserDefaults
    private var generation = UUID()
    private var operationID: UUID?
    private var cancelOperation: (() -> Void)?
    private var inFlight: [UUID: (cancel: () -> Void, wait: () async -> Void)] = [:]
    private var shuttingDown = false
    private let openURL: (URL) -> Void
    private var loginBrowserOpened = false
    private var repositoryPage = 0

    init(service: GitHubService? = nil, preferences: UserDefaults = .standard, openURL: ((URL) -> Void)? = nil) {
        self.preferences = preferences
        self.service = service ?? GitHubService(configuredCLIPath: preferences.string(forKey: Self.cliPreference))
        self.openURL = openURL ?? { NSWorkspace.shared.open($0) }
    }

    func cancel() { cancelOperation?() }

    func shutdown() async {
        shuttingDown = true
        let work = Array(inFlight.values)
        work.forEach { $0.cancel() }
        for operation in work { await operation.wait() }
    }

    func configureCLI(path: String?) async {
        cancel()
        generation = UUID(); operationID = nil; busy = false
        preferences.set(path, forKey: Self.cliPreference)
        await service.configureCLI(path: path)
        auth = GitHubAuthState(); repositories = []; repositoryPage = 0; hasMoreRepositories = false
        await refreshAuth()
    }

    func refreshAuth() async {
        if let value = await perform({ try await self.service.authStatus() }) { auth = value }
    }

    func login() async {
        loginOutput = "Opening GitHub authorization…"
        loginBrowserOpened = false
        let owner = generation
        let value = await perform {
            try await self.service.login { [weak self] message in
                Task { @MainActor in
                    guard let self, self.generation == owner else { return }
                    self.loginOutput = String((self.loginOutput + "\n" + message).suffix(4096))
                    if message.hasPrefix("Enter code "), !self.loginBrowserOpened {
                        self.loginBrowserOpened = true
                        self.openURL(URL(string: "https://github.com/login/device")!)
                    }
                }
            }
        }
        if let value {
            auth = value
            loginOutput = value.isAuthenticated ? "Connected to GitHub." : value.message
            await loadRepositories()
        }
    }

    func logout() async {
        guard let login = auth.login else { return }
        if await perform({ try await self.service.logout(login: login) }) != nil {
            auth = GitHubAuthState(executablePath: auth.executablePath)
            repositories = []; repositoryPage = 0; hasMoreRepositories = false; pullRequests = []
            loginOutput = ""
        }
    }

    func loadRepositories(reset: Bool = true) async {
        guard auth.isAuthenticated else { return }
        let page = reset ? 1 : repositoryPage + 1
        if let values = await perform({ try await self.service.repositories(page: page) }) {
            if reset { repositories = values }
            else {
                let known = Set(repositories.map(\.id))
                repositories += values.filter { !known.contains($0.id) }
            }
            repositoryPage = page
            hasMoreRepositories = values.count == 50
        }
    }

    func setProject(root: String?) async {
        let canonical = root.map { URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath().path }
        guard canonical != projectRoot else { return }
        cancel(); generation = UUID(); operationID = nil; busy = false
        projectRoot = canonical
        snapshot = nil; branches = []; commits = []; pullRequests = []; diff = ""; error = nil; githubError = nil; lastFetchedAt = nil
        compareSelection = "Working changes"
        await refresh()
    }

    func refresh() async {
        guard let root = projectRoot else { return }
        let result = await perform { () async throws -> (GitDesktopSnapshot, [GitBranch], [GitCommit], [GitHubPullRequest], String?) in
            let state = try await self.service.snapshot(root: root)
            guard state.isRepository else { return (state, [], [], [], nil) }
            let branches = try await self.service.branches(root: root)
            let commits = try await self.service.commits(root: root)
            var requests: [GitHubPullRequest] = [], remoteFailure: String?
            if self.auth.isAuthenticated && state.repository != nil {
                do { requests = try await self.service.pullRequests(root: root) }
                catch is CancellationError { throw CancellationError() }
                catch { remoteFailure = GitHubService.redact(error.localizedDescription) }
            }
            return (state, branches, commits, requests, remoteFailure)
        }
        if let result {
            snapshot = result.0; branches = result.1; commits = result.2; pullRequests = result.3
            githubError = result.4
        }
    }

    func stage(paths: [String]) async { await mutate { try await self.service.stage(root: $0, paths: paths) } }
    func unstage(paths: [String]) async { await mutate { try await self.service.unstage(root: $0, paths: paths) } }
    func commit(message: String) async { await mutate { try await self.service.commit(root: $0, message: message) } }
    func fetch() async {
        if await mutate({ try await self.service.fetch(root: $0) }) { lastFetchedAt = Date() }
    }
    func pull() async {
        guard let expected = currentExpectation() else { return }
        await mutate { try await self.service.pull(root: $0, expected: expected) }
    }
    func push() async {
        guard let expected = currentExpectation() else { return }
        await mutate { try await self.service.push(root: $0, expected: expected) }
    }
    func createBranch(name: String) async { await mutate { try await self.service.createBranch(root: $0, name: name) } }
    func switchBranch(name: String) async { await mutate { try await self.service.switchBranch(root: $0, name: name) } }
    func mergeBranch(name: String) async {
        guard let expected = currentExpectation(), let source = branches.first(where: { $0.name == name }) else { return }
        await mutate { try await self.service.mergeBranch(root: $0, name: name, expected: expected, expectedSourceSHA: source.sha) }
    }
    func abortMerge() async { await mutate { try await self.service.abortMerge(root: $0) } }

    func compare(_ comparison: GitComparison) async {
        guard !busy, !shuttingDown, let root = projectRoot else { return }
        diff = ""
        if let value = await perform({ try await self.service.diff(root: root, comparison: comparison) }) {
            diff = value
            switch comparison {
            case .working(let path): compareSelection = path.map { "Working: \($0)" } ?? "Working changes"
            case .staged(let path): compareSelection = path.map { "Staged: \($0)" } ?? "Staged changes"
            case .upstream: compareSelection = "Upstream → local"
            case .branches(let base, let head): compareSelection = "\(base) → \(head)"
            case .commit(let sha): compareSelection = "Commit \(sha.prefix(8))"
            }
        }
    }

    func loadPullRequestDiff(_ request: GitHubPullRequest) async {
        guard !busy, !shuttingDown, let root = projectRoot else { return }
        diff = ""
        if let value = await perform({ try await self.service.pullRequestDiff(root: root, request: request) }) {
            diff = value; compareSelection = "Pull request #\(request.number): \(request.title)"
        }
    }

    func clone(repo: GitHubRepository, to destination: URL) async -> URL? {
        await perform { try await self.service.clone(repository: repo, to: destination) }
    }

    @discardableResult
    func publish(name: String, privateRepository: Bool = true) async -> Bool {
        await mutate { try await self.service.publish(root: $0, name: name, privateRepository: privateRepository) }
    }

    func createRepository(name: String, at destination: URL, privateRepository: Bool = true) async -> URL? {
        await perform { try await self.service.createRepository(name: name, at: destination, privateRepository: privateRepository) }
    }

    func createPullRequest(title: String, body: String, base: String, draft: Bool) async {
        guard let expected = currentExpectation() else { return }
        await mutate { try await self.service.createPullRequest(root: $0, title: title, body: body, base: base, draft: draft, expected: expected) }
    }

    func mergePullRequest(_ request: GitHubPullRequest) async {
        await mutate { try await self.service.mergePullRequest(root: $0, request: request) }
    }

    @discardableResult
    private func mutate(_ action: @escaping @MainActor (String) async throws -> Void) async -> Bool {
        guard let root = projectRoot else { error = "Choose a local project first."; return false }
        let owner = generation
        guard await perform({ try await action(root) }) != nil else {
            if generation == owner, !busy, !shuttingDown {
                let failure = error
                if failure?.hasPrefix("Canceled.") == true { return false }
                await refresh()
                if let failure { error = failure }
                if generation == owner { await onRepositoryChanged?() }
            }
            return false
        }
        diff = ""
        await refresh()
        if generation == owner { await onRepositoryChanged?() }
        return true
    }

    private func currentExpectation() -> GitOperationExpectation? {
        guard let snapshot, snapshot.isRepository, snapshot.root == projectRoot else {
            error = "Refresh the current repository before continuing."
            return nil
        }
        return GitOperationExpectation(snapshot)
    }

    private func perform<Value>(_ action: @escaping @MainActor () async throws -> Value) async -> Value? {
        guard !busy, !shuttingDown else { return nil }
        let owner = generation, id = UUID()
        operationID = id; busy = true; error = nil
        let task = Task { try await action() }
        cancelOperation = { task.cancel() }
        inFlight[id] = (cancel: { task.cancel() }, wait: { _ = try? await task.value })
        defer {
            inFlight.removeValue(forKey: id)
            if operationID == id { busy = false; operationID = nil; cancelOperation = nil }
        }
        do {
            let result = try await task.value
            guard generation == owner, operationID == id else { return nil }
            guard !task.isCancelled else {
                error = "Canceled. Refresh before retrying; a remote action may have completed."
                return nil
            }
            return result
        } catch is CancellationError {
            if generation == owner, operationID == id {
                error = "Canceled. Refresh before retrying; a remote action may have completed."
            }
            return nil
        } catch {
            guard generation == owner, operationID == id else { return nil }
            self.error = GitHubService.redact(error.localizedDescription)
            return nil
        }
    }
}
