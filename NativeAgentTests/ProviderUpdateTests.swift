import XCTest
@testable import NativeAgent

private actor UpdateProbe {
    var paths: [String] = []
    func version(_ path: String) async throws -> String { paths.append(path); try await Task.sleep(for: .milliseconds(10)); return "2.1.9" }
}

@MainActor
final class ProviderUpdateTests: XCTestCase {
    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
    private func calendar(_ zone: String) -> Calendar { var value = Calendar(identifier: .gregorian); value.timeZone = TimeZone(identifier: zone)!; return value }
    private func preferences() -> (String, UserDefaults) { let suite = "ProviderUpdates.\(UUID())"; return (suite, UserDefaults(suiteName: suite)!) }

    func testHalfHourBoundariesDoNotDriftAndHandleDSTAndFractionalTimeZones() {
        let utc = calendar("UTC")
        XCTAssertEqual(HalfHourUpdateSchedule.next(after: date("2026-10-17T09:17:05Z"), calendar: utc), date("2026-10-17T09:30:00Z"))
        XCTAssertEqual(HalfHourUpdateSchedule.next(after: date("2026-10-17T09:30:00Z"), calendar: utc), date("2026-10-17T10:00:00Z"))
        XCTAssertEqual(HalfHourUpdateSchedule.next(after: date("2026-10-17T23:59:59Z"), calendar: utc), date("2026-10-18T00:00:00Z"))
        XCTAssertEqual(HalfHourUpdateSchedule.latest(at: date("2026-10-17T09:30:00Z"), calendar: utc), date("2026-10-17T09:30:00Z"))
        XCTAssertEqual(HalfHourUpdateSchedule.next(after: date("2026-10-17T09:17:05Z"), calendar: calendar("Asia/Kathmandu")), date("2026-10-17T09:45:00Z"))
        let la = calendar("America/Los_Angeles")
        XCTAssertEqual(HalfHourUpdateSchedule.next(after: date("2026-03-08T09:45:00Z"), calendar: la), date("2026-03-08T10:00:00Z"))
        XCTAssertEqual(HalfHourUpdateSchedule.next(after: date("2026-11-01T08:45:00Z"), calendar: la), date("2026-11-01T09:00:00Z"))
        XCTAssertEqual(HalfHourUpdateSchedule.next(after: date("2026-11-01T09:05:00Z"), calendar: la), date("2026-11-01T09:30:00Z"))
    }

    func testVersionComparisonAndUntrustedReleaseParsing() async throws {
        XCTAssertLessThan(RuntimeReleaseVersion("2.1.9")!, RuntimeReleaseVersion("2.1.10")!)
        XCTAssertLessThan(RuntimeReleaseVersion("2.1.10-rc.2")!, RuntimeReleaseVersion("2.1.10-rc.10")!)
        XCTAssertLessThan(RuntimeReleaseVersion("2.1.10-rc.10")!, RuntimeReleaseVersion("2.1.10")!)
        XCTAssertEqual(RuntimeReleaseVersion("2.1.10+build1"), RuntimeReleaseVersion("2.1.10+build2"))
        for invalid in ["2.1", "latest", "2.1.10\nrun this", "https://bad.invalid", String(repeating: "9", count: 60) + ".1.1"] { XCTAssertNil(RuntimeReleaseVersion(invalid)) }
        XCTAssertEqual(RuntimeReleaseVersion.fromOutput("Claude Code 2.1.10-beta.2\n"), "2.1.10-beta.2")
        let service = ProviderUpdateService(fetch: { _ in Data("<html>Error 500</html>".utf8) }, probe: { _, _ in "2.1.9" })
        let result = try await service.check(.claude, path: "/fixture/claude", at: .now)
        XCTAssertNotNil(result.issue); XCTAssertNil(result.latest); XCTAssertFalse(result.updateAvailable)
        XCTAssertEqual(result.status, "Check needs attention")
        let absent = try await service.check(.grok, path: nil, at: .now)
        XCTAssertEqual(absent.status, "Not installed or not configured")
    }

