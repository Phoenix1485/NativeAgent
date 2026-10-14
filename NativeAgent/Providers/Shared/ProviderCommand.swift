import Foundation

/// Runs only after an explicit connection/sign-in action. Never invokes a shell.
actor ProviderCommand {
    private let transport = ProcessTransport()
    private var running = false
    private var cancelled = false
    private var timedOut = false

    func run(path: String, arguments: [String], environment: [String: String], timeout: Duration = .seconds(180), workingDirectory: URL? = nil) async throws -> (code: Int32, output: Data) {
        guard !running else { throw NativeAgentError.alreadyRunning }
        running = true
        cancelled = false; timedOut = false
        defer { running = false }
        let output = try await transport.start(binary: URL(fileURLWithPath: path), arguments: arguments, workingDirectory: workingDirectory, environment: environment)
        await transport.closeInput()
        let stdout = Task { () -> Data in
            var result = Data()
            for await data in output.stdout { if result.count < 1_048_576 { result.append(data.prefix(1_048_576 - result.count)) } }
            return result
        }
        // Login output can include sensitive URLs. Drain stderr, but never log it.
        let stderr = Task { for await _ in output.stderr {} }
        let timer = Task {
            do { try await Task.sleep(for: timeout); timedOut = true; await transport.stop() } catch {}
        }
        var code: Int32 = -1
        for await status in output.termination { code = status }
        timer.cancel()
        let data = await stdout.value
        await stderr.value
        if cancelled { throw CancellationError() }
        if timedOut { throw NativeAgentError.requestTimedOut }
        return (code, data)
    }
    func cancel() async { cancelled = true; await transport.stop() }
}
