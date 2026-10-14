import Foundation
import Darwin

actor ProcessTransport {
    struct Output: Sendable {
        let stdout: AsyncStream<Data>
        let stderr: AsyncStream<Data>
        let termination: AsyncStream<Int32>
    }

    private var process: Process?
    private var input: FileHandle?
    private var stdoutContinuation: AsyncStream<Data>.Continuation?
    private var stderrContinuation: AsyncStream<Data>.Continuation?
    private var terminationContinuation: AsyncStream<Int32>.Continuation?
    private var generation = UUID()

    func start(binary: URL, arguments: [String], workingDirectory: URL?, environment: [String: String]? = nil) throws -> Output {
        guard process == nil else { throw NativeAgentError.alreadyRunning }

        let standardInput = Pipe()
        let standardOutput = Pipe()
        let standardError = Pipe()
        let child = Process()
        child.executableURL = binary
        child.arguments = arguments
        child.currentDirectoryURL = workingDirectory
        if let environment { child.environment = environment }
        child.standardInput = standardInput
        child.standardOutput = standardOutput
        child.standardError = standardError

        // Each chunk is at most 64 KiB. Overflow terminates the protocol rather
        // than silently dropping part of a JSON frame or growing without bound.
        let stdout = AsyncStream<Data>(bufferingPolicy: .bufferingOldest(128)) { self.stdoutContinuation = $0 }
        let stderr = AsyncStream<Data>(bufferingPolicy: .bufferingOldest(32)) { self.stderrContinuation = $0 }
        let termination = AsyncStream<Int32> { self.terminationContinuation = $0 }

        let token = UUID(); generation = token
        let drains = DispatchGroup()
        let stdoutSink = stdoutContinuation!, stderrSink = stderrContinuation!
        let terminateSink = terminationContinuation!
        child.terminationHandler = { [weak self] process in
            // A fast-exiting login/status command may still have unread output.
            // Finish only after BOTH pipes have drained, preserving chunk order.
            drains.notify(queue: .global()) {
                Task {
                    await self?.didTerminate(generation: token)
                    terminateSink.yield(process.terminationStatus)
                    terminateSink.finish()
                }
            }
        }
        drains.enter(); drains.enter()
        do { try child.run() } catch {
            drains.leave(); drains.leave()
            stdoutSink.finish(); stderrSink.finish(); terminateSink.finish()
            throw error
        }
        Self.drain(standardOutput.fileHandleForReading, into: stdoutSink, group: drains, process: child)
        Self.drain(standardError.fileHandleForReading, into: stderrSink, group: drains, process: child)
        process = child
        input = standardInput.fileHandleForWriting
        return Output(stdout: stdout, stderr: stderr, termination: termination)
    }

    func write(_ data: Data) throws {
        guard let input else { throw NativeAgentError.providerUnavailable("Provider is not connected.") }
        try input.write(contentsOf: data)
    }

    func interrupt() {
        guard let process, process.isRunning else { return }
        process.interrupt()
    }

    func closeInput() {
        try? input?.close()
        input = nil
    }

    func stop() {
        guard let process else { return }
        Self.terminate(process)
        stdoutContinuation?.finish()
        stderrContinuation?.finish()
        terminationContinuation?.finish()
        cleanup()
    }

    func isRunning() -> Bool { process?.isRunning == true }

    private nonisolated static func terminate(_ process: Process) {
        if process.isRunning { process.terminate() }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }

    private nonisolated static func drain(_ handle: FileHandle, into sink: AsyncStream<Data>.Continuation, group: DispatchGroup, process: Process) {
        DispatchQueue.global(qos: .utility).async {
            defer { try? handle.close(); sink.finish(); group.leave() }
            do {
                while let data = try handle.read(upToCount: 65_536), !data.isEmpty {
                    switch sink.yield(data) {
                    case .dropped, .terminated: Self.terminate(process); return
                    case .enqueued: break
                    @unknown default: Self.terminate(process); return
                    }
                }
            } catch { }
        }
    }

    private func didTerminate(generation token: UUID) {
        if token == generation { cleanup() }
    }

    private func cleanup() {
        generation = UUID()
        input?.closeFile()
        input = nil
        process = nil
        stdoutContinuation = nil
        stderrContinuation = nil
        terminationContinuation = nil
    }
}
