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
    private var writeTail: Task<Void, Error>?

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
        let fd = standardInput.fileHandleForWriting.fileDescriptor
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        _ = fcntl(fd, F_SETNOSIGPIPE, 1)
        return Output(stdout: stdout, stderr: stderr, termination: termination)
    }

    func write(_ data: Data) async throws {
        let previous = writeTail, token = generation
        let task = Task {
            try await previous?.value
            try await writeFrame(data, generation: token)
        }
        writeTail = task
        try await task.value
    }

    private func writeFrame(_ data: Data, generation token: UUID) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        var offset = 0
        while offset < data.count {
            try Task.checkCancellation()
            guard token == generation, let input else { throw NativeAgentError.providerUnavailable("Provider is not connected.") }
            guard ContinuousClock.now < deadline else { throw NativeAgentError.requestTimedOut }
            let count = data.withUnsafeBytes { bytes in
                Darwin.write(input.fileDescriptor, bytes.baseAddress!.advanced(by: offset), min(65_536, data.count - offset))
            }
            if count > 0 { offset += count }
            else if count < 0 && errno == EINTR { continue }
            else if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                // Backpressure only while a frame is being written, never idle polling.
                try await Task.sleep(for: .milliseconds(10))
            } else { throw NativeAgentError.providerUnavailable("Provider input closed.") }
        }
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
            // FileHandle's buffered read can wait to fill the requested count on pipes.
            // A protocol peer keeps stdout open while awaiting our next request: use one
            // POSIX read, which returns the bytes currently available, without waiting for EOF.
            var buffer = [UInt8](repeating: 0, count: 65_536)
            while true {
                let count = Darwin.read(handle.fileDescriptor, &buffer, buffer.count)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { return }
                let data = Data(buffer.prefix(count))
                switch sink.yield(data) {
                case .dropped, .terminated: Self.terminate(process); return
                case .enqueued: break
                @unknown default: Self.terminate(process); return
                }
            }
        }
    }

    private func didTerminate(generation token: UUID) {
        if token == generation { cleanup() }
    }

    private func cleanup() {
        generation = UUID()
        writeTail?.cancel(); writeTail = nil
        input?.closeFile()
        input = nil
        process = nil
        stdoutContinuation = nil
        stderrContinuation = nil
        terminationContinuation = nil
    }
}
