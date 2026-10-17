import Foundation

/// The checker deliberately has no Codex executable path or install operation.
enum CheckedCLI: String, Codable, CaseIterable, Identifiable, Sendable {
    case claude, grok
    var id: String { rawValue }
    var provider: ProviderKind { self == .claude ? .claude : .grok }
    var title: String { self == .claude ? "Claude Code" : "Grok Build" }
    var package: String { self == .claude ? "@anthropic-ai/claude-code" : "@xai-official/grok" }
    var releaseURL: URL { URL(string: self == .claude ? "https://downloads.claude.ai/claude-code-releases/latest" : "https://x.ai/cli/stable")! }
    var channel: String { self == .claude ? "Latest release" : "Latest stable release" }
}

struct RuntimeReleaseVersion: Equatable, Comparable, Sendable {
    let numbers: [Int]
    let prerelease: [String]
    init?(_ raw: String) {
        guard raw.utf8.count <= 100, raw.range(of: #"^[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z]+(?:[.-][0-9A-Za-z]+)*)?(?:\+[0-9A-Za-z.-]+)?$"#, options: .regularExpression) != nil else { return nil }
        let parts = raw.split(separator: "+", maxSplits: 1)[0].split(separator: "-", maxSplits: 1)
        let components = parts[0].split(separator: ".").compactMap { Int($0) }
        guard components.count == 3 else { return nil }
        numbers = components
        prerelease = parts.count > 1 ? parts[1].split(separator: ".").map(String.init) : []
    }
    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.numbers != rhs.numbers { return lhs.numbers.lexicographicallyPrecedes(rhs.numbers) }
        if lhs.prerelease.isEmpty || rhs.prerelease.isEmpty { return !lhs.prerelease.isEmpty && rhs.prerelease.isEmpty }
        for (left, right) in zip(lhs.prerelease, rhs.prerelease) where left != right {
            if let l = Int(left), let r = Int(right) { return l < r }
            if Int(left) != nil { return true }
            if Int(right) != nil { return false }
            return left < right
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }
    static func fromOutput(_ output: String) -> String? {
        guard output.utf8.count <= 4_096,
              let range = output.range(of: #"\b[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z]+(?:[.-][0-9A-Za-z]+)*)?(?:\+[0-9A-Za-z.-]+)?\b"#, options: .regularExpression) else { return nil }
        let value = String(output[range])
        return Self(value) == nil ? nil : value
    }
}

struct CLIUpdateResult: Codable, Equatable, Identifiable, Sendable {
    let cli: CheckedCLI
    var id: String { cli.id }
    var path: String?
    var installed: String?
    var latest: String?
    var issue: String?
    var checkedAt: Date
    var updateAvailable: Bool {
        guard let installed, let latest, let current = RuntimeReleaseVersion(installed), let release = RuntimeReleaseVersion(latest) else { return false }
        return current < release
    }
    var status: String {
        if path == nil { return "Not installed or not configured" }
        if updateAvailable { return "Update available" }
        if issue != nil { return "Check needs attention" }
        if installed != nil && latest != nil { return "No newer release on this channel" }
        return "Version could not be verified"
    }
}

struct ProviderUpdateService: Sendable {
    var fetch: @Sendable (URL) async throws -> Data = { try await Self.fetchRelease($0) }
    var probe: @Sendable (CheckedCLI, String) async throws -> String = { try await Self.probeVersion($0, path: $1) }

    func check(_ cli: CheckedCLI, path: String?, at date: Date) async throws -> CLIUpdateResult {
        var result = CLIUpdateResult(cli: cli, path: path, checkedAt: date)
        guard let path else { return result }
        try Task.checkCancellation()
        do {
            if let metadata = try Self.installedMetadata(cli, path: path) { result.installed = metadata }
            else { result.installed = try await probe(cli, path) }
            guard result.installed.flatMap(RuntimeReleaseVersion.init) != nil else { throw NativeAgentError.unsupported("The installed version could not be read.") }
        } catch is CancellationError { throw CancellationError() }
        catch { result.issue = "Installed version: " + error.localizedDescription }
        try Task.checkCancellation()
        do {
            let data = try await fetch(cli.releaseURL)
            guard data.count <= 4_096, let text = String(data: data, encoding: .utf8) else { throw NativeAgentError.unsupported("Invalid release metadata.") }
            let version = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard RuntimeReleaseVersion(version) != nil else { throw NativeAgentError.unsupported("The release source returned an unrecognized version.") }
            result.latest = version
        } catch is CancellationError { throw CancellationError() }
        catch {
            let message: String
            switch (error as? URLError)?.code {
            case .notConnectedToInternet, .networkConnectionLost: message = "No internet connection. Check again when online."
            case .timedOut: message = "The release source took too long to respond. Try again."
            case .cannotFindHost, .cannotConnectToHost: message = "Could not reach the release source. Try again later."
            default: message = error.localizedDescription
            }
            result.issue = [result.issue, "Release check: " + message].compactMap { $0 }.joined(separator: "\n")
        }
        return result
    }

    /// Read known installation metadata first. Unknown formats use a bounded version-only probe.
    static func installedMetadata(_ cli: CheckedCLI, path: String) throws -> String? {
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        if cli == .claude, resolved.deletingLastPathComponent().lastPathComponent == "versions",
           RuntimeReleaseVersion(resolved.lastPathComponent) != nil { return resolved.lastPathComponent }
        var directory = resolved.deletingLastPathComponent()
        for _ in 0..<5 {
            let manifest = directory.appendingPathComponent("package.json")
            if let info = try? manifest.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), info.isRegularFile == true, (info.fileSize ?? Int.max) <= 262_144,
               let data = try? Data(contentsOf: manifest), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               json["name"] as? String == cli.package, let version = json["version"] as? String, RuntimeReleaseVersion(version) != nil { return version }
            let parent = directory.deletingLastPathComponent()
            if parent == directory { break }; directory = parent
        }
        return nil
    }

    static func fetchRelease(_ url: URL) async throws -> Data {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15; configuration.timeoutIntervalForResource = 20
        configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("NativeAgent-UpdateCheck", forHTTPHeaderField: "User-Agent")
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200, response.url?.scheme == "https" else {
            throw NativeAgentError.unsupported("The release source is unavailable. Try again later.")
        }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < 4_096 else { throw NativeAgentError.unsupported("Release metadata exceeded its size limit.") }
            data.append(byte)
        }
        return data
    }

