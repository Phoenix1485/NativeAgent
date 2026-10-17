import Foundation
import XCTest
@testable import NativeAgent

final class GitHubServiceTests: XCTestCase {
    func testPorcelainRenamesUseDestinationAndConflictsRemainVisible() {
        let records = Data("R  new name.swift\0old name.swift\0UU conflict.swift\0?? untracked.txt\0".utf8)
        let changes = GitHubService.parseChanges(records)
        XCTAssertEqual(changes.first?.path, "new name.swift")
        XCTAssertEqual(changes.first?.kind, .renamed)
        XCTAssertEqual(changes.filter { $0.kind == .conflicted }.count, 2)
        XCTAssertEqual(changes.last?.kind, .untracked)
    }

    func testReferencesPathsRemotesAndProgressRejectInjectionAndCredentials() throws {
        for value in ["--upload-pack=evil", "main..other", "branch@{1}", "a:b", "a/../b", "a\nb"] {
            XCTAssertThrowsError(try GitHubService.validateRef(value))
        }
        for value in ["../secret", "/tmp/secret", ".git/config", "dir/../secret", "a\0b"] {
            XCTAssertThrowsError(try GitHubService.validatePath(value))
        }
        try GitHubService.validatePath("name with spaces [1]*.swift")
        XCTAssertFalse(GitHubService.isSafeRemote("ext::sh -c evil"))
        XCTAssertFalse(GitHubService.isSafeRemote("https://user:token@github.com/org/repo"))
        XCTAssertTrue(GitHubService.isSafeRemote("git@github.com:org/repo.git"))
        XCTAssertEqual(GitHubService.githubRepository("https://github.com/org/repo.git"), "org/repo")
        XCTAssertNil(GitHubService.githubRepository("https://github.com.evil.test/org/repo.git"))
        XCTAssertNil(GitHubService.loginProgress("Token: ghp_secretvalue123456789"))
        XCTAssertEqual(GitHubService.loginProgress("! First copy your one-time code: ABCD-1234"), "Enter code ABCD-1234 at https://github.com/login/device")
        XCTAssertFalse(GitHubService.redact("failure ghp_secretvalue123456789 github_pat_secretvalue123456789").contains("secretvalue"))
    }

