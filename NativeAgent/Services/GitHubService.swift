import Foundation

actor GitHubService {
    private let runner: any GitCommandRunning
    private var configuredCLIPath: String?
    private let cliCandidates: [String]
    private let pageSize = 50

    init(runner: any GitCommandRunning = GitCommandRunner(), configuredCLIPath: String? = nil,
         cliCandidates: [String] = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]) {
        self.runner = runner
        self.configuredCLIPath = configuredCLIPath
        self.cliCandidates = cliCandidates
    }

    func configureCLI(path: String?) { configuredCLIPath = path }

    func authStatus() async throws -> GitHubAuthState {
        guard let path = discoveredCLI() else { return GitHubAuthState(message: "Install the official GitHub CLI, then connect your account.") }
        let version = try await runner.run(GitCommand(executable: path, arguments: ["--version"], timeout: 10), progress: nil)
        guard version.status == 0, version.text.hasPrefix("gh version ") else {
            throw GitHubOperationError.invalid("Select the official GitHub CLI executable named gh.")
        }
        let status = try await gh(["auth", "status", "--hostname", "github.com", "--active"], allowFailure: true)
        guard status.status == 0 else { return GitHubAuthState(executablePath: path, message: "GitHub CLI is ready. Connect your GitHub account.") }
        let account = try await gh(["api", "--hostname", "github.com", "user", "--jq", ".login"])
        let login = account.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.matches(login, pattern: "^[A-Za-z0-9][A-Za-z0-9-]{0,38}$") else {
            throw GitHubOperationError.failed("GitHub returned an invalid account name.")
        }
        let storage = status.text + String(decoding: status.stderr, as: UTF8.self)
        let keychain = storage.contains("(keyring)")
        return GitHubAuthState(executablePath: path, login: login, usesKeychain: keychain,
            message: keychain ? "Connected as \(login). Credentials are managed by GitHub CLI in Keychain." :
                "Connected as \(login). GitHub CLI is using credentials outside Keychain; check gh auth status in Terminal.")
    }

    func login(progress: @escaping @Sendable (String) -> Void) async throws -> GitHubAuthState {
        _ = try await gh(["auth", "login", "--hostname", "github.com", "--git-protocol", "https", "--web"], timeout: 600,
            progress: { line in if let message = Self.loginProgress(line) { progress(message) } })
        _ = try await gh(["auth", "setup-git", "--hostname", "github.com"])
        return try await authStatus()
    }

    func logout(login: String) async throws {
        guard Self.matches(login, pattern: "^[A-Za-z0-9][A-Za-z0-9-]{0,38}$") else { throw GitHubOperationError.invalid("Invalid GitHub account.") }
        _ = try await gh(["auth", "logout", "--hostname", "github.com", "--user", login])
    }

    func repositories(page: Int) async throws -> [GitHubRepository] {
        guard (1...1000).contains(page) else { throw GitHubOperationError.invalid("Invalid repository page.") }
        let endpoint = "user/repos?per_page=\(pageSize)&page=\(page)&sort=updated&affiliation=owner,collaborator,organization_member"
        let result = try await gh(["api", "--hostname", "github.com", "--method", "GET", endpoint])
        return try JSONDecoder().decode([GitHubRepository].self, from: result.stdout)
    }

    func snapshot(root: String) async throws -> GitDesktopSnapshot {
        let root = try Self.directory(root)
        let top = try await git(["rev-parse", "--show-toplevel"], root: root, allowFailure: true)
        guard top.status == 0 else {
            return GitDesktopSnapshot(root: root, branch: "Not a Git repository", changes: [], ahead: 0, behind: 0,
                upstream: nil, remoteURL: nil, repository: nil, headSHA: nil, isRepository: false)
        }
        guard Self.canonical(top.text.trimmingCharacters(in: .whitespacesAndNewlines)) == root else {
            throw GitHubOperationError.invalid("Select the repository's root folder to manage Git changes.")
        }
        let status = try await git(["status", "--porcelain=v1", "-z", "--branch"], root: root)
        let branchResult = try await git(["symbolic-ref", "--quiet", "--short", "HEAD"], root: root, allowFailure: true)
        let headResult = try await git(["rev-parse", "--verify", "HEAD"], root: root, allowFailure: true)
        let upstreamResult = try await git(["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"], root: root, allowFailure: true)
        let remoteResult = try await git(["remote", "get-url", "origin"], root: root, allowFailure: true)
        let mergeHead = try await git(["rev-parse", "--quiet", "--verify", "MERGE_HEAD"], root: root, allowFailure: true)
        let upstream = upstreamResult.status == 0 ? upstreamResult.text.trimmed : nil
        var ahead = 0, behind = 0
        if upstream != nil {
            let counts = try await git(["rev-list", "--left-right", "--count", "HEAD...@{upstream}"], root: root)
            let values = counts.text.split(whereSeparator: \.isWhitespace).compactMap { Int($0) }
            if values.count == 2 { ahead = values[0]; behind = values[1] }
        }
        let remote = remoteResult.status == 0 ? remoteResult.text.trimmed : nil
        return GitDesktopSnapshot(root: root, branch: branchResult.status == 0 ? branchResult.text.trimmed : "Detached HEAD",
            changes: Self.parseChanges(status.stdout), ahead: ahead, behind: behind, upstream: upstream,
            remoteURL: remote.map(Self.redact), repository: remote.flatMap(Self.githubRepository),
            headSHA: headResult.status == 0 ? headResult.text.trimmed : nil, mergeInProgress: mergeHead.status == 0)
    }

    func branches(root: String) async throws -> [GitBranch] {
        let result = try await git(["for-each-ref", "--format=%(refname:short)%00%(HEAD)%00%(upstream:short)%00%(objectname)%00%(refname)",
                                    "refs/heads/", "refs/remotes/"], root: root)
        return result.text.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 5, !fields[0].hasSuffix("/HEAD") else { return nil }
            return GitBranch(name: fields[0], isCurrent: fields[1] == "*", isRemote: fields[4].hasPrefix("refs/remotes/"),
                             upstream: fields[2].isEmpty ? nil : fields[2], sha: fields[3])
        }
    }

    func commits(root: String, comparison: GitComparison? = nil, skip: Int = 0) async throws -> [GitCommit] {
        guard skip >= 0 else { throw GitHubOperationError.invalid("Invalid history page.") }
        var args = ["log", "-z", "--max-count=100", "--skip=\(skip)", "--format=%H%x00%s%x00%an%x00%cI"]
        if case .branches(let base, let head) = comparison {
            try Self.validateRef(base); try Self.validateRef(head)
            args.append("\(base)..\(head)")
        } else if case .upstream = comparison { args.append("@{upstream}..HEAD") }
        args.append("--")
        let result = try await git(args, root: root, allowFailure: true)
        if result.status != 0 {
            let head = try await git(["rev-parse", "--verify", "HEAD"], root: root, allowFailure: true)
            if head.status != 0 { return [] }
            try Self.requireSuccess(result)
        }
        let fields = result.text.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
        return stride(from: 0, to: max(0, fields.count - 3), by: 4).compactMap { index in
            guard Self.isSHA(fields[index]) else { return nil }
            return GitCommit(sha: fields[index], subject: fields[index + 1], author: fields[index + 2], date: fields[index + 3])
        }
    }

    func diff(root: String, comparison: GitComparison) async throws -> String {
        var args = ["diff", "--no-ext-diff", "--no-textconv", "--no-color"]
        switch comparison {
        case .working(let path):
            if let path { try Self.validatePath(path); args += ["--", path] }
            else { args.append("--") }
        case .staged(let path):
            args.append("--cached")
            if let path { try Self.validatePath(path); args += ["--", path] } else { args.append("--") }
        case .upstream: args += ["@{upstream}", "HEAD", "--"]
        case .branches(let base, let head):
            try Self.validateRef(base); try Self.validateRef(head)
            args += [base, head, "--"]
        case .commit(let sha):
            guard Self.isSHA(sha) else { throw GitHubOperationError.invalid("Invalid commit SHA.") }
            args = ["show", "--format=fuller", "--no-ext-diff", "--no-textconv", "--no-color", sha, "--"]
        }
        let result = try await git(args, root: root)
        if result.stdout.isEmpty, case .working(let path?) = comparison {
            let state = try await git(["status", "--porcelain=v1", "-z", "--", path], root: root)
            if Self.parseChanges(state.stdout).contains(where: { $0.kind == .untracked }) {
                let addition = try await git(["diff", "--no-index", "--no-ext-diff", "--no-textconv", "--no-color", "--", "/dev/null", path], root: root, allowFailure: true)
                guard addition.status == 0 || addition.status == 1 else { try Self.requireSuccess(addition); return "" }
                return addition.text
            }
        }
        return result.text
    }

    func stage(root: String, paths: [String]) async throws {
        try Self.validatePaths(paths)
        _ = try await git(["add", "--"] + paths, root: root)
    }

    func unstage(root: String, paths: [String]) async throws {
        try Self.validatePaths(paths)
        let head = try await git(["rev-parse", "--verify", "HEAD"], root: root, allowFailure: true)
        var selected = paths
        if head.status == 0 {
            // A staged rename represents both the old deletion and new addition.
            // Restoring only the displayed destination would leave the deletion
            // staged, so include its original path as part of the same action.
            let status = try await git(["status", "--porcelain=v1", "-z"], root: root)
            let records = status.stdout.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
            let destinations = Set(paths)
            var index = 0
            while index < records.count {
                let record = records[index]; index += 1
                let markers = record.prefix(2)
                guard markers.contains("R") || markers.contains("C") else { continue }
                guard index < records.count else { throw GitHubOperationError.failed("Unable to read the complete rename. Refresh and retry.") }
                let source = records[index]; index += 1
                if record.first == "R", destinations.contains(String(record.dropFirst(3))), !selected.contains(source) {
                    try Self.validatePath(source)
                    selected.append(source)
                }
            }
        }
        let args = head.status == 0 ? ["restore", "--staged", "--"] : ["rm", "--cached", "--ignore-unmatch", "--"]
        _ = try await git(args + selected, root: root)
    }

    func commit(root: String, message: String) async throws {
        guard !message.trimmed.isEmpty, message.utf8.count <= 32_768, !message.contains("\0") else {
            throw GitHubOperationError.invalid("Enter a commit message under 32 KiB.")
        }
        _ = try await git(["commit", "-m", message], root: root, timeout: 120)
    }

    func fetch(root: String) async throws {
        try await validateRemote(root: root)
        _ = try await git(["fetch", "origin"], root: root, timeout: 180)
    }

    func pull(root: String, expected: GitOperationExpectation) async throws {
        try await validateRemote(root: root)
        let state = try await checkedSnapshot(root: root, expected: expected)
        guard state.changes.isEmpty, !state.mergeInProgress else { throw GitHubOperationError.invalid("Commit your changes and finish any merge before pulling.") }
        guard state.branch != "Detached HEAD", let upstream = state.upstream, upstream.hasPrefix("origin/") else {
            throw GitHubOperationError.invalid("The current branch needs an origin tracking branch before pulling.")
        }
        let branch = String(upstream.dropFirst("origin/".count)); try Self.validateRef(branch)
        _ = try await git(["pull", "--ff-only", "--no-rebase", "origin", branch], root: root, timeout: 180)
    }

    func push(root: String, expected: GitOperationExpectation) async throws {
        let remote = try await reviewedPushRemote(root: root, expected: expected)
        let state = try await checkedSnapshot(root: root, expected: expected)
        guard state.branch != "Detached HEAD", let reviewedSHA = expected.headSHA else { throw GitHubOperationError.invalid("Commit on a named branch before pushing.") }
        try Self.validateRef(state.branch)
        let destination = state.upstream?.hasPrefix("origin/") == true ? String(state.upstream!.dropFirst(7)) : state.branch
        try Self.validateRef(destination)
        let trackingRef = "refs/remotes/origin/\(destination)"
        let previous = try await git(["rev-parse", "--verify", trackingRef], root: root, allowFailure: true)
        let oldSHA = previous.status == 0 ? previous.text.trimmed : String(repeating: "0", count: reviewedSHA.count)
        // Pin both object and destination: origin can have multiple push URLs or
        // change while this command runs. Mirror the resulting tracking ref only
        // if a concurrent fetch has not already advanced it.
        _ = try await git(["push", remote, "\(reviewedSHA):refs/heads/\(destination)"], root: root, timeout: 180)
        _ = try await git(["update-ref", trackingRef, reviewedSHA, oldSHA], root: root, allowFailure: true)
        _ = try await git(["branch", "--set-upstream-to=origin/\(destination)", "--", expected.branch], root: root)
    }

    func createBranch(root: String, name: String) async throws {
        try Self.validateRef(name)
        _ = try await git(["check-ref-format", "--branch", name], root: root)
        _ = try await git(["switch", "--create", name], root: root)
    }

    func switchBranch(root: String, name: String) async throws {
        try Self.validateRef(name)
        let available = try await branches(root: root)
        guard let branch = available.first(where: { $0.name == name }) else { throw GitHubOperationError.invalid("The selected branch no longer exists.") }
        if branch.isRemote {
            guard name.hasPrefix("origin/") else { throw GitHubOperationError.invalid("Only origin branches can be checked out here.") }
            let local = String(name.dropFirst(7)); try Self.validateRef(local)
            if available.contains(where: { !$0.isRemote && $0.name == local }) { _ = try await git(["switch", "--", local], root: root) }
            else { _ = try await git(["switch", "--track", "--create", local, name], root: root) }
        } else { _ = try await git(["switch", "--", name], root: root) }
    }

    func mergeBranch(root: String, name: String, expected: GitOperationExpectation, expectedSourceSHA: String) async throws {
        try Self.validateRef(name)
        guard Self.isSHA(expectedSourceSHA) else { throw GitHubOperationError.invalid("Refresh the source branch before merging.") }
        let state = try await checkedSnapshot(root: root, expected: expected)
        guard state.changes.isEmpty, !state.mergeInProgress, state.branch != "Detached HEAD" else {
            throw GitHubOperationError.invalid("Commit your changes and finish any existing merge before merging a branch.")
        }
        guard name != state.branch, try await branches(root: root).contains(where: { $0.name == name && $0.sha == expectedSourceSHA }) else {
            throw GitHubOperationError.invalid("The source branch changed. Refresh and review it before merging.")
        }
        _ = try await git(["merge", "--no-edit", "--", expectedSourceSHA], root: root, timeout: 120)
    }

    func abortMerge(root: String) async throws {
        let mergeHead = try await git(["rev-parse", "--quiet", "--verify", "MERGE_HEAD"], root: root, allowFailure: true)
        guard mergeHead.status == 0 else { throw GitHubOperationError.invalid("There is no merge to abort.") }
        _ = try await git(["merge", "--abort"], root: root)
    }

    func clone(repository: GitHubRepository, to destination: URL) async throws -> URL {
        try Self.validateRepository(repository.fullName)
        let target = try Self.destination(destination)
        _ = try await gh(["repo", "clone", repository.fullName, target.path], timeout: 300)
        return target
    }

    func publish(root: String, name: String, privateRepository: Bool = true) async throws {
        try Self.validateRepository(name, allowUnqualified: true)
        let root = try Self.directory(root)
        let state = try await snapshot(root: root)
        guard state.remoteURL == nil else { throw GitHubOperationError.invalid("This folder already has an origin remote. Use Push to update it.") }
        if !state.isRepository {
            _ = try await git(["init", "--initial-branch=main"], root: root)
        }
        _ = try await gh(["repo", "create", name, privateRepository ? "--private" : "--public", "--source", root, "--remote", "origin"], directory: root, timeout: 120)
    }

    func createRepository(name: String, at destination: URL, privateRepository: Bool = true) async throws -> URL {
        try Self.validateRepository(name, allowUnqualified: true)
        let target = try Self.destination(destination)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        try await publish(root: target.path, name: name, privateRepository: privateRepository)
        return target
    }

    func pullRequests(root: String) async throws -> [GitHubPullRequest] {
        guard let repository = try await snapshot(root: root).repository else { return [] }
        let fields = "number,title,url,headRefName,baseRefName,headRefOid,isDraft,mergeStateStatus,state"
        let result = try await gh(["pr", "list", "--repo", repository, "--state", "open", "--limit", "100", "--json", fields], directory: root)
        return try JSONDecoder().decode([GitHubPullRequest].self, from: result.stdout)
    }

    func createPullRequest(root: String, title: String, body: String, base: String, draft: Bool, expected: GitOperationExpectation) async throws {
        guard !title.trimmed.isEmpty, title.utf8.count < 1024, body.utf8.count <= 65_536,
              !title.contains("\0"), !body.contains("\0") else { throw GitHubOperationError.invalid("Enter a title and a pull request description under 64 KiB.") }
        try Self.validateRef(base)
        let state = try await checkedSnapshot(root: root, expected: expected)
        guard let repository = state.repository, state.branch != "Detached HEAD", state.headSHA != nil else {
            throw GitHubOperationError.invalid("Select a GitHub repository and a named branch.")
        }
        try Self.validateRef(state.branch)
        guard let upstream = state.upstream, upstream.hasPrefix("origin/"), state.ahead == 0, state.behind == 0 else {
            throw GitHubOperationError.invalid("Push this branch to origin and synchronize it before creating its pull request.")
        }
        let remoteBranch = String(upstream.dropFirst("origin/".count))
        try Self.validateRef(remoteBranch)
        let encodedBranch = remoteBranch.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~")))!
        let remoteHead = try await gh(["api", "--hostname", "github.com", "repos/\(repository)/branches/\(encodedBranch)", "--jq", ".commit.sha"])
        guard remoteHead.text.trimmed == expected.headSHA else {
            throw GitHubOperationError.invalid("The GitHub branch differs from the reviewed commit. Fetch, synchronize, and review it before creating a pull request.")
        }
        var args = ["pr", "create", "--repo", repository, "--head", remoteBranch, "--base", base, "--title", title, "--body", body]
        if draft { args.append("--draft") }
        _ = try await gh(args, directory: root, timeout: 120)
    }

    func mergePullRequest(root: String, request: GitHubPullRequest) async throws {
        guard request.number > 0, Self.isSHA(request.headRefOid), !request.isDraft, request.state.uppercased() == "OPEN" else {
            throw GitHubOperationError.invalid("Only an open, non-draft pull request with a reviewed commit can be merged.")
        }
        guard let repository = try await snapshot(root: root).repository else { throw GitHubOperationError.invalid("Select a GitHub repository.") }
        guard request.url.hasPrefix("https://github.com/\(repository)/pull/") else {
            throw GitHubOperationError.invalid("The pull request belongs to a different repository. Refresh and select it again.")
        }
        _ = try await gh(["pr", "merge", String(request.number), "--repo", repository, "--merge", "--match-head-commit", request.headRefOid], directory: root, timeout: 120)
    }

    func pullRequestDiff(root: String, request: GitHubPullRequest) async throws -> String {
        guard request.number > 0, let repository = try await snapshot(root: root).repository,
              request.url.hasPrefix("https://github.com/\(repository)/pull/") else {
            throw GitHubOperationError.invalid("Select a pull request from this repository.")
        }
        return try await gh(["pr", "diff", String(request.number), "--repo", repository, "--color", "never"], directory: root).text
    }

    private func discoveredCLI() -> String? {
        let candidates = configuredCLIPath.map { [$0] } ?? cliCandidates
        return candidates.first { $0.hasPrefix("/") && URL(fileURLWithPath: $0).lastPathComponent == "gh" && FileManager.default.isExecutableFile(atPath: $0) }
    }

    private func gh(_ arguments: [String], directory: String? = nil, timeout: TimeInterval = 60,
                    allowFailure: Bool = false, progress: (@Sendable (String) -> Void)? = nil) async throws -> GitCommandResult {
        try Task.checkCancellation()
        guard let path = discoveredCLI() else { throw GitHubOperationError.unavailable("Install GitHub CLI or select its gh executable in GitHub settings.") }
        let result = try await runner.run(GitCommand(executable: path, arguments: arguments, directory: directory,
                                                     timeout: timeout, environment: ["GH_HOST": "github.com", "GH_BROWSER": "/usr/bin/open"]), progress: progress)
        try Task.checkCancellation()
        if !allowFailure { try Self.requireSuccess(result) }
        return result
    }

    private func git(_ arguments: [String], root: String, timeout: TimeInterval = 60, allowFailure: Bool = false) async throws -> GitCommandResult {
        try Task.checkCancellation()
        let directory = try Self.directory(root)
        let result = try await runner.run(GitCommand(executable: "/usr/bin/git", arguments: ["--literal-pathspecs", "-c", "core.fsmonitor=false", "-C", directory] + arguments,
            directory: directory, timeout: timeout), progress: nil)
        try Task.checkCancellation()
        if !allowFailure { try Self.requireSuccess(result) }
        return result
    }

    private func validateRemote(root: String, pushing: Bool = false) async throws {
        let args = ["remote", "get-url"] + (pushing ? ["--push"] : []) + ["origin"]
        let remote = try await git(args, root: root)
        guard Self.isSafeRemote(remote.text.trimmed) else { throw GitHubOperationError.invalid("The origin remote must use an HTTPS or SSH URL without embedded credentials.") }
    }

    private func reviewedPushRemote(root: String, expected: GitOperationExpectation) async throws -> String {
        let result = try await git(["remote", "get-url", "--push", "--all", "origin"], root: root)
        let urls = result.text.split(whereSeparator: \.isNewline).map(String.init)
        guard urls.count == 1, let remote = urls.first, Self.isSafeRemote(remote), let reviewedRemote = expected.remoteURL else {
            throw GitHubOperationError.invalid("Origin must have one HTTPS or SSH push destination. Review its remote configuration before pushing.")
        }
        let reviewedRepository = Self.githubRepository(reviewedRemote)?.lowercased()
        guard remote == reviewedRemote || (reviewedRepository != nil && Self.githubRepository(remote)?.lowercased() == reviewedRepository) else {
            throw GitHubOperationError.invalid("Origin pushes to a different repository than the one displayed. Review its remote configuration before pushing.")
        }
        return remote
    }

    private func checkedSnapshot(root: String, expected: GitOperationExpectation) async throws -> GitDesktopSnapshot {
        let current = try await snapshot(root: root)
        guard GitOperationExpectation(current) == expected else {
            throw GitHubOperationError.invalid("The repository's branch, commit, or remote changed. Refresh and review it before retrying.")
        }
        return current
    }

    static func parseChanges(_ data: Data) -> [GitFileChange] {
        let records = data.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
        var result: [GitFileChange] = [], index = 0
        while index < records.count {
            let record = records[index]; index += 1
            guard !record.hasPrefix("## "), record.count >= 3 else { continue }
            let markers = Array(record.prefix(2)), path = String(record.dropFirst(3))
            if markers.contains("R") || markers.contains("C") { index += 1 } // -z places the destination first.
            if markers == ["?", "?"] { result.append(GitFileChange(path: path, kind: .untracked, staged: false)); continue }
            let conflict = markers.contains("U") || markers == ["A", "A"] || markers == ["D", "D"]
            for (position, marker) in markers.enumerated() where marker != " " && marker != "!" {
                let kind: GitChangeKind = conflict ? .conflicted : ["A": .added, "D": .deleted, "R": .renamed, "C": .copied][String(marker)] ?? .modified
                result.append(GitFileChange(path: path, kind: kind, staged: position == 0))
            }
        }
        return result
    }

    static func validateRef(_ value: String) throws {
        guard !value.isEmpty, value.utf8.count <= 255, !value.hasPrefix("-"), !value.hasPrefix("/"), !value.hasSuffix("/"),
              !value.hasSuffix("."), !value.contains(".."), !value.contains("//"), !value.contains("@{"),
              !value.split(separator: "/").contains(where: { $0.hasPrefix(".") || $0.hasSuffix(".lock") }),
              value.unicodeScalars.allSatisfy({ $0.value > 32 && $0.value != 127 && !"~^:?*[\\".unicodeScalars.contains($0) }) else {
            throw GitHubOperationError.invalid("Enter a valid Git branch or reference name.")
        }
    }

    static func validatePath(_ path: String) throws {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\0"), path.utf8.count < 16_384,
              !path.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0 == ".." || $0 == "." || $0.isEmpty || $0 == ".git" }) else {
            throw GitHubOperationError.invalid("Select a file inside the current repository.")
        }
    }

    private static func validatePaths(_ paths: [String]) throws {
        guard !paths.isEmpty, paths.count <= 2000 else { throw GitHubOperationError.invalid("Select between 1 and 2,000 files.") }
        try paths.forEach(validatePath)
    }

    static func validateRepository(_ name: String, allowUnqualified: Bool = false) throws {
        let parts = name.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2 || (allowUnqualified && parts.count == 1),
              parts.allSatisfy({ matches(String($0), pattern: "^[A-Za-z0-9][A-Za-z0-9._-]{0,99}$") && $0 != "." && $0 != ".." }) else {
            throw GitHubOperationError.invalid("Use a repository name such as owner/project.")
        }
    }

    static func githubRepository(_ remote: String) -> String? {
        guard isSafeRemote(remote) else { return nil }
        let path: String
        if remote.hasPrefix("git@github.com:") { path = String(remote.dropFirst("git@github.com:".count)) }
        else if let url = URL(string: remote), url.host?.lowercased() == "github.com", ["https", "ssh"].contains(url.scheme ?? ""), url.password == nil {
            path = String(url.path.drop(while: { $0 == "/" }))
        } else { return nil }
        let repository = path.hasSuffix(".git") ? String(path.dropLast(4)) : path
        return (try? validateRepository(repository)) != nil ? repository : nil
    }

    static func isSafeRemote(_ remote: String) -> Bool {
        if matches(remote, pattern: "^git@[A-Za-z0-9.-]+:[A-Za-z0-9._/-]+$") { return !remote.contains("..") }
        guard let url = URL(string: remote), let host = url.host, !host.isEmpty, url.password == nil, url.query == nil, url.fragment == nil else { return false }
        if url.scheme == "https" { return url.user == nil && !url.path.isEmpty }
        return url.scheme == "ssh" && url.user == "git" && !url.path.isEmpty
    }

    static func redact(_ text: String) -> String {
        var value = text
        for pattern in ["(?:gh[pousr]_[A-Za-z0-9_]+|github_pat_[A-Za-z0-9_]+)", "(?i)(?:Bearer|token)\\s+[A-Za-z0-9_.-]{12,}", "https://[^\\s/@]+@"] {
            if let expression = try? NSRegularExpression(pattern: pattern) {
                value = expression.stringByReplacingMatches(in: value, range: NSRange(value.startIndex..., in: value), withTemplate: "[redacted]")
            }
        }
        return value
    }

    static func loginProgress(_ line: String) -> String? {
        if let range = line.range(of: "\\b[A-Z0-9]{4}-[A-Z0-9]{4}\\b", options: .regularExpression) {
            return "Enter code \(line[range]) at https://github.com/login/device"
        }
        if line.localizedCaseInsensitiveContains("authentication complete") { return "GitHub authorization completed." }
        if line.localizedCaseInsensitiveContains("browser") { return "Continue authorization in your browser." }
        return nil
    }

    private static func requireSuccess(_ result: GitCommandResult) throws {
        guard result.status == 0 else {
            let text = String(decoding: result.stderr.prefix(8192), as: UTF8.self).trimmed
            throw GitHubOperationError.failed(redact(text.isEmpty ? "Command failed (exit \(result.status))." : text))
        }
    }

    private static func matches(_ value: String, pattern: String) -> Bool { value.range(of: pattern, options: .regularExpression) != nil }
    private static func isSHA(_ value: String) -> Bool { matches(value, pattern: "^[0-9a-fA-F]{40}(?:[0-9a-fA-F]{24})?$") }
    private static func canonical(_ path: String) -> String { URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path }
    private static func directory(_ path: String) throws -> String {
        var directory: ObjCBool = false
        guard path.hasPrefix("/"), !path.contains("\0"), FileManager.default.fileExists(atPath: path, isDirectory: &directory), directory.boolValue else {
            throw GitHubOperationError.invalid("Choose an existing local folder.")
        }
        return canonical(path)
    }
    private static func destination(_ url: URL) throws -> URL {
        guard url.isFileURL, !FileManager.default.fileExists(atPath: url.path), !url.lastPathComponent.isEmpty else {
            throw GitHubOperationError.invalid("Choose a new destination folder that does not already exist.")
        }
        let parent = try directory(url.deletingLastPathComponent().path)
        return URL(fileURLWithPath: parent, isDirectory: true).appendingPathComponent(url.lastPathComponent, isDirectory: true)
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