    static func probeVersion(_ cli: CheckedCLI, path: String) async throws -> String {
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        guard !resolved.lastPathComponent.lowercased().contains("codex"), !URL(fileURLWithPath: path).lastPathComponent.lowercased().contains("codex"),
              FileManager.default.isExecutableFile(atPath: path) else { throw NativeAgentError.unsupported("Choose a working \(cli.title) executable in Configuration.") }
        let command = ProviderCommand()
        var environment = ProviderExecutable.environment(kind: cli.provider, key: nil)
        environment["DISABLE_AUTOUPDATER"] = "1"
        environment["DISABLE_UPDATES"] = "1"
        let arguments = cli == .grok ? ["--no-auto-update", "--version"] : ["--version"]
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let result = try await command.run(path: path, arguments: arguments, environment: environment, timeout: .seconds(10), workingDirectory: FileManager.default.temporaryDirectory)
            try Task.checkCancellation()
            guard result.code == 0, let version = RuntimeReleaseVersion.fromOutput(String(decoding: result.output, as: UTF8.self)) else {
                throw NativeAgentError.unsupported("The version-only check failed. Repair the CLI or select its executable in Configuration.")
            }
            return version
        } onCancel: { Task { await command.cancel() } }
    }
}

enum HalfHourUpdateSchedule {
    static func next(after date: Date, calendar: Calendar = .autoupdatingCurrent) -> Date {
        [0, 30].compactMap { calendar.nextDate(after: date, matching: DateComponents(minute: $0, second: 0), matchingPolicy: .nextTime, repeatedTimePolicy: .first) }.min()!
    }
    static func latest(at date: Date, calendar: Calendar = .autoupdatingCurrent) -> Date {
        [0, 30].compactMap { calendar.nextDate(after: date.addingTimeInterval(0.001), matching: DateComponents(minute: $0, second: 0), matchingPolicy: .nextTime, repeatedTimePolicy: .last, direction: .backward) }.max()!
    }
}