    func testMetadataReadsKnownPackagesAndNativeSymlinksWithoutProbing() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("bin"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let manifest = directory.appendingPathComponent("package.json")
        try Data(#"{"name":"@anthropic-ai/claude-code","version":"2.1.9"}"#.utf8).write(to: manifest)
        let binary = directory.appendingPathComponent("bin/claude"); try Data().write(to: binary)
        let service = ProviderUpdateService(fetch: { _ in Data("2.1.10\n".utf8) }, probe: { _, _ in XCTFail("Metadata should avoid a process"); return "0.0.0" })
        let result = try await service.check(.claude, path: binary.path, at: .now)
        XCTAssertEqual(result.installed, "2.1.9"); XCTAssertTrue(result.updateAvailable)
        XCTAssertNil(try ProviderUpdateService.installedMetadata(.grok, path: binary.path))
        let versions = directory.appendingPathComponent("versions"); try FileManager.default.createDirectory(at: versions, withIntermediateDirectories: true)
        let target = versions.appendingPathComponent("2.1.11"); try Data().write(to: target)
        let link = directory.appendingPathComponent("native-claude"); try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertEqual(try ProviderUpdateService.installedMetadata(.claude, path: link.path), "2.1.11")
    }

    func testStartupManualWakeClockChangesAndOptOutCoalesceWithoutDrift() async throws {
        let (suite, defaults) = preferences(); defer { defaults.removePersistentDomain(forName: suite) }
        let probe = UpdateProbe()
        let service = ProviderUpdateService(fetch: { _ in Data("2.1.10".utf8) }, probe: { _, path in try await probe.version(path) })
        var now = date("2026-10-17T09:17:00Z"), modelChecks = 0
        let controller = ProviderUpdateController(defaults: defaults, service: service, now: { now }, paths: { [.claude: "/fixture/claude", .grok: "/fixture/grok"] }, refreshModels: { modelChecks += 1; return .refreshed(4) })
        controller.start(); controller.start(); controller.checkNow(); await controller.waitForCheck()
        XCTAssertEqual(modelChecks, 1); XCTAssertEqual(controller.results.count, 2)
        let boundary = controller.nextCheck
        now = date("2026-10-17T09:24:00Z"); controller.checkNow(); await controller.waitForCheck()
        XCTAssertEqual(modelChecks, 2); XCTAssertEqual(controller.nextCheck, boundary)
        now = date("2026-10-17T09:30:00Z"); controller.scheduledCheck(); controller.clockOrWakeChanged(); await controller.waitForCheck()
        XCTAssertEqual(modelChecks, 3)
        now = date("2026-10-17T12:47:00Z"); controller.clockOrWakeChanged(); controller.clockOrWakeChanged(); await controller.waitForCheck()
        XCTAssertEqual(modelChecks, 4)
        now = date("2026-10-17T08:05:00Z"); controller.clockOrWakeChanged(); await controller.waitForCheck()
        XCTAssertEqual(modelChecks, 5)
        controller.automaticallyChecks = false
        XCTAssertNil(controller.nextCheck)
        now = date("2026-10-17T09:30:00Z"); controller.scheduledCheck(); await controller.waitForCheck(); XCTAssertEqual(modelChecks, 5)
        controller.checkNow(); await controller.waitForCheck(); XCTAssertEqual(modelChecks, 6)
        await controller.shutdown(); controller.checkNow(); XCTAssertFalse(controller.checking)
        let paths = await probe.paths; XCTAssertEqual(paths.count, 12); XCTAssertTrue(paths.allSatisfy { !$0.contains("codex") })
        let restored = ProviderUpdateController(defaults: defaults, service: service, paths: { [:] }, refreshModels: { .refreshed(0) })
        XCTAssertFalse(restored.automaticallyChecks); XCTAssertEqual(restored.results, controller.results); XCTAssertNotNil(restored.lastChecked)
        restored.start(); XCTAssertFalse(restored.checking); await restored.shutdown()
    }

    func testDeferredModelsRetryWithoutRepeatingCLICheckAndShutdownCancels() async throws {
        let (suite, defaults) = preferences(); defer { defaults.removePersistentDomain(forName: suite) }
        let probe = UpdateProbe(); var busy = true
        let service = ProviderUpdateService(fetch: { _ in Data("2.1.10".utf8) }, probe: { _, path in try await probe.version(path) })
        let controller = ProviderUpdateController(defaults: defaults, service: service, paths: { [.claude: "/fixture/claude"] }, refreshModels: { busy ? .deferred : .refreshed(3) })
        controller.checkNow(); await controller.waitForCheck(); XCTAssertEqual(controller.modelMessage, ProviderModelRefresh.deferred.message)
        busy = false; controller.refreshDeferredModels(); await controller.waitForCheck()
        XCTAssertEqual(controller.modelMessage, ProviderModelRefresh.refreshed(3).message)
        let calls = await probe.paths; XCTAssertEqual(calls.count, 1)
        await controller.shutdown()
        let slow = ProviderUpdateService(fetch: { _ in try await Task.sleep(for: .seconds(60)); return Data() }, probe: { _, _ in "1.0.0" })
        let cancelled = ProviderUpdateController(defaults: defaults, service: slow, paths: { [.grok: "/fixture/grok"] }, refreshModels: { XCTFail("Cancelled check must not refresh models"); return .refreshed(0) })
        cancelled.checkNow(); await cancelled.shutdown(); XCTAssertFalse(cancelled.checking)
    }

    func testCodexPathIsRefusedBeforeAnyProcessAndModelRefreshPreservesPreferences() async throws {
        do { _ = try await ProviderUpdateService.probeVersion(.claude, path: "/nonexistent/codex"); XCTFail("Must refuse Codex") } catch {}
        let (suite, defaults) = preferences(); defer { defaults.removePersistentDomain(forName: suite) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = WorkspaceViewModel(provider: SettingsTestProvider(), database: try DatabaseActor(url: directory.appendingPathComponent("test.sqlite3")), files: FileService(), git: GitService(), automaticallyRestore: false, preferences: defaults, credentials: MemoryCredentials(), chatGPTCredentials: MemoryChatGPTCredentials())
        model.connectionStatus = .ready(account: "Fixture")
        model.settings.update(.codex) { $0.defaultModelID = "deep"; $0.disabledModels = ["fast"]; $0.starredModels = ["deep"] }
        model.accountActionInProgress = true
        let deferred = await model.refreshModelsForUpdateCheck(); XCTAssertEqual(deferred, .deferred)
        model.accountActionInProgress = false
        let refreshed = await model.refreshModelsForUpdateCheck(); XCTAssertEqual(refreshed, .refreshed(2))
        XCTAssertEqual(model.settings.profile(.codex).disabledModels, ["fast"])
        XCTAssertEqual(model.settings.profile(.codex).starredModels, ["deep"])
        XCTAssertEqual(model.selectedModelID, "deep")
        model.settings.provider = .claude
        let unavailable = await model.refreshModelsForUpdateCheck()
        guard case .unavailable = unavailable else { return XCTFail("Do not claim a remote catalog for CLI providers") }
        await model.shutdown()
    }
}
