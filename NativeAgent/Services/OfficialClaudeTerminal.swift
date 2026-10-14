import AppKit
import Foundation
import Darwin

/// A short-lived native mode of this same executable hands stdin/out directly to
/// the unmodified Claude program in Terminal.app. No tokens enter a shell script.
struct ClaudeTerminalJob: Codable, Sendable {
    enum Action: String, Codable { case login, session }
    var action: Action
    var executable: String
    var configurationDirectory: String
    var method: AuthenticationMethod
    var workingDirectory: String?
    var model: String?
    var readOnly: Bool = false

    var arguments: [String] {
        if action == .login { return ["auth", "login"] }
        var args: [String] = []
        if let model { args += ["--model", model] }
        // Terminal owns permissions, /resume, /model and Ctrl-C. Plan mode is a
        // starting preference, not NativeAgent's enforced filesystem sandbox.
        if readOnly { args += ["--permission-mode", "plan"] }
        return args
    }
}

actor OfficialClaudeTerminal {
    private var pending: URL?

    func login(path: String) async throws {
        let directory = try await launch(.init(action: .login, executable: path,
            configurationDirectory: ProviderExecutable.profileDescription(.claude), method: .account))
        pending = directory
        defer { pending = nil; try? FileManager.default.removeItem(at: directory) }
        for _ in 0..<600 {
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent("cancel").path) { throw CancellationError() }
            if let data = try? Data(contentsOf: directory.appendingPathComponent("result")), let code = Int32(String(decoding: data, as: UTF8.self)) {
                guard code == 0 else { throw NativeAgentError.providerUnavailable("Claude Code sign-in did not complete. Close its Terminal window and try again.") }
                return
            }
            try await Task.sleep(for: .seconds(1))
        }
        try? Data().write(to: directory.appendingPathComponent("cancel"))
        throw NativeAgentError.providerUnavailable("Claude Code sign-in timed out. Close its Terminal window and reconnect to check the account.")
    }

    func cancel() {
        if let pending { try? Data().write(to: pending.appendingPathComponent("cancel")) }
    }

    func openSession(path: String, method: AuthenticationMethod, folder: String, model: String?, readOnly: Bool) async throws {
        let directory = try await launch(.init(action: .session, executable: path,
            configurationDirectory: ProviderExecutable.profileDescription(.claude), method: method,
            workingDirectory: folder, model: model, readOnly: readOnly))
        // The helper removes session artifacts after Terminal's process exits.
        _ = directory
    }

    static func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    private func launch(_ job: ClaudeTerminalJob) async throws -> URL {
        guard let executable = Bundle.main.executableURL else { throw NativeAgentError.providerUnavailable("Cannot locate NativeAgent’s terminal launcher.") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("NativeAgent-terminal-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            try JSONEncoder().encode(job).write(to: directory.appendingPathComponent("job.json"), options: .atomic)
            let script = directory.appendingPathComponent("Claude Code.command")
            // zsh -f avoids user shell startup hooks. Only escaped paths appear here.
            let source = "#!/bin/zsh -f\nexec " + Self.shellQuote(executable.path) + " --official-claude-terminal " + Self.shellQuote(directory.path) + "\n"
            try Data(source.utf8).write(to: script, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
            // Cancellation can arrive while Launch Services is opening Terminal.
            // Publish the pending directory before suspending so the helper sees it.
            if job.action == .login { pending = directory }
            try await Self.openInTerminal(script)
            return directory
        } catch {
            if pending == directory { pending = nil }
            try? FileManager.default.removeItem(at: directory); throw error
        }
    }

    @MainActor private static func openInTerminal(_ script: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NSWorkspace.shared.open([script], withApplicationAt: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"), configuration: .init()) { _, error in
                if error != nil { continuation.resume(throwing: NativeAgentError.providerUnavailable("macOS could not open the official Claude Code session in Terminal.")) }
                else { continuation.resume() }
            }
        }
    }

    /// Runs in Terminal as a separate invocation, never in the GUI's main actor.
    static func runHelper(directory: URL) async -> Int32 {
        guard directory.lastPathComponent.hasPrefix("NativeAgent-terminal-"),
              directory.deletingLastPathComponent().standardizedFileURL == FileManager.default.temporaryDirectory.standardizedFileURL,
              let data = try? Data(contentsOf: directory.appendingPathComponent("job.json")), data.count < 65_536,
              let job = try? JSONDecoder().decode(ClaudeTerminalJob.self, from: data) else { return 1 }
        defer {
            if job.action == .session { try? FileManager.default.removeItem(at: directory) }
        }
        let cancelURL = directory.appendingPathComponent("cancel")
        guard !FileManager.default.fileExists(atPath: cancelURL.path) else { return 1 }
        let status: Int32
        do {
            let key = job.method == .apiKey ? try KeychainCredentialStore().read(.claude) : nil
            if job.method == .apiKey && key == nil { throw NativeAgentError.providerUnavailable("The saved Claude API key is missing. Reconnect in NativeAgent.") }
            var environment = ProviderExecutable.environment(kind: .claude, key: key)
            environment["CLAUDE_CONFIG_DIR"] = job.configurationDirectory
            if job.action == .session {
                let check = try await ProviderCommand().run(path: job.executable, arguments: ["auth", "status"], environment: environment, timeout: .seconds(20), workingDirectory: job.workingDirectory.map(URL.init(fileURLWithPath:)))
                guard try ClaudeProvider.validatedAccount(check.output, exitCode: check.code, method: job.method) != nil else {
                    throw NativeAgentError.providerUnavailable("Claude Code’s current authentication does not match the selected billing mode. Reconnect in NativeAgent.")
                }
            }
            print(job.action == .login ? "Complete sign-in through the official Claude Code flow. NativeAgent is waiting for confirmation." : "Official Claude Code session · permissions, /model, /resume and Ctrl-C are handled here.\nNativeAgent does not capture this terminal conversation. Billing mode: \(job.method == .account ? "Claude subscription" : "Separate API billing").")
            let child = Process()
            child.executableURL = URL(fileURLWithPath: job.executable)
            child.arguments = job.arguments
            child.environment = environment
            child.currentDirectoryURL = job.workingDirectory.map(URL.init(fileURLWithPath:))
            child.standardInput = FileHandle.standardInput
            child.standardOutput = FileHandle.standardOutput
            child.standardError = FileHandle.standardError
            try child.run()
            while child.isRunning {
                if !FileManager.default.fileExists(atPath: directory.path) || FileManager.default.fileExists(atPath: cancelURL.path) {
                    child.terminate()
                    try? await Task.sleep(for: .seconds(2))
                    if child.isRunning { kill(child.processIdentifier, SIGKILL) }
                    break
                }
                try await Task.sleep(for: .milliseconds(250))
            }
            child.waitUntilExit()
            status = child.terminationStatus
        } catch {
            // Deliberately excludes CLI output, login URLs and environment values.
            print("NativeAgent: \(error.localizedDescription)")
            status = 1
        }
        if job.action == .login { try? Data(String(status).utf8).write(to: directory.appendingPathComponent("result"), options: .atomic) }
        return status
    }
}
