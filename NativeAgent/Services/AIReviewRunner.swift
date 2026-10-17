import Foundation

struct AIReviewJob: Sendable {
    let recipient: AIRecipient
    let complete: @Sendable () async throws -> String
}

enum AIReviewRunner {
    static func context(history: [TimelineEntry], prompt: String) -> String {
        let messages = history.filter { $0.kind == .userMessage || $0.kind == .agentMessage }.suffix(24).map {
            ["role": $0.kind == .userMessage ? "user" : "assistant", "speaker": $0.title, "text": String($0.text.prefix(2_000))]
        }
        guard !messages.isEmpty else { return prompt }
        let json = (try? JSONSerialization.data(withJSONObject: messages, options: .sortedKeys)) ?? Data()
        return "Recent visible conversation excerpt (older messages and long tails may be omitted):\n" + String(decoding: json, as: UTF8.self) + "\n\nCurrent user question:\n" + prompt
    }
    /// Batch at most two requests. One provider failure never retries or cancels its peers.
    static func run(_ jobs: [AIReviewJob], receive: @escaping @Sendable (AIRecipient, Result<String, Error>) async -> Void) async {
        for offset in stride(from: 0, to: jobs.count, by: 2) {
            guard !Task.isCancelled else { return }
            await withTaskGroup(of: Void.self) { group in
                for job in jobs[offset..<min(offset + 2, jobs.count)] {
                    group.addTask {
                        let result: Result<String, Error>
                        do { try Task.checkCancellation(); result = .success(try await job.complete()) }
                        catch { result = .failure(error) }
                        guard !Task.isCancelled else { return }
                        await receive(job.recipient, result)
                    }
                }
            }
        }
    }

    static func grok(path: String, model: String, prompt: String, folder: String) async throws -> String {
        try await runtime(GrokProvider(path: path), model: model, prompt: prompt, folder: folder)
    }

    static func runtime(_ provider: any CodingProvider, model: String, prompt: String, folder: String, timeout: Duration = .seconds(180)) async throws -> String {
        return try await withTaskCancellationHandler {
            do {
                let answer = try await withThrowingTaskGroup(of: String.self) { group in
                    group.addTask {
                        try await provider.connect()
                        var started = false, text = ""
                        for await event in await provider.events {
                            try Task.checkCancellation()
                            switch event {
                            case .connected:
                                guard !started else { continue }; started = true
                                await provider.configure(.init(access: .readOnly, instructions: "Review and answer the question. Do not edit files or run commands."))
                                let thread = try await provider.startThread(projectPath: folder, model: model)
                                try await provider.startTurn(threadID: thread, prompt: prompt, projectPath: folder, model: model)
                            case .agentDelta(_, let delta):
                                guard text.count + delta.count <= 100_000 else { throw NativeAgentError.unsupported("Grok answer exceeded the review limit.") }
                                text += delta
                            case .approval(let request): try await provider.answerApproval(id: request.id, decision: .cancel)
                            case .authenticationRequired, .authenticationFailed:
                                throw NativeAgentError.unsupported("Reconnect your Grok account in Settings → Accounts.")
                            case .turnCompleted(_, let status, _):
                                guard status == .completed, !text.isEmpty else { throw NativeAgentError.unsupported("Grok review did not complete. No automatic retry was made.") }
                                return text
                            default: break
                            }
                        }
                        throw CancellationError()
                    }
                    group.addTask { try await Task.sleep(for: timeout); throw NativeAgentError.unsupported("Grok review timed out.") }
                    defer { group.cancelAll() }
                    return try await group.next()!
                }
                await provider.disconnect(); return answer
            } catch { await provider.disconnect(); throw error }
        } onCancel: { Task { await provider.disconnect() } }
    }
}