    func testRunnerDrainsBothPipesAndKeepsArgumentsLiteral() async throws {
        let runner = GitCommandRunner()
        let result = try await runner.run(GitCommand(executable: "/bin/sh", arguments: ["-c",
            "i=0; while [ \"$i\" -lt 20000 ]; do printf 'error-data\\n' >&2; i=$((i+1)); done; printf 'done\\n'"], timeout: 15), progress: nil)
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.text, "done\n")
        XCTAssertGreaterThan(result.stderr.count, 100_000)
        let literal = "$(touch /tmp/this-must-not-run); ' --dangerous"
        let echo = try await runner.run(GitCommand(executable: "/usr/bin/printf", arguments: ["%s", literal]), progress: nil)
        XCTAssertEqual(echo.text, literal)
    }

    func testRunnerBoundsOutputTimeoutAndCancellation() async throws {
        let runner = GitCommandRunner()
        do {
            _ = try await runner.run(GitCommand(executable: "/usr/bin/yes", arguments: [], timeout: 5, maximumOutput: 4096), progress: nil)
            XCTFail("Unbounded output succeeded")
        } catch GitHubOperationError.outputLimit { }
        let start = Date()
        do {
            _ = try await runner.run(GitCommand(executable: "/bin/sleep", arguments: ["5"], timeout: 0.05), progress: nil)
            XCTFail("Timeout was ignored")
        } catch GitHubOperationError.timedOut { }
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
        let pending = Task { try await runner.run(GitCommand(executable: "/bin/sleep", arguments: ["5"]), progress: nil) }
        try await Task.sleep(for: .milliseconds(50))
        pending.cancel()
        do { _ = try await pending.value; XCTFail("Cancellation was ignored") } catch is CancellationError { }
    }

    func testLocalStageUnstageCommitBranchAndDiffUseLiteralPaths() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try await initialize(root)
        let service = GitHubService()
        let selected = "file [1]*.txt", other = "file 1-extra.txt"
        try Data("first\n".utf8).write(to: root.appendingPathComponent(selected))
        try Data("other\n".utf8).write(to: root.appendingPathComponent(other))
        try await service.stage(root: root.path, paths: [selected])
        var state = try await service.snapshot(root: root.path)
        XCTAssertEqual(state.changes.filter(\.staged).map(\.path), [selected])
        try await service.unstage(root: root.path, paths: [selected])
        state = try await service.snapshot(root: root.path)
        XCTAssertFalse(state.changes.contains(where: \.staged))
        try await service.stage(root: root.path, paths: [selected])
        let staged = try await service.diff(root: root.path, comparison: .staged(path: selected))
        XCTAssertTrue(staged.contains("+first"))
        try await service.commit(root: root.path, message: "First commit\n\nLiteral commit body $(nothing)")
        let history = try await service.commits(root: root.path)
        XCTAssertEqual(history.first?.subject, "First commit")
        try await service.createBranch(root: root.path, name: "feature/test")
        try Data("first\nsecond\n".utf8).write(to: root.appendingPathComponent(selected))
        let diff = try await service.diff(root: root.path, comparison: .working(path: selected))
        XCTAssertTrue(diff.contains("+second"))
        try await service.stage(root: root.path, paths: [selected])
        try await service.commit(root: root.path, message: "Second commit")
        try await service.switchBranch(root: root.path, name: "main")
        let comparison = try await service.diff(root: root.path, comparison: .branches(base: "main", head: "feature/test"))
        XCTAssertTrue(comparison.contains("+second"))
        let branches = try await service.branches(root: root.path)
        XCTAssertEqual(branches.first(where: \.isCurrent)?.name, "main")
    }

    func testMergeConflictsArePreservedAndExplicitAbortRestoresCleanStart() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try await initialize(root)
        let service = GitHubService(), file = root.appendingPathComponent("conflict.txt")
        try Data("base\n".utf8).write(to: file)
        try await service.stage(root: root.path, paths: ["conflict.txt"])
        try await service.commit(root: root.path, message: "Base")
        try await service.createBranch(root: root.path, name: "feature")
        try Data("feature\n".utf8).write(to: file)
        try await service.stage(root: root.path, paths: ["conflict.txt"])
        try await service.commit(root: root.path, message: "Feature")
        let sourceSnapshot = try await service.snapshot(root: root.path)
        let sourceSHA = try XCTUnwrap(sourceSnapshot.headSHA)
        try await service.switchBranch(root: root.path, name: "main")
        try Data("main\n".utf8).write(to: file)
        try await service.stage(root: root.path, paths: ["conflict.txt"])
        try await service.commit(root: root.path, message: "Main")
        let reviewed = try await service.snapshot(root: root.path)
        do { try await service.mergeBranch(root: root.path, name: "feature", expected: GitOperationExpectation(reviewed), expectedSourceSHA: sourceSHA); XCTFail("Expected merge conflict") } catch { }
        let conflict = try await service.snapshot(root: root.path)
        XCTAssertTrue(conflict.mergeInProgress)
        XCTAssertTrue(conflict.changes.contains { $0.kind == .conflicted })
        XCTAssertTrue(try String(contentsOf: file, encoding: .utf8).contains("<<<<<<<"))
        try await service.abortMerge(root: root.path)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "main\n")
        let afterAbort = try await service.snapshot(root: root.path)
        XCTAssertFalse(afterAbort.mergeInProgress)
        try Data("dirty\n".utf8).write(to: file)
        let dirty = try await service.snapshot(root: root.path)
        do { try await service.mergeBranch(root: root.path, name: "feature", expected: GitOperationExpectation(dirty), expectedSourceSHA: sourceSHA); XCTFail("Dirty merge started") } catch { }
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "dirty\n")
    }

    func testUnstageRenameRestoresBothIndexPathsAndPreservesWorkingFile() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try await initialize(root)
        let service = GitHubService()
        let original = "before [1]*.txt", renamed = "after [1]*.txt"
        try Data("unchanged contents\n".utf8).write(to: root.appendingPathComponent(original))
        try await service.stage(root: root.path, paths: [original])
        try await service.commit(root: root.path, message: "Original file")
        try FileManager.default.moveItem(at: root.appendingPathComponent(original), to: root.appendingPathComponent(renamed))
        try await service.stage(root: root.path, paths: [original, renamed])
        let staged = try await service.snapshot(root: root.path)
        XCTAssertTrue(staged.changes.contains { $0.path == renamed && $0.kind == .renamed && $0.staged })

        try await service.unstage(root: root.path, paths: [renamed])
        let unstaged = try await service.snapshot(root: root.path)
        XCTAssertFalse(unstaged.changes.contains(where: \.staged), "The original deletion must also be unstaged")
        XCTAssertTrue(unstaged.changes.contains { $0.path == original && $0.kind == .deleted })
        XCTAssertTrue(unstaged.changes.contains { $0.path == renamed && $0.kind == .untracked })
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent(renamed), encoding: .utf8), "unchanged contents\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(original).path))
    }

    func testGitHubPagingAuthAndPublishUseExplicitSafeArguments() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("gh")
        try Data().write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let fake = GitHubFixtureRunner(root: root.path)
        let service = GitHubService(runner: fake, configuredCLIPath: executable.path)
        let auth = try await service.authStatus()
        XCTAssertEqual(auth.login, "octocat")
        XCTAssertTrue(auth.usesKeychain)
        let repositories = try await service.repositories(page: 2)
        XCTAssertEqual(repositories.first?.fullName, "octocat/project")
        try await service.publish(root: root.path, name: "new-project")
        let commands = await fake.commands
        XCTAssertTrue(commands.contains { $0.arguments.contains(where: { $0.contains("page=2") && $0.contains("per_page=50") }) })
        let create = try XCTUnwrap(commands.first { $0.arguments.starts(with: ["repo", "create"]) })
        XCTAssertTrue(create.arguments.contains("--private"))
        XCTAssertFalse(create.arguments.contains("--push"))
        XCTAssertFalse(commands.contains { $0.arguments.contains("push") || $0.arguments.contains("commit") || $0.arguments.contains("add") })
        XCTAssertFalse(commands.contains { $0.arguments.starts(with: ["auth", "token"]) })
    }

    func testPullRequestMergePinsReviewedHeadAndRejectsDifferentRepository() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("gh")
        try Data().write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let fake = GitHubFixtureRunner(root: root.path, remote: "https://github.com/octocat/project.git")
        let service = GitHubService(runner: fake, configuredCLIPath: executable.path)
        let sha = String(repeating: "a", count: 40)
        let request = GitHubPullRequest(number: 7, title: "Feature", url: "https://github.com/octocat/project/pull/7", headRefName: "feature", baseRefName: "main", headRefOid: sha, isDraft: false, mergeStateStatus: "CLEAN", state: "OPEN")
        try await service.mergePullRequest(root: root.path, request: request)
        let commands = await fake.commands
        let merge = try XCTUnwrap(commands.first { $0.arguments.starts(with: ["pr", "merge"]) })
        XCTAssertEqual(merge.arguments, ["pr", "merge", "7", "--repo", "octocat/project", "--merge", "--match-head-commit", sha])
        XCTAssertFalse(merge.arguments.contains("--admin"))
        let wrong = GitHubPullRequest(number: 7, title: "Wrong", url: "https://github.com/other/repo/pull/7", headRefName: "feature", baseRefName: "main", headRefOid: sha, isDraft: false, mergeStateStatus: "CLEAN", state: "OPEN")
        do { try await service.mergePullRequest(root: root.path, request: wrong); XCTFail("Merged a stale repository's request") } catch { }
        let after = await fake.commands
        XCTAssertEqual(after.filter { $0.arguments.starts(with: ["pr", "merge"]) }.count, 1)
    }

    func testReviewedCommitGuardsRejectExternalChangesAndPushExactSHA() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("gh")
        try Data().write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let fake = GitHubFixtureRunner(root: root.path, remote: "https://github.com/octocat/project.git")
        let service = GitHubService(runner: fake, configuredCLIPath: executable.path)
        let original = try await service.snapshot(root: root.path)
        let expected = GitOperationExpectation(original)
        await fake.setHead(String(repeating: "b", count: 40))
        do { try await service.push(root: root.path, expected: expected); XCTFail("Pushed an unreviewed commit") } catch { }
        do { try await service.pull(root: root.path, expected: expected); XCTFail("Pulled into an unreviewed commit") } catch { }
        do {
            try await service.createPullRequest(root: root.path, title: "Review", body: "Body", base: "main", draft: true, expected: expected)
            XCTFail("Created a PR from an unreviewed checkout")
        } catch { }
        do {
            try await service.mergeBranch(root: root.path, name: "feature", expected: expected, expectedSourceSHA: String(repeating: "c", count: 40))
            XCTFail("Merged into an unreviewed checkout")
        } catch { }
        let rejected = await fake.commands
        XCTAssertFalse(rejected.contains { $0.arguments.contains("push") || $0.arguments.contains("pull") || $0.arguments.contains("merge") || $0.arguments.starts(with: ["pr", "create"]) })

        let reviewedSHA = try XCTUnwrap(original.headSHA)
        await fake.setHead(reviewedSHA)
        try await service.push(root: root.path, expected: expected)
        let commands = await fake.commands
        let push = try XCTUnwrap(commands.first { $0.arguments.contains("push") })
        XCTAssertEqual(Array(push.arguments.suffix(3)), ["push", "https://github.com/octocat/project.git", "\(reviewedSHA):refs/heads/main"])
        XCTAssertFalse(push.arguments.contains(where: { $0.hasPrefix("HEAD:") || $0.contains("force") }))
        XCTAssertTrue(commands.contains { $0.arguments.suffix(4) == ["update-ref", "refs/remotes/origin/main", reviewedSHA, reviewedSHA] })
        XCTAssertTrue(commands.contains { $0.arguments.contains("--set-upstream-to=origin/main") && $0.arguments.last == "main" })
    }

    func testPushRejectsDifferentAndMultipleDestinationsBeforeUploading() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let remote = "https://github.com/octocat/project.git"
        for destinations in [["https://github.com/other/private.git"], [remote, "https://github.com/other/private.git"]] {
            let fake = GitHubFixtureRunner(root: root.path, remote: remote, pushRemotes: destinations)
            let service = GitHubService(runner: fake)
            let state = try await service.snapshot(root: root.path)
            do { try await service.push(root: root.path, expected: GitOperationExpectation(state)); XCTFail("Uploaded to an unreviewed destination") } catch { }
            let commands = await fake.commands
            XCTAssertFalse(commands.contains { $0.arguments.contains("push") })
        }
    }

    func testPullRequestUsesOriginBranchAndChecksItsLiveReviewedCommit() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("gh")
        try Data().write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let fake = GitHubFixtureRunner(root: root.path, remote: "https://github.com/octocat/project.git")
        let service = GitHubService(runner: fake, configuredCLIPath: executable.path)

        await fake.setUpstream("other/published-feature")
        var state = try await service.snapshot(root: root.path)
        do {
            try await service.createPullRequest(root: root.path, title: "Review", body: "Body", base: "main", draft: true, expected: GitOperationExpectation(state))
            XCTFail("Created a pull request from another remote")
        } catch { }

        await fake.setUpstream("origin/published/feature")
        await fake.setRemoteHead(String(repeating: "b", count: 40))
        state = try await service.snapshot(root: root.path)
        do {
            try await service.createPullRequest(root: root.path, title: "Review", body: "Body", base: "main", draft: true, expected: GitOperationExpectation(state))
            XCTFail("Created a pull request from unreviewed remote contents")
        } catch { }
        let rejected = await fake.commands
        XCTAssertFalse(rejected.contains { $0.arguments.starts(with: ["pr", "create"]) })

        await fake.setRemoteHead(try XCTUnwrap(state.headSHA))
        try await service.createPullRequest(root: root.path, title: "Review", body: "Body", base: "main", draft: true, expected: GitOperationExpectation(state))
        let commands = await fake.commands
        XCTAssertTrue(commands.contains { $0.arguments.contains("repos/octocat/project/branches/published%2Ffeature") })
        let create = try XCTUnwrap(commands.first { $0.arguments.starts(with: ["pr", "create"]) })
        let headIndex = try XCTUnwrap(create.arguments.firstIndex(of: "--head"))
        XCTAssertEqual(create.arguments[headIndex + 1], "published/feature")
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("GitHubTests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.resolvingSymlinksInPath()
    }

    private func initialize(_ root: URL) async throws {
        for arguments in [["init", "-q", "--initial-branch=main"], ["config", "user.name", "Test User"], ["config", "user.email", "test@example.invalid"]] {
            let result = try await GitCommandRunner().run(GitCommand(executable: "/usr/bin/git", arguments: ["-C", root.path] + arguments), progress: nil)
            XCTAssertEqual(result.status, 0, String(decoding: result.stderr, as: UTF8.self))
        }
    }
}

