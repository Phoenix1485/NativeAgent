import Foundation
import XCTest
@testable import NativeAgent

@MainActor
final class GitHubControllerTests: XCTestCase {
    func testProjectSwitchDropsDelayedOldRepositoryState() async throws {
        let fixture = try makeFixture()
        defer { fixture.clean() }
        await fixture.runner.setDelay(root: fixture.old.path)
        let controller = GitHubController(service: fixture.service, preferences: fixture.defaults)
        let old = Task { await controller.setProject(root: fixture.old.path) }
        try await Task.sleep(for: .milliseconds(20))
        await controller.setProject(root: fixture.new.path)
        await old.value
        XCTAssertEqual(controller.snapshot?.root, fixture.new.path)
        XCTAssertEqual(controller.snapshot?.branch, "new")
        XCTAssertFalse(controller.busy)
        XCTAssertNil(controller.error)
        await controller.shutdown()
    }

    func testOfflineGitHubKeepsLocalSnapshotAndFailedCompareClearsOldDiff() async throws {
        let fixture = try makeFixture()
        defer { fixture.clean() }
        await fixture.runner.setOffline(true)
        let controller = GitHubController(service: fixture.service, preferences: fixture.defaults)
        await controller.refreshAuth()
        XCTAssertTrue(controller.auth.isAuthenticated)
        await controller.setProject(root: fixture.new.path)
        XCTAssertEqual(controller.snapshot?.branch, "new")
        XCTAssertFalse(controller.commits.isEmpty)
        XCTAssertEqual(controller.githubError, "GitHub is offline")
        XCTAssertNil(controller.error)
        await controller.compare(.working())
        XCTAssertTrue(controller.diff.contains("+new"))
        await fixture.runner.setFailDiff(true)
        await controller.compare(.staged())
        XCTAssertEqual(controller.diff, "")
        XCTAssertNotNil(controller.error)
        await controller.shutdown()
    }

