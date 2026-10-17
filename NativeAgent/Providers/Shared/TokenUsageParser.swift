import Foundation

/// One provider request, or the current cumulative report for one runtime turn.
/// Nil tokens means the provider did not supply usable consumption counters.
struct ProviderTokenUsage: Equatable, Sendable {
    let id: String
    var turnID: String? = nil
    var threadID: String? = nil
    var model: String? = nil
    var tokens: UsageTokens? = nil
    var contextTokens: Int64? = nil
    var contextLimit: Int64? = nil
}

typealias ProviderTokenUsageCallback = @Sendable (ProviderTokenUsage) async -> Void

enum TokenUsageParser {
    static func count(_ value: JSONValue?) -> Int64? {
        guard case .number(let number) = value, number.isFinite, number >= 0, number <= 1_000_000_000_000 else { return nil }
        return Int64(exactly: number)
    }
    static func contextLimit(_ value: JSONValue?) -> Int64? {
        guard let limit = count(value), limit > 0 else { return nil }; return limit
    }

    static func responses(_ usage: JSONValue?) -> UsageTokens? {
        normalized(input: usage?["input_tokens"], output: usage?["output_tokens"],
            cached: usage?["input_tokens_details"]?["cached_tokens"],
            written: usage?["input_tokens_details"]?["cache_write_tokens"],
            reasoning: usage?["output_tokens_details"]?["reasoning_tokens"])
    }

    static func api(_ response: JSONValue, format: AIWireFormat, requestID: String, model: String) -> ProviderTokenUsage {
        let usage = response["usage"]
        let tokens: UsageTokens?
        if format == .anthropic {
            // Anthropic reports uncached input separately from both cache buckets.
            if let input = count(usage?["input_tokens"]), let output = count(usage?["output_tokens"]),
               validOptional(usage?["cache_read_input_tokens"]), validOptional(usage?["cache_creation_input_tokens"]) {
                let read = count(usage?["cache_read_input_tokens"]), write = count(usage?["cache_creation_input_tokens"])
                let totalInput = input + (read ?? 0) + (write ?? 0)
                tokens = totalInput + output <= 1_000_000_000_000 ? UsageTokens(inputTokens: totalInput, outputTokens: output,
                    cachedInputTokens: read, cacheWriteInputTokens: write) : nil
            } else { tokens = nil }
        } else {
            tokens = normalized(input: usage?["prompt_tokens"], output: usage?["completion_tokens"],
                cached: usage?["prompt_tokens_details"]?["cached_tokens"],
                written: usage?["prompt_tokens_details"]?["cache_write_tokens"],
                reasoning: usage?["completion_tokens_details"]?["reasoning_tokens"])
        }
        return .init(id: response["id"]?.stringValue.nonempty ?? requestID,
                     model: response["model"]?.stringValue.nonempty ?? model, tokens: tokens)
    }

    static func codex(_ usage: JSONValue?) -> UsageTokens? {
        normalized(input: usage?["inputTokens"], output: usage?["outputTokens"], cached: usage?["cachedInputTokens"],
            written: usage?["cacheWriteInputTokens"], reasoning: usage?["reasoningOutputTokens"])
    }

    static func acpContext(_ update: JSONValue, threadID: String, turnID: String?, model: String?) -> ProviderTokenUsage {
        .init(id: "grok/" + threadID + "/" + (turnID ?? "context"), turnID: turnID, threadID: threadID,
              model: model, contextTokens: count(update["used"]), contextLimit: contextLimit(update["size"]))
    }

    private static func validOptional(_ value: JSONValue?) -> Bool { value == nil || value == .null || count(value) != nil }
    private static func normalized(input: JSONValue?, output: JSONValue?, cached: JSONValue?, written: JSONValue?, reasoning: JSONValue?) -> UsageTokens? {
        guard let input = count(input), let output = count(output), input + output <= 1_000_000_000_000 else { return nil }
        return UsageTokens(inputTokens: input, outputTokens: output, cachedInputTokens: count(cached),
                           cacheWriteInputTokens: count(written), reasoningOutputTokens: count(reasoning))
    }

    static func difference(_ current: UsageTokens, from baseline: UsageTokens) -> UsageTokens? {
        guard current.inputTokens >= baseline.inputTokens, current.outputTokens >= baseline.outputTokens else { return nil }
        func subtract(_ current: Int64?, _ old: Int64?) -> Int64? {
            guard let current, let old, current >= old else { return nil }; return current - old
        }
        return UsageTokens(inputTokens: current.inputTokens - baseline.inputTokens, outputTokens: current.outputTokens - baseline.outputTokens,
            cachedInputTokens: subtract(current.cachedInputTokens, baseline.cachedInputTokens),
            cacheWriteInputTokens: subtract(current.cacheWriteInputTokens, baseline.cacheWriteInputTokens),
            reasoningOutputTokens: subtract(current.reasoningOutputTokens, baseline.reasoningOutputTokens))
    }
}

/// Tracks exactly one HTTP request, including an interrupted or failed response.
struct ResponseUsageTracker {
    private var id: String
    private let turnID: String?, threadID: String?
    private var model: String?
    private var reported = false