actor GitHubFixtureRunner: GitCommandRunning {
    private(set) var commands: [GitCommand] = []
    let root: String
    let remote: String?
    let pushRemotes: [String]?
    private var head = String(repeating: "a", count: 40)
    private var upstream: String?
    private var remoteHead = String(repeating: "a", count: 40)
    init(root: String, remote: String? = nil, pushRemotes: [String]? = nil) {
        self.root = root; self.remote = remote; self.pushRemotes = pushRemotes
    }
    func setHead(_ value: String) { head = value }
    func setUpstream(_ value: String) { upstream = value }
    func setRemoteHead(_ value: String) { remoteHead = value }

    func run(_ command: GitCommand, progress: (@Sendable (String) -> Void)?) async throws -> GitCommandResult {
        commands.append(command)
        let args = command.arguments
        var output = "", status: Int32 = 0
        if args == ["--version"] { output = "gh version 2.88.0\n" }
        else if args.starts(with: ["auth", "status"]) { output = "Logged in to github.com account octocat (keyring)\n" }
        else if args.contains(".login") { output = "octocat\n" }
        else if args.contains(".commit.sha") { output = remoteHead + "\n" }
        else if args.contains(where: { $0.hasPrefix("user/repos?") }) {
            output = """
            [{"id":1,"name":"project","full_name":"octocat/project","private":true,"html_url":"https://github.com/octocat/project","clone_url":"https://github.com/octocat/project.git","default_branch":"main","description":null}]
            """
        } else if args.contains("--show-toplevel") { output = root + "\n" }
        else if args.contains("symbolic-ref") { output = "main\n" }
        else if args.contains("MERGE_HEAD") { status = 1 }
        else if args.contains("@{upstream}") { if let upstream { output = upstream + "\n" } else { status = 1 } }
        else if args.contains("HEAD...@{upstream}") { output = "0\t0\n" }
        else if args.contains("get-url") && args.contains("--push"), let pushRemotes { output = pushRemotes.joined(separator: "\n") + "\n" }
        else if args.contains("get-url") { if let remote { output = remote + "\n" } else { status = 2 } }
        else if args.contains("--verify") { output = head + "\n" }
        else if args.contains("status") { output = "## main\0" }
        return GitCommandResult(status: status, stdout: Data(output.utf8), stderr: Data())
    }
}