    func testShutdownWaitsForCanceledWorkAndDoesNotStartNewRefresh() async throws {
        let fixture = try makeFixture()
        defer { fixture.clean() }
        let controller = GitHubController(service: fixture.service, preferences: fixture.defaults)
        await controller.setProject(root: fixture.new.path)
        await fixture.runner.setSlowDiff(true)
        let comparison = Task { await controller.compare(.working()) }
        for _ in 0..<100 {
            if await fixture.runner.diffRunning { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        await controller.shutdown()
        await comparison.value
        XCTAssertFalse(controller.busy)
        let running = await fixture.runner.diffRunning
        XCTAssertFalse(running)
        XCTAssertTrue(controller.error?.hasPrefix("Canceled.") == true)
        let count = await fixture.runner.commandCount
        await controller.refresh()
        let after = await fixture.runner.commandCount
        XCTAssertEqual(count, after)
    }

    func testBusyComparisonsPreserveTheDisplayedDiff() async throws {
        let fixture = try makeFixture()
        defer { fixture.clean() }
        let controller = GitHubController(service: fixture.service, preferences: fixture.defaults)
        await controller.setProject(root: fixture.new.path)
        await controller.compare(.working())
        let displayed = controller.diff, selection = controller.compareSelection
        XCTAssertFalse(displayed.isEmpty)

        await fixture.runner.setDelay(root: fixture.new.path)
        let refresh = Task { await controller.refresh() }
        for _ in 0..<100 {
            if controller.busy { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(controller.busy)
        await controller.compare(.staged())
        let request = GitHubPullRequest(number: 1, title: "Other diff", url: "https://github.com/octocat/project/pull/1",
            headRefName: "feature", baseRefName: "main", headRefOid: String(repeating: "a", count: 40), isDraft: false, mergeStateStatus: "CLEAN", state: "OPEN")
        await controller.loadPullRequestDiff(request)
        XCTAssertEqual(controller.diff, displayed)
        XCTAssertEqual(controller.compareSelection, selection)
        controller.cancel()
        await refresh.value
        await controller.shutdown()
    }

    func testDeviceLoginOpensOfficialPageWithoutLeakingTokenOutput() async throws {
        let fixture = try makeFixture()
        defer { fixture.clean() }
        var opened: [URL] = []
        let controller = GitHubController(service: fixture.service, preferences: fixture.defaults, openURL: { opened.append($0) })
        await controller.login()
        XCTAssertTrue(controller.auth.isAuthenticated)
        XCTAssertEqual(opened.map(\.absoluteString), ["https://github.com/login/device"])
        XCTAssertFalse(controller.loginOutput.contains("ghp_"))
        await controller.shutdown()
    }

    func testRepositoryChangedCallbackRunsAfterSuccessfulAndFailedMutations() async throws {
        let fixture = try makeFixture()
        defer { fixture.clean() }
        let controller = GitHubController(service: fixture.service, preferences: fixture.defaults)
        await controller.setProject(root: fixture.new.path)
        var notifications = 0
        controller.onRepositoryChanged = { notifications += 1 }
        await controller.stage(paths: ["file.swift"])
        XCTAssertEqual(notifications, 1)
        await controller.stage(paths: ["../outside.swift"])
        XCTAssertEqual(notifications, 2)
        XCTAssertNotNil(controller.error)
        await controller.shutdown()
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("GitHubControllerTests-\(UUID())").resolvingSymlinksInPath()
        let old = root.appendingPathComponent("old"), new = root.appendingPathComponent("new")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: new, withIntermediateDirectories: true)
        let gh = root.appendingPathComponent("gh")
        try Data().write(to: gh)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: gh.path)
        let suite = "GitHubControllerTests.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        let runner = GitHubControllerFixtureRunner()
        return Fixture(root: root, old: old, new: new, suite: suite, defaults: defaults, runner: runner,
            service: GitHubService(runner: runner, configuredCLIPath: gh.path))
    }

    private struct Fixture {
        let root: URL, old: URL, new: URL
        let suite: String
        let defaults: UserDefaults
        let runner: GitHubControllerFixtureRunner
        let service: GitHubService
        func clean() { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
    }
}

private actor GitHubControllerFixtureRunner: GitCommandRunning {
    private var delayedRoot: String?, offline = false, failDiff = false, slowDiff = false
    private(set) var diffRunning = false
    private(set) var commandCount = 0
    func setDelay(root: String) { delayedRoot = root }
    func setOffline(_ value: Bool) { offline = value }
    func setFailDiff(_ value: Bool) { failDiff = value }
    func setSlowDiff(_ value: Bool) { slowDiff = value }

    func run(_ command: GitCommand, progress: (@Sendable (String) -> Void)?) async throws -> GitCommandResult {
        commandCount += 1
        if command.directory == delayedRoot { try? await Task.sleep(for: .milliseconds(150)) }
        let args = command.arguments
        let sha = String(repeating: "a", count: 40)
        var output = "", failure = "", status: Int32 = 0
        if args == ["--version"] { output = "gh version 2.88.0\n" }
        else if args.starts(with: ["auth", "status"]) { output = "account octocat (keyring)\n" }
        else if args.starts(with: ["auth", "login"]) {
            progress?("! First copy your one-time code: ABCD-1234")
            progress?("Token: ghp_shouldneverreachtheUI")
            progress?("Open this URL to continue in your web browser: https://github.com/login/device")
            try await Task.sleep(for: .milliseconds(20))
        } else if args.contains(".login") { output = "octocat\n" }
        else if args.contains(where: { $0.hasPrefix("user/repos?") }) { output = "[]" }
        else if args.starts(with: ["pr", "list"]) {
            if offline { status = 1; failure = "GitHub is offline" } else { output = "[]" }
        } else if args.contains("--show-toplevel") { output = (command.directory ?? "") + "\n" }
        else if args.contains("symbolic-ref") { output = URL(fileURLWithPath: command.directory ?? "/").lastPathComponent + "\n" }
        else if args.contains("MERGE_HEAD") || args.contains("@{upstream}") { status = 1 }
        else if args.contains("get-url") { output = "https://github.com/octocat/project.git\n" }
        else if args.contains("--verify") { output = sha + "\n" }
        else if args.contains("status") { output = "## main\0" }
        else if args.contains("log") { output = "\(sha)\0Commit subject\0Author\02026-01-01T12:00:00Z\0" }
        else if args.contains("diff") {
            if slowDiff {
                diffRunning = true
                defer { diffRunning = false }
                // Deliberately return after cancellation; service/controller must
                // reject a result from an operation the user canceled.
                try? await Task.sleep(for: .seconds(5))
            }
            if failDiff { status = 1; failure = "Comparison unavailable" } else { output = "@@ -1 +1 @@\n-old\n+new\n" }
        }
        return GitCommandResult(status: status, stdout: Data(output.utf8), stderr: Data(failure.utf8))
    }
}
