import Darwin
import Foundation

struct GitCommand: Sendable {
    let executable: String
    let arguments: [String]
    var directory: String?
    var timeout: TimeInterval = 60
    var maximumOutput = 8 * 1_024 * 1_024
    var environment: [String: String] = [:]
}

struct GitCommandResult: Sendable {
    let status: Int32
    let stdout: Data
    let stderr: Data
    var text: String { String(decoding: stdout, as: UTF8.self) }
}

protocol GitCommandRunning: Sendable {
    func run(_ command: GitCommand, progress: (@Sendable (String) -> Void)?) async throws -> GitCommandResult
}

/// Uses argument vectors, drains both pipes without blocking, and bounds every
/// process independently of its descendants keeping stdout/stderr open.
struct GitCommandRunner: GitCommandRunning {
    func run(_ command: GitCommand, progress: (@Sendable (String) -> Void)? = nil) async throws -> GitCommandResult {
        let cancellation = GitCommandCancellation()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await Task.detached(priority: .userInitiated) {
                try Self.execute(command, cancellation: cancellation, progress: progress)
            }.value
        } onCancel: {
            cancellation.cancel()
        }
    }

    private static func execute(_ command: GitCommand, cancellation: GitCommandCancellation,
                                progress: (@Sendable (String) -> Void)?) throws -> GitCommandResult {
        let process = Process(), output = Pipe(), errors = Pipe()
        process.executableURL = URL(fileURLWithPath: command.executable)
        process.arguments = command.arguments
        if let directory = command.directory { process.currentDirectoryURL = URL(fileURLWithPath: directory) }
        var environment = ProcessInfo.processInfo.environment
        for key in environment.keys where key.hasPrefix("GIT_") || ["GH_TOKEN", "GITHUB_TOKEN", "GH_ENTERPRISE_TOKEN", "GITHUB_ENTERPRISE_TOKEN", "GH_DEBUG"].contains(key) {
            environment.removeValue(forKey: key)
        }
        environment.merge([
            "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "GIT_TERMINAL_PROMPT": "0", "GIT_PAGER": "cat", "GH_PAGER": "cat",
            "GH_PROMPT_DISABLED": "1", "GH_NO_UPDATE_NOTIFIER": "1", "NO_COLOR": "1", "LC_ALL": "C"
        ]) { _, new in new }
        environment.merge(command.environment) { _, new in new }
        process.environment = environment
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = FileHandle.nullDevice
        guard !cancellation.isCancelled else { throw CancellationError() }
        try process.run()
        let streams = [output.fileHandleForReading, errors.fileHandleForReading]
        for handle in streams {
            let flags = fcntl(handle.fileDescriptor, F_GETFL)
            _ = fcntl(handle.fileDescriptor, F_SETFL, flags | O_NONBLOCK)
        }
        defer { streams.forEach { try? $0.close() } }
        var buffers = [Data(), Data()], lines = [Data(), Data()], ended = [false, false]
        let start = ProcessInfo.processInfo.systemUptime
        var exitedAt: TimeInterval?
        do {
            while true {
                if cancellation.isCancelled { throw CancellationError() }
                let now = ProcessInfo.processInfo.systemUptime
                guard now - start < command.timeout else { throw GitHubOperationError.timedOut }
                for index in streams.indices where !ended[index] {
                    var bytes = [UInt8](repeating: 0, count: 16_384)
                    // Alternate pipes after a bounded read so a noisy stderr cannot
                    // starve stdout, cancellation, or timeout handling.
                    let count = Darwin.read(streams[index].fileDescriptor, &bytes, bytes.count)
                    if count == 0 { ended[index] = true }
                    else if count > 0 {
                        guard buffers[0].count + buffers[1].count + count <= command.maximumOutput else {
                            throw GitHubOperationError.outputLimit
                        }
                        let chunk = Data(bytes.prefix(count))
                        buffers[index].append(chunk)
                        if let progress {
                            lines[index].append(chunk)
                            while let newline = lines[index].firstIndex(of: 10) {
                                progress(String(decoding: lines[index][..<newline], as: UTF8.self))
                                lines[index].removeSubrange(...newline)
                            }
                        }
                    } else if errno != EAGAIN && errno != EINTR {
                        ended[index] = true
                    }
                }
                if !process.isRunning {
                    if ended.allSatisfy({ $0 }) { break }
                    if exitedAt == nil { exitedAt = now }
                    // Descendants must not keep an otherwise finished operation
                    // waiting indefinitely with inherited file descriptors.
                    if now - (exitedAt ?? now) > 1 { break }
                }
                Thread.sleep(forTimeInterval: 0.005)
            }
            for line in lines where !line.isEmpty { progress?(String(decoding: line, as: UTF8.self)) }
            return GitCommandResult(status: process.terminationStatus, stdout: buffers[0], stderr: buffers[1])
        } catch {
            stop(process)
            throw error
        }
    }

    private static func stop(_ process: Process) {
        guard process.isRunning else { return }
        let pid = process.processIdentifier
        // Foundation may launch a separate process group. Signal that group only
        // when it is owned by this child, never the application's own group.
        let target = getpgid(pid) == pid ? -pid : pid
        _ = kill(target, SIGTERM)
        let deadline = ProcessInfo.processInfo.systemUptime + 0.2
        while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline { Thread.sleep(forTimeInterval: 0.01) }
        if process.isRunning { _ = kill(target, SIGKILL) }
    }
}

private final class GitCommandCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
}