    init(requestID: String = UUID().uuidString, turnID: String? = nil, threadID: String? = nil, model: String?) {
        id = requestID; self.turnID = turnID; self.threadID = threadID; self.model = model
    }
    mutating func consume(_ frame: String) throws -> ProviderTokenUsage? {
        let event = try JSONDecoder().decode(JSONValue.self, from: Data(frame.utf8))
        if let responseID = event["response"]?["id"]?.stringValue.nonempty { id = responseID }
        if let actualModel = event["response"]?["model"]?.stringValue.nonempty { model = actualModel }
        guard ["response.completed", "response.failed", "response.incomplete", "error"].contains(event["type"]?.stringValue ?? "") else { return nil }
        reported = true
        return .init(id: id, turnID: turnID, threadID: threadID, model: model, tokens: TokenUsageParser.responses(event["response"]?["usage"]))
    }
    mutating func finish() -> ProviderTokenUsage? {
        guard !reported else { return nil }; reported = true
        return .init(id: id, turnID: turnID, threadID: threadID, model: model)
    }
}

/// A resumed thread's lifetime counters are only a baseline, never new usage.
/// Each update for the accepted turn replaces the same report in persistence.
struct CodexTurnUsageTracker {
    private var threadID: String?
    private var cumulative: UsageTokens?
    private var baseline: UsageTokens?
    private var activeTurnID: String?
    private var model: String?
    private var preparing = false
    private var buffered: [JSONValue] = []
    private var lastReport: ProviderTokenUsage?
    private var bufferOverflow = false
    var needsBaseline: Bool { cumulative == nil }

    mutating func reset(threadID: String, newThread: Bool, response: JSONValue? = nil) {
        self = Self(); self.threadID = threadID
        cumulative = newThread ? UsageTokens(inputTokens: 0, outputTokens: 0, cachedInputTokens: 0, cacheWriteInputTokens: 0, reasoningOutputTokens: 0) : nil
        captureBaseline(response)
    }
    mutating func captureBaseline(_ response: JSONValue?) {
        if let total = TokenUsageParser.codex(response?["thread"]?["tokenUsage"]?["total"] ?? response?["tokenUsage"]?["total"]), isAtLeastCurrent(total) { cumulative = total }
    }
    mutating func prepare(model: String?) {
        self.model = model; baseline = cumulative; activeTurnID = nil; lastReport = nil; preparing = true; buffered = []; bufferOverflow = false
    }
    mutating func activate(turnID: String) -> [ProviderTokenUsage] {
        guard preparing else { return [] }
        // Resume may replay usage while turn/start is awaiting its response.
        // Only that response's turn ID is authoritative for the new operation.
        for value in buffered where value["turnId"]?.stringValue != turnID {
            if let total = TokenUsageParser.codex(value["tokenUsage"]?["total"]), isAtLeastCurrent(total) { baseline = total; cumulative = total }
        }
        if bufferOverflow { baseline = nil }
        activeTurnID = turnID; preparing = false
        let pending = buffered; buffered = []
        return pending.compactMap { consume($0) }
    }
    mutating func consume(_ params: JSONValue) -> ProviderTokenUsage? {
        guard let threadID, params["threadId"]?.stringValue == threadID else { return nil }
        if preparing {
            if buffered.count < 256 { buffered.append(params) }
            else { bufferOverflow = true } // Never infer a complete turn from dropped updates.
            return nil
        }
        let total = TokenUsageParser.codex(params["tokenUsage"]?["total"])
        guard let turnID = activeTurnID else {
            // Delayed history replay must never lower an already observed total.
            if let total, isAtLeastCurrent(total) { cumulative = total }
            return nil
        }
        guard params["turnId"]?.stringValue == turnID else { return nil }
        if let total, let previous = cumulative,
           total.inputTokens < previous.inputTokens || total.outputTokens < previous.outputTokens { baseline = nil }
        let tokens = total.flatMap { total in baseline.flatMap { TokenUsageParser.difference(total, from: $0) } }
        cumulative = total
        let report = ProviderTokenUsage(id: "codex/" + threadID + "/" + turnID, turnID: turnID, threadID: threadID, model: model,
            tokens: tokens, contextTokens: TokenUsageParser.count(params["tokenUsage"]?["last"]?["totalTokens"]),
            contextLimit: TokenUsageParser.contextLimit(params["tokenUsage"]?["modelContextWindow"]))
        lastReport = report
        return report
    }
    mutating func finish(turnID: String) -> ProviderTokenUsage? {
        guard turnID == activeTurnID, let threadID else { return nil }
        defer { activeTurnID = nil; baseline = nil; lastReport = nil }
        if lastReport == nil { cumulative = nil }
        return lastReport == nil ? ProviderTokenUsage(id: "codex/" + threadID + "/" + turnID, turnID: turnID, threadID: threadID, model: model) : nil
    }
    private func isAtLeastCurrent(_ total: UsageTokens) -> Bool {
        guard let cumulative else { return true }
        return total.inputTokens >= cumulative.inputTokens && total.outputTokens >= cumulative.outputTokens
    }
}

private extension Optional where Wrapped == String {
    var nonempty: String? { flatMap { $0.isEmpty ? nil : $0 } }
}
